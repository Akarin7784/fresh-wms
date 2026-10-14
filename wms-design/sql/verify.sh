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
# 期望值：main 8ed5f0c 为 38 表 / 99 索引 / 1 视图。docs/02 新增 stock_hold、stock_recon_alert、
# stock_movement_key、stock_ledger_line → 42 表 / 114 索引（含 PK、UNIQUE 自动索引和分区父表上的分区索引；
# 分区子表及其继承来的索引不计）/ 1 视图。二轮 C2 加 uq_mvk_mv（外键被引用键）→ 115；A3 加 stock_hold_release（PK、uq_hr_op、ix_hr_hold）→ 43 表 / 118。改 DDL 必须同步改这里。
# 必须用新建的空库跑（DROP SCHEMA public 重建会丢 wms_app 的 USAGE；schema 里已 GRANT USAGE 兜底，小赵 C6）。
EXPECT_TABLES=53   # +10 docs/01（含 md_disable_action_policy）
EXPECT_INDEXES=140   # +22 docs/01：10 主键 + 6 唯一 + 6 显式
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

T=$(psql -t -A -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relispartition")
I=$(psql -t -A -c "SELECT count(*) FROM pg_indexes i JOIN pg_class c ON c.relname=i.tablename JOIN pg_namespace n ON n.oid=c.relnamespace AND n.nspname=i.schemaname WHERE i.schemaname='public' AND NOT c.relispartition")
V=$(psql -t -A -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public'")
echo "  → 表 $T 张 / 索引 $I 个 / 视图 $V 个"
[ "$T" = "$EXPECT_TABLES" ]  && ok "表数 = $T"   || bad "表数 = $T，期望 $EXPECT_TABLES"
[ "$I" = "$EXPECT_INDEXES" ] && ok "索引数 = $I" || bad "索引数 = $I，期望 $EXPECT_INDEXES"
[ "$V" = "$EXPECT_VIEWS" ]   && ok "视图数 = $V" || bad "视图数 = $V，期望 $EXPECT_VIEWS"

# 小赵 S4：按期望权限矩阵逐表核对 wms_app（表、分区父表、视图、物化视图；序列查 USAGE），多给、少给、漏表都失败
EXPECT_PRIVS="adjust_line:SELECT,INSERT,UPDATE adjust_order:SELECT,INSERT,UPDATE api_credential:SELECT,INSERT,UPDATE audit_log:SELECT,INSERT count_line:SELECT,INSERT,UPDATE count_order:SELECT,INSERT,UPDATE customer:SELECT,INSERT,UPDATE device:SELECT,INSERT,UPDATE driver:SELECT,INSERT,UPDATE idempotency_record:SELECT,INSERT,UPDATE inbound_line:SELECT,INSERT,UPDATE inbound_message:SELECT,INSERT,UPDATE inbound_order:SELECT,INSERT,UPDATE location:SELECT,INSERT,UPDATE lot:SELECT,INSERT,UPDATE md_change_log:SELECT,INSERT md_disable_action_policy:SELECT md_pending_disable:SELECT,INSERT,UPDATE md_sync_state:SELECT,INSERT,UPDATE node_registry:SELECT,INSERT numbering_segment:SELECT,INSERT,UPDATE outbound_line:SELECT,INSERT,UPDATE outbound_order:SELECT,INSERT,UPDATE outbox_event:SELECT,INSERT,UPDATE pack_box:SELECT,INSERT,UPDATE pack_box_line:SELECT,INSERT,UPDATE pick_task:SELECT,INSERT,UPDATE pick_task_line:SELECT,INSERT,UPDATE shipment:SELECT,INSERT,UPDATE shipment_order:SELECT,INSERT,UPDATE sku:SELECT,INSERT,UPDATE sku_barcode:SELECT,INSERT,UPDATE sku_unit:SELECT,INSERT,UPDATE stock:SELECT,INSERT,UPDATE stock_hold:SELECT,INSERT stock_hold_release:SELECT,INSERT stock_ledger_line:SELECT,INSERT stock_movement:SELECT,INSERT stock_movement_key:SELECT,INSERT stock_recon_alert:SELECT,INSERT,UPDATE stock_reservation:SELECT,INSERT,UPDATE stock_snapshot_daily:SELECT,INSERT supplier:SELECT,INSERT,UPDATE sys_permission:SELECT,INSERT,UPDATE sys_role:SELECT,INSERT,UPDATE sys_role_perm:SELECT,INSERT,UPDATE sys_user:SELECT,INSERT,UPDATE sys_user_role:SELECT,INSERT,UPDATE sys_user_warehouse:SELECT,INSERT,UPDATE v_stock_available:SELECT vehicle:SELECT,INSERT,UPDATE warehouse:SELECT,INSERT,UPDATE wave:SELECT,INSERT,UPDATE zone:SELECT,INSERT,UPDATE"
ACT=$(psql -t -A -c "SELECT string_agg(x, ' ' ORDER BY x) FROM (SELECT c.relname || ':' || COALESCE(NULLIF(concat_ws(',', CASE WHEN c.relkind='S' THEN (CASE WHEN has_sequence_privilege('wms_app', c.oid, 'USAGE') THEN 'USAGE' END) ELSE (CASE WHEN has_table_privilege('wms_app', c.oid, 'SELECT') THEN 'SELECT' END) END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'INSERT') THEN 'INSERT' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'UPDATE') THEN 'UPDATE' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'DELETE') THEN 'DELETE' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'TRUNCATE') THEN 'TRUNCATE' END), ''), 'NONE') AS x FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S') AND NOT c.relispartition) t")
if [ "$ACT" = "$EXPECT_PRIVS" ]; then ok "S4 wms_app 权限矩阵与期望逐表一致（$(echo "$ACT" | wc -w) 个对象；列级 UPDATE 另测）"
else bad "S4 wms_app 权限矩阵不符：$(diff <(echo "$EXPECT_PRIVS" | tr ' ' '\n') <(echo "$ACT" | tr ' ' '\n') | grep '^[<>]' | tr '\n' ' ')"; fi
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
    *ERROR*"$pat"*|*"ERROR:  $3"*) ok "$1 → 已拦截（$3）";;   # 第二种：触发器 RAISE 的消息不带引号
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
seed "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');"
expect_block "§4.6② 业务层幂等（source_system+source_order_no 重复）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (2,'OBT2',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');" \
  "uq_obo_src"
expect_block "§2.2 职责分离（拣货人=复核人）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date,picker_id,checker_id) VALUES (3,'OBT3',1,'SALE','MALL','M-2026-003','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16',77,77);" \
  "ck_obo_sod"
expect_block "I6 同维度重复库存行（container_id 用 0 哨兵后应被拦）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (21,1,3,1,1,0,'KG',5000);" \
  "uq_stock_dim"

echo "=== 2a'. docs/04 出库数量 milli、source_hash、回冲上限 ==="
expect_block "04 D6 source_hash 不是 64 位（空串）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (4,'OBT4',1,'SALE','MALL','M-2026-004','',1,'CREATED','2026-10-16');" \
  "ck_obo_hash"
expect_block "N4 source_hash 大写 hex" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (6,'OBT6',1,'SALE','MALL','M-2026-006','Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');" \
  "ck_obo_hash"
expect_block "N4 source_hash 非 hex（z）" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (7,'OBT7',1,'SALE','MALL','M-2026-007','zaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');" \
  "ck_obo_hash"
expect_block "N4 source_hash 长度 63" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8,'OBT8',1,'SALE','MALL','M-2026-008','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');" \
  "ck_obo_hash"
