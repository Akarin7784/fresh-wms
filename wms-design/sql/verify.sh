#!/usr/bin/env bash
# =============================================================================
#  WMS 核心表结构验证脚本（PG 侧）
#  用法：
#    A) 有 PG 连接（如 GitHub Actions 的 postgres service container）：
#         PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=xxx PGDATABASE=postgres bash sql/verify.sh
#       只要设置了 PGHOST，就直连该库（需要本机有 psql 客户端）。注意：脚本会在该库建表，请用空库。
#    B) 未设置 PGHOST：回退为起一次性 Docker PG16 容器（docker exec 执行 psql）。
#  作用：建表 → 表/索引/视图数量 → 约束断言（按约束名精确匹配）→ 差异列 → FEFO → 50 并发防超卖
#  退出码非 0 即表示设计文档中的某条主张不成立
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SCHEMA=sql/schema_postgres.sql
# 期望值：main 8ed5f0c 为 38 表 / 99 索引 / 1 视图；docs/02 新增 stock_hold、stock_recon_alert
# 两张表及若干 UNIQUE/索引 → 40 表 / 111 索引（含 PK 与 UNIQUE 自动索引）/ 1 视图。改 DDL 必须同步改这里。
EXPECT_TABLES=40
EXPECT_INDEXES=111
EXPECT_VIEWS=1

CTR=wms-pg-verify
PORT=55432
pass=0; fail=0

ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }

if [ ! -f "$SCHEMA" ]; then
  echo "  ✗ 找不到 $SCHEMA"; exit 1
fi

if [ -n "${PGHOST:-}" ]; then
  MODE=env
  command -v psql >/dev/null 2>&1 || { echo "  ✗ 设置了 PGHOST 但本机没有 psql 客户端"; exit 1; }
  export PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"
  psql() { command psql -X "$@" 2>&1; }
  cleanup() { :; }
  echo "=== 0. 直连 PG：$PGUSER@$PGHOST:$PGPORT/$PGDATABASE ==="
  for _ in $(seq 1 30); do command psql -X -t -A -c "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
else
  MODE=docker
  command -v docker >/dev/null 2>&1 || { echo "  ✗ 未设置 PGHOST，且本机没有 docker，无法验证 PG 侧"; exit 1; }
  psql() { docker exec -i "$CTR" psql -X -U postgres -d postgres "$@" 2>&1; }
  cleanup() { docker rm -f "$CTR" >/dev/null 2>&1; }
  echo "=== 0. 启动一次性 PG16 容器（回退模式）==="
  docker rm -f "$CTR" >/dev/null 2>&1
  docker run -d --name "$CTR" -e POSTGRES_PASSWORD=verify -p $PORT:5432 postgres:16-alpine >/dev/null
  for _ in $(seq 1 60); do docker exec "$CTR" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
fi

echo "=== 1. 建表（ON_ERROR_STOP，任何语法/方言错误直接失败）==="
SCHEMA_OUT=$(psql -v ON_ERROR_STOP=1 -q < "$SCHEMA")
if [ -n "$SCHEMA_OUT" ]; then
  bad "schema 执行报错"; echo "$SCHEMA_OUT" | head -20; cleanup; exit 1
fi
ok "schema_postgres.sql 在 PG16 全量执行通过（无任何告警输出）"

T=$(psql -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")
I=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public'")
V=$(psql -t -A -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public'")
echo "  → 表 $T 张 / 索引 $I 个 / 视图 $V 个"
[ "$T" = "$EXPECT_TABLES" ]  && ok "表数 = $T"   || bad "表数 = $T，期望 $EXPECT_TABLES"
[ "$I" = "$EXPECT_INDEXES" ] && ok "索引数 = $I" || bad "索引数 = $I，期望 $EXPECT_INDEXES"
[ "$V" = "$EXPECT_VIEWS" ]   && ok "视图数 = $V" || bad "视图数 = $V，期望 $EXPECT_VIEWS"

echo "=== 2. 库层不变量断言（§4.1 I1–I5 + §2.2 SoD + §4.6 幂等）==="
seed() { psql -q -c "$1" >/dev/null; }
seed "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WH-SH-01','上海青浦仓','20:00',-1);"
seed "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK'),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE');"
seed "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010');"
seed "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10);"
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16);"
seed "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (11,1,1,1,2,'KG',50000,0),(12,1,2,1,1,'KG',30000,10000),(13,1,3,1,3,'KG',200000,0),(14,1,3,1,1,'KG',80000,0);"

expect_block() {  # $1 描述  $2 SQL  $3 期望命中的约束名（或错误片段）
  # 注意：不要用 `psql | grep -q`。grep -q 命中即退出会触发 SIGPIPE，
  # 在 set -o pipefail 下会把"确实拦截了"误判成"未拦截"。先捕获再匹配。
  # 只认"指定约束"拦下：被别的约束/语法错误拦下 = 这条断言没测到它声称测的东西。
  local out; out=$(psql -q -c "$2")
  # 约束名按 PG 报错里的 "name" 带引号精确匹配（避免 ck_res 误命中 ck_res_int）；含空格的 $3 视为错误片段子串匹配
  local pat="\"$3\""; case "$3" in *" "*) pat="$3";; esac
  case "$out" in
    *ERROR*"$pat"*) ok "$1 → 已拦截（$3）";;
    *ERROR*) bad "$1 → 被拦了但约束不对，期望 $3：$(echo "$out" | head -1)";;
    *) bad "$1 → 未拦截（设计有洞）";;
  esac
}
expect_allow() {  # $1 描述  $2 SQL —— 参数顺序与 expect_block 保持一致
  local out; out=$(psql -q -c "$2")
  case "$out" in *ERROR*) bad "$1 → 被误拦：$out";; *) ok "$1 → 通过";; esac
}

