#!/usr/bin/env bash
# =============================================================================
#  WMS 核心表结构验证脚本
#  用法：bash sql/verify.sh          （需要 Docker）
#  作用：在一次性 PG 容器上建表 → 跑 7 项约束断言 + 1 项并发防超卖 + 1 项 FEFO 排序
#  退出码非 0 即表示设计文档中的某条主张不成立
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

CTR=wms-pg-verify
PORT=55432
pass=0; fail=0

ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }
psql() { docker exec -i "$CTR" psql -U postgres -d postgres "$@" 2>&1; }

echo "=== 0. 启动一次性 PG16 容器 ==="
docker rm -f "$CTR" >/dev/null 2>&1
docker run -d --name "$CTR" -e POSTGRES_PASSWORD=verify -p $PORT:5432 postgres:16-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$CTR" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

echo "=== 1. 建表（ON_ERROR_STOP，任何语法/方言错误直接失败）==="
SCHEMA_OUT=$(psql -v ON_ERROR_STOP=1 -q < sql/schema_postgres.sql)
if [ -n "$SCHEMA_OUT" ]; then
  bad "schema 执行报错"; echo "$SCHEMA_OUT" | head -20; docker rm -f "$CTR" >/dev/null 2>&1; exit 1
fi
ok "schema_postgres.sql 在 PG16 全量执行通过（无任何告警输出）"

T=$(psql -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")
I=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public'")
V=$(psql -t -A -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public'")
echo "  → 表 $T 张 / 索引 $I 个 / 视图 $V 个"

echo "=== 2. 库层不变量断言（§4.1 I1–I5 + §2.2 SoD + §4.6 幂等）==="
seed() { psql -q -c "$1" >/dev/null; }
seed "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WH-SH-01','上海青浦仓','20:00',-1);"
seed "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK'),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE');"
seed "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010');"
seed "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10);"
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16);"
seed "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand,allocated) VALUES (11,1,1,1,2,'KG',50,0),(12,1,2,1,1,'KG',30,10),(13,1,3,1,3,'KG',200,0),(14,1,3,1,1,'KG',80,0);"

expect_block() {  # $1 描述  $2 SQL
  # 注意：不要用 `psql | grep -q`。grep -q 命中即退出会触发 SIGPIPE，
  # 在 set -o pipefail 下会把"确实拦截了"误判成"未拦截"。先捕获再匹配。
  local out; out=$(psql -q -c "$2")
  case "$out" in *ERROR*) ok "$1 → 已拦截";; *) bad "$1 → 未拦截（设计有洞）";; esac
}
expect_allow() {  # $1 描述  $2 SQL —— 参数顺序与 expect_block 保持一致
  local out; out=$(psql -q -c "$2")
  case "$out" in *ERROR*) bad "$1 → 被误拦：$out";; *) ok "$1 → 通过";; esac
}

expect_block "I2 超占（allocated>on_hand）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand,allocated) VALUES (900,1,1,1,1,'KG',10,99);"
expect_block "I5 流水平衡（after<>before+qty*dir）" \
  "INSERT INTO stock_movement (id,biz_no,biz_type,direction,warehouse_id,location_id,sku_id,lot_id,quantity,on_hand_before,on_hand_after,occurred_at,idempotency_key) VALUES (1,'PK1','PICK',-1,1,1,1,1,3,100,98,'2026-10-15','k1');"
expect_allow "写入一条平衡的合法流水" \
  "INSERT INTO stock_movement (id,biz_no,biz_type,direction,warehouse_id,location_id,sku_id,lot_id,quantity,on_hand_before,on_hand_after,occurred_at,idempotency_key) VALUES (2,'PK1','PICK',-1,1,1,1,1,3,100,97,'2026-10-15','k2');"