expect_block "04 I4 非法出库单状态" \
  "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (5,'OBT5',1,'SALE','MALL','M-2026-005','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'ALLOCATING','2026-10-16');" \
  "ck_obo_status"
seed "INSERT INTO outbound_line (id,outbound_id,line_no,sku_id,order_qty_milli,picked_qty_milli,uom) VALUES (1,1,1,1,10000,5000,'KG');"
expect_block "04 D4 回冲超过拣出（reversed > picked）" \
  "UPDATE outbound_line SET reversed_qty_milli = 6000 WHERE id = 1;" \
  "ck_obl_reversed"
expect_block "04 出库行数量为负" \
  "UPDATE outbound_line SET short_qty_milli = -1 WHERE id = 1;" \
  "ck_obl_nonneg"
R1=$(psql -t -A -c "UPDATE outbound_line SET reversed_qty_milli = reversed_qty_milli + 3000 WHERE id = 1 AND reversed_qty_milli + 3000 <= picked_qty_milli RETURNING 1" | grep -c '^1$')
R2=$(psql -t -A -c "UPDATE outbound_line SET reversed_qty_milli = reversed_qty_milli + 3000 WHERE id = 1 AND reversed_qty_milli + 3000 <= picked_qty_milli RETURNING 1" | grep -c '^1$')
[ "$R1" = "1" ] && [ "$R2" = "0" ] && ok "04 回冲条件更新：第 1 次 3000 → 1 行；再冲 3000 超过 picked 5000 → 0 行（走 42214，不靠 CHECK）" \
  || bad "04 回冲条件更新 rowcount = $R1/$R2（期望 1/0）"


echo "=== 2b. docs/02 库存核心：BIGINT *_qty_milli 与记账链断言 ==="
expect_block "02 文本小数写入 BIGINT（'12.500'）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (32,1,3,1,1,8,'KG','12.500');" \
  "invalid input syntax for type bigint"


echo "=== 2b. docs/02 库存核心：记账去重、只追加、期初、互斥、占用/冻结状态、对账去重 ==="
expect_block "I5 流水平衡（after<>before+qty*dir）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ0',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'ADJ0',1,1,1,'DOC','ADJUST',-1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,3000,100000,98000,'2026-10-15','ADJ0:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (1,'ADJ0:1:D1:1','ADJ0',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,-1,'2026-10-15'); COMMIT;" \
  "ck_mv_balance"
expect_allow "期初流水 OPENING（迁移行 seq=1，before=0）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',11,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'OPEN-MIG1',11,1,1,'DOC','OPENING',1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:11:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (2,'OPEN-MIG1:11:D1:1','OPEN-MIG1',11,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,1,'2026-10-15'); COMMIT;"
expect_block "期初流水只能是该行第 1 条" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',111,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'OPEN-MIG1',111,1,1,'DOC','OPENING',1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:111:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (3,'OPEN-MIG1:111:D1:1','OPEN-MIG1',111,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,1,'2026-10-15'); COMMIT;" \
  "ck_mv_opening"
expect_allow "DOC 过账（调整出 3000）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','ADJ1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (4,'ADJ1:1:D1:1','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,-1,'2026-10-15'); COMMIT;"
expect_block "重复过账：同 biz_no+line_no+op_no+leg，换 idempotency_key" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,9,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','X:other'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (5,'X:other','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,9,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_biz_line"
expect_allow "同一 DOC 行第二次合法操作（op_no=2，不被吞）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'ADJ1',1,2,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,47000,46000,'2026-10-15','ADJ1:1:D2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6,'ADJ1:1:D2:1','ADJ1',1,2,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15'); COMMIT;"
expect_block "idempotency_key 重复（唯一格式）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ9',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'ADJ9',1,1,1,'DOC','ADJUST',-1,11,4,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (7,'ADJ1:1:D1:1','ADJ9',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,4,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_idem"
expect_block "记账链分叉（同 stock_id+stock_seq）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ8',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'ADJ8',1,1,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ8:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (8,'ADJ8:1:D1:1','ADJ8',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_stock_seq"
expect_allow "direction=0 纯事件流水不入链（SHIP）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('SHP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'SHP1',1,1,1,'DOC','SHIP',0,11,3,1,1,1,2,NULL,NULL,NULL,NULL,3000,46000,46000,'2026-10-15','SHP1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (9,'SHP1:1:D1:1','SHP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,0,'2026-10-15'); COMMIT;"
expect_allow "期初：stock 12" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',12,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (10,'OPEN-MIG1',12,1,1,'DOC','OPENING',1,12,1,1,2,1,1,NULL,NULL,NULL,NULL,30000,0,30000,'2026-10-15','OPEN-MIG1:12:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (10,'OPEN-MIG1:12:D1:1','OPEN-MIG1',12,1,1,'DOC',NULL,NULL,NULL,NULL,12,1,1,'2026-10-15'); COMMIT;"
expect_allow "PDA 拣货（四元组 77/3/DEV-A/1）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (11,'PK2',3,0,1,'PDA','PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PK2:3:PDEV-A.1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (11,'PK2:3:PDEV-A.1:1','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,2,-1,'2026-10-15'); COMMIT;"
expect_block "Idempotency-Key 过期后 PDA 重放同一四元组（换 idempotency_key）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (12,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','X:replay'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (12,'X:replay','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,3,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_pda_op"
expect_allow "同一 PDA 行第二次合法操作（op_seq=2，不被吞）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (13,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',2,1000,29000,28000,'2026-10-15','PK2:3:PDEV-A.2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (13,'PK2:3:PDEV-A.2:1','PK2',3,0,1,'PDA',77,3,'DEV-A',2,12,3,-1,'2026-10-15'); COMMIT;"
expect_block "同一单据行 DOC 与 PDA 互斥（PDA 行上来一条 DOC 过账）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (14,'PK2',3,1,1,'DOC','PICK',-1,12,4,1,2,1,1,NULL,NULL,NULL,NULL,1000,28000,27000,'2026-10-15','PK2:3:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (14,'PK2:3:D1:1','PK2',3,1,1,'DOC',NULL,NULL,NULL,NULL,12,4,-1,'2026-10-15'); COMMIT;" \
  "ledger_line_owner_mismatch"