expect_block "I2 超占（allocated>on_hand）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (900,1,1,1,1,'KG',10000,99000);" \
  "ck_stock_nonneg"
expect_block "I5 流水平衡（after<>before+qty*dir）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'PK1',1,1,'PICK',-1,11,1,1,1,1,1,3000,100000,98000,'2026-10-15','k1');" \
  "ck_mv_balance"
expect_allow "写入一条平衡的合法流水" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'PK1',1,1,'PICK',-1,11,1,1,1,1,1,3000,100000,97000,'2026-10-15','k2');"
expect_block "§4.6③ 记账层幂等（idempotency_key 重复）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'PK1',2,1,'PICK',-1,11,2,1,1,1,1,3000,97000,94000,'2026-10-15','k2');" \
  "uq_mv_idem"
seed "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16');"
expect_block "§4.6② 业务层幂等（source_system+source_order_no 重复）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (2,'OBT2',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16');" \
  "uq_obo_src"
expect_block "§2.2 职责分离（拣货人=复核人）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date,picker_id,checker_id) VALUES (3,'OBT3',1,'SALE','MALL','M-2026-003',1,'CREATED','2026-10-16',77,77);" \
  "ck_obo_sod"
expect_block "I6 同维度重复库存行（container_id 用 0 哨兵后应被拦）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (21,1,3,1,1,0,'KG',5000);" \
  "uq_stock_dim"


echo "=== 2b. docs/02 库存核心：BIGINT *_qty_milli 与记账链断言 ==="
expect_block "02 重复过账（同 biz_no+line_no+leg，换一个 idempotency_key）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'PK1',1,1,'PICK',-1,11,9,1,1,1,1,3000,100000,97000,'2026-10-15','k-other');" \
  "uq_mv_biz_line"
expect_block "02 记账链分叉（同 stock_id+stock_seq）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'PK9',1,1,'PICK',-1,11,1,1,1,1,1,1000,100000,99000,'2026-10-15','k5');" \
  "uq_mv_stock_seq"
expect_allow "02 direction=0 纯事件流水不入链（SHIP）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'SHP1',1,1,'SHIP',0,11,1,1,1,1,1,3000,97000,97000,'2026-10-15','k6');"
expect_allow "02 PDA 拣货流水带第 5 篇业务键" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'PK2',3,1,'PICK',-1,12,1,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PICK:PK2:3:1');"
expect_block "02 Idempotency-Key 过期后 PDA 重放同一操作 → 业务键兜底" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'PK2',3,1,'PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','PICK:PK2:3:2');" \
  "uq_mv_pda_op"
expect_block "02 PDA 业务键半截（device_instance_id 为 NULL）" \
  "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'PK2',4,1,'PICK',-1,12,3,1,2,1,1,77,4,NULL,1,1000,28000,27000,'2026-10-15','PICK:PK2:4:1');" \
  "ck_mv_pda_src"
expect_block "02 文本小数写入 BIGINT（'12.500'）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (32,1,3,1,1,8,'KG','12.500');" \
  "invalid input syntax for type bigint"
# 已知方言差异（未在 PG 实测，待有 Docker 的机器确认）：PG 对数值字面量 3.5 → bigint 做赋值转换并四舍五入为 4，不报错。
# 所以"拒绝 3 位以上小数"只能靠应用层（Quantity 解析返回 400），库层 CHECK 只在 SQLite 侧能拦 REAL。
psql -q -c "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (31,1,3,1,1,7,'KG',3.5);" >/dev/null
R31=$(psql -t -A -c "SELECT on_hand_qty_milli FROM stock WHERE id=31")
[ "$R31" = "4" ] && ok "已知差异：PG 把 3.5 静默取整为 4（应用层必须先拦）" || bad "PG 3.5 写入结果 = '$R31'（与文档 02 §9 的预期不符，需更新文档）"
psql -q -c "DELETE FROM stock WHERE id=31;" >/dev/null   # 复原，避免干扰 FEFO 断言
expect_allow "02 占用写入（RESERVE 10000）" \
  "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli) VALUES (1,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1',10000);"