expect_block "§4.6③ 记账层幂等（idempotency_key 重复）" \
  "INSERT INTO stock_movement (id,biz_no,biz_type,direction,warehouse_id,location_id,sku_id,lot_id,quantity,on_hand_before,on_hand_after,occurred_at,idempotency_key) VALUES (3,'PK1','PICK',-1,1,1,1,1,3,100,97,'2026-10-15','k2');"
seed "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16');"
expect_block "§4.6② 业务层幂等（source_system+source_order_no 重复）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (2,'OBT2',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16');"
expect_block "§2.2 职责分离（拣货人=复核人）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date,picker_id,checker_id) VALUES (3,'OBT3',1,'SALE','MALL','M-2026-003',1,'CREATED','2026-10-16',77,77);"
expect_block "I6 同维度重复库存行（container_id 用 0 哨兵后应被拦）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand) VALUES (21,1,3,1,1,0,'KG',5);"

echo "=== 3. §5.6 盘点差异生成列（实盘 − 基准账面 − 期间流水）==="
seed "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty,movement_qty,actual_qty) VALUES (1,1,1,1,1,100,-30,68);"
D=$(psql -t -A -c "SELECT diff_qty FROM count_line WHERE id=1")
[ "$D" = "-2.000" ] && ok "diff_qty = $D（预期 -2.000）" || bad "diff_qty = $D（预期 -2.000）"

echo "=== 4. §4.4 FEFO 候选池排序（出库禁发期 10 天）==="
# 放在并发测试之前：并发测试会插入 id=999 的 lot-1008 库存行，干扰排序断言
ORDER=$(psql -t -A -c "
SELECT lot_code FROM v_stock_available
WHERE sku_id=1 AND warehouse_id=1 AND available_qty > 0
  AND expiry_date >= '2026-10-15'::date + 10
ORDER BY expiry_date ASC, remaining_life_days ASC, pick_sequence ASC, stock_id ASC;" | tr -d '\r')
EXPECT="LOT-1008
LOT-1008
LOT-1012
LOT-1014"
echo "  → 出库顺序：$(echo "$ORDER" | tr '\n' ' ')"
[ "$ORDER" = "$EXPECT" ] && ok "FEFO 全序列匹配（同批次内先拣货位 A01-03-01 后存储位 B02-01-05）" \
                         || bad "FEFO 排序偏离预期"
AV=$(psql -t -A -c "SELECT available_qty FROM v_stock_available WHERE stock_id=12")
[ "$AV" = "20.000" ] && ok "available = on_hand(30) − allocated(10) = $AV" || bad "可用量计算错误：$AV"

echo "=== 5. §4.3 并发防超卖：50 个独立连接同时扣 3 KG，起始 100 KG ==="
psql -q -c "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand) VALUES (999,1,1,1,1,'KG',100.000);" >/dev/null
rm -f /tmp/wms_ct_*.out
for _ in $(seq 1 50); do
  docker exec -i "$CTR" psql -U postgres -d postgres -t -A -c \
    "UPDATE stock SET on_hand = on_hand - 3.000, version = version + 1, updated_at = now() WHERE id = 999 AND on_hand >= 3.000;" \
    > "/tmp/wms_ct_$_.out" 2>&1 &
done
wait
succ=$(grep -c 'UPDATE 1' /tmp/wms_ct_*.out 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
rej=$(grep -c 'UPDATE 0' /tmp/wms_ct_*.out 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
FINAL=$(psql -t -A -c "SELECT on_hand FROM stock WHERE id=999")
echo "  → 成功 $succ / 拒绝 $rej / 剩余 $FINAL"
[ "$succ" = "33" ] && [ "$rej" = "17" ] && [ "$FINAL" = "1.000" ] \
  && ok "无超卖、无负库存、无丢更新（33×3 + 1 = 100）" \
  || bad "并发结果偏离预期"

echo "=== 汇总 ==="
echo "  通过 $pass 项 / 失败 $fail 项"
docker rm -f "$CTR" >/dev/null 2>&1
[ "$fail" = "0" ]