expect_block "换设备实例不能直接记账（DEV-B 不是当前持有设备）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-B') ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (15,'PK2',3,0,1,'PDA','PICK',-1,12,4,1,2,1,1,77,3,'DEV-B',1,1000,28000,27000,'2026-10-15','PK2:3:PDEV-B.1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (15,'PK2:3:PDEV-B.1:1','PK2',3,0,1,'PDA',77,3,'DEV-B',1,12,4,-1,'2026-10-15'); COMMIT;" \
  "ledger_line_owner_mismatch"
expect_block "PDA 业务键半截（device_instance_id 为 NULL）" \
  "BEGIN; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (16,'PK3',1,0,1,'PDA','PICK',-1,12,4,1,2,1,1,78,1,NULL,1,1000,28000,27000,'2026-10-15','PK3:1:PDEV-A.1:1'); COMMIT;" \
  "ck_mv_kind"
expect_block "只追加：UPDATE 流水" \
  "BEGIN; UPDATE stock_movement SET remark='x' WHERE id=4; COMMIT;" \
  "append_only_violation: stock_movement"
expect_block "只追加：DELETE 去重键" \
  "BEGIN; DELETE FROM stock_movement_key WHERE movement_id=4; COMMIT;" \
  "append_only_violation: stock_movement_key"