expect_block "02 占用幂等（同 op_key 重复占用）" \
  "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli) VALUES (2,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1',10000);" \
  "uq_res_op"
expect_block "02 占用超消耗（consumed+released > reserve）" \
  "UPDATE stock_reservation SET consumed_qty_milli = 6000, released_qty_milli = 5000 WHERE id = 1;" \
  "ck_res"
expect_block "02 冻结明细超释放（released > hold）" \
  "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,op_key,hold_qty_milli,released_qty_milli,operator_id) VALUES (1,11,'MANUAL','DAMAGE','MANUAL','HOLD:1',1000,2000,7);" \
  "ck_hold"

expect_allow "02 待回库 RETURN_PENDING 冻结（明细）" \
  "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (10,14,'MANUAL','RETURN_PENDING','RETURN_RECORD',501,'RTP:501',5000,7);"
expect_block "02 同一待回库记录重复冻结" \
  "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (11,14,'MANUAL','RETURN_PENDING','RETURN_RECORD',501,'RTP:501:dup',5000,7);" \
  "uq_hold_return"
expect_block "02 RETURN_PENDING 必须挂待回库记录且计入 frozen" \
  "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (12,14,'QUALITY','RETURN_PENDING','MANUAL',0,'RTP:x',1000,7);" \
  "ck_hold_return"
expect_block "02 冻结原因不在码表" \
  "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (13,14,'MANUAL','WHATEVER','MANUAL',0,'H:13',1000,7);" \
  "ck_hold_reason"

echo "=== 3. §5.6 盘点差异生成列（实盘 − 基准账面 − 期间流水）==="
seed "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (1,1,1,1,1,100000,-30000,68000);"
D=$(psql -t -A -c "SELECT diff_qty_milli FROM count_line WHERE id=1")
[ "$D" = "-2000" ] && ok "diff_qty_milli = $D（预期 -2000）" || bad "diff_qty_milli = $D（预期 -2000）"

echo "=== 4. §4.4 FEFO 候选池排序（出库禁发期 10 天）==="
# 放在并发测试之前：并发测试会插入 id=999 的 lot-1008 库存行，干扰排序断言
ORDER=$(psql -t -A -c "
SELECT lot_code FROM v_stock_available
WHERE sku_id=1 AND warehouse_id=1 AND available_qty_milli > 0
  AND expiry_date >= '2026-10-15'::date + 10
ORDER BY expiry_date ASC, remaining_life_days ASC, pick_sequence ASC, stock_id ASC;" | tr -d '\r')
EXPECT="LOT-1008
LOT-1008
LOT-1012
LOT-1014"
echo "  → 出库顺序：$(echo "$ORDER" | tr '\n' ' ')"
[ "$ORDER" = "$EXPECT" ] && ok "FEFO 全序列匹配（同批次内先拣货位 A01-03-01 后存储位 B02-01-05）" \
                         || bad "FEFO 排序偏离预期"
AV=$(psql -t -A -c "SELECT available_qty_milli FROM v_stock_available WHERE stock_id=12")
[ "$AV" = "20000" ] && ok "available_qty_milli = 30000 − 10000 = $AV" || bad "可用量计算错误：$AV"

echo "=== 5. §4.3 并发防超卖：50 个独立连接同时扣 3 KG，起始 100 KG ==="
psql -q -c "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (999,1,1,1,1,'KG',100000);" >/dev/null
CT_DIR=$(mktemp -d)
for _ in $(seq 1 50); do
  psql -t -A -c \
    "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1, updated_at = now() WHERE id = 999 AND on_hand_qty_milli >= 3000;" \
    > "$CT_DIR/ct_$_.out" &
done
wait
succ=$(grep -c 'UPDATE 1' "$CT_DIR"/ct_*.out 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
rej=$(grep -c 'UPDATE 0' "$CT_DIR"/ct_*.out 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
FINAL=$(psql -t -A -c "SELECT on_hand_qty_milli FROM stock WHERE id=999")
VER=$(psql -t -A -c "SELECT version FROM stock WHERE id=999")
echo "  → 成功 $succ / 拒绝 $rej / 剩余 $FINAL / version $VER"
[ "$succ" = "33" ] && [ "$rej" = "17" ] && [ "$FINAL" = "1000" ] && [ "$VER" = "33" ] \
  && ok "无超卖、无负库存、无丢更新（33×3000 + 1000 = 100000 milli）" \
  || bad "并发结果偏离预期"

echo "=== 汇总 ==="
echo "  通过 $pass 项 / 失败 $fail 项"
cleanup
[ "$fail" = "0" ]