expect_allow "跨分区去重：10-31 记一条" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('XP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (17,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-10-31','XP1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (17,'XP1:1:D1:1','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-10-31'); COMMIT;"
expect_block "跨分区去重：同一键 11-01 再记（PG 落在另一个分区）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('XP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (18,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-11-01','X:xp'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (18,'X:xp','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-11-01'); COMMIT;" \
  "uq_mvk_biz_line"
expect_allow "占用写入（RESERVE 10000）" \
  "BEGIN; INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (1,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED'); COMMIT;"
expect_block "占用幂等（同 op_key）" \
  "BEGIN; INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (2,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED'); COMMIT;" \
  "uq_res_op"
expect_block "超消耗（consumed+released > reserve）" \
  "BEGIN; UPDATE stock_reservation SET consumed_qty_milli=6000, released_qty_milli=5000, status='CONSUMED' WHERE id=1; COMMIT;" \
  "ck_res"
expect_block "状态与余量不符：全部释放但仍是 RESERVED（过期任务会漏/重复扫）" \
  "BEGIN; UPDATE stock_reservation SET released_qty_milli=10000 WHERE id=1; COMMIT;" \
  "ck_res_status"
expect_block "状态与余量不符：余量>0 却标 RELEASED" \
  "BEGIN; UPDATE stock_reservation SET released_qty_milli=4000, status='RELEASED' WHERE id=1; COMMIT;" \
  "ck_res_status"
expect_block "冻结超释放" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (1,11,'MANUAL','DAMAGE','MANUAL',0,'HOLD:1',1000,2000,'RELEASED',7); COMMIT;" \
  "ck_hold"
expect_block "冻结状态与余量不符（已全释放仍 HELD）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (2,11,'MANUAL','DAMAGE','MANUAL',0,'HOLD:2',1000,1000,'HELD',7); COMMIT;" \
  "ck_hold_status"
expect_block "冻结类型不在码表" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (3,11,'FROZEN','DAMAGE','MANUAL',0,'HOLD:3',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_type"
expect_block "原因与类型不配（MANUAL 冒用 RETURN_PENDING）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (4,11,'MANUAL','RETURN_PENDING','RETURN_RECORD',501,'HOLD:4',1000,0,'HELD',0); COMMIT;" \
  "ck_hold_reason"
expect_block "RETURN_PENDING 必须挂待回库记录且为系统冻结" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (5,11,'RETURN_PENDING','RETURN_PENDING','MANUAL',0,'HOLD:5',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_return"
expect_allow "待回库 RETURN_PENDING 冻结（RRH:501）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (10,14,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',501,'RRH:501',5000,0,'HELD',0); COMMIT;"
expect_block "同一待回库记录重复冻结" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (11,14,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',501,'RRH:501:dup',5000,0,'HELD',0); COMMIT;" \
  "uq_hold_return"
expect_allow "对账告警（I4, stock 13）" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (1,'I4',1,13,200000,199000); COMMIT;"
expect_block "同一未闭环差异不重复建告警" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (2,'I4',1,13,200000,198000); COMMIT;" \
  "uq_recon_open"
expect_allow "重复检出走 upsert 累加 hit_count" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (3,'I4',1,13,200000,198000) ON CONFLICT (check_code,warehouse_id,stock_id) WHERE status <> 'RESOLVED' DO UPDATE SET hit_count = stock_recon_alert.hit_count + 1, actual_qty_milli = excluded.actual_qty_milli; COMMIT;"
expect_allow "闭环后同一差异可再开" \
  "BEGIN; UPDATE stock_recon_alert SET status='RESOLVED', resolved_by=7, resolution='调整单 ADJ-x' WHERE id=1; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (4,'I4',1,13,200000,199000); COMMIT;"
echo "=== 2b2. 小赵复评 C2–C5 + convert_hold ==="
expect_block "C2 只写流水、不写 key 行（库层外键，提交时拦）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ7',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (30,'ADJ7',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1'); COMMIT;" \
  "fk_mv_key"
expect_block "C2 key 行与流水内容不一致（key=ADJ7，流水=ADJ6）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ7',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (31,'ADJ6',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (31,'ADJ7:1:D1:1','ADJ7',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,1,-1,'2026-10-15'); COMMIT;" \
  "fk_mv_key"
expect_block "C3 归属行 src_kind 从 PDA 改成 DOC" \
  "BEGIN; UPDATE stock_ledger_line SET src_kind='DOC', owner_device_instance_id=NULL WHERE biz_no='PK2' AND line_no=3; COMMIT;" \
  "ledger_line_immutable"
expect_block "C3 归属行 biz_no 不可改" \
  "BEGIN; UPDATE stock_ledger_line SET biz_no='PK9' WHERE biz_no='PK2' AND line_no=3; COMMIT;" \
  "ledger_line_immutable"
expect_allow "C3 换主（只改 owner_device_instance_id）仍允许" \
  "BEGIN; UPDATE stock_ledger_line SET owner_device_instance_id='DEV-B', post_count=post_count+1 WHERE biz_no='PK2' AND line_no=3; COMMIT;"
expect_block "C4 check_code='ZZZ'" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9,'ZZZ',1,13,1,2); COMMIT;" \
  "ck_recon_code"
expect_allow "convert_hold 准备：stock 40 被 RETURN_PENDING 冻满（available=0）" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (40,1,2,1,3,'KG',5000,5000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (30,40,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',601,'RRH:601',5000,0,'HELD',0); COMMIT;"
expect_allow "convert_hold：available=0 时 RETURN_PENDING → SCRAP_PENDING/SCRAP（source_id = 报损单 9001）" \
  "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (31,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0); COMMIT;"
expect_block "convert_hold 重试：CVT:30 已存在（幂等，由 uq_hold_op 兜底）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (32,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0); COMMIT;" \
  "uq_hold_op"
R=$(psql -t -A -c "SELECT s.hold_qty_milli||'/'||v.available_qty_milli||'/'||(SELECT COALESCE(SUM(hold_qty_milli - released_qty_milli),0) FROM stock_hold WHERE stock_id=40 AND status='HELD' AND hold_type IN ('MANUAL','RETURN_PENDING','SCRAP_PENDING')) FROM stock s JOIN v_stock_available v ON v.stock_id=s.id WHERE s.id=40")
[ "$R" = "5000/0/5000" ] && ok "convert_hold 后 hold_qty/available/明细余量 = $R（冻结总量不变）" || bad "convert_hold 后 = $R（期望 5000/0/5000）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0")
[ "$R" = "UPDATE 0" ] && ok "convert_hold 并发第二个：关闭原冻结 rowcount=0" || bad "重复关闭：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 31 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "SCRAP_PENDING 人工解冻：人工路径只放行 QUALITY/MANUAL，rowcount=0（→ 40933）" || bad "人工解冻了 SCRAP_PENDING：$R"
expect_block "N1 SCRAP_PENDING 改成 MANUAL（洗白后人工解冻）" \
  "BEGIN; UPDATE stock_hold SET hold_type='MANUAL', reason_code='DAMAGE', operator_id=7 WHERE id=31; COMMIT;" \
  "hold_immutable"
expect_block "N1 改冻结明细数量 hold_qty_milli" \
  "BEGIN; UPDATE stock_hold SET hold_qty_milli=9000 WHERE id=31; COMMIT;" \
  "hold_immutable"
expect_block "N1 改冻结来源 source_type/source_id" \
  "BEGIN; UPDATE stock_hold SET source_type='MANUAL', source_id=0 WHERE id=31; COMMIT;" \
  "hold_immutable"
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE stock_hold SET hold_type='MANUAL', reason_code='DAMAGE', operator_id=7 WHERE id=31;")
case "$OUT" in *"permission denied for table stock_hold"*) ok "N1 wms_app 对 stock_hold.hold_type 无 UPDATE 列权限";; *) bad "wms_app 改 hold_type 未被拒：$OUT";; esac
R=$(psql -t -A -c "BEGIN; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 1000; SELECT s.hold_qty_milli||'/'||h.released_qty_milli||'/'||h.status FROM stock s JOIN stock_hold h ON h.stock_id=s.id WHERE h.id=31; ROLLBACK;" | grep '/')
[ "$R" = "4000/1000/HELD" ] && ok "N1 正常释放仍可：SCRAP_PENDING 释放 1000 + stock.hold_qty −1000 → $R（事务内验证后回滚）" || bad "N1 正常释放 = $R（期望 4000/1000/HELD）"
R=$(psql -t -A -c "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 9001 AND status = 'HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - 5000, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 5000; SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.status FROM stock s JOIN stock_hold h ON h.stock_id=s.id WHERE h.id=31; ROLLBACK;" | grep '/')
[ "$R" = "5000/0/5000/RELEASED" ] && ok "release_scrap_hold REVOKED：释放回可用 → $R（回滚）" || bad "REVOKED = $R（期望 5000/0/5000/RELEASED）"
R=$(psql -t -A -c "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 9001 AND status = 'HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - 5000, on_hand_qty_milli = on_hand_qty_milli - 5000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 5000 AND on_hand_qty_milli >= 5000; SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.status FROM stock s JOIN stock_hold h ON h.stock_id=s.id WHERE h.id=31; ROLLBACK;" | grep '/')
[ "$R" = "0/0/0/RELEASED" ] && ok "release_scrap_hold POSTED：释放与扣减同事务 → $R（回滚）" || bad "POSTED = $R（期望 0/0/0/RELEASED）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 9002 AND status = 'HELD'")
[ "$R" = "UPDATE 0" ] && ok "release_scrap_hold 报损单不匹配（9002）rowcount=0（→ 40930）" || bad "错单释放：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 30 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 601 AND status = 'HELD'")
[ "$R" = "UPDATE 0" ] && ok "release_scrap_hold 非 SCRAP_PENDING 冻结 rowcount=0（→ 40930）" || bad "非报损冻结被释放：$R"
expect_block "R1 已释放冻结改回 HELD（released 清零）" "BEGIN; UPDATE stock_hold SET released_qty_milli = 0, status = 'HELD' WHERE id = 30; COMMIT;" "hold_immutable"
expect_block "R1 释放量减少（5000→1000）" "BEGIN; UPDATE stock_hold SET released_qty_milli = 1000, status = 'HELD' WHERE id = 30; COMMIT;" "hold_immutable"
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE stock_hold SET released_qty_milli = 0, status = 'HELD' WHERE id = 30;")
case "$OUT" in *"hold_immutable"*) ok "R1 wms_app 改回 HELD 被触发器拦（列级授权放行了这两列，靠触发器）";; *) bad "wms_app 改回 HELD 未被拦：$OUT";; esac
expect_block "R2 超级用户 DELETE 冻结明细" "BEGIN; DELETE FROM stock_hold WHERE id = 31; COMMIT;" "hold_immutable"
OUT=$(psql -q -c "SET ROLE wms_app; DELETE FROM stock_hold WHERE id = 31;")
case "$OUT" in *"permission denied for table stock_hold"*) ok "R2 wms_app DELETE stock_hold → permission denied";; *) bad "wms_app DELETE 未被拒：$OUT";; esac
OUT=$(psql -q -c "TRUNCATE stock_hold CASCADE;")   # 有 fk_hr_hold 后不带 CASCADE 会先报外键；CASCADE 时两表触发器都拦
case "$OUT" in *"hold_immutable"*) ok "R2 超级用户 TRUNCATE stock_hold 被语句级触发器拦";; *) bad "TRUNCATE 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT hold_type||'/'||status||'/'||released_qty_milli FROM stock_hold WHERE id=31")
[ "$R" = "SCRAP_PENDING/HELD/0" ] && ok "R2 绕过尝试后 id=31 仍为 $R" || bad "id=31 被改成 $R"
expect_block "报损冻结不能再用 MANUAL/SCRAP（只能 SCRAP_PENDING）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (33,40,'MANUAL','SCRAP','SCRAP',601,'H33',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_reason"
expect_block "SCRAP_PENDING 必须挂报损单且为系统冻结" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (34,40,'SCRAP_PENDING','SCRAP','RETURN_RECORD',601,'H34',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_scrap"
OUT=$(psql -q -c "TRUNCATE stock_movement_key CASCADE;")
case "$OUT" in *"append_only_violation"*) ok "C5 超级用户 TRUNCATE 去重表被语句级触发器拦下";; *) bad "TRUNCATE 未被拦：$OUT";; esac
OUT=$(psql -q -c "TRUNCATE stock_movement;")
case "$OUT" in *"append_only_violation"*) ok "C5 超级用户 TRUNCATE 流水表被拦";; *) bad "TRUNCATE 流水未被拦：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE stock_ledger_line SET src_kind='DOC' WHERE biz_no='PK2';")
case "$OUT" in *"permission denied"*) ok "C3 wms_app 无 stock_ledger_line.src_kind 列的 UPDATE 权限";; *) bad "wms_app 改 src_kind 未被拒：$OUT";; esac
XP1=$(psql -t -A -c "SELECT count(*) FROM stock_movement WHERE biz_no='XP1'")
XPP=$(psql -t -A -c "SELECT count(DISTINCT tableoid) FROM stock_movement WHERE biz_no='XP1' OR id=4")
[ "$XP1" = "1" ] && ok "跨分区去重：被拦那笔随事务回滚（XP1 只有 1 条；样本流水分布在 $XPP 个分区）" || bad "XP1 流水 $XP1 条"
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE stock_movement SET remark='x' WHERE id=4;")
case "$OUT" in *"permission denied for table stock_movement"*) ok "只追加：应用角色 wms_app 无 UPDATE 权限";; *) bad "wms_app UPDATE 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; DELETE FROM stock_movement_key WHERE movement_id=4;")
case "$OUT" in *"permission denied for table stock_movement_key"*) ok "只追加：应用角色 wms_app 无 DELETE 权限";; *) bad "wms_app DELETE 未被拒：$OUT";; esac

echo "=== 2f. A3 RETURN_QC 系统冻结、release_qc_hold、QUALITY/RETURN_QC → SCRAP_PENDING ==="
expect_allow "A3 准备：stock 41 质检冻结 9000（RETURN_QC 6000 + QUALITY 3000）" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (41,1,2,2,3,'KG',9000,9000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (50,41,'RETURN_QC','RETURN_QC','QC',7001,'RQC:7001',6000,0,'HELD',0); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (51,41,'QUALITY','QC_PENDING','INBOUND_QC',1,'H51',3000,0,'HELD',0); COMMIT;"
expect_block "A3 RETURN_QC 必须挂质检单且为系统冻结" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (54,41,'RETURN_QC','RETURN_QC','INBOUND_QC',7002,'H54',1000,0,'HELD',5); COMMIT;" "ck_hold_retqc"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "A3 手工解冻 RETURN_QC rowcount=0（→ 40933）" || bad "手工解冻了 RETURN_QC：$R"
expect_allow "A3 release_qc_hold 释放 1000（去重行 + 明细 + stock 同事务）" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (1,50,'QCR:7001:1',1000); UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 50 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 7001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 1000; COMMIT;"
expect_block "A3 release_qc_hold 重放同一 op_key（不重复解冻）" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (2,50,'QCR:7001:1',1000); UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 50 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 7001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 1000; COMMIT;" "uq_hr_op"
R=$(psql -t -A -c "SELECT h.released_qty_milli||'/'||s.quality_hold_qty_milli FROM stock_hold h JOIN stock s ON s.id=h.stock_id WHERE h.id=50")
[ "$R" = "1000/8000" ] && ok "A3 重放后 已释放/quality_hold = $R（只释放一次）" || bad "A3 重放后 = $R（期望 1000/8000）"
expect_allow "A3 convert_hold QUALITY → SCRAP_PENDING（跨列：同事务 quality_hold −q、hold_qty +q）" "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 51 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (52,41,'SCRAP_PENDING','SCRAP','SCRAP',9101,'CVT:51',3000,0,'HELD',0); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 3000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "5000/3000/1000" ] && ok "A3 QUALITY 转后 quality/hold/available = $R（冻结总量 8000 与可用量不变）" || bad "A3 QUALITY 转后 = $R（期望 5000/3000/1000）"
expect_allow "A3 convert_hold RETURN_QC 剩余 5000 → SCRAP_PENDING" "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND released_qty_milli = 1000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (53,41,'SCRAP_PENDING','SCRAP','SCRAP',9102,'CVT:50',5000,0,'HELD',0); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 5000, hold_qty_milli = hold_qty_milli + 5000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 5000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "0/8000/1000" ] && ok "A3 RETURN_QC 转后 quality/hold/available = $R（冻结总量 8000 与可用量不变）" || bad "A3 RETURN_QC 转后 = $R（期望 0/8000/1000）"
expect_block "A3 stock_hold_release 只追加（UPDATE）" "BEGIN; UPDATE stock_hold_release SET qty_milli = 2000 WHERE op_key = 'QCR:7001:1'; COMMIT;" "hold_immutable"
echo "=== 2f2. 小赵五轮 Q1/S5/S6 stock_hold_release；Q2 去重记录与 outbox 清理 ==="
expect_block "S6 释放记录挂不存在的冻结（外键）" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (4,999999,'QCR:x:1',1); COMMIT;" "fk_hr_hold"
OUT=$(psql -q -c "TRUNCATE stock_hold_release;")
case "$OUT" in *"hold_immutable"*) ok "S5 超级用户 TRUNCATE stock_hold_release 被语句级触发器拦";; *) bad "TRUNCATE stock_hold_release 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT count(*) FROM (SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)) t")
[ "$R" = "0" ] && ok "S6 I3e 对账：RETURN_QC 已释放 = Σ释放记录 + 转报损量（无差异行）" || bad "I3e 差异行 $R"
R=$(psql -t -A -c "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (55,41,'RETURN_QC','RETURN_QC','QC',7003,'RQC:7003',2000,0,'HELD',0); UPDATE stock_hold SET released_qty_milli = 500, version = version + 1 WHERE id = 55; SELECT 'ids=' || string_agg(id::text, ',') FROM (SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)) t; ROLLBACK;" | grep '^ids=')
[ "$R" = "ids=55" ] && ok "S6 I3e 反向：绕过释放记录直接 UPDATE 释放 → 对账查出 hold 55" || bad "I3e 未查出：$R"
expect_allow "Q2 准备：去重记录（未过期/已过期）+ outbox（PENDING / 8 天前 SENT / 刚 SENT）" "BEGIN; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','h','{}',200,now()+interval '1 day'),('dead','h','{}',200,now()-interval '1 hour'); INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8801,'t','k','{}','PENDING',NULL),(8802,'t','k','{}','SENT',now()-interval '8 days'),(8803,'t','k','{}','SENT',now()); COMMIT;"
OUT=$(psql -q -c "SET ROLE wms_app; DELETE FROM idempotency_record WHERE idem_key='dead';")
case "$OUT" in *"permission denied for table idempotency_record"*) ok "Q2 wms_app DELETE idempotency_record → permission denied";; *) bad "wms_app DELETE idem 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; DELETE FROM outbox_event WHERE id=8802;")
case "$OUT" in *"permission denied for table outbox_event"*) ok "Q2 wms_app DELETE outbox_event → permission denied";; *) bad "wms_app DELETE outbox 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; TRUNCATE outbox_event;")
case "$OUT" in *"permission denied"*) ok "Q2 wms_app TRUNCATE outbox_event → permission denied";; *) bad "wms_app TRUNCATE 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_cleaner; DELETE FROM idempotency_record WHERE idem_key='dead';")
case "$OUT" in *"permission denied for table idempotency_record"*) ok "Q2 wms_cleaner 直接 DELETE → permission denied（只能 EXECUTE 函数）";; *) bad "wms_cleaner 直接 DELETE 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; SELECT * FROM purge_expired();")
case "$OUT" in *"permission denied for function purge_expired"*) ok "Q2 wms_app 调 purge_expired() → permission denied";; *) bad "wms_app 调函数未被拒：$OUT";; esac
expect_block "Q2 超级用户删未过期去重记录（触发器兜底）" "BEGIN; DELETE FROM idempotency_record WHERE idem_key='live'; COMMIT;" "purge_not_allowed: idempotency_record"
expect_block "Q2 超级用户删 PENDING 事件" "BEGIN; DELETE FROM outbox_event WHERE id=8801; COMMIT;" "purge_not_allowed: outbox_event"
expect_block "Q2 超级用户删刚投递（未过保留期）事件" "BEGIN; DELETE FROM outbox_event WHERE id=8803; COMMIT;" "purge_not_allowed: outbox_event"
OUT=$(psql -q -c "TRUNCATE idempotency_record;")
case "$OUT" in *"purge_not_allowed"*) ok "Q2 超级用户 TRUNCATE idempotency_record 被拦";; *) bad "TRUNCATE idem 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT p.prosecdef::text || '/' || array_to_string(p.proconfig, ',') || '/' || r.rolsuper::text || '/' || r.rolname || '/' || has_function_privilege('public', p.oid, 'EXECUTE')::text FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.proname = 'purge_expired'")
[ "$R" = "true/search_path=pg_catalog, public/false/wms_purge_owner/false" ] && ok "Q2 purge_expired：SECURITY DEFINER、固定 search_path、属主非超级用户、PUBLIC 无 EXECUTE（$R）" || bad "purge_expired 属性：$R"
R=$(psql -t -A -c "SET ROLE wms_cleaner; SELECT idem_deleted || '/' || outbox_deleted FROM purge_expired();" | grep '/')
[ "$R" = "1/1" ] && ok "Q2 wms_cleaner 调 purge_expired() 删掉 1 条过期去重 + 1 条过保留期 SENT" || bad "purge_expired 结果：$R"
R=$(psql -t -A -c "SELECT (SELECT string_agg(idem_key, ',') FROM idempotency_record) || '|' || (SELECT string_agg(id::text, ',' ORDER BY id) FROM outbox_event)")
[ "$R" = "live|8801,8803" ] && ok "Q2 清理后剩余 $R（未过期、PENDING、未过保留期的都在）" || bad "Q2 清理后：$R"
echo "=== 2c. docs/02 40906：库位锁定写进扣减原语的 WHERE ==="
psql -q -c "UPDATE location SET status='LOCKED' WHERE id=3;" >/dev/null
DEDUCT="UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 AND EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED');"
R=$(psql -t -A -c "$DEDUCT")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：扣减 rowcount=0" || bad "锁定库位仍扣减：$R"
psql -q -c "UPDATE location SET status='AVAILABLE' WHERE id=3;" >/dev/null
R=$(psql -t -A -c "$DEDUCT")
[ "$R" = "UPDATE 1" ] && ok "库位解锁后 rowcount=1" || bad "解锁后：$R"
psql -q -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;" >/dev/null
echo "=== 2c2. post_in：REVERSE_PICK 放行库位锁（盘点期间流水），其他来源仍拦 ==="
psql -q -c "UPDATE location SET status='LOCKED' WHERE id=3;" >/dev/null
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('REVERSE_PICK' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 1" ] && ok "库位 LOCKED：REVERSE_PICK 入账 rowcount=1" || bad "REVERSE_PICK 被锁拦：$R"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('RECEIVE' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：RECEIVE 入账 rowcount=0（→ 40906）" || bad "RECEIVE 未被锁拦：$R"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('MOVE' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：MOVE 目标腿 rowcount=0" || bad "MOVE 未被锁拦：$R"
psql -q -c "UPDATE location SET status='AVAILABLE' WHERE id=3; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;" >/dev/null

echo "=== 2e. docs/01 主数据：milli 换算、损耗 ppm、往来方、节点号、下发日志 ==="
expect_block "01 损耗容差超过 5%（ppm=50001）" \
  "UPDATE sku SET natural_loss_tolerance_ppm = 50001 WHERE id = 1;" "ck_sku_loss_ppm"
expect_block "01 出库禁发期大于保质期" \
  "UPDATE sku SET ship_min_shelf_life = 31 WHERE id = 1;" "ck_sku_shelf_life"
expect_block "01 单位换算为 0" \
  "INSERT INTO sku_unit (id,sku_id,uom,base_qty_milli) VALUES (901,1,'BOX',0);" "ck_unit_ratio"
expect_allow "01 单位换算 1 箱 = 12.5 KG（12500 milli）" \
  "INSERT INTO sku_unit (id,sku_id,uom,base_qty_milli) VALUES (902,1,'BOX',12500);"
expect_block "01 库位补货水位 max < min" \
  "UPDATE location SET min_level_milli = 5000, max_level_milli = 1000 WHERE id = 1;" "ck_loc_level"
expect_block "01 门店没挂客户" \
  "INSERT INTO customer (id,code,name,customer_type) VALUES (901,'ST-001','静安店','STORE');" "ck_customer_type"
seed "INSERT INTO customer (id,code,name,customer_type) VALUES (1,'C-001','华东连锁','CUSTOMER');"
expect_allow "01 门店挂在客户下" \
  "INSERT INTO customer (id,code,name,customer_type,parent_id) VALUES (2,'ST-002','徐汇店','STORE',1);"
expect_block "01 客户编码重复" \
  "INSERT INTO customer (id,code,name,customer_type) VALUES (903,'C-001','重复','CUSTOMER');" "uq_customer_code"
expect_block "01 节点号超出 0–1023" \
  "INSERT INTO node_registry (node_id,warehouse_id,form,role,host_label) VALUES (1024,1,'B','EDGE','edge-x');" "ck_node_id_range"
expect_block "01 边缘节点不挂仓" \
  "INSERT INTO node_registry (node_id,form,role,host_label) VALUES (5,'B','EDGE','edge-x');" "ck_node_form"
seed "INSERT INTO node_registry (node_id,warehouse_id,form,role,host_label) VALUES (7,1,'B','EDGE','qp-edge-01');"
seed "UPDATE node_registry SET status='RETIRED', retired_at=now(), retire_reason='HW_REPLACE' WHERE node_id = 7;"
expect_block "01 退役节点号重新分配（同号 INSERT）" \
  "INSERT INTO node_registry (node_id,warehouse_id,form,role,host_label) VALUES (7,1,'B','EDGE','qp-edge-02');" "node_registry_pkey"
expect_block "01 退役节点号复活" \
  "UPDATE node_registry SET status='ACTIVE', retired_at=NULL WHERE node_id = 7;" "node_id_never_reused"
expect_block "01 删除节点登记" \
  "DELETE FROM node_registry WHERE node_id = 7;" "node_id_never_reused"
seed "INSERT INTO md_change_log (seq,entity_type,entity_id,md_version,op,payload_json,operator_id) VALUES (1,'SKU',1,2,'UPSERT','{}',100);"
expect_block "01 同一实体同一版本两条下发日志" \
  "INSERT INTO md_change_log (seq,entity_type,entity_id,md_version,op,payload_json,operator_id) VALUES (2,'SKU',1,2,'UPSERT','{\"x\":1}',100);" "uq_mdlog_ver"
expect_block "01 下发日志只追加（UPDATE）" \
  "UPDATE md_change_log SET payload_json='{}' WHERE seq = 1;" "append_only_violation: md_change_log"
seed "INSERT INTO md_pending_disable (id,entity_type,entity_id,warehouse_id,requested_version,requested_by) VALUES (1,'SKU',1,1,3,100);"
expect_block "01 同一实体同仓两条等待中的延迟停用" \
  "INSERT INTO md_pending_disable (id,entity_type,entity_id,warehouse_id,requested_version,requested_by) VALUES (2,'SKU',1,1,4,100);" "uq_mdpd_waiting"

echo "=== 2e2. docs/01 小钱副审 B1–B4 / I1–I4 / 建议 ==="
expect_allow "01 I4 损耗容差 = 5%（50000）放行" "UPDATE sku SET natural_loss_tolerance_ppm = 50000 WHERE id = 1;"
expect_block "01 I3 基本单位行换算 ≠ 1000" \
  "INSERT INTO sku_unit (id,sku_id,uom,base_qty_milli) VALUES (903,1,'KG',999);" "base_unit_ratio_must_be_1000"
expect_allow "01 I3 基本单位行换算 = 1000" "INSERT INTO sku_unit (id,sku_id,uom,base_qty_milli) VALUES (904,1,'KG',1000);"
expect_allow "01 I1 库位 md_status = PENDING_DISABLE" "UPDATE location SET md_status='PENDING_DISABLE' WHERE id = 3;"
expect_block "01 I1 作业状态不再承载 DISABLED" "UPDATE location SET status='DISABLED' WHERE id = 3;" "ck_loc_status"
seed "UPDATE sku SET md_version = 5 WHERE id = 1;"
expect_block "01 I2 md_version 回退" "UPDATE sku SET md_version = 2 WHERE id = 1;" "md_version_rewind"
seed "INSERT INTO md_sync_state (node_id,applied_seq) VALUES (7,100);"
expect_block "01 I2 应用水位回退" "UPDATE md_sync_state SET applied_seq = 5 WHERE node_id = 7;" "applied_seq_rewind"
P=$(psql -t -A -c "SELECT string_agg(action_code||'='||allowed_when_pending, ',' ORDER BY action_code) FROM md_disable_action_policy WHERE action_code IN ('SCRAP_CREATE','MOVE_OUT','COUNT_ADJUST','RETURN_TO_SUPPLIER','CUSTOMER_RETURN_IN','RELEASE_HOLD','CONVERT_HOLD','INBOUND_CREATE','ALLOCATE','PUTAWAY_TO_LOCATION','OUTBOUND_CREATE','MOVE_IN')")
[ "$P" = "ALLOCATE=false,CONVERT_HOLD=true,COUNT_ADJUST=true,CUSTOMER_RETURN_IN=true,INBOUND_CREATE=false,MOVE_IN=false,MOVE_OUT=true,OUTBOUND_CREATE=false,PUTAWAY_TO_LOCATION=false,RELEASE_HOLD=true,RETURN_TO_SUPPLIER=true,SCRAP_CREATE=true" ] \
  && ok "01 B1 停用白名单：报损/移出/盘点调整/退供/门店退货/release_*_hold/convert_hold 放行；入库/分配/上架/出库/移入拦截" || bad "01 B1 白名单不符：$P"
expect_block "01 B1 把增加引用的动作改成放行" \
  "UPDATE md_disable_action_policy SET allowed_when_pending = true WHERE action_code = 'INBOUND_CREATE';" "ck_mdap_add_never"
expect_block "01 B1 新增一个放行的 ADD 动作" \
  "INSERT INTO md_disable_action_policy VALUES ('NEW_PO','ADD',true,'03');" "ck_mdap_add_never"
expect_block "01 B2 ACTIVE 节点改仓" \
  "INSERT INTO node_registry (node_id,warehouse_id,form,role,host_label) VALUES (8,1,'B','EDGE','e8'); UPDATE node_registry SET warehouse_id = 9 WHERE node_id = 8;" "node_id_never_reused"
expect_block "01 B2 已退役节点改 retire_reason" \
  "UPDATE node_registry SET retire_reason = 'x' WHERE node_id = 7;" "node_id_never_reused"
expect_block "01 B2 TRUNCATE node_registry" "TRUNCATE node_registry;" "node_id_never_reused"
expect_block "01 B3 TRUNCATE md_change_log" "TRUNCATE md_change_log;" "append_only_violation: md_change_log"
expect_block "01 B3 DELETE md_change_log" "DELETE FROM md_change_log WHERE seq = 1;" "append_only_violation: md_change_log"
expect_block "01 门店挂在不存在的客户下" \
  "INSERT INTO customer (id,code,name,customer_type,parent_id) VALUES (904,'ST-904','x','STORE',777);" "customer_parent_invalid"
expect_block "01 门店挂在门店下" \
  "INSERT INTO customer (id,code,name,customer_type,parent_id) VALUES (905,'ST-905','x','STORE',2);" "customer_parent_invalid"
expect_block "01 entity_type 不在码表" \
  "INSERT INTO md_change_log (seq,entity_type,entity_id,md_version,op,payload_json,operator_id) VALUES (9,'BANANA',1,1,'UPSERT','{}',1);" "ck_mdlog_entity"
expect_block "01 待停用 entity_type 不在码表" \
  "INSERT INTO md_pending_disable (id,entity_type,entity_id,warehouse_id,requested_version,requested_by) VALUES (9,'WHATEVER',1,1,1,1);" "ck_mdpd_entity"
OUT=$(psql -q -c "SET ROLE wms_app; DELETE FROM supplier;" 2>&1)
case "$OUT" in *"permission denied for table supplier"*) ok "01 B4 wms_app 无 supplier DELETE";; *) bad "01 B4 wms_app DELETE supplier 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE md_change_log SET op='DISABLE';" 2>&1)
case "$OUT" in *"permission denied for table md_change_log"*) ok "01 B4 wms_app 无 md_change_log UPDATE";; *) bad "01 B4 wms_app UPDATE md_change_log 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE node_registry SET warehouse_id = 2 WHERE node_id = 8;" 2>&1)
case "$OUT" in *"permission denied for table node_registry"*) ok "01 B4 wms_app 只能改 node_registry 退役列";; *) bad "01 B4 wms_app 改 node_registry.warehouse_id 未被拒：$OUT";; esac
OUT=$(psql -q -c "SET ROLE wms_app; UPDATE md_disable_action_policy SET doc_ref='x';" 2>&1)
case "$OUT" in *"permission denied"*) ok "01 B4 wms_app 白名单只读";; *) bad "01 B4 wms_app 改白名单未被拒：$OUT";; esac

echo "=== 2d. Q7：PG 写入 bigint 的取整行为（QA 在 PG16.14 实测，已关闭）==="
# 临时表只活在一个会话里：建表、插入、查询必须在同一次 psql 调用（小赵 C1）
Q7=$(psql -q -t -A -c "CREATE TEMP TABLE q7 (v BIGINT); INSERT INTO q7 VALUES (3.5), (2.5), (2.5::float8); SELECT string_agg(v::text, ',' ORDER BY ctid) FROM q7;")
[ "$Q7" = "4,3,2" ] && ok "numeric 3.5→4、2.5→3（四舍五入），float8 2.5→2（银行家舍入）→ 应用层只绑定整数" \
                  || bad "Q7 取整结果 = $Q7（期望 4,3,2）"

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
RP=$(psql -t -A -q -c "BEGIN;
INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (20,12,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',20,'RRH:20',20000,0,'HELD',0);
UPDATE stock SET hold_qty_milli = hold_qty_milli + 20000 WHERE id = 12 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 20000;
SELECT (SELECT available_qty_milli FROM v_stock_available WHERE stock_id=12) || ',' || (SELECT count(*) FROM v_stock_available WHERE sku_id=1 AND warehouse_id=1 AND available_qty_milli > 0 AND expiry_date >= '2026-10-15'::date + 10) || ',' || (SELECT count(*) FROM v_stock_available WHERE stock_id=12 AND available_qty_milli > 0);
ROLLBACK;" | tr -d '\r' | grep -E '^[0-9]+,[0-9]+,[0-9]+$')
[ "$RP" = "0,3,0" ] && ok "RETURN_PENDING 冻满 stock 12：available→0，FEFO 候选 4→3 行且不含 12" || bad "RETURN_PENDING/FEFO = $RP（期望 0,3,0）"
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
