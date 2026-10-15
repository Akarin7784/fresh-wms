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
export PGTZ=UTC   # 九轮 P1：时间列一律按 UTC 存，写入端会话固定 UTC（清理/守卫本身不依赖会话时区）
cd "$(dirname "$0")/.."

SCHEMA_DIR=sql/schema
SCHEMA_PARTS=(
  00_preamble.sql
  01_master.sql
  02_inventory.sql
  03_inbound.sql
  04_outbound.sql
  05_picking.sql
  06_pack_ship.sql
  07_replenishment.sql
  08_count.sql
  10_returns.sql
  09_scrap.sql
  11_integration.sql
  12_auth.sql
  12b_auth_audit.sql
  16_delivery.sql
  17_processing.sql
  18_live.sql
  90_available_view.sql
  99_grants.sql
)
# 期望值：main 8ed5f0c 为 38 表 / 99 索引 / 1 视图。docs/02 新增 stock_hold、stock_recon_alert、
# stock_movement_key、stock_ledger_line → 42 表 / 114 索引（含 PK、UNIQUE 自动索引和分区父表上的分区索引；
# 分区子表及其继承来的索引不计）/ 1 视图。二轮 C2 加 uq_mvk_mv（外键被引用键）→ 115；A3 加 stock_hold_release（PK、uq_hr_op、ix_hr_hold）→ 43 表 / 118。ix_hold_from（from_hold_id 部分索引，非唯一）→ 119。ix_mv_hold（hold_id 部分索引）→ 120。改 DDL 必须同步改这里。
# 必须用新建的空库跑（DROP SCHEMA public 重建会丢 wms_app 的 USAGE；schema 里已 GRANT USAGE 兜底，小赵 C6）。
# docs/12 的 DDL 在 12b_auth_audit.sql：在 43 表 / 119 索引上增加 user_device_binding、offline_token、approval_request（3 主键 + uq_offline_jti + uq_apr_code + uq_audit_node_seq + 7 个显式索引）→ 46 表 / 132 索引；合入 1d907031（#2 第四轮 ix_mv_hold，43/120）后 → 46 表 / 133 索引（PG16.15 实测）。以 PG 实测为准。
# 退供（pr-supplier-return，基于 30041054）：+supplier_return（PK、uq_srtn_code、ix_srtn_due）+ uq_srtn_scrap、uq_scr_srtn → 73 表 / 218 索引。
# docs/03：+5 表（测温/收货/更正单/上架/质量反馈），索引 +25
# docs/07（磐石）：+5 表（replenish_task、replenish_task_line、replenish_demand、move_order、move_order_line）
#   +21 索引（replenish_task PK/uq_rt_code/ix_rt_claim/ix_rt_mine、replenish_task_line PK/uq_rtl/ix_rtl_task/ix_rtl_stock、
#    replenish_demand PK/uq_rpd_code/uq_rpd_open/ix_rpd_open/ix_rpd_task/ix_rpd_loc、
#    move_order PK/uq_mo_code/ix_mo_wh、move_order_line PK/uq_mol/ix_mol_order/ix_mol_stock）
#   +1 视图（v_location_sku_candidate）→ 84 表 / 276 索引 / 3 视图（PG16 实测）
EXPECT_TABLES=98
EXPECT_INDEXES=323
# 第 12 篇：+device_reconnect（PK、uq_drc_id_binding、ix_drc_binding、ix_drc_jti）+ audit_log.uq_audit_rbac_once → 79 表 / 248 索引（PG16 实测）
# docs/05（长流）：+ix_pt_handover（pick_task 交接任务来源的部分索引）→ 249 索引
# docs/08（长流）：+ix_cnt_wh、ix_adj_wh、ix_adj_src、uq_adjl、ix_cnt_line_count、ix_cnt_line_loc → 255 索引（249 + 6）
EXPECT_VIEWS=3

CTR=wms-pg-verify
PORT=55432
pass=0; fail=0

ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }

for _part in "${SCHEMA_PARTS[@]}"; do
  if [ ! -f "$SCHEMA_DIR/$_part" ]; then
    echo "  ✗ 找不到 $SCHEMA_DIR/$_part"; exit 1
  fi
done
SCHEMA=$(mktemp)
trap 'rm -f "$SCHEMA"' EXIT
cat "${SCHEMA_PARTS[@]/#/$SCHEMA_DIR/}" > "$SCHEMA"

if [ -n "${PGHOST:-}" ]; then
  MODE=env
  command -v psql >/dev/null 2>&1 || { echo "  ✗ 设置了 PGHOST 但本机没有 psql 客户端"; exit 1; }
  export PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"
  # stderr 保持独立。需要按错误文本断言的调用点自己合并（psql_capture）。
  # -v ON_ERROR_STOP=1 放在包装里，等价于每次会话 \set ON_ERROR_STOP on。
  psql() { command psql -X -v ON_ERROR_STOP=1 "$@"; }
  cleanup() { :; }
  echo "=== 0. 直连 PG：$PGUSER@$PGHOST:$PGPORT/$PGDATABASE ==="
  conn_err=$(mktemp)
  ready=0
  for _ in $(seq 1 30); do
    if psql -t -A -c "SELECT 1" >/dev/null 2>"$conn_err"; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    echo "  ✗ 连不上 $PGUSER@$PGHOST:$PGPORT/$PGDATABASE（psql 退出码非 0）"
    cat "$conn_err"
    rm -f "$conn_err"
    exit 1
  fi
  rm -f "$conn_err"
else
  MODE=docker
  command -v docker >/dev/null 2>&1 || { echo "  ✗ 未设置 PGHOST，且本机没有 docker，无法验证 PG 侧"; exit 1; }
  # 与直连分支一样：每次 psql 都开 ON_ERROR_STOP，就绪检查看退出码，不看文本。
  psql() { docker exec -i "$CTR" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
  cleanup() { docker rm -f "$CTR" >/dev/null 2>&1; }
  echo "=== 0. 启动一次性 PG16 容器（回退模式）==="
  docker rm -f "$CTR" >/dev/null 2>&1
  docker run -d --name "$CTR" -e POSTGRES_PASSWORD=verify -p $PORT:5432 postgres:16-alpine >/dev/null
  ready=0
  for _ in $(seq 1 60); do
    if docker exec "$CTR" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    echo "  ✗ PG16 容器未就绪"
    cleanup
    exit 1
  fi
  if ! psql -t -A -c "SELECT 1" >/dev/null; then
    echo "  ✗ docker 分支 psql SELECT 1 退出码非 0（ON_ERROR_STOP 已开）"
    cleanup
    exit 1
  fi
fi

echo "=== 1. 建表（ON_ERROR_STOP，任何语法/方言错误直接失败）==="
SCHEMA_ERR=$(mktemp)
SCHEMA_OUT=$(psql -q < "$SCHEMA" 2>"$SCHEMA_ERR")
SCHEMA_RC=$?
if [ "$SCHEMA_RC" != 0 ] || [ -s "$SCHEMA_ERR" ] || [ -n "$SCHEMA_OUT" ]; then
  bad "schema 执行报错（退出 $SCHEMA_RC）"
  echo "--- stdout ---"; printf '%s\n' "$SCHEMA_OUT" | head -20
  echo "--- stderr ---"; head -20 "$SCHEMA_ERR"
  rm -f "$SCHEMA_ERR"; cleanup; exit 1
fi
rm -f "$SCHEMA_ERR"
ok "sql/schema/*.sql 在 PG16 按序全量执行通过（退出码 0，stdout/stderr 都空）"

# 把 stdout 和 stderr 拼在一起，并带回 psql 的退出码。
# 调用方要自己接 $?：这里不能写 `|| true`，否则连不上库（退出码非 0）会被当成成功。
psql_capture() {
  local errf out rc
  errf=$(mktemp)
  out=$(psql -q -c "$1" 2>"$errf")
  rc=$?
  printf '%s\n%s' "$out" "$(cat "$errf")"
  rm -f "$errf"
  return "$rc"
}

T=$(psql -t -A -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relispartition")
I=$(psql -t -A -c "SELECT count(*) FROM pg_indexes i JOIN pg_class c ON c.relname=i.tablename JOIN pg_namespace n ON n.oid=c.relnamespace AND n.nspname=i.schemaname WHERE i.schemaname='public' AND NOT c.relispartition")
V=$(psql -t -A -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public'")
echo "  → 表 $T 张 / 索引 $I 个 / 视图 $V 个"
[ "$T" = "$EXPECT_TABLES" ]  && ok "表数 = $T"   || bad "表数 = $T，期望 $EXPECT_TABLES"
[ "$I" = "$EXPECT_INDEXES" ] && ok "索引数 = $I" || bad "索引数 = $I，期望 $EXPECT_INDEXES"
[ "$V" = "$EXPECT_VIEWS" ]   && ok "视图数 = $V" || bad "视图数 = $V，期望 $EXPECT_VIEWS"

# 小赵 S4：按期望权限矩阵逐表核对 wms_app（表、分区父表、视图、物化视图；序列查 USAGE），多给、少给、漏表都失败
EXPECT_PRIVS="adjust_line:SELECT,INSERT,UPDATE adjust_order:SELECT,INSERT,UPDATE api_credential:SELECT,INSERT,UPDATE approval_request:SELECT,INSERT audit_log:SELECT,INSERT count_line:SELECT,INSERT,UPDATE count_order:SELECT,INSERT,UPDATE customer:SELECT,INSERT,UPDATE delivery_order:SELECT,INSERT,UPDATE delivery_return:SELECT,INSERT,UPDATE delivery_return_line:SELECT,INSERT,UPDATE delivery_stop:SELECT,INSERT,UPDATE device:SELECT,INSERT,UPDATE device_reconnect:SELECT,INSERT driver:SELECT,INSERT,UPDATE exception_case:SELECT,INSERT,UPDATE exception_code:SELECT,INSERT,UPDATE idempotency_record:SELECT,INSERT,UPDATE inbound_correction:SELECT,INSERT inbound_line:SELECT,INSERT inbound_message:SELECT,INSERT,UPDATE inbound_order:SELECT,INSERT,UPDATE inbound_putaway:SELECT,INSERT inbound_quality_feedback:SELECT,INSERT,UPDATE inbound_receipt:SELECT,INSERT inbound_temp_check:SELECT,INSERT live_count_ledger:SELECT,INSERT live_death:SELECT,INSERT live_inspection:SELECT,INSERT live_shrink_settlement:SELECT,INSERT live_stock_count:SELECT,INSERT,UPDATE live_tank:SELECT,INSERT,UPDATE live_tank_hold:SELECT,INSERT live_weigh:SELECT,INSERT location:SELECT,INSERT,UPDATE lot:SELECT,INSERT,UPDATE move_order:SELECT,INSERT,UPDATE move_order_line:SELECT,INSERT,UPDATE numbering_segment:SELECT,INSERT,UPDATE offline_paper_record:SELECT,INSERT,UPDATE offline_token:SELECT,INSERT outbound_line:SELECT,INSERT,UPDATE outbound_order:SELECT,INSERT,UPDATE outbox_event:SELECT,INSERT,UPDATE pack_box:SELECT,INSERT,UPDATE pack_box_line:SELECT,INSERT,UPDATE pick_task:SELECT,INSERT,UPDATE pick_task_line:SELECT,INSERT,UPDATE pod_correction:SELECT,INSERT,UPDATE pod_line:SELECT,INSERT,UPDATE pod_op:SELECT,INSERT pod_tolerance_config:SELECT,INSERT,UPDATE process_bom:SELECT,INSERT,UPDATE process_bom_line:SELECT,INSERT,UPDATE process_issue:SELECT,INSERT,UPDATE process_lot_trace:SELECT,INSERT process_order:SELECT,INSERT,UPDATE process_output:SELECT,INSERT,UPDATE process_report:SELECT,INSERT process_reversal:SELECT,INSERT replenish_demand:SELECT,INSERT,UPDATE replenish_task:SELECT,INSERT,UPDATE replenish_task_line:SELECT,INSERT,UPDATE return_blind_receipt:SELECT,INSERT return_reservation:SELECT,INSERT,UPDATE return_reservation_line:SELECT,INSERT,UPDATE scrap_line:SELECT,INSERT,UPDATE scrap_order:SELECT,INSERT,UPDATE shipment:SELECT,INSERT,UPDATE shipment_order:SELECT,INSERT,UPDATE sku:SELECT,INSERT,UPDATE sku_barcode:SELECT,INSERT,UPDATE sku_live_param:SELECT,INSERT,UPDATE sku_unit:SELECT,INSERT,UPDATE stock:SELECT,INSERT,UPDATE stock_hold:SELECT,INSERT stock_hold_release:SELECT,INSERT stock_ledger_line:SELECT,INSERT stock_movement:SELECT,INSERT stock_movement_key:SELECT,INSERT stock_recon_alert:SELECT,INSERT,UPDATE stock_reservation:SELECT,INSERT,UPDATE stock_snapshot_daily:SELECT,INSERT supplier:SELECT,INSERT,UPDATE supplier_return:SELECT,INSERT sys_permission:SELECT,INSERT,UPDATE sys_role:SELECT,INSERT,UPDATE sys_role_perm:SELECT sys_user:SELECT,INSERT,UPDATE sys_user_role:SELECT sys_user_warehouse:SELECT upstream_push_log:SELECT,INSERT user_device_binding:SELECT,INSERT v_live_death_in_transit:SELECT v_location_sku_candidate:SELECT v_stock_available:SELECT vehicle:SELECT,INSERT,UPDATE warehouse:SELECT,INSERT,UPDATE wave:SELECT,INSERT,UPDATE waybill:SELECT,INSERT,UPDATE zone:SELECT,INSERT,UPDATE"
ACT=$(psql -t -A -c "SELECT string_agg(x, ' ' ORDER BY x) FROM (SELECT c.relname || ':' || COALESCE(NULLIF(concat_ws(',', CASE WHEN c.relkind='S' THEN (CASE WHEN has_sequence_privilege('wms_app', c.oid, 'USAGE') THEN 'USAGE' END) ELSE (CASE WHEN has_table_privilege('wms_app', c.oid, 'SELECT') THEN 'SELECT' END) END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'INSERT') THEN 'INSERT' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'UPDATE') THEN 'UPDATE' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'DELETE') THEN 'DELETE' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'TRUNCATE') THEN 'TRUNCATE' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'REFERENCES') THEN 'REFERENCES' END, CASE WHEN c.relkind<>'S' AND has_table_privilege('wms_app', c.oid, 'TRIGGER') THEN 'TRIGGER' END), ''), 'NONE') AS x FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S') AND NOT c.relispartition) t")
if [ "$ACT" = "$EXPECT_PRIVS" ]; then ok "S4 wms_app 权限矩阵与期望逐表一致（$(echo "$ACT" | wc -w) 个对象，含 TRIGGER/REFERENCES；列级 UPDATE 另测）"
else bad "S4 wms_app 权限矩阵不符：$(diff <(echo "$EXPECT_PRIVS" | tr ' ' '\n') <(echo "$ACT" | tr ' ' '\n') | grep '^[<>]' | tr '\n' ' ')"; fi
echo "=== 2. 库层不变量断言（§4.1 I1–I5 + §2.2 SoD + §4.6 幂等）==="
seed() { psql -q -c "$1" >/dev/null || { echo "  ✗ seed 失败，立即退出：$1"; exit 2; }; }   # 种子任何一步失败都立即非零退出；错误留在 stderr
assert_n() {  # $1 描述  $2 SQL  $3 期望行数。计数语句本身失败也立即退出，不当成 0 行。
  local n
  n=$(psql -t -A -q -c "$2") || { echo "  ✗ 计数失败：$1"; exit 2; }
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  [ "$n" = "$3" ] && ok "$1 = $n" || bad "$1 = $n，期望 $3"
}
seed "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WHSH01','上海青浦仓','20:00',-1);"
# 跨篇 FK 收口（Chief 2026-10-16）：03/10 supplier_id 与 04 customer_id 的既有种子用 501 / 1，**父行必须最先建**
seed "INSERT INTO supplier (id,code,name) VALUES (501,'SUP501','跨篇 FK 收口父行');"
seed "INSERT INTO customer (id,code,name) VALUES (1,'STORE0001','跨篇 FK 收口父行');"
# 第 12 篇 FK 底数：102–199、201–299 号测试用户（审批人 / 申请人 / 映射引用）
seed "INSERT INTO sys_user (id,username,password_hash) SELECT i, 'seed' || i, 'x' FROM generate_series(102,299) i WHERE i <> 200;"
seed "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK',20,80),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE',20,80);"
seed "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010');"
seed "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10,14);"
seed "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (2,'SKU-PEAR','砀山酥梨','KG','CHILLED',30,10,14);"   # 第十三轮：补外键父行
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16);"
seed "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (11,1,1,1,2,'KG',50000,0),(12,1,2,1,1,'KG',30000,10000),(13,1,3,1,3,'KG',200000,0),(14,1,3,1,1,'KG',80000,0);"
assert_n "主数据种子 warehouse" "SELECT count(*) FROM warehouse" 1
assert_n "主数据种子 zone" "SELECT count(*) FROM zone" 2
assert_n "主数据种子 location" "SELECT count(*) FROM location" 3
assert_n "主数据种子 sku" "SELECT count(*) FROM sku" 2
assert_n "主数据种子 lot" "SELECT count(*) FROM lot" 3
assert_n "主数据种子 stock" "SELECT count(*) FROM stock" 4

expect_block() {  # $1 描述  $2 SQL  $3 期望命中的约束名（或错误片段）
  # 注意：不要用 `psql | grep -q`。grep -q 命中即退出会触发 SIGPIPE，
  # 在 set -o pipefail 下会把"确实拦截了"误判成"未拦截"。先捕获再匹配。
  # 只认"指定约束"拦下：被别的约束/语法错误拦下 = 这条断言没测到它声称测的东西。
  # 错误在 stderr，必须用 psql_capture，不能只看 stdout。
  local out; out=$(psql_capture "$2")
  # 约束名按 PG 报错里的 "name" 带引号精确匹配（避免 ck_res 误命中 ck_res_int）；含空格的 $3 视为错误片段子串匹配
  local pat="\"$3\""; case "$3" in *" "*) pat="$3";; esac
  case "$out" in
    *ERROR*"$pat"*|*"ERROR:  $3"*) ok "$1 → 已拦截（$3）";;   # 第二种：触发器 RAISE 的消息不带引号
    *ERROR*) bad "$1 → 被拦了但约束不对，期望 $3：$(echo "$out" | head -1)";;
    *) bad "$1 → 未拦截（设计有洞）";;
  esac
}
expect_allow() {  # $1 描述  $2 SQL —— 参数顺序与 expect_block 保持一致
  # 失败条件有两条，缺一不可：
  #   1. psql 退出码非 0（ON_ERROR_STOP 下语句失败，以及连不上库，都走这里）
  #   2. 输出里出现 error:，不区分大小写。连不上时是小写 "psql: error:"，
  #      语句失败时是大写 "ERROR:"；只匹配大写会把连不上当成通过。
  local out rc low
  out=$(psql_capture "$2")
  rc=$?
  low=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
  if [ "$rc" != 0 ] || [ "${low#*error:}" != "$low" ]; then
    bad "$1 → 被误拦（退出 $rc）：$out"
  else
    ok "$1 → 通过"
  fi
}

expect_block "I2 超占（allocated>on_hand）" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (900,1,1,1,1,'KG',10000,99000);" \
  "ck_stock_nonneg"
seed "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16');"
assert_n "种子 outbound_order" "SELECT count(*) FROM outbound_order" 1
# 第 7 篇：补货任务 / 任务行 / 需求 / 移库单 / 移库行各一条（供逐键实打与视图断言；父行都在上面）
seed "INSERT INTO replenish_task (id,code,warehouse_id,zone_id,work_date,status,line_count) VALUES (701,'RPL-20261015-000001',1,1,'2026-10-15','PENDING',1);"
seed "INSERT INTO replenish_task_line (id,task_id,seq,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,planned_qty_milli,uom) VALUES (7101,701,1,3,1,1,3,13,20000,'KG');"
seed "INSERT INTO replenish_demand (id,code,warehouse_id,work_date,cause,target_location_id,sku_id,demand_qty_milli,source_outbound_id,source_outbound_line_id,source_alloc_round,source_doc_no) VALUES (7201,'RPD-20261015-000001',1,'2026-10-15','OUTBOUND_SHORTAGE',1,1,20000,1,1,1,'OBT1');"
seed "INSERT INTO move_order (id,code,warehouse_id,move_type,status,reason_code,line_count) VALUES (7301,'MV-20261015-000001',1,'LOCATION_TRANSFER','DRAFT','TIDY',1);"
seed "INSERT INTO move_order_line (id,move_order_id,line_no,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,qty_milli,uom) VALUES (7311,7301,1,2,3,1,1,12,10000,'KG');"
# 逐键实打要「无子行」样本：这两条没有任何行引用，供 move_order(code) / replenish_task(code) 的 REPLACE 实打
seed "INSERT INTO replenish_task (id,code,warehouse_id,zone_id,work_date,status,line_count) VALUES (702,'RPL-20261015-000002',1,2,'2026-10-15','PENDING',0);"
seed "INSERT INTO move_order (id,code,warehouse_id,move_type,status,reason_code,line_count) VALUES (7302,'MV-20261015-000002',1,'CONSOLIDATE','DRAFT','MERGE',0);"
assert_n "种子 replenish_task" "SELECT count(*) FROM replenish_task" 2
assert_n "种子 replenish_task_line" "SELECT count(*) FROM replenish_task_line" 1
assert_n "种子 replenish_demand" "SELECT count(*) FROM replenish_demand" 1
assert_n "种子 move_order" "SELECT count(*) FROM move_order" 2
assert_n "种子 move_order_line" "SELECT count(*) FROM move_order_line" 1
assert_n "种子 supplier(501)" "SELECT count(*) FROM supplier WHERE id = 501" 1
assert_n "种子 customer(1)" "SELECT count(*) FROM customer WHERE id = 1" 1
# 第 7 篇候选视图 v_location_sku_candidate：每个用例一个事务现造夹具（BEGIN … ROLLBACK），不依赖基础种子；
# 与 verify_sqlite.py 的 _view_case 同名同口径（两库对称）。号段避开其他篇用例。
_vseed="INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (7711,1,'Z7V-C','7篇视图冷藏','CHILLED','STORAGE',0,40),(7712,1,'Z7V-A','7篇视图常温','AMBIENT','STORAGE',100,300); \
INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7711,1,7711,'7V-A01','BIN',2,true,true,'7VA01','AVAILABLE'),(7712,1,7711,'7V-A02','BIN',2,false,true,'7VA02','AVAILABLE'),(7713,1,7711,'7V-A03','BIN',2,true,true,'7VA03','LOCKED'),(7714,1,7711,'7V-A04','BIN',2,false,true,'7VA04','AVAILABLE'),(7715,1,7712,'7V-B01','BIN',2,true,true,'7VB01','AVAILABLE'); \
INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (97101,'SKU7-CH','7篇视图冷藏货','KG','CHILLED',30,10,14),(97102,'SKU7-AM','7篇视图常温货','KG','AMBIENT',365,30,30),(97103,'SKU7-CH2','7篇视图冷藏货2','KG','CHILLED',30,10,14); \
INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (97111,97101,'LOT7-C1','2026-11-01','2026-10-15'),(97114,97103,'LOT7-C3','2026-11-03','2026-10-15'),(97115,97103,'LOT7-C4','2026-11-04','2026-10-15'),(97113,97102,'LOT7-A1','2026-12-01','2026-10-15');"
vcase() { # $1=描述 $2=期望值（| 连接） $3=额外夹具 $4=聚合表达式
  local got
  got=$(psql -q -t -A -c "BEGIN; $_vseed $3 SELECT $4; ROLLBACK;" 2>&1 | tail -1)
  [ "$got" = "$2" ] && ok "$1 → $got" || bad "$1 → $got，期望 $2"
}
vcase "07 视图：冷藏 SKU 候选 = 冷藏可用位（7711/7712/7714）；LOCKED 7713 与常温位 7715 都不进" \
  "7711|7712|7714" "" "string_agg(location_id::text,'|' ORDER BY location_id) FROM v_location_sku_candidate WHERE sku_id=97101 AND zone_id=7711"
vcase "07 视图：常温 SKU 候选只有常温位 7715（四个冷藏位全不进）" \
  "7715" "" "string_agg(location_id::text,'|' ORDER BY location_id) FROM v_location_sku_candidate WHERE sku_id=97102 AND zone_id=7712"
vcase "07 视图：mix_sku=false 的 7714 已有别的冷藏 SKU 的货 → 本 SKU 不进候选" \
  "7711|7712" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (97141,1,7714,97103,97114,'KG',5000);" \
  "string_agg(location_id::text,'|' ORDER BY location_id) FROM v_location_sku_candidate WHERE sku_id=97101 AND zone_id=7711"
vcase "07 视图：mix_sku=false 的 7714 已有同 SKU 的货 → 仍在候选且 has_same_sku=1" \
  "1" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (97142,1,7714,97101,97111,'KG',5000);" \
  "has_same_sku FROM v_location_sku_candidate WHERE sku_id=97101 AND location_id=7714"
vcase "07 视图：mix_sku=true 的 7711 有别的冷藏 SKU 的货也照样进候选" \
  "7711" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (97143,1,7711,97103,97114,'KG',5000);" \
  "string_agg(location_id::text,'|' ORDER BY location_id) FROM v_location_sku_candidate WHERE sku_id=97101 AND location_id=7711"
vcase "07 视图：max_lots=2 的 7714 已放 2 个批次 → lot_cnt=2 且 has_lot_slot=0" \
  "2/2/0" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (97144,1,7714,97103,97114,'KG',1000),(97145,1,7714,97103,97115,'KG',1000);" \
  "lot_cnt::text || '/' || max_lots::text || '/' || has_lot_slot::text FROM v_location_sku_candidate WHERE sku_id=97103 AND location_id=7714"
vcase "07 视图：7714 只有 1 个批次 → lot_cnt=1 且 has_lot_slot=1" \
  "1/1" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (97146,1,7714,97103,97114,'KG',1000);" \
  "lot_cnt::text || '/' || has_lot_slot::text FROM v_location_sku_candidate WHERE sku_id=97103 AND location_id=7714"
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
assert_n "种子 outbound_line" "SELECT count(*) FROM outbound_line" 1
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
expect_allow "#2 第十二轮 02 原语先查再插：同一单据行建两次归属行（第二次 0 行，与 SQLite 同文）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'SLLRP',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'SLLRP' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'SLLRP',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'SLLRP' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; ROLLBACK;"
expect_block "I5 流水平衡（after<>before+qty*dir）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ0',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ0' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'ADJ0',1,1,1,'DOC','ADJUST',-1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,3000,100000,98000,'2026-10-15','ADJ0:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (1,'ADJ0:1:D1:1','ADJ0',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,-1,'2026-10-15'); COMMIT;" \
  "ck_mv_balance"
expect_allow "期初流水 OPENING（迁移行 seq=1，before=0）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',11,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 11) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'OPEN-MIG1',11,1,1,'DOC','OPENING',1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:11:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (2,'OPEN-MIG1:11:D1:1','OPEN-MIG1',11,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,1,'2026-10-15'); COMMIT;"
expect_block "期初流水只能是该行第 1 条" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',111,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 111) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'OPEN-MIG1',111,1,1,'DOC','OPENING',1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:111:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (3,'OPEN-MIG1:111:D1:1','OPEN-MIG1',111,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,1,'2026-10-15'); COMMIT;" \
  "ck_mv_opening"
expect_allow "DOC 过账（调整出 3000）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','ADJ1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (4,'ADJ1:1:D1:1','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,-1,'2026-10-15'); COMMIT;"
expect_block "重复过账：同 biz_no+line_no+op_no+leg，换 idempotency_key" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,9,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','X:other'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (5,'X:other','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,9,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_biz_line"
expect_allow "同一 DOC 行第二次合法操作（op_no=2，不被吞）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'ADJ1',1,2,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,47000,46000,'2026-10-15','ADJ1:1:D2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6,'ADJ1:1:D2:1','ADJ1',1,2,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15'); COMMIT;"
expect_block "idempotency_key 重复（唯一格式）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ9',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ9' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'ADJ9',1,1,1,'DOC','ADJUST',-1,11,4,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (7,'ADJ1:1:D1:1','ADJ9',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,4,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_idem"
expect_block "记账链分叉（同 stock_id+stock_seq）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ8',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ8' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'ADJ8',1,1,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ8:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (8,'ADJ8:1:D1:1','ADJ8',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_stock_seq"
expect_allow "direction=0 纯事件流水不入链（SHIP）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'SHP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'SHP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'SHP1',1,1,1,'DOC','SHIP',0,11,3,1,1,1,2,NULL,NULL,NULL,NULL,3000,46000,46000,'2026-10-15','SHP1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (9,'SHP1:1:D1:1','SHP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,0,'2026-10-15'); COMMIT;"
expect_allow "期初：stock 12" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',12,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 12) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (10,'OPEN-MIG1',12,1,1,'DOC','OPENING',1,12,1,1,2,1,1,NULL,NULL,NULL,NULL,30000,0,30000,'2026-10-15','OPEN-MIG1:12:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (10,'OPEN-MIG1:12:D1:1','OPEN-MIG1',12,1,1,'DOC',NULL,NULL,NULL,NULL,12,1,1,'2026-10-15'); COMMIT;"
expect_allow "PDA 拣货（四元组 77/3/DEV-A/1）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (11,'PK2',3,0,1,'PDA','PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PK2:3:PDEV-A.1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (11,'PK2:3:PDEV-A.1:1','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,2,-1,'2026-10-15'); COMMIT;"
expect_block "Idempotency-Key 过期后 PDA 重放同一四元组（换 idempotency_key）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (12,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','X:replay'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (12,'X:replay','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,3,-1,'2026-10-15'); COMMIT;" \
  "uq_mvk_pda_op"
expect_allow "同一 PDA 行第二次合法操作（op_seq=2，不被吞）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (13,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',2,1000,29000,28000,'2026-10-15','PK2:3:PDEV-A.2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (13,'PK2:3:PDEV-A.2:1','PK2',3,0,1,'PDA',77,3,'DEV-A',2,12,3,-1,'2026-10-15'); COMMIT;"
expect_block "同一单据行 DOC 与 PDA 互斥（PDA 行上来一条 DOC 过账）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (14,'PK2',3,1,1,'DOC','PICK',-1,12,4,1,2,1,1,NULL,NULL,NULL,NULL,1000,28000,27000,'2026-10-15','PK2:3:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (14,'PK2:3:D1:1','PK2',3,1,1,'DOC',NULL,NULL,NULL,NULL,12,4,-1,'2026-10-15'); COMMIT;" \
  "ledger_line_owner_mismatch"
expect_block "换设备实例不能直接记账（DEV-B 不是当前持有设备）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-B' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (15,'PK2',3,0,1,'PDA','PICK',-1,12,4,1,2,1,1,77,3,'DEV-B',1,1000,28000,27000,'2026-10-15','PK2:3:PDEV-B.1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (15,'PK2:3:PDEV-B.1:1','PK2',3,0,1,'PDA',77,3,'DEV-B',1,12,4,-1,'2026-10-15'); COMMIT;" \
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
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'XP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'XP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (17,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-10-31','XP1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (17,'XP1:1:D1:1','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-10-31'); COMMIT;"
expect_block "跨分区去重：同一键 11-01 再记（PG 落在另一个分区）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'XP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'XP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (18,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-11-01','X:xp'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (18,'X:xp','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-11-01'); COMMIT;" \
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
expect_block "第十三轮：RESOLVED 告警不可再改（resolution 抹空）" \
  "BEGIN; UPDATE stock_recon_alert SET resolution = NULL, resolved_by = NULL WHERE id = 1; COMMIT;" "recon_resolved_immutable"
expect_allow "第十三轮：未闭环告警仍可 UPDATE（认领 ACKED）" \
  "BEGIN; UPDATE stock_recon_alert SET status = 'ACKED' WHERE id = 4; ROLLBACK;"
expect_allow "变异：去掉 trg_recon_resolved_lock 后可改 RESOLVED 告警" \
  "BEGIN; DROP TRIGGER trg_recon_resolved_lock ON stock_recon_alert; UPDATE stock_recon_alert SET resolution = NULL WHERE id = 1; ROLLBACK;"
echo "=== 2b2. 小赵复评 C2–C5 + convert_hold ==="
expect_block "C2 只写流水、不写 key 行（库层外键，提交时拦）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ7',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ7' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (30,'ADJ7',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1'); COMMIT;" \
  "fk_mv_key"
expect_block "C2 key 行与流水内容不一致（key=ADJ7，流水=ADJ6）" \
  "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ7',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ7' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (31,'ADJ6',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (31,'ADJ7:1:D1:1','ADJ7',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,1,-1,'2026-10-15'); COMMIT;" \
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
expect_allow "C4 正向：check_code='RR_HOLD_FAILED'、'RR_HOLD_MISMATCH'（04 §9 / 05 巡检，#7 Q15）可写入" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9021,'RR_HOLD_FAILED',1,12,1000,0),(9020,'RR_HOLD_MISMATCH',1,14,5000,0); ROLLBACK;"
expect_allow "C4 正向：check_code='CHECK_BOX_MISMATCH'、'SHIP_EVENT_MISSING'（06 巡检，#11 Q10）可写入" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9022,'CHECK_BOX_MISMATCH',1,12,1000,0),(9023,'SHIP_EVENT_MISSING',1,14,5000,0); ROLLBACK;"
expect_allow "convert_hold 准备：stock 40 被 RETURN_PENDING 冻满（available=0）" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (40,1,2,1,3,'KG',5000,5000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (30,40,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',601,'RRH:601',5000,0,'HELD',0); COMMIT;"
expect_allow "convert_hold：available=0 时 RETURN_PENDING → SCRAP_PENDING/SCRAP（source_id = 报损单 9001）" \
  "BEGIN; SELECT id FROM stock WHERE id = 40 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 30 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (31,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0,30); COMMIT;"
expect_block "convert_hold 重试：CVT:30 已存在（幂等，由 uq_hold_op 兜底）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (32,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0); COMMIT;" \
  "uq_hold_op"
R=$(psql -t -A -c "SELECT s.hold_qty_milli||'/'||v.available_qty_milli||'/'||(SELECT COALESCE(SUM(hold_qty_milli - released_qty_milli),0) FROM stock_hold WHERE stock_id=40 AND status='HELD' AND hold_type IN ('MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')) FROM stock s JOIN v_stock_available v ON v.stock_id=s.id WHERE s.id=40")
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
OUT=$(psql_capture "SET ROLE wms_app; UPDATE stock_hold SET hold_type='MANUAL', reason_code='DAMAGE', operator_id=7 WHERE id=31;")
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
OUT=$(psql_capture "SET ROLE wms_app; UPDATE stock_hold SET released_qty_milli = 0, status = 'HELD' WHERE id = 30;")
case "$OUT" in *"hold_immutable"*) ok "R1 wms_app 改回 HELD 被触发器拦（列级授权放行了这两列，靠触发器）";; *) bad "wms_app 改回 HELD 未被拦：$OUT";; esac
expect_block "R2 超级用户 DELETE 冻结明细" "BEGIN; DELETE FROM stock_hold WHERE id = 31; COMMIT;" "hold_immutable"
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM stock_hold WHERE id = 31;")
case "$OUT" in *"permission denied for table stock_hold"*) ok "R2 wms_app DELETE stock_hold → permission denied";; *) bad "wms_app DELETE 未被拒：$OUT";; esac
OUT=$(psql_capture "TRUNCATE stock_hold CASCADE;")   # 有 fk_hr_hold 后不带 CASCADE 会先报外键；CASCADE 时两表触发器都拦
case "$OUT" in *"hold_immutable"*) ok "R2 超级用户 TRUNCATE stock_hold 被语句级触发器拦";; *) bad "TRUNCATE 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT hold_type||'/'||status||'/'||released_qty_milli FROM stock_hold WHERE id=31")
[ "$R" = "SCRAP_PENDING/HELD/0" ] && ok "R2 绕过尝试后 id=31 仍为 $R" || bad "id=31 被改成 $R"
expect_block "报损冻结不能再用 MANUAL/SCRAP（只能 SCRAP_PENDING）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (33,40,'MANUAL','SCRAP','SCRAP',601,'H33',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_reason"
expect_block "SCRAP_PENDING 必须挂报损单且为系统冻结" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (34,40,'SCRAP_PENDING','SCRAP','RETURN_RECORD',601,'H34',1000,0,'HELD',7); COMMIT;" \
  "ck_hold_scrap"
OUT=$(psql_capture "TRUNCATE stock_movement_key CASCADE;")
case "$OUT" in *"append_only_violation"*) ok "C5 超级用户 TRUNCATE 去重表被语句级触发器拦下";; *) bad "TRUNCATE 未被拦：$OUT";; esac
OUT=$(psql_capture "TRUNCATE stock_movement;")
case "$OUT" in *"append_only_violation"*) ok "C5 超级用户 TRUNCATE 流水表被拦";; *) bad "TRUNCATE 流水未被拦：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; UPDATE stock_ledger_line SET src_kind='DOC' WHERE biz_no='PK2';")
case "$OUT" in *"permission denied"*) ok "C3 wms_app 无 stock_ledger_line.src_kind 列的 UPDATE 权限";; *) bad "wms_app 改 src_kind 未被拒：$OUT";; esac
XP1=$(psql -t -A -c "SELECT count(*) FROM stock_movement WHERE biz_no='XP1'")
XPP=$(psql -t -A -c "SELECT count(DISTINCT tableoid) FROM stock_movement WHERE biz_no='XP1' OR id=4")
[ "$XP1" = "1" ] && ok "跨分区去重：被拦那笔随事务回滚（XP1 只有 1 条；样本流水分布在 $XPP 个分区）" || bad "XP1 流水 $XP1 条"
OUT=$(psql_capture "SET ROLE wms_app; UPDATE stock_movement SET remark='x' WHERE id=4;")
case "$OUT" in *"permission denied for table stock_movement"*) ok "只追加：应用角色 wms_app 无 UPDATE 权限";; *) bad "wms_app UPDATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM stock_movement_key WHERE movement_id=4;")
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
expect_allow "A3 convert_hold QUALITY → SCRAP_PENDING（跨列：同事务 quality_hold −q、hold_qty +q）" "BEGIN; SELECT id FROM stock WHERE id = 41 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 51 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 51 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (52,41,'SCRAP_PENDING','SCRAP','SCRAP',9101,'CVT:51',3000,0,'HELD',0,51); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 3000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "5000/3000/1000" ] && ok "A3 QUALITY 转后 quality/hold/available = $R（冻结总量 8000 与可用量不变）" || bad "A3 QUALITY 转后 = $R（期望 5000/3000/1000）"
expect_allow "A3 convert_hold RETURN_QC 剩余 5000 → SCRAP_PENDING" "BEGIN; SELECT id FROM stock WHERE id = 41 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 50 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND released_qty_milli = 1000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (53,41,'SCRAP_PENDING','SCRAP','SCRAP',9102,'CVT:50',5000,0,'HELD',0,50); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 5000, hold_qty_milli = hold_qty_milli + 5000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 5000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "0/8000/1000" ] && ok "A3 RETURN_QC 转后 quality/hold/available = $R（冻结总量 8000 与可用量不变）" || bad "A3 RETURN_QC 转后 = $R（期望 0/8000/1000）"
expect_block "A3 stock_hold_release 只追加（UPDATE）" "BEGIN; UPDATE stock_hold_release SET qty_milli = 2000 WHERE op_key = 'QCR:7001:1'; COMMIT;" "hold_immutable"
echo "=== 2f2. 小赵五轮 Q1/S5/S6 stock_hold_release；Q2 去重记录与 outbox 清理 ==="
expect_block "S6 释放记录挂不存在的冻结（外键）" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (4,999999,'QCR:x:1',1); COMMIT;" "fk_hr_hold"
OUT=$(psql_capture "TRUNCATE stock_hold_release;")
case "$OUT" in *"hold_immutable"*) ok "S5 超级用户 TRUNCATE stock_hold_release 被语句级触发器拦";; *) bad "TRUNCATE stock_hold_release 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT count(*) FROM (SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)) t")
[ "$R" = "0" ] && ok "S6 I3e 对账：RETURN_QC 已释放 = Σ释放记录 + 转报损量（无差异行）" || bad "I3e 差异行 $R"
R=$(psql -t -A -c "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (55,41,'RETURN_QC','RETURN_QC','QC',7003,'RQC:7003',2000,0,'HELD',0); UPDATE stock_hold SET released_qty_milli = 500, version = version + 1 WHERE id = 55; SELECT 'ids=' || string_agg(id::text, ',') FROM (SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)) t; ROLLBACK;" | grep '^ids=')
[ "$R" = "ids=55" ] && ok "S6 I3e 反向：绕过释放记录直接 UPDATE 释放 → 对账查出 hold 55" || bad "I3e 未查出：$R"
expect_allow "Q2 准备：去重记录（未过期/已过期）+ outbox（PENDING / 8 天前 SENT / 刚 SENT）" "BEGIN; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','h','{}',200,now()+interval '1 day'),('dead','h','{}',200,now()-interval '1 hour'); INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8801,'t','k','{}','PENDING',NULL,NULL),(8802,'t','k','{}','SENT',now()-interval '8 days','2XX'),(8803,'t','k','{}','SENT',now(),'2XX'); COMMIT;"
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM idempotency_record WHERE idem_key='dead';")
case "$OUT" in *"permission denied for table idempotency_record"*) ok "Q2 wms_app DELETE idempotency_record → permission denied";; *) bad "wms_app DELETE idem 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM outbox_event WHERE id=8802;")
case "$OUT" in *"permission denied for table outbox_event"*) ok "Q2 wms_app DELETE outbox_event → permission denied";; *) bad "wms_app DELETE outbox 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; TRUNCATE outbox_event;")
case "$OUT" in *"permission denied"*) ok "Q2 wms_app TRUNCATE outbox_event → permission denied";; *) bad "wms_app TRUNCATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_cleaner; DELETE FROM idempotency_record WHERE idem_key='dead';")
case "$OUT" in *"permission denied for table idempotency_record"*) ok "Q2 wms_cleaner 直接 DELETE → permission denied（只能 EXECUTE 函数）";; *) bad "wms_cleaner 直接 DELETE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; SELECT * FROM purge_expired();")
case "$OUT" in *"permission denied for function purge_expired"*) ok "Q2 wms_app 调 purge_expired() → permission denied";; *) bad "wms_app 调函数未被拒：$OUT";; esac
expect_block "Q2 超级用户删未过期去重记录（触发器兜底）" "BEGIN; DELETE FROM idempotency_record WHERE idem_key='live'; COMMIT;" "purge_not_allowed: idempotency_record"
expect_block "Q2 超级用户删 PENDING 事件" "BEGIN; DELETE FROM outbox_event WHERE id=8801; COMMIT;" "purge_not_allowed: outbox_event"
expect_block "Q2 超级用户删刚投递（未过保留期）事件" "BEGIN; DELETE FROM outbox_event WHERE id=8803; COMMIT;" "purge_not_allowed: outbox_event"
OUT=$(psql_capture "TRUNCATE idempotency_record;")
case "$OUT" in *"purge_not_allowed"*) ok "Q2 超级用户 TRUNCATE idempotency_record 被拦";; *) bad "TRUNCATE idem 未被拦：$OUT";; esac
R=$(psql -t -A -c "SELECT p.prosecdef::text || '/' || array_to_string(p.proconfig, ',') || '/' || r.rolsuper::text || '/' || r.rolname || '/' || has_function_privilege('public', p.oid, 'EXECUTE')::text FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.proname = 'purge_expired'")
[ "$R" = "true/search_path=pg_catalog, public, pg_temp/false/wms_purge_owner/false" ] && ok "Q2 purge_expired：SECURITY DEFINER、固定 search_path、属主非超级用户、PUBLIC 无 EXECUTE（$R）" || bad "purge_expired 属性：$R"
# 小赵 S2：wms_cleaner / wms_purge_owner / PUBLIC 的逐表权限矩阵（七种表权限全查），以及 purge_expired 的 proacl 逐条核对
role_matrix() {  # $1 角色名（public 用小写）：列出有任一权限的对象，无则输出 NONE
  psql -t -A -c "SELECT COALESCE(string_agg(x, ' ' ORDER BY x), 'NONE') FROM (SELECT c.relname || ':' || concat_ws(',', CASE WHEN has_table_privilege('$1', c.oid, 'SELECT') THEN 'SELECT' END, CASE WHEN has_table_privilege('$1', c.oid, 'INSERT') THEN 'INSERT' END, CASE WHEN has_table_privilege('$1', c.oid, 'UPDATE') THEN 'UPDATE' END, CASE WHEN has_table_privilege('$1', c.oid, 'DELETE') THEN 'DELETE' END, CASE WHEN has_table_privilege('$1', c.oid, 'TRUNCATE') THEN 'TRUNCATE' END, CASE WHEN has_table_privilege('$1', c.oid, 'REFERENCES') THEN 'REFERENCES' END, CASE WHEN has_table_privilege('$1', c.oid, 'TRIGGER') THEN 'TRIGGER' END) AS x FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m') AND NOT c.relispartition) t WHERE x NOT LIKE '%:'"
}
# upstream_push_log:SELECT,DELETE 由 #2 99_grants 的目录检查授予（4e3a7efb 起）
for spec in "wms_cleaner|NONE" "wms_purge_owner|idempotency_record:SELECT,DELETE outbox_event:SELECT,DELETE upstream_push_log:SELECT,DELETE" "public|NONE"; do
  RL=${spec%%|*}; EXP=${spec#*|}; GOT=$(role_matrix "$RL")
  [ "$GOT" = "$EXP" ] && ok "S2 $RL 表权限矩阵 = $EXP" || bad "S2 $RL 表权限矩阵：期望 $EXP，实际 $GOT"
done
R=$(psql -t -A -c "SELECT string_agg(e, ' ' ORDER BY e) FROM (SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || '=' || a.privilege_type || '/' || pg_get_userbyid(a.grantor) AS e FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname = 'purge_expired') t")
[ "$R" = "wms_cleaner=EXECUTE/wms_purge_owner wms_purge_owner=EXECUTE/wms_purge_owner" ] && ok "S2 purge_expired proacl 只有属主与 wms_cleaner 的 EXECUTE（PUBLIC 无，$R）" || bad "S2 purge_expired proacl：$R"
R=$(psql -t -A -c "SELECT has_function_privilege('wms_app', 'public.purge_expired()', 'EXECUTE')::text || '/' || has_function_privilege('wms_cleaner', 'public.purge_expired()', 'EXECUTE')::text || '/' || r.rolsuper::text || r.rolcanlogin::text || '/' || c.rolsuper::text || c.rolcanlogin::text FROM pg_roles r, pg_roles c WHERE r.rolname = 'wms_purge_owner' AND c.rolname = 'wms_cleaner'")
[ "$R" = "false/true/falsefalse/falsefalse" ] && ok "S2 wms_app 无 EXECUTE、wms_cleaner 有；两个清理角色均非超级用户且 NOLOGIN（$R）" || bad "S2 清理角色属性：$R"
R=$(psql -t -A -c "SET ROLE wms_cleaner; SELECT idem_deleted || '/' || outbox_deleted FROM purge_expired();" | grep '/')
[ "$R" = "1/1" ] && ok "Q2 wms_cleaner 调 purge_expired() 删掉 1 条过期去重 + 1 条过保留期 SENT" || bad "purge_expired 结果：$R"
R=$(psql -t -A -c "SELECT (SELECT string_agg(idem_key, ',') FROM idempotency_record) || '|' || (SELECT string_agg(id::text, ',' ORDER BY id) FROM outbox_event)")
[ "$R" = "live|8801,8803" ] && ok "Q2 清理后剩余 $R（未过期、PENDING、未过保留期的都在）" || bad "Q2 清理后：$R"
echo "=== 2f2b. 九轮 P1–P3：UTC 清理、过期列只许往后改、SENT 必带 sent_at ==="
expect_block "P3 status=SENT 但 sent_at 为空" "INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8804,'t','k','{}','SENT',NULL,'2XX');" "ck_outbox_sent"
expect_allow "P3 正向：PENDING 不带 sent_at、SENT 带 sent_at" "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8805,'t','k','{}','PENDING',NULL,NULL),(8806,'t','k','{}','SENT',now() AT TIME ZONE 'UTC','2XX'); ROLLBACK;"
expect_block "P2 wms_app 把 idem expires_at 改早" "SET ROLE wms_app; UPDATE idempotency_record SET expires_at='2000-01-01' WHERE idem_key='live';" "expiry_backdate: expires_at"
expect_block "P2 idem created_at 被改" "UPDATE idempotency_record SET created_at='2000-01-01' WHERE idem_key='live';" "expiry_backdate: created_at"
expect_block "P2 wms_app 把 outbox sent_at 改早" "SET ROLE wms_app; UPDATE outbox_event SET sent_at=(now() AT TIME ZONE 'UTC') - interval '30 days' WHERE id=8803;" "expiry_backdate: sent_at"
expect_block "P2 outbox sent_at 清空（SENT 仍在）" "UPDATE outbox_event SET sent_at=NULL WHERE id=8803;" "expiry_backdate: sent_at"
expect_block "P2 wms_app PENDING → SENT 时 sent_at 倒填 2000-01-01（R1 起先由 sent_at_not_now 拦）" "SET ROLE wms_app; UPDATE outbox_event SET status='SENT', sent_at='2000-01-01' WHERE id=8801;" "sent_at_not_now"
expect_block "P2 SENT 退回 PENDING" "UPDATE outbox_event SET status='PENDING' WHERE id=8803;" "expiry_backdate: status"
expect_allow "P2 正向：idem expires_at 往后延" "BEGIN; SET LOCAL ROLE wms_app; UPDATE idempotency_record SET expires_at=(now() AT TIME ZONE 'UTC') + interval '2 days' WHERE idem_key='live'; ROLLBACK;"
expect_allow "P2 正向：sent_at 往后改、PENDING → SENT 写当前 UTC" "BEGIN; SET LOCAL ROLE wms_app; UPDATE outbox_event SET sent_at=sent_at + interval '1 minute' WHERE id=8803; UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=now() AT TIME ZONE 'UTC' WHERE id=8801; ROLLBACK;"
expect_block "R1 补洞：wms_app 以 SENT 状态插入 outbox（sent_at 倒写 1 天前）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8811,'t','k','{}','SENT',(now() AT TIME ZONE 'UTC') - interval '1 day'); ROLLBACK;" "outbox_insert_not_pending"
expect_block "R1 补洞：wms_app 以 PENDING 插入但带过去的 sent_at" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8812,'t','k','{}','PENDING',(now() AT TIME ZONE 'UTC') - interval '8 days'); ROLLBACK;" "outbox_insert_not_pending"
expect_allow "R1 补洞正向：wms_app 以 PENDING 插入（不带 sent_at）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO outbox_event (id,topic,biz_key,payload) VALUES (8813,'t','k','{}'); ROLLBACK;"
expect_block "R1 PENDING → SENT 时 sent_at 写成 1 小时前" "BEGIN; SET LOCAL ROLE wms_app; UPDATE outbox_event SET status='SENT', sent_at=(now() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=8801; ROLLBACK;" "sent_at_not_now"
expect_block "R1 PENDING → SENT 时 sent_at 写成 1 小时后" "BEGIN; SET LOCAL ROLE wms_app; UPDATE outbox_event SET status='SENT', sent_at=(now() AT TIME ZONE 'UTC') + interval '1 hour' WHERE id=8801; ROLLBACK;" "sent_at_not_now"
expect_allow "R1 正向：PENDING → SENT 写当前 UTC（容差内 +3 秒）" "BEGIN; SET LOCAL ROLE wms_app; UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=(now() AT TIME ZONE 'UTC') + interval '3 seconds' WHERE id=8801; ROLLBACK;"
echo "=== 2f2c. search_path 钉死；登录角色劫持同名对象；非属主插入 FAILED ==="
# #2 定义的 10 个函数。proconfig 要正好是 search_path=pg_catalog, public, pg_temp（与 purge_expired 已有断言同一写法）。
R=$(psql -t -A -c "SELECT count(*)::text || '/' || (count(*) FILTER (WHERE p.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[]))::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname IN ('purge_expired','trg_append_only','trg_expiry_forward','trg_hold_immutable','trg_hold_no_delete','trg_lot_sell_deadline','trg_mvk_line_kind','trg_outbox_insert_pending','trg_purge_guard','trg_sll_immutable')")
[ "$R" = "10/10" ] && ok "#2 的 10 个函数 proconfig 都是 search_path=pg_catalog, public, pg_temp（$R）" || bad "search_path 目录：$R（期望 10/10）"
# 角色是集群级的。CREATE ROLE 不能放进事务。已有就改属性，避免第二次跑 verify 撞“角色已存在”。
if [ "$(psql -t -A -c "SELECT count(*) FROM pg_roles WHERE rolname = 'wms_login_test'" | tr -d '[:space:]')" != "1" ]; then
  seed "CREATE ROLE wms_login_test LOGIN INHERIT"
fi
seed "ALTER ROLE wms_login_test LOGIN INHERIT"
seed "GRANT wms_app TO wms_login_test"
R=$(psql -t -A -c "SELECT r.rolname || '/' || r.rolcanlogin::text || '/' || pg_has_role('wms_login_test', 'wms_app', 'member')::text FROM pg_roles r WHERE r.rolname = 'wms_login_test'")
[ "$R" = "wms_login_test/true/true" ] && ok "wms_login_test 是登录角色，且继承 wms_app（后面的语句只 SET ROLE 到它，不再 SET ROLE wms_app）" || bad "登录角色：$R"
# 劫持对象放在 hijack，不进 public，避免改 S4 的表权限矩阵。要让同名对象赢，会话必须把 hijack 放在 pg_catalog 前面；函数自己的 search_path 会盖住这条会话设置。
seed "DROP SCHEMA IF EXISTS hijack CASCADE"
seed "$(cat <<'SQL'
CREATE SCHEMA hijack AUTHORIZATION wms_login_test;
CREATE TABLE hijack.stock_ledger_line (biz_no varchar(64), line_no int, src_kind varchar(8), owner_device_instance_id varchar(64));
INSERT INTO hijack.stock_ledger_line (biz_no, line_no, src_kind, owner_device_instance_id) VALUES ('HIJACK', 1, 'DOC', NULL);
CREATE FUNCTION hijack.now() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT '2000-01-01 00:00:00+00'::timestamptz $$;
CREATE FUNCTION hijack.date_eq_always(date, date) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT true $$;
CREATE OPERATOR hijack.= (FUNCTION = hijack.date_eq_always, LEFTARG = date, RIGHTARG = date);
SQL
)"
expect_block "劫持同名表打 trg_mvk_line_kind（登录角色把 hijack 放在 pg_catalog 前）" \
  "SET ROLE wms_login_test; SET search_path = hijack, pg_catalog, public; INSERT INTO public.stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (99001,'HIJ:1:D1:1','HIJACK',1,1,1,'DOC',11,99001,0,'2026-10-15 00:00:00');" \
  "ledger_line_owner_mismatch"
expect_block "劫持同名 now() 打 trg_expiry_forward（登录角色把 hijack 放在 pg_catalog 前）" \
  "SET ROLE wms_login_test; SET search_path = hijack, pg_catalog, public; UPDATE public.outbox_event SET status='SENT', sent_at='2000-01-01' WHERE id=8801;" \
  "sent_at_not_now"
expect_block "劫持同名 =(date,date) 打 trg_lot_sell_deadline（登录角色把 hijack 放在 pg_catalog 前）" \
  "SET ROLE wms_login_test; SET search_path = hijack, pg_catalog, public; UPDATE public.lot SET sell_deadline = '2026-12-15' WHERE id = 1;" \
  "sell_deadline_immutable"
# 应用连接的 current_user 是登录角色本身，不会再 SET ROLE wms_app。这里只 SET ROLE 到登录角色。
expect_block "继承 wms_app 的登录角色不 SET ROLE wms_app，插入 status=FAILED" \
  "SET ROLE wms_login_test; INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (8899,'t','k','{}','FAILED');" \
  "outbox_insert_not_pending"
expect_allow "同一登录角色插入 PENDING（不带 sent_at）" \
  "BEGIN; SET LOCAL ROLE wms_login_test; INSERT INTO outbox_event (id,topic,biz_key,payload) VALUES (8898,'t','k','{}'); ROLLBACK;"
seed "INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,created_at,expires_at) VALUES ('tz_live12h','h','{}',200,now() AT TIME ZONE 'UTC',(now() AT TIME ZONE 'UTC') + interval '12 hours'),('tz_dead','h','{}',200,now() AT TIME ZONE 'UTC',(now() AT TIME ZONE 'UTC') - interval '1 hour');"
# POSIX 记号相反：Etc/GMT-8 = UTC+8，Etc/GMT+10 = UTC-10，Etc/GMT-14 = UTC+14（小赵 P1 的复现时区）
TZR=""
for Z in Etc/GMT-8 Etc/GMT+10 Etc/GMT-14; do
  N=$(psql -t -A -c "BEGIN; SET LOCAL TimeZone='$Z'; SET LOCAL ROLE wms_cleaner; SELECT 'n=' || idem_deleted FROM purge_expired(); ROLLBACK;" | grep '^n=')
  TZR="$TZR$Z:$N "
done
[ "$TZR" = "Etc/GMT-8:n=1 Etc/GMT+10:n=1 Etc/GMT-14:n=1 " ] && ok "P1 会话时区 +8 / -10 / +14 下 purge_expired 删的行数相同（$TZR，只删 tz_dead）" || bad "P1 时区清理行数：$TZR"
expect_block "P1 会话时区 +14 下超级用户删还剩 12 小时的记录（守卫按 UTC）" "SET TimeZone='Etc/GMT-14'; DELETE FROM idempotency_record WHERE idem_key='tz_live12h';" "purge_not_allowed: idempotency_record"
R=$(psql -t -A -c "SET TimeZone='Etc/GMT-14'; SET ROLE wms_cleaner; SELECT 'n=' || idem_deleted FROM purge_expired();" | grep '^n=')
R2=$(psql -t -A -c "SELECT string_agg(idem_key, ',' ORDER BY idem_key) FROM idempotency_record WHERE idem_key LIKE 'tz_%'")
[ "$R/$R2" = "n=1/tz_live12h" ] && ok "P1 +14 时区实删后 tz_live12h 仍在（$R/$R2）" || bad "P1 +14 实删：$R/$R2"

echo "=== 2f3. 误报回转 SCRAP_PENDING → RETURN_QC（SCRAP_MISREPORT 审批）==="
seed "CREATE TABLE IF NOT EXISTS approval_request (     id BIGINT PRIMARY KEY,     code VARCHAR(64) NOT NULL,     CONSTRAINT uq_apr_code UNIQUE (code) ); INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (90,'W1','x','20:00'),(91,'Z9Z9Z9Z9Z9Z9Z9Z9','x','20:00') ON CONFLICT (id) DO NOTHING; INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (5001,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'HOLD','5001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5002,'APR-WHSH01-20261015-000002','CANCEL_AFTER_PICK',1,'HOLD','5002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5003,'APR-WHSH01-20261015-000003','CANCEL_AFTER_PICK',1,'HOLD','5003','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5004,'APR-WHSH01-20261015-000004','CANCEL_AFTER_PICK',1,'HOLD','5004','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5009,'APR-WHSH01-20261015-000009','CANCEL_AFTER_PICK',1,'HOLD','5009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5099,'APR-WHSH01-20261015-000099','CANCEL_AFTER_PICK',1,'HOLD','5099','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5123,'APR-WHSH01-20261015-000123','CANCEL_AFTER_PICK',1,'HOLD','5123','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5999,'APR-WHSH01-20261231-999999','CANCEL_AFTER_PICK',1,'HOLD','5999','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5160,'APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000','CANCEL_AFTER_PICK',91,'HOLD','5160','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5011,'APR-W1-20261015-000001','CANCEL_AFTER_PICK',90,'HOLD','5011','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5000,'APR-WHSH01-20260101-000000','CANCEL_AFTER_PICK',1,'HOLD','5000','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL), (5029,'APR-WHSH01-20280229-000001','CANCEL_AFTER_PICK',1,'HOLD','5029','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL) ON CONFLICT (code) DO NOTHING;"
assert_n "审批号底数：合法 APR 写入 approval_request" "SELECT count(*) FROM approval_request" 12
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "0/8000/1000" ] && ok "误报回转前 quality/hold/available = $R" || bad "误报回转前 = $R（期望 0/8000/1000）"
expect_block "误报回转缺审批单号（→ 应用层 40930，库层 ck_hold_approval 兜底）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (57,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,NULL,NULL,true); COMMIT;" "ck_hold_approval"
expect_block "误报回转审批类型不是 SCRAP_MISREPORT" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (59,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,'OTHER','APR-WHSH01-20261015-000002',true); COMMIT;" "ck_hold_approval"
expect_block "非误报回转的明细不能挂审批（MANUAL + SCRAP_MISREPORT）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (60,41,'MANUAL','DAMAGE','MANUAL',0,'H60',1000,0,'HELD',7,'SCRAP_MISREPORT','APR-WHSH01-20261015-000003'); COMMIT;" "ck_hold_approval"
expect_allow "误报回转：SCRAP_PENDING 52（3000）→ RETURN_QC 56，挂新质检单 7010 + 审批 APR-WHSH01-20261015-000001；hold −q、quality +q" "BEGIN; SELECT id FROM stock WHERE id = 41 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 52 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 52 AND hold_type = 'SCRAP_PENDING' AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal,from_hold_id) VALUES (56,41,'RETURN_QC','RETURN_QC','QC',7010,'CVT:52',3000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',true,52); UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, quality_hold_qty_milli = quality_hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND hold_qty_milli >= 3000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=41")
[ "$R" = "3000/5000/1000" ] && ok "误报回转后 quality/hold/available = $R（冻结总量 8000、可用量 1000 不变）" || bad "误报回转后 = $R（期望 3000/5000/1000）"
expect_block "误报回转后审批单号不可改" "BEGIN; UPDATE stock_hold SET approval_no = 'APR-WHSH01-20261015-000099' WHERE id = 56; COMMIT;" "hold_immutable"
R=$(psql -t -A -c "SELECT count(*) FROM (SELECT h.id FROM stock_hold h WHERE h.is_reversal AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE o.id = h.from_hold_id AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)) t")
[ "$R" = "0" ] && ok "I3e（含误报回转口径）无差异行" || bad "I3e 差异 $R"
R=$(psql -t -A -c "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (58,41,'RETURN_QC','RETURN_QC','QC',7012,'CVT:999',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000004',true); SELECT 'ids=' || string_agg(id::text, ',') FROM (SELECT h.id FROM stock_hold h WHERE h.is_reversal AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE o.id = h.from_hold_id AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)) t; ROLLBACK;" | grep '^ids=')
[ "$R" = "ids=58" ] && ok "I3e 反向：RETURN_QC 声称回转自不存在的 SCRAP_PENDING 999→ 查出 58" || bad "I3e 未查出：$R"
echo "=== 2f4. 审批单号格式 ck_hold_approval_no：APR-{仓库编码}-{yyyyMMdd}-{6位数字} ==="
expect_block "审批单号格式反向：仓库编码小写" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (70,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:870',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-whsh01-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：前缀不是 APR" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (71,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:871',1000,0,'HELD',0,'SCRAP_MISREPORT','APV-WHSH01-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：仓库编码含 '-'" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (72,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:872',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WH-SH-01-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：仓库编码为空" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (73,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:873',1000,0,'HELD',0,'SCRAP_MISREPORT','APR--20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：月份 13" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (74,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:874',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261315-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：日期 32" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (75,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:875',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261032-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：序号 5 位" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (76,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:876',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-00001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：序号 7 位" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (77,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:877',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-0000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：日期 7 位" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (78,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:878',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-2026101-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：末尾多空格" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (79,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:879',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001 ',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：仓库编码 17 位" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (80,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:880',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-AAAAAAAAAAAAAAAAA-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：仓库编码 1 位" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (81,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:881',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-W-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "审批单号格式反向：仓库编码含下划线" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (82,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:882',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH_01-20261015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_allow "审批单号格式正向：常规 WHSH01（APR-WHSH01-20261015-000123）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (90,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:890',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000123',true); ROLLBACK;"
expect_allow "审批单号格式正向：年末日期（APR-WHSH01-20261231-999999）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (91,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:891',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261231-999999',true); ROLLBACK;"
expect_allow "审批单号格式正向：16 位编码（APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (92,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:892',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000',true); ROLLBACK;"
expect_allow "审批单号格式正向：2 位编码（APR-W1-20261015-000001）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (95,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:895',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-W1-20261015-000001',true); ROLLBACK;"
expect_allow "审批单号格式正向：年初 + 序号全 0（APR-WHSH01-20260101-000000）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (96,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:896',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260101-000000',true); ROLLBACK;"
expect_block "N1 审批单号非真实日期：2 月 30 日" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (83,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:883',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260230-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "N1 审批单号非真实日期：平年 2 月 29 日" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (84,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:884',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20250229-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "N1 审批单号非真实日期：4 月 31 日" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (85,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:885',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260431-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_block "N1 审批单号非真实日期：年份 0000" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (86,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:886',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-00001015-000001',true); ROLLBACK;" "ck_hold_approval_no"
expect_allow "N1 审批单号真实日期正向：闰年 2 月 29 日（APR-WHSH01-20280229-000001）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (93,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:893',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20280229-000001',true); ROLLBACK;"
expect_block "N1 回转标记打在非 RETURN_QC 上" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (87,41,'MANUAL','DAMAGE','MANUAL',0,'H87',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',true); ROLLBACK;" "ck_hold_reversal_key"
expect_block "N1 RETURN_QC 的 CVT 明细未标回转（不带审批伪造回转）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (88,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:888',1000,0,'HELD',0,NULL,NULL,false); ROLLBACK;" "ck_hold_reversal_key"
R=$(psql -t -A -c "SELECT count(*) FROM stock_hold WHERE id >= 70 AND id < 100")
[ "$R" = "0" ] && ok "审批单号格式用例全部回滚，无残留明细" || bad "审批单号格式用例残留 $R 行"
echo "=== 2c. docs/02 40906：库位锁定写进扣减原语的 WHERE ==="
seed "UPDATE location SET status='LOCKED' WHERE id=3;"
DEDUCT="UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 AND EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED');"
R=$(psql -t -A -c "$DEDUCT")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：扣减 rowcount=0" || bad "锁定库位仍扣减：$R"
seed "UPDATE location SET status='AVAILABLE' WHERE id=3;"
R=$(psql -t -A -c "$DEDUCT")
[ "$R" = "UPDATE 1" ] && ok "库位解锁后 rowcount=1" || bad "解锁后：$R"
seed "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;"
echo "=== 2c2. post_in：REVERSE_PICK 放行库位锁（盘点期间流水），其他来源仍拦 ==="
seed "UPDATE location SET status='LOCKED' WHERE id=3;"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('REVERSE_PICK' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 1" ] && ok "库位 LOCKED：REVERSE_PICK 入账 rowcount=1" || bad "REVERSE_PICK 被锁拦：$R"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('RECEIVE' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：RECEIVE 入账 rowcount=0（→ 40906）" || bad "RECEIVE 未被锁拦：$R"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('MOVE' = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "库位 LOCKED：MOVE 目标腿 rowcount=0" || bad "MOVE 未被锁拦：$R"
seed "UPDATE location SET status='AVAILABLE' WHERE id=3; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;"
echo "=== 2c3. G19：COUNT（盘盈/盘亏）放行库位锁，post_in / post_out 同口径；其他来源仍拦 ==="
# 白名单是 biz_type ∈ {COUNT, REVERSE_PICK}，与 §7.1 原语表、§8.1 行为矩阵同一口径。
# 盘亏走 post_out(COUNT)，此前例外只写在 post_in 语境 → 盘亏在 LOCKED 库位被 40906 拦下（G19）。
seed "UPDATE location SET status='LOCKED' WHERE id=3;"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND ('COUNT' IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 1" ] && ok "G19 库位 LOCKED：post_in(COUNT) 盘盈入账 rowcount=1" || bad "G19 盘盈被锁拦：$R"
seed "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 AND ('COUNT' IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 1" ] && ok "G19 库位 LOCKED：post_out(COUNT) 盘亏过账 rowcount=1" || bad "G19 盘亏被锁拦：$R"
seed "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq - 1 WHERE id = 13;"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 AND ('SCRAP' IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "G19 库位 LOCKED：post_out(SCRAP) rowcount=0（→ 40906）" || bad "G19 SCRAP 未被锁拦：$R"
R=$(psql -t -A -c "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 AND ('ADJUST' IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
[ "$R" = "UPDATE 0" ] && ok "G19 库位 LOCKED：post_out(ADJUST) rowcount=0（待 08 篇定，§12 Q13）" || bad "G19 ADJUST 未被锁拦：$R"
seed "UPDATE location SET status='AVAILABLE' WHERE id=3;"

echo "=== 2d. Q7：PG 写入 bigint 的取整行为（QA 在 PG16.14 实测，已关闭）==="
# 临时表只活在一个会话里：建表、插入、查询必须在同一次 psql 调用（小赵 C1）
Q7=$(psql -q -t -A -c "CREATE TEMP TABLE q7 (v BIGINT); INSERT INTO q7 VALUES (3.5), (2.5), (2.5::float8); SELECT string_agg(v::text, ',' ORDER BY ctid) FROM q7;") || { echo "  ✗ Q7 语句失败"; exit 2; }
[ "$Q7" = "4,3,2" ] && ok "numeric 3.5→4、2.5→3（四舍五入），float8 2.5→2（银行家舍入）→ 应用层只绑定整数" \
                  || bad "Q7 取整结果 = $Q7（期望 4,3,2）"

echo "=== 2g. docs/10 退货与异常：异常单 I1/I2、A2 键、FAILOVER_GAP、RTN milli、A1/A3/A4 ==="
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1953,2,'LOT-RTN-1953','2026-10-31','2026-10-14');"   # #5 自有批次：避开 #2 N-1/N-2 库存行维度（uq_stock_dim）
expect_allow "10 准备：异常码字典 RETURN_COUNT_DIFF / FAILOVER_GAP" "INSERT INTO exception_code (code,name,action,liability) VALUES ('RETURN_COUNT_DIFF','拒收回仓清点差异','ADJUST','CARRIER'),('FAILOVER_GAP','故障切换丢单','NONE','WAREHOUSE');"
expect_allow "10 拒收回仓差异异常单（key=POD:1610:0，司机报 5000，仓点 4000）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (100,'EXC-100',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000001',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);"
expect_block "10 同一来源业务键重复建异常单" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (101,'EXC-101',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000002',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7);" "uq_exc_src"
expect_block "10 差异列必须 = 实点 − 声称" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (102,'EXC-102',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1612:0','0000000000000000000000000000000000000000000000000000000000000003',1,1,5000,4000,1000,'2026-10-15 12:00:00',7);" "ck_exc_diff"
expect_block "10 I1 异常码不在字典（外键）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (103,'EXC-103',1,'NO_SUCH_CODE','DELIVERY_RETURN','POD:1613:0','0000000000000000000000000000000000000000000000000000000000000004',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);" "exception_case_exception_code_fkey"
expect_block "10 I1 来源类型非法" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (104,'EXC-104',1,'RETURN_COUNT_DIFF','BOGUS','X:1','0000000000000000000000000000000000000000000000000000000000000005',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);" "ck_exc_src_type"
expect_block "10 source_hash 不是 64 位小写 hex" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (105,'EXC-105',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1614:0','h1',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);" "ck_exc_hash"
expect_block "10 source_hash 大写" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (106,'EXC-106',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1615:0','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);" "ck_exc_hash"
expect_block "10 关闭异常必须有处置结论和处理人" "UPDATE exception_case SET status='RESOLVED' WHERE id=100;" "ck_exc_close"
expect_block "10 异常单非法状态" "UPDATE exception_case SET status='DONE' WHERE id=100;" "ck_exc_status"
expect_allow "10 OPEN → RESOLVED（ACCEPT_COUNT）" "UPDATE exception_case SET status='RESOLVED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=100;"
expect_block "10 I2 RESOLVED 后改实点（同时改差异，ck_exc_diff 仍成立）" "UPDATE exception_case SET counted_qty_milli=5000, diff_qty_milli=0 WHERE id=100;" "exc_immutable"
expect_block "10 I2 RESOLVED → OPEN" "UPDATE exception_case SET status='OPEN' WHERE id=100;" "exc_state_forward_only"
expect_allow "10 RESOLVED → CLOSED" "UPDATE exception_case SET status='CLOSED', closed_at='2026-10-15 12:00:00' WHERE id=100;"
expect_block "10 I2 CLOSED → OPEN" "UPDATE exception_case SET status='OPEN' WHERE id=100;" "exc_state_forward_only"
expect_block "10 I2 CLOSED 后改声称数" "UPDATE exception_case SET claimed_qty_milli=4000, diff_qty_milli=0 WHERE id=100;" "exc_immutable"
expect_allow "10 A2 首签差异单 POD:1611:0" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (110,'EXC-110',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:0','000000000000000000000000000000000000000000000000000000000000000a',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7);"
expect_allow "10 A2 更正后先取消旧单（X5）" "UPDATE exception_case SET status='CANCELLED' WHERE id=110;"
expect_block "10 A2 已取消的旧键仍占位（uq_exc_src 不变，不能复用旧键）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (111,'EXC-111',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:0','000000000000000000000000000000000000000000000000000000000000000b',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7);" "uq_exc_src"
expect_allow "10 A2 更正后新键 POD:1611:1 建单成功" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (112,'EXC-112',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:1','000000000000000000000000000000000000000000000000000000000000000c',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7);"
expect_block "10 I2 CANCELLED → OPEN" "UPDATE exception_case SET status='OPEN' WHERE id=110;" "exc_state_forward_only"
expect_allow "10 FAILOVER_GAP 第一次故障 FG:1:ERP:SO-1" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (120,'EXC-120',1,'FAILOVER_GAP','FAILOVER_GAP','FG:1:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000014',1,1,0,0,0,'2026-10-15 12:00:00',7);"
expect_allow "10 FAILOVER_GAP 同一单第二次故障 FG:2:ERP:SO-1 不撞键" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (121,'EXC-121',1,'FAILOVER_GAP','FAILOVER_GAP','FG:2:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000015',1,1,0,0,0,'2026-10-15 12:00:00',7);"
expect_block "10 FAILOVER_GAP 同一次故障同一单重复" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (122,'EXC-122',1,'FAILOVER_GAP','FAILOVER_GAP','FG:1:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000016',1,1,0,0,0,'2026-10-15 12:00:00',7);" "uq_exc_src"
expect_block "10 异常码字典责任方取值" "INSERT INTO exception_code (code,name,action,liability) VALUES ('X','x','NONE','NOBODY');" "ck_exc_liab"
expect_allow "10 准备：RTN 单头 8001（第 3 篇 inbound_order，order_type=RETURN，source=WMS_DELIVERY）" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8001,'RTN-8001',1,'RETURN','WMS_DELIVERY','POD-1610','RECEIVING','2026-10-15');"
expect_block "10 ALTER ck_inb_rtn_src：RETURN 单来源不在白名单" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8002,'RTN-8002',1,'RETURN','WMS','X-1','RECEIVING','2026-10-15');" "ck_inb_rtn_src"
expect_allow "10 I3 RTN 行 milli 列（实点 4000；声称数在异常单 / 预约行，不在 inbound_line）" "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (8101,8001,1,2,'KG',4000);"
expect_block "10 I3 质检合格+不合格 > 实点" "UPDATE inbound_line SET qc_passed_qty_milli=3000, qc_failed_qty_milli=1001 WHERE id=8101;" "ck_inbl_qc"
expect_block "10 I3 负的实点" "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (8102,8001,2,2,'KG',-1);" "ck_inbl_qc"
expect_allow "10 A3 准备：RTN 收货后 RETURN_QC 系统冻结 4000（source=QC/RTN 8001，operator=0）" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (1960,1,3,2,1953,'KG',4000,4000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (60,1960,'RETURN_QC','RETURN_QC','QC',8001,'RQC:8101',4000,0,'HELD',0); COMMIT;"
expect_block "10 A3 退货待检挂成 QUALITY 人工冻结（RETURN_QC 必须系统冻结）" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (61,1960,'RETURN_QC','RETURN_QC','QC',8001,'RQC:8101b',1000,0,'HELD',7);" "ck_hold_retqc"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "10 A3 人工解冻路径（只放行 QUALITY/MANUAL）对 RETURN_QC → 40933 rowcount=0" || bad "10 A3 人工解冻路径（只放行 QUALITY/MANUAL）对 RETURN_QC → 40933：$R（期望 UPDATE 0）"
expect_allow "10 A4 质检合格：qc_passed +1000 与 release_qc_hold 1000 同事务、同 op_key QCR:8101:1" "BEGIN; UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli + 1000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 1000 <= received_qty_milli; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (60,60,'QCR:8101:1',1000); UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 1960 AND quality_hold_qty_milli >= 1000; COMMIT;"
expect_block "10 A4 重放同一 op_key（Key 过期后再提交）整事务回滚" "BEGIN; UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli + 1000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 1000 <= received_qty_milli; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (61,60,'QCR:8101:1',1000); UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 1960 AND quality_hold_qty_milli >= 1000; COMMIT;" "uq_hr_op"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8002 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500")
[ "$R" = "UPDATE 0" ] && ok "10 A4 release_qc_hold 新签名：inbound_order_id 与冻结 source_id 不符（8002≠8001）→ 40930 rowcount=0" || bad "10 A4 release_qc_hold 新签名：inbound_order_id 与冻结 source_id 不符（8002≠8001）→ 40930：$R（期望 UPDATE 0）"
R=$(psql -t -A -c "SELECT l.qc_passed_qty_milli||'/'||h.released_qty_milli||'/'||s.quality_hold_qty_milli FROM inbound_line l, stock_hold h, stock s WHERE l.id=8101 AND h.id=60 AND s.id=1960")
[ "$R" = "1000/1000/3000" ] && ok "10 A4 重放后 qc_passed/已释放/quality_hold（只记一次、只解一次） = $R" || bad "10 A4 重放后 qc_passed/已释放/quality_hold（只记一次、只解一次） = $R（期望 1000/1000/3000）"
expect_block "10 A1 不合格转 SCRAP_PENDING 不能挂质检来源（必须挂报损单）" "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND released_qty_milli = 1000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (62,1960,'SCRAP_PENDING','SCRAP','QC',8001,'CVT:60:1',3000,0,'HELD',0); COMMIT;" "ck_hold_scrap"
expect_allow "10 A1 先建 DRAFT 报损单 9201，再 convert_hold(qty=3000) RETURN_QC → SCRAP_PENDING（子明细 from_hold_id=60）（source=SCRAP/9201）" "BEGIN; UPDATE inbound_line SET qc_failed_qty_milli = qc_failed_qty_milli + 3000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 3000 <= received_qty_milli; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND released_qty_milli = 1000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (63,1960,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:60:1',3000,0,'HELD',0,60); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 1960 AND quality_hold_qty_milli >= 3000; COMMIT;"
R=$(psql -t -A -c "SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=1960")
[ "$R" = "0/3000/1000" ] && ok "10 A1 转后 quality/hold/available = $R" || bad "10 A1 转后 quality/hold/available = $R（期望 0/3000/1000）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 63 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "10 A1 人工解冻路径对转入的 SCRAP_PENDING → 40933 rowcount=0" || bad "10 A1 人工解冻路径对转入的 SCRAP_PENDING → 40933：$R（期望 UPDATE 0）"

expect_allow "10 L1 准备：异常单 140 / 141（OPEN）" "BEGIN; INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (140,'EXC-140',1,'RETURN_COUNT_DIFF','MANUAL','M:140','0000000000000000000000000000000000000000000000000000000000000082',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7); INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (141,'EXC-141',1,'RETURN_COUNT_DIFF','MANUAL','M:141','0000000000000000000000000000000000000000000000000000000000000083',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7); COMMIT;"
expect_block "10 L1 OPEN → CLOSED（跳过 RESOLVED）" "UPDATE exception_case SET status='CLOSED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=141;" "exc_state_forward_only"
expect_allow "10 L1 OPEN → PROCESSING" "UPDATE exception_case SET status='PROCESSING', assignee_id=8 WHERE id=140;"
expect_block "10 L1 PROCESSING → CLOSED（跳过 RESOLVED）" "UPDATE exception_case SET status='CLOSED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=140;" "exc_state_forward_only"
expect_block "10 建议 1 处置结论取值非法" "UPDATE exception_case SET resolution='WHATEVER' WHERE id=141;" "ck_exc_resol"
expect_block "10 建议 1 报损处置缺报损单号" "UPDATE exception_case SET status='RESOLVED', resolution='SCRAP', closed_by=8 WHERE id=140;" "ck_exc_resdoc"
expect_allow "10 L1 PROCESSING → RESOLVED（SCRAP，带单号）" "UPDATE exception_case SET status='RESOLVED', resolution='SCRAP', resolution_doc='SCR-1', closed_by=8 WHERE id=140;"
expect_block "10 L1 RESOLVED → PROCESSING（已解决不能退回）" "UPDATE exception_case SET status='PROCESSING' WHERE id=140;" "exc_state_forward_only"
expect_block "10 L1 RESOLVED 后改实点（借道重开改数被堵）" "UPDATE exception_case SET counted_qty_milli=5000, diff_qty_milli=0 WHERE id=140;" "exc_immutable"
expect_block "10 L2 RESOLVED 后改处置结论" "UPDATE exception_case SET resolution='NO_ACTION', resolution_doc=NULL WHERE id=140;" "exc_immutable"
expect_block "10 L2 RESOLVED 后改责任方" "UPDATE exception_case SET liable_party='CARRIER' WHERE id=140;" "exc_immutable"
expect_allow "10 L2 RESOLVED 下首次写 closed_at" "UPDATE exception_case SET closed_at='2026-10-15 13:00:00' WHERE id=140;"
expect_block "10 L2 closed_at 只能写一次" "UPDATE exception_case SET closed_at='2026-10-16 13:00:00' WHERE id=140;" "exc_immutable"
expect_block "10 L2 CLOSED 后改处置结论 / 清单号" "UPDATE exception_case SET resolution='NO_ACTION', resolution_doc=NULL WHERE id=100;" "exc_immutable"
expect_block "10 L2 CLOSED 后改责任方" "UPDATE exception_case SET liable_party='CARRIER' WHERE id=100;" "exc_immutable"
expect_block "10 L2 CLOSED 后改关闭人" "UPDATE exception_case SET closed_by=99 WHERE id=100;" "exc_immutable"
expect_block "10 L2 CLOSED 后改仓库" "UPDATE exception_case SET warehouse_id=2 WHERE id=100;" "exc_immutable"
expect_block "10 L2 CLOSED 后只改 version 也不行" "UPDATE exception_case SET version=version+1 WHERE id=100;" "exc_immutable"
expect_block "10 L2 建单后改仓库（OPEN）" "UPDATE exception_case SET warehouse_id=2 WHERE id=141;" "exc_immutable"
expect_block "10 L2 建单后改异常码" "UPDATE exception_case SET exception_code='FAILOVER_GAP' WHERE id=141;" "exc_immutable"
expect_block "10 L2 建单后改上报人" "UPDATE exception_case SET reporter_id=99 WHERE id=141;" "exc_immutable"
expect_block "10 L2 建单后改单号" "UPDATE exception_case SET code='EXC-X' WHERE id=141;" "exc_immutable"
expect_block "10 L3 DELETE 已关闭异常单（去重键不能被释放）" "DELETE FROM exception_case WHERE id=100;" "exc_no_delete"
expect_block "10 L3 DELETE 已取消异常单" "DELETE FROM exception_case WHERE id=110;" "exc_no_delete"
expect_allow "10 质检单来源 SCRAP_MISREPORT（第 9 篇交接 / 质检误报回转）" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8010,'RTN-10',1,'RETURN','SCRAP_MISREPORT','APR-WHSH01-20261015-000001','CREATED','2026-10-15');"
expect_block "10 质检单来源拼错（SCRAP_MISREPORTX）" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8011,'RTN-11',1,'RETURN','SCRAP_MISREPORTX','APR-WHSH01-20261015-000002','CREATED','2026-10-15');" "ck_inb_rtn_src"
expect_allow "10 异常单来源 SCRAP_MISREPORT" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (142,'EXC-142',1,'RETURN_COUNT_DIFF','SCRAP_MISREPORT','APR-WHSH01-20261015-000001','0000000000000000000000000000000000000000000000000000000000000084',1,1,0,0,0,'2026-10-15 12:00:00',7);"
# 叠加 #16 的 fk_dretl_exc（delivery_return_line → exception_case）后，PG 会先以外键拒绝 TRUNCATE（报错不再是 exc_no_delete）；
# 两种拦法都算通过，再核对行数未变（与 02 §C5、12 的 TRUNCATE 断言同一写法）
_EXC0=$(psql -t -A -c "SELECT count(*) FROM exception_case")
OUT=$(psql_capture "TRUNCATE exception_case;")
case "$OUT" in
  *"exc_no_delete"*|*"cannot truncate a table referenced in a foreign key constraint"*) ok "10 L3 PG TRUNCATE 异常单被拦（守卫或 #16 外键）";;
  *) bad "10 L3 TRUNCATE 异常单未被拦：$OUT";;
esac
_EXC1=$(psql -t -A -c "SELECT count(*) FROM exception_case")
[ "$_EXC1" = "$_EXC0" ] && ok "10 TRUNCATE 异常单：行数不变（$_EXC0）" || bad "10 TRUNCATE 异常单后行数变化：$_EXC0 → $_EXC1"
expect_allow "10 STORE_RETURN 门店退货回仓 RTN" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8002,'RTN-2',1,'RETURN','STORE_RETURN','ST01:R-001','CREATED','2026-10-15');"
expect_block "10 STORE_RETURN 之外的未登记退货来源" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8003,'RTN-3',1,'RETURN','WHATEVER','X-1','CREATED','2026-10-15');" "ck_inb_rtn_src"
expect_allow "10 非退货入库单不受退货来源 CHECK 约束" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8004,'PO-1',1,'PURCHASE','ERP_X','PO-001','CREATED','2026-10-15');"
expect_allow "10 STORE_RETURN 入库后 RETURN_QC 系统冻结（source=QC/RTN 8002）" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (70,1,1,2,1953,'KG',2000,2000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (70,70,'RETURN_QC','RETURN_QC','QC',8002,'RQC:8201',2000,0,'HELD',0); COMMIT;"
expect_block "10 STORE_RETURN 不走 RETURN_PENDING（挂质检来源被拦）" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (71,70,'RETURN_PENDING','RETURN_PENDING','QC',8002,'X71',1000,0,'HELD',0);" "ck_hold_return"
expect_block "10 STORE_RETURN 冻结不能是人工冻结（operator≠0）" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (72,70,'RETURN_QC','RETURN_QC','QC',8002,'X72',1000,0,'HELD',7);" "ck_hold_retqc"
expect_allow "10 STORE_RETURN 清点差异异常单（source_type=STORE_RETURN）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (130,'EXC-130',1,'RETURN_COUNT_DIFF','STORE_RETURN','RTN-2:1','000000000000000000000000000000000000000000000000000000000000001e',2,3,3000,2000,-1000,'2026-10-15 12:00:00',7);"

expect_allow "10 盲收 RTN 来源 STORE_BLIND" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8020,'RTN-20',1,'RETURN','STORE_BLIND','BRC-20261015-000001','CREATED','2026-10-15');"
expect_block "10 RTN 来源拼错 STORE_BLINDX" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8021,'RTN-21',1,'RETURN','STORE_BLINDX','BRC-20261015-000009','CREATED','2026-10-15');" "ck_inb_rtn_src"
expect_allow "10 盲收异常单（BLIND_RETURN，截止 = 建单 + 48h）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (150,'EXC-150',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:1','0000000000000000000000000000000000000000000000000000000000000000',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-17 10:00:00','UNKNOWN');"
expect_block "10 盲收异常单缺截止时间" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00',NULL,'UNKNOWN');" "ck_exc_blind"
expect_block "10 盲收异常单截止 ≠ +48h" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-16 10:00:00','UNKNOWN');" "exc_blind_deadline"
expect_block "10 liable_party 取值非法（SUPPLIER 不在四值内）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-17 10:00:00','SUPPLIER');" "ck_exc_liable"
R=$(psql -t -A -c "SELECT liable_party FROM exception_case WHERE id=100")
[ "$R" = "UNKNOWN" ] && ok "10 liable_party 默认 UNKNOWN = $R" || bad "10 liable_party 默认 UNKNOWN = $R（期望 UNKNOWN）"
expect_allow "10 liable_party 改为 STORE（处理中）" "UPDATE exception_case SET liable_party='STORE' WHERE id=150;"
expect_allow "10 截止往后延（+24h，主管）" "UPDATE exception_case SET link_deadline_at='2026-10-18 10:00:00' WHERE id=150;"
expect_block "10 截止往前改" "UPDATE exception_case SET link_deadline_at='2026-10-17 09:00:00' WHERE id=150;" "exc_deadline_backward"
expect_block "10 截止清空" "UPDATE exception_case SET link_deadline_at=NULL WHERE id=150;" "exc_deadline_backward"
expect_allow "10 盲收记录（容器码 + 原因码 + 照片）" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (1,'BRC-20261015-000001',1,1,3000,'ST001','CTN-001','DAMAGED','["F1","F2"]',8020,150,'IDEM-BLIND-1',7);"
expect_block "10 盲收缺容器码" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,'ST001','DAMAGED','[]',8020,150,'IDEM-BLIND-2',7);" "container_code"
expect_block "10 盲收缺原因码" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,'ST001','CTN-002','[]',8020,150,'IDEM-BLIND-2',7);" "reason_code"
expect_block "10 盲收容器码空串" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'','DAMAGED','[]',8020,150,'IDEM-BLIND-2',7);" "ck_rbr_ctn"
expect_block "10 盲收原因码不在枚举" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'CTN-002','BROKEN','[]',8020,150,'IDEM-BLIND-2',7);" "ck_rbr_reason"
expect_block "10 盲收同 op_key 重放" "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'CTN-002','DAMAGED','[]',8020,150,'IDEM-BLIND-1',7);" "uq_rbr_op"
expect_block "10 盲收记录不可改" "UPDATE return_blind_receipt SET qty_milli=1000 WHERE id=1;" "rbr_immutable"
expect_block "10 盲收记录不可删" "DELETE FROM return_blind_receipt WHERE id=1;" "rbr_immutable"
expect_allow "10 退货预约建单（门店 ST001）" "INSERT INTO return_reservation (id,code,warehouse_id,store_code,outbound_order_id,created_by) VALUES (1,'RSV-20261015-000001',1,'ST001',1,21);"
expect_allow "10 预约行（原因码 + 容器码）" "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (1,1,1,1,2000,'QUALITY','CTN-101');"
expect_block "10 预约行缺原因码" "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,container_code) VALUES (2,1,2,1,2000,'CTN-102');" "reason_code"
expect_block "10 预约行缺容器码" "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code) VALUES (2,1,2,1,2000,'QUALITY');" "container_code"
expect_block "10 预约行原因码非法" "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (2,1,2,1,2000,'NOPE','CTN-102');" "ck_rrsl_reason"
expect_block "10 预约 RECEIVED 缺 RTN / 收货人" "UPDATE return_reservation SET status='RECEIVED' WHERE id=1;" "ck_rrsv_recv"
expect_allow "10 收货写实点" "UPDATE return_reservation_line SET received_qty_milli=2000 WHERE id=1;"
expect_block "10 实点只写一次" "UPDATE return_reservation_line SET received_qty_milli=1000 WHERE id=1;" "rrsl_locked"
expect_block "10 预约门店不可改" "UPDATE return_reservation SET store_code='ST002' WHERE id=1;" "rrsv_immutable"
expect_allow "10 预约收货 CREATED → RECEIVED（RTN 8010，随后挂 RETURN_QC）" "UPDATE return_reservation SET status='RECEIVED', rtn_inbound_id=8010, received_by=7, received_at='2026-10-15 11:00:00', version=version+1 WHERE id=1 AND status='CREATED';"
expect_block "10 预约 RECEIVED → CANCELLED" "UPDATE return_reservation SET status='CANCELLED' WHERE id=1;" "rrsv_state_forward_only"
expect_block "10 预约终态整行只读" "UPDATE return_reservation SET version=9 WHERE id=1;" "rrsv_immutable"
expect_block "10 收货后再加预约行" "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (3,1,3,1,1000,'QUALITY','CTN-103');" "rrsl_locked"
expect_block "10 收货后改预约行" "UPDATE return_reservation_line SET container_code='X' WHERE id=1;" "rrsl_locked"
expect_block "10 预约不可删" "DELETE FROM return_reservation_line WHERE id=1;" "return_no_delete"
expect_block "10 预约同号重复（SQLite 拦 REPLACE）" "INSERT INTO return_reservation (id,code,warehouse_id,store_code,outbound_order_id,created_by) VALUES (2,'RSV-20261015-000001',1,'ST001',1,21);" "uq_rrsv_code"
R=$(psql -t -A -c "UPDATE return_reservation SET status='CANCELLED' WHERE id=1 AND status='CREATED'")
[ "$R" = "UPDATE 0" ] && ok "10 预约 version 条件更新（旧状态 CREATED）0 行 rowcount=0" || bad "10 预约 version 条件更新（旧状态 CREATED）0 行：$R"

echo "=== 2e-exc1. docs/10 × 17：加工损耗未获批部分转异常（source_type=PROCESS_LOSS）==="
expect_allow "10 PROCESS_LOSS 准备：异常码 PROCESS_LOSS_UNSETTLED" "INSERT INTO exception_code (code,name,action,liability) VALUES ('PROCESS_LOSS_UNSETTLED','加工损耗未获批部分','ADJUST','WAREHOUSE');"
expect_allow "10 PROCESS_LOSS：17 损耗行 1757 审批驳回/过期，未批 0.400 转异常（key=PRCL:1757）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1900,'EXC-1900',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1757','0000000000000000000000000000000000000000000000000000000000000130',1,1,400,0,-400,'2026-10-15 12:00:00',0);"
R=$(psql -q -t -A -c "BEGIN; WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1911,'EXC-1911',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1757','0000000000000000000000000000000000000000000000000000000000000911',1,1,400,0,-400,'2026-10-15 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'PROCESS_LOSS' DO NOTHING RETURNING code), ob AS (INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9911,'wms.process.loss_settled','PRC-SH01-20261015-000017','{\"result\":\"REJECTED\"}' FROM ins RETURNING id) SELECT COALESCE((SELECT code FROM ins),(SELECT code FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='PRCL:1757')); COMMIT;")
[ "$R" = "EXC-1900" ] && ok "10 PROCESS_LOSS 同一损耗行再次转异常（回调重放）→ 不报错，返回已有 exception_no $R，不写 outbox" || bad "10 PROCESS_LOSS 重放幂等返回：$R（期望 EXC-1900）"
# 第二道保险（部分唯一索引 uq_exc_pl_key）单会话顺序模拟：主守卫（17 损耗行条件更新）若被绕过，两方都走到建单，后到者仍拿到同一 exception_no
#（PG 两会话真并发竞态由小玛丽负责，不在本段）
RA=$(psql -q -t -A -c "BEGIN; WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1921,'EXC-1921',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1758','0000000000000000000000000000000000000000000000000000000000000921',1,1,400,0,-400,'2026-10-15 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'PROCESS_LOSS' DO NOTHING RETURNING code), ob AS (INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9921,'wms.process.loss_settled','PRC-SH01-20261015-000017','{}' FROM ins RETURNING id) SELECT COALESCE((SELECT code FROM ins),(SELECT code FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='PRCL:1758')); COMMIT;")
RB=$(psql -q -t -A -c "BEGIN; WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1922,'EXC-1922',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1758','0000000000000000000000000000000000000000000000000000000000000922',1,1,400,0,-400,'2026-10-15 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'PROCESS_LOSS' DO NOTHING RETURNING code), ob AS (INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9922,'wms.process.loss_settled','PRC-SH01-20261015-000017','{}' FROM ins RETURNING id) SELECT COALESCE((SELECT code FROM ins),(SELECT code FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='PRCL:1758')); COMMIT;")
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='PRCL:1758') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9911,9921,9922))")
[ "$RA" = "EXC-1921" ] && [ "$RB" = "EXC-1921" ] && [ "$R" = "1/1" ] && ok "10×17 审批回调与过期任务处理同一损耗行（顺序模拟，索引兜底）：异常单 1 张、两方都返回 $RA、loss_settled 1 条" || bad "10×17 转异常兜底：A=$RA B=$RB 异常单/事件=$R（期望 EXC-1921 EXC-1921 1/1）"
expect_block "10 PROCESS_LOSS source_key 不是 PRCL:{损耗行 id}" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1902,'EXC-1902',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','POD:1757:0','0000000000000000000000000000000000000000000000000000000000000132',1,1,400,0,-400,'2026-10-15 12:00:00',0);" "ck_exc_pl_key"
expect_block "10 PROCESS_LOSS 缺 SKU" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1903,'EXC-1903',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1759','0000000000000000000000000000000000000000000000000000000000000133',0,1,400,0,-400,'2026-10-15 12:00:00',0);" "ck_exc_pl_key"
expect_block "10 PROCESS_LOSS 键带前导零 PRCL:01757" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1905,'EXC-1905',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:01757','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0);" "ck_exc_pl_key"
expect_block "10 PROCESS_LOSS 键为 0（PRCL:0）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1906,'EXC-1906',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:0','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0);" "ck_exc_pl_key"
expect_block "10 PROCESS_LOSS 键非纯数字 PRCL:17a" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1907,'EXC-1907',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:17a','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0);" "ck_exc_pl_key"

echo "=== 2e-exc2. docs/10 × 18：活鲜死亡延迟扣减转异常（source_type=LIVE_DEATH，LDTH:{live_death.id}）==="
expect_allow "10 LIVE_DEATH 准备：异常码 LIVE_DEATH_UNDEDUCTED" "INSERT INTO exception_code (code,name,action,liability) VALUES ('LIVE_DEATH_UNDEDUCTED','活鲜死亡延迟扣减失败','ADJUST','WAREHOUSE');"
R=$(psql -q -t -A -c "BEGIN; WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1931,'EXC-1931',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:1801','0000000000000000000000000000000000000000000000000000000000000931',1,1,1000,0,-1000,'2026-10-15 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'LIVE_DEATH' DO NOTHING RETURNING code) SELECT COALESCE((SELECT code FROM ins),(SELECT code FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:1801')); COMMIT;")
[ "$R" = "EXC-1931" ] && ok "10 LIVE_DEATH：18 延迟扣减任务 deduct_status=EXCEPTION 转异常（LDTH:1801）→ $R" || bad "10 LIVE_DEATH 建单：$R"
R=$(psql -q -t -A -c "BEGIN; WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1932,'EXC-1932',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:1801','0000000000000000000000000000000000000000000000000000000000000932',1,1,1000,0,-1000,'2026-10-15 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'LIVE_DEATH' DO NOTHING RETURNING code) SELECT COALESCE((SELECT code FROM ins),(SELECT code FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:1801')); COMMIT;")
[ "$R" = "EXC-1931" ] && ok "10 LIVE_DEATH 重放同一死亡登记 → 不报错，返回已有 $R" || bad "10 LIVE_DEATH 重放：$R（期望 EXC-1931）"
R=$(psql -t -A -c "SELECT count(*) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:1801'")
[ "$R" = "1" ] && ok "10 LIVE_DEATH 重放后异常单仍 1 张" || bad "10 LIVE_DEATH 异常单数 $R"
R=$(psql -t -A -c "SELECT string_agg(c.relname||':'||i.indisunique||':'||pg_get_expr(i.indpred,i.indrelid),' ' ORDER BY c.relname) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname IN ('uq_exc_ldth_key','uq_exc_pl_key') AND i.indrelid='public.exception_case'::regclass AND i.indnatts=1 AND i.indkey[0]=(SELECT attnum FROM pg_attribute WHERE attrelid='public.exception_case'::regclass AND attname='source_key')")
[ "$R" = "uq_exc_ldth_key:true:((source_type)::text = 'LIVE_DEATH'::text) uq_exc_pl_key:true:((source_type)::text = 'PROCESS_LOSS'::text)" ] && ok "10 ON CONFLICT 仲裁索引按名存在：uq_exc_ldth_key / uq_exc_pl_key 为 source_key 单列部分唯一（重复键断言不再只靠 uq_exc_src）" || bad "10 uq_exc_ldth_key/uq_exc_pl_key 定义不符：$R"
expect_block "10 LIVE_DEATH source_key 不是 LDTH:{live_death.id}" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1933,'EXC-1933',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','PRCL:1801','0000000000000000000000000000000000000000000000000000000000000933',1,1,1000,0,-1000,'2026-10-15 12:00:00',0);" "ck_exc_ldth_key"
expect_block "10 LIVE_DEATH 缺 SKU" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1934,'EXC-1934',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:1802','0000000000000000000000000000000000000000000000000000000000000934',0,1,1000,0,-1000,'2026-10-15 12:00:00',0);" "ck_exc_ldth_key"
expect_block "10 LIVE_DEATH 键为 0（LDTH:0）" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1935,'EXC-1935',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:0','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0);" "ck_exc_ldth_key"
expect_block "10 LIVE_DEATH 键带前导零 LDTH:007" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1936,'EXC-1936',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:007','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0);" "ck_exc_ldth_key"
expect_block "10 LIVE_DEATH 旧前缀 LVD:1801" "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1937,'EXC-1937',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LVD:1801','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0);" "ck_exc_ldth_key"

echo "=== 2e-exc3. search_path 固定（pg_catalog, public）：目录断言 + 同名表劫持 + 变异检查（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;

CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.return_reservation (id BIGINT, status TEXT);
INSERT INTO hj_evil.return_reservation VALUES (999999,'CREATED');
SET LOCAL search_path = public;
DO $hj$ BEGIN INSERT INTO public.return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,container_code) VALUES (19902,999999,1,1,2000,'CTN-HJ'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,container_code) VALUES (19902,999999,1,1,2000,'CTN-HJ'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_exc_forward','trg_exc_no_delete','trg_exc_blind_ins','trg_rrsv_guard','trg_rrsl_guard','trg_rtn10_no_delete','trg_rbr_immutable')), true);
ALTER FUNCTION public.trg_rrsl_guard() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_exc_forward','trg_exc_no_delete','trg_exc_blind_ins','trg_rrsv_guard','trg_rrsl_guard','trg_rtn10_no_delete','trg_rbr_immutable')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,container_code) VALUES (19902,999999,1,1,2000,'CTN-HJ'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/7" ] && ok "本 PR 新增/重定义的 7 个 PL/pgSQL 函数 proconfig 都含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "search_path 目录断言：缺失/总数 = $HC0（期望 0/7）"
[ -n "$HB" ] && [ "$HF" = "$HB" ] && ok "劫持：wms_app 在自建 schema hj_evil 建同名表 return_reservation 并置于 search_path 首位，trg_rrsl_guard() 仍读 public（结果与无劫持一致：$HB）" || bad "劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/7" ] && [ "$HM" != "$HB" ] && ok "变异检查：RESET trg_rrsl_guard() 的 search_path 后，目录断言变红（$HC1）且劫持生效（$HM），两条断言都能抓到" || bad "变异检查没变红：目录=$HC1 劫持后=$HM 基准=$HB"
echo "=== 2f. docs/09 效期与损耗：报损单状态前进、交接单不可撤回、来源/原因 CHECK、外键 ==="
expect_allow "09 报损单建单（DRAFT，来源=效期扫描 501）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (100,'SCR-1',1,'EXPIRY_SCAN',501,'EXPIRED','2026-10-15',7);"
expect_block "09 同一来源重复建有效报损单" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (101,'SCR-2',1,'EXPIRY_SCAN',501,'EXPIRED','2026-10-15',7);" "uq_scr_source"
expect_block "09 I3 来源类型非法" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (109,'SCR-9',1,'WHATEVER',9,'EXPIRED','2026-10-15',7);" "ck_scr_src_type"
expect_block "09 I3 原因码非法" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (109,'SCR-9',1,'MANUAL',9,'ANY','2026-10-15',7);" "ck_scr_reason"
expect_block "09 报损单非法状态值（建单）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (109,'SCR-9',1,'MANUAL',9,'OTHER','2026-10-15',7,'DONE');" "ck_scr_status"
expect_allow "09 DRAFT 单下加报损行" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (100,100,1,14,1,1,5000,0,'POST_OUT');"
expect_block "09 报损行数量 0" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (101,100,2,14,1,1,0,0,'POST_OUT');" "ck_scrl_qty"
expect_block "09 I3 报损行挂到不存在的报损单（外键）" "UPDATE scrap_line SET scrap_id=999 WHERE id=100;" "scrap_line_scrap_id_fkey"
expect_block "09 I3 新增报损行挂到不存在的报损单" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (103,999,1,14,1,1,1000,0,'POST_OUT');" "scrap_line_locked"
expect_allow "09 S1 DRAFT → PENDING_APPROVAL" "UPDATE scrap_order SET status='PENDING_APPROVAL', version=version+1 WHERE id=100 AND status='DRAFT';"
expect_block "09 I3 提交后不能再加行" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (104,100,2,14,1,1,1000,0,'POST_OUT');" "scrap_line_locked"
expect_block "09 I3 提交后不能改量" "UPDATE scrap_line SET scrap_qty_milli=4000 WHERE id=100;" "scrap_line_locked"
expect_block "09 报损审批 SoD（审批人=申请人）" "UPDATE scrap_order SET approver_id=7, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=100;" "ck_scr_sod"
expect_allow "09 S2 审批（审批人 8）" "UPDATE scrap_order SET approver_id=8, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=100 AND status='PENDING_APPROVAL';"
expect_block "09 I3 APPROVED → DRAFT（跳回）" "UPDATE scrap_order SET status='DRAFT' WHERE id=100;" "scrap_state_forward_only"
expect_allow "09 S3 APPROVED → POSTED" "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:01:00' WHERE id=100 AND status='APPROVED';"
expect_block "09 I3 POSTED → DRAFT" "UPDATE scrap_order SET status='DRAFT' WHERE id=100;" "scrap_state_forward_only"
expect_block "09 I3 POSTED → CANCELLED" "UPDATE scrap_order SET status='CANCELLED' WHERE id=100;" "scrap_state_forward_only"
expect_block "09 I3 POSTED 单下插 POST_OUT 且 hold_id=0 的行" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (105,100,9,14,1,1,1000,0,'POST_OUT');" "scrap_line_locked"
expect_block "09 报损单非法状态值（更新）" "UPDATE scrap_order SET status='DONE' WHERE id=100;" "scrap_state_forward_only"
expect_allow "09 交接报损单 DRAFT（RETURN_HANDOVER，source_id=待回库 701）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (102,'SCR-3',1,'RETURN_HANDOVER',701,'DAMAGED','2026-10-15',8);"
expect_block "09 同一待回库记录重复交接报损" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (103,'SCR-4',1,'RETURN_HANDOVER',701,'DAMAGED','2026-10-15',8);" "uq_scr_source"
expect_block "09 交接单不许取消（DRAFT → CANCELLED）" "UPDATE scrap_order SET status='CANCELLED' WHERE id=102;" "scrap_handover_no_revoke"
expect_allow "09 交接单提交" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=102 AND status='DRAFT';"
expect_block "09 交接单不许撤回（PENDING_APPROVAL → DRAFT，→ 40930）" "UPDATE scrap_order SET status='DRAFT' WHERE id=102;" "scrap_handover_no_revoke"
expect_block "09 交接单不许驳回到 REJECTED" "UPDATE scrap_order SET status='REJECTED' WHERE id=102;" "scrap_handover_no_revoke"
expect_block "09 来源不可改（交接单改成 MANUAL 绕过）" "UPDATE scrap_order SET source_type='MANUAL' WHERE id=102;" "scrap_state_forward_only"
expect_allow "09 准备：交接单 102 / 手工单 104 各挂一条 SCRAP_PENDING" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (80,1,1,2,4,'KG',4000,4000); INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (104,'SCR-5',1,'MANUAL',0,'DAMAGED','2026-10-15',7); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (80,80,'SCRAP_PENDING','SCRAP','SCRAP',102,'CVT:79',2000,0,'HELD',0); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (81,80,'SCRAP_PENDING','SCRAP','SCRAP',104,'SCRH:81',2000,0,'HELD',0); COMMIT;"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 102 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 102 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))")
[ "$R" = "UPDATE 0" ] && ok "09 release_scrap_hold(REVOKED) 对交接单拒绝（→ 40930） rowcount=0" || bad "09 release_scrap_hold(REVOKED) 对交接单拒绝（→ 40930）：$R（期望 UPDATE 0）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 81 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 104 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 104 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))")
[ "$R" = "UPDATE 1" ] && ok "09 release_scrap_hold(REVOKED) 对手工单放行 rowcount=1" || bad "09 release_scrap_hold(REVOKED) 对手工单放行：$R（期望 UPDATE 1）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "09 人工解冻路径对 SCRAP_PENDING（→ 40933） rowcount=0" || bad "09 人工解冻路径对 SCRAP_PENDING（→ 40933）：$R（期望 UPDATE 0）"
expect_allow "09 A1 质检不合格报损单 DRAFT（RETURN_QC，source_id=退货行 8101）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (105,'SCR-6',1,'RETURN_QC',8101,'QC_REJECT','2026-10-15',9);"

expect_block "09 Q8 交接单作废必须带 SCRAP_MISREPORT 审批单号" "UPDATE scrap_order SET status='VOIDED' WHERE id=102;" "ck_scr_void"
expect_block "09 Q8 非交接单不能作废（手工单 104）" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000009' WHERE id=104;" "scrap_state_forward_only"
expect_block "09 Q8 误报回转缺审批（ck_hold_approval）" "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,is_reversal) VALUES (82,80,'RETURN_QC','RETURN_QC','QC',8301,'CVT:80',2000,0,'HELD',0,true); UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, quality_hold_qty_milli = quality_hold_qty_milli + 2000, version = version + 1 WHERE id = 80 AND hold_qty_milli >= 2000; UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000001', version=version+1 WHERE id=102 AND status='PENDING_APPROVAL'; COMMIT;" "ck_hold_approval"
expect_block "09 Q17 审批单号格式不对（APR-1）" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-1' WHERE id=102;" "ck_scr_apr_fmt"
expect_block "09 Q17 审批单号序号不足 6 位" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-12345' WHERE id=102;" "ck_scr_apr_fmt"
expect_block "09 Q17 审批单号仓库编码含小写" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-whsh01-20261015-000001' WHERE id=102;" "ck_scr_apr_fmt"
expect_block "09 Q17 审批单号日期不足 8 位" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-2026101-000001' WHERE id=102;" "ck_scr_apr_fmt"
expect_block "09 Q17 审批单号仓库编码只有 1 位" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-S-20261015-000001' WHERE id=102;" "ck_scr_apr_fmt"
expect_block "09 Q17 审批单号仓库编码超过 16 位" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-ABCDEFGHIJKLMNOPQ-20261015-000001' WHERE id=102;" "ck_scr_apr_fmt"
expect_allow "09 Q8 误报同一事务：convert_hold SCRAP_PENDING→RETURN_QC（CVT:80，审批 APR-1，新质检单 8301）+ 报损单 VOIDED" "BEGIN; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND released_qty_milli = 0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (82,80,'RETURN_QC','RETURN_QC','QC',8301,'CVT:80',2000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',true); UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, quality_hold_qty_milli = quality_hold_qty_milli + 2000, version = version + 1 WHERE id = 80 AND hold_qty_milli >= 2000; UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000001', version=version+1 WHERE id=102 AND status='PENDING_APPROVAL'; COMMIT;"
R=$(psql -t -A -c "SELECT hold_qty_milli||'/'||quality_hold_qty_milli FROM stock WHERE id=80")
[ "$R" = "2000/2000" ] && ok "09 Q8 回转后 stock 80 hold/quality（跨列挪量，可用量不变） = $R" || bad "09 Q8 回转后 stock 80 hold/quality（跨列挪量，可用量不变） = $R（期望 2000/2000）"
expect_block "09 K1 质检不合格单不许取消（DRAFT → CANCELLED，→ 40930）" "UPDATE scrap_order SET status='CANCELLED' WHERE id=105;" "scrap_handover_no_revoke"
expect_allow "09 K1/K4 准备：质检单 105 挂 SCRAP_PENDING 3000，行数量 = 冻结量" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (81,1,1,2,5,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (83,81,'SCRAP_PENDING','SCRAP','SCRAP',105,'CVT:84',3000,0,'HELD',0); INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (110,105,1,81,2,5,3000,83,'POST_OUT'); COMMIT;"
expect_block "09 K4 带冻结的行数量 ≠ 冻结余量（建行）" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (111,105,2,81,2,5,1000,83,'POST_OUT');" "scrap_line_hold_mismatch"
expect_block "09 K4 交接 / 质检 DRAFT 改数量（5000→1 式）" "UPDATE scrap_line SET scrap_qty_milli=1 WHERE id=110;" "scrap_line_hold_locked"
expect_block "09 K4 交接 / 质检 DRAFT 摘掉冻结（hold_id → 0）" "UPDATE scrap_line SET hold_id=0 WHERE id=110;" "scrap_line_hold_locked"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 83 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 105 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 105 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))")
[ "$R" = "UPDATE 0" ] && ok "09 K1 release_scrap_hold(REVOKED) 对质检单拒绝（→ 40930） rowcount=0" || bad "09 K1 release_scrap_hold(REVOKED) 对质检单拒绝（→ 40930）：$R"
expect_allow "09 K1 质检单提交" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=105 AND status='DRAFT';"
expect_block "09 K1 质检单不许撤回（→ DRAFT）" "UPDATE scrap_order SET status='DRAFT' WHERE id=105;" "scrap_handover_no_revoke"
expect_block "09 K1 质检单不许驳回（→ REJECTED）" "UPDATE scrap_order SET status='REJECTED' WHERE id=105;" "scrap_handover_no_revoke"
expect_allow "09 K1 质检判错只走 SCRAP_MISREPORT 作废（VOIDED，合法审批号）" "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000002' WHERE id=105 AND status='PENDING_APPROVAL';"
expect_block "09 K3 POSTED 单的行改 hold_id / ledger_mode" "UPDATE scrap_line SET hold_id=0, ledger_mode='NONE' WHERE id=100;" "scrap_line_locked"
expect_block "09 K3 POSTED 单的行改成本" "UPDATE scrap_line SET cost_amount=1 WHERE id=100;" "scrap_line_locked"
expect_block "09 K3 事后换申请人" "UPDATE scrap_order SET applicant_id=12 WHERE id=100;" "scrap_immutable"
expect_block "09 K3 事后换审批人" "UPDATE scrap_order SET approver_id=13 WHERE id=100;" "scrap_immutable"
expect_block "09 K3 过账时间改写" "UPDATE scrap_order SET posted_at='2026-10-16 00:00:00' WHERE id=100;" "scrap_immutable"
expect_block "09 K3 终态改原因码" "UPDATE scrap_order SET reason_code='OTHER' WHERE id=100;" "scrap_immutable"
expect_block "09 K3 改仓库" "UPDATE scrap_order SET warehouse_id=2 WHERE id=104;" "scrap_immutable"
expect_block "09 S1 建单直接写 CANCELLED" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (120,'SCR-20',1,'RETURN_HANDOVER',720,'DAMAGED','2026-10-15',8,'CANCELLED');" "scrap_insert_draft_only"
expect_block "09 S1 建单直接写 POSTED" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (121,'SCR-21',1,'MANUAL',0,'DAMAGED','2026-10-15',8,'POSTED');" "scrap_insert_draft_only"
expect_allow "09 S1 手工单 104 提交" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=104 AND status='DRAFT';"
expect_block "09 S1 审批缺 approved_at" "UPDATE scrap_order SET approver_id=8, status='APPROVED' WHERE id=104;" "ck_scr_appr"
expect_block "09 K2 DELETE 报损单" "DELETE FROM scrap_order WHERE id=102;" "scrap_no_delete"
expect_block "09 K2 DELETE POSTED 单的行" "DELETE FROM scrap_line WHERE id=100;" "scrap_no_delete"
expect_block "09 K2 PG TRUNCATE 报损行（超级用户 / 迁移脚本）" "TRUNCATE scrap_line;" "scrap_no_delete"
expect_block "09 K2 PG TRUNCATE 报损单" "TRUNCATE scrap_order CASCADE;" "scrap_no_delete"
expect_allow "09 sell_days 到期自动报损单（SELL_EXPIRED，批次 lot_id=601，系统建草稿）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (130,'SCR-30',1,'SELL_EXPIRED',601,'2026-10-15','SELL_EXPIRED','2026-10-15',0);"
expect_block "09 sell_days 同一批次同一天重复建单" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_EXPIRED',601,'2026-10-15','SELL_EXPIRED','2026-10-15',0);" "uq_scr_source"
expect_allow "09 sell_days 同一批次次日余量（退货回仓后）再建一张" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (132,'SCR-32',1,'SELL_EXPIRED',601,'2026-10-16','SELL_EXPIRED','2026-10-16',0);"
expect_allow "09 sell_days 来源与 EXPIRY_SCAN 同 source_id 互不干扰" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (133,'SCR-33',1,'EXPIRY_SCAN',601,'EXPIRED','2026-10-15',0);"
expect_block "09 sell_days 来源拼错" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_DAY_EXPIRED',602,'SELL_EXPIRED','2026-10-15',0);" "ck_scr_src_type"
expect_block "09 sell_days 原因码拼错" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_EXPIRED',602,'2026-10-15','SELL_DAYS','2026-10-15',0);" "ck_scr_reason"
expect_block "09 D3 SELL_EXPIRED 缺 source_date（默认 1970-01-01）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'SELL_EXPIRED',603,'SELL_EXPIRED','2026-10-15',0);" "ck_scr_src_date"
expect_block "09 D3 SELL_EXPIRED source_date ≠ work_date" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'SELL_EXPIRED',603,'2026-10-14','SELL_EXPIRED','2026-10-15',0);" "ck_scr_src_date"
expect_block "09 D3 非按日来源写了日期（EXPIRY_SCAN）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'EXPIRY_SCAN',603,'2026-10-15','EXPIRED','2026-10-15',7);" "ck_scr_src_date"
expect_block "09 D3 建单后改 source_date" "UPDATE scrap_order SET source_date='2026-10-17', work_date='2026-10-17' WHERE id=132;" "scrap_state_forward_only"
expect_allow "09 D3 LIVE_SHRINK 批次 605 第一天" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (140,'SCR-40',1,'LIVE_SHRINK',605,'2026-10-15','NATURAL_LOSS','2026-10-15',0);"
expect_allow "09 D3 LIVE_SHRINK 同批次次日再建" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (141,'SCR-41',1,'LIVE_SHRINK',605,'2026-10-16','NATURAL_LOSS','2026-10-16',0);"
expect_block "09 D3 LIVE_SHRINK 同批次同日重复" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (142,'SCR-42',1,'LIVE_SHRINK',605,'2026-10-15','NATURAL_LOSS','2026-10-15',0);" "uq_scr_source"
expect_block "09 D3 LIVE_SHRINK 缺 source_date" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (143,'SCR-43',1,'LIVE_SHRINK',606,'1970-01-01','NATURAL_LOSS','2026-10-15',0);" "ck_scr_src_date"
expect_block "09 D3 LIVE_DEATH 写了日期（不按日）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (144,'SCR-44',1,'LIVE_DEATH',607,'2026-10-15','OTHER','2026-10-15',0);" "ck_scr_src_date"
expect_allow "09 sell_days 系统提交（DRAFT → PENDING_APPROVAL，S1 同事务冻结 SCRAP_PENDING 即下架）" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=130 AND status='DRAFT';"
expect_block "09 sell_days 系统单也要人审（审批人 = 申请人 0）" "UPDATE scrap_order SET approver_id=0, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=130;" "ck_scr_sod"
expect_block "09 Q8 VOIDED 是终态（→ POSTED）" "UPDATE scrap_order SET status='POSTED' WHERE id=102;" "scrap_state_forward_only"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 82 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "09 Q8 回转后的 RETURN_QC 不能人工解冻（→ 40933，只能 release_qc_hold） rowcount=0" || bad "09 Q8 回转后的 RETURN_QC 不能人工解冻（→ 40933，只能 release_qc_hold）：$R"

echo "=== 2f2. docs/09 记账型来源 PROCESS_LOSS / LIVE_*（Doro P1）、加工原因码、PROCESS_LOSS 作废 ==="
R=$(psql -t -A -c "SELECT CASE WHEN pg_get_constraintdef(oid) LIKE '%''PROCESS_LOSS''%' THEN 'Y' ELSE 'N' END FROM pg_constraint WHERE conname='ck_scr_src_type'")
[ "$R" = "Y" ] && ok "09 ck_scr_src_type 含 PROCESS_LOSS（PG，对齐 00 §6.4 1d907031 登记）" || bad "09 ck_scr_src_type 缺 PROCESS_LOSS：$R"
expect_allow "09 PROCESS_LOSS 报损单（17 损耗行 1752，TRIM，记账型）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (150,'SCR-50',1,'PROCESS_LOSS',1752,'TRIM','2026-10-15',21);"
R=$(psql -t -A -c "SELECT CASE WHEN record_only THEN 'Y' ELSE 'N' END FROM scrap_order WHERE id=150")
[ "$R" = "Y" ] && ok "09 PROCESS_LOSS 自动推出 record_only = $R" || bad "09 PROCESS_LOSS 自动推出 record_only = $R（期望 Y）"
expect_block "09 record_only 不能由应用写入（生成列）" "UPDATE scrap_order SET record_only=false WHERE id=150;" "column \"record_only\" can only be updated to DEFAULT"
expect_block "09 PROCESS_LOSS 用通用原因码 NATURAL_LOSS" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'PROCESS_LOSS',1753,'NATURAL_LOSS','2026-10-15',21);" "ck_scr_reason_src"
expect_block "09 手工报损用加工原因 TRIM" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'MANUAL',0,'TRIM','2026-10-15',21);" "ck_scr_reason_src"
expect_block "09 PROCESS_LOSS 写了 source_date" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'PROCESS_LOSS',1753,'2026-10-15','TRIM','2026-10-15',21);" "ck_scr_src_date"
expect_block "09 记账型单的行挂冻结（会扣第二次）" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (150,150,1,11,1,1,2700,0,'POST_OUT');" "scrap_line_record_only"
expect_allow "09 记账型行：hold_id=0、ledger_mode=NONE" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (150,150,1,11,1,1,2700,0,'NONE');"
expect_block "09 记账型行改成出账" "UPDATE scrap_line SET ledger_mode='POST_OUT' WHERE id=150;" "scrap_line_record_only"
expect_block "09 普通单（手工）不能 DRAFT 直接 POSTED" "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=104;" "scrap_state_forward_only"
expect_allow "09 PROCESS_LOSS 容差内 DRAFT → POSTED（无人审、不出账）" "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=150 AND status='DRAFT';"
expect_block "09 PROCESS_LOSS 作废缺 void_ref" "UPDATE scrap_order SET status='VOIDED' WHERE id=150;" "ck_scr_void"
expect_block "09 void_ref 不是 17 冲回键" "UPDATE scrap_order SET status='VOIDED', void_ref='X:1' WHERE id=150;" "ck_scr_void_ref"
expect_allow "09 17 损耗改原因：POSTED → VOIDED（void_ref = PRCR 冲回键）" "UPDATE scrap_order SET status='VOIDED', void_ref='PRCR:1711:00000000-0000-4000-8000-000000001794' WHERE id=150 AND status='POSTED';"
expect_block "09 VOIDED 后不能再 POSTED" "UPDATE scrap_order SET status='POSTED' WHERE id=150;" "scrap_state_forward_only"
expect_allow "09 PROCESS_LOSS 超容差：DRAFT → PENDING_APPROVAL（随 17 PROCESS_YIELD_DEVIATION 合并审批）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (152,'SCR-52',1,'PROCESS_LOSS',1758,'DEFECT','2026-10-15',21);"
expect_allow "09 超容差单提交" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=152 AND status='DRAFT';"
expect_block "09 待审批的记账型单不能跳过审批直接 POSTED" "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=152;" "scrap_state_forward_only"
expect_allow "09 LIVE_DEATH 报损单（18 consume_live_hold 已扣，记账型）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (153,'SCR-53',1,'LIVE_DEATH',1801,'LIVE_DEATH','2026-10-15',21);"
expect_block "09 LIVE_DEATH 行挂冻结（双扣）" "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (153,153,1,11,1,1,800,0,'POST_OUT');" "scrap_line_record_only"
expect_block "09 LIVE_DEATH 原因码用在效期扫描单" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (154,'SCR-54',1,'EXPIRY_SCAN',1999,'LIVE_DEATH','2026-10-15',21);" "ck_scr_reason_src"
echo "=== 2f3-sp. search_path 固定（pg_catalog, public）：目录断言 + 同名表劫持 + 变异检查（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;

CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.scrap_order (id BIGINT, status TEXT, record_only BOOLEAN, source_type TEXT);
INSERT INTO hj_evil.scrap_order VALUES (999999,'DRAFT',false,'MANUAL');
SET LOCAL search_path = public;
DO $hj$ BEGIN INSERT INTO public.scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (19901,999999,1,14,1,1,5000,0,'POST_OUT'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (19901,999999,1,14,1,1,5000,0,'POST_OUT'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_scr_forward','trg_scr_ins_draft','trg_scrl_draft_only','trg_scr_no_delete')), true);
ALTER FUNCTION public.trg_scrl_draft_only() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_scr_forward','trg_scr_ins_draft','trg_scrl_draft_only','trg_scr_no_delete')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (19901,999999,1,14,1,1,5000,0,'POST_OUT'); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/4" ] && ok "本 PR 新增/重定义的 4 个 PL/pgSQL 函数 proconfig 都含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "search_path 目录断言：缺失/总数 = $HC0（期望 0/4）"
[ -n "$HB" ] && [ "$HF" = "$HB" ] && ok "劫持：wms_app 在自建 schema hj_evil 建同名表 scrap_order 并置于 search_path 首位，trg_scrl_draft_only() 仍读 public（结果与无劫持一致：$HB）" || bad "劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/4" ] && [ "$HM" != "$HB" ] && ok "变异检查：RESET trg_scrl_draft_only() 的 search_path 后，目录断言变红（$HC1）且劫持生效（$HM），两条断言都能抓到" || bad "变异检查没变红：目录=$HC1 劫持后=$HM 基准=$HB"
echo "=== 2h. docs/17 加工中心（#13 改稿，基于 #2 1d907031）：02 原语、守恒 C1–C5、外键、状态白名单、REPLACE 防护 ==="
expect_allow "17 种子：SKU 原料三文鱼/鱼柳/鱼骨/按件鸡腿、库位、批次" "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (1701,'SKU-SALMON','三文鱼整鱼','KG','CHILLED',6,1,3),(1702,'SKU-FILLET','三文鱼柳','KG','CHILLED',3,1,2),(1703,'SKU-BONE','三文鱼骨','KG','CHILLED',2,0,1),(1704,'SKU-LEG','鸡腿（定量装）','EA','CHILLED',5,1,3); INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1790,1,2,'PC-01','FLOOR',99,'P010'),(1791,1,2,'C-01-01','PALLET',8,'C010'),(1792,1,1,'A09-01-01','BIN',8,'A090'); INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1701,1701,'L-RAW1','2026-10-20','2026-10-14'),(1760,1702,'L-FIL1','2026-10-18','2026-10-15'),(1761,1703,'L-BON1','2026-10-17','2026-10-15'),(1762,1702,'L-FIL2','2026-10-18','2026-10-15'),(1763,1702,'L-FIL3','2026-10-18','2026-10-15'),(1764,1704,'L-LEG1','2026-10-19','2026-10-14'),(1765,1703,'L-BON2','2026-10-17','2026-10-15');"
expect_allow "17 种子：库存行 + 期初（原料 20 KG、鸡腿 10 件）" "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1781,1,1791,1701,1701,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1782,1,1790,1701,1701,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1783,1,1792,1702,1760,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1784,1,1792,1703,1761,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1785,1,1792,1702,1762,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1786,1,1792,1702,1763,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1787,1,1790,1704,1764,'KG',0); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1788,1,1792,1703,1765,'KG',0); BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-1781',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=20000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1781 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17001,'OPEN-1781',1,1,1,'DOC','OPENING',1,1781,1,1,1791,1701,1701,20000,0,20000,'2026-10-15','OPEN-1781:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17001,'OPEN-1781:1:D1:1','OPEN-1781',1,1,1,'DOC',1781,1,1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-1787',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1787 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17002,'OPEN-1787',1,1,1,'DOC','OPENING',1,1787,1,1,1790,1704,1764,10000,0,10000,'2026-10-15','OPEN-1787:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17002,'OPEN-1787:1:D1:1','OPEN-1787',1,1,1,'DOC',1787,1,1,'2026-10-15'); COMMIT;"
expect_allow "17 BOM 草稿（出成率 45%–55%，损耗上限 30%，称重容差 0.5%）" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,loss_max_bp,balance_tol_bp,created_by) VALUES (1701,1,'BOM-SALMON',1,'三文鱼分切',4500,5500,3000,50,8);"
expect_block "17 BOM 损耗上限 > 100%" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,loss_max_bp,created_by) VALUES (1709,1,'BOM-X',1,'x',4000,5000,10001,8);" "ck_pbom_loss"
expect_block "17 BOM 行 SKU 不存在（外键）" "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17019,1701,9,'INPUT',999999,1000);" "fk_pboml_sku"
expect_block "17 BOM 行挂不存在的 BOM（外键）" "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17019,999,1,'INPUT',1701,1000);" "fk_pboml_bom"
expect_allow "17 BOM 行：原料 / 成品 / 副产品" "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17011,1701,1,'INPUT',1701,10000),(17012,1701,2,'FINISHED',1702,5000),(17013,1701,3,'BYPRODUCT',1703,2000);"
expect_allow "17 BOM 生效" "UPDATE process_bom SET status='ACTIVE', activated_at='2026-10-15 01:00:00' WHERE id=1701;"
expect_block "17 BOM ACTIVE → DRAFT 回退（绕 bom_frozen）" "UPDATE process_bom SET status='DRAFT' WHERE id=1701;" "bom_forward_only"
expect_block "17 BOM ACTIVE 时改出成率" "UPDATE process_bom SET yield_min_bp=1000 WHERE id=1701;" "bom_forward_only"
expect_block "17 BOM 生效后不能改行" "UPDATE process_bom_line SET std_qty_milli=1 WHERE id=17012;" "bom_frozen"
expect_allow "17 BOM v2 草稿 → 生效 → 退役" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1702,1,'BOM-SALMON',2,'v2',4500,5500,8);"
expect_block "17 BOM RETIRED/DRAFT 不能直接跳 RETIRED（DRAFT → RETIRED）" "UPDATE process_bom SET status='RETIRED', activated_at='2026-10-15 02:00:00' WHERE id=1702;" "bom_forward_only"
expect_block "17 加工单直接以 IN_PROGRESS 插入" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,status) VALUES (1719,1,'PRC-X','2026-10-15',1701,1790,1,8,'IN_PROGRESS');" "process_order_bad_transition"
expect_block "17 加工单 BOM 不存在（外键）" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1719,1,'PRC-X','2026-10-15',999,1790,1,8);" "fk_prc_bom"
expect_allow "17 加工单 1710 CREATED" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1710,1,'PRC-SH01-0001-20261015-000001','2026-10-15',1701,1790,10000,8);"
expect_block "17 CREATED → COMPLETED 跳状态" "UPDATE process_order SET status='COMPLETED', completed_at='2026-10-15 03:00:00' WHERE id=1710;" "process_order_bad_transition"
expect_allow "17 下达（带快照）" "UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00', bom_code='BOM-SALMON', bom_version=1, bom_snapshot='[INPUT:1701,FINISHED:1702,BYPRODUCT:1703]', yield_min_bp=4500, yield_max_bp=5500, loss_max_bp=3000, balance_tol_bp=50 WHERE id=1710;"
expect_allow "17 开工 IN_PROGRESS" "UPDATE process_order SET status='IN_PROGRESS' WHERE id=1710;"
expect_block "17 IN_PROGRESS → CREATED 回退" "UPDATE process_order SET status='CREATED' WHERE id=1710;" "process_order_bad_transition"
expect_allow "17 领用 10 KG：move(存储位→加工中心) + place_hold(PROCESSING) + 领用行 + 单头累计" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1781 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17003,'PRC-SH01-0001-20261015-000001',1,1,1,'DOC','PROCESS_ISSUE',-1,1781,2,1,1791,1701,1701,10000,20000,10000,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17003,'PRC-SH01-0001-20261015-000001:1:D1:1','PRC-SH01-0001-20261015-000001',1,1,1,'DOC',1781,2,-1,'2026-10-15'); UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1782 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17004,'PRC-SH01-0001-20261015-000001',1,1,2,'DOC','PROCESS_ISSUE',1,1782,1,1,1790,1701,1701,10000,0,10000,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D1:2',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17004,'PRC-SH01-0001-20261015-000001:1:D1:2','PRC-SH01-0001-20261015-000001',1,1,2,'DOC',1782,1,1,'2026-10-15'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1730,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:00000000-0000-4000-8000-000000001720',10000,0); UPDATE stock SET hold_qty_milli=10000, version=version+1 WHERE id=1782; INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1720,1,1710,1,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',10000,21); UPDATE process_order SET issued_qty_milli=10000 WHERE id=1710; COMMIT;"
R=$(psql -t -A -c "SELECT available_qty_milli FROM v_stock_available WHERE stock_id=1782")
[ "$R" = "0" ] && ok "17 加工中心原料全部 PROCESSING 冻结，可用 = 0 = $R" || bad "17 加工中心原料全部 PROCESSING 冻结，可用 = 0 = $R（期望 0）"
expect_block "17 领用行挂不存在的冻结（外键）" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1781,1782,999999,1701,1701,'2026-10-20',1,21);" "fk_prci_hold"
expect_block "17 LIVE_TANK 领用缺 18 出池称重 live_weigh_id" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_count) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'LIVE_TANK',1781,1782,999998,1701,1701,'2026-10-20',1,21,3);" "ck_prci_live"
expect_block "17 按件领用：件数 × 单件净重 ≠ 净重" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_pcs,unit_net_weight_g) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1787,1787,999998,1704,1764,'2026-10-20',2000,21,5,350);" "ck_prci_pcs"
expect_block "17 按件领用：缺单件净重（std_net_weight_g 为空 → 40001）" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_pcs) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1787,1787,999998,1704,1764,'2026-10-20',2000,21,5);" "ck_prci_pcs"
expect_block "17 领用行 op_key 重放" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1729,1,1710,9,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',1,21);" "uq_prci_op"
expect_block "17 领用量不可改" "UPDATE process_issue SET issue_qty_milli=9000 WHERE id=1720;" "process_issue_immutable"
expect_block "17 领用行不可删" "DELETE FROM process_issue WHERE id=1720;" "process_issue_immutable"
expect_allow "17 报工 #1：成品 4.8 + 副产 2.0 + 损耗 TRIM 2.7（报损单只记账）；consume_process_hold 9.5（含损耗）+ post_in 两条" "BEGIN; INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1740,1,1710,'00000000-0000-4000-8000-000000001740','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,false,200,'{}',21); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1750,1,1710,1740,1,'FINISHED',1702,1760,1792,4820,20,4800,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1751,1,1710,1740,2,'BYPRODUCT',1703,1761,1792,2020,20,2000,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1752,1,1710,1740,3,'LOSS',1701,NULL,NULL,2720,20,2700,'2026-10-15 03:00:00',NULL,NULL,9001,'TRIM',NULL); UPDATE stock_hold SET released_qty_milli=9500, status='HELD', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=9500; UPDATE stock SET on_hand_qty_milli=500, hold_qty_milli=500, ledger_seq=2, version=version+1 WHERE id=1782 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17005,'PRC-SH01-0001-20261015-000001',1,2,1,'DOC','PROCESS_CONSUME',-1,1782,2,1,1790,1701,1701,9500,10000,500,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D2:1',1730); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17005,'PRC-SH01-0001-20261015-000001:1:D2:1','PRC-SH01-0001-20261015-000001',1,2,1,'DOC',1782,2,-1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1001,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=4800, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1783 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17006,'PRC-SH01-0001-20261015-000001',1001,1,1,'DOC','PROCESS_OUTPUT',1,1783,1,1,1792,1702,1760,4800,0,4800,'2026-10-15','PRC-SH01-0001-20261015-000001:1001:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17006,'PRC-SH01-0001-20261015-000001:1001:D1:1','PRC-SH01-0001-20261015-000001',1001,1,1,'DOC',1783,1,1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1002,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1784 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17007,'PRC-SH01-0001-20261015-000001',1002,1,1,'DOC','PROCESS_OUTPUT',1,1784,1,1,1792,1703,1761,2000,0,2000,'2026-10-15','PRC-SH01-0001-20261015-000001:1002:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17007,'PRC-SH01-0001-20261015-000001:1002:D1:1','PRC-SH01-0001-20261015-000001',1002,1,1,'DOC',1784,1,1,'2026-10-15'); UPDATE process_issue SET consumed_qty_milli=9500 WHERE id=1720; UPDATE process_order SET consumed_qty_milli=9500, output_qty_milli=4800, byproduct_qty_milli=2000, loss_qty_milli=2700 WHERE id=1710; COMMIT;"
R=$(psql -t -A -c "SELECT on_hand_qty_milli || '/' || hold_qty_milli FROM stock WHERE id=1782")
[ "$R" = "500/500" ] && ok "17 C1 报工后：加工中心余料 = 0.5 KG，仍全部冻结 = $R" || bad "17 C1 报工后：加工中心余料 = 0.5 KG，仍全部冻结 = $R（期望 500/500）"
expect_block "17 C2 单头已消耗 ≠ 各去向之和" "UPDATE process_order SET consumed_qty_milli=9600 WHERE id=1710;" "ck_prc_consume"
expect_block "17 C2 消耗超过净领用（余料 < 0）" "UPDATE process_order SET consumed_qty_milli=10100, loss_qty_milli=3300 WHERE id=1710;" "ck_prc_cap"
expect_block "17 领用行 冲回 + 消耗 > 领用（42214 OVER_REVERSE）" "UPDATE process_issue SET reversed_qty_milli=501 WHERE id=1720;" "ck_prci_reverse"
expect_block "17 领用行消耗量回退" "UPDATE process_issue SET consumed_qty_milli=9000 WHERE id=1720;" "process_issue_immutable"
expect_block "17 余料 0.5 KG > 容差 50g 时直接完工（必须先领用冲回）" "UPDATE process_order SET status='COMPLETED', yield_bp=4800, completed_at='2026-10-15 04:00:00' WHERE id=1710;" "ck_prc_balance"
expect_allow "17 领用冲回 0.45 KG：release_hold（stock_hold_release）+ move 回来源库位 + 冲回记录（movement_ref/hold_release_id）" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (1735,1730,'PRCR:1710:00000000-0000-4000-8000-000000001790',450); UPDATE stock_hold SET released_qty_milli=9950, status='HELD', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=450; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1710',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=50, hold_qty_milli=50, ledger_seq=3, version=version+1 WHERE id=1782 AND ledger_seq=2; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17008,'PRCR-1710',1,1,1,'DOC','PROCESS_REVERSE',-1,1782,3,1,1790,1701,1701,450,500,50,'2026-10-15','PRCR-1710:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17008,'PRCR-1710:1:D1:1','PRCR-1710',1,1,1,'DOC',1782,3,-1,'2026-10-15'); UPDATE stock SET on_hand_qty_milli=10450, hold_qty_milli=0, ledger_seq=3, version=version+1 WHERE id=1781 AND ledger_seq=2; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17009,'PRCR-1710',1,1,2,'DOC','PROCESS_REVERSE',1,1781,3,1,1791,1701,1701,450,10000,10450,'2026-10-15','PRCR-1710:1:D1:2',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17009,'PRCR-1710:1:D1:2','PRCR-1710',1,1,2,'DOC',1781,3,1,'2026-10-15'); UPDATE process_issue SET reversed_qty_milli=450 WHERE id=1720; UPDATE process_order SET reversed_qty_milli=450 WHERE id=1710; INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1790,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001790','ISSUE',NULL,NULL,1720,NULL,450,'PRCR-1710:1:D1:1',1735,'测试',9); COMMIT;"
expect_block "17 领用冲回缺 hold_release_id" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001791','ISSUE',NULL,NULL,1720,NULL,1,'PRCR-1710:1:D1:1',NULL,'测试',9);" "ck_prcv_type"
expect_block "17 冲回 movement_ref 指向不存在的流水（外键）" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001791','ISSUE',NULL,NULL,1720,NULL,1,'NOPE:1:D1:1',1735,'测试',9);" "fk_prcv_mv"
expect_block "17 冲回 op_key 不带加工单 id / 非 UUID" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,issue_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:abc','ISSUE',1720,1,'PRCR-1710:1:D1:1',1735,'x',9);" "ck_prcv_op"
expect_block "17 冲回 op_key 重放" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001790','ISSUE',NULL,NULL,1720,NULL,1,'PRCR-1710:1:D1:1',1735,'测试',9);" "uq_prcv_op"
expect_allow "17 完工报工：余料 50g ≤ 容差 → WEIGH_DIFF 损耗 + consume 50g" "BEGIN; INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1741,1,1710,'00000000-0000-4000-8000-000000001741','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',2,true,200,'{}',21); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1753,1,1710,1741,1,'LOSS',1701,NULL,NULL,70,20,50,'2026-10-15 03:00:00',NULL,NULL,9002,'WEIGH_DIFF',NULL); UPDATE stock_hold SET released_qty_milli=10000, status='RELEASED', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=50; UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=4, version=version+1 WHERE id=1782 AND ledger_seq=3; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17010,'PRC-SH01-0001-20261015-000001',1,3,1,'DOC','PROCESS_CONSUME',-1,1782,4,1,1790,1701,1701,50,50,0,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D3:1',1730); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17010,'PRC-SH01-0001-20261015-000001:1:D3:1','PRC-SH01-0001-20261015-000001',1,3,1,'DOC',1782,4,-1,'2026-10-15'); UPDATE process_issue SET consumed_qty_milli=9550 WHERE id=1720; UPDATE process_order SET consumed_qty_milli=9550, loss_qty_milli=2750 WHERE id=1710; COMMIT;"
expect_block "17 完工出成率与净额不符（应用传 5100）" "UPDATE process_order SET status='COMPLETED', yield_bp=5100, completed_at='2026-10-15 04:00:00' WHERE id=1710;" "ck_prc_yield"
expect_allow "17 完工：余料 0、出成率 4.8/9.55 = 50.26%、损耗 28.8% 均在界内" "UPDATE process_order SET status='COMPLETED', yield_bp=5026, completed_at='2026-10-15 04:00:00' WHERE id=1710;"
expect_block "17 完工后单据只读" "UPDATE process_order SET loss_qty_milli=2751 WHERE id=1710;" "process_order_frozen"
R=$(psql -t -A -c "SELECT status || '/' || released_qty_milli FROM stock_hold WHERE id=1730")
[ "$R" = "RELEASED/10000" ] && ok "17 1710 冻结已全部释放（RELEASED，释放 = 消耗 + 冲回） = $R" || bad "17 1710 冻结已全部释放（RELEASED，释放 = 消耗 + 冲回） = $R（期望 RELEASED/10000）"
expect_allow "17 单 1711 建单 → 下达 → 开工" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1711,1,'PRC-SH01-0001-20261015-000002','2026-10-15',1701,1790,10000,8);"
expect_allow "17 单 1711 下达" "UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00', bom_code='BOM-SALMON', bom_version=1, bom_snapshot='[INPUT:1701,FINISHED:1702,BYPRODUCT:1703]', yield_min_bp=4500, yield_max_bp=5500, loss_max_bp=3000, balance_tol_bp=50 WHERE id=1711;"
expect_allow "17 单 1711 开工" "UPDATE process_order SET status='IN_PROGRESS' WHERE id=1711;"
expect_allow "17 单 1711 领用 5 KG" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=5450, hold_qty_milli=0, ledger_seq=4, version=version+1 WHERE id=1781 AND ledger_seq=3; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17011,'PRC-SH01-0001-20261015-000002',1,1,1,'DOC','PROCESS_ISSUE',-1,1781,4,1,1791,1701,1701,5000,10450,5450,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17011,'PRC-SH01-0001-20261015-000002:1:D1:1','PRC-SH01-0001-20261015-000002',1,1,1,'DOC',1781,4,-1,'2026-10-15'); UPDATE stock SET on_hand_qty_milli=5000, hold_qty_milli=0, ledger_seq=5, version=version+1 WHERE id=1782 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17012,'PRC-SH01-0001-20261015-000002',1,1,2,'DOC','PROCESS_ISSUE',1,1782,5,1,1790,1701,1701,5000,0,5000,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D1:2',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17012,'PRC-SH01-0001-20261015-000002:1:D1:2','PRC-SH01-0001-20261015-000002',1,1,2,'DOC',1782,5,1,'2026-10-15'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1731,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1711,'PRCI:1711:00000000-0000-4000-8000-000000001721',5000,0); UPDATE stock SET hold_qty_milli=5000, version=version+1 WHERE id=1782; INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1721,1,1711,1,'PRCI:1711:00000000-0000-4000-8000-000000001721',1791,'PALLET',1781,1782,1731,1701,1701,'2026-10-20',5000,21); UPDATE process_order SET issued_qty_milli=5000 WHERE id=1711; COMMIT;"
expect_allow "17 单 1711 报工：成品 2.5 + 副产 2.0 + 损耗 TRIM 0.5，consume 5.0" "BEGIN; INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1742,1,1711,'00000000-0000-4000-8000-000000001742','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,false,200,'{}',21); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1754,1,1711,1742,1,'FINISHED',1702,1762,1792,2520,20,2500,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1755,1,1711,1742,2,'BYPRODUCT',1703,1765,1792,2020,20,2000,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1756,1,1711,1742,3,'LOSS',1701,NULL,NULL,520,20,500,'2026-10-15 03:00:00',NULL,NULL,9003,'TRIM',NULL); UPDATE stock_hold SET released_qty_milli=5000, status='RELEASED', version=version+1 WHERE id=1731 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=5000; UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=6, version=version+1 WHERE id=1782 AND ledger_seq=5; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17013,'PRC-SH01-0001-20261015-000002',1,2,1,'DOC','PROCESS_CONSUME',-1,1782,6,1,1790,1701,1701,5000,5000,0,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D2:1',1731); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17013,'PRC-SH01-0001-20261015-000002:1:D2:1','PRC-SH01-0001-20261015-000002',1,2,1,'DOC',1782,6,-1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1001,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=2500, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1785 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17014,'PRC-SH01-0001-20261015-000002',1001,1,1,'DOC','PROCESS_OUTPUT',1,1785,1,1,1792,1702,1762,2500,0,2500,'2026-10-15','PRC-SH01-0001-20261015-000002:1001:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17014,'PRC-SH01-0001-20261015-000002:1001:D1:1','PRC-SH01-0001-20261015-000002',1001,1,1,'DOC',1785,1,1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1002,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1788 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17015,'PRC-SH01-0001-20261015-000002',1002,1,1,'DOC','PROCESS_OUTPUT',1,1788,1,1,1792,1703,1765,2000,0,2000,'2026-10-15','PRC-SH01-0001-20261015-000002:1002:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17015,'PRC-SH01-0001-20261015-000002:1002:D1:1','PRC-SH01-0001-20261015-000002',1002,1,1,'DOC',1788,1,1,'2026-10-15'); UPDATE process_issue SET consumed_qty_milli=5000 WHERE id=1721; UPDATE process_order SET consumed_qty_milli=5000, output_qty_milli=2500, byproduct_qty_milli=2000, loss_qty_milli=500 WHERE id=1711; COMMIT;"
expect_allow "17 C3 产出冲回报废 0.3 KG：post_out(PROCESS_REVERSE)，output −0.3、scrapped +0.3、consumed 不变" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1711',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=2200, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1785 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17016,'PRCR-1711',1,1,1,'DOC','PROCESS_REVERSE',-1,1785,2,1,1792,1702,1762,300,2500,2200,'2026-10-15','PRCR-1711:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17016,'PRCR-1711:1:D1:1','PRCR-1711',1,1,1,'DOC',1785,2,-1,'2026-10-15'); UPDATE process_output SET reversed_qty_milli=300 WHERE id=1754; UPDATE process_order SET output_qty_milli=2200, scrapped_qty_milli=300 WHERE id=1711; INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1792,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001792','OUTPUT','SCRAP',NULL,NULL,1754,300,'PRCR-1711:1:D1:1',NULL,'测试',9); COMMIT;"
expect_block "17 产出冲回直接改库存、不记报废（旧写法：output 减了、scrapped 没加）" "UPDATE process_order SET output_qty_milli=2100 WHERE id=1711;" "ck_prc_consume"
expect_block "17 scrapped 回退" "UPDATE process_order SET output_qty_milli=2300, scrapped_qty_milli=200 WHERE id=1711;" "process_order_frozen"
expect_block "17 返工回台缺主管审批单号" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1793,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001793','OUTPUT','REWORK',NULL,NULL,1754,200,'PRCR-1711:1:D1:1',NULL,'测试',9);" "ck_prcv_type"
expect_allow "17 返工回台 0.2 KG（主管 approval_no）：move 成品 → 加工中心 + place_hold + REWORK 领用行；issued +0.2、reworked +0.2" "BEGIN; UPDATE stock SET location_id=1790, lot_id=1762 WHERE id=1786; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1711',2,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=3, version=version+1 WHERE id=1785 AND ledger_seq=2; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17017,'PRCR-1711',2,1,1,'DOC','PROCESS_REVERSE',-1,1785,3,1,1792,1702,1762,200,2200,2000,'2026-10-15','PRCR-1711:2:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17017,'PRCR-1711:2:D1:1','PRCR-1711',2,1,1,'DOC',1785,3,-1,'2026-10-15'); UPDATE stock SET on_hand_qty_milli=200, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1786 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17018,'PRCR-1711',2,1,2,'DOC','PROCESS_REVERSE',1,1786,1,1,1790,1702,1762,200,0,200,'2026-10-15','PRCR-1711:2:D1:2',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17018,'PRCR-1711:2:D1:2','PRCR-1711',2,1,2,'DOC',1786,1,1,'2026-10-15'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1732,1786,'PROCESSING','PROCESSING','PROCESS_ORDER',1711,'PRCI:1711:00000000-0000-4000-8000-000000001722',200,0); UPDATE stock SET hold_qty_milli=200, version=version+1 WHERE id=1786; INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1722,1,1711,2,'PRCI:1711:00000000-0000-4000-8000-000000001722',1792,'REWORK',1785,1786,1732,1702,1762,'2026-10-18',200,21); UPDATE process_output SET reversed_qty_milli=500 WHERE id=1754; UPDATE process_order SET issued_qty_milli=5200, output_qty_milli=2000, reworked_qty_milli=200 WHERE id=1711; INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1793,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001793','OUTPUT','REWORK','APR-WHSH01-20261015-000031',NULL,1754,200,'PRCR-1711:2:D1:1',NULL,'测试',9); COMMIT;"
expect_allow "17 返工报工：成品 0.19 + 损耗 TRIM 0.01，consume 0.2" "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1789,1,1792,1702,1763,'KG',0); INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1743,1,1711,'00000000-0000-4000-8000-000000001743','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',2,false,200,'{}',21); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1757,1,1711,1743,1,'FINISHED',1702,1763,1792,210,20,190,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1758,1,1711,1743,2,'LOSS',1702,NULL,NULL,30,20,10,'2026-10-15 03:00:00',NULL,NULL,9004,'TRIM',NULL); UPDATE stock_hold SET released_qty_milli=200, status='RELEASED', version=version+1 WHERE id=1732 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=200; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',2,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1786 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17019,'PRC-SH01-0001-20261015-000002',2,2,1,'DOC','PROCESS_CONSUME',-1,1786,2,1,1790,1702,1762,200,200,0,'2026-10-15','PRC-SH01-0001-20261015-000002:2:D2:1',1732); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17019,'PRC-SH01-0001-20261015-000002:2:D2:1','PRC-SH01-0001-20261015-000002',2,2,1,'DOC',1786,2,-1,'2026-10-15'); INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',2001,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=190, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1789 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17020,'PRC-SH01-0001-20261015-000002',2001,1,1,'DOC','PROCESS_OUTPUT',1,1789,1,1,1792,1702,1763,190,0,190,'2026-10-15','PRC-SH01-0001-20261015-000002:2001:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17020,'PRC-SH01-0001-20261015-000002:2001:D1:1','PRC-SH01-0001-20261015-000002',2001,1,1,'DOC',1789,1,1,'2026-10-15'); UPDATE process_issue SET consumed_qty_milli=200 WHERE id=1722; UPDATE process_order SET consumed_qty_milli=5200, output_qty_milli=2190, loss_qty_milli=510 WHERE id=1711; COMMIT;"
expect_block "17 C4 损耗部分冲回（只能整行转出，对应 09 整张作废）" "UPDATE process_output SET reversed_qty_milli=100 WHERE id=1756;" "ck_prco_loss_whole"
expect_allow "17 C4 损耗冲回只改原因/拆数量：TRIM 0.5 整行转出 → TRIM 0.4 + DEFECT 0.1（新行 from_output_id、新报损单），不回在制、单头损耗不变" "BEGIN; UPDATE process_output SET reversed_qty_milli=500 WHERE id=1756; INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1744,1,1711,'00000000-0000-4000-8000-000000001744','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',3,false,200,'{}',21); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1768,1,1711,1744,1,'LOSS',1701,NULL,NULL,420,20,400,'2026-10-15 03:00:00',NULL,NULL,9005,'TRIM',1756); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1759,1,1711,1744,2,'LOSS',1701,NULL,NULL,120,20,100,'2026-10-15 03:00:00',NULL,NULL,9006,'DEFECT',1756); INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1794,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001794','LOSS',NULL,NULL,NULL,1756,500,NULL,NULL,'测试',9); COMMIT;"
expect_block "17 损耗冲回带库存流水（回在制）" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1795,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001795','LOSS',NULL,NULL,NULL,1756,1,'PRCR-1711:1:D1:1',NULL,'测试',9);" "ck_prcv_type"
expect_block "17 损耗冲回直接把单头损耗减掉（重量凭空消失）" "UPDATE process_order SET loss_qty_milli=410 WHERE id=1711;" "ck_prc_consume"
expect_block "17 LOSS 行原因不可直接改" "UPDATE process_output SET loss_reason='DRIP' WHERE id=1756;" "process_output_immutable"
expect_block "17 LOSS 原因 REVERSE_SCRAP 不收（报废单独记 scrapped）" "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1769,1,1711,1744,9,'LOSS',1701,NULL,NULL,21,20,1,'2026-10-15 03:00:00',NULL,NULL,9006,'REVERSE_SCRAP',NULL);" "ck_prco_kind"
expect_block "17 越界直接完工（无审批单）" "UPDATE process_order SET status='COMPLETED', yield_bp=4380, completed_at='2026-10-15 05:00:00' WHERE id=1711;" "ck_prc_dev"
expect_block "17 待审批缺过期时刻（Q-f 12h）" "UPDATE process_order SET status='PENDING_APPROVAL', yield_bp=4380, approval_no='APR-WHSH01-20261015-000032' WHERE id=1711;" "ck_prc_apr_exp"
expect_allow "17 越界转 PROCESS_YIELD_DEVIATION（出成率+损耗合并一张，12h 过期）" "UPDATE process_order SET status='PENDING_APPROVAL', yield_bp=4380, approval_no='APR-WHSH01-20261015-000032', approval_expires_at='2026-10-15 17:00:00' WHERE id=1711;"
expect_block "17 PENDING_APPROVAL → CANCELLED 不允许" "UPDATE process_order SET status='CANCELLED', cancel_reason='x' WHERE id=1711;" "process_order_bad_transition"
expect_allow "17 审批通过 → COMPLETED" "UPDATE process_order SET status='COMPLETED', completed_at='2026-10-15 06:00:00' WHERE id=1711;"
expect_allow "17 撤销单 1713 建单" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1713,1,'PRC-SH01-0001-20261015-000003','2026-10-15',1701,1790,10000,8);"
expect_block "17 撤销缺原因" "UPDATE process_order SET status='CANCELLED' WHERE id=1713;" "ck_prc_cancel"
expect_allow "17 撤销" "UPDATE process_order SET status='CANCELLED', cancel_reason='设备故障' WHERE id=1713;"
expect_allow "17 追溯：成品 1760 ← 原料行 1720；返工成品 1763 ← REWORK 行 1722" "INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1770,1,1710,1750,1760,1720,1701),(1771,1,1710,1751,1761,1720,1701),(1772,1,1711,1757,1763,1722,1762),(1773,1,1711,1754,1762,1721,1701);"
expect_block "17 追溯挂不存在的产出（外键）" "INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1779,1,1710,999999,1760,1720,1701);" "fk_plt_output"
R=$(psql -t -A -c "SELECT count(*) FROM stock s WHERE s.id BETWEEN 1781 AND 1789 AND (s.on_hand_qty_milli <> COALESCE((SELECT SUM(m.direction*m.move_qty_milli) FROM stock_movement m WHERE m.stock_id=s.id),0) OR s.ledger_seq <> COALESCE((SELECT MAX(m.stock_seq) FROM stock_movement m WHERE m.stock_id=s.id AND m.direction<>0),0))")
[ "$R" = "0" ] && ok "17 C5 流水回放：8 行库存 on_hand = Σ流水 且 ledger_seq = 末条 stock_seq（差异行数） = $R" || bad "17 C5 流水回放：8 行库存 on_hand = Σ流水 且 ledger_seq = 末条 stock_seq（差异行数） = $R（期望 0）"
R=$(psql -t -A -c "SELECT count(*) FROM process_order WHERE id IN (1710,1711) AND NOT (issued_qty_milli - reversed_qty_milli = consumed_qty_milli AND consumed_qty_milli = output_qty_milli+byproduct_qty_milli+loss_qty_milli+scrapped_qty_milli+reworked_qty_milli)")
[ "$R" = "0" ] && ok "17 C5 单头公式：issued − reversed = consumed = 成品+副产+损耗+报废+返工（不平的单数） = $R" || bad "17 C5 单头公式：issued − reversed = consumed = 成品+副产+损耗+报废+返工（不平的单数） = $R（期望 0）"
R=$(psql -t -A -c "SELECT count(*) FROM process_order o WHERE o.id IN (1710,1711) AND (o.issued_qty_milli,o.reversed_qty_milli,o.consumed_qty_milli) <> (SELECT SUM(i.issue_qty_milli),SUM(i.reversed_qty_milli),SUM(i.consumed_qty_milli) FROM process_issue i WHERE i.process_order_id=o.id)")
[ "$R" = "0" ] && ok "17 C5 明细 ↔ 单头：Σ领用行 issued/reversed/consumed = 单头（不平的单数） = $R" || bad "17 C5 明细 ↔ 单头：Σ领用行 issued/reversed/consumed = 单头（不平的单数） = $R（期望 0）"
R=$(psql -t -A -c "SELECT count(*) FROM process_issue i JOIN stock_hold h ON h.id=i.hold_id WHERE i.reversed_qty_milli + i.consumed_qty_milli <> h.released_qty_milli OR h.status <> 'RELEASED'")
[ "$R" = "0" ] && ok "17 C5 明细 ↔ 冻结：每行 冲回+消耗 = PROCESSING 已释放量，余量 = 0（不平的行数） = $R" || bad "17 C5 明细 ↔ 冻结：每行 冲回+消耗 = PROCESSING 已释放量，余量 = 0（不平的行数） = $R（期望 0）"
R=$(psql -t -A -c "SELECT -SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_type='PROCESS_CONSUME' AND biz_no LIKE 'PRC-SH01-0001-20261015-%'")
[ "$R" = "14750" ] && ok "17 C5 流水 ↔ 单头：Σ PROCESS_CONSUME = consumed（1710/1711 合计 9550+5200） = $R" || bad "17 C5 流水 ↔ 单头：Σ PROCESS_CONSUME = consumed（1710/1711 合计 9550+5200） = $R（期望 14750）"
R=$(psql -t -A -c "SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_type='PROCESS_OUTPUT'")
[ "$R" = "11490" ] && ok "17 C5 流水 ↔ 产出：Σ PROCESS_OUTPUT = 成品+副产 产出原值（4800+2000+2500+2000+190） = $R" || bad "17 C5 流水 ↔ 产出：Σ PROCESS_OUTPUT = 成品+副产 产出原值（4800+2000+2500+2000+190） = $R（期望 11490）"
R=$(psql -t -A -c "SELECT (SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_no='PRCR-1710') || '/' || (SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_no='PRCR-1711')")
[ "$R" = "0/-300" ] && ok "17 C5 冲回流水平衡：领用冲回两腿净额 0、报废 −0.3、返工两腿净额 0（PRCR-1710 / PRCR-1711 合计） = $R" || bad "17 C5 冲回流水平衡：领用冲回两腿净额 0、报废 −0.3、返工两腿净额 0（PRCR-1710 / PRCR-1711 合计） = $R（期望 0/-300）"
R=$(psql -t -A -c "SELECT (SELECT SUM(qty_milli) FROM process_reversal WHERE reversal_type='ISSUE') - (SELECT SUM(reversed_qty_milli) FROM process_issue) + (SELECT count(*) FROM process_reversal v WHERE v.movement_ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.idempotency_key=v.movement_ref))")
[ "$R" = "0" ] && ok "17 C5 冲回记录 ↔ 明细：Σ ISSUE 冲回 = Σ 领用行 reversed；每条冲回 movement_ref 都有流水 = $R" || bad "17 C5 冲回记录 ↔ 明细：Σ ISSUE 冲回 = Σ 领用行 reversed；每条冲回 movement_ref 都有流水 = $R（期望 0）"
R=$(psql -t -A -c "SELECT (SELECT SUM(on_hand_qty_milli) FROM stock WHERE id IN (1781,1782,1783,1784,1785,1786,1788,1789)) + (SELECT SUM(loss_qty_milli+scrapped_qty_milli) FROM process_order WHERE id IN (1710,1711))")
[ "$R" = "20000" ] && ok "17 C5 全仓重量守恒：原料期初 20 = 在库(原料+在制+成品+副产) + 损耗 + 报废（克） = $R" || bad "17 C5 全仓重量守恒：原料期初 20 = 在库(原料+在制+成品+副产) + 损耗 + 报废（克） = $R（期望 20000）"
R=$(psql -t -A -c "SELECT count(*) FROM stock_hold h WHERE h.id IN (1730,1731,1732) AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0)")
[ "$R" = "0" ] && ok "17 I3f（#2 1d907031）按 hold_id 对账：每条 PROCESSING 冻结 已释放 = stock_hold_release + 本冻结 PROCESS_CONSUME 流水（不平的冻结数） = $R" || bad "17 I3f（#2 1d907031）按 hold_id 对账：每条 PROCESSING 冻结 已释放 = stock_hold_release + 本冻结 PROCESS_CONSUME 流水（不平的冻结数） = $R（期望 0）"
R=$(psql -t -A -c "SELECT count(*) FROM stock_movement m WHERE m.biz_type='PROCESS_CONSUME' AND m.biz_no LIKE 'PRC-SH01-0001-20261015-%' AND (m.hold_id IS NULL OR NOT EXISTS (SELECT 1 FROM process_issue i JOIN process_order o ON o.id=i.process_order_id WHERE i.hold_id=m.hold_id AND o.code=m.biz_no AND i.line_no=m.line_no))")
[ "$R" = "0" ] && ok "17 consume 流水全部写 hold_id，且与领用行 hold_id 一致（缺失/不一致条数） = $R" || bad "17 consume 流水全部写 hold_id，且与领用行 hold_id 一致（缺失/不一致条数） = $R（期望 0）"
expect_block "17 B6 覆写已缓存的 process_report（PG：ON CONFLICT DO UPDATE）" "INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1740,1,1710,'00000000-0000-4000-8000-000000001740','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',1,false,202,'{}',21) ON CONFLICT (process_order_id,report_client_id) DO UPDATE SET response=EXCLUDED.response;" "append_only_violation: process_report"
expect_block "17 B6 覆写已缓存的 process_issue（PG：ON CONFLICT DO UPDATE）" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1720,1,1710,1,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',1,21) ON CONFLICT (op_key) DO UPDATE SET issue_qty_milli=EXCLUDED.issue_qty_milli;" "process_issue_immutable"
expect_block "17 B6 覆写已缓存的 process_output（PG：ON CONFLICT DO UPDATE）" "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1750,1,1710,1740,1,'FINISHED',1702,1760,1792,9020,20,9000,'2026-10-15 03:00:00','2026-10-18','2026-10-20') ON CONFLICT (report_id,line_no) DO UPDATE SET qty_milli=EXCLUDED.qty_milli;" "process_output_immutable"
expect_block "17 B6 覆写已缓存的 process_lot_trace（PG：ON CONFLICT DO UPDATE）" "INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1770,1,1710,1750,1760,1720,1765) ON CONFLICT (output_id,issue_id) DO UPDATE SET raw_lot_id=EXCLUDED.raw_lot_id;" "append_only_violation: process_lot_trace"
expect_block "17 B6 覆写已缓存的 process_reversal（PG：ON CONFLICT DO UPDATE）" "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,output_id,qty_milli,reason,operator_id) VALUES (1794,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001794','LOSS',1756,1,'x',9) ON CONFLICT (op_key) DO UPDATE SET qty_milli=EXCLUDED.qty_milli;" "append_only_violation: process_reversal"
R=$(psql -t -A -c "WITH RECURSIVE f(lot) AS (SELECT output_lot_id FROM process_lot_trace WHERE raw_lot_id=1701 UNION SELECT t.output_lot_id FROM process_lot_trace t JOIN f ON t.raw_lot_id=f.lot) SELECT string_agg(lot::text, ',' ORDER BY lot) FROM f")
[ "$R" = "1760,1761,1762,1763" ] && ok "17 召回正查（递归，含返工二级）：原料批次 1701 → $R" || bad "17 召回正查 = $R（期望 1760,1761,1762,1763）"
OUT=$(psql_capture "SET ROLE wms_app; UPDATE process_report SET response='{}' WHERE id=1740;")
case "$OUT" in *"permission denied for table process_report"*) ok "17 wms_app 对 process_report 无 UPDATE（报工只追加）";; *) bad "wms_app 改 process_report 未被拒：$OUT";; esac
echo "=== 2h-ck. docs/17 CHECK 三件套（按名拒绝 + 变异；本轮第一批 12 个，其余见 PR 描述）==="
mut_ck17() { expect_allow "17 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3 ROLLBACK;"; }
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1870,1702,'L-CK1','2026-10-18','2026-10-15');"
seed "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1830,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:ck0',1000,0);"
seed "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1831,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:ck9',1000,0);"
expect_block "17 ck_pbom_status 非法状态值" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status,activated_at) VALUES (1801,1,'BOM-CK1',1,'x',4000,5000,8,'BOGUS','2026-10-15 01:00:00');" "ck_pbom_status"
mut_ck17 "ck_pbom_status" "process_bom" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status,activated_at) VALUES (1801,1,'BOM-CK1',1,'x',4000,5000,8,'BOGUS','2026-10-15 01:00:00');"
expect_block "17 ck_pbom_yield 出成率下限 > 上限" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1802,1,'BOM-CK2',1,'x',6000,5000,8);" "ck_pbom_yield"
mut_ck17 "ck_pbom_yield" "process_bom" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1802,1,'BOM-CK2',1,'x',6000,5000,8);"
expect_block "17 ck_pbom_tol 称重容差 > 10%" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,balance_tol_bp,created_by) VALUES (1803,1,'BOM-CK3',1,'x',4000,5000,1001,8);" "ck_pbom_tol"
mut_ck17 "ck_pbom_tol" "process_bom" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,balance_tol_bp,created_by) VALUES (1803,1,'BOM-CK3',1,'x',4000,5000,1001,8);"
expect_block "17 ck_pbom_act ACTIVE 却没 activated_at" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status) VALUES (1804,1,'BOM-CK4',1,'x',4000,5000,8,'ACTIVE');" "ck_pbom_act"
mut_ck17 "ck_pbom_act" "process_bom" "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status) VALUES (1804,1,'BOM-CK4',1,'x',4000,5000,8,'ACTIVE');"
expect_block "17 ck_pboml_qty BOM 行标准量为 0" "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1801,1702,1,'INPUT',1701,0);" "ck_pboml_qty"
mut_ck17 "ck_pboml_qty" "process_bom_line" "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1801,1702,1,'INPUT',1701,0);"
expect_block "17 ck_prc_nonneg 计划量为负" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1811,1,'PRC-CK1','2026-10-15',1701,1790,-1,8);" "ck_prc_nonneg"
mut_ck17 "ck_prc_nonneg" "process_order" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1811,1,'PRC-CK1','2026-10-15',1701,1790,-1,8);"
expect_block "17 ck_prc_reverse 累计冲回 > 累计领用" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,issued_qty_milli,reversed_qty_milli) VALUES (1812,1,'PRC-CK2','2026-10-15',1701,1790,100,8,100,101);" "ck_prc_reverse"
mut_ck17 "ck_prc_reverse" "process_order" "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,issued_qty_milli,reversed_qty_milli) VALUES (1812,1,'PRC-CK2','2026-10-15',1701,1790,100,8,100,101);"
expect_block "17 ck_prci_qty 领用量为 0" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1811,1,1710,9,'PRCI:1710:ck1',1791,'PALLET',1781,1782,1830,1701,1701,'2026-10-20',0,21);" "ck_prci_qty"
mut_ck17 "ck_prci_qty" "process_issue" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1811,1,1710,9,'PRCI:1710:ck1',1791,'PALLET',1781,1782,1830,1701,1701,'2026-10-20',0,21);"
expect_block "17 ck_prci_op op_key 前缀不是 PRCI:" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1812,1,1710,8,'NOPE:1710:ck2',1791,'PALLET',1781,1782,1831,1701,1701,'2026-10-20',1,21);" "ck_prci_op"
mut_ck17 "ck_prci_op" "process_issue" "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1812,1,1710,8,'NOPE:1710:ck2',1791,'PALLET',1781,1782,1831,1701,1701,'2026-10-20',1,21);"
# PG 的 BIGINT 列会先把 1.5 取整成 2 再落库，ck_prco_int（= CAST(x AS BIGINT)）在 PG 上不可达（防御性检查）；SQLite 保留 REAL，同名用例在那边命中。
expect_allow "17 ck_prco_int（PG）：非整数净重先被 BIGINT 取整后落库（该 CHECK 在 PG 不可达，防御性）" "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1811,1,1710,1740,9,'FINISHED',1702,1870,1792,1.5,0,1.5,'2026-10-15 03:00:00','2026-10-18','2026-10-20');"
expect_block "17 ck_prcr_http 回执状态码不是 200/202" "INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1811,1,1710,'00000000-0000-4000-8000-000000001811','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',99,201,'{}',21);" "ck_prcr_http"
mut_ck17 "ck_prcr_http" "process_report" "INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1811,1,1710,'00000000-0000-4000-8000-000000001811','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',99,201,'{}',21);"
expect_block "17 ck_plt_self 成品批与原料批同批" "INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1811,1,1710,1750,1760,1721,1760);" "ck_plt_self"
mut_ck17 "ck_plt_self" "process_lot_trace" "INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1811,1,1710,1750,1760,1721,1760);"
echo "=== 2h-loss. docs/17 损耗定案主守卫：损耗行条件更新（审批回调 / 12h 过期任务重放，单会话）==="
expect_allow "17 损耗定案准备：1711 两条越界损耗行 1797/1798（PENDING_APPROVAL）" "BEGIN; INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1797,1,1711,1744,7,'LOSS',1701,NULL,NULL,320,20,300,'2026-10-15 03:00:00',NULL,NULL,9007,'WEIGH_DIFF',NULL,'PENDING_APPROVAL'); INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1798,1,1711,1744,8,'LOSS',1701,NULL,NULL,420,20,400,'2026-10-15 03:00:00',NULL,NULL,9008,'WEIGH_DIFF',NULL,'PENDING_APPROVAL'); COMMIT;"
R=$(psql -q -t -A -c "WITH u AS (UPDATE process_output SET loss_status='APPROVED', loss_approved_qty_milli=300, loss_exception_no=NULL WHERE id=1797 AND loss_status='PENDING_APPROVAL' RETURNING id) INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9971,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' FROM u")
R=$(psql -q -t -A -c "WITH u AS (UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0, loss_exception_no='EXC-1797' WHERE id=1797 AND loss_status='PENDING_APPROVAL' RETURNING id) INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9972,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' FROM u")
[ "$R" = "INSERT 0 0" ] || [ -z "$R" ] && ok "17 先审批通过，过期任务重放 → 条件更新 0 行，不建异常、不发事件" || bad "17 过期重放：$R"
R=$(psql -t -A -c "SELECT loss_status || '/' || COALESCE(loss_exception_no,'-') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9971,9972)) FROM process_output WHERE id=1797")
[ "$R" = "APPROVED/-/1" ] && ok "17 审批→过期重放后 状态/异常单/loss_settled = $R" || bad "17 审批→过期重放后 = $R（期望 APPROVED/-/1）"
R=$(psql -q -t -A -c "WITH u AS (UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0, loss_exception_no='EXC-1798' WHERE id=1798 AND loss_status='PENDING_APPROVAL' RETURNING id) INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9981,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' FROM u")
R=$(psql -q -t -A -c "WITH u AS (UPDATE process_output SET loss_status='APPROVED', loss_approved_qty_milli=400, loss_exception_no=NULL WHERE id=1798 AND loss_status='PENDING_APPROVAL' RETURNING id) INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9982,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' FROM u")
R=$(psql -q -t -A -c "WITH u AS (UPDATE process_output SET loss_status='REJECTED', loss_approved_qty_milli=0, loss_exception_no='EXC-1798B' WHERE id=1798 AND loss_status='PENDING_APPROVAL' RETURNING id) INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9983,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' FROM u")
R=$(psql -t -A -c "SELECT loss_status || '/' || COALESCE(loss_exception_no,'-') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9981,9982,9983)) FROM process_output WHERE id=1798")
[ "$R" = "EXPIRED_TO_EXCEPTION/EXC-1798/1" ] && ok "17 先过期转异常，审批通过/驳回回调重放 → 仍 $R（异常单 1 张、loss_settled 1 条）" || bad "17 过期→审批重放后 = $R（期望 EXPIRED_TO_EXCEPTION/EXC-1798/1）"
expect_block "17 绕过条件更新：已 APPROVED 直接改 REJECTED" "UPDATE process_output SET loss_status='REJECTED', loss_approved_qty_milli=0, loss_exception_no='EXC-X' WHERE id=1797;" "process_loss_settle_once"
expect_block "17 定案后改异常单号" "UPDATE process_output SET loss_exception_no='EXC-Y' WHERE id=1798;" "process_loss_settle_once"
expect_block "17 过期转异常不带异常单号" "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1799,1,1711,1744,9,'LOSS',1701,NULL,NULL,120,20,100,'2026-10-15 03:00:00',NULL,NULL,9009,'WEIGH_DIFF',NULL,'PENDING_APPROVAL'); UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0 WHERE id=1799;" "ck_prco_loss_settle"
expect_block "17 非 LOSS 行（SETTLED）不能改成待审" "UPDATE process_output SET loss_status='PENDING_APPROVAL' WHERE output_role='FINISHED' AND process_order_id=1711;" "process_loss_settle_once"

echo "=== 2h-sp. search_path 固定（pg_catalog, public）：目录断言 + 同名表劫持 + 变异检查（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;

CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.process_bom (id BIGINT, status TEXT);
INSERT INTO hj_evil.process_bom VALUES (999999,'ACTIVE');
SET LOCAL search_path = public;
DO $hj$ BEGIN INSERT INTO public.process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17099,999999,1,'INPUT',1701,1000); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17099,999999,1,'INPUT',1701,1000); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_pbom_forward','trg_pboml_frozen','trg_prc_snapshot','trg_prc_insert','trg_prci_immutable','trg_prco_immutable')), true);
ALTER FUNCTION public.trg_pboml_frozen() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_pbom_forward','trg_pboml_frozen','trg_prc_snapshot','trg_prc_insert','trg_prci_immutable','trg_prco_immutable')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17099,999999,1,'INPUT',1701,1000); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/6" ] && ok "本 PR 新增/重定义的 6 个 PL/pgSQL 函数 proconfig 都含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "search_path 目录断言：缺失/总数 = $HC0（期望 0/6）"
[ -n "$HB" ] && [ "$HF" = "$HB" ] && ok "劫持：wms_app 在自建 schema hj_evil 建同名表 process_bom 并置于 search_path 首位，trg_pboml_frozen() 仍读 public（结果与无劫持一致：$HB）" || bad "劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/6" ] && [ "$HM" != "$HB" ] && ok "变异检查：RESET trg_pboml_frozen() 的 search_path 后，目录断言变红（$HC1）且劫持生效（$HM），两条断言都能抓到" || bad "变异检查没变红：目录=$HC1 劫持后=$HM 基准=$HB"
echo "=== 2i. docs/11 集成：outbox 节点序号、入站报文 ==="
expect_allow "11 outbox 事件（node 3, seq 1）" \
  "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (100,'wms.shipment.completed','SHP1','{}',1,3,1);"
expect_block "11 同节点 seq 重复（回传顺序被破坏）" \
  "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (101,'wms.shipment.completed','SHP2','{}',1,3,1);" \
  "uq_outbox_seq"
expect_allow "11 不同节点同 seq 合法" \
  "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (102,'wms.shipment.completed','SHP3','{}',1,4,1);"
expect_block "11 outbox 非法状态" \
  "UPDATE outbox_event SET status='LOST' WHERE id=100;" \
  "ck_outbox_status"
expect_allow "11 入站报文落库" \
  "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (100,'ERP','SALES_ORDER','SO-1','{}','h1');"
expect_block "11 同源同单号重复落库" \
  "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (101,'ERP','SALES_ORDER','SO-1','{}','h2');" \
  "uq_in_msg"
expect_block "11 入站报文非法状态" \
  "UPDATE inbound_message SET status='OK' WHERE id=100;" \
  "ck_in_msg_status"

expect_allow "11 推送日志：同单号重推各记一行（只追加，不唯一；保留 90 天）" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,warehouse_id,payload_sha,payload,received_at,result_status,retain_until) VALUES (1,'ERP','SALES_ORDER','SO-1',1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00'),(2,'ERP','SALES_ORDER','SO-1',1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:05:00','DUPLICATE','2027-01-13 01:05:00');"
expect_block "11 推送日志结果取值" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (3,'ERP','SALES_ORDER','SO-3','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','OK','2027-01-13 01:00:00');" \
  "ck_upl_result"
expect_block "11 I1 保留期等于接收时间" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (4,'ERP','SALES_ORDER','SO-4','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-15 01:00:00');" \
  "ck_upl_retain"
expect_block "11 I1 保留期只有 1 秒" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (5,'ERP','SALES_ORDER','SO-5','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-15 01:00:01');" \
  "ck_upl_retain"
expect_block "11 I1 保留期 7 天（旧口径，现低于 90 天下限）" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (6,'ERP','SALES_ORDER','SO-6','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-22 01:00:00');" \
  "ck_upl_retain"
expect_block "11 I1 保留期 90 天差 1 秒" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (7,'ERP','SALES_ORDER','SO-7','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 00:59:59');" \
  "ck_upl_retain"
expect_allow "11 I1 保留期恰好 90 天（边界放行）" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (8,'ERP','SALES_ORDER','SO-8','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00');"
expect_block "11 payload_sha 大写 hex" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (9,'ERP','SALES_ORDER','SO-9','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00');" \
  "ck_upl_sha"
expect_block "11 payload_sha 长度 63" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (10,'ERP','SALES_ORDER','SO-10','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00');" \
  "ck_upl_sha"
expect_block "11 payload_sha 非 hex（z）" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (11,'ERP','SALES_ORDER','SO-11','zaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00');" \
  "ck_upl_sha"
expect_block "11 B1 只追加：UPDATE 推送日志（改结果+原文）" \
  "UPDATE upstream_push_log SET result_status='REJECTED', payload='x' WHERE id=1;" \
  "append_only_violation: upstream_push_log"
expect_block "11 B1 只追加：DELETE 推送日志" \
  "DELETE FROM upstream_push_log WHERE id=1;" \
  "append_only_violation: upstream_push_log"
expect_allow "11 写一条已过保留期的旧日志（归档用例）" \
  "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (20,'ERP','SALES_ORDER','SO-OLD','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','{}','2020-01-01 00:00:00','ACCEPTED','2020-04-01 00:00:00');"
expect_block "11 B1 超级用户 DELETE 已过期行（非归档角色也拦）" \
  "DELETE FROM upstream_push_log WHERE id=20;" \
  "append_only_violation: upstream_push_log"
expect_block "11 B1 TRUNCATE 推送日志" \
  "TRUNCATE upstream_push_log;" \
  "append_only_violation: upstream_push_log"
OUT=$(psql_capture "SET ROLE wms_app; INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (21,'ERP','SALES_ORDER','SO-21','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','{}','2026-10-15 02:00:00','ACCEPTED','2027-01-13 02:00:00');")
case "$OUT" in *ERROR*) bad "I2 wms_app INSERT 推送日志被拒：$OUT";; *) ok "I2 wms_app 可 INSERT 推送日志";; esac
OUT=$(psql -q -t -A -c "SET ROLE wms_app; SELECT count(*) FROM upstream_push_log;")
case "$OUT" in *ERROR*) bad "I2 wms_app SELECT 推送日志被拒：$OUT";; *) ok "I2 wms_app 可 SELECT 推送日志";; esac
OUT=$(psql_capture "SET ROLE wms_app; UPDATE upstream_push_log SET result_status='REJECTED' WHERE id=1;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_app UPDATE 推送日志 → permission denied";; *) bad "wms_app UPDATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM upstream_push_log WHERE id=20;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_app DELETE（即使已过期）→ permission denied";; *) bad "wms_app DELETE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; TRUNCATE upstream_push_log;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_app TRUNCATE → permission denied";; *) bad "wms_app TRUNCATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_cleaner; DELETE FROM upstream_push_log WHERE id=20;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_cleaner 直接 DELETE 推送日志 → permission denied（只能 EXECUTE 函数）";; *) bad "wms_cleaner 直删未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_cleaner; DELETE FROM upstream_push_log WHERE id=1;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_cleaner 直接 DELETE 未过期日志（id=1）→ permission denied";; *) bad "wms_cleaner 删未过期日志未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_cleaner; UPDATE upstream_push_log SET result_status='REJECTED' WHERE id=20;")
case "$OUT" in *"permission denied for table upstream_push_log"*) ok "B1 wms_cleaner 直接 UPDATE 推送日志 → permission denied";; *) bad "wms_cleaner UPDATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_purge_owner; DELETE FROM upstream_push_log WHERE id=1;")
case "$OUT" in *"append_only_violation: upstream_push_log"*) ok "B1 wms_purge_owner 删未过期日志 → 触发器 append_only_violation（只放行过期行的 DELETE）";; *) bad "wms_purge_owner 删未过期未被拦：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_purge_owner; UPDATE upstream_push_log SET result_status='REJECTED' WHERE id=20;")
case "$OUT" in *"append_only_violation: upstream_push_log"*|*"permission denied for table upstream_push_log"*) ok "B1 wms_purge_owner UPDATE 过期日志 → 被拒";; *) bad "wms_purge_owner UPDATE 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; SELECT * FROM purge_push_log();")
case "$OUT" in *"permission denied for function purge_push_log"*) ok "B1 wms_app 调 purge_push_log() → permission denied";; *) bad "wms_app 调函数未被拒：$OUT";; esac
R=$(psql -t -A -c "SELECT p.prosecdef::text || '/' || array_to_string(p.proconfig, ',') || '/' || r.rolname || '/' || has_function_privilege('public', p.oid, 'EXECUTE')::text FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.proname = 'purge_push_log'")
[ "${R%%/*}/$(echo "$R" | cut -d/ -f2)/${R##*/}" = "true/search_path=pg_catalog, public, pg_temp/false" ] && ok "B1 purge_push_log：SECURITY DEFINER、固定 search_path、PUBLIC 无 EXECUTE（属主 $(echo "$R" | cut -d/ -f3)；属主改 wms_purge_owner 由 #2 99 授予）" || bad "purge_push_log 属性：$R"
OUT=$(psql -q -t -A -c "SET ROLE wms_cleaner; SELECT push_log_deleted FROM purge_push_log();" 2>&1)
R2=$(psql -t -A -c "SELECT count(*) FROM upstream_push_log WHERE retain_until < (now() AT TIME ZONE 'UTC')")
[ "$OUT/$R2" = "1/0" ] && ok "B1 wms_cleaner 调 purge_push_log() 只删 1 条已过 retain_until 的日志，未过期行都在（$OUT/$R2）" || bad "purge_push_log 结果：$OUT / 剩余过期 $R2（期望 1/0）"
N=$(psql -t -A -c "SELECT count(*) FROM upstream_push_log WHERE id IN (1,2,8,21)")
[ "$N" = "4" ] && ok "B1 各种绕过后未到期日志仍在（4 行）" || bad "未到期日志被动过：$N"

# round 8 语义（不改触发器）：继承 wms_app 的登录角色直接登录（不 SET ROLE），PENDING 但带 sent_at → outbox_insert_not_pending
R=$(psql -U wms_login_test -t -A -c "SELECT current_user || '/' || session_user || '/' || pg_has_role('wms_app','member')::text" 2>&1)
[ "$R" = "wms_login_test/wms_login_test/true" ] && ok "11 登录角色直连（不 SET ROLE）：current_user=session_user=wms_login_test，继承 wms_app" || bad "11 登录角色直连失败：$R"
OUT=$(psql -U wms_login_test -q -c "INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (19960,'t','OBT-LOGIN-1','{}','PENDING',now() AT TIME ZONE 'UTC');" 2>&1)
case "$OUT" in *outbox_insert_not_pending*) ok "11 登录角色直连插 PENDING 但带 sent_at → outbox_insert_not_pending";; *) bad "11 登录角色直连插 PENDING+sent_at 未按 outbox_insert_not_pending 拦下：$OUT"; psql -q -c "DELETE FROM outbox_event WHERE id=19960" >/dev/null 2>&1;; esac
echo "=== 2i2. docs/11 小吴 C1 死信阻塞同 biz_key / C2 409 判定 / C3 形态 A relay 补 seq ==="
expect_allow "C1 同一单 3 个事件入队（OBT-C1：创建/变更/取消）" "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9101,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9102,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9103,'wms.outbound.changed','OBT-C1','{}',1,0,0); COMMIT;"
expect_allow "C1 第 1 个事件投递成功（SENDING→SENT 2XX）" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9101; UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=(now() AT TIME ZONE 'UTC') WHERE id=9101; COMMIT;"
expect_allow "C1 第 2 个事件进死信（SENDING→FAILED→DEAD）" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9102; UPDATE outbox_event SET status='FAILED' WHERE id=9102; UPDATE outbox_event SET status='DEAD' WHERE id=9102; COMMIT;"
expect_block "C1 第 3 个事件在前序 DEAD 时不能投递（验收用例）" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9103; COMMIT;" "outbox_bizkey_blocked"
expect_block "C1 同一 biz_key 第二条 DEAD" "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq,status) VALUES (9104,'wms.outbound.changed','OBT-C1','{}',1,0,0,'DEAD'); COMMIT;" "uq_outbox_dead_bizkey"
expect_block "C1 跳过不带审计（无人、无时间、无原因）" "BEGIN; UPDATE outbox_event SET status='SKIPPED' WHERE id=9102; COMMIT;" "ck_outbox_skip"
expect_block "C1 跳过原因过短" "BEGIN; UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='x' WHERE id=9102; COMMIT;" "ck_outbox_skip"
expect_block "C1 非 DEAD 事件不能直接跳过（PENDING→SKIPPED）" "BEGIN; UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='下游已手工补录' WHERE id=9103; COMMIT;" "outbox_illegal_transition"
expect_block "C1 非 SKIPPED 行不能带跳过审计字段" "BEGIN; UPDATE outbox_event SET skip_reason='下游已手工补录' WHERE id=9103; COMMIT;" "ck_outbox_skip"
expect_allow "C1 人工跳过死信（谁/何时/原因齐全）" "BEGIN; UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='下游已手工补录' WHERE id=9102; COMMIT;"
expect_allow "C1 跳过后第 3 个事件放行" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9103; COMMIT;"
expect_block "C1 SKIPPED 是终态（不能改回 PENDING）" "BEGIN; UPDATE outbox_event SET status='PENDING', skipped_by=NULL, skipped_at=NULL, skip_reason=NULL WHERE id=9102; COMMIT;" "outbox_illegal_transition"
expect_allow "C1 另一单：头事件 DEAD、后续 PENDING" "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq,status) VALUES (9201,'wms.outbound.changed','OBT-C1B','{}',1,0,0,'DEAD'); INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9202,'wms.outbound.changed','OBT-C1B','{}',1,0,0); COMMIT;"
expect_block "C1 重放前后续事件被阻塞" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9202; COMMIT;" "outbox_bizkey_blocked"
expect_allow "C1 重放死信成功（DEAD→PENDING→SENDING→SENT，replay_count+1）" "BEGIN; UPDATE outbox_event SET status='PENDING', replay_count=replay_count+1 WHERE id=9201; UPDATE outbox_event SET status='SENDING' WHERE id=9201; UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=(now() AT TIME ZONE 'UTC') WHERE id=9201; COMMIT;"
expect_allow "C1 重放成功后后续事件放行" "BEGIN; UPDATE outbox_event SET status='SENDING' WHERE id=9202; COMMIT;"
expect_block "C2 SENT 不注明依据" "BEGIN; UPDATE outbox_event SET status='SENT', sent_at=(now() AT TIME ZONE 'UTC') WHERE id=9202; COMMIT;" "ck_outbox_ack"
expect_block "C2 SENT 依据为任意 409" "BEGIN; UPDATE outbox_event SET status='SENT', ack_kind='409', sent_at=(now() AT TIME ZONE 'UTC') WHERE id=9202; COMMIT;" "ck_outbox_ack"
expect_block "C2 非 SENT 行带 ack_kind" "BEGIN; UPDATE outbox_event SET status='FAILED', ack_kind='DUP_409' WHERE id=9202; COMMIT;" "ck_outbox_ack"
expect_allow "C2 下游 409 且识别为同一请求重复 → SENT(DUP_409)" "BEGIN; UPDATE outbox_event SET status='SENT', ack_kind='DUP_409', sent_at=(now() AT TIME ZONE 'UTC') WHERE id=9202; COMMIT;"
expect_block "C2 SENT 是终态（不能改回 PENDING 重发；合并 02 后先由 02 的 SENT 终态守卫拦）" "BEGIN; UPDATE outbox_event SET status='PENDING', ack_kind=NULL WHERE id=9202; COMMIT;" "expiry_backdate: status"
expect_allow "C3 形态 A 业务事务只写 seq=0（不碰 numbering_segment）" "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9301,'wms.outbound.changed','OBT-C3-9301','{}',1,9,0),(9302,'wms.outbound.changed','OBT-C3-9302','{}',1,9,0),(9303,'wms.outbound.changed','OBT-C3-9303','{}',1,9,0); COMMIT;"
expect_allow "C3 relay 提交后补号" "BEGIN; UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 9 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 9) m WHERE outbox_event.id = r.id; COMMIT;"
expect_block "C3 已补的 seq 不可改" "BEGIN; UPDATE outbox_event SET seq=100 WHERE id=9301; COMMIT;" "outbox_seq_immutable"
expect_block "C3 已补的 seq 不可清零重补" "BEGIN; UPDATE outbox_event SET seq=0 WHERE id=9301; COMMIT;" "outbox_seq_immutable"
R=$(psql -q -t -A -c "SELECT string_agg(id || ':' || seq, ',' ORDER BY id) FROM outbox_event WHERE node_id = 9")
[ "$R" = "9301:1,9302:2,9303:3" ] && ok "C3 relay 按 id 顺序补 1..3（$R）" || bad "C3 relay 补号：$R"
expect_allow "C3 relay 重跑幂等（无 seq=0 行则不动）" "UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 9 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 9) m WHERE outbox_event.id = r.id;"
R=$(psql -q -t -A -c "SELECT count(*) FROM numbering_segment WHERE biz_prefix LIKE 'OUTBOX%'")
[ "$R" = "0" ] && ok "C3 形态 A 不再写 numbering_segment(OUTBOX:node)" || bad "numbering_segment 出现 OUTBOX 行：$R"

echo "=== 2i3. 第 11 篇 Q1：离线纸质单补录 offline_paper_record（PAPER_BACKFILL）==="
expect_allow "Q1 正向：提交 PENDING（恢复联网后 14h，窗口内）" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (11,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL'); COMMIT;"
expect_allow "Q1 正向：主管（≠ 申请人）审批通过" "BEGIN; UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2026-10-15 11:00:00' WHERE id=11; COMMIT;"
expect_allow "Q1 正向：过期补录落 EXPIRED 并挂异常单" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (12,1,'PDA-07','PICK_CONFIRM','PK-L2','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',5001,'PAPER_BACKFILL'); COMMIT;"
expect_block "Q1 反向：自批（审批人 = 申请人）" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (13,1,'PDA-07','PICK_CONFIRM','PK-L3','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL'); UPDATE offline_paper_record SET status='APPROVED', approver_id=7, approved_at='2026-10-15 11:00:00' WHERE id=13; COMMIT;" "ck_paper_sod"
expect_block "Q1 反向：backfill_deadline_at ≠ 恢复联网 + 24h（写成 +12h）" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (14,1,'PDA-07','PICK_CONFIRM','PK-L4','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 08:00:00','2026-10-15 07:00:00','PENDING',NULL,'PAPER_BACKFILL'); COMMIT;" "ck_paper_deadline"
expect_block "Q1 反向：过期后仍以 PENDING 提交" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (15,1,'PDA-07','PICK_CONFIRM','PK-L5','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','PENDING',NULL,'PAPER_BACKFILL'); COMMIT;" "ck_paper_expired"
expect_block "Q1 反向：过期但不挂异常单" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (16,1,'PDA-07','PICK_CONFIRM','PK-L6','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',NULL,'PAPER_BACKFILL'); COMMIT;" "ck_paper_expired"
expect_block "Q1 反向：审批类型不是 PAPER_BACKFILL" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (17,1,'PDA-07','PICK_CONFIRM','PK-L7','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'SCRAP_MISREPORT'); COMMIT;" "ck_paper_type"
expect_block "Q1 反向：APPROVED 不带审批人" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (18,1,'PDA-07','PICK_CONFIRM','PK-L8','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL'); UPDATE offline_paper_record SET status='APPROVED' WHERE id=18; COMMIT;" "ck_paper_approve"
expect_block "Q1 反向：同仓同 biz_key 重复补录" "BEGIN; INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (19,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL'); COMMIT;" "uq_paper_bizkey"
R=$(psql -t -A -c "SELECT string_agg(id || ':' || status, ',' ORDER BY id) FROM offline_paper_record")
[ "$R" = "11:APPROVED,12:EXPIRED" ] && ok "Q1 反向用例全部回滚，只剩 11:APPROVED、12:EXPIRED" || bad "Q1 残留：$R"
echo "=== 2i4. 第 11 篇时间加固（小玛丽 time-scan 11-1…11-6；00 §6.8）==="
PAPER_COLS="id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type"
UPL_COLS="id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until"
H64=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
q11() { psql -t -A -q -c "$1" 2>&1 | tr -d '\n'; }
expect_allow "11-1 wms_app 插入倒填 received_at=2000-01-01 / retain_until=2000-04-01（库改写，不报错）" "SET ROLE wms_app; INSERT INTO upstream_push_log ($UPL_COLS) VALUES (40,'ERP','SALES_ORDER','SO-T40','$H64','{}','2000-01-01 00:00:00','ACCEPTED','2000-04-01 00:00:00');"
R=$(q11 "SELECT (abs(extract(epoch FROM received_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || '/' || (received_at = date_trunc('second', received_at))::text || '/' || (retain_until >= received_at + interval '90 days')::text FROM upstream_push_log WHERE id=40")
[ "$R" = "true/true/true" ] && ok "11-1 落库 received_at = 当前 UTC 整秒，retain_until ≥ +90 天（$R）" || bad "11-1 received_at 未被库改写：$R"
OUT=$(psql -q -t -A -c "SET ROLE wms_cleaner; SELECT push_log_deleted FROM purge_push_log();" 2>&1); R=$(q11 "SELECT count(*) FROM upstream_push_log WHERE id=40")
[ "$R" = "1" ] && ok "11-1 purge_push_log() 后倒填的日志仍在（删 $OUT 行，id=40 剩 $R）" || bad "11-1 倒填日志被清掉：$R"
R=$(q11 "BEGIN; ALTER TABLE upstream_push_log DISABLE TRIGGER trg_upl_server_time; SET LOCAL ROLE wms_app; INSERT INTO upstream_push_log ($UPL_COLS) VALUES (41,'ERP','SALES_ORDER','SO-T41','$H64','{}','2000-01-01 00:00:00','ACCEPTED','2000-04-01 00:00:00'); RESET ROLE; SELECT 'M=' || (received_at < '2001-01-01')::text FROM upstream_push_log WHERE id=41; ROLLBACK;")
[ "${R#*M=}" = "true" ] && ok "11-1 变异：停用 trg_upl_server_time 后倒填照样落库（上面的断言会变红）" || bad "11-1 变异未变红：$R"
expect_block "11-2 wms_app 插入 expires_at 已过期（2000-01-01）" "SET ROLE wms_app; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('t11past','h','{}',200,'2000-01-01 00:00:00');" "idem_expires_in_past"
expect_allow "11-2 wms_app 插入 ttl_seconds=600、created_at 倒填 2000 年（库改写）" "SET ROLE wms_app; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,ttl_seconds,created_at,expires_at) VALUES ('t11ttl','h','{}',200,600,'2000-01-01 00:00:00','2099-01-01 00:00:00');"
R=$(q11 "SELECT extract(epoch FROM expires_at - created_at)::int::text || '/' || (abs(extract(epoch FROM created_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || '/' || (created_at = date_trunc('second', created_at))::text FROM idempotency_record WHERE idem_key='t11ttl'")
[ "$R" = "600/true/true" ] && ok "11-2 expires_at = 库时间 created_at + ttl（$R）" || bad "11-2 expires_at 未由库计算：$R"
OUT=$(psql -q -t -A -c "SET ROLE wms_cleaner; SELECT idem_deleted FROM purge_expired();" 2>&1); R=$(q11 "SELECT count(*) FROM idempotency_record WHERE idem_key='t11ttl'")
[ "$R" = "1" ] && ok "11-2 purge_expired() 不会立即清掉新记录" || bad "11-2 新记录被清：$R"
expect_block "11-2 ttl_seconds 超过 90 天" "SET ROLE wms_app; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,ttl_seconds) VALUES ('t11big','h','{}',200,7776001);" "ck_idem_ttl"
R=$(q11 "BEGIN; ALTER TABLE idempotency_record DISABLE TRIGGER trg_idem_server_time; SET LOCAL ROLE wms_app; INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('t11mut','h','{}',200,'2000-01-01 00:00:00'); RESET ROLE; SELECT 'M=' || count(*) FROM idempotency_record WHERE idem_key='t11mut'; ROLLBACK;")
[ "${R#*M=}" = "1" ] && ok "11-2 变异：停用 trg_idem_server_time 后过去的 expires_at 照样落库" || bad "11-2 变异未变红：$R"
expect_block "11-5 wms_app 6 年前的补录写 submitted_at=reconnected_at 仍以 PENDING 提交" "SET ROLE wms_app; INSERT INTO offline_paper_record ($PAPER_COLS) VALUES (40,1,'PDA-07','PICK_CONFIRM','PK-T40','2020-10-14 10:00:00',11,'{}',7,'2020-10-14 08:00:00','2020-10-14 20:00:00','2020-10-15 20:00:00','2020-10-14 20:00:00','PENDING',NULL,'PAPER_BACKFILL');" "ck_paper_expired"
R=$(q11 "BEGIN; ALTER TABLE offline_paper_record DISABLE TRIGGER trg_paper_server_time; SET LOCAL ROLE wms_app; INSERT INTO offline_paper_record ($PAPER_COLS) VALUES (41,1,'PDA-07','PICK_CONFIRM','PK-T41','2020-10-14 10:00:00',11,'{}',7,'2020-10-14 08:00:00','2020-10-14 20:00:00','2020-10-15 20:00:00','2020-10-14 20:00:00','PENDING',NULL,'PAPER_BACKFILL'); RESET ROLE; SELECT 'M=' || status FROM offline_paper_record WHERE id=41; ROLLBACK;")
[ "${R#*M=}" = "PENDING" ] && ok "11-5 变异：停用 trg_paper_server_time 后 6 年前补录照样 PENDING" || bad "11-5 变异未变红：$R"
expect_allow "11-5 wms_app 正常补录（恢复联网 2 小时前，submitted_at 乱填 2000 年由库改写）" "SET ROLE wms_app; INSERT INTO offline_paper_record ($PAPER_COLS) SELECT 42,1,'PDA-07','PICK_CONFIRM','PK-T42',t - interval '3 hours',11,'{}',7,t - interval '4 hours',t - interval '2 hours',t + interval '22 hours','2000-01-01 00:00:00','PENDING',NULL,'PAPER_BACKFILL' FROM (SELECT date_trunc('second', now() AT TIME ZONE 'UTC') AS t) x;"
expect_allow "11-5 wms_app 审批，approved_at 倒填 2000 年（库改写）" "SET ROLE wms_app; UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2000-01-01 00:00:00' WHERE id=42;"
R=$(q11 "SELECT (abs(extract(epoch FROM submitted_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || '/' || (abs(extract(epoch FROM approved_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || '/' || (approved_at = date_trunc('second', approved_at))::text FROM offline_paper_record WHERE id=42")
[ "$R" = "true/true/true" ] && ok "11-5 submitted_at、approved_at 都是库写的当前 UTC 整秒（$R）" || bad "11-5 时间未被库改写：$R"
expect_block "11-5 wms_app 事后改 reconnected_at（挪截止）" "SET ROLE wms_app; UPDATE offline_paper_record SET reconnected_at = reconnected_at + interval '1 day', backfill_deadline_at = backfill_deadline_at + interval '1 day' WHERE id=42;" "paper_time_immutable"
expect_block "11-5 超级用户事后改 approved_at（时间列不可改对所有角色）" "UPDATE offline_paper_record SET approved_at = '2000-01-01 00:00:00' WHERE id=42;" "paper_time_immutable"
R=$(q11 "BEGIN; ALTER TABLE offline_paper_record DISABLE TRIGGER trg_paper_server_time; UPDATE offline_paper_record SET approved_at = '2000-01-01 00:00:00' WHERE id=42; SELECT 'M=' || approved_at FROM offline_paper_record WHERE id=42; ROLLBACK;")
[ "${R#*M=}" = "2000-01-01 00:00:00" ] && ok "11-5 变异：停用触发器后 approved_at 可被改（paper_time_immutable 断言会变红）" || bad "11-5 不可改变异未变红：$R"
R=$(q11 "BEGIN; SET LOCAL TIME ZONE 'Asia/Shanghai'; SET LOCAL ROLE wms_app; INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (9501,'t11.tz',7,9501,1); INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (9501,'ERP','SALES_ORDER','SO-T9501','{}','h'); INSERT INTO numbering_segment (biz_prefix,date_key,next_value) VALUES ('T11','20261015',1); INSERT INTO idempotency_record (idem_key,req_hash,response,status_code) VALUES ('t11tz','h','{}',200); RESET ROLE; SELECT 'M=' || (SELECT (abs(extract(epoch FROM occurred_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND occurred_at = date_trunc('second', occurred_at))::text FROM audit_log WHERE id=9501) || '/' || (SELECT (abs(extract(epoch FROM received_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND received_at = date_trunc('second', received_at))::text FROM inbound_message WHERE id=9501) || '/' || (SELECT (abs(extract(epoch FROM updated_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND updated_at = date_trunc('second', updated_at))::text FROM numbering_segment WHERE biz_prefix='T11') || '/' || (SELECT (abs(extract(epoch FROM created_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM idempotency_record WHERE idem_key='t11tz'); ROLLBACK;")
[ "${R#*M=}" = "true/true/true/true" ] && ok "11-6 会话 Asia/Shanghai：audit_log.occurred_at / inbound_message.received_at / numbering_segment.updated_at / idem.created_at 落库是 UTC 整秒（${R#*M=}）" || bad "11-6 Asia/Shanghai 下不是 UTC：$R"
# 小玛丽 blocker：numbering_segment 只许前进（numbering_regress / numbering_key_immutable → 40930），inbound_message 判重键不可改（inbound_message_key_immutable → 40930）
expect_allow "NS1 准备：wms_app 建号段 T11N/20261015 next_value=1000" "SET ROLE wms_app; INSERT INTO numbering_segment (biz_prefix,date_key,next_value,step) VALUES ('T11N','20261015',1000,100);"
expect_allow "NS1 正向：取号原语 next_value = next_value + step" "SET ROLE wms_app; UPDATE numbering_segment SET next_value = next_value + step WHERE biz_prefix='T11N' AND date_key='20261015';"
R=$(q11 "SELECT next_value FROM numbering_segment WHERE biz_prefix='T11N'"); [ "$R" = "1100" ] && ok "NS1 取号后 next_value=1100" || bad "NS1 取号结果：$R"
expect_block "NS1 wms_app 把 next_value 调回 500（号段回退）" "SET ROLE wms_app; UPDATE numbering_segment SET next_value = 500 WHERE biz_prefix='T11N';" "numbering_regress"
expect_block "NS1 属主也不能把 next_value 调小" "UPDATE numbering_segment SET next_value = next_value - 1 WHERE biz_prefix='T11N';" "numbering_regress"
expect_block "NS1 step 改负再取号（等于回退）" "SET ROLE wms_app; UPDATE numbering_segment SET step = -100, next_value = next_value - 100 WHERE biz_prefix='T11N';" "numbering_regress"
expect_block "NS1 改键列 date_key（把今天的号段挪成别的日子）" "SET ROLE wms_app; UPDATE numbering_segment SET date_key='20261016' WHERE biz_prefix='T11N';" "numbering_key_immutable"
expect_block "NS1 改键列 biz_prefix" "UPDATE numbering_segment SET biz_prefix='T11X' WHERE biz_prefix='T11N';" "numbering_key_immutable"
expect_block "NS1 属主 DELETE 号段（删了重插 = 回退）" "DELETE FROM numbering_segment WHERE biz_prefix='T11N';" "numbering_regress"
expect_block "NS1 属主 TRUNCATE numbering_segment" "TRUNCATE numbering_segment;" "numbering_regress"
R=$(q11 "SELECT next_value FROM numbering_segment WHERE biz_prefix='T11N' AND date_key='20261015'"); [ "$R" = "1100" ] && ok "NS1 拒绝用例后号段仍为 1100" || bad "NS1 号段被改：$R"
R=$(q11 "BEGIN; ALTER TABLE numbering_segment DISABLE TRIGGER trg_numbering_guard; UPDATE numbering_segment SET next_value = 500 WHERE biz_prefix='T11N'; SELECT 'M=' || (next_value = 500)::text FROM numbering_segment WHERE biz_prefix='T11N'; ROLLBACK;")
[ "${R#*M=}" = "true" ] && ok "NS1 变异：停用 trg_numbering_guard 后号段可回退（上面的断言会变红）" || bad "NS1 变异未变红：$R"
R=$(q11 "BEGIN; ALTER TABLE numbering_segment DISABLE TRIGGER trg_numbering_guard; DELETE FROM numbering_segment WHERE biz_prefix='T11N'; INSERT INTO numbering_segment (biz_prefix,date_key,next_value) VALUES ('T11N','20261015',1); SELECT 'M=' || (next_value = 1)::text FROM numbering_segment WHERE biz_prefix='T11N'; ROLLBACK;")
[ "${R#*M=}" = "true" ] && ok "NS1 变异：停用后删了重插把号段回到 1（DELETE 断言会变红）" || bad "NS1 删除变异未变红：$R"
R=$(q11 "BEGIN; ALTER TABLE numbering_segment DISABLE TRIGGER trg_numbering_guard; UPDATE numbering_segment SET date_key='20261016' WHERE biz_prefix='T11N'; SELECT 'M=' || count(*)::text FROM numbering_segment WHERE biz_prefix='T11N' AND date_key='20261016'; ROLLBACK;")
[ "${R#*M=}" = "1" ] && ok "NS1 变异：停用后键列可改（键列断言会变红）" || bad "NS1 键列变异未变红：$R"
R=$(q11 "BEGIN; ALTER TABLE numbering_segment DISABLE TRIGGER trg_numbering_no_truncate; TRUNCATE numbering_segment; SELECT 'M=' || count(*)::text FROM numbering_segment; ROLLBACK;")
[ "${R#*M=}" = "0" ] && ok "NS1 变异：停用 trg_numbering_no_truncate 后可清空（TRUNCATE 断言会变红）" || bad "NS1 TRUNCATE 变异未变红：$R"
expect_allow "IM1 准备：入站报文 ERP/SALES_ORDER/SO-I1" "SET ROLE wms_app; INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (9601,'ERP','SALES_ORDER','SO-I1','{}','h');"
expect_allow "IM1 正向：处理状态可推进（status/processed_at/biz_ref）" "SET ROLE wms_app; UPDATE inbound_message SET status='DONE', processed_at = now() AT TIME ZONE 'UTC', biz_ref='OBT-1' WHERE id=9601;"
expect_block "IM1 改 external_no（腾出判重键让同号重推再进一次）" "SET ROLE wms_app; UPDATE inbound_message SET external_no='SO-I1-x' WHERE id=9601;" "inbound_message_key_immutable"
expect_block "IM1 改 source" "SET ROLE wms_app; UPDATE inbound_message SET source='WMS' WHERE id=9601;" "inbound_message_key_immutable"
expect_block "IM1 改 biz_type" "SET ROLE wms_app; UPDATE inbound_message SET biz_type='PURCHASE' WHERE id=9601;" "inbound_message_key_immutable"
expect_block "IM1 改 id" "UPDATE inbound_message SET id=9602 WHERE id=9601;" "inbound_message_key_immutable"
expect_block "IM1 同号重推再插（uq_in_msg）" "SET ROLE wms_app; INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (9603,'ERP','SALES_ORDER','SO-I1','{}','h');" "uq_in_msg"
R=$(q11 "BEGIN; ALTER TABLE inbound_message DISABLE TRIGGER trg_in_msg_key_immutable; UPDATE inbound_message SET external_no='SO-I1-x' WHERE id=9601; SELECT 'M=' || count(*)::text FROM inbound_message WHERE external_no='SO-I1-x'; ROLLBACK;")
[ "${R#*M=}" = "1" ] && ok "IM1 变异：停用 trg_in_msg_key_immutable 后判重键可改（上面的断言会变红）" || bad "IM1 变异未变红：$R"
R=$(q11 "BEGIN; ALTER TABLE audit_log ALTER COLUMN occurred_at SET DEFAULT now(); SET LOCAL TIME ZONE 'Asia/Shanghai'; INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (9502,'t11.tz',7,9502,1); SELECT 'M=' || (abs(extract(epoch FROM occurred_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM audit_log WHERE id=9502; ROLLBACK;")
[ "${R#*M=}" = "false" ] && ok "11-6 变异：occurred_at 改回 DEFAULT now() 后 Asia/Shanghai 下偏 8 小时（断言变红）" || bad "11-6 变异未变红：$R"
R=$(q11 "SELECT string_agg(c.relname || '.' || a.attname, ',') FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid WHERE c.relname IN ('upstream_push_log','offline_paper_record','idempotency_record','inbound_message','outbox_event','audit_log','numbering_segment') AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'timestamptz'::regtype")
[ -z "$R" ] && ok "11 时间列全是 TIMESTAMP（无 timestamptz）" || bad "11 有 timestamptz 列：$R"
R=$(q11 "SELECT count(*) FILTER (WHERE proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[]) || '/' || count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_upl_server_time','trg_idem_server_time','trg_paper_server_time')")
[ "$R" = "3/3" ] && ok "11 时间加固新增 3 个函数 search_path = pg_catalog, public, pg_temp（00 §6.9）" || bad "11 新函数 search_path：$R"
# T2（Doro 裁定）：audit_log.occurred_at / inbound_message.received_at 由库写，设备原始时间留在 client_occurred_at
expect_allow "T2 wms_app 写审计：occurred_at 倒填 2000 年、client_occurred_at=2000-01-01 00:00:00" "SET ROLE wms_app; INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,occurred_at,client_occurred_at) VALUES (9503,'t11.t2',7,9503,1,'2000-01-01 00:00:00','2000-01-01 00:00:00');"
expect_allow "T2 wms_app 写入站报文：received_at 倒填 2000 年、client_occurred_at=2000-01-01 00:00:00" "SET ROLE wms_app; INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at,client_occurred_at) VALUES (9503,'ERP','SALES_ORDER','SO-T9503','{}','h','2000-01-01 00:00:00','2000-01-01 00:00:00');"
R=$(q11 "SELECT (SELECT (abs(extract(epoch FROM occurred_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || ',' || client_occurred_at FROM audit_log WHERE id=9503) || '/' || (SELECT (abs(extract(epoch FROM received_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || ',' || client_occurred_at FROM inbound_message WHERE id=9503)")
[ "$R" = "true,2000-01-01 00:00:00/true,2000-01-01 00:00:00" ] && ok "T2 occurred_at / received_at 被改写为库时间，client_occurred_at 原样保留（$R）" || bad "T2 改写/保留不符：$R"
R=$(q11 "BEGIN; ALTER TABLE audit_log DISABLE TRIGGER trg_audit_server_time; ALTER TABLE inbound_message DISABLE TRIGGER trg_in_msg_server_time; SET LOCAL ROLE wms_app; INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,occurred_at) VALUES (9504,'t11.t2',7,9504,1,'2000-01-01 00:00:00'); INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (9504,'ERP','SALES_ORDER','SO-T9504','{}','h','2000-01-01 00:00:00'); RESET ROLE; SELECT 'M=' || (SELECT occurred_at FROM audit_log WHERE id=9504) || '/' || (SELECT received_at FROM inbound_message WHERE id=9504); ROLLBACK;")
[ "${R#*M=}" = "2000-01-01 00:00:00/2000-01-01 00:00:00" ] && ok "T2 变异：停用两个触发器后倒填照样落库（上面的断言会变红）" || bad "T2 变异未变红：$R"
expect_block "T2 client_occurred_at 带小数秒（审计）" "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,client_occurred_at) VALUES (9505,'t11.t2',7,9505,1,'2026-01-01 00:00:00.5');" "ck_audit_cts"
expect_block "T2 client_occurred_at 带小数秒（入站报文）" "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,client_occurred_at) VALUES (9505,'ERP','SALES_ORDER','SO-T9505','{}','h','2026-01-01 00:00:00.5');" "ck_in_msg_cts"
expect_allow "T2 client_occurred_at 不设容差：1999 年、2099 年都接受" "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,client_occurred_at) VALUES (9506,'ERP','SALES_ORDER','SO-T9506','{}','h','1999-01-01 00:00:00'),(9507,'ERP','SALES_ORDER','SO-T9507','{}','h','2099-01-01 00:00:00');"
T2CAT="SELECT (SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND prosrc LIKE '%client_occurred_at%') + (SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND pg_get_constraintdef(oid) LIKE '%client_occurred_at%' AND conname NOT IN ('ck_audit_cts','ck_in_msg_cts','ck_pod_op_cct')) + (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexdef LIKE '%client_occurred_at%') + (SELECT count(*) FROM pg_views WHERE schemaname='public' AND definition LIKE '%client_occurred_at%')"
R=$(q11 "$T2CAT")
[ "$R" = "0" ] && ok "T2 client_occurred_at 不进任何函数（含 purge_expired / purge_push_log）、约束（格式 CHECK 除外）、索引、视图" || bad "T2 client_occurred_at 被引用：$R"
R=$(q11 "BEGIN; CREATE FUNCTION public.t11_bad_purge() RETURNS void LANGUAGE sql SET search_path = pg_catalog, public, pg_temp AS \$f\$ SELECT 1 FROM public.audit_log WHERE client_occurred_at < now() \$f\$; SELECT 'M=' || ($T2CAT); ROLLBACK;")
[ "${R#*M=}" = "1" ] && ok "T2 变异：加一个按 client_occurred_at 清理的函数，目录断言变红" || bad "T2 目录变异未变红：$R"
R=$(q11 "SELECT string_agg(id::text, ',' ORDER BY id) FROM offline_paper_record WHERE id >= 40")
[ "$R" = "42" ] && ok "11-5 反向用例全部回滚（只剩 42）" || bad "11-5 残留：$R"
echo "=== 2i-sp. search_path 固定（pg_catalog, public）：目录断言 + 同名表劫持 + 变异检查（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;
INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (19950,'t','HJ-1','{}',1,3,0);
CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.outbox_event (id BIGINT, biz_key TEXT, status TEXT);
INSERT INTO hj_evil.outbox_event VALUES (1,'HJ-1','PENDING');
SET LOCAL search_path = public;
DO $hj$ BEGIN UPDATE public.outbox_event SET status='SENDING' WHERE id=19950; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN UPDATE public.outbox_event SET status='SENDING' WHERE id=19950; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_upl_append_only','purge_push_log','trg_outbox_order_guard','trg_purge_guard','trg_expiry_forward','trg_outbox_insert_pending')), true);
ALTER FUNCTION public.trg_outbox_order_guard() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_upl_append_only','purge_push_log','trg_outbox_order_guard','trg_purge_guard','trg_expiry_forward','trg_outbox_insert_pending')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN UPDATE public.outbox_event SET status='SENDING' WHERE id=19950; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/6" ] && ok "本 PR 新增/重定义的 6 个 PL/pgSQL 函数 proconfig 都含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "search_path 目录断言：缺失/总数 = $HC0（期望 0/6）"
[ -n "$HB" ] && [ "$HF" = "$HB" ] && ok "劫持：wms_app 在自建 schema hj_evil 建同名表 outbox_event 并置于 search_path 首位，trg_outbox_order_guard() 仍读 public（结果与无劫持一致：$HB）" || bad "劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/6" ] && [ "$HM" != "$HB" ] && ok "变异检查：RESET trg_outbox_order_guard() 的 search_path 后，目录断言变红（$HC1）且劫持生效（$HM），两条断言都能抓到" || bad "变异检查没变红：目录=$HC1 劫持后=$HM 基准=$HB"
echo "=== 3. §5.6 盘点差异生成列（实盘 − 基准账面 − 期间流水）==="
seed "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (1,'CNT-SH01-0001-20261015-000001',1,'FULL','{}','DRAFT','2026-10-15 02:00:00');"   # 长流：count_line.count_id 加外键后的父行
seed "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (1,1,1,1,1,100000,-30000,68000);"
assert_n "种子 count_line" "SELECT count(*) FROM count_line" 1
D=$(psql -t -A -c "SELECT diff_qty_milli FROM count_line WHERE id=1")
[ "$D" = "-2000" ] && ok "diff_qty_milli = $D（预期 -2000）" || bad "diff_qty_milli = $D（预期 -2000）"

echo "=== 2g. 部分 convert_hold、PROCESSING/LIVE_HOLD、consume_process_hold、sell_deadline ==="
expect_block "回转 op_key 小写 cvt: 两库都拒（ck_hold_reversal_key）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (130,41,'RETURN_QC','RETURN_QC','QC',7200,'cvt:52',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000009',true); ROLLBACK;" \
  "ck_hold_reversal_key"
expect_allow "部分转换准备：stock 45 RETURN_QC 4000" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (45,1,1,1,3,'KG',4000,4000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (110,45,'RETURN_QC','RETURN_QC','QC',7201,'RQC:7201',4000,0,'HELD',0); COMMIT;"
expect_allow "convert_hold 部分 2000，调用方键 CVT:110:1" \
  "BEGIN; SELECT id FROM stock WHERE id = 45 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 110 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 2000, status = CASE WHEN released_qty_milli + 2000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 2000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (111,45,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:110:1',2000,0,'HELD',0,110); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 2000, hold_qty_milli = hold_qty_milli + 2000, version = version + 1 WHERE id = 45 AND quality_hold_qty_milli >= 2000; COMMIT;"
expect_allow "convert_hold 再转 500，另一键 CVT:110:2" \
  "BEGIN; SELECT id FROM stock WHERE id = 45 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id = 110 ORDER BY id FOR UPDATE; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, status = CASE WHEN released_qty_milli + 500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (112,45,'SCRAP_PENDING','SCRAP','SCRAP',9202,'CVT:110:2',500,0,'HELD',0,110); UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 500, hold_qty_milli = hold_qty_milli + 500, version = version + 1 WHERE id = 45 AND quality_hold_qty_milli >= 500; COMMIT;"
expect_block "同一调用方键 CVT:110:1 重放（uq_hold_op）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (113,45,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:110:1',2000,0,'HELD',0,110); ROLLBACK;" \
  "uq_hold_op"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000")
[ "$R" = "UPDATE 0" ] && ok "超量部分转换 rowcount=0（→ 40905）" || bad "超量转换：$R"
R=$(psql -t -A -c "SELECT h.released_qty_milli||'/'||h.status||'/'||(SELECT COALESCE(SUM(c.hold_qty_milli),0) FROM stock_hold c WHERE c.from_hold_id=h.id)||'/'||s.quality_hold_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli) FROM stock_hold h JOIN stock s ON s.id=h.stock_id WHERE h.id=110")
[ "$R" = "2500/HELD/2500/1500/2500/0" ] && ok "部分转换后 父释放/状态/子合计/quality/hold/available = $R" || bad "部分转换后 = $R（期望 2500/HELD/2500/1500/2500/0）"
expect_block "from_hold_id 不可改" "BEGIN; UPDATE stock_hold SET from_hold_id = 50 WHERE id = 111; COMMIT;" "hold_immutable"
R=$(psql -t -A -c "SELECT count(*) FROM (SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)) t")
[ "$R" = "0" ] && ok "I3e 部分转换后仍无差异（按 from_hold_id 汇总）" || bad "I3e 差异行 $R"
expect_block "PROCESSING op_key 小写 prci:" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (129,11,'PROCESSING','PROCESSING','PROCESS_ORDER',1,'prci:1',1000,0,'HELD',0); ROLLBACK;" \
  "ck_hold_process"
expect_block "PROCESSING operator 非 0（人工 hold 插不进去）" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (128,11,'PROCESSING','PROCESSING','PROCESS_ORDER',1,'PRCI:badop',1000,0,'HELD',7); ROLLBACK;" \
  "ck_hold_process"
expect_block "LIVE_HOLD 来源不是 LIVE_TANK_HOLD" \
  "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (127,11,'LIVE_HOLD','LIVE_HOLD','MANUAL',1,'LH:bad',1000,0,'HELD',0); ROLLBACK;" \
  "ck_hold_live"
expect_allow "place_hold PROCESSING：stock 46 冻满 5000" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (46,1,2,1,2,'KG',5000,5000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (120,46,'PROCESSING','PROCESSING','PROCESS_ORDER',8801,'PRCI:8801',5000,0,'HELD',0); COMMIT;"
expect_allow "place_hold LIVE_HOLD：stock 47 冻满 3000" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (47,1,3,1,2,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (121,47,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6601,'LH:6601',3000,0,'HELD',0); COMMIT;"
R=$(psql -t -A -c "SELECT (SELECT available_qty_milli FROM v_stock_available WHERE stock_id=46)||'/'||(SELECT available_qty_milli FROM v_stock_available WHERE stock_id=47)")
[ "$R" = "0/0" ] && ok "PROCESSING/LIVE_HOLD 可用量 = $R（都从 available 扣除，FEFO 分不到）" || bad "系统锁可用量 = $R（期望 0/0）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 120 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "PROCESSING 人工解冻 rowcount=0（→ 40933）" || bad "人工解冻了 PROCESSING：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 121 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')")
[ "$R" = "UPDATE 0" ] && ok "LIVE_HOLD 人工解冻 rowcount=0（→ 40933）" || bad "人工解冻了 LIVE_HOLD：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, version = version + 1 WHERE id = 121 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500")
[ "$R" = "UPDATE 0" ] && ok "release_hold 不释放 LIVE_HOLD（WHERE 限 PROCESSING，rowcount=0）" || bad "release_hold 误放了 LIVE_HOLD：$R"
expect_allow "consume_process_hold 扣 2000（hold 与 on_hand 同一条 UPDATE，记 PROCESS_CONSUME）" \
  "BEGIN; SELECT id FROM stock WHERE id=46 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=120 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, on_hand_qty_milli = on_hand_qty_milli - 2000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 2000 AND on_hand_qty_milli >= 2000; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 2000, status = CASE WHEN released_qty_milli + 2000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 2000;  INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC1',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (200,'PRC1',1,1,1,'DOC','PROCESS_CONSUME',-1,46,120,1,1,2,1,2,NULL,NULL,NULL,NULL,2000,5000,3000,'2026-10-16','PRC1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (200,'PRC1:1:D1:1','PRC1',1,1,1,'DOC',NULL,NULL,NULL,NULL,46,1,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=46 AND biz_type='PROCESS_CONSUME') FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
[ "$R" = "3000/3000/0/2000/HELD/1" ] && ok "consume 2000 后 on_hand/hold/available/released/status/流水 = $R" || bad "consume 2000 = $R（期望 3000/3000/0/2000/HELD/1）"
expect_allow "consume_process_hold 再扣 1000，另一幂等键" \
  "BEGIN; SELECT id FROM stock WHERE id=46 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=120 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000;  INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (201,'PRC1',1,2,1,'DOC','PROCESS_CONSUME',-1,46,120,2,1,2,1,2,NULL,NULL,NULL,NULL,1000,3000,2000,'2026-10-16','PRC1:1:D2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (201,'PRC1:1:D2:1','PRC1',1,2,1,'DOC',NULL,NULL,NULL,NULL,46,2,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=46 AND biz_type='PROCESS_CONSUME') FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
[ "$R" = "2000/2000/0/3000/2" ] && ok "consume 再扣 1000 后 = $R" || bad "第二次 consume = $R（期望 2000/2000/0/3000/2）"
expect_block "consume 重放同一幂等键，整笔回滚（不二次扣减）" \
  "BEGIN; SELECT id FROM stock WHERE id=46 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=120 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC9',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (202,'PRC9',1,1,1,'DOC','PROCESS_CONSUME',-1,46,120,9,1,2,1,2,NULL,NULL,NULL,NULL,1000,2000,1000,'2026-10-16','PRC1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (202,'PRC1:1:D1:1','PRC9',1,1,1,'DOC',NULL,NULL,NULL,NULL,46,9,-1,'2026-10-16'); COMMIT;" \
  "uq_mvk_idem"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=46) FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
[ "$R" = "2000/2000/3000/2" ] && ok "重放回滚后 on_hand/hold/released/流水 = $R" || bad "重放后 = $R（期望 2000/2000/3000/2）"
R=$(psql -t -A -c "SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN '1' ELSE '0' END FROM stock_hold h WHERE h.id=120")
[ "$R" = "1" ] && ok "I3f PROCESSING 已释放 = 释放记录 + PROCESS_CONSUME 流水" || bad "I3f = $R（期望 1）"
expect_allow "同一 stock 两条 PROCESSING，只扣其中一条（stock 52 / hold 130、131）" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (52,1,3,2,1,'KG',2000,2000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (130,52,'PROCESSING','PROCESSING','PROCESS_ORDER',8810,'PRCI:8810',1000,0,'HELD',0),(131,52,'PROCESSING','PROCESSING','PROCESS_ORDER',8811,'PRCI:8811',1000,0,'HELD',0); SELECT id FROM stock WHERE id=52 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id IN (130,131) ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 400, on_hand_qty_milli = on_hand_qty_milli - 400, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 52 AND hold_qty_milli >= 400 AND on_hand_qty_milli >= 400; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 400, status = CASE WHEN released_qty_milli + 400 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 130 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 400; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC2',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (220,'PRC2',1,1,1,'DOC','PROCESS_CONSUME',-1,52,130,1,1,3,2,1,NULL,NULL,NULL,NULL,400,2000,1600,'2026-10-16','PRC2:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (220,'PRC2:1:D1:1','PRC2',1,1,1,'DOC',NULL,NULL,NULL,NULL,52,1,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "SELECT string_agg(h.id || ':' || CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN '1' ELSE '0' END, '/' ORDER BY h.id) FROM stock_hold h WHERE h.id IN (130,131)")
[ "$R" = "130:1/131:1" ] && ok "I3f 按单条冻结对账，未扣的 131 不被 130 的流水算进去 = $R" || bad "I3f 双冻结 = $R（期望 130:1/131:1）"
R=$(psql -t -A -c "SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.stock_id=h.stock_id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN '1' ELSE '0' END FROM stock_hold h WHERE h.id=131")
[ "$R" = "0" ] && ok "按 stock 汇总 PROCESS_CONSUME 会对不上未扣的那条 PROCESSING" || bad "按 stock 汇总居然对上了 131：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000")
[ "$R" = "UPDATE 0" ] && ok "consume 超过 PROCESSING 余量 rowcount=0（→ 40905）" || bad "超量 consume：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 121 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100")
[ "$R" = "UPDATE 0" ] && ok "consume_process_hold 不接受 LIVE_HOLD（rowcount=0）" || bad "LIVE_HOLD 被 consume：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 31 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100")
[ "$R" = "UPDATE 0" ] && ok "consume_process_hold 不接受 SCRAP_PENDING（rowcount=0）" || bad "非 PROCESSING 被 consume：$R"
expect_allow "同池两条 LIVE_HOLD（stock 48/51，source 7701，sku 2，不进 FEFO）" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (48,1,1,2,1,'KG',2000,2000),(51,1,3,2,2,'KG',3500,3500); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (123,48,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7701,'LH:7701:48',2000,0,'HELD',0),(126,51,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7701,'LH:7701:51',3500,0,'HELD',0); COMMIT;"
R=$(psql -t -A -c "BEGIN; SELECT id FROM stock WHERE id IN (SELECT stock_id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD') ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD' ORDER BY id FOR UPDATE; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT v.rid, h.id, 'LTH:7701:8801:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h JOIN (SELECT 81 AS rid, 123 AS hid UNION ALL SELECT 82, 126) v ON h.id = v.hid WHERE h.hold_type='LIVE_HOLD' AND h.source_type='LIVE_TANK_HOLD' AND h.source_id=7701 AND h.status='HELD'; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id IN (123,126) AND hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82)), version=version+1 WHERE id IN (48,51) AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82)) AND 1=0; SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126')) || '/' || (SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='RELEASED') || '/' || (SELECT count(*) FROM stock WHERE id IN (48,51) AND hold_qty_milli=0); ROLLBACK;" | grep '/')
[ "$R" = "2/2/0" ] && ok "release_live_hold 行数不一致 释放/明细/汇总 = $R，已回滚（→ 50010）" || bad "行数不一致 = $R（期望 2/2/0）"
R=$(psql -t -A -c "SELECT (SELECT status FROM stock_hold WHERE id=123)||'/'||(SELECT status FROM stock_hold WHERE id=126)")
[ "$R" = "HELD/HELD" ] && ok "行数不一致回滚后两条仍 HELD" || bad "回滚后状态 = $R"
expect_allow "release_live_hold 整池释放 source 7701" \
  "BEGIN; SELECT id FROM stock WHERE id IN (SELECT stock_id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD') ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD' ORDER BY id FOR UPDATE; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT v.rid, h.id, 'LTH:7701:8801:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h JOIN (SELECT 81 AS rid, 123 AS hid UNION ALL SELECT 82, 126) v ON h.id = v.hid WHERE h.hold_type='LIVE_HOLD' AND h.source_type='LIVE_TANK_HOLD' AND h.source_id=7701 AND h.status='HELD'; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id IN (123,126) AND hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82)), version=version+1 WHERE id IN (48,51) AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82)); COMMIT;"
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126'))||'/'||(SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='RELEASED')||'/'||(SELECT count(*) FROM stock WHERE id IN (48,51) AND hold_qty_milli=0)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=48)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=48)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=51)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=51)")
[ "$R" = "2/2/2/2000/0/3500/0" ] && ok "整池释放 释放行/明细/汇总/两行 on_hand/hold = $R" || bad "整池释放 = $R（期望 2/2/2/2000/0/3500/0）"
R=$(psql -t -A -c "SELECT count(*)||'/'||COALESCE(SUM(qty_milli),0) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126')")
[ "$R" = "2/5500" ] && ok "release_live_hold 幂等：等值命中已有 op_key（合计 5500），直接返回不再写" || bad "幂等预查 = $R（期望 2/5500）"
expect_block "release_live_hold 重放同一 op_key" \
  "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (83,123,'LTH:7701:8801:123',2000); ROLLBACK;" \
  "uq_hr_op"
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126'))||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=48)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=48)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=51)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=51)")
[ "$R" = "2/2000/0/3500/0" ] && ok "重放回滚后整池释放行数与在库不变 = $R" || bad "重放后整池 = $R"
expect_allow "consume_live_hold 准备：stock 50 LIVE_HOLD 4000（source 7702）" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (50,1,2,2,1,'KG',4000,4000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (125,50,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7702,'LH:7702',4000,0,'HELD',0); COMMIT;"
expect_allow "consume_live_hold 部分扣 1500（LIVE_DEATH，一条 SCRAP -1）" \
  "BEGIN; SELECT id FROM stock WHERE id=50 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=125 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1500, on_hand_qty_milli = on_hand_qty_milli - 1500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 1500 AND on_hand_qty_milli >= 1500; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1500, status = CASE WHEN released_qty_milli + 1500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1500;  INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD1',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (210,'LD1',1,1,1,'DOC','SCRAP',-1,50,125,1,1,2,2,1,NULL,NULL,NULL,NULL,1500,4000,2500,'2026-10-16','LD1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (210,'LD1:1:D1:1','LD1',1,1,1,'DOC',NULL,NULL,NULL,NULL,50,1,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=50 AND biz_type='SCRAP' AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
[ "$R" = "2500/2500/0/1500/HELD/1" ] && ok "死亡一次只有一条 -1 流水，部分扣后 = $R" || bad "consume_live_hold = $R（期望 2500/2500/0/1500/HELD/1）"
expect_block "consume_live_hold 重放同一幂等键" \
  "BEGIN; SELECT id FROM stock WHERE id=50 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=125 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1500, on_hand_qty_milli = on_hand_qty_milli - 1500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 1500 AND on_hand_qty_milli >= 1500; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1500, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1500; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD9',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (212,'LD9',1,1,1,'DOC','SCRAP',-1,50,125,9,1,2,2,1,NULL,NULL,NULL,NULL,1500,2500,1000,'2026-10-16','LD1:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (212,'LD1:1:D1:1','LD9',1,1,1,'DOC',NULL,NULL,NULL,NULL,50,9,-1,'2026-10-16'); COMMIT;" \
  "uq_mvk_idem"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=50 AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
[ "$R" = "2500/2500/1500/1" ] && ok "死亡重放不二次扣减，仍一条 -1 流水 = $R" || bad "死亡重放后 = $R"
expect_allow "consume_live_hold 再扣 500，另一幂等键" \
  "BEGIN; SELECT id FROM stock WHERE id=50 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=125 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 500, on_hand_qty_milli = on_hand_qty_milli - 500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 500 AND on_hand_qty_milli >= 500; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, status = CASE WHEN released_qty_milli + 500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500;  INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (211,'LD1',1,2,1,'DOC','SCRAP',-1,50,125,2,1,2,2,1,NULL,NULL,NULL,NULL,500,2500,2000,'2026-10-16','LD1:1:D2:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (211,'LD1:1:D2:1','LD1',1,2,1,'DOC',NULL,NULL,NULL,NULL,50,2,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=50 AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
[ "$R" = "2000/2000/0/2000/2" ] && ok "consume_live_hold 再扣 500 后 = $R" || bad "第二次 consume_live = $R（期望 2000/2000/0/2000/2）"
R=$(psql -t -A -c "SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='SCRAP' AND m.direction=-1),0) THEN '1' ELSE '0' END FROM stock_hold h WHERE h.id=125")
[ "$R" = "1" ] && ok "I3g LIVE_HOLD 已释放 = 释放记录 + 本行 SCRAP 流水" || bad "I3g = $R（期望 1）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000")
[ "$R" = "UPDATE 0" ] && ok "consume_live_hold 超量 rowcount=0（→ 40905）" || bad "超量 consume_live：$R"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 120 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100")
[ "$R" = "UPDATE 0" ] && ok "consume_live_hold 不接受 PROCESSING（rowcount=0）" || bad "PROCESSING 被 consume_live：$R"
expect_allow "N-1 consume_process_hold：stock 53 冻结 3000，一次扣完并提交" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (53,1,1,2,3,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (140,53,'PROCESSING','PROCESSING','PROCESS_ORDER',5301,'PRCI:5301',3000,0,'HELD',0); SELECT id FROM stock WHERE id=53 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=140 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 53 AND hold_qty_milli >= 3000 AND on_hand_qty_milli >= 3000; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, status = CASE WHEN released_qty_milli + 3000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 140 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC3',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (230,'PRC3',1,1,1,'DOC','PROCESS_CONSUME',-1,53,140,1,1,1,2,3,NULL,NULL,NULL,NULL,3000,3000,0,'2026-10-16','PRC3:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (230,'PRC3:1:D1:1','PRC3',1,1,1,'DOC',NULL,NULL,NULL,NULL,53,1,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "BEGIN; SELECT id||'/'||move_qty_milli||'/'||on_hand_before_qty_milli||'/'||on_hand_after_qty_milli FROM stock_movement WHERE idempotency_key = 'PRC3:1:D1:1'; COMMIT;" | tr -d '\r' | grep '/')
[ "$R" = "230/3000/3000/0" ] && ok "N-1 加工消耗重放：等值命中原流水，扣减之前就返回 = $R" || bad "N-1 加工预查 = $R（期望 230/3000/3000/0）"
R=$(psql -t -A -c "SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE idempotency_key='PRC3:1:D1:1') FROM stock s JOIN stock_hold h ON h.id=140 WHERE s.id=53")
[ "$R" = "1/0/0/3000/RELEASED/1" ] && ok "N-1 加工重放未再扣、未再记账 = $R" || bad "N-1 加工重放后 = $R（期望 1/0/0/3000/RELEASED/1）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 140 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000")
[ "$R" = "UPDATE 0" ] && ok "N-1 加工：跳过预查时余量扣减 rowcount=0（→ 40905），原语不得走到这一步" || bad "N-1 加工 40905 对照 = $R"
expect_allow "N-1 consume_live_hold：stock 54 冻结 3000，一次扣完并提交" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (54,1,1,2,2,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (141,54,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6602,'LH:6602',3000,0,'HELD',0); SELECT id FROM stock WHERE id=54 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=141 ORDER BY id FOR UPDATE; UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 54 AND hold_qty_milli >= 3000 AND on_hand_qty_milli >= 3000; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, status = CASE WHEN released_qty_milli + 3000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 141 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD3',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (231,'LD3',1,1,1,'DOC','SCRAP',-1,54,141,1,1,1,2,2,NULL,NULL,NULL,NULL,3000,3000,0,'2026-10-16','LD3:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (231,'LD3:1:D1:1','LD3',1,1,1,'DOC',NULL,NULL,NULL,NULL,54,1,-1,'2026-10-16'); COMMIT;"
R=$(psql -t -A -c "BEGIN; SELECT id||'/'||move_qty_milli||'/'||on_hand_before_qty_milli||'/'||on_hand_after_qty_milli FROM stock_movement WHERE idempotency_key = 'LD3:1:D1:1'; COMMIT;" | tr -d '\r' | grep '/')
[ "$R" = "231/3000/3000/0" ] && ok "N-1 活鲜消耗重放：等值命中原流水，扣减之前就返回 = $R" || bad "N-1 活鲜预查 = $R（期望 231/3000/3000/0）"
R=$(psql -t -A -c "SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE idempotency_key='LD3:1:D1:1') FROM stock s JOIN stock_hold h ON h.id=141 WHERE s.id=54")
[ "$R" = "1/0/0/3000/RELEASED/1" ] && ok "N-1 活鲜重放未再扣、未再记账 = $R" || bad "N-1 活鲜重放后 = $R（期望 1/0/0/3000/RELEASED/1）"
R=$(psql -t -A -c "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 141 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000")
[ "$R" = "UPDATE 0" ] && ok "N-1 活鲜：跳过预查时余量扣减 rowcount=0（→ 40905），原语不得走到这一步" || bad "N-1 活鲜 40905 对照 = $R"
expect_allow "N-2 顺序：stock 61 整池释放一次后提交" \
  "BEGIN; INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (61,1,3,2,3,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (172,61,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7903,'LH:7903',3000,0,'HELD',0); SELECT id FROM stock WHERE id=61 ORDER BY id FOR UPDATE; SELECT id FROM stock_hold WHERE id=172 AND status='HELD' ORDER BY id FOR UPDATE; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT 193, h.id, 'LTH:7903:9003:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h WHERE h.id=172 AND h.status='HELD'; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id=172 AND status='HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r WHERE r.id=193), version=version+1 WHERE id=61 AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r WHERE r.id=193); COMMIT;"
R=$(psql -t -A -c "BEGIN; SELECT (SELECT count(*) FROM stock_hold WHERE id=172 AND status='HELD') || '/' || (SELECT id||':'||qty_milli FROM stock_hold_release WHERE op_key='LTH:7903:9003:172'); COMMIT;" | tr -d '\r' | grep '/')
[ "$R" = "0/193:3000" ] && ok "N-2 顺序：第 1 步锁到 0 条 HELD 后重跑幂等查询，返回原释放 = $R" || bad "N-2 顺序重查 = $R（期望 0/193:3000）"
R=$(psql -t -A -c "SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(SELECT count(*) FROM stock_hold_release WHERE hold_id=172)||'/'||h.version FROM stock s JOIN stock_hold h ON h.id=172 WHERE s.id=61")
[ "$R" = "1/3000/0/1/1" ] && ok "N-2 顺序重放不插空释放、不抬 version = $R" || bad "N-2 顺序重放后 = $R（期望 1/3000/0/1/1）"
expect_allow "ck_recon_code 活鲜四码可写入" \
  "BEGIN; INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9101,'LIVE_COUNT_WEIGHT',1,46,1,0),(9102,'LIVE_COUNT_LEDGER',1,46,1,0),(9103,'LIVE_HOLD_MISMATCH',1,47,1,0),(9104,'LIVE_INSPECT_OVERDUE',1,47,1,0); ROLLBACK;"
expect_block "已有批次 sell_deadline 从 NULL 补写" "UPDATE lot SET sell_deadline = '2026-11-01' WHERE id = 1;" "sell_deadline_immutable"
expect_allow "新建批次写入 sell_deadline" \
  "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,sell_deadline) VALUES (90,1,'LOT-SD','2026-12-01','2026-10-01','2026-11-01');"
expect_block "sell_deadline 改早" "UPDATE lot SET sell_deadline = '2026-10-01' WHERE id = 90;" "sell_deadline_immutable"
expect_block "sell_deadline 改晚" "UPDATE lot SET sell_deadline = '2026-12-15' WHERE id = 90;" "sell_deadline_immutable"
expect_block "sell_deadline 清空" "UPDATE lot SET sell_deadline = NULL WHERE id = 90;" "sell_deadline_immutable"
expect_allow "sell_deadline 不动时其余列可改" "UPDATE lot SET remaining_life_days = 12 WHERE id = 90;"

echo "=== 2h. docs/18 活鲜暂存：B2 死亡/失重单次扣减、P2 整池释放、B3 task_kind、B5 42217 不占键、B6 外键 ==="
expect_allow "18 种子：活鲜 SKU 3、池 61（LIVE_TANK）、普通位 62、批次 31/32、stock 6101/6102" "BEGIN; INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (61,1,2,'LT-01','LIVE_TANK',4,'L010'),(62,1,2,'B09-01-01','BIN',2,'L020'); INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (3,'SKU-CRAB','阳澄湖大闸蟹','KG','CHILLED',7,1,3); INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (31,3,'LOT-C1','2026-10-22','2026-10-15','QUALIFIED',7),(32,3,'LOT-C2','2026-10-23','2026-10-16','QUALIFIED',7); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (6101,1,61,3,31,'KG',50000),(6102,1,61,3,32,'KG',20000); COMMIT;"
expect_block "18 B6 普通库位挂池扩展" "BEGIN; INSERT INTO live_tank (location_id,warehouse_id,sku_id,water_volume_l,temp_min_c10,temp_max_c10,temp_severe_min_c10,temp_severe_max_c10,do_min_x100,do_severe_min_x100,ph_min_x100,ph_max_x100) VALUES (62,1,3,2000,140,200,100,240,500,300,700,850); COMMIT;" "lt_not_live_tank"
expect_allow "18 SKU 参数与池扩展（池 61）" "BEGIN; INSERT INTO sku_live_param (sku_id) VALUES (3); INSERT INTO live_tank (location_id,warehouse_id,sku_id,water_volume_l,temp_min_c10,temp_max_c10,temp_severe_min_c10,temp_severe_max_c10,do_min_x100,do_severe_min_x100,ph_min_x100,ph_max_x100) VALUES (61,1,3,2000,140,200,100,240,500,300,700,850); COMMIT;"
expect_block "18 B6 SKU 参数指向不存在的 SKU" "BEGIN; INSERT INTO sku_live_param (sku_id) VALUES (9999); COMMIT;" "sku_live_param_sku_id_fkey"
expect_block "18 一池一 SKU：改池 SKU" "BEGIN; UPDATE live_tank SET sku_id=1 WHERE location_id=61; COMMIT;" "lt_immutable"
expect_allow "18 尾数余额（6101 120 只，6102 40 只）" "BEGIN; INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES (6101,61,31,120),(6102,61,32,40); COMMIT;"
expect_block "18 B6 尾数余额引用不存在的 stock" "BEGIN; INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES (987654,61,31,0); COMMIT;" "fk_lsc_stock"
expect_block "18 B6 尾数流水引用不存在的重量流水" "BEGIN; INSERT INTO live_count_ledger (id,stock_id,biz_type,biz_no,delta_count,count_before,count_after,movement_id) VALUES (6190,6101,'DEATH','LD-X',-1,120,119,987654); COMMIT;" "fk_lcl_mv"
expect_block "18 B6 巡检挂在非池库位" "BEGIN; INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6190,1,62,'DEV-L','op-x',7,'2026-10-15 10:00:00',180,600,780,'NORMAL',0,false); COMMIT;" "fk_li_tank"
expect_allow "18 连续 2 次超标 → 锁池单 6121 + 两条 place_hold(LIVE_HOLD)（先锁 stock 行再写冻结明细）" "BEGIN; INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6111,1,61,'DEV-L','op-1',7,'2026-10-15 10:00:00',215,600,780,'ALARM',1,false); INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6112,1,61,'DEV-L','op-2',7,'2026-10-15 10:00:00',216,600,780,'ALARM',2,false); INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id) VALUES (6121,1,61,'CONSECUTIVE_BREACH',6112); UPDATE stock SET hold_qty_milli = hold_qty_milli + on_hand_qty_milli, version = version + 1 WHERE id IN (6101,6102) AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli = on_hand_qty_milli; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (6131,6101,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6121,'LH:6121:6101',50000,0,'HELD',0),(6132,6102,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6121,'LH:6121:6102',20000,0,'HELD',0); COMMIT;"
expect_block "18 同池第二条 ACTIVE 锁" "BEGIN; INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id) VALUES (6129,1,61,'SEVERE',987654); COMMIT;" "uq_lth_active"
expect_allow "18 B2 锁池中死亡：consume_live_hold(6131, 1200, LIVE_DEATH) + 只数 −2 + 流水挂 hold_id、live_death 挂 movement_id" "BEGIN; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1200, on_hand_qty_milli = on_hand_qty_milli - 1200, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6101 AND hold_qty_milli >= 1200 AND on_hand_qty_milli >= 1200; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1200, status = CASE WHEN released_qty_milli + 1200 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 6131 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1200; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6151',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (6141,'LD-6151',1,1,1,'DOC','SCRAP',-1,6101,1,1,61,3,31,NULL,NULL,NULL,NULL,1200,50000,48800,'2026-10-16','LD-6151:1:D1:1',6131); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6141,'LD-6151:1:D1:1','LD-6151',1,1,1,'DOC',NULL,NULL,NULL,NULL,6101,1,-1,'2026-10-16'); UPDATE live_stock_count SET on_hand_count = on_hand_count - 2, version = version + 1 WHERE stock_id = 6101 AND on_hand_count >= 2; INSERT INTO live_count_ledger (id,stock_id,biz_type,biz_no,delta_count,count_before,count_after,movement_id) VALUES (6161,6101,'DEATH','LD-6151',-2,120,118,6141); INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6151,1,61,6101,31,'2026-10-16','DEV-L','d-1',2,1200,125,6141,1200,7,'2026-10-15 10:00:00'); COMMIT;"
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=6101 AND direction=-1)||'/'||(SELECT on_hand_count FROM live_stock_count WHERE stock_id=6101) FROM stock s JOIN stock_hold h ON h.stock_id=s.id AND h.id=6131")
[ "$R" = "48800/48800/0/1200/1/118" ] && ok "18 B2 死亡一次：在库/冻结/可用/明细已扣/−1 流水条数/只数 = $R" || bad "18 B2 死亡一次：在库/冻结/可用/明细已扣/−1 流水条数/只数 = $R（期望 48800/48800/0/1200/1/118）"
expect_block "18 B2 死亡离线重放（同设备同 op）" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6152,1,61,6101,31,'2026-10-16','DEV-L','d-1',2,1200,125,6141,1200,7,'2026-10-15 10:00:00'); COMMIT;" "uq_ld_op"
expect_block "18 B2 两条死亡挂同一条流水（重复扣减依据）" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6153,1,61,6101,31,'2026-10-16','DEV-L','d-2',2,1200,125,6141,1200,7,'2026-10-15 10:00:00'); COMMIT;" "uq_ld_mv"
expect_block "18 B2 consume_live_hold 同一 op_key 重放" "BEGIN; UPDATE stock SET hold_qty_milli = hold_qty_milli - 1200, on_hand_qty_milli = on_hand_qty_milli - 1200, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6101 AND hold_qty_milli >= 1200 AND on_hand_qty_milli >= 1200; UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1200, status = CASE WHEN released_qty_milli + 1200 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 6131 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1200; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6151R',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (6142,'LD-6151R',1,1,1,'DOC','SCRAP',-1,6101,2,1,61,3,31,NULL,NULL,NULL,NULL,1200,48800,47600,'2026-10-16','LD-6151:1:D1:1',6131); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6142,'LD-6151:1:D1:1','LD-6151R',1,1,1,'DOC',NULL,NULL,NULL,NULL,6101,2,-1,'2026-10-16'); COMMIT;" "uq_mvk_idem"
R=$(psql -t -A -c "SELECT (SELECT on_hand_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT released_qty_milli FROM stock_hold WHERE id=6131)||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=6101 AND direction=-1)")
[ "$R" = "48800/1200/1" ] && ok "18 B2 重放回滚后不二次扣减 = $R" || bad "18 B2 重放回滚后不二次扣减 = $R（期望 48800/1200/1）"
expect_block "18 用非复检记录释放锁池" "BEGIN; UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6112, released_at='2026-10-15 10:00:00' WHERE id=6121; COMMIT;" "lth_recheck_required"
expect_allow "18 P2 复检合格 → release_live_hold(6121, 6113, LTH:6121:6113, release_ids=[616131,616132]) 按本次释放行 id 汇总 + 锁池单 RELEASED" "BEGIN; INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6113,1,61,'DEV-L','op-3',7,'2026-10-15 10:00:00',180,600,780,'NORMAL',0,true); INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT v.rid, h.id, 'LTH:6121:6113:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h JOIN (SELECT 616131 AS rid, 6131 AS hold_id UNION ALL SELECT 616132, 6132) v ON v.hold_id = h.id WHERE h.status='HELD'; UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id IN (6131, 6132) AND status='HELD'; UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND r.id IN (616131, 616132)), version=version+1 WHERE id IN (SELECT stock_id FROM stock_hold WHERE id IN (6131, 6132)) AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND r.id IN (616131, 616132)); UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6113, released_at='2026-10-15 10:00:00' WHERE id=6121 AND status='ACTIVE'; COMMIT;"
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:6121:6113:6131', 'LTH:6121:6113:6132'))||'/'||(SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=6121 AND status='RELEASED')||'/'||(SELECT count(*) FROM stock WHERE id IN (6101,6102) AND hold_qty_milli=0)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=6102)")
[ "$R" = "2/2/2/48800/20000" ] && ok "18 P2 整池释放：释放行/明细 RELEASED/两行 hold=0/两行在库不变 = $R" || bad "18 P2 整池释放：释放行/明细 RELEASED/两行 hold=0/两行在库不变 = $R（期望 2/2/2/48800/20000）"
expect_block "18 P2 release_live_hold 同一 op_key 重放" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (606131,6131,'LTH:6121:6113:6131',48800); COMMIT;" "uq_hr_op"
expect_block "18 P2 释放后再释放（锁池单已关）" "BEGIN; UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6113, released_at='2026-10-15 10:00:00' WHERE id=6121; COMMIT;" "lth_closed"
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:6121:6113:6131', 'LTH:6121:6113:6132'))||'/'||(SELECT hold_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=6102)")
[ "$R" = "2/0/0" ] && ok "18 P2 重放后释放行数与汇总不变 = $R" || bad "18 P2 重放后释放行数与汇总不变 = $R（期望 2/0/0）"
R=$(psql -t -A -c "SELECT string_agg(h.id||':'||CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.direction=-1),0) THEN 'OK' ELSE 'BAD' END||':'||(SELECT count(*) FROM stock_movement m WHERE m.hold_id=h.id), '/' ORDER BY h.id) FROM stock_hold h WHERE source_type='LIVE_TANK_HOLD' AND source_id=6121")
[ "$R" = "6131:OK:1/6132:OK:0" ] && ok "18 LIVE_HOLD_MISMATCH 逐条明细对账：hold_id 经 stock_movement 取（6131 挂死亡流水 1 条，另一条 0 条） = $R" || bad "18 LIVE_HOLD_MISMATCH 逐条明细对账：hold_id 经 stock_movement 取（6131 挂死亡流水 1 条，另一条 0 条） = $R"
expect_allow "18 B5 超容差 REJECTED（42217）留痕" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6171,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00'); COMMIT;"
expect_allow "18 B5 同一键再次 REJECTED：42217 不占幂等键，重新执行" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6172,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9600,500,9100,8,10200,1079,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00'); COMMIT;"
expect_allow "18 B5 同一键重称通过 ACCEPTED（扣 10.0kg 8 只）" "BEGIN; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 10000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 10000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LW-6173',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6143,'LW-6173',1,1,1,'DOC','PICK',-1,6102,1,1,61,3,32,NULL,NULL,NULL,NULL,10000,20000,10000,'2026-10-16','LW-6173:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6143,'LW-6173:1:D1:1','LW-6173',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,1,-1,'2026-10-16'); INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6173,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10000,8,10200,197,'ACCEPTED',NULL,6143,7,'2026-10-15 10:00:00'); COMMIT;"
expect_block "18 B5 ACCEPTED 同键重放 → 40910 LIVE_WEIGH 依据" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6174,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10000,8,10200,197,'ACCEPTED',NULL,6143,7,'2026-10-15 10:00:00'); COMMIT;" "uq_lw_key"
expect_allow "18 B3 加工领用同 task_id/weigh_client_id 不撞拣货键（task_kind 区分）" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6175,1,'PROCESS_ISSUE',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00'); COMMIT;"
expect_block "18 B3 task_kind 非法" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6176,1,'RETURN',7001,1,'w-2','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00'); COMMIT;" "ck_lw_kind"
expect_block "18 S1 REJECTED 的 result_code 不是 42217" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6177,1,'PICK',7001,1,'w-3','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','99999',NULL,7,'2026-10-15 10:00:00'); COMMIT;" "ck_lw_result"
expect_block "18 净重 ≠ 毛 − 皮" "BEGIN; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6178,1,'PICK',7001,1,'w-4','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10500,8,10200,294,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00'); COMMIT;" "ck_lw_qty"
expect_block "18 B2 失重 LOSS 不带扣减流水" "BEGIN; INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome,scrap_order_id) VALUES (6181,1,61,31,6101,'2026-10-16',48800,48500,300,62,100,'LOSS',901); COMMIT;" "ck_lss_outcome"
expect_allow "18 超容差 → VARIANCE（不扣，挂盘点单）" "BEGIN; INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome,count_order_id) VALUES (6182,1,61,31,6101,'2026-10-16',48800,46800,2000,410,100,'VARIANCE',801); COMMIT;"
expect_block "18 同池同批同日重复结算（→ 40910 LIVE_SHRINK）" "BEGIN; INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome) VALUES (6183,1,61,31,6101,'2026-10-16',48800,48800,0,0,100,'NONE'); COMMIT;" "uq_lss_day"
expect_block "18 删死亡登记" "BEGIN; DELETE FROM live_death WHERE id=6151; COMMIT;" "append_only_violation"
expect_block "18 改称重记录" "BEGIN; UPDATE live_weigh SET net_qty_milli=9000 WHERE id=6173; COMMIT;" "append_only_violation"
# 18 D1/D2（Doro 定）：死亡先落、扣减延后补扣；补扣在库不足转 EXCEPTION
expect_allow "18 D1 写节点暂停：死亡先落 PENDING（6154，4.0kg，未扣）" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6154,1,61,6102,32,'2026-10-16','DEV-L','d-p1',1,4000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00'); COMMIT;"
expect_block "18 D1 PENDING 带已扣量" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x1',1,1000,100,NULL,'PENDING',500,NULL,7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D1 DEDUCTED 不带 movement_id" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x2',1,1000,100,NULL,'DEDUCTED',1000,NULL,7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D1 DEDUCTED 已扣量 ≠ 死亡量" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x3',1,1000,100,6143,'DEDUCTED',500,NULL,7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
R=$(psql -t -A -c "SELECT deduct_status||'/'||diff_qty_milli FROM v_live_death_in_transit WHERE live_death_id=6154")
[ "$R" = "PENDING/4000" ] && ok "18 D1 PENDING 列为在途差异（不算对平） = $R" || bad "18 D1 PENDING 列为在途差异（不算对平） = $R（期望 PENDING/4000）"
expect_allow "18 D1 恢复后补扣：post_out(SCRAP) 4.0kg + PENDING→DEDUCTED 回填 movement_id" "BEGIN; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 4000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 4000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6154',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6144,'LD-6154',1,1,1,'DOC','SCRAP',-1,6102,2,1,61,3,32,NULL,NULL,NULL,NULL,4000,10000,6000,'2026-10-16','LD-6154:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6144,'LD-6154:1:D1:1','LD-6154',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,2,-1,'2026-10-16'); UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6144, deducted_qty_milli=4000, exception_key=NULL WHERE id=6154 AND deduct_status='PENDING'; COMMIT;"
expect_block "18 D1 补扣重放（同 op_key）" "BEGIN; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 4000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 4000; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6146,'LD-6154',1,1,1,'DOC','SCRAP',-1,6102,2,1,61,3,32,NULL,NULL,NULL,NULL,4000,10000,6000,'2026-10-16','LD-6154:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6146,'LD-6154:1:D1:1','LD-6154',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,2,-1,'2026-10-16'); UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6146, deducted_qty_milli=4000, exception_key=NULL WHERE id=6154 AND deduct_status='PENDING'; COMMIT;" "uq_mvk_idem"
R=$(psql -t -A -c "SELECT (SELECT on_hand_qty_milli FROM stock WHERE id=6102)||'/'||(SELECT count(*) FROM stock_movement WHERE biz_no='LD-6154')||'/'||(SELECT count(*) FROM v_live_death_in_transit WHERE live_death_id=6154)")
[ "$R" = "6000/1/0" ] && ok "18 D1 补扣重放只扣一次：在库/−1 流水数/在途行 = $R" || bad "18 D1 补扣重放只扣一次：在库/−1 流水数/在途行 = $R（期望 6000/1/0）"
expect_block "18 D1 DEDUCTED 改回 PENDING" "BEGIN; UPDATE live_death SET deduct_status='PENDING', movement_id=NULL, deducted_qty_milli=0 WHERE id=6154; COMMIT;" "live_death_key_immutable: 40930"
expect_allow "18 D2 死亡先落 PENDING（6155 9.0kg、6156 0.5kg）" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6155,1,61,6102,32,'2026-10-16','DEV-L','d-p2',1,9000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00'); INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6156,1,61,6102,32,'2026-10-16','DEV-L','d-p3',1,500,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00'); COMMIT;"
expect_block "18 D2 补扣时顺手改死亡量" "BEGIN; UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6144, deducted_qty_milli=4000, death_qty_milli=4000 WHERE id=6155; COMMIT;" "append_only_violation"
expect_allow "18 D2 补扣在库不足（部分）：扣 6.0kg + EXCEPTION 回填 movement_id，差额 3.0kg 转 10 异常单 LDTH:6155" "BEGIN; UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 6000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 6000; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6155',1,'DOC',NULL); INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6145,'LD-6155',1,1,1,'DOC','SCRAP',-1,6102,3,1,61,3,32,NULL,NULL,NULL,NULL,6000,6000,0,'2026-10-16','LD-6155:1:D1:1'); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6145,'LD-6155:1:D1:1','LD-6155',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,3,-1,'2026-10-16'); UPDATE live_death SET deduct_status='EXCEPTION', movement_id=6145, deducted_qty_milli=6000, exception_key='LDTH:6155' WHERE id=6155 AND deduct_status='PENDING'; COMMIT;"
expect_allow "18 D2 补扣在库为 0（零扣）：EXCEPTION、movement_id 为空，0.5kg 转异常单 LDTH:6156" "BEGIN; UPDATE live_death SET deduct_status='EXCEPTION', movement_id=NULL, deducted_qty_milli=0, exception_key='LDTH:6156' WHERE id=6156 AND deduct_status='PENDING'; COMMIT;"
R=$(psql -t -A -c "SELECT string_agg(live_death_id||':'||deduct_status||':'||diff_qty_milli||':'||CASE WHEN death_qty_milli = deducted_qty_milli + diff_qty_milli AND movement_qty_milli = deducted_qty_milli THEN 'OK' ELSE 'BAD' END, ',') FROM (SELECT * FROM v_live_death_in_transit ORDER BY live_death_id) t")
[ "$R" = "6155:EXCEPTION:3000:OK,6156:EXCEPTION:500:OK" ] && ok "18 D2 EXCEPTION 列为差异 + 守恒（死亡量 = 已扣 + 异常量，流水量 = 已扣） = $R" || bad "18 D2 EXCEPTION 列为差异 + 守恒（死亡量 = 已扣 + 异常量，流水量 = 已扣） = $R（期望 6155:EXCEPTION:3000:OK,6156:EXCEPTION:500:OK）"
expect_block "18 D2 EXCEPTION 已扣 > 0 但无 movement_id" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x4',1,1000,100,NULL,'EXCEPTION',300,'LDTH:6157',7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D2 EXCEPTION 零扣却挂流水" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x5',1,1000,100,6143,'EXCEPTION',0,'LDTH:6157',7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D2 EXCEPTION 已扣 = 死亡量（应为 DEDUCTED）" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x6',1,1000,100,6143,'EXCEPTION',1000,'LDTH:6157',7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D2 EXCEPTION 来源键前导零 LDTH:06157" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x7',1,1000,100,NULL,'EXCEPTION',0,'LDTH:06157',7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D2 EXCEPTION 来源键不是本行 id" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x8',1,1000,100,NULL,'EXCEPTION',0,'LDTH:6156',7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
expect_block "18 D2 EXCEPTION 不带来源键" "BEGIN; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x9',1,1000,100,NULL,'EXCEPTION',0,NULL,7,'2026-10-15 11:00:00'); COMMIT;" "ck_ld_deduct"
echo "=== 2h2. 18 两会话补扣（PG only；SQLite 单写者，没有真并发，只在 §2h 测重放；补扣对 release_live_hold 的并发不在本篇）==="
# 测试代码本身不加锁：两个 psql 会话直接调原语 live_death_makeup() / release_live_hold()，锁由原语自己加。
# 每个会话 ON_ERROR_STOP=1 + lock_timeout，后台会话另有看门狗；死锁 / 超时 / 非零退出都记 bad。
t18_mk() {  # $1 live_death id  $2 movement id：调补扣原语，差额 > 0 时同一语句在 #5 真表 exception_case 开 LDTH 异常单（ON CONFLICT … DO NOTHING，仲裁索引 uq_exc_ldth_key），打印原语返回值
  echo "WITH m AS (SELECT live_death_makeup($1, $2) AS r), e AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) SELECT $2, 'EXC-' || $2, 1, 'LIVE_DEATH_UNDEDUCTED', 'LIVE_DEATH', 'LDTH:' || $1, lpad('$2', 64, '0'), split_part(r, ':', 4)::bigint, 32, split_part(r, ':', 3)::bigint, 0, -split_part(r, ':', 3)::bigint, '2026-10-17 12:00:00', 0 FROM m WHERE split_part(r, ':', 1) = 'WON' AND split_part(r, ':', 3)::bigint > 0 ON CONFLICT (source_key) WHERE source_type = 'LIVE_DEATH' DO NOTHING RETURNING 1) SELECT r FROM m;"
}
t18_sess() {  # $1 输出文件  $2 首个语句  $3 提交前睡几秒；其余在同一会话 BEGIN … COMMIT
  psql -q -t -A -c "SET lock_timeout = '15s'" -c "BEGIN" -c "$2" -c "SELECT 't18_hold_' || pg_sleep($3)" -c "COMMIT" > "$1" 2>&1   # 包装已带 ON_ERROR_STOP；stderr 并进本会话的输出文件供断言
}
t18_wait_active() {  # 等后台会话进入提交前的睡眠（已拿到锁）
  for _ in $(seq 1 100); do
    n=$(psql -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND query LIKE '%t18_hold_%' AND pid <> pg_backend_pid() AND state = 'active'")
    [ "$n" = "1" ] && return 0; sleep 0.1
  done; return 1
}
t18_pair() {  # $1 用例名  $2 A 语句  $3 B 语句；A 后台先拿锁并睡 2 秒，B 随后进来
  local fa fb pa wd ra rb; fa=$(mktemp); fb=$(mktemp)
  t18_sess "$fa" "$2" 2 & pa=$!
  ( sleep 40; kill $pa 2>/dev/null ) & wd=$!
  t18_wait_active || echo "A 未进入睡眠" >> "$fa"
  t18_sess "$fb" "$3" 0; rb=$?
  wait $pa; ra=$?; kill $wd 2>/dev/null; wait $wd 2>/dev/null
  T18_A=$(grep -v '^t18_hold_\|^$\|^SET$\|^BEGIN$\|^COMMIT$' "$fa" | tr '\n' ' '); T18_B=$(grep -v '^t18_hold_\|^$\|^SET$\|^BEGIN$\|^COMMIT$' "$fb" | tr '\n' ' ')
  T18_RC="$ra/$rb"; rm -f "$fa" "$fb"
}
t18_state() {  # $1 stock $2 live_death：流水数 / 流水 hold_id / LDTH 异常单数(sku>0) / 状态:已扣:键 / on_hand:hold
  psql -t -A -c "SELECT (SELECT count(*) FROM stock_movement WHERE idempotency_key = 'LD-$2:1:D1:1')||'/'||COALESCE((SELECT hold_id::text FROM stock_movement WHERE idempotency_key = 'LD-$2:1:D1:1'),'-')||'/'||(SELECT count(*) FROM exception_case e JOIN live_death d ON d.id = $2 WHERE e.source_type = 'LIVE_DEATH' AND e.source_key = 'LDTH:$2' AND e.sku_id = 3 AND e.exception_code = 'LIVE_DEATH_UNDEDUCTED' AND e.claimed_qty_milli = d.death_qty_milli - d.deducted_qty_milli)||'/'||(SELECT deduct_status||':'||deducted_qty_milli||':'||COALESCE(exception_key,'-') FROM live_death WHERE id = $2)||'/'||(SELECT on_hand_qty_milli||':'||hold_qty_milli FROM stock WHERE id = $1)"
}
t18_i3g() {  # $1 hold id（0 = 无冻结）：I3g 逐条明细对账
  [ "$1" = 0 ] && { echo 1; return; }
  psql -t -A -c "SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id = h.id AND m.biz_type = 'SCRAP' AND m.direction = -1), 0) THEN 1 ELSE 0 END FROM stock_hold h WHERE h.id = $1"
}
t18_seed() {  # $1 stock  $2 hold（0 = 未锁池）  $3 live_death  $4 余量  $5 锁池单 id（hold 的 source_id）
  seed "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES ($1,1,61,3,32,$1,'KG',$4,$([ "$2" = 0 ] && echo 0 || echo $4)); INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES ($1,61,32,0);"
  [ "$2" != 0 ] && seed "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES ($2,$1,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',$5,'LH:$5:$1',$4,0,'HELD',0);"
  seed "INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES ($3,1,61,$1,32,'2026-10-16','DEV-T18','c-$3',1,1000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00');"
}
# 异常单数只认 sku=3、异常码 LIVE_DEATH_UNDEDUCTED、数量 = 死亡量 − 已扣 的那张
# 补扣对补扣：同一条 PENDING（死亡 1000），两会话同 op_key，A 先拿锁
for T18C in "ENOUGH 6801 6802 6803 3000 1/6802/0/DEDUCTED:1000:-/2000:2000 DEDUCTED" "PARTIAL 6811 6812 6813 400 1/6812/1/EXCEPTION:400:LDTH:6813/0:0 EXCEPTION" "ZERO 6821 0 6823 0 0/-/1/EXCEPTION:0:LDTH:6823/0:0 EXCEPTION"; do
  set -- $T18C; T18N=$1; S18=$2; H18=$3; L18=$4
  t18_seed $S18 $H18 $L18 $5 6890
  t18_pair "$T18N" "$(t18_mk $L18 ${L18}01)" "$(t18_mk $L18 ${L18}02)"
  R=$(t18_state $S18 $L18); C=$(t18_i3g $H18)
  if [ "$T18_RC" = "0/0" ] && [ "$R" = "$6" ] && [ "$C" = "1" ] && [ "$T18_B" = "EXISTING:$7 " ] && case "$T18_A" in WON:*) true;; *) false;; esac; then
    ok "18 两会话补扣 $T18N：赢家 $T18_A，输家干净返回 $T18_B，终态 $R，I3g=$C"
  else bad "18 两会话补扣 $T18N：rc=$T18_RC A=[$T18_A] B=[$T18_B] 终态 $R（期望 $6）I3g=$C"; fi
done
# 赢家提交后再重放（新会话，同 op_key、另一个 movement id）：返回 EXISTING，不多写任何行
R1=$(psql -q -t -A -c "$(t18_mk 6803 680303)" 2>&1); E1=$?
R=$(t18_state 6801 6803)/$(psql -t -A -c "SELECT count(*) FROM stock_movement WHERE stock_id = 6801")
if [ "$E1" = "0" ] && [ "$R1" = "EXISTING:DEDUCTED" ] && [ "$R" = "1/6802/0/DEDUCTED:1000:-/2000:2000/1" ]; then
  ok "18 补扣提交后重放：$R1，终态不变 $R"
else bad "18 补扣提交后重放：rc=$E1 [$R1] 终态 $R"; fi

# 重复 LDTH 键（Doro/小玛丽：断言 0 行，不只断言被拒；删掉 uq_exc_ldth_key 后这里报 42P10 变红）
R=$(psql -q -t -A -c "WITH ins AS (INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (681399,'EXC-681399',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:6813',lpad('681399',64,'0'),3,32,600,0,-600,'2026-10-17 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'LIVE_DEATH' DO NOTHING RETURNING 1) SELECT count(*) FROM ins" 2>&1)
N=$(psql -t -A -c "SELECT count(*) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:6813'")
[ "$R" = "0" ] && [ "$N" = "1" ] && ok "18 重复 LDTH:6813 走 ON CONFLICT (source_key) WHERE LIVE_DEATH：插入 0 行，仍 1 张" || bad "18 重复 LDTH 键：插入=[$R] 张数=$N（期望 0/1）"
R=$(psql -t -A -c "SELECT indisunique::text || '/' || pg_get_expr(indpred, indrelid) || '/' || pg_get_indexdef(indexrelid, 1, true) FROM pg_index WHERE indexrelid = to_regclass('public.uq_exc_ldth_key')")
[ "$R" = "true/((source_type)::text = 'LIVE_DEATH'::text)/source_key" ] && ok "18 依赖的 uq_exc_ldth_key：唯一、部分谓词 LIVE_DEATH、列 source_key" || bad "uq_exc_ldth_key 目录：[$R]"

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
seed "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (999,1,1,1,1,'KG',100000);"
CT_DIR=$(mktemp -d)
for _ in $(seq 1 50); do
  psql -t -A -c \
    "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1, updated_at = now() WHERE id = 999 AND on_hand_qty_milli >= 3000;" \
    > "$CT_DIR/ct_$_.out" 2>&1 &
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

echo "=== 5b. release_live_hold 与 consume_live_hold 并发：先锁再按余量写，不扣旁边的 MANUAL ==="
expect_allow "并发底数：stock 60，LIVE_HOLD 3000 + MANUAL 2000" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (60,1,2,2,2,'KG',5000,5000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (160,60,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7801,'LH:7801',3000,0,'HELD',0),(161,60,'MANUAL','DAMAGE','MANUAL',0,'HOLD:161',2000,0,'HELD',7);"
REL_A=$(mktemp)
REL_B=$(mktemp)
psql >"$REL_A" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM stock WHERE id = 60 ORDER BY id FOR UPDATE;
SELECT id FROM stock_hold WHERE stock_id = 60 ORDER BY id FOR UPDATE;
SELECT pg_sleep(2);
INSERT INTO stock_hold_release (id, hold_id, op_key, qty_milli)
SELECT 181, h.id, 'LTH:7801:8901:' || h.id, h.hold_qty_milli - h.released_qty_milli
  FROM stock_hold h
 WHERE h.id = 160 AND h.hold_type = 'LIVE_HOLD' AND h.status = 'HELD';
UPDATE stock_hold
   SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1
 WHERE id = 160 AND hold_type = 'LIVE_HOLD' AND status = 'HELD';
UPDATE stock
   SET hold_qty_milli = hold_qty_milli - (
         SELECT COALESCE(SUM(r.qty_milli), 0) FROM stock_hold_release r WHERE r.id = 181 AND r.hold_id = 160),
       version = version + 1
 WHERE id = 60
   AND hold_qty_milli >= (
         SELECT COALESCE(SUM(r.qty_milli), 0) FROM stock_hold_release r WHERE r.id = 181 AND r.hold_id = 160);
COMMIT;
SQL
APID=$!
locked=0
for _ in $(seq 1 50); do
  n=$(psql -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep%';")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  if [ -n "$n" ] && [ "$n" != "0" ]; then locked=1; break; fi
  sleep 0.1
done
if [ "$locked" = "1" ]; then ok "释放会话已锁住库存行并停在 pg_sleep，消耗会话才开始"; else bad "没等到释放会话进入 pg_sleep"; echo "--- release ---"; cat "$REL_A"; fi
psql >"$REL_B" 2>&1 <<'SQL'
DO $$
DECLARE
  n_stock int;
  n_hold int;
BEGIN
  PERFORM id FROM stock WHERE id = 60 ORDER BY id FOR UPDATE;
  PERFORM id FROM stock_hold WHERE id IN (160, 161) ORDER BY id FOR UPDATE;
  UPDATE stock
     SET hold_qty_milli = hold_qty_milli - 1000,
         on_hand_qty_milli = on_hand_qty_milli - 1000,
         ledger_seq = ledger_seq + 1,
         version = version + 1
   WHERE id = 60 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000;
  GET DIAGNOSTICS n_stock = ROW_COUNT;
  UPDATE stock_hold
     SET released_qty_milli = released_qty_milli + 1000, version = version + 1
   WHERE id = 160 AND hold_type = 'LIVE_HOLD' AND status = 'HELD'
     AND hold_qty_milli - released_qty_milli >= 1000;
  GET DIAGNOSTICS n_hold = ROW_COUNT;
  IF n_stock <> 1 OR n_hold <> 1 THEN
    RAISE EXCEPTION 'consume_skipped stock=% hold=%', n_stock, n_hold;
  END IF;
END
$$;
SQL
BSTAT=$?
wait "$APID"
ASTAT=$?
if [ "$ASTAT" = "0" ] && ! grep -q deadlock "$REL_A"; then
  ok "并发释放会话提交成功，无死锁"
else
  bad "并发释放会话退出 $ASTAT"; echo "--- release ---"; cat "$REL_A"
fi
if [ "$BSTAT" != "0" ] && grep -q consume_skipped "$REL_B" && ! grep -q deadlock "$REL_B"; then
  ok "并发消耗会话等到锁后发现 LIVE_HOLD 已释放，整笔回滚，无死锁"
else
  bad "并发消耗会话退出 $BSTAT"; echo "--- consume ---"; cat "$REL_B"
fi
R=$(psql -t -A -c "SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h160.status||'/'||h160.released_qty_milli||'/'||h161.status||'/'||(h161.hold_qty_milli - h161.released_qty_milli)||'/'||(SELECT qty_milli FROM stock_hold_release WHERE id=181) FROM stock s JOIN stock_hold h160 ON h160.id=160 JOIN stock_hold h161 ON h161.id=161 WHERE s.id=60")
[ "$R" = "5000/2000/RELEASED/3000/HELD/2000/3000" ] && ok "并发后 on_hand/hold_qty/活鲜状态/已释放/MANUAL状态/MANUAL余量/释放量 = $R（MANUAL 2000 没被扣）" || bad "并发后 = $R（期望 5000/2000/RELEASED/3000/HELD/2000/3000）"
rm -f "$REL_A" "$REL_B"

echo "=== 5c. N-2 release_live_hold 同一 op_key 并发：锁到 0 条 HELD 就重查，不提交空释放、不抬 version ==="
expect_allow "N-2 并发底数：stock 62（container 1）LIVE_HOLD 3000" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (62,1,3,2,3,1,'KG',3000,3000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (171,62,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7902,'LH:7902',3000,0,'HELD',0);"
REL_A=$(mktemp)
REL_B=$(mktemp)
psql >"$REL_A" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM stock WHERE id = 62 ORDER BY id FOR UPDATE;
SELECT id FROM stock_hold WHERE id = 171 ORDER BY id FOR UPDATE;
SELECT pg_sleep(2);
INSERT INTO stock_hold_release (id, hold_id, op_key, qty_milli)
SELECT 192, h.id, 'LTH:7902:9002:' || h.id, h.hold_qty_milli - h.released_qty_milli
  FROM stock_hold h
 WHERE h.id = 171 AND h.status = 'HELD';
UPDATE stock_hold
   SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1
 WHERE id = 171 AND status = 'HELD';
UPDATE stock
   SET hold_qty_milli = hold_qty_milli - (
         SELECT COALESCE(SUM(r.qty_milli), 0) FROM stock_hold_release r WHERE r.id = 192),
       version = version + 1
 WHERE id = 62
   AND hold_qty_milli >= (
         SELECT COALESCE(SUM(r.qty_milli), 0) FROM stock_hold_release r WHERE r.id = 192);
COMMIT;
SQL
APID=$!
locked=0
for _ in $(seq 1 50); do
  n=$(psql -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep%';")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  if [ -n "$n" ] && [ "$n" != "0" ]; then locked=1; break; fi
  sleep 0.1
done
if [ "$locked" = "1" ]; then ok "N-2 释放会话已持锁并停在 pg_sleep，重放会话才开始"; else bad "N-2 没等到释放会话进入 pg_sleep"; echo "--- release ---"; cat "$REL_A"; fi
psql >"$REL_B" 2>&1 <<'SQL'
DO $$
DECLARE
  n0 int;
  n_held int;
  n2 int;
BEGIN
  SELECT count(*) INTO n0 FROM stock_hold_release WHERE op_key = 'LTH:7902:9002:171';
  PERFORM id FROM stock WHERE id = 62 ORDER BY id FOR UPDATE;
  PERFORM id FROM stock_hold WHERE id = 171 AND status = 'HELD' ORDER BY id FOR UPDATE;
  SELECT count(*) INTO n_held FROM stock_hold WHERE id = 171 AND status = 'HELD';
  IF n_held <> 0 THEN
    RAISE EXCEPTION 'held_still %', n_held;
  END IF;
  SELECT count(*) INTO n2 FROM stock_hold_release WHERE op_key = 'LTH:7902:9002:171';
  IF n0 <> 0 OR n2 <> 1 THEN
    RAISE EXCEPTION 'replay_bad n0=% held=% n2=%', n0, n_held, n2;
  END IF;
  RAISE NOTICE 'replay_return n0=% held=% releases=%', n0, n_held, n2;
END
$$;
SQL
BSTAT=$?
wait "$APID"
ASTAT=$?
if [ "$ASTAT" = "0" ] && ! grep -q deadlock "$REL_A"; then
  ok "N-2 并发释放会话提交成功，无死锁"
else
  bad "N-2 并发释放会话退出 $ASTAT"; echo "--- release ---"; cat "$REL_A"
fi
if [ "$BSTAT" = "0" ] && grep -q 'replay_return n0=0 held=0 releases=1' "$REL_B" && ! grep -q deadlock "$REL_B"; then
  ok "N-2 重放会话等到锁后 HELD 为 0，重查到原释放并返回，无死锁"
else
  bad "N-2 重放会话退出 $BSTAT"; echo "--- replay ---"; cat "$REL_B"
fi
R=$(psql -t -A -c "SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.status||'/'||h.version||'/'||(SELECT count(*) FROM stock_hold_release WHERE op_key='LTH:7902:9002:171')||'/'||(SELECT qty_milli FROM stock_hold_release WHERE id=192) FROM stock s JOIN stock_hold h ON h.id=171 WHERE s.id=62")
[ "$R" = "1/3000/0/RELEASED/1/1/3000" ] && ok "N-2 并发后 version/on_hand/hold_qty/状态/明细 version/释放行数/释放量 = $R（没有第二次释放）" || bad "N-2 并发后 = $R（期望 1/3000/0/RELEASED/1/1/3000）"
rm -f "$REL_A" "$REL_B"
echo "=== 6. 小吴 C3 形态 A 并发：业务事务只写 seq=0，relay 提交后补号 ==="
# ① 小 id 后提交：T1 先插 id=9401 但晚提交，T2 插 id=9402 先提交；relay 在 T1 提交前跑一次、之后再跑一次
psql -v ON_ERROR_STOP=1 -q -c "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9401,'t','OBT-C3-A','{}',1,8,0); SELECT pg_sleep(2); COMMIT;" >/dev/null &
T1=$!
sleep 0.5
psql -v ON_ERROR_STOP=1 -q -c "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9402,'t','OBT-C3-B','{}',1,8,0);" >/dev/null || bad "C3 T2 插 9402失败"
psql -v ON_ERROR_STOP=1 -q -c "BEGIN; SELECT pg_advisory_xact_lock(8); UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id; COMMIT;" >/dev/null || bad "C3 relay 第 1 次补号失败"
wait $T1 || bad "C3 T1（9401 晚提交）失败"
psql -v ON_ERROR_STOP=1 -q -c "BEGIN; SELECT pg_advisory_xact_lock(8); UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id; COMMIT;" >/dev/null || bad "C3 relay 第 2 次补号（T1 提交后）失败"
R=$(psql -q -t -A -c "SELECT string_agg(id || ':' || seq, ',' ORDER BY id) FROM outbox_event WHERE node_id = 8")
[ "$R" = "9401:2,9402:1" ] && ok "C3 小 id 后提交 → 拿到更大的 seq（$R）：seq 只按提交后补号顺序，不承诺全仓全局按 id 有序" || bad "C3 提交顺序用例：$R"
# ② 40 个并发业务事务（各自 biz_key）+ relay 循环同时跑；结束后 seq 连续 1..42 无重复
CC_DIR=$(mktemp -d)
for i in $(seq 1 40); do
  psql -q -c "BEGIN; INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES ($((9500+i)),'t','OBT-CC-$i','{}',1,8,0); SELECT pg_sleep(random()*0.2); COMMIT;" > "$CC_DIR/i_$i.out" &
done
for _ in $(seq 1 5); do psql -q -c "BEGIN; SELECT pg_advisory_xact_lock(8); UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id; COMMIT;" > "$CC_DIR/r_$_.out" & sleep 0.05; done
wait
psql -v ON_ERROR_STOP=1 -q -c "BEGIN; SELECT pg_advisory_xact_lock(8); UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id; COMMIT;" >/dev/null || bad "C3 收尾 relay 补号失败"
ERRS=$(cat "$CC_DIR"/*.out | grep -c ERROR)
R=$(psql -q -t -A -c "SELECT count(*) || '/' || count(DISTINCT seq) || '/' || min(seq) || '/' || max(seq) || '/' || sum(CASE WHEN seq = 0 THEN 1 ELSE 0 END) FROM outbox_event WHERE node_id = 8")
[ "$R" = "42/42/1/42/0" ] && [ "$ERRS" = "0" ] && ok "C3 40 并发事务 + 5 个并发 relay：seq 连续 1..42、无重复、无漏补、无报错（$R）" || bad "C3 并发补号：$R，错误 $ERRS"
R=$(psql -q -t -A -c "SELECT count(*) FROM numbering_segment WHERE biz_prefix LIKE 'OUTBOX%'")
[ "$R" = "0" ] && ok "C3 并发期间业务事务未触碰 numbering_segment（无单行热点）" || bad "numbering_segment 出现 OUTBOX 行：$R"
expect_block "C3 并发补号后重复 seq（同节点）" "UPDATE outbox_event SET seq = 1 WHERE id = (SELECT id FROM outbox_event WHERE node_id = 8 AND seq = 2);" "outbox_seq_immutable"

echo "=== 5d. convert_hold 与 consume_live_hold 并发：先锁 stock、停在 pg_sleep、再锁 stock_hold，不死锁 ==="
# 睡眠放在两把锁中间：转换会话只持有 stock 行锁时，消耗会话按 release/consume 的顺序去锁同一行。
# 若转换改回先锁 stock_hold，消耗会话会先拿到 stock、再去等 stock_hold，两边交叉等待，这里应报 deadlock。
expect_allow "convert 并发底数：stock 63（container 2）RETURN_PENDING 3000 + LIVE_HOLD 2000" \
  "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (63,1,1,2,1,2,'KG',5000,5000); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (180,63,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',963,'RRH:963',3000,0,'HELD',0),(181,63,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',9631,'LH:9631',2000,0,'HELD',0);"
REL_A=$(mktemp)
REL_B=$(mktemp)
psql >"$REL_A" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM stock WHERE id = 63 ORDER BY id FOR UPDATE;
SELECT pg_sleep(2);
SELECT id FROM stock_hold WHERE id = 180 ORDER BY id FOR UPDATE;
UPDATE stock_hold
   SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1
 WHERE id = 180 AND status = 'HELD' AND released_qty_milli = 0;
INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id)
VALUES (182,63,'SCRAP_PENDING','SCRAP','SCRAP',9301,'CVT:180',3000,0,'HELD',0,180);
COMMIT;
SQL
APID=$!
locked=0
for _ in $(seq 1 50); do
  n=$(psql -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep%';")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  if [ -n "$n" ] && [ "$n" != "0" ]; then locked=1; break; fi
  sleep 0.1
done
if [ "$locked" = "1" ]; then ok "convert 会话已锁库存行并停在 pg_sleep，消耗会话才开始"; else bad "没等到 convert 会话进入 pg_sleep"; echo "--- convert ---"; cat "$REL_A"; fi
psql >"$REL_B" 2>&1 <<'SQL'
DO $$
DECLARE
  n_stock int;
  n_hold int;
BEGIN
  PERFORM id FROM stock WHERE id = 63 ORDER BY id FOR UPDATE;
  PERFORM id FROM stock_hold WHERE id IN (180, 181) ORDER BY id FOR UPDATE;
  UPDATE stock
     SET hold_qty_milli = hold_qty_milli - 1000,
         on_hand_qty_milli = on_hand_qty_milli - 1000,
         ledger_seq = ledger_seq + 1,
         version = version + 1
   WHERE id = 63 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000;
  GET DIAGNOSTICS n_stock = ROW_COUNT;
  UPDATE stock_hold
     SET released_qty_milli = released_qty_milli + 1000, version = version + 1
   WHERE id = 181 AND hold_type = 'LIVE_HOLD' AND status = 'HELD'
     AND hold_qty_milli - released_qty_milli >= 1000;
  GET DIAGNOSTICS n_hold = ROW_COUNT;
  IF n_stock <> 1 OR n_hold <> 1 THEN
    RAISE EXCEPTION 'consume_skipped stock=% hold=%', n_stock, n_hold;
  END IF;
END
$$;
SQL
BSTAT=$?
wait "$APID"
ASTAT=$?
if [ "$ASTAT" = "0" ] && ! grep -q deadlock "$REL_A"; then
  ok "并发 convert 会话提交成功，无死锁"
else
  bad "并发 convert 会话退出 $ASTAT"; echo "--- convert ---"; cat "$REL_A"
fi
if [ "$BSTAT" = "0" ] && ! grep -q deadlock "$REL_B"; then
  ok "并发消耗会话按同一锁序等到库存行后扣 1000，无死锁"
else
  bad "并发消耗会话退出 $BSTAT"; echo "--- consume ---"; cat "$REL_B"
fi
R=$(psql -t -A -c "SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||s.ledger_seq||'/'||h180.status||'/'||h180.released_qty_milli||'/'||h182.status||'/'||h182.hold_qty_milli||'/'||h181.status||'/'||h181.released_qty_milli FROM stock s JOIN stock_hold h180 ON h180.id=180 JOIN stock_hold h182 ON h182.id=182 JOIN stock_hold h181 ON h181.id=181 WHERE s.id=63")
[ "$R" = "1/4000/4000/1/RELEASED/3000/HELD/3000/HELD/1000" ] && ok "并发后 version/on_hand/hold_qty/ledger/待回库/已释放/报损状态/报损量/活鲜状态/活鲜已释放 = $R（同列转换没改库存数量，只被消耗扣了 1000）" || bad "并发后 = $R（期望 1/4000/4000/1/RELEASED/3000/HELD/3000/HELD/1000）"
rm -f "$REL_A" "$REL_B"

echo "=== 2g. docs/12 权限与审计（小赵评审 B1、I1–I7、S1 + SCRAP_MISREPORT）==="
seed "INSERT INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x');"
seed "UPDATE sys_user SET perm_version = 3 WHERE id = 101;"
seed "INSERT INTO sys_role (id,code,name) VALUES (1,'WH_SUPERVISOR','仓库主管'),(2,'CENTER_OPS','中心运维'),(3,'QC_SUPERVISOR','质检主管');"
seed "INSERT INTO sys_permission (id,code,name,module) VALUES (1,'device.binding.approve','设备绑定审批','12'),(2,'delivery.pod.correct.approve','POD 更正审批','15'),(3,'outbound.order.cancel_after_pick.approve','拣后取消审批','04'),(4,'outbound.order.cancel_after_pick','拣后取消申请','04');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,1),(1,2),(1,3),(1,4),(2,3);"
seed "INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (2,'W2','x','20:00'),(3,'ABCDEFGH12345678','x','20:00'),(4,'SHPD01','x','20:00');"
seed "INSERT INTO sys_user_role (user_id,role_id) VALUES (202,1),(202,2),(203,2),(205,3),(206,1),(207,3),(101,1),(208,1),(201,1);"
seed "INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (202,1),(203,1),(204,1),(205,1),(206,1),(101,1),(201,1);"
seed "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-A','PDA',101,1);"
seed "INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00');"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000111','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);"
seed "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1,'outbound.cancel_after_pick',7,1,1);"
_AC=$(psql -t -A -c "SELECT count(*) FROM audit_log")
expect_block "12 审计重复回传同 (node_id,node_seq)" \
  "INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (2,'x',7,1);" "uq_audit_node_seq"
_AC2=$(psql -t -A -c "SELECT count(*) FROM audit_log"); [ "$_AC2" = "$_AC" ] && ok "12 审计重复回传同 (node_id,node_seq)：audit_log 行数不变（$_AC）" || bad "12 审计重复回传同 (node_id,node_seq)：audit_log 行数 $_AC -> $_AC2"
_AH=$(psql -t -A -c "SELECT md5(row_to_json(a)::text) FROM audit_log a WHERE id=1")
expect_block "12 audit_log 只追加（UPDATE）" \
  "UPDATE audit_log SET reason='x' WHERE id=1;" "append_only_violation: audit_log"
_AH2=$(psql -t -A -c "SELECT md5(row_to_json(a)::text) FROM audit_log a WHERE id=1"); [ -n "$_AH" ] && [ "$_AH2" = "$_AH" ] && ok "12 audit_log 只追加（UPDATE）：id=1 行内容不变（md5 $_AH）" || bad "12 audit_log 只追加（UPDATE）：id=1 行内容变了 $_AH -> $_AH2"
_AC=$(psql -t -A -c "SELECT count(*) FROM audit_log")
expect_block "12 audit_log 只追加（DELETE）" \
  "DELETE FROM audit_log WHERE id=1;" "append_only_violation: audit_log"
_AC2=$(psql -t -A -c "SELECT count(*) FROM audit_log"); [ "$_AC2" = "$_AC" ] && ok "12 audit_log 只追加（DELETE）：audit_log 行数不变（$_AC）" || bad "12 audit_log 只追加（DELETE）：audit_log 行数 $_AC -> $_AC2"
expect_allow "12 B1 正向：新 (node_id,node_seq) 追加" \
  "BEGIN; INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (3,'x',7,2); COMMIT;"
expect_block "12 同一设备实例两条 PENDING/ACTIVE 绑定" \
  "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (2,'DEV-A','PDA',102,1);" "uq_udb_active"
expect_block "12 I3 直接插成 ACTIVE" \
  "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,status,activated_at,approval_id) VALUES (3,'DEV-C','PDA',101,1,'ACTIVE','2026-10-15 08:00',1);" "binding_insert_not_pending"
expect_block "12 REVOKED 没有吊销时间" \
  "UPDATE user_device_binding SET status='REVOKED' WHERE id=1;" "ck_udb_status"
expect_block "12 I3 用不存在的审批激活" \
  "UPDATE user_device_binding SET status='ACTIVE', approval_id=999, activated_at='2026-10-15 09:00' WHERE id=1;" "binding_approval_invalid"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (7,'APR-WHSH01-20261015-000007','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL);"
seed "UPDATE approval_request SET status='APPROVED', first_approver_id=101, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=7;"
expect_block "12 S1 审批人 = 绑定使用人" \
  "UPDATE user_device_binding SET status='ACTIVE', approval_id=7, activated_at='2026-10-15 09:00' WHERE id=1;" "binding_approval_invalid"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (8,'APR-WHSH01-20261015-000008','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL);"
seed "UPDATE approval_request SET status='REJECTED', decided_at='2026-10-15 09:00', reject_reason='x' WHERE id=8;"
expect_block "12 I3 用已驳回的审批激活" \
  "UPDATE user_device_binding SET status='ACTIVE', approval_id=8, activated_at='2026-10-15 09:00' WHERE id=1;" "binding_approval_invalid"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (9,'APR-WHSH01-20261015-000909','CANCEL_AFTER_PICK',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL);"
seed "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=9;"
expect_block "12 I3 用别的类型的审批激活" \
  "UPDATE user_device_binding SET status='ACTIVE', approval_id=9, activated_at='2026-10-15 09:00' WHERE id=1;" "binding_approval_invalid"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (10,'APR-WHSH01-20261015-000010','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL);"
seed "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=10;"
expect_allow "12 I3 正向：DEVICE_BIND 已通过、审批人≠使用人 → PENDING→ACTIVE" \
  "BEGIN; UPDATE user_device_binding SET status='ACTIVE', approval_id=10, activated_at='2026-10-15 09:00' WHERE id=1 AND status='PENDING'; COMMIT;"
expect_block "12 I3 绑定换人" \
  "UPDATE user_device_binding SET user_id=99 WHERE id=1;" "binding_immutable"
expect_block "12 I3 ACTIVE 退回 PENDING" \
  "UPDATE user_device_binding SET status='PENDING', activated_at=NULL WHERE id=1;" "binding_immutable"
expect_allow "12 I3 正向：吊销" \
  "BEGIN; UPDATE user_device_binding SET status='REVOKED', revoked_at='2026-10-15 10:00', revoke_reason='LOST' WHERE id=1; COMMIT;"
expect_block "12 I3 REVOKED 复活" \
  "UPDATE user_device_binding SET status='ACTIVE', revoked_at=NULL WHERE id=1;" "binding_immutable"
expect_block "12 绑定不可删除" \
  "DELETE FROM user_device_binding WHERE id=1;" "append_only_violation: user_device_binding"
expect_block "12 离线令牌到期早于签发" \
  "INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (2,'J2',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 07:00');" "ck_offline_ttl"
expect_block "12 I4 离线令牌 30 天" \
  "INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (3,'J3',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-11-14 08:00');" "ck_offline_max_ttl"
expect_allow "12 I4 正向：恰好 12 小时" \
  "BEGIN; INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (4,'J4',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00'); COMMIT;"
expect_block "12 离线令牌 jti 重复" \
  "INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (5,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00');" "uq_offline_jti"
expect_block "12 I4 延长有效期" \
  "UPDATE offline_token SET expires_at='2026-10-15 19:00' WHERE id=1;" "offline_token_immutable"
expect_allow "12 I4 正向：吊销" \
  "BEGIN; UPDATE offline_token SET revoked_at='2026-10-15 10:00' WHERE id=1; COMMIT;"
expect_block "12 I4 吊销后恢复" \
  "UPDATE offline_token SET revoked_at=NULL WHERE id=1;" "offline_token_immutable"
expect_block "12 I2 直接插成 APPROVED" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at,status) VALUES (20,'APR-WHSH01-20261015-000020','POD_CORRECT',1,'POD','20','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01','APPROVED');" "approval_insert_not_pending"
expect_block "12 同一目标两条待审批" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (21,'APR-WHSH01-20261015-000021','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,NULL);" "uq_apr_open"
expect_block "12 SoD：申请人自己审批" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1;" "ck_apr_sod"
expect_block "12 I2 单人审批进 PARTIAL" \
  "UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=1;" "ck_apr_partial"
expect_block "12 I2 审批人三列不成组" \
  "UPDATE approval_request SET first_approver_id=202 WHERE id=1;" "ck_apr_pair"
expect_block "12 I2 REJECTED 没有 decided_at" \
  "UPDATE approval_request SET status='REJECTED' WHERE id=1;" "ck_apr_decided"
expect_allow "12 正向：主管审批通过" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1; COMMIT;"
expect_block "12 I1/I2 APPROVED 改回 PENDING" \
  "UPDATE approval_request SET status='PENDING', decided_at=NULL WHERE id=1;" "approval_final"
expect_block "12 审批不可删除" \
  "DELETE FROM approval_request WHERE id=1;" "append_only_violation: approval_request"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,created_at,expires_at) VALUES (4,'APR-WHSH01-20261015-000114','POD_CORRECT',1,'POD','4','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2019-12-31 23:00:00','2020-01-01 00:00:00');"
expect_block "12 I2 过期后审批" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=4;" "approval_expired"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,created_at,expires_at) VALUES (41,'APR-WHSH01-20261015-000041','POD_CORRECT',1,'POD','41','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,date_trunc('second', now() AT TIME ZONE 'UTC') - interval '2 minutes',date_trunc('second', now() AT TIME ZONE 'UTC') - interval '1 minute');"
expect_block "12 UTC 反向：expires_at = UTC 当前 −1 分钟，已过期不能再批" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=41;" "approval_expired"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (42,'APR-WHSH01-20261015-000042','POD_CORRECT',1,'POD','42','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,date_trunc('second', now() AT TIME ZONE 'UTC') + interval '2 hours');"
expect_allow "12 UTC 正向：expires_at = UTC 当前 +2 小时（比本地 UTC+8 早）仍可批" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=42; COMMIT;"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (3,'APR-WHSH01-20261015-000903','UNPLANNED_FAILOVER',1,'WAREHOUSE','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);"
expect_block "12 I5 第一确认人不持有任何角色" \
  "UPDATE approval_request SET status='PARTIAL', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3;" "approval_role_not_held"
expect_block "12 I5 第一确认人只有 CENTER_OPS 却写 WH_SUPERVISOR" \
  "UPDATE approval_request SET status='PARTIAL', first_approver_id=203, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3;" "approval_role_not_held"
expect_allow "12 I5 正向：真主管确认 → PARTIAL" \
  "BEGIN; UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3; COMMIT;"
expect_block "12 I2 换第一审批人" \
  "UPDATE approval_request SET first_approver_id=203 WHERE id=3;" "approval_approver_immutable"
expect_block "12 I2 PARTIAL 倒退 PENDING" \
  "UPDATE approval_request SET status='PENDING' WHERE id=3;" "approval_transition_invalid"
expect_block "12 I5 第二确认人不持有 CENTER_OPS" \
  "UPDATE approval_request SET second_approver_id=204, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3;" "approval_role_not_held"
expect_block "12 第二确认人 = 第一确认人" \
  "UPDATE approval_request SET second_approver_id=202, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3;" "ck_apr_dual"
expect_block "12 非计划切换只有一人确认就 APPROVED" \
  "UPDATE approval_request SET status='APPROVED', decided_at='2026-10-15 09:30' WHERE id=3;" "ck_apr_done"
expect_allow "12 I5 正向：中心运维第二确认 → APPROVED" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', second_approver_id=203, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30', decided_at='2026-10-15 09:30' WHERE id=3; COMMIT;"
# SCRAP_MISREPORT 权限点化（Chief 裁决：以权限点为准）：发起 scrap.misreport.request、审批 scrap.misreport.approve。
# 授权：role 1 = WH_SUPERVISOR 持发起；role 2 = CENTER_OPS、role 3 = QC_SUPERVISOR 持审批。
seed "INSERT INTO sys_permission (id,code,name,module) VALUES (16,'scrap.misreport.request','报损误报回转发起','12'),(17,'scrap.misreport.approve','报损误报回转审批','12');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,16),(2,17),(3,17);"
expect_block "12 SM 发起人不是本仓仓库主管（只有 CENTER_OPS）" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (23,'APR-WHSH01-20261015-000023','SCRAP_MISREPORT',1,'SCRAP_ORDER','9009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,NULL);" "approval_perm_not_held"
expect_block "12 SM 发起人是质检主管而非仓库主管" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (24,'APR-WHSH01-20261015-000024','SCRAP_MISREPORT',1,'SCRAP_ORDER','9010','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',205,NULL);" "approval_perm_not_held"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (5,'APR-WHSH01-20261015-000005','SCRAP_MISREPORT',1,'SCRAP_ORDER','9001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL);"
expect_block "12 SM 发起人自己审批（202 兼 CENTER_OPS 也不行）" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5;" "ck_apr_sod"
expect_block "12 SM 审批角色写成仓库主管（另一主管 206 不具审批权）" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=206, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5;" "approval_perm_not_held"
expect_block "12 SM 审批人不持有 QC_SUPERVISOR 却写质检主管" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5;" "approval_perm_not_held"
expect_block "12 SM 质检主管不在本仓" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=207, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5;" "approval_perm_not_held"
expect_allow "12 SM 正向：本仓质检主管审批" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5; COMMIT;"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (6,'APR-WHSH01-20261015-000006','SCRAP_MISREPORT',1,'SCRAP_ORDER','9002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',206,NULL);"
expect_allow "12 SM 正向：中心运维审批" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=6; COMMIT;"
expect_block "12 审批单号格式：旧格式 SM-2026-001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (30,'SM-2026-001','CANCEL_AFTER_PICK',1,'OUTBOUND','30','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：日期 7 位 APR-WHSH01-2026101-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (31,'APR-WHSH01-2026101-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','31','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：序号 5 位 APR-WHSH01-20261015-00001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (32,'APR-WHSH01-20261015-00001','CANCEL_AFTER_PICK',1,'OUTBOUND','32','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：仓库编码为空 APR--20261015-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (33,'APR--20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','33','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：日期含字母 APR-WHSH01-2026A015-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (34,'APR-WHSH01-2026A015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','34','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：月份 13 APR-WHSH01-20261315-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (35,'APR-WHSH01-20261315-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','35','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：序号含字母 APR-WHSH01-20261015-00000X" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (36,'APR-WHSH01-20261015-00000X','CANCEL_AFTER_PICK',1,'OUTBOUND','36','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：前缀小写 apr-WH01-20261015-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (37,'apr-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','37','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 审批单号格式：仓库编码含 - APR-WH-01-20261015-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (38,'APR-WH-01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','38','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_allow "12 审批单号格式正向：APR-SHPD01-20261231-999999" \
  "BEGIN; INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (40,'APR-SHPD01-20261231-999999','POD_CORRECT',4,'POD','40','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL); COMMIT;"
expect_block "12 审批类型不在码表" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (22,'APR-WHSH01-20261015-000022','BANANA',1,'X','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_type"
expect_block "12 perm_version 回退" \
  "UPDATE sys_user SET perm_version = 1 WHERE id = 101;" "perm_version_rewind"
expect_allow "12 I7 正向：perm_version 前进" \
  "BEGIN; UPDATE sys_user SET perm_version = 4 WHERE id = 101; COMMIT;"
expect_block "12 T1 审批单号：仓库编码小写 APR-sh01-20261015-000001" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (50,'APR-sh01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','50','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 T1 审批单号：仓库编码含下划线 APR-S_01-20261015-000002" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (51,'APR-S_01-20261015-000002','CANCEL_AFTER_PICK',1,'OUTBOUND','51','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 T1 审批单号：仓库编码含空格 APR-S 01-20261015-000003" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (52,'APR-S 01-20261015-000003','CANCEL_AFTER_PICK',1,'OUTBOUND','52','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 T1 审批单号：仓库编码长度 1 APR-A-20261015-000004" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (53,'APR-A-20261015-000004','CANCEL_AFTER_PICK',1,'OUTBOUND','53','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_block "12 T1 审批单号：仓库编码长度 17 APR-ABCDEFGHIJKLMNOPQ-20261015-000005" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (54,'APR-ABCDEFGHIJKLMNOPQ-20261015-000005','CANCEL_AFTER_PICK',1,'OUTBOUND','54','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "ck_apr_code"
expect_allow "12 T1 正向：仓库编码长度 2 / 16" \
  "BEGIN; INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (56,'APR-W2-20261015-000006','POD_CORRECT',2,'POD','56','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL); INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (57,'APR-ABCDEFGH12345678-20261015-000007','POD_CORRECT',3,'POD','57','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL); COMMIT;"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (60,'APR-WHSH01-20261015-000060','DEVICE_BIND',1,'DEVICE_BINDING','60','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL);"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (61,'APR-WHSH01-20261015-000061','POD_CORRECT',1,'POD','61','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (62,'APR-WHSH01-20261015-000062','CANCEL_AFTER_PICK',1,'OUTBOUND','62','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);"
expect_block "12 T2 DEVICE_BIND：无任何角色的用户（204）批准" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60;" "approval_perm_not_held"
expect_block "12 T2 POD_CORRECT：无任何角色的用户（204）批准" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61;" "approval_perm_not_held"
expect_block "12 T2 CANCEL_AFTER_PICK：无任何角色的用户（204）批准" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=62;" "approval_perm_not_held"
expect_block "12 T2 DEVICE_BIND：角色存在但无该权限点（203 CENTER_OPS）" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60;" "approval_perm_not_held"
expect_block "12 T2 DEVICE_BIND：有主管角色但不在本仓（208）" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=208, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60;" "approval_perm_not_held"
expect_block "12 T2 POD_CORRECT：质检主管无该权限点（205）" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61;" "approval_perm_not_held"
expect_allow "12 T2 正向：本仓主管经 sys_role_perm 持有 device.binding.approve" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60; COMMIT;"
expect_allow "12 T2 正向：本仓主管持有 delivery.pod.correct.approve" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61; COMMIT;"
expect_allow "12 T2 正向：本仓主管持有 outbound.order.cancel_after_pick.approve" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=62; COMMIT;"
seed "INSERT INTO sys_role (id,code,name) VALUES (4,'CS','客服');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (4,4);"
seed "INSERT INTO sys_user_role (user_id,role_id) VALUES (209,4),(210,2);"
seed "INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (209,1);"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (63,'APR-WHSH01-20261015-000063','CANCEL_AFTER_PICK',1,'OUTBOUND','63','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',209,NULL);"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (64,'APR-WHSH01-20261015-000064','CANCEL_AFTER_PICK',1,'OUTBOUND','64','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL);"
expect_block "12 拣后取消：只有申请权限 cancel_after_pick（客服 209）不能审批" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=209, first_approver_role='CS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64;" "approval_perm_not_held"
expect_block "12 拣后取消：申请人 202（持有 .approve）审批自己的单" \
  "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64;" "ck_apr_sod"
expect_allow "12 拣后取消正向：不在本仓的 CENTER_OPS（210，数据范围 ALL）审批" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=210, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=63; COMMIT;"
expect_allow "12 拣后取消正向：另一位本仓主管 201 审批 202 的申请" \
  "BEGIN; UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64; COMMIT;"
expect_block "12 单号仓库编码 WH01 ≠ 仓 1 的 WHSH01" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (65,'APR-WH01-20261015-000065','POD_CORRECT',1,'POD','65','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "approval_code_warehouse_mismatch"
expect_block "12 单号写 W2 但挂在仓 1" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (66,'APR-W2-20261015-000066','POD_CORRECT',1,'POD','66','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "approval_code_warehouse_mismatch"
expect_block "12 所属仓不存在（warehouse_id=99）" \
  "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (67,'APR-WHSH01-20261015-000067','POD_CORRECT',99,'POD','67','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL);" "approval_code_warehouse_mismatch"
expect_allow "12 单号仓库编码正向：APR-WHSH01-… 挂仓 1" \
  "BEGIN; INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (68,'APR-WHSH01-20261015-000068','POD_CORRECT',1,'POD','68','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL); COMMIT;"
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM approval_request WHERE id=1;")
case "$OUT" in *"permission denied for table approval_request"*) ok "12 wms_app 不能删审批";; *) bad "12 wms_app 不能删审批 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; UPDATE offline_token SET expires_at='2030-01-01' WHERE id=4;")
case "$OUT" in *"permission denied for table offline_token"*) ok "12 wms_app 不能改离线令牌有效期";; *) bad "12 wms_app 不能改离线令牌有效期 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; DELETE FROM user_device_binding WHERE id=1;")
case "$OUT" in *"permission denied for table user_device_binding"*) ok "12 wms_app 不能删设备绑定";; *) bad "12 wms_app 不能删设备绑定 未被拒：$OUT";; esac
OUT=$(psql_capture "SET ROLE wms_app; UPDATE user_device_binding SET user_id=5 WHERE id=1;")
case "$OUT" in *"permission denied for table user_device_binding"*) ok "12 I3 wms_app 不能改绑定使用人（列级授权）";; *) bad "12 I3 wms_app 不能改绑定使用人（列级授权） 未被拒：$OUT";; esac
_AC=$(psql -t -A -c "SELECT count(*) FROM audit_log")
OUT=$(psql_capture "TRUNCATE audit_log;")
case "$OUT" in *"append_only_violation"*) ok "12 TRUNCATE audit_log 被语句级触发器拦下";; *) bad "TRUNCATE audit_log 未被拦：$OUT";; esac
_AC2=$(psql -t -A -c "SELECT count(*) FROM audit_log"); [ "$_AC2" = "$_AC" ] && ok "12 TRUNCATE audit_log：audit_log 行数不变（$_AC）" || bad "12 TRUNCATE audit_log：audit_log 行数 $_AC -> $_AC2"
# 叠加 #2 的 fk_hold_approval_no 后，PG 会先以外键拒绝 TRUNCATE（报错不再是 append_only_violation）；两种拦法都算通过，再核对行数未变
CNT_B=$(psql -qtAc "SELECT (SELECT count(*) FROM approval_request)||'/'||(SELECT count(*) FROM user_device_binding);")
OUT=$(psql_capture "TRUNCATE approval_request, user_device_binding;")
CNT_A=$(psql -qtAc "SELECT (SELECT count(*) FROM approval_request)||'/'||(SELECT count(*) FROM user_device_binding);")
case "$OUT" in *"append_only_violation"*|*"cannot truncate a table referenced in a foreign key constraint"*) ok "12 TRUNCATE 审批/绑定被拦";; *) bad "TRUNCATE 审批/绑定未被拦：$OUT";; esac
[ -n "$CNT_B" ] && [ "$CNT_B" = "$CNT_A" ] && ok "12 TRUNCATE 审批/绑定后行数不变（$CNT_A）" || bad "TRUNCATE 审批/绑定后行数变化：$CNT_B -> $CNT_A"
# 逐表单独 TRUNCATE 命中目标表自身的语句级 TRUNCATE 触发器：只挑**不被任何外键引用**的 append-only 表
# （approval_request / user_device_binding 被 stock_hold / audit_log / device_reconnect / offline_token，以及第 16 篇的
#   pod_correction.fk_podc_apr 引用，单表 TRUNCATE 会先撞外键 —— 那条路由由下面两条「被外键拒」断言覆盖）
for T in audit_log device_reconnect; do
  OUT=$(psql_capture "BEGIN; TRUNCATE $T; ROLLBACK;")
  case "$OUT" in *"append_only_violation: $T"*) ok "12 单表 TRUNCATE $T 命中自身触发器";; *) bad "12 单表 TRUNCATE $T 未报 append_only_violation：$OUT";; esac
done
# 被外键引用的 append-only 表：TRUNCATE 由外键先拒（#16 的 pod_correction.fk_podc_apr 让 approval_request 也走这条路由）
for T in approval_request user_device_binding; do
  OUT=$(psql_capture "TRUNCATE $T;")
  case "$OUT" in *"cannot truncate a table referenced in a foreign key constraint"*) ok "12 单表 TRUNCATE $T 被外键拒（引用它的表拦在前面）";; *) bad "12 单表 TRUNCATE $T 未被外键拒：$OUT";; esac
done
FKN=$(psql -qtAc "SELECT count(*) FROM pg_constraint WHERE conname IN ('fk_hold_approval_no','fk_podc_apr');")
[ "$FKN" = 2 ] && ok "12 单表 TRUNCATE 用例后 fk_hold_approval_no / fk_podc_apr 仍在（$FKN）" || bad "单表 TRUNCATE 用例后外键丢失：$FKN"


echo "=== 2g2. 新审批类型 + audit node 必填 ==="
seed "INSERT INTO sys_permission (id,code,name,module) VALUES (11,'offline.paper.approve','纸质补录审批','00'),(12,'pack.box.void.approve','作废箱审批','06'),(13,'process.yield.approve','得率偏离审批','17'),(14,'live.death.approve','活鲜死亡超阈值审批','18'),(15,'process.rework.approve','加工返工审批','17');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,11),(1,12),(1,13),(1,14),(1,15);"
H=$(printf 'a%.0s' $(seq 64))
i=0
for T in PAPER_BACKFILL BOX_VOID PROCESS_YIELD_DEVIATION LIVE_DEATH_OVER PROCESS_REWORK; do
  A=$((81+i)); B=$((86+i))
  seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES ($A,'APR-WHSH01-20261015-0000$A','$T',1,'$T','$A','{}','$H','r',201,NULL),($B,'APR-WHSH01-20261015-0000$B','$T',1,'$T','$B','{}','$H','r',202,NULL);"
  APP="UPDATE approval_request SET status='APPROVED', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00'"
  expect_block "12 $T：无该审批权限点（质检主管 205）" "$APP, first_approver_id=205, first_approver_role='QC_SUPERVISOR' WHERE id=$A;" "approval_perm_not_held"
  expect_block "12 $T：申请人 202 自批" "$APP, first_approver_id=202, first_approver_role='WH_SUPERVISOR' WHERE id=$B;" "ck_apr_sod"
  expect_allow "12 $T 正向：本仓主管 202 审批 201 的申请" "$APP, first_approver_id=202, first_approver_role='WH_SUPERVISOR' WHERE id=$A;"
  i=$((i+1))
done
# 12 search_path 固定：8 个函数都带 SET search_path = pg_catalog, public（防同名表劫持）
R=$(psql -t -A -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('trg_audit_node_required','trg_audit_append_only','trg_apr_insert','trg_apr_final','trg_udb_guard','trg_no_delete_12','trg_offline_guard','trg_user_perm_ver') AND 'search_path=pg_catalog, public, pg_temp' = ANY(p.proconfig)")
[ "$R" = "8" ] && ok "12 search_path：8 个触发器函数 proconfig 均为 search_path=pg_catalog, public, pg_temp（$R）" || bad "12 search_path：只有 $R/8 个函数固定了 search_path"
seed "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (95,'APR-WHSH01-20261015-000095','PAPER_BACKFILL',1,'PAPER_BACKFILL','95','{}','$H','r',201,NULL);"
# 劫持：会话把自建 schema 放在 search_path 最前，建同名的 sys_user_role/sys_role/sys_role_perm/sys_permission/sys_user_warehouse 影子表，给质检主管 205 伪造 offline.paper.approve。函数固定了 search_path，仍查 public 的真表 → 必须照样 approval_perm_not_held
OUT=$(psql_capture "CREATE SCHEMA hijack12; CREATE TABLE hijack12.sys_user_role (user_id BIGINT, role_id BIGINT); CREATE TABLE hijack12.sys_role (id BIGINT, code VARCHAR(32)); CREATE TABLE hijack12.sys_role_perm (role_id BIGINT, perm_id BIGINT); CREATE TABLE hijack12.sys_permission (id BIGINT, code VARCHAR(64)); CREATE TABLE hijack12.sys_user_warehouse (user_id BIGINT, warehouse_id BIGINT); INSERT INTO hijack12.sys_user_role VALUES (205,3); INSERT INTO hijack12.sys_role VALUES (3,'QC_SUPERVISOR'); INSERT INTO hijack12.sys_role_perm VALUES (3,11); INSERT INTO hijack12.sys_permission VALUES (11,'offline.paper.approve'); INSERT INTO hijack12.sys_user_warehouse VALUES (205,1); SET search_path = hijack12, public; UPDATE approval_request SET status='APPROVED', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00', first_approver_id=205, first_approver_role='QC_SUPERVISOR' WHERE id=95;")
case "$OUT" in *"approval_perm_not_held"*) ok "12 search_path 劫持：影子权限表在前，质检主管 205 仍被 approval_perm_not_held 拦下";; *) bad "12 search_path 劫持未拦：$OUT";; esac
R=$(psql -t -A -c "SELECT status||'/'||(SELECT count(*) FROM pg_namespace WHERE nspname='hijack12') FROM approval_request WHERE id=95")
psql -q -c "DROP SCHEMA IF EXISTS hijack12 CASCADE;" >/dev/null 2>&1
[ "$R" = "PENDING/0" ] && ok "12 search_path 劫持后审批仍 PENDING，影子 schema 随事务回滚（$R）" || bad "12 search_path 劫持后 状态/影子 schema = $R（期望 PENDING/0）"
_AC=$(psql -t -A -c "SELECT count(*) FROM audit_log")
expect_block "12 audit_log 新写入省略 node_id/node_seq → 40001" "INSERT INTO audit_log (id,action,warehouse_id) VALUES (900,'x',1);" "audit_node_required"
_AC2=$(psql -t -A -c "SELECT count(*) FROM audit_log"); [ "$_AC2" = "$_AC" ] && ok "12 audit_log 新写入省略 node_id/node_seq → 40001：audit_log 行数不变（$_AC）" || bad "12 audit_log 新写入省略 node_id/node_seq → 40001：audit_log 行数 $_AC -> $_AC2"
_AC=$(psql -t -A -c "SELECT count(*) FROM audit_log")
expect_block "12 audit_log node_seq=0 → 40001" "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (901,'x',7,0,1);" "audit_node_required"
_AC2=$(psql -t -A -c "SELECT count(*) FROM audit_log"); [ "$_AC2" = "$_AC" ] && ok "12 audit_log node_seq=0 → 40001：audit_log 行数不变（$_AC）" || bad "12 audit_log node_seq=0 → 40001：audit_log 行数 $_AC -> $_AC2"
expect_allow "12 audit_log node_id/node_seq > 0 正向" "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (902,'x',7,902,1);"
expect_block "12 stock_hold.approval_no 没有对应审批单" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (990,41,'RETURN_QC','RETURN_QC','QC',7990,'CVT:990',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000990',true);" "fk_hold_approval_no"
expect_allow "12 stock_hold.approval_no 指向已有审批单" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (991,41,'RETURN_QC','RETURN_QC','QC',7991,'CVT:991',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000123',true); ROLLBACK;"

echo "=== 2h-apr. 第 17 篇 × 第 12 篇：PROCESS_YIELD_DEVIATION / PROCESS_REWORK 审批权限与 SoD（放在 #9「2g3. stock_hold.approval_no」段之后；树里没有 #9 时整段跳过；权限点 process.yield.approve / process.rework.approve 用 #9 verify 种子，本段不插） ==="
_N9=$(psql -t -A -c "SELECT count(*) FROM sys_permission WHERE code IN ('process.yield.approve','process.rework.approve')" 2>/dev/null || echo 0)
_HAS12B=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='approval_request' AND column_name='approval_type'" 2>/dev/null || echo 0)
if [ "$_N9" = "0" ] && [ "$_HAS12B" = "0" ]; then
  ok "17×12 跳过：树里没有 #9（无 12b approval_request、无权限点种子），本段不自建"
elif [ "$_N9" = "0" ]; then
  bad "17×12 前置：已加载 #9 的 12b，但本段跑在 #9 种子之前（权限点 0/2）——本段须放在 #9「2g2. 新审批类型」/「2g3. stock_hold.approval_no」之后"
elif [ "$_N9" != "2" ]; then
  bad "17×12 前置：#9 权限点种子不全（$_N9/2）"
else
ok "17×12 前置：#9 种子已有 process.yield.approve / process.rework.approve（本段不自建）"
expect_allow "17×12 审批种子：申请人 1731（也持 PROC_LEAD）、无权审批人 1732（WH_SUPERVISOR 无 process.yield.approve）、加工主管 1733（PROC_LEAD 持有）" "INSERT INTO sys_user (id,username,password_hash) VALUES (1731,'u1731','x'),(1732,'u1732','x'),(1733,'u1733','x'); INSERT INTO sys_role (id,code,name) VALUES (1731,'WH_SUPERVISOR_17','仓库主管'),(1732,'PROC_LEAD','加工主管'); INSERT INTO sys_role_perm (role_id,perm_id) SELECT 1732, id FROM sys_permission WHERE code = 'process.yield.approve'; INSERT INTO sys_user_role (user_id,role_id) VALUES (1732,1731),(1733,1732),(1731,1732); INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1731,1),(1732,1),(1733,1); INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1732,'APR-WHSH01-20261015-000032','PROCESS_YIELD_DEVIATION',1,'PROCESS_ORDER','1711','{}','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc','出成率 43.8% 越界',1731,NULL);"
expect_block "17×12 无 process.yield.approve 的人批 PROCESS_YIELD_DEVIATION" "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732;" "approval_perm_not_held"
expect_block "17×12 报工人自己批（SoD）" "UPDATE approval_request SET status='APPROVED', first_approver_id=1731, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732;" "ck_apr_sod"
expect_allow "17×12 加工主管批 PROCESS_YIELD_DEVIATION" "UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732;"
expect_allow "17×12 返工审批种子：发起人 1734（权限点 process.yield.approve / process.rework.approve 复用 #9 种子，不自建；PROC_REWORKER，持 process.order.reverse 且也持 process.rework.approve，专测 SoD）；1733 PROC_LEAD 加持 process.rework.approve" "INSERT INTO sys_user (id,username,password_hash) VALUES (1734,'u1734','x'); INSERT INTO sys_role (id,code,name) VALUES (1734,'PROC_REWORKER','加工返工发起'); INSERT INTO sys_permission (id,code,name,module) VALUES (1734,'process.order.reverse','加工冲回/返工发起','process'); INSERT INTO sys_role_perm (role_id,perm_id) SELECT r.rid, p.id FROM (SELECT 1734 AS rid, 'process.order.reverse' AS pc UNION ALL SELECT 1734, 'process.rework.approve' UNION ALL SELECT 1732, 'process.rework.approve') r JOIN sys_permission p ON p.code = r.pc; INSERT INTO sys_user_role (user_id,role_id) VALUES (1734,1734); INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1734,1); INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1735,'APR-WHSH01-20261015-000035','PROCESS_REWORK',1,'PROCESS_ORDER','1711','{}','dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd','产出 1759 返工',1734,NULL);"
expect_block "17×12 返工：无 process.rework.approve 的人（1732 仓库主管）批 PROCESS_REWORK" "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735;" "approval_perm_not_held"
expect_block "17×12 返工 SoD：发起人 1734 自己批（即使持 process.rework.approve）" "UPDATE approval_request SET status='APPROVED', first_approver_id=1734, first_approver_role='PROC_REWORKER', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735;" "ck_apr_sod"
expect_allow "17×12 返工：加工主管 1733 批 PROCESS_REWORK" "UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735;"
fi
echo "=== 2h3. 18 函数固定 search_path（目录断言 + 同名表劫持）==="
R=$(psql -t -A -c "SELECT string_agg(p.proname || '=' || COALESCE(array_to_string(p.proconfig, ','), 'NONE'), ' ' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname IN ('trg_slp_guard','trg_lt_guard','trg_lt_type','trg_lsc_guard','trg_lth_guard','trg_ld_guard','live_death_makeup')")
EXP18="live_death_makeup=search_path=pg_catalog, public, pg_temp trg_ld_guard=search_path=pg_catalog, public, pg_temp trg_lsc_guard=search_path=pg_catalog, public, pg_temp trg_lt_guard=search_path=pg_catalog, public, pg_temp trg_lt_type=search_path=pg_catalog, public, pg_temp trg_lth_guard=search_path=pg_catalog, public, pg_temp trg_slp_guard=search_path=pg_catalog, public, pg_temp"
[ "$R" = "$EXP18" ] && ok "18 的 7 个 PG 函数 proconfig 均为 search_path=pg_catalog, public, pg_temp" || bad "18 函数 proconfig 不符：$R"
# 劫持：调用方 search_path 前置 rogue schema，放一张同名 live_death，id 999999 标 HIJACK。
# 固定后函数只看 public，public 里没有 999999 → live_death_not_found；被劫持则返回 EXISTING:HIJACK。整段 ROLLBACK。
OUT=$(psql_capture "BEGIN; CREATE SCHEMA t18_rogue; CREATE TABLE t18_rogue.live_death (id BIGINT, deduct_status TEXT); INSERT INTO t18_rogue.live_death VALUES (999999, 'HIJACK'); SET LOCAL search_path = t18_rogue, public; SELECT live_death_makeup(999999, 999999); ROLLBACK;")
case "$OUT" in
  *"EXISTING:HIJACK"*) bad "live_death_makeup 被同名表劫持：$OUT";;
  *"live_death_not_found: 999999"*) ok "live_death_makeup 不受调用方 search_path 里的同名 live_death 劫持（报 live_death_not_found）";;
  *) bad "劫持检查结果异常：$OUT";;
esac
[ "$(psql -t -A -c "SELECT count(*) FROM pg_namespace WHERE nspname='t18_rogue'")" = "0" ] && ok "劫持检查回滚后无残留 schema" || bad "t18_rogue 残留"

seed "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days,return_as_fresh) VALUES (97001,'SKU-SR-FRZ','冷冻虾仁','KG','FROZEN',180,30,90,false),(97002,'SKU-SR-AMB','常温大米','KG','AMBIENT',365,30,NULL,false),(97003,'SKU-SR-AMBF','常温香蕉（按生鲜退）','KG','AMBIENT',7,1,NULL,true),(97004,'SKU-SR-LIVE','活鲜（未定义映射）','KG','LIVE',3,1,NULL,false);"
echo "=== 2s. 第 10/9 篇 退供应商（Alex 定案）：原因白名单、处置必填、食安只退或报废、提货时限、超期转 09 报损 + hold(SCRAP_PENDING)；每条规则 正向 / 拒绝 / 变异 ==="
# 变异检查：同一事务里删掉约束（或触发器）再执行被拒语句，必须变成通过，然后 ROLLBACK —— 证明拒绝确实来自该约束
srtn_mut() {  # $1 约束/触发器描述  $2 删除语句  $3 原本被拒的语句
  expect_allow "变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; $2 $3 ROLLBACK;"
}
expect_allow "退供 R1 正向：质量问题退供（生鲜，T+24h）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97101,'SRN-97101',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31);"
expect_allow "退供 R1 正向：错送 + 换货" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97102,'SRN-97102',1,501,14,97002,1,5000,'WRONG_DELIVERY',NULL,false,'EXCHANGE','STANDARD','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 R1 拒绝：原因不在白名单（OVERSTOCK）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'OVERSTOCK',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_reason"
srtn_mut "ck_srtn_reason" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_reason;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'OVERSTOCK',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 R1 正向：滞销 + 合同约定（contract_ref）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97103,'SRN-97103',1,501,14,97002,1,5000,'SLOW_MOVING','CT-2026-018 §7.2',false,'RETURN','STANDARD','2026-10-15 08:00:00','2026-10-30 08:00:00',31);"
expect_block "退供 R1 拒绝：滞销无合同约定" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,97002,1,5000,'SLOW_MOVING',NULL,false,'DISCOUNT','STANDARD','2026-10-15 08:00:00',NULL,31);" "ck_srtn_slow"
srtn_mut "ck_srtn_slow" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_slow;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,97002,1,5000,'SLOW_MOVING',NULL,false,'DISCOUNT','STANDARD','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 R2 正向：处置折价（非食安）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97104,'SRN-97104',1,501,14,1,1,5000,'QUALITY',NULL,false,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 R2 拒绝：处置方式不在四选一" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'DONATE','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_disp"
srtn_mut "ck_srtn_disp" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_disp;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'DONATE','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 R2 拒绝：处置方式为空" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,NULL,'FRESH','2026-10-15 08:00:00',NULL,31);" "null value in column \"disposition\""
srtn_mut "disposition NOT NULL" "ALTER TABLE supplier_return ALTER COLUMN disposition DROP NOT NULL;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,NULL,'FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 R2 正向：食安 + 报废" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97105,'SRN-97105',1,501,14,1,1,5000,'QUALITY',NULL,true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 R2 拒绝：食安问题折价" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,true,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_fsafe"
srtn_mut "ck_srtn_fsafe" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_fsafe;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,true,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 R2 正向：召回（食安）退供，冷冻 T+7d" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97106,'SRN-97106',1,501,14,97001,1,5000,'RECALL',NULL,true,'RETURN','FROZEN','2026-10-15 08:00:00','2026-10-22 08:00:00',31);"
expect_block "退供 R2 拒绝：召回未标食安" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'RECALL',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_recall_fs"
srtn_mut "ck_srtn_recall_fs" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_recall_fs;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'RECALL',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 R3 正向：常温 T+15d" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97107,'SRN-97107',1,501,14,97002,1,5000,'QUALITY',NULL,false,'RETURN','STANDARD','2026-10-15 08:00:00','2026-10-30 08:00:00',31);"
expect_block "退供 R3 拒绝：生鲜截止写成 T+48h" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-17 08:00:00',31);" "ck_srtn_deadline"
srtn_mut "ck_srtn_deadline（时限）" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_deadline;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-17 08:00:00',31);"
expect_block "退供 R3 拒绝：退供缺截止时间" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97109,'SRN-97109',1,501,14,97001,1,5000,'QUALITY',NULL,false,'RETURN','FROZEN','2026-10-15 08:00:00',NULL,31);" "ck_srtn_deadline"
expect_allow "退供 R3 正向：截止前提货" "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97107; UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-30 07:59:59' WHERE id=97107;"
expect_block "退供 R3 拒绝：超过截止再提货（必须走超期报损）" "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97106; UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-22 08:00:01' WHERE id=97106;" "ck_srtn_picked"
srtn_mut "ck_srtn_picked" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_picked;" "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97106; UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-22 08:00:01' WHERE id=97106;"
expect_allow "退供 R4 种子：97101 待提货" "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97101;"
expect_allow "退供 R4 种子：09 报损单（SUPPLIER_RETURN / PICKUP_OVERDUE）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97101,'SCR-97101',1,'SUPPLIER_RETURN',97101,'PICKUP_OVERDUE','2026-10-16',0);"
expect_block "09 拒绝：PICKUP_OVERDUE 用在非退供来源" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97109,'SCR-97109',1,'MANUAL',0,'PICKUP_OVERDUE','2026-10-16',7);" "ck_scr_reason_src"
srtn_mut "ck_scr_reason_src（PICKUP_OVERDUE 绑定）" "ALTER TABLE scrap_order DROP CONSTRAINT ck_scr_reason_src;" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97109,'SCR-97109',1,'MANUAL',0,'PICKUP_OVERDUE','2026-10-16',7);"
expect_block "退供 R4 拒绝：有报损单但没有 hold(SCRAP_PENDING) 就转超期" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101;" "srtn_overdue_no_scrap_hold"
srtn_mut "trg_srtn_overdue" "DROP TRIGGER trg_srtn_overdue ON supplier_return;" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101;"
expect_block "退供 R4 拒绝：建单直接写 OVERDUE_SCRAP" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by,status,overdue_at,scrap_order_id) VALUES (97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31,'OVERDUE_SCRAP','2026-10-16 09:00:00',97101);" "srtn_overdue_no_scrap_hold"
expect_allow "退供 R4 种子：02 原语 hold(SCRAP_PENDING)，op_key=SRTO:97101" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97101,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0);"
expect_block "退供 R4 拒绝：未过截止（overdue_at = 截止）就转超期" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:00', scrap_order_id=97101 WHERE id=97101;" "ck_srtn_overdue"
srtn_mut "ck_srtn_overdue" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_overdue;" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:00', scrap_order_id=97101 WHERE id=97101;"
expect_allow "退供 R4 正向：超期 + 报损单 + SCRAP_PENDING 冻结 → OVERDUE_SCRAP" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101;"
expect_block "退供 R4 拒绝：报损单号不存在（外键兜底：即使绕过 trg_srtn_overdue）" "BEGIN; DROP TRIGGER trg_srtn_overdue ON supplier_return; DROP TRIGGER trg_srtn_forward ON supplier_return; UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=987654 WHERE id=97103; ROLLBACK;" "fk_srtn_scrap"
echo "=== 2s2. 退供 食安/滞销（Doro 定）、超期绕过 hold(SCRAP_PENDING)、op_key 与重放、唯一与并发（小玛丽攻击面预测）==="
expect_allow "退供 食安 正向：合同滞销 + 折价" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97110,'SRN-97110',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 食安 正向：合同滞销 + 换货" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97111,'SRN-97111',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 食安 正向：合同滞销 + 报废" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97112,'SRN-97112',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 食安 拒绝：合同滞销标成食安" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_slow_fs"
srtn_mut "ck_srtn_slow_fs" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_slow_fs;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 食安 正向：召回 + 报废" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97113,'SRN-97113',1,501,14,1,1,5000,'RECALL',NULL,true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 食安 拒绝：召回 + 折价" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_fsafe"
expect_block "退供 食安 拒绝：召回 + 换货" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_fsafe"
srtn_mut "ck_srtn_fsafe（召回换货）" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_fsafe;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_block "退供 食安 拒绝：质量食安 + 换货" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'QUALITY',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31);" "ck_srtn_fsafe"
expect_block "退供 食安 拒绝：建单后把食安单改成折价（UPDATE 绕过）" "UPDATE supplier_return SET disposition='DISCOUNT' WHERE id=97105;" "ck_srtn_fsafe"
expect_block "退供 食安 拒绝：建单后把召回的食安标记去掉" "UPDATE supplier_return SET food_safety=false WHERE id=97113;" "ck_srtn_recall_fs"
expect_block "退供 食安 拒绝：召回改成合同滞销（仍是食安）" "UPDATE supplier_return SET reason_code='SLOW_MOVING', contract_ref='CT-1' WHERE id=97113;" "ck_srtn_slow_fs"
expect_allow "退供 绕过 种子：97130 待提货 + 报损单 97130" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97130,'SRN-97130',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31); UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97130; INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97130,'SCR-97130',1,'SUPPLIER_RETURN',97130,'PICKUP_OVERDUE','2026-10-16',0); COMMIT;"
expect_block "退供 绕过 拒绝：op_key 小写 srto:" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'srto:97130',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：op_key 前导零 SRTO:097130" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:097130',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：op_key 尾随空格" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130 ',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：op_key 指向别的退供单 SRTO:97101x" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:971300',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：冻结量 ≠ 退供量" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',4999,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：冻结在别的库存行" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,13,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：冻结已释放" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',5000,5000,'RELEASED',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：冻结挂在别的报损单" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97130',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130; ROLLBACK;" "srtn_overdue_no_scrap_hold"
srtn_mut "trg_srtn_overdue（op_key 小写）" "DROP TRIGGER trg_srtn_overdue ON supplier_return;" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'srto:97130',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130;"
expect_allow "退供 绕过 种子：97132 报损单已取消（有冻结）" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97132,'SRN-97132',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31); UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97132; INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97132,'SCR-97132',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0); UPDATE scrap_order SET status='CANCELLED' WHERE id=97132; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97132,14,'SCRAP_PENDING','SCRAP','SCRAP',97132,'SRTO:97132',5000,0,'HELD',0); COMMIT;"
expect_block "退供 绕过 拒绝：报损单已取消" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97132 WHERE id=97132;" "srtn_overdue_no_scrap_hold"
expect_allow "退供 绕过 种子：97133 OPEN（未进待提货）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97133,'SRN-97133',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31);"
expect_block "退供 0 行 拒绝：给未进待提货的退供单开报损单" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97133,'SCR-97133',1,'SUPPLIER_RETURN',97133,'PICKUP_OVERDUE','2026-10-16',0);" "srtn_scrap_not_awaiting"
srtn_mut "trg_scr_srtn（INSERT 来源须待提货）" "DROP TRIGGER trg_scr_srtn ON scrap_order;" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97133,'SCR-97133',1,'SUPPLIER_RETURN',97133,'PICKUP_OVERDUE','2026-10-16',0);"
expect_block "退供 绕过 拒绝：OPEN 直接跳 OVERDUE_SCRAP（状态机先拦）" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97133;" "srtn_state_forward_only"
expect_block "退供 绕过 拒绝：OPEN 直接跳 OVERDUE_SCRAP（去掉状态机后仍由超期守卫拦）" "BEGIN; DROP TRIGGER trg_srtn_forward ON supplier_return; UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97133; ROLLBACK;" "srtn_overdue_no_scrap_hold"
expect_block "退供 绕过 拒绝：转超期后换挂报损单" "UPDATE supplier_return SET scrap_order_id=97130 WHERE id=97101;" "srtn_overdue_immutable"
expect_block "退供 绕过 拒绝：转超期后退回待提货（状态机先拦）" "UPDATE supplier_return SET status='AWAITING_PICKUP', overdue_at=NULL, scrap_order_id=NULL WHERE id=97101;" "srtn_state_forward_only"
expect_block "退供 绕过 拒绝：转超期后退回待提货（去掉状态机后仍由超期守卫拦）" "BEGIN; DROP TRIGGER trg_srtn_forward ON supplier_return; UPDATE supplier_return SET status='AWAITING_PICKUP', overdue_at=NULL, scrap_order_id=NULL WHERE id=97101; ROLLBACK;" "srtn_overdue_immutable"
expect_block "退供 绕过 拒绝：转超期后改数量" "UPDATE supplier_return SET qty_milli=1 WHERE id=97101;" "srtn_overdue_immutable"
srtn_mut "trg_srtn_overdue（转超期后换挂报损单）" "DROP TRIGGER trg_srtn_overdue ON supplier_return;" "UPDATE supplier_return SET scrap_order_id=97130 WHERE id=97101;"
expect_block "退供 重放 拒绝：同一退供单再 hold(SCRAP_PENDING)（op_key SRTO:97101 已用）" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97139,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0);" "uq_hold_op"
srtn_mut "uq_hold_op（02，重放去重）" "ALTER TABLE stock_hold DROP CONSTRAINT uq_hold_op;" "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97139,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0);"
R=$(psql -t -A -c "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97101 WHERE id=97101 AND status='AWAITING_PICKUP'"); [ "$R" = "UPDATE 0" ] && ok "退供 重放 转超期：条件更新 WHERE status='AWAITING_PICKUP' 影响 0 行（$R）" || bad "退供 重放 转超期：条件更新 WHERE status='AWAITING_PICKUP' 影响 0 行：$R"
expect_allow "退供 重放 正向：同值重放转超期（终态不变）是 no-op" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101;"
expect_block "退供 唯一 拒绝：已取消旧报损单后再给同一退供单开报损单（uq_scr_source 放过，uq_scr_srtn 拦）" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97134,'SCR-97134',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0);" "uq_scr_srtn"
srtn_mut "uq_scr_srtn" "DROP INDEX uq_scr_srtn;" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97134,'SCR-97134',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0);"
expect_block "退供 唯一 拒绝：两张退供单挂同一报损单（绕过触发器后由 uq_srtn_scrap 兜底）" "BEGIN; DROP TRIGGER trg_srtn_overdue ON supplier_return; DROP TRIGGER trg_srtn_forward ON supplier_return; UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=97101 WHERE id=97103; ROLLBACK;" "uq_srtn_scrap"
srtn_mut "uq_srtn_scrap" "DROP TRIGGER trg_srtn_overdue ON supplier_return; DROP TRIGGER trg_srtn_forward ON supplier_return; DROP INDEX uq_srtn_scrap;" "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=97101 WHERE id=97103;"
# 并发：两个会话同时给退供单 97135 开报损单（各自事务，A 持有 1.5s 再提交）。只能成一张，后到者撞唯一索引
seed "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97135,'SRN-97135',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00','AWAITING_PICKUP',31);"
_CA=$(mktemp); _CB=$(mktemp)
( psql_capture "BEGIN; INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97140,'SCR-97140',1,'SUPPLIER_RETURN',97135,'PICKUP_OVERDUE','2026-10-16',0); SELECT pg_sleep(1.5); COMMIT;" > "$_CA" ) &
( sleep 0.3; psql_capture "BEGIN; INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97141,'SCR-97141',1,'SUPPLIER_RETURN',97135,'PICKUP_OVERDUE','2026-10-16',0); COMMIT;" > "$_CB" ) &
wait
_N=$(psql -t -A -c "SELECT count(*) FROM scrap_order WHERE source_type='SUPPLIER_RETURN' AND source_id=97135")
if [ "$_N" = "1" ] && ! grep -q ERROR "$_CA" && grep -Eq 'ERROR.*"(uq_scr_srtn|uq_scr_source)"' "$_CB"; then ok "退供 并发转超期：两会话同时开报损单，只成 1 张，后到者撞唯一索引（$(grep -o '"uq_scr_[a-z]*"' "$_CB" | head -1)）"
else bad "退供 并发转超期：报损单 $_N 张；A=$(head -c 200 "$_CA") B=$(head -c 200 "$_CB")"; fi
rm -f "$_CA" "$_CB"
echo "=== 2s-sp. trg_srtn_overdue 固定 search_path：目录断言 + 同名表劫持 + 变异检查（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;
UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97107 AND false;
INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97120,'SRN-97120',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '25 hours',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '1 hour','AWAITING_PICKUP',31);
INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97120,'SCR-97120',1,'SUPPLIER_RETURN',97120,'PICKUP_OVERDUE','2026-10-16',0);
CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.stock_hold (id BIGINT, stock_id BIGINT, hold_type TEXT, source_type TEXT, source_id BIGINT, op_key TEXT, status TEXT, hold_qty_milli BIGINT);
INSERT INTO hj_evil.stock_hold VALUES (1,14,'SCRAP_PENDING','SCRAP',97120,'SRTO:97120','HELD',5000);
SET LOCAL search_path = public;
DO $hj$ BEGIN UPDATE public.supplier_return SET status='OVERDUE_SCRAP', overdue_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'), scrap_order_id=97120 WHERE id=97120; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN UPDATE public.supplier_return SET status='OVERDUE_SCRAP', overdue_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'), scrap_order_id=97120 WHERE id=97120; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_overdue')), true);
ALTER FUNCTION public.trg_srtn_overdue() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_overdue')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN UPDATE public.supplier_return SET status='OVERDUE_SCRAP', overdue_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'), scrap_order_id=97120 WHERE id=97120; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/1" ] && ok "退供 trg_srtn_overdue proconfig 含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "退供 search_path 目录断言：缺失/总数 = $HC0（期望 0/1）"
[ "$HB" = "srtn_overdue_no_scrap_hold" ] && [ "$HF" = "$HB" ] && ok "退供劫持：wms_app 在 hj_evil 伪造同名 stock_hold（含匹配的 SCRAP_PENDING）并置于 search_path 首位，trg_srtn_overdue() 仍读 public，照样拒（$HF）" || bad "退供劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/1" ] && [ "$HM" = "HJ_OK" ] && ok "退供变异检查：RESET trg_srtn_overdue() 的 search_path 后，目录断言变红（$HC1）且伪造冻结生效（$HM）" || bad "退供变异检查没变红：目录=$HC1 劫持后=$HM"

echo "=== 2s3. 退供 温区映射（Doro 定）：FROZEN→FROZEN、CHILLED→FRESH、AMBIENT→STANDARD、AMBIENT+return_as_fresh→FRESH ==="
expect_block "退供 温区 拒绝：冷藏 SKU 标 return_as_fresh" "UPDATE sku SET return_as_fresh=true WHERE id=1;" "ck_sku_rtn_fresh"
srtn_mut "ck_sku_rtn_fresh" "ALTER TABLE sku DROP CONSTRAINT ck_sku_rtn_fresh;" "UPDATE sku SET return_as_fresh=true WHERE id=1;"
expect_allow "退供 温区 正向：冷藏 → FRESH" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97150,'SRN-97150',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 温区 正向：冷冻 → FROZEN" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97151,'SRN-97151',1,501,14,97001,1,5000,'QUALITY',NULL,false,'SCRAP','FROZEN','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 温区 正向：常温 → STANDARD" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97152,'SRN-97152',1,501,14,97002,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 温区 正向：常温 + return_as_fresh → FRESH" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97153,'SRN-97153',1,501,14,97003,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);"
expect_allow "退供 温区 正向：常温 + return_as_fresh 退供，截止 T+24h" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97154,'SRN-97154',1,501,14,97003,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31);"
expect_block "退供 温区 拒绝：冷藏标 STANDARD" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：冷冻标 FRESH" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97001,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：常温标 FRESH（无覆盖标记）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97002,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：常温 + return_as_fresh 标 STANDARD（T+15d）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97003,1,5000,'QUALITY',NULL,false,'RETURN','STANDARD','2026-10-15 08:00:00','2026-10-30 08:00:00',31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：未定义映射的温区 LIVE" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97004,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：SKU 不存在" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,999999,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31);" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：建单后 UPDATE 改 temp_class" "UPDATE supplier_return SET temp_class='FROZEN' WHERE id=97150;" "srtn_temp_class_mismatch"
expect_block "退供 温区 拒绝：建单后 UPDATE 换成冷藏 SKU（类别仍 STANDARD）" "UPDATE supplier_return SET sku_id=1 WHERE id=97152;" "srtn_temp_class_mismatch"
srtn_mut "trg_srtn_temp" "DROP TRIGGER trg_srtn_temp ON supplier_return;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31);"
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;
CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE TABLE hj_evil.sku (id BIGINT, temperature_required TEXT, return_as_fresh BOOLEAN);
INSERT INTO hj_evil.sku VALUES (1,'AMBIENT',false);
SET LOCAL search_path = public;
DO $hj$ BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97160,'SRN-97160',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','STANDARD',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'),31); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97160,'SRN-97160',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','STANDARD',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'),31); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_temp','trg_srtn_overdue')), true);
ALTER FUNCTION public.trg_srtn_temp() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_temp','trg_srtn_overdue')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, public;
DO $hj$ BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97160,'SRN-97160',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','STANDARD',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'),31); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HC0 HC1 <<< "$R"
[ "$HC0" = "0/2" ] && ok "退供 trg_srtn_temp / trg_srtn_overdue proconfig 都含 search_path=pg_catalog, public, pg_temp（缺失/总数 = $HC0）" || bad "退供温区 search_path 目录断言：$HC0（期望 0/2）"
[ "$HB" = "srtn_temp_class_mismatch" ] && [ "$HF" = "$HB" ] && ok "退供温区劫持：hj_evil 伪造同名 sku（把冷藏 SKU 1 改成常温）置于 search_path 首位，trg_srtn_temp() 仍读 public，照样拒（$HF）" || bad "退供温区劫持后行为改变：无劫持=$HB / 劫持=$HF"
[ "$HC1" = "1/2" ] && [ "$HM" = "HJ_OK" ] && ok "退供温区变异检查：RESET trg_srtn_temp() 的 search_path 后，目录断言变红（$HC1）且伪造 sku 生效（$HM）" || bad "退供温区变异检查没变红：目录=$HC1 劫持后=$HM"
echo "=== 2s4. 退供 时间与 0 行（小玛丽 pr03 B1/B2/B3/N4/N5 同类，本篇预先修）：格式、时钟窗口、只写一次、列级授权、边界、孤儿报损单 ==="
expect_block "退供 时间 拒绝：ready_at 带小数秒（PG 不再四舍五入，直接拒）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97190,'SRN-97190',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00.5',NULL,31);" "ck_srtn_ts"
srtn_mut "ck_srtn_ts（整秒）" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_ts;" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97190,'SRN-97190',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00.5',NULL,31);"
expect_block "退供 时间 拒绝：ready_at = 'zzzz'（PG 类型解析即拒）" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97190,'SRN-97190',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','zzzz',NULL,31);" "invalid input syntax for type timestamp"
R=$(psql -t -A -c "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97190,'SRN-97190',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00+08:00',NULL,31); SELECT ready_at::text FROM supplier_return WHERE id=97190; ROLLBACK;" | grep -v -e BEGIN -e INSERT -e ROLLBACK)
[ "$R" = "2026-10-15 08:00:00" ] && ok "退供 时间 PG 行为固化：TIMESTAMP 丢弃偏移（'+08:00' 存成 08:00:00，见 10_returns.sql 表头约定；非属主写入另受时钟窗口）" || bad "退供 时间 PG 偏移行为变了：$R"
srtn_forced() {  # $1 描述  $2 SQL（含 SET ROLE）  $3 断言表达式（布尔）  $4 期望 t/f
  local r; r=$(psql -q -t -A -c "BEGIN; $2; RESET ROLE; SELECT ($3)::text; COMMIT;" 2>&1 | grep -E '^(true|false)$|ERROR' | head -1)
  [ "$r" = "$4" ] && ok "$1（$r）" || bad "$1：得到 $r，期望 $4"
}
srtn_forced_rb() {  # 同上但 ROLLBACK（变异用）
  local r; r=$(psql -q -t -A -c "BEGIN; $2; RESET ROLE; SELECT ($3)::text; ROLLBACK;" 2>&1 | grep -E '^(true|false)$|ERROR' | head -1)
  [ "$r" = "$4" ] && ok "$1（$r）" || bad "$1：得到 $r，期望 $4"
}
srtn_forced "退供 时钟：wms_app 倒签 ready_at（now−1d）+ 自算截止，PG 触发器强制覆盖成库时钟，截止按 now+24h 重算" "SET ROLE wms_app; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97170,'SRN-97170',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '1 day',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'),31)" "(SELECT abs(extract(epoch FROM (ready_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 AND pickup_deadline_at = ready_at + INTERVAL '24 hours' FROM supplier_return WHERE id=97170)" "true"
srtn_forced_rb "变异：去掉 trg_srtn_zclock 后，倒签 ready_at 原样落库（断言变红）" "DROP TRIGGER trg_srtn_zclock ON supplier_return; SET ROLE wms_app; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97196,'SRN-97196',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '1 day',NULL,31)" "(SELECT abs(extract(epoch FROM (ready_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97196)" "false"
srtn_forced "退供 时钟：wms_app 预签 ready_at（now+1d），强制覆盖成库时钟" "SET ROLE wms_app; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97197,'SRN-97197',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') + INTERVAL '1 day',NULL,31)" "(SELECT abs(extract(epoch FROM (ready_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97197)" "true"
expect_block "退供 时钟 拒绝：wms_app 越过 OPEN 直接以 AWAITING_PICKUP 建单" "SET ROLE wms_app; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97191,'SRN-97191',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'),date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') + INTERVAL '24 hours','AWAITING_PICKUP',31);" "srtn_insert_open_only"
expect_allow "退供 时钟：表属主（迁移/种子）不受时钟窗口约束（同 11 outbox 属主口径）" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97192,'SRN-97192',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '30 days',NULL,31); ROLLBACK;"
expect_allow "退供 时钟 种子：97170 进待提货（wms_app 列级 UPDATE status）" "SET ROLE wms_app; UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97170;"
srtn_forced "退供 时钟：wms_app 倒签 picked_up_at（now−1h），强制覆盖成库时钟" "SET ROLE wms_app; UPDATE supplier_return SET status='PICKED_UP', picked_up_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '1 hour' WHERE id=97170" "(SELECT abs(extract(epoch FROM (picked_up_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97170)" "true"
expect_allow "退供 时钟 种子：97171 已过截止的待提货单（属主写入）+ 报损单 + 冻结" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97171,'SRN-97171',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '25 hours',date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - INTERVAL '1 hour','AWAITING_PICKUP',31); INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97171,'SCR-97171',1,'SUPPLIER_RETURN',97171,'PICKUP_OVERDUE','2026-10-16',0); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97171,14,'SCRAP_PENDING','SCRAP','SCRAP',97171,'SRTO:97171',5000,0,'HELD',0); COMMIT;"
srtn_forced "退供 时钟：wms_app 预签 overdue_at（now+1d），强制覆盖成库时钟" "SET ROLE wms_app; UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') + INTERVAL '1 day', scrap_order_id=97171 WHERE id=97171" "(SELECT abs(extract(epoch FROM (overdue_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97171)" "true"
expect_block "退供 授权 拒绝：wms_app 直接 UPDATE ready_at（无列级权限）" "SET ROLE wms_app; UPDATE supplier_return SET ready_at = ready_at - INTERVAL '1 day' WHERE id=97170;" "permission denied for table supplier_return"
expect_block "退供 授权 拒绝：wms_app 事后把食安标记改成 false（再改折价即绕过 R2）" "SET ROLE wms_app; UPDATE supplier_return SET food_safety=false WHERE id=97105;" "permission denied for table supplier_return"
srtn_mut "列级授权（GRANT UPDATE (food_safety)）" "GRANT UPDATE (food_safety) ON supplier_return TO wms_app;" "SET ROLE wms_app; UPDATE supplier_return SET food_safety=false WHERE id=97105; RESET ROLE;"
expect_block "退供 时间 拒绝：属主也不能事后改 ready_at / 截止（连带推迟期限）" "UPDATE supplier_return SET ready_at = ready_at - INTERVAL '1 hour', pickup_deadline_at = pickup_deadline_at - INTERVAL '1 hour' WHERE id=97170;" "srtn_time_immutable"
srtn_mut "trg_srtn_zclock（时间列只写一次）" "DROP TRIGGER trg_srtn_zclock ON supplier_return;" "UPDATE supplier_return SET ready_at = ready_at - INTERVAL '1 hour', pickup_deadline_at = pickup_deadline_at - INTERVAL '1 hour' WHERE id=97170;"
expect_allow "退供 边界 种子：97180 待提货（截止 2026-10-16 08:00:00）" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97180,'SRN-97180',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00','AWAITING_PICKUP',31); COMMIT;"
expect_block "变异：ck_srtn_picked 的 <= 改成 < 后，恰在截止时刻提货被拒（边界用例变红）" "BEGIN; ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_picked; ALTER TABLE supplier_return ADD CONSTRAINT ck_srtn_picked CHECK ((status = 'PICKED_UP') = (picked_up_at IS NOT NULL) AND (picked_up_at IS NULL OR picked_up_at < pickup_deadline_at)); UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-16 08:00:00' WHERE id=97180; ROLLBACK;" "ck_srtn_picked"
expect_allow "退供 边界 正向：恰在截止时刻（picked_up_at = 截止）提货" "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-16 08:00:00' WHERE id=97180;"
expect_allow "变异：ck_srtn_overdue 的 > 改成 >= 后，恰在截止时刻转超期通过（现有边界拒绝用例变红）" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97181,'SRN-97181',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00','AWAITING_PICKUP',31); INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97181,'SCR-97181',1,'SUPPLIER_RETURN',97181,'PICKUP_OVERDUE','2026-10-16',0); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97181,14,'SCRAP_PENDING','SCRAP','SCRAP',97181,'SRTO:97181',5000,0,'HELD',0); ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_overdue; ALTER TABLE supplier_return ADD CONSTRAINT ck_srtn_overdue CHECK ((status = 'OVERDUE_SCRAP') = (overdue_at IS NOT NULL) AND (status = 'OVERDUE_SCRAP') = (scrap_order_id IS NOT NULL) AND (overdue_at IS NULL OR overdue_at >= pickup_deadline_at)); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:00', scrap_order_id=97181 WHERE id=97181; ROLLBACK;"
expect_block "退供 0 行 拒绝：给已提货的退供单开报损单" "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97107,'SCR-97107',1,'SUPPLIER_RETURN',97107,'PICKUP_OVERDUE','2026-10-16',0);" "srtn_scrap_not_awaiting"
expect_allow "退供 0 行 种子：97183 已过截止待提货" "BEGIN; INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97183,'SRN-97183',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-14 08:00:00','2026-10-15 08:00:00','AWAITING_PICKUP',31); COMMIT;"
R=$(psql -t -A -c "BEGIN; INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97183,'SCR-97183',1,'SUPPLIER_RETURN',97183,'PICKUP_OVERDUE','2026-10-16',0); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97183,14,'SCRAP_PENDING','SCRAP','SCRAP',97183,'SRTO:97183',5000,0,'HELD',0); UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-15 09:00:00', scrap_order_id=97183 WHERE id=97183 AND status='PICKED_UP'; COMMIT;" 2>&1 | tr '\n' ' ')
case "$R" in *"UPDATE 0"*COMMIT*) ok "退供 0 行 复现：服务端漏查 rowcount，转超期条件更新 0 行仍提交（报损单 + 冻结落库，退供单未转）——库层下一步兜底";; *) bad "退供 0 行 复现异常：$R";; esac
expect_block "退供 0 行 拒绝：孤儿报损单（退供单未转超期）不能提交审批 / 过账" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97183;" "srtn_scrap_orphan"
srtn_mut "trg_scr_srtn（孤儿报损单不能前进）" "DROP TRIGGER trg_scr_srtn ON scrap_order;" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97183;"
expect_allow "退供 0 行 正向：孤儿报损单可以取消（释放冻结）" "UPDATE scrap_order SET status='CANCELLED' WHERE id=97183;"
expect_allow "退供 0 行 正向：正常转超期的报损单可以提交审批" "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97101;"
echo "=== 2s4-sp. trg_srtn_zclock / trg_scr_srtn 固定 search_path：目录断言 + 劫持 + 变异（PG）==="
R=$(psql -q -t -A <<'HJSQL' | grep '^HJ#'
BEGIN;
CREATE SCHEMA hj_evil AUTHORIZATION wms_app;
SET LOCAL ROLE wms_app;
CREATE FUNCTION hj_evil.now() RETURNS timestamptz LANGUAGE sql STABLE AS $f$ SELECT '2020-01-01 00:00:00+00'::timestamptz $f$;
CREATE TABLE hj_evil.supplier_return (id BIGINT, status TEXT, scrap_order_id BIGINT);
INSERT INTO hj_evil.supplier_return VALUES (97107,'AWAITING_PICKUP',NULL);
SET LOCAL search_path = public;
DO $hj$ DECLARE v timestamp; BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97195,'SRN-97195',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2020-01-01 00:00:00',31) RETURNING ready_at INTO v; RAISE EXCEPTION '%', CASE WHEN v = '2020-01-01 00:00:00' THEN 'FORGED' ELSE 'NOW' END; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base', SQLERRM, true); END $hj$;
DO $hj$ BEGIN INSERT INTO public.scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97195,'SCR-97195',1,'SUPPLIER_RETURN',97107,'PICKUP_OVERDUE','2026-10-16',0); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.base2', SQLERRM, true); END $hj$;
SET LOCAL search_path = hj_evil, pg_catalog, public;
DO $hj$ DECLARE v timestamp; BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97195,'SRN-97195',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2020-01-01 00:00:00',31) RETURNING ready_at INTO v; RAISE EXCEPTION '%', CASE WHEN v = '2020-01-01 00:00:00' THEN 'FORGED' ELSE 'NOW' END; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed', SQLERRM, true); END $hj$;
DO $hj$ BEGIN INSERT INTO public.scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97195,'SCR-97195',1,'SUPPLIER_RETURN',97107,'PICKUP_OVERDUE','2026-10-16',0); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.fixed2', SQLERRM, true); END $hj$;
RESET ROLE;
SET LOCAL search_path = public;
SELECT set_config('hj.cat0', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_zclock','trg_scr_srtn')), true);
ALTER FUNCTION public.trg_srtn_zclock() RESET search_path;
ALTER FUNCTION public.trg_scr_srtn() RESET search_path;
SELECT set_config('hj.cat1', (SELECT count(*) FILTER (WHERE NOT COALESCE(proconfig,'{}'::text[]) @> ARRAY['search_path=pg_catalog, public, pg_temp']) || '/' || count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('trg_srtn_zclock','trg_scr_srtn')), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = hj_evil, pg_catalog, public;
DO $hj$ DECLARE v timestamp; BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97195,'SRN-97195',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2020-01-01 00:00:00',31) RETURNING ready_at INTO v; RAISE EXCEPTION '%', CASE WHEN v = '2020-01-01 00:00:00' THEN 'FORGED' ELSE 'NOW' END; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut', SQLERRM, true); END $hj$;
DO $hj$ BEGIN INSERT INTO public.scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97195,'SCR-97195',1,'SUPPLIER_RETURN',97107,'PICKUP_OVERDUE','2026-10-16',0); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('hj.mut2', SQLERRM, true); END $hj$;
RESET ROLE;
SELECT 'HJ#' || current_setting('hj.base') || '#' || current_setting('hj.fixed') || '#' || current_setting('hj.mut') || '#' || current_setting('hj.base2') || '#' || current_setting('hj.fixed2') || '#' || current_setting('hj.mut2') || '#' || current_setting('hj.cat0') || '#' || current_setting('hj.cat1');
ROLLBACK;
HJSQL
)
IFS='#' read -r _ HB HF HM HB2 HF2 HM2 HC0 HC1 <<< "$R"
[ "$HC0" = "0/2" ] && ok "退供 trg_srtn_zclock / trg_scr_srtn proconfig 含 search_path=pg_catalog, public, pg_temp（$HC0）" || bad "退供 2s4 search_path 目录断言：$HC0（期望 0/2）"
[ "$HB" = "NOW" ] && [ "$HF" = "NOW" ] && ok "退供 时钟劫持：wms_app 在 hj_evil 伪造 now()（返回 2020-01-01）并放在 pg_catalog 前，ready_at 仍被覆盖成真实库时钟（$HF）" || bad "退供 时钟劫持后行为改变：$HB / $HF"
[ "$HB2" = "srtn_scrap_not_awaiting" ] && [ "$HF2" = "$HB2" ] && ok "退供 孤儿劫持：hj_evil 伪造同名 supplier_return（97107 待提货），trg_scr_srtn() 仍读 public（$HF2）" || bad "退供 孤儿劫持后行为改变：$HB2 / $HF2"
[ "$HC1" = "2/2" ] && [ "$HM" = "FORGED" ] && [ "$HM2" = "HJ_OK" ] && ok "退供 2s4 变异：RESET 两个函数的 search_path 后目录变红（$HC1），伪造时钟与伪造退供单都生效" || bad "退供 2s4 变异没变红：目录=$HC1 时钟=$HM 孤儿=$HM2"
echo "=== 2s5. 退供 终审（小玛丽 srtn-final）：B1 pg_temp 劫持、B2 状态机、N1 created_at ==="
SRI="INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by"
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[]) || '/' || count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_srtn_temp','trg_srtn_zclock','trg_srtn_forward','trg_scr_srtn','trg_srtn_overdue')")
[ "$R" = "5/5" ] && ok "B1 本增量 5 个 PG 函数 proconfig 都是 search_path=pg_catalog, public, pg_temp（pg_temp 显式最后）（$R）" || bad "B1 search_path 目录：$R（期望 5/5）"
R=$(psql -t -A -c "SELECT has_database_privilege('wms_app', current_database(), 'TEMP')")
[ "$R" = "t" ] && ok "B1 前提：wms_app 有库级 TEMP 权限（能建临时表冒充真表）" || bad "B1 前提变了：wms_app TEMP=$R"
# $1 = 变异前置（空 = 修复后；ALTER … pg_catalog, public = 去掉 pg_temp）
pgtemp_attack() {
psql -q -t -A <<PGT | grep '^PT#'
BEGIN;
$1
$SRI,status) VALUES (97401,'SRN-97401',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH',date_trunc('second', now() AT TIME ZONE 'UTC') - INTERVAL '25 hours',date_trunc('second', now() AT TIME ZONE 'UTC') - INTERVAL '1 hour',31,'AWAITING_PICKUP');
INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97401,'SCR-97401',1,'SUPPLIER_RETURN',97401,'PICKUP_OVERDUE','2026-10-16',0);
$SRI) VALUES (97403,'SRN-97403',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31);
SET LOCAL ROLE wms_app;
CREATE TEMP TABLE stock_hold (id BIGINT, stock_id BIGINT, hold_type TEXT, source_type TEXT, source_id BIGINT, op_key TEXT, status TEXT, hold_qty_milli BIGINT, released_qty_milli BIGINT, reason_code TEXT);
INSERT INTO pg_temp.stock_hold VALUES (1,14,'SCRAP_PENDING','SCRAP',97401,'SRTO:97401','HELD',5000,0,'SCRAP');
CREATE TEMP TABLE sku (id BIGINT, temperature_required TEXT, return_as_fresh BOOLEAN);
INSERT INTO pg_temp.sku VALUES (1,'AMBIENT',false);
CREATE TEMP TABLE supplier_return (id BIGINT, status TEXT, scrap_order_id BIGINT);
INSERT INTO pg_temp.supplier_return VALUES (97403,'AWAITING_PICKUP',NULL);
DO \$a\$ BEGIN UPDATE public.supplier_return SET status='OVERDUE_SCRAP', overdue_at=now(), scrap_order_id=97401 WHERE id=97401; RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('pt.a1', SQLERRM, true); END \$a\$;
DO \$a\$ BEGIN INSERT INTO public.supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,food_safety,disposition,temp_class,ready_at,created_by) VALUES (97402,'SRN-97402',1,501,14,1,1,5000,'QUALITY',false,'RETURN','STANDARD','2026-10-15 08:00:00',31); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('pt.a2', SQLERRM, true); END \$a\$;
DO \$a\$ BEGIN INSERT INTO public.scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97403,'SCR-97403',1,'SUPPLIER_RETURN',97403,'PICKUP_OVERDUE','2026-10-16',0); RAISE EXCEPTION 'HJ_OK'; EXCEPTION WHEN OTHERS THEN PERFORM set_config('pt.a3', SQLERRM, true); END \$a\$;
RESET ROLE;
SELECT 'PT#' || current_setting('pt.a1') || '#' || current_setting('pt.a2') || '#' || current_setting('pt.a3') || '#' || (SELECT count(*) FROM public.stock_hold WHERE op_key='SRTO:97401');
ROLLBACK;
PGT
}
IFS='#' read -r _ A1 A2 A3 RH <<< "$(pgtemp_attack "")"
[ "$A1" = "srtn_overdue_no_scrap_hold" ] && [ "$RH" = "0" ] && ok "B1 攻击 1 拒绝：wms_app 用 TEMP stock_hold 伪造 SRTO 冻结，无真实冻结的退供单转超期被拦（$A1）" || bad "B1 攻击 1：$A1 / 真实冻结 $RH"
[ "$A2" = "srtn_temp_class_mismatch" ] && ok "B1 攻击 2 拒绝：TEMP sku 把冷藏 SKU 伪装成常温，冷藏货以 STANDARD（15 天）建单被拦（$A2）" || bad "B1 攻击 2：$A2"
[ "$A3" = "srtn_scrap_not_awaiting" ] && ok "B1 攻击 3 拒绝：TEMP supplier_return 伪装待提货，给 OPEN 退供单开报损单被拦（$A3）" || bad "B1 攻击 3：$A3"
MUT="ALTER FUNCTION public.trg_srtn_overdue() SET search_path = pg_catalog, public; ALTER FUNCTION public.trg_srtn_temp() SET search_path = pg_catalog, public; ALTER FUNCTION public.trg_scr_srtn() SET search_path = pg_catalog, public;"
IFS='#' read -r _ M1 M2 M3 _ <<< "$(pgtemp_attack "$MUT")"
[ "$M1" = "HJ_OK" ] && [ "$M2" = "HJ_OK" ] && [ "$M3" = "HJ_OK" ] && ok "B1 变异：三个函数去掉 pg_temp（回到 pg_catalog, public）后，三种临时表冒充全部得逞（变红）" || bad "B1 变异没变红：$M1 / $M2 / $M3"
R=$(psql -t -A -c "SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_srtn_temp','trg_scr_srtn','trg_srtn_overdue') AND proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[]")
[ "$R" = "3" ] && ok "B1 变异回滚后三个函数仍是 pg_catalog, public, pg_temp" || bad "B1 变异残留：$R"
# B2 状态机
expect_allow "B2 种子：wms_app 建 97410（RETURN）→ 待提货 → 已提货" "BEGIN; SET LOCAL ROLE wms_app; $SRI) VALUES (97410,'SRN-97410',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00',NULL,31); UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97410; UPDATE supplier_return SET status='PICKED_UP', picked_up_at=now() WHERE id=97410; COMMIT;"
expect_block "B2 拒绝：PICKED_UP → AWAITING_PICKUP 且清空 picked_up_at（wms_app）" "SET ROLE wms_app; UPDATE supplier_return SET status='AWAITING_PICKUP', picked_up_at=NULL WHERE id=97410;" "srtn_state_forward_only"
srtn_mut "trg_srtn_forward（PICKED_UP 回退）" "DROP TRIGGER trg_srtn_forward ON supplier_return;" "SET LOCAL ROLE wms_app; UPDATE supplier_return SET status='AWAITING_PICKUP', picked_up_at=NULL WHERE id=97410; RESET ROLE;"
expect_block "B2 拒绝：表属主也不能 PICKED_UP → AWAITING_PICKUP" "UPDATE supplier_return SET status='AWAITING_PICKUP', picked_up_at=NULL WHERE id=97410;" "srtn_state_forward_only"
expect_block "B2 拒绝：PICKED_UP 后改 picked_up_at（状态不变）" "UPDATE supplier_return SET picked_up_at = picked_up_at - INTERVAL '1 second' WHERE id=97410;" "srtn_time_immutable"
srtn_mut "trg_srtn_zclock（picked_up_at 只写一次）" "DROP TRIGGER trg_srtn_zclock ON supplier_return;" "UPDATE supplier_return SET picked_up_at = picked_up_at - INTERVAL '1 second' WHERE id=97410;"
expect_allow "B2 正向：OPEN → CANCELLED（97411，SCRAP）" "BEGIN; SET LOCAL ROLE wms_app; $SRI) VALUES (97411,'SRN-97411',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31); UPDATE supplier_return SET status='CANCELLED' WHERE id=97411; COMMIT;"
expect_block "B2 拒绝：CANCELLED → OPEN（终态复活）" "SET ROLE wms_app; UPDATE supplier_return SET status='OPEN' WHERE id=97411;" "srtn_state_forward_only"
srtn_mut "trg_srtn_forward（CANCELLED 复活）" "DROP TRIGGER trg_srtn_forward ON supplier_return;" "UPDATE supplier_return SET status='OPEN' WHERE id=97411;"
expect_allow "B2 正向：非 RETURN 处置 OPEN → DISPOSED（97412，DISCOUNT）" "BEGIN; SET LOCAL ROLE wms_app; $SRI) VALUES (97412,'SRN-97412',1,501,14,1,1,5000,'QUALITY',false,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31); UPDATE supplier_return SET status='DISPOSED' WHERE id=97412; COMMIT;"
expect_allow "B2 种子：属主直接写入 DISPOSED 的 RETURN 单 97413（历史数据形态）" "$SRI,status) VALUES (97413,'SRN-97413',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31,'DISPOSED');"
expect_block "B2 拒绝：DISPOSED → AWAITING_PICKUP" "SET ROLE wms_app; UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97413;" "srtn_state_forward_only"
srtn_mut "trg_srtn_forward（DISPOSED 复活）" "DROP TRIGGER trg_srtn_forward ON supplier_return;" "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97413;"
expect_allow "B2 种子：97414 RETURN 待建（OPEN）" "$SRI) VALUES (97414,'SRN-97414',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31);"
expect_block "B2 拒绝：RETURN 处置 OPEN → DISPOSED（退供单不能跳过提货直接处置）" "UPDATE supplier_return SET status='DISPOSED' WHERE id=97414;" "srtn_state_forward_only"
srtn_mut "trg_srtn_forward（RETURN 直接 DISPOSED）" "DROP TRIGGER trg_srtn_forward ON supplier_return;" "UPDATE supplier_return SET status='DISPOSED' WHERE id=97414;"
expect_block "B2 拒绝：OPEN → PICKED_UP（跳过待提货）" "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-15 09:00:00' WHERE id=97414;" "srtn_state_forward_only"
srtn_mut "trg_srtn_forward（跳过待提货）" "DROP TRIGGER trg_srtn_forward ON supplier_return;" "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-15 09:00:00' WHERE id=97414;"
srtn_forced "时间约定：会话 SET TIME ZONE 'Asia/Shanghai' 下 wms_app 建单，ready_at / created_at 仍是 UTC 整秒（与 now() AT TIME ZONE 'UTC' 相差 ≤ 5s，与上海本地时间差 8h）" "SET TIME ZONE 'Asia/Shanghai'; SET ROLE wms_app; $SRI) VALUES (97430,'SRN-97430',1,501,14,1,1,5000,'QUALITY',false,'RETURN','FRESH','2026-10-15 08:00:00',NULL,31)" "(SELECT abs(extract(epoch FROM (ready_at - (now() AT TIME ZONE 'UTC')))) <= 5 AND abs(extract(epoch FROM (ready_at - now()::timestamp))) >= 28790 AND created_at = ready_at AND ready_at = date_trunc('second', ready_at) AND pickup_deadline_at = ready_at + INTERVAL '24 hours' FROM supplier_return WHERE id=97430)" "true"
srtn_forced_rb "变异：trg_srtn_zclock 改用裸 now()（去掉 AT TIME ZONE 'UTC'）后，上海会话写出的是本地时间（UTC 断言变红）" "SET TIME ZONE 'Asia/Shanghai'; DO \$m\$ BEGIN EXECUTE replace(pg_get_functiondef('public.trg_srtn_zclock'::regproc), \$q\$now() AT TIME ZONE 'UTC'\$q\$, 'now()'); END \$m\$; SET ROLE wms_app; $SRI) VALUES (97431,'SRN-97431',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)" "(SELECT abs(extract(epoch FROM (ready_at - (now() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97431)" "false"
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE data_type = 'timestamp without time zone') || '/' || count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='supplier_return' AND column_name IN ('ready_at','pickup_deadline_at','picked_up_at','overdue_at','created_at')")
[ "$R" = "5/5" ] && ok "时间约定：supplier_return 五个时间列都是 TIMESTAMP（无时区），不是 timestamptz（$R）" || bad "时间列类型：$R（期望 5/5）"
# N1 created_at
srtn_forced "N1 created_at：wms_app 传 created_at='1999-01-01'，PG 触发器覆盖成库时钟" "SET ROLE wms_app; $SRI,created_at) VALUES (97420,'SRN-97420',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31,'1999-01-01')" "(SELECT abs(extract(epoch FROM (created_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 AND created_at = ready_at FROM supplier_return WHERE id=97420)" "true"
srtn_forced_rb "变异：去掉 trg_srtn_zclock 后，created_at='1999-01-01' 原样落库（断言变红）" "DROP TRIGGER trg_srtn_zclock ON supplier_return; SET ROLE wms_app; $SRI,created_at) VALUES (97421,'SRN-97421',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31,'1999-01-01')" "(SELECT abs(extract(epoch FROM (created_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')))) <= 5 FROM supplier_return WHERE id=97421)" "false"
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE created_at <> date_trunc('second', created_at)) || '/' || count(*) FROM supplier_return")
[ "${R%%/*}" = "0" ] && ok "N1 created_at 默认值（属主写入）也是整秒 UTC（非整秒/总数 = $R）" || bad "N1 created_at 非整秒：$R"
expect_block "N1 拒绝：created_at 带小数秒（属主写入也拒）" "$SRI,created_at) VALUES (97422,'SRN-97422',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31,'2026-10-15 08:00:00.5');" "ck_srtn_ts"
srtn_mut "ck_srtn_ts（created_at 整秒）" "ALTER TABLE supplier_return DROP CONSTRAINT ck_srtn_ts;" "$SRI,created_at) VALUES (97422,'SRN-97422',1,501,14,1,1,5000,'QUALITY',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31,'2026-10-15 08:00:00.5');"
expect_block "N1 拒绝：属主事后改 created_at" "UPDATE supplier_return SET created_at = created_at - INTERVAL '1 day' WHERE id=97420;" "srtn_time_immutable"
srtn_mut "trg_srtn_zclock（created_at 只写一次）" "DROP TRIGGER trg_srtn_zclock ON supplier_return;" "UPDATE supplier_return SET created_at = created_at - INTERVAL '1 day' WHERE id=97420;"
expect_block "N1 拒绝：wms_app 改 created_at（无列级授权）" "SET ROLE wms_app; UPDATE supplier_return SET created_at = now() WHERE id=97420;" "permission denied for table supplier_return"
echo "=== 2z. pg_temp 劫持（#2 第九轮）：search_path 必须显式写 pg_temp 且放最后；目录断言 + 临时表劫持 + 去掉 pg_temp 的变异（PG）==="
# PG 规则：search_path 里没写 pg_temp 时，会话临时 schema 被隐式放在最前面查表。wms_app 默认有库级 TEMP 权限，
# 能建同名临时表盖住 public 的真表。所以 'pg_catalog, public' 不够，必须 'pg_catalog, public, pg_temp'（pg_temp 显式且最后）。
# SQLite 没有对应攻击面：没有 schema 搜索路径，TEMP 表只对本连接可见，触发器体里的表名在建触发器时就绑到 main（不跟会话走），verify_sqlite.py 不加对应用例。
# 目录断言：public 里所有带 search_path 设置的函数（含退供增量自带的 5 个，米雪儿已按本规则写）都必须正好是 pg_catalog, public, pg_temp。
# docs/07 新增 5 个 PL/pgSQL 触发器函数（trg_rt_forward、trg_rtl_forward、trg_rpd_forward、trg_mo_forward、trg_mol_forward）→ 86 → 91。
# 05 增量 +2：trg_wave_parent_cycle / trg_pt_handover_cycle → 91 → 93。
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE c <> 'search_path=pg_catalog, public, pg_temp') || '/' || count(*) FROM (SELECT unnest(p.proconfig) c FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace) s WHERE c LIKE 'search_path=%'")
[ "$R" = "0/94" ] && ok "pg_temp 目录断言：94 个固定 search_path 的函数都显式以 pg_temp 结尾（不合规/总数 = $R）" || bad "pg_temp 目录断言：不合规/总数 = $R（期望 0/94）"
# 通用断言（不限函数个数）：public 下任何函数只要设了 search_path，pg_temp 必须是最后一项
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE c !~ ',\s*pg_temp\s*$') || '/' || count(*) || '#' || COALESCE(string_agg(proname, ',') FILTER (WHERE c !~ ',\s*pg_temp\s*$'), '') FROM (SELECT p.proname, c FROM pg_proc p, unnest(p.proconfig) c WHERE p.pronamespace = 'public'::regnamespace AND c LIKE 'search_path=%') s")
[ "${R%%/*}" = "0" ] && ok "pg_temp 末位断言：public 下设了 search_path 的函数 pg_temp 都在最后（缺/总 = ${R%%#*}）" || bad "pg_temp 末位断言：缺/总 = ${R%%#*}，函数：${R#*#}"
R=$(psql -t -A -c "SELECT has_database_privilege('wms_app', current_database(), 'TEMP')")
[ "$R" = "t" ] && ok "前提：wms_app 有库级 TEMP 权限（攻击面真实存在，下面的劫持用例有意义）" || bad "wms_app TEMP 权限 = $R，劫持用例前提不成立"
# 四个目标：02 trg_mvk_line_kind（读 stock_ledger_line）、09 trg_scrl_draft_only（读 scrap_order）、
# 11 trg_outbox_order_guard（读 outbox_event）、12 trg_apr_insert（读 warehouse）。每个都由 wms_app 建同名临时表并塞伪造行。
# fixed = 现行函数下的结果（必须是真表给出的原拒绝），mut = 把该函数改成 'pg_catalog, public'（去掉 pg_temp）后的结果（必须变）。
R=$(psql -q -t -A <<'PTSQL' | grep '^PT#'
BEGIN;
INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (19960,'t','PT-1','{}',1,3,0);
INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (19960,'SCR-PT-19960',1,'MANUAL',19960,'DAMAGED','2026-10-16',0);
UPDATE scrap_order SET status='CANCELLED' WHERE id=19960;
SET LOCAL ROLE wms_app;
CREATE TEMP TABLE stock_ledger_line (biz_no varchar(64), line_no int, src_kind varchar(8), owner_device_instance_id varchar(64)) ON COMMIT DROP;
INSERT INTO pg_temp.stock_ledger_line VALUES ('PT-HIJACK', 1, 'DOC', NULL);
CREATE TEMP TABLE scrap_order (id BIGINT, status TEXT, record_only BOOLEAN, source_type TEXT) ON COMMIT DROP;
INSERT INTO pg_temp.scrap_order VALUES (19960,'DRAFT',false,'MANUAL');
CREATE TEMP TABLE outbox_event (id BIGINT, biz_key TEXT, status TEXT, node_id BIGINT, seq BIGINT) ON COMMIT DROP;
INSERT INTO pg_temp.outbox_event VALUES (1,'PT-1','PENDING',3,0);
CREATE TEMP TABLE warehouse (id BIGINT, code TEXT) ON COMMIT DROP;
INSERT INTO pg_temp.warehouse VALUES (1,'PTFAKE');
SET LOCAL search_path = public;
CREATE FUNCTION pg_temp.pt_try(q text, k text) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'PT_PASSED'; EXCEPTION WHEN OTHERS THEN PERFORM set_config(k, SQLERRM, true); END; END $f$;
SELECT pg_temp.pt_try($q$INSERT INTO public.stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (99061,'PT:1:D1:1','PT-HIJACK',1,1,1,'DOC',11,99061,0,'2026-10-15 00:00:00')$q$, 'pt.a0');
SELECT pg_temp.pt_try($q$INSERT INTO public.scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (19961,19960,1,14,1,1,5000,0,'POST_OUT')$q$, 'pt.b0');
SELECT pg_temp.pt_try($q$UPDATE public.outbox_event SET status='SENDING' WHERE id=19960$q$, 'pt.c0');
SELECT pg_temp.pt_try($q$INSERT INTO public.approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (19960,'APR-PTFAKE-20261015-019960','PAPER_BACKFILL',1,'PAPER_BACKFILL','19960','{}','0000000000000000000000000000000000000000000000000000000000000000','r',201,NULL)$q$, 'pt.d0');
RESET ROLE;
ALTER FUNCTION public.trg_mvk_line_kind() SET search_path = pg_catalog, public;
ALTER FUNCTION public.trg_scrl_draft_only() SET search_path = pg_catalog, public;
ALTER FUNCTION public.trg_outbox_order_guard() SET search_path = pg_catalog, public;
ALTER FUNCTION public.trg_apr_insert() SET search_path = pg_catalog, public;
SELECT set_config('pt.cat1', (SELECT count(*) FILTER (WHERE c <> 'search_path=pg_catalog, public, pg_temp') || '/' || count(*) FROM (SELECT unnest(p.proconfig) c FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace) s WHERE c LIKE 'search_path=%'), true);
SET LOCAL ROLE wms_app;
SET LOCAL search_path = public;
SELECT pg_temp.pt_try($q$INSERT INTO public.stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (99061,'PT:1:D1:1','PT-HIJACK',1,1,1,'DOC',11,99061,0,'2026-10-15 00:00:00')$q$, 'pt.a1');
SELECT pg_temp.pt_try($q$INSERT INTO public.scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (19961,19960,1,14,1,1,5000,0,'POST_OUT')$q$, 'pt.b1');
SELECT pg_temp.pt_try($q$UPDATE public.outbox_event SET status='SENDING' WHERE id=19960$q$, 'pt.c1');
SELECT pg_temp.pt_try($q$INSERT INTO public.approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (19960,'APR-PTFAKE-20261015-019960','PAPER_BACKFILL',1,'PAPER_BACKFILL','19960','{}','0000000000000000000000000000000000000000000000000000000000000000','r',201,NULL)$q$, 'pt.d1');
RESET ROLE;
SELECT 'PT#' || current_setting('pt.a0') || '#' || current_setting('pt.a1') || '#' || current_setting('pt.b0') || '#' || current_setting('pt.b1') || '#' || current_setting('pt.c0') || '#' || current_setting('pt.c1') || '#' || current_setting('pt.d0') || '#' || current_setting('pt.d1') || '#' || current_setting('pt.cat1');
ROLLBACK;
PTSQL
)
IFS='#' read -r _ A0 A1 B0 B1 C0 C1 D0 D1 PC1 <<< "$R"
echo "  → fixed/mut：02[$A0 | $A1] 09[$B0 | $B1] 11[$C0 | $C1] 12[$D0 | $D1]"
[ "$A0" = "ledger_line_owner_mismatch" ] && ok "pg_temp 劫持 02 trg_mvk_line_kind：wms_app 建临时表 stock_ledger_line 伪造归属行，函数仍读 public → $A0" || bad "02 pg_temp 劫持：$A0（期望 ledger_line_owner_mismatch）"
[ "$B0" = "scrap_line_locked" ] && ok "pg_temp 劫持 09 trg_scrl_draft_only：临时表 scrap_order 把已取消单伪造成 DRAFT，函数仍读 public → $B0" || bad "09 pg_temp 劫持：$B0（期望 scrap_line_locked）"
[ "$C0" = "PT_PASSED" ] && ok "pg_temp 劫持 11 trg_outbox_order_guard：临时表 outbox_event 伪造同 biz_key 更早的 PENDING 行想卡住投递，函数仍读 public，真实事件照常进 SENDING（$C0）" || bad "11 pg_temp 劫持：$C0（期望正常放行 PT_PASSED）"
[ "$D0" = "approval_code_warehouse_mismatch" ] && ok "pg_temp 劫持 12 trg_apr_insert：临时表 warehouse 把仓 1 编码伪造成 PTFAKE，函数仍读 public → $D0" || bad "12 pg_temp 劫持：$D0（期望 approval_code_warehouse_mismatch）"
[ "$PC1" = "4/94" ] && ok "变异：四个函数去掉 pg_temp 后目录断言变红（$PC1）" || bad "变异目录断言没变红：$PC1（期望 4/94）"
[ "$A1" != "$A0" ] && ok "变异：trg_mvk_line_kind 去掉 pg_temp 后临时表劫持生效（$A1）" || bad "变异没变红：trg_mvk_line_kind 去掉 pg_temp 后仍是 $A1"
[ "$B1" != "$B0" ] && ok "变异：trg_scrl_draft_only 去掉 pg_temp 后临时表劫持生效（$B1）" || bad "变异没变红：trg_scrl_draft_only 去掉 pg_temp 后仍是 $B1"
[ "$C1" != "$C0" ] && ok "变异：trg_outbox_order_guard 去掉 pg_temp 后临时表劫持生效（$C1）" || bad "变异没变红：trg_outbox_order_guard 去掉 pg_temp 后仍是 $C1"
[ "$D1" != "$D0" ] && ok "变异：trg_apr_insert 去掉 pg_temp 后临时表劫持生效（$D1）" || bad "变异没变红：trg_apr_insert 去掉 pg_temp 后仍是 $D1"
echo "=== 2z2. #2 第九轮 时间约定：UTC 整秒、TIMESTAMP（不带时区）；预占 expires_at 由库计算（PG）==="
# 会话时区设成 Asia/Shanghai，经 02 路径写入：stock.created_at（DEFAULT）与 stock_reservation.created_at/expires_at（BEFORE 触发器）都必须是 UTC 整秒
R=$(psql -t -A <<'TZSQL' | grep '^TZ#'
SET TIME ZONE 'Asia/Shanghai';
INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (9201,1,2,1,3,9201,'KG',1000);
INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status,created_at) VALUES (9201,11,'RESERVE','OUTBOUND_LINE',1,9201,'RES:TZ:9201',1000,'RESERVED','2000-01-01 00:00:00');
SELECT 'TZ#' || (SELECT abs(extract(epoch FROM created_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND created_at = date_trunc('second', created_at) FROM stock WHERE id=9201)::text
  || '#' || (SELECT abs(extract(epoch FROM created_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND created_at = date_trunc('second', created_at) FROM stock_reservation WHERE id=9201)::text
  || '#' || (SELECT extract(epoch FROM expires_at - created_at)::bigint FROM stock_reservation WHERE id=9201)::text;
TZSQL
)
IFS='#' read -r _ TZ1 TZ2 TZ3 <<< "$R"
[ "$TZ1" = "true" ] && ok "会话 TIME ZONE=Asia/Shanghai 下经 02 写 stock：created_at 是 UTC 整秒（与 now() AT TIME ZONE 'UTC' 差 ≤ 5s）" || bad "stock.created_at 不是 UTC 整秒：$TZ1"
[ "$TZ2" = "true" ] && ok "会话 Asia/Shanghai 下写预占，调用方填 created_at=2000-01-01 被库改写成 UTC 整秒的当前时间" || bad "stock_reservation.created_at 不是库时钟 UTC 整秒：$TZ2"
[ "$TZ3" = "86400" ] && ok "预占不带 expires_at：库补算 created_at + 24h（$TZ3 s）" || bad "预占 expires_at 补算 = $TZ3（期望 86400）"
R=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND data_type = 'timestamp with time zone'")
[ "$R" = "0" ] && ok "public 下没有 timestamptz 列（时间列一律 TIMESTAMP 不带时区，语义 UTC）" || bad "public 下有 $R 个 timestamptz 列"
expect_block "预占 expires_at 填 2999 年（永不过期）" \
  "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status,expires_at) VALUES (9202,11,'RESERVE','OUTBOUND_LINE',1,9202,'RES:TTL:9202',1000,'RESERVED','2999-01-01 00:00:00');" "ck_res_ttl"
expect_block "预占 expires_at = 当前 UTC + 24h + 1min" \
  "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status,expires_at) VALUES (9203,11,'RESERVE','OUTBOUND_LINE',1,9203,'RES:TTL:9203',1000,'RESERVED',(now() AT TIME ZONE 'UTC') + interval '24 hours 1 minute');" "ck_res_ttl"
expect_block "预占 事后把 expires_at 改成 2999 年" "UPDATE stock_reservation SET expires_at='2999-01-01 00:00:00' WHERE id=9201;" "ck_res_ttl"
expect_block "预占 事后改 created_at（借此抬高上界）" "UPDATE stock_reservation SET created_at='2999-01-01 00:00:00', expires_at='2999-01-01 12:00:00' WHERE id=9201;" "reservation_created_at_immutable"
expect_block "预占 B1：属主把 expires_at 改成 NULL（永不过期）" "UPDATE stock_reservation SET expires_at=NULL WHERE id=9201;" "expires_at"
expect_block "预占 B1：wms_app 把 expires_at 改成 NULL（永不过期）" "SET ROLE wms_app; UPDATE stock_reservation SET expires_at=NULL WHERE id=9201;" "expires_at"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
ALTER TABLE stock_reservation ALTER COLUMN expires_at DROP NOT NULL;
DO $m$ BEGIN UPDATE stock_reservation SET expires_at=NULL WHERE id=9201; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 expires_at NOT NULL 后，改成 NULL 成功（B1 断言能抓到）" || bad "变异没变红：去掉 NOT NULL 后仍是 $R"
expect_allow "预占 N1：缩短 TTL（expires_at = created_at + 1s）允许" "UPDATE stock_reservation SET expires_at = created_at + interval '1 second' WHERE id=9201;"
expect_block "预占 N1：再延长到 created_at + 24h + 1s 仍拒" "UPDATE stock_reservation SET expires_at = created_at + interval '24 hours 1 second' WHERE id=9201;" "ck_res_ttl"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
ALTER TABLE stock_reservation DROP CONSTRAINT ck_res_ttl;
DO $m$ BEGIN INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status,expires_at) VALUES (9204,11,'RESERVE','OUTBOUND_LINE',1,9204,'RES:TTL:9204',1000,'RESERVED','2999-01-01 00:00:00'); PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 ck_res_ttl 后，expires_at=2999 的预占写入成功（断言能抓到）" || bad "变异没变红：去掉 ck_res_ttl 后仍是 $R"
echo "=== 2z4. #2 第十一轮 流水 occurred_at 由库定（PG）==="
MVI="INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key)"
MKI="INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at)"
mv_try() {  # $1 = 前置语句（属主），$2 = 客户端 occurred_at 表达式；输出 MV#<结果>#<库里的值是否 = 事务 now 整秒>
psql -q -t -A <<MVSQL | grep '^MV#'
BEGIN;
INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (9301,1,2,1,3,9301,'KG',0);
INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('MVCLK',1,'DOC',NULL);
$1
SET LOCAL ROLE wms_app;
DO \$m\$ BEGIN
  $MVI VALUES (99301,'MVCLK',1,1,1,'DOC','OPENING',1,9301,1,1,2,1,3,50000,0,50000,$2,'MVCLK:1');
  $MKI VALUES (99301,'MVCLK:1','MVCLK',1,1,1,'DOC',9301,1,1,$2);
  PERFORM set_config('m.r','PASSED',true);
EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END \$m\$;
RESET ROLE;
SELECT 'MV#' || current_setting('m.r') || '#' || COALESCE((SELECT (m.occurred_at = date_trunc('second', now() AT TIME ZONE 'UTC') AND k.occurred_at = m.occurred_at)::text FROM stock_movement m JOIN stock_movement_key k ON k.movement_id = m.id WHERE m.id = 99301), 'none');
ROLLBACK;
MVSQL
}
R=$(mv_try "" "date_trunc('month', now() AT TIME ZONE 'UTC')")
[ "$R" = "MV#PASSED#true" ] && ok "wms_app 写流水 occurred_at=本月 1 日 0 点：库改写成事务 now 的 UTC 整秒（流水与 key 一致）" || bad "流水 occurred_at 同月改写：$R（期望 MV#PASSED#true）"
R=$(mv_try "" "date_trunc('second', now() AT TIME ZONE 'UTC') + interval '2 months'")
[ "${R#MV#}" != "${R#MV#movement_clock_skew}" ] && ok "wms_app 写流水 occurred_at=2 个月后（跨分区）→ movement_clock_skew（40003）" || bad "流水 occurred_at 跨月：$R（期望 movement_clock_skew）"
R=$(mv_try "SET LOCAL TIME ZONE 'Asia/Shanghai';" "'2000-01-01 00:00:00'::timestamp + (date_trunc('month', now() AT TIME ZONE 'UTC') - '2000-01-01'::timestamp)")
[ "$R" = "MV#PASSED#true" ] && ok "会话时区 Asia/Shanghai 下 wms_app 写流水：仍落 UTC 整秒" || bad "时区下流水 occurred_at：$R"
R=$(mv_try "DROP TRIGGER trg_mv_zclock ON stock_movement; DROP TRIGGER trg_mvk_zclock ON stock_movement_key;" "date_trunc('month', now() AT TIME ZONE 'UTC')")
[ "$R" = "MV#PASSED#false" ] && ok "变异：去掉 trg_mv_zclock / trg_mvk_zclock 后，客户端填的本月 1 日原样落库（断言能抓到）" || bad "变异没变红：去掉流水时钟触发器后 $R（期望 MV#PASSED#false）"
R=$(mv_try "DROP TRIGGER trg_mv_zclock ON stock_movement; DROP TRIGGER trg_mvk_zclock ON stock_movement_key;" "date_trunc('second', now() AT TIME ZONE 'UTC') + interval '2 months'")
[ "$R" = "MV#PASSED#false" ] && ok "变异：去掉流水时钟触发器后，2 个月后的 occurred_at 写入成功（断言能抓到）" || bad "变异没变红：$R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE t.tgname='trg_mv_zclock' AND c.relispartition")
[ "$R" -ge 1 ] && ok "trg_mv_zclock 挂在分区父表，已克隆到 $R 个分区" || bad "trg_mv_zclock 没克隆到分区：$R"
echo "=== 2z5. N4 收尾：清掉 verify 自建的劫持辅助对象，库里不留未固定 search_path 的自定义函数（PG）==="
psql -q -c "DROP SCHEMA IF EXISTS hijack, hijack12, hj_evil, t18_rogue CASCADE;" >/dev/null 2>&1
R=$(psql -t -A -c "SELECT count(*) || '#' || COALESCE(string_agg(n.nspname || '.' || p.proname, ','), '') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%' AND p.prolang IN (SELECT oid FROM pg_language WHERE lanname IN ('plpgsql','sql')) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=pg_catalog, public, pg_temp')")
[ "${R%%#*}" = "0" ] && ok "收尾后库内自定义函数全部固定 search_path=pg_catalog, public, pg_temp（不合规 0）" || bad "收尾后仍有未固定 search_path 的函数：${R#*#}"
echo "=== 2z4 第 1/2 篇触发器 / 索引名冻结基线（#2 第十三轮；少一个 = 红）==="
T0102="'warehouse','zone','location','sku','sku_barcode','sku_unit','lot','stock','stock_reservation','stock_hold','stock_hold_release','stock_ledger_line','stock_movement','stock_movement_key','stock_snapshot_daily','stock_recon_alert'"
PG_TRG_NOW=$(psql -t -A -c "SELECT string_agg(DISTINCT t.tgname, ' ' ORDER BY t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace AND NOT c.relispartition AND c.relname IN ($T0102)")
PG_IDX_NOW=$(psql -t -A -c "SELECT string_agg(i.relname, ' ' ORDER BY i.relname) FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class c ON c.oid = x.indrelid WHERE c.relnamespace = 'public'::regnamespace AND NOT c.relispartition AND c.relname IN ($T0102)")
PG_TRG_BASE="trg_hold_immutable trg_hold_no_delete trg_hold_no_truncate trg_hr_append_only trg_hr_no_truncate trg_lot_sell_deadline trg_mv_append_only trg_mv_no_truncate trg_mv_zclock trg_mvk_append_only trg_mvk_line_kind trg_mvk_no_truncate trg_mvk_zclock trg_recon_resolved_lock trg_res_ttl trg_sll_immutable"
PG_IDX_BASE="ix_hold_from ix_hold_stock ix_hr_hold ix_loc_replen ix_lot_aging ix_lot_expiry ix_mv_biz ix_mv_hold ix_mv_sku_time ix_mv_stock ix_mv_time ix_recon_open ix_res_exp ix_res_source ix_res_stock ix_sku_category ix_snap_sku ix_stock_loc ix_stock_sku_avail ix_stock_wh ix_zone_wh_type location_pkey lot_pkey sku_barcode_pkey sku_pkey sku_unit_pkey stock_hold_pkey stock_hold_release_pkey stock_ledger_line_pkey stock_movement_key_pkey stock_movement_pkey stock_pkey stock_recon_alert_pkey stock_reservation_pkey stock_snapshot_daily_pkey uq_barcode uq_hold_op uq_hold_return uq_hr_op uq_location_code uq_lot uq_mvk_biz_line uq_mvk_idem uq_mvk_mv uq_mvk_pda_op uq_mvk_stock_seq uq_recon_open uq_res_op uq_sku_code uq_sku_uom uq_stock_dim uq_warehouse_code uq_zone_code warehouse_pkey zone_pkey"
for KIND in TRG IDX; do
  eval "NOW=\$PG_${KIND}_NOW; BASE=\$PG_${KIND}_BASE"
  MISS=$(comm -23 <(tr ' ' '\n' <<<"$BASE" | sort) <(tr ' ' '\n' <<<"$NOW" | sort) | tr '\n' ' ')
  EXTRA=$(comm -13 <(tr ' ' '\n' <<<"$BASE" | sort) <(tr ' ' '\n' <<<"$NOW" | sort) | tr '\n' ' ')
  [ -z "${MISS// /}" ] && ok "01/02 $KIND 名单与冻结基线一致（$(wc -w <<<"$BASE") 个）" || bad "01/02 $KIND 少了：$MISS"
  [ -z "${EXTRA// /}" ] || echo "  · 01/02 $KIND 基线外新增（请补进基线）：$EXTRA"
done
echo "=== 2z4-11 第 11 篇触发器 / 索引名冻结基线（同 #2 第十三轮机制；少一个 = 红）==="
# audit_log 属第 11 篇（爱弥斯确认），12b 挂在它上面的触发器 / 索引一并冻结
T11="'outbox_event','idempotency_record','upstream_push_log','offline_paper_record','inbound_message','numbering_segment','audit_log'"
Q11_TRG="SELECT string_agg(DISTINCT t.tgname, ' ' ORDER BY t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace AND NOT c.relispartition AND c.relname IN ($T11)"
Q11_IDX="SELECT string_agg(i.relname, ' ' ORDER BY i.relname) FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class c ON c.oid = x.indrelid WHERE c.relnamespace = 'public'::regnamespace AND NOT c.relispartition AND c.relname IN ($T11)"
PG11_TRG_NOW=$(psql -t -A -c "$Q11_TRG"); PG11_IDX_NOW=$(psql -t -A -c "$Q11_IDX")
PG11_TRG_BASE="trg_audit_append_only trg_audit_no_truncate trg_audit_node_required trg_audit_server_time trg_idem_expiry_fwd trg_idem_no_truncate trg_idem_purge_guard trg_idem_server_time trg_in_msg_key_immutable trg_in_msg_server_time trg_numbering_guard trg_numbering_no_truncate trg_outbox_expiry_fwd trg_outbox_insert_pending trg_outbox_no_truncate trg_outbox_order_guard trg_outbox_purge_guard trg_paper_server_time trg_upl_append_only trg_upl_no_truncate trg_upl_server_time"
PG11_IDX_BASE="audit_log_pkey idempotency_record_pkey inbound_message_pkey ix_audit_actor ix_audit_target ix_audit_wh ix_idem_exp ix_in_msg_retry ix_outbox_bizkey ix_outbox_noseq ix_outbox_pending ix_paper_pending ix_upl_src ix_upl_time numbering_segment_pkey offline_paper_record_pkey outbox_event_pkey upstream_push_log_pkey uq_audit_node_seq uq_in_msg uq_outbox_dead_bizkey uq_outbox_seq uq_paper_bizkey"
miss11() { comm -23 <(tr ' ' '\n' <<<"$1" | sort) <(tr ' ' '\n' <<<"$2" | sort) | tr '\n' ' '; }
for KIND in TRG IDX; do
  eval "NOW=\$PG11_${KIND}_NOW; BASE=\$PG11_${KIND}_BASE"
  MISS=$(miss11 "$BASE" "$NOW"); EXTRA=$(miss11 "$NOW" "$BASE")
  [ -z "${MISS// /}" ] && ok "11 $KIND 名单与冻结基线一致（$(wc -w <<<"$BASE") 个）" || bad "11 $KIND 少了：$MISS"
  [ -z "${EXTRA// /}" ] || echo "  · 11 $KIND 基线外新增（请补进基线）：$EXTRA"
done
MT=$(psql -t -A -q -c "BEGIN; DROP TRIGGER trg_numbering_guard ON numbering_segment; DROP INDEX uq_outbox_seq; $Q11_TRG; $Q11_IDX; ROLLBACK;" 2>&1 | tr '\n' '|')
MTT=$(miss11 "$PG11_TRG_BASE" "$(cut -d'|' -f1 <<<"$MT")"); MTI=$(miss11 "$PG11_IDX_BASE" "$(cut -d'|' -f2 <<<"$MT")")
[ "${MTT// /}" = "trg_numbering_guard" ] && [ "${MTI// /}" = "uq_outbox_seq" ] && ok "变异：去掉 trg_numbering_guard + uq_outbox_seq → 11 基线变红（$MTT/ $MTI）" || bad "变异：11 基线未变红：[$MTT] [$MTI]"
# 第 13 轮配套：11 表声明外键，种子无孤儿
R=$(psql -t -A -c "SELECT (SELECT count(*) FROM audit_log a WHERE a.warehouse_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM warehouse w WHERE w.id = a.warehouse_id)) || '/' || (SELECT count(*) FROM offline_paper_record p WHERE NOT EXISTS (SELECT 1 FROM warehouse w WHERE w.id = p.warehouse_id))")
[ "$R" = "0/0" ] && ok "11 外键：audit_log / offline_paper_record 的 warehouse_id 无孤儿（$R）" || bad "11 外键孤儿：$R"
expect_block "11 外键：audit_log.warehouse_id 指向不存在的仓" "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (779701,'t11.fk',7,779701,999999);" "audit_log_warehouse_id_fkey"
expect_block "11 外键：offline_paper_record.warehouse_id 指向不存在的仓" "INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (779702,999999,'PDA-07','PICK_CONFIRM','PK-FK','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL');" "offline_paper_record_warehouse_id_fkey"
echo "=== 2h-clock. 18 服务端时间（time-scan 18-1）：非属主写入改成库时钟 UTC（PG）==="
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, '2099-01-01 00:00:00' FROM live_death ORDER BY id LIMIT 1; RESET ROLE; SELECT abs(extract(epoch FROM reported_at - date_trunc('second', now() AT TIME ZONE 'UTC'))) <= 1 FROM live_death WHERE id=(SELECT max(id) FROM live_death); ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "18 wms_app 死亡上报 reported_at=2099 → 库时钟" || bad "18 wms_app 死亡上报 reported_at=2099 → 库时钟：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) SELECT id+900000, warehouse_id, location_id, device_instance_id, client_op_id || 'z', inspector_id, '2020-01-01 00:00:00', temp_c10, do_x100, ph_x100, result, consecutive_breach, is_recheck FROM live_inspection ORDER BY id LIMIT 1; RESET ROLE; SELECT abs(extract(epoch FROM inspected_at - date_trunc('second', now() AT TIME ZONE 'UTC'))) <= 1 FROM live_inspection WHERE id=(SELECT max(id) FROM live_inspection); ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "18 wms_app 巡检 inspected_at 倒签 → 库时钟" || bad "18 wms_app 巡检 inspected_at 倒签 → 库时钟：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) SELECT id+900000, warehouse_id, task_kind, task_id, line_no, weigh_client_id || 'z', device_instance_id, scale_id, reading_source, location_id, stock_id, sku_id, lot_id, gross_qty_milli, tare_qty_milli, net_qty_milli, qty_count, planned_qty_milli, deviation_bp, result, result_code, movement_id, weighed_by, '2020-01-01 00:00:00' FROM live_weigh ORDER BY id LIMIT 1; RESET ROLE; SELECT abs(extract(epoch FROM weighed_at - date_trunc('second', now() AT TIME ZONE 'UTC'))) <= 1 FROM live_weigh WHERE id=(SELECT max(id) FROM live_weigh); ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "18 wms_app 称重 weighed_at 倒签 → 库时钟" || bad "18 wms_app 称重 weighed_at 倒签 → 库时钟：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at,client_occurred_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, '2020-01-01 00:00:00', '2020-01-01 00:00:00' FROM live_death ORDER BY id LIMIT 1; RESET ROLE; SELECT abs(extract(epoch FROM reported_at - date_trunc('second', now() AT TIME ZONE 'UTC'))) <= 1 AND client_occurred_at = '2020-01-01 00:00:00' FROM live_death WHERE id=(SELECT max(id) FROM live_death); ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "18 T2 反向：wms_app 上报 reported_at 倒签，库写 now，设备原值保留在 client_occurred_at" || bad "18 T2 反向：wms_app 上报 reported_at 倒签，库写 now，设备原值保留在 client_occurred_at：$R"
R=$(psql -t -A -c "SELECT string_agg(table_name||'.'||column_name||':'||is_nullable||':'||data_type, ' ' ORDER BY table_name) FROM information_schema.columns WHERE table_schema='public' AND column_name = 'client_occurred_at' AND table_name LIKE 'live%'")
[ "$R" = "live_death.client_occurred_at:YES:timestamp without time zone live_inspection.client_occurred_at:YES:timestamp without time zone live_weigh.client_occurred_at:YES:timestamp without time zone" ] && ok "18 §6.8-7 三张表 client_occurred_at：可空 TIMESTAMP（不带时区）" || bad "18 T2 client 列：$R"
expect_block "18 库写时间改成 NULL：live_death.reported_at" "BEGIN; UPDATE live_death SET reported_at = NULL WHERE id = (SELECT min(id) FROM live_death); COMMIT;" "append_only_violation"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL TIME ZONE 'Asia/Shanghai'; SET LOCAL ROLE wms_app; INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, localtimestamp FROM live_death ORDER BY id LIMIT 1; RESET ROLE; SELECT abs(extract(epoch FROM reported_at - date_trunc('second', now() AT TIME ZONE 'UTC'))) <= 1 AND localtimestamp - reported_at > interval '7 hours 59 minutes' FROM live_death WHERE id=(SELECT max(id) FROM live_death); ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "18 时区：SET TIME ZONE Asia/Shanghai，wms_app 死亡上报存 UTC" || bad "18 时区：SET TIME ZONE Asia/Shanghai，wms_app 死亡上报存 UTC：$R"
R=$(psql -t -A -c "SELECT proconfig::text FROM pg_proc WHERE proname='trg_live_zclock'")
[ "$R" = "{\"search_path=pg_catalog, public, pg_temp\"}" ] && ok "18 trg_live_zclock search_path 含 pg_temp" || bad "18 trg_live_zclock proconfig：$R"
R=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name LIKE 'live%' AND data_type = 'timestamp with time zone'")
[ "$R" = "0" ] && ok "18 时间列全部是 TIMESTAMP（without time zone）" || bad "18 有 timestamptz 列：$R"
echo "=== 2j. docs/03 入库：UC1/UC9、测温与离冷链、上架 SoD、质量反馈 SCRAP_PENDING、关单不可改、收货更正单（审批窗口 24h/7d、收货人不能审批） ==="
expect_allow "03 种子：冷藏收货区/暂存位/存储位、SKU 冷鲜猪里脊、批次、两条库存行、采购入库单 + 行（订 100 KG）" "BEGIN; INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (31,1,'Z-RCV','冷藏收货区','CHILLED','RECEIVE',20,80); INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (31,1,31,'RCV-01','FLOOR',99,'R010'),(32,1,2,'B31-01-01','PALLET',8,'B310'); INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (31,'SKU-PORK','冷鲜猪里脊','KG','CHILLED',5,2,3); INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (303,31,'L-PORK1','2026-10-20','2026-10-15'); INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (3101,1,31,31,303,'KG',0),(3102,1,32,31,303,'KG',0); INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date,arrived_at,unload_start_at) VALUES (3100,'INB-SH01-0001-20261015-000001',1,'PURCHASE','ERP','PO-3100','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',501,'RECEIVING','2026-10-15','2026-10-15 01:00:00','2026-10-15 01:05:00'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,temp_zone,ordered_qty_milli,lot_id,expiry_date) VALUES (3110,3100,1,31,'KG','CHILLED',100000,303,'2026-10-20'); COMMIT;"
expect_block "03 单头状态白名单" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1',NULL,'DONE','2026-10-15',NULL); COMMIT;" "ck_inb_status"
expect_block "03 source_hash 大写 hex" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA','CREATED','2026-10-15',NULL); COMMIT;" "ck_inb_hash"
expect_block "03 退货入库来源白名单（#5 的 ck_inb_rtn_src，10 ALTER，基线已有）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'RTN-X1',1,'RETURN','WHATEVER','X-1',NULL,'CREATED','2026-10-15',NULL); COMMIT;" "ck_inb_rtn_src"
expect_block "03 COMPLETED 不带 closed_at" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1',NULL,'COMPLETED','2026-10-15',NULL); COMMIT;" "ck_inb_closed"
expect_block "03 同上游单号重推（uq_inb_src，00 §6.5）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-3100',NULL,'CREATED','2026-10-15',NULL); COMMIT;" "uq_inb_src"
expect_allow "03 #5 兼容：退货单只给 #5 用到的列也能建（三列由 10 ALTER 加）（RTN + 行 received_qty_milli）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3190,'RTN-3190',1,'RETURN','WMS_DELIVERY','POD-3190','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3191,3190,1,31,'KG',4000); COMMIT;"
expect_block "03 行实收为负（#5 的 ck_inbl_qc）" "BEGIN; INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3192,3190,2,31,'KG',-1); COMMIT;" "ck_inbl_qc"
expect_block "03 行挂在不存在的单上" "BEGIN; INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3193,999999,1,31,'KG'); COMMIT;" "fk_inbl_order"
expect_allow "03 测温：温区整批 3.0 ℃ + 行 3.5 ℃（冷藏 0–4 ℃ 快照），PASS/ACCEPT" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3120,1,3100,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3100:z1',21,'2026-10-15 01:06:00'),(3121,1,3100,'LINE','CHILLED',3110,35,0,40,'PASS','ACCEPT','TMP:3100:l1',21,'2026-10-15 01:07:00'); COMMIT;"
expect_block "03 测温 8.0 ℃ 却记 PASS（结果与读数不符）" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3110,80,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00'); COMMIT;" "ck_itc_result"
expect_block "03 测温 FAIL 仍判 ACCEPT（不合格只能拒收或转质检冻结）" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3110,80,0,40,'FAIL','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00'); COMMIT;" "ck_itc_disp"
expect_block "03 按行测温不带行号" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00'); COMMIT;" "ck_itc_scope"
expect_block "03 冷藏测温没有上下限快照" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'ZONE','CHILLED',NULL,30,NULL,NULL,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00'); COMMIT;" "ck_itc_range"
# 03+10 增量·测温严格方案（Chief 三次确认）：非 AMBIENT 只给一端 = 快照不完整，必须拒；AMBIENT 两端全空仍放行
expect_block "03 严格方案：冷藏只给上限（max=-150）也是快照不完整 → 拒" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3124,1,3100,'ZONE','CHILLED',NULL,-600,NULL,-150,'PASS','ACCEPT','TMP:3100:x4',21,'2026-10-15 01:10:00'); COMMIT;" "ck_itc_range"
expect_block "03 严格方案：冷冻只给下限（min=-250）也是快照不完整 → 拒" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3125,1,3100,'ZONE','FROZEN',NULL,-250,-250,NULL,'PASS','ACCEPT','TMP:3100:x5',21,'2026-10-15 01:10:00'); COMMIT;" "ck_itc_range"
expect_allow "03 严格方案正向：冷冻两端齐全（-250 ～ -150）照常 PASS" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3126,1,3100,'ZONE','FROZEN',NULL,-200,-250,-150,'PASS','ACCEPT','TMP:3100:x6',21,'2026-10-15 01:10:00'); COMMIT;"
expect_allow "03 严格方案：AMBIENT 两端全空仍可落库（没有上下限快照）" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3127,1,3100,'ZONE','AMBIENT',NULL,250,NULL,NULL,'PASS','ACCEPT','TMP:3100:x7',21,'2026-10-15 01:10:00'); COMMIT;"
expect_allow "03 严格方案变异：去掉 ck_itc_range 后，只给上限的 -60 ℃ 冻货又能落库（随后回滚）" "BEGIN; ALTER TABLE inbound_temp_check DROP CONSTRAINT ck_itc_range; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3128,1,3100,'ZONE','CHILLED',NULL,-600,NULL,-150,'PASS','ACCEPT','TMP:3100:x8',21,'2026-10-15 01:10:00'); ROLLBACK;"
expect_block "03 按行测温挂到别的单的行上（组合外键）" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3191,30,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00'); COMMIT;" "fk_itc_line"
expect_allow "03 测温：复测 9.0 ℃ FAIL → REJECT" "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3123,1,3100,'LINE','CHILLED',3110,90,0,40,'FAIL','REJECT','TMP:3100:l2',21,'2026-10-15 01:09:00'); COMMIT;"
expect_block "03 测温记录只追加（UPDATE 改结果）" "BEGIN; UPDATE inbound_temp_check SET result='PASS', disposition='ACCEPT', measured_c10=30 WHERE id=3123; COMMIT;" "append_only_violation: inbound_temp_check"
expect_allow "03 UC1 收货 60 KG：post_in(RECEIVE) 暂存位 + hold(QUALITY, QC_PENDING) + 收货记录（离冷链 12 分钟 ≤ 20 分钟上限快照）+ 行实收" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('INB-SH01-0001-20261015-000001',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=60000, ledger_seq=1, version=version+1 WHERE id=3101 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31001,'INB-SH01-0001-20261015-000001',1,1,1,'DOC','RECEIVE',1,3101,1,1,31,31,303,60000,0,60000,'2026-10-15','INB-SH01-0001-20261015-000001:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31001,'INB-SH01-0001-20261015-000001:1:D1:1','INB-SH01-0001-20261015-000001',1,1,1,'DOC',3101,1,1,'2026-10-15'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3130,3101,'QUALITY','QC_PENDING','INBOUND_QC',3100,'RCVH:3140',60000,21,NULL); UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli+60000, version=version+1 WHERE id=3101 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=60000; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3140,1,3100,3110,'RCV:3110:1',60000,3101,3130,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_line SET received_qty_milli=received_qty_milli+60000, version=version+1 WHERE id=3110; COMMIT;"
expect_block "03 冷藏收货不挂测温" "BEGIN; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',NULL,NULL,'2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); COMMIT;" "ck_rcp_temp"
expect_block "03 收货挂的是 REJECT 测温" "BEGIN; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3123,'REJECT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); COMMIT;" "ck_rcp_temp"
expect_block "03 收货挂 REJECT 测温却谎报 ACCEPT（组合外键带处置）" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3139,3101,'QUALITY','QC_PENDING','INBOUND_QC',3100,'RCVH:x',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3139,'INB-SH01-0001-20261015-000001',303,'CHILLED',3123,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); COMMIT;" "fk_rcp_temp"
expect_block "03 离冷链 25 分钟超 20 分钟上限却不标超时" "BEGIN; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',1500,1200,0,21,'2026-10-15 01:20:00'); COMMIT;" "ck_rcp_chain"
expect_block "03 冷藏收货不记离冷链时长" "BEGIN; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT',NULL,NULL,NULL,NULL,0,21,'2026-10-15 01:20:00'); COMMIT;" "ck_rcp_chain"
expect_block "03 收货记录只追加（UPDATE 改数量）" "BEGIN; UPDATE inbound_receipt SET qty_milli=50000 WHERE id=3140; COMMIT;" "append_only_violation: inbound_receipt"
expect_block "03 收货记录只追加（DELETE）" "BEGIN; DELETE FROM inbound_receipt WHERE id=3140; COMMIT;" "append_only_violation: inbound_receipt"
expect_block "03 收货重放同一 op_key" "BEGIN; INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:1',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); COMMIT;" "uq_rcp_op"
expect_block "03 收货记录 TRUNCATE（PG）" "BEGIN; TRUNCATE inbound_receipt CASCADE; COMMIT;" "append_only_violation: inbound_receipt"
expect_allow "03 UC9 质检放行 50 KG：unhold QUALITY（释放去重 + 明细 + quality_hold）+ 行 qc_passed" "BEGIN; INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (3150,3130,'QCP:3110:1',50000); UPDATE stock_hold SET released_qty_milli=released_qty_milli+50000, status=CASE WHEN released_qty_milli+50000=hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version=version+1 WHERE id=3130 AND hold_type='QUALITY' AND status='HELD' AND hold_qty_milli-released_qty_milli>=50000; UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-50000, version=version+1 WHERE id=3101 AND quality_hold_qty_milli>=50000; UPDATE inbound_line SET qc_passed_qty_milli=qc_passed_qty_milli+50000, version=version+1 WHERE id=3110 AND inbound_id=3100 AND qc_passed_qty_milli+qc_failed_qty_milli+50000<=received_qty_milli; COMMIT;"
expect_block "03 合格 + 不合格超过实收" "BEGIN; UPDATE inbound_line SET qc_failed_qty_milli=20000 WHERE id=3110; COMMIT;" "ck_inbl_qc"
expect_allow "03 UC9 质检不合格 4 KG：convert_hold QUALITY → SCRAP_PENDING（跨列）+ 行 qc_failed" "BEGIN; UPDATE stock_hold SET released_qty_milli=released_qty_milli+4000, version=version+1 WHERE id=3130 AND status='HELD' AND hold_qty_milli-released_qty_milli>=4000; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3132,3101,'SCRAP_PENDING','SCRAP','SCRAP',9301,'CVT:3110:1',4000,0,3130); UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-4000, hold_qty_milli=hold_qty_milli+4000, version=version+1 WHERE id=3101 AND quality_hold_qty_milli>=4000; UPDATE inbound_line SET qc_failed_qty_milli=qc_failed_qty_milli+4000, version=version+1 WHERE id=3110 AND qc_passed_qty_milli+qc_failed_qty_milli+4000<=received_qty_milli; COMMIT;"
expect_allow "03 UC2 上架 30 KG（收货人 21、上架人 22）：move(PUTAWAY) 两腿 + 上架记录 + 行 putaway（trg_inbp_apply 累加）" "BEGIN; UPDATE stock SET on_hand_qty_milli=30000, ledger_seq=2, version=version+1 WHERE id=3101 AND ledger_seq=1 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=30000; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31002,'INB-SH01-0001-20261015-000001',1,2,1,'DOC','PUTAWAY',-1,3101,2,1,31,31,303,30000,60000,30000,'2026-10-15','INB-SH01-0001-20261015-000001:1:D2:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31002,'INB-SH01-0001-20261015-000001:1:D2:1','INB-SH01-0001-20261015-000001',1,2,1,'DOC',3101,2,-1,'2026-10-15'); UPDATE stock SET on_hand_qty_milli=30000, ledger_seq=1, version=version+1 WHERE id=3102 AND ledger_seq=0; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31003,'INB-SH01-0001-20261015-000001',1,2,2,'DOC','PUTAWAY',1,3102,1,1,32,31,303,30000,0,30000,'2026-10-15','INB-SH01-0001-20261015-000001:1:D2:2',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31003,'INB-SH01-0001-20261015-000001:1:D2:2','INB-SH01-0001-20261015-000001',1,2,2,'DOC',3102,1,1,'2026-10-15'); INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3160,1,3100,3110,3140,21,22,NULL,'PUT:3140:1',3101,32,30000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;"
expect_block "03 SoD：收货人 = 上架人（无放宽审批）" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,NULL,'PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_sod"
expect_block "03 SoD：放宽单号不是审批单号" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,'OK-123','PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 SoD：上架记录伪造收货人（与收货记录不符，组合外键）" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,23,21,NULL,'PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "fk_inbp_rcp"
expect_allow "03 SoD 放宽：小仓凭审批单号允许同一人（00 §2，放宽记审计）（已回滚）" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,'APR-WHSH01-20261015-000301','PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); ROLLBACK;"
expect_block "03 上架记录只追加（UPDATE 改上架人）" "BEGIN; UPDATE inbound_putaway SET putaway_by=21 WHERE id=3160; COMMIT;" "append_only_violation: inbound_putaway"
R=$(psql -t -A -c "SELECT (SELECT putaway_qty_milli FROM inbound_line WHERE id=3110)||'/'||(SELECT sum(qty_milli) FROM inbound_putaway WHERE inbound_line_id=3110)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=3102)")
[ "$R" = "30000/30000/30000" ] && ok "03 对账：行上架量 = Σ上架记录 = 存储位在库 = $R" || bad "03 对账：行上架量 = Σ上架记录 = 存储位在库 = $R（期望 30000/30000/30000）"
expect_block "03 B1 超上架：已上 30 KG，再上 20.001 KG（合格 50 KG）" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,20001,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "inbound_putaway_over_qty"
expect_allow "03 B1 上架正好补满合格量（30 + 20 = 50 KG）（已回滚）" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,20000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); ROLLBACK;"
expect_block "03 B1 上架数量 0" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,0,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_qty"
expect_block "03 B1 直接改行上架量超过合格量" "BEGIN; UPDATE inbound_line SET putaway_qty_milli=999999 WHERE id=3191; COMMIT;" "inbound_putaway_over_qc_passed"
expect_block "03 B1 直接改行上架量（≤ 合格量但与上架记录合计不符）" "BEGIN; UPDATE inbound_line SET putaway_qty_milli=31000 WHERE id=3110; COMMIT;" "inbound_putaway_counter_mismatch"
expect_block "03 B1 把合格量压到已上架量以下（计数器只增，先被 counter_not_monotonic 拦）" "BEGIN; UPDATE inbound_line SET qc_passed_qty_milli=29999 WHERE id=3110; COMMIT;" "inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC"
expect_block "03 B1 新建行自带上架量" "BEGIN; INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli,qc_passed_qty_milli,putaway_qty_milli) VALUES (3194,3190,2,31,'KG',10,10,5); COMMIT;" "inbound_putaway_counter_mismatch"
expect_block "03 N1 SoD 放宽单号格式：只有前缀 APR-" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 N1 SoD 放宽单号格式：空串" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 N1 SoD 放宽单号格式：APR- 加空格" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-   ','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 N1 SoD 放宽单号格式：小写" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'apr-whsh01-20261015-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 N1 SoD 放宽单号格式：前导空格" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,' APR-WHSH01-20261015-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 N1 SoD 放宽单号格式：13 月" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-WHSH01-20261315-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "ck_inbp_waiver"
expect_block "03 B1 wms_app 直接改上架计数（列级授权不含计数列）" "BEGIN; SET LOCAL ROLE wms_app; UPDATE inbound_line SET putaway_qty_milli=0 WHERE id=3191; COMMIT;" "permission denied for table inbound_line"
expect_block "03 B1 wms_app 直接改质检合格量" "BEGIN; SET LOCAL ROLE wms_app; UPDATE inbound_line SET qc_passed_qty_milli=0 WHERE id=3191; COMMIT;" "permission denied for table inbound_line"
expect_allow "03 B1 wms_app 改非计数列（lot_id）（已回滚）" "BEGIN; SET LOCAL ROLE wms_app; UPDATE inbound_line SET lot_id=303 WHERE id=3191; ROLLBACK;"
expect_allow "03 B1 wms_app 走上架记录（trg_inbp_apply SECURITY DEFINER 回写计数）（已回滚）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3164,1,3100,3110,3140,21,22,NULL,'PUT:3140:3164',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); ROLLBACK;"
R=$(psql -t -A -c "SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.column_privileges WHERE grantee='wms_app' AND table_name='inbound_line' AND privilege_type='UPDATE'")
[ "$R" = "cost_amount_fen,expiry_date,lot_id,ordered_qty_milli,production_date,sku_id,temp_zone,uom,version" ] && ok "03 B1 wms_app 对 inbound_line 只有 9 个非计数列的列级 UPDATE" || bad "03 inbound_line 列级 UPDATE 不符：$R"
expect_allow "03 入库后质量反馈：在库发现 1 KG 腐坏 → hold(QUALITY) + 反馈单 OPEN" "BEGIN; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3134,3102,'QUALITY','QC_PENDING','INBOUND_FB',3180,'IQFH:3180',1000,22,NULL); UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli+1000, version=version+1 WHERE id=3102 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=1000; INSERT INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,disposition,reported_by,found_at) VALUES (3180,1,'IQF-SH01-0001-20261015-000001',3100,3110,303,'IN_STOCK','ROT',1000,3102,3134,'PENDING',22,'2026-10-15 05:00:00'); COMMIT;"
expect_block "03 质量反馈：驳回处置不挂冻结" "BEGIN; INSERT INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,status,disposition,reported_by,found_at,closed_by,closed_at) VALUES (3181,1,'IQF-SH01-0001-20261015-000002',3100,3110,303,'IN_STOCK','ROT',1000,3102,NULL,'CLOSED','REJECTED',22,'2026-10-15 05:00:00',9,'2026-10-15 06:00:00'); COMMIT;" "ck_iqf_hold"
expect_block "03 质量反馈：OPEN 改受影响数量" "BEGIN; UPDATE inbound_quality_feedback SET affected_qty_milli=500 WHERE id=3180; COMMIT;" "iqf_immutable"
expect_block "03 质量反馈：发现人自己关单" "BEGIN; UPDATE inbound_quality_feedback SET status='CLOSED', disposition='REJECTED', closed_by=22, closed_at='2026-10-15 06:00:00' WHERE id=3180; COMMIT;" "ck_iqf_close"
expect_block "03 质量反馈：报损关单不挂 SCRAP_PENDING 冻结" "BEGIN; UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00' WHERE id=3180; COMMIT;" "ck_iqf_scrap"
expect_block "03 质量反馈：报损关单挂的是 QUALITY 冻结（不是 SCRAP_PENDING）" "BEGIN; UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00', scrap_hold_id=3134 WHERE id=3180; COMMIT;" "iqf_scrap_hold_not_scrap_pending"
expect_block "03 质量反馈：退供待处置也必须挂 SCRAP_PENDING" "BEGIN; UPDATE inbound_quality_feedback SET status='CLOSED', disposition='RETURN_SUPPLIER', closed_by=9, closed_at='2026-10-15 06:00:00' WHERE id=3180; COMMIT;" "ck_iqf_scrap"
expect_allow "03 质量反馈关单：主管 9 判 SCRAP，挂 hold(SCRAP_PENDING) 3135，convert_hold QUALITY → SCRAP_PENDING" "BEGIN; UPDATE stock_hold SET released_qty_milli=1000, status='RELEASED', version=version+1 WHERE id=3134 AND status='HELD' AND released_qty_milli=0; INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3135,3102,'SCRAP_PENDING','SCRAP','SCRAP',9302,'CVT:3134',1000,0,3134); UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-1000, hold_qty_milli=hold_qty_milli+1000, version=version+1 WHERE id=3102 AND quality_hold_qty_milli>=1000; UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00', scrap_hold_id=3135, version=version+1 WHERE id=3180 AND status='OPEN'; COMMIT;"
expect_block "03 质量反馈：关单后再改" "BEGIN; UPDATE inbound_quality_feedback SET remark='x' WHERE id=3180; COMMIT;" "iqf_immutable"
expect_block "03 质量反馈：删除" "BEGIN; DELETE FROM inbound_quality_feedback WHERE id=3180; COMMIT;" "iqf_immutable"
expect_allow "03 关单：入库单 3100 COMPLETED（属主写 closed_at 10:00，不被库时钟覆盖）" "BEGIN; UPDATE inbound_order SET status='COMPLETED', received_at='2026-10-15 01:20:00', closed_at='2026-10-15 10:00:00', version=version+1 WHERE id=3100 AND status='RECEIVING'; COMMIT;"
R=$(psql -t -A -c "SELECT closed_at FROM inbound_order WHERE id=3100")
[ "$R" = "2026-10-15 10:00:00" ] && ok "03 时间：属主豁免，关单时间保留种子值 $R" || bad "03 属主关单时间被改写：$R"
expect_block "03 关单后改原单（单头备注）" "BEGIN; UPDATE inbound_order SET remark='x' WHERE id=3100; COMMIT;" "inbound_order_closed_immutable"
expect_block "03 关单后改入库行实收（更正只能开更正单）" "BEGIN; UPDATE inbound_line SET received_qty_milli=62000 WHERE id=3110; COMMIT;" "inbound_line_closed_immutable"
expect_block "03 关单后往单上加行" "BEGIN; INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3111,3100,2,31,'KG'); COMMIT;" "inbound_line_closed_immutable"
expect_block "03 关单后删单" "BEGIN; DELETE FROM inbound_order WHERE id=3100; COMMIT;" "inbound_order_closed_immutable"
expect_block "03 B1 关单后再上架" "BEGIN; INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3165,1,3100,3110,3140,21,22,NULL,'PUT:3140:3165',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00'); COMMIT;" "inbound_putaway_closed_immutable"
expect_block "03 更正单：关单后 24h+1s 只有主管审批（要主管 + 采购双审）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31101,'IRC-B1',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31101,'IRC-B1:1:D1:1','IRC-B1',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31101,'wms.inbound.corrected','IRC-B1','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3201,1,'IRC-B1',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3201',1,2000,3102,31101,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03201','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-16 10:00:01'); COMMIT;" "inbound_correction_dual_approval_required"
expect_block "03 更正单：关单后 7d+1s（超窗，转 08 盘点调整）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B2',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31102,'IRC-B2',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B2:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31102,'IRC-B2:1:D1:1','IRC-B2',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31102,'wms.inbound.corrected','IRC-B2','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3202,1,'IRC-B2',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3202',1,2000,3102,31102,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03202','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-22 10:00:01'); COMMIT;" "inbound_correction_window_closed"
expect_block "03 更正单：24h 内按双审落档（层级必须与窗口一致）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B3',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31103,'IRC-B3',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B3:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31103,'IRC-B3:1:D1:1','IRC-B3',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31103,'wms.inbound.corrected','IRC-B3','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3203,1,'IRC-B3',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3203',1,2000,3102,31103,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03203','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-15 12:00:00'); COMMIT;" "inbound_correction_tier_mismatch"
expect_block "03 更正单：收货人 21 当主管审批（申请人另有其人）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B4',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31104,'IRC-B4',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B4:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31104,'IRC-B4:1:D1:1','IRC-B4',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31104,'wms.inbound.corrected','IRC-B4','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3204,1,'IRC-B4',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3204',1,2000,3102,31104,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03204','SUPERVISOR',23,'2026-10-15 10:00:00',21,NULL,'2026-10-15 12:00:00'); COMMIT;" "ck_irc_receiver_sod"
expect_block "03 更正单：收货人 21 当采购审批（双审）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B5',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31105,'IRC-B5',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B5:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31105,'IRC-B5:1:D1:1','IRC-B5',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31105,'wms.inbound.corrected','IRC-B5','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3205,1,'IRC-B5',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3205',1,2000,3102,31105,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03205','DUAL',23,'2026-10-15 10:00:00',9,21,'2026-10-17 12:00:00'); COMMIT;" "ck_irc_receiver_sod"
expect_block "03 更正单：申请人自批" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B6',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31106,'IRC-B6',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B6:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31106,'IRC-B6:1:D1:1','IRC-B6',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31106,'wms.inbound.corrected','IRC-B6','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3206,1,'IRC-B6',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3206',1,2000,3102,31106,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03206','SUPERVISOR',23,'2026-10-15 10:00:00',23,NULL,'2026-10-15 12:00:00'); COMMIT;" "ck_irc_self_apr"
expect_block "03 更正单：原因码必填" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B7',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31107,'IRC-B7',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B7:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31107,'IRC-B7:1:D1:1','IRC-B7',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31107,'wms.inbound.corrected','IRC-B7','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3207,1,'IRC-B7',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3207',1,2000,3102,31107,NULL,NULL,'APR-WHSH01-20261015-03207','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00'); COMMIT;" "violates not-null constraint"
expect_block "03 更正单：原因码 OTHER 不写说明" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B8',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31108,'IRC-B8',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B8:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31108,'IRC-B8:1:D1:1','IRC-B8',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31108,'wms.inbound.corrected','IRC-B8','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3208,1,'IRC-B8',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3208',1,2000,3102,31108,'OTHER',NULL,'APR-WHSH01-20261015-03208','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00'); COMMIT;" "ck_irc_reason"
expect_block "03 更正单：原因码不在字典" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B9',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31109,'IRC-B9',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B9:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31109,'IRC-B9:1:D1:1','IRC-B9',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31109,'wms.inbound.corrected','IRC-B9','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3209,1,'IRC-B9',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3209',1,2000,3102,31109,'MISCOUNT',NULL,'APR-WHSH01-20261015-03209','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00'); COMMIT;" "ck_irc_reason"
expect_block "03 更正单：伪造收货人（与收货记录不符，组合外键）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B10',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31110,'IRC-B10',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B10:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31110,'IRC-B10:1:D1:1','IRC-B10',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31110,'wms.inbound.corrected','IRC-B10','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3210,1,'IRC-B10',3100,3110,3140,22,'2026-10-15 10:00:00','IRC:3140:3210',1,2000,3102,31110,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03210','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00'); COMMIT;" "fk_irc_rcp"
expect_block "03 更正单：伪造关单时间把窗口往后挪（组合外键）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B11',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31111,'IRC-B11',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B11:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31111,'IRC-B11:1:D1:1','IRC-B11',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31111,'wms.inbound.corrected','IRC-B11','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3211,1,'IRC-B11',3100,3110,3140,21,'2026-10-16 12:00:00','IRC:3140:3211',1,2000,3102,31111,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03211','SUPERVISOR',23,'2026-10-16 12:00:00',9,NULL,'2026-10-17 12:00:00'); COMMIT;" "fk_irc_closed"
expect_block "03 更正单：流水数量和更正数量不符（必须经 02 原语过账同量）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B12',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31112,'IRC-B12',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,1500,30000,31500,CURRENT_TIMESTAMP,'IRC-B12:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31112,'IRC-B12:1:D1:1','IRC-B12',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31112,'wms.inbound.corrected','IRC-B12','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3212,1,'IRC-B12',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3212',1,2000,3102,31112,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03212','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00'); COMMIT;" "inbound_correction_movement_mismatch"
expect_block "03 B2 更正单：批准时间早于关单（整秒比较）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B14',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31113,'IRC-B14',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B14:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31113,'IRC-B14:1:D1:1','IRC-B14',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31113,'wms.inbound.corrected','IRC-B14','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3213,1,'IRC-B14',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3213',1,2000,3102,31113,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03213','SUPERVISOR',23,'2026-10-15 09:59:59',9,NULL,'2026-10-15 09:59:59'); COMMIT;" "inbound_correction_before_close"
expect_allow "03 更正单 +2 KG：关单后正好 24h，主管 9 审批（收货人 21、申请人 23）→ post_in(ADJUST) + outbox PENDING" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31120,'IRC-A1',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-A1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31120,'IRC-A1:1:D1:1','IRC-A1',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31120,'wms.inbound.corrected','IRC-A1','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3220,1,'IRC-A1',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3220',1,2000,3102,31120,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03220','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-16 10:00:00'); COMMIT;"
expect_allow "03 更正单 −1 KG：关单后正好 7d，主管 9 + 采购 41 双审 → post_out(ADJUST)" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A2',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=31000, ledger_seq=3, version=version+1 WHERE id=3102 AND ledger_seq=2 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=1000; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31122,'IRC-A2',1,1,1,'DOC','ADJUST',-1,3102,3,1,32,31,303,1000,32000,31000,CURRENT_TIMESTAMP,'IRC-A2:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31122,'IRC-A2:1:D1:1','IRC-A2',1,1,1,'DOC',3102,3,-1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31122,'wms.inbound.corrected','IRC-A2','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3222,1,'IRC-A2',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3222',-1,1000,3102,31122,'WEIGHT_ERROR',NULL,'APR-WHSH01-20261015-03222','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-22 10:00:00'); COMMIT;"
expect_allow "03 更正单 +0.5 KG：25h 双审（24h–7d 段内）" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A3',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=31500, ledger_seq=4, version=version+1 WHERE id=3102 AND ledger_seq=3; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31123,'IRC-A3',1,1,1,'DOC','ADJUST',1,3102,4,1,32,31,303,500,31000,31500,CURRENT_TIMESTAMP,'IRC-A3:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31123,'IRC-A3:1:D1:1','IRC-A3',1,1,1,'DOC',3102,4,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31123,'wms.inbound.corrected','IRC-A3','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3223,1,'IRC-A3',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3223',1,500,3102,31123,'WRONG_BATCH',NULL,'APR-WHSH01-20261015-03223','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 11:00:00'); COMMIT;"
expect_block "03 更正单：同一 op_key 重放" "BEGIN; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A3R',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31121,'IRC-A3R',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-A3R:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31121,'IRC-A3R:1:D1:1','IRC-A3R',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31121,'wms.inbound.corrected','IRC-A3R','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3221,1,'IRC-A3R',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3223',1,500,3102,31121,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03221','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 11:00:00'); COMMIT;" "uq_irc_op"
expect_block "03 更正单只追加（UPDATE 改数量）" "BEGIN; UPDATE inbound_correction SET qty_milli=1 WHERE id=3220; COMMIT;" "append_only_violation: inbound_correction"
expect_block "03 更正单只追加（DELETE）" "BEGIN; DELETE FROM inbound_correction WHERE id=3220; COMMIT;" "append_only_violation: inbound_correction"
expect_block "03 已对账结算后再开更正单（转 08）" "BEGIN; UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 12:00:00' WHERE id=3100; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00'); COMMIT;" "inbound_correction_reconciled"
expect_block "03 N4 对账时间 = 批准时间（同一秒，边界算已对账）" "BEGIN; UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:00' WHERE id=3100; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00'); COMMIT;" "inbound_correction_reconciled"
expect_allow "03 N4 对账时间晚批准 1 秒：仍可开更正单（已回滚）" "BEGIN; UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:01' WHERE id=3100; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00'); ROLLBACK;"
expect_block "03 对账时间回写后不能再改" "BEGIN; UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 12:00:00' WHERE id=3100; UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:00' WHERE id=3100; COMMIT;" "inbound_order_closed_immutable"
R=$(psql -t -A -c "SELECT (SELECT received_qty_milli FROM inbound_line WHERE id=3110) + (SELECT sum(direction*qty_milli) FROM inbound_correction WHERE inbound_line_id=3110)")
[ "$R" = "61500" ] && ok "03 对账：净实收 = 行实收 60 + Σ更正（+2 −1 +0.5） = $R" || bad "03 对账：净实收 = 行实收 60 + Σ更正（+2 −1 +0.5） = $R（期望 61500）"
R=$(psql -t -A -c "SELECT on_hand_qty_milli FROM stock WHERE id=3102")
[ "$R" = "31500" ] && ok "03 对账：存储位在库 30 + 1.5 = $R" || bad "03 对账：存储位在库 30 + 1.5 = $R（期望 31500）"
R=$(psql -t -A -c "SELECT sum(m.direction*m.move_qty_milli) FROM stock_movement m JOIN inbound_correction c ON c.movement_id=m.id WHERE m.biz_type='ADJUST'")
[ "$R" = "1500" ] && ok "03 对账：更正单挂的 ADJUST 流水净额 = $R" || bad "03 对账：更正单挂的 ADJUST 流水净额 = $R（期望 1500）"
R=$(psql -t -A -c "SELECT count(*) FROM outbox_event WHERE topic='wms.inbound.corrected' AND status='PENDING'")
[ "$R" = "3" ] && ok "03 对账：更正单回传 11：outbox 都是 PENDING = $R" || bad "03 对账：更正单回传 11：outbox 都是 PENDING = $R（期望 3）"
R=$(psql -t -A -c "SELECT count(*) FROM inbound_receipt WHERE id=3140 AND qty_milli=60000")
[ "$R" = "1" ] && ok "03 对账：原收货记录未被改（60 KG） = $R" || bad "03 对账：原收货记录未被改（60 KG） = $R（期望 1）"
R=$(psql -t -A -c "SELECT (SELECT putaway_qty_milli FROM inbound_line WHERE id=3110) = (SELECT sum(qty_milli) FROM inbound_putaway WHERE inbound_line_id=3110)")
[ "$R" = "t" ] && ok "03 对账：B1 行上架量 = Σ上架记录 = $R" || bad "03 对账：B1 行上架量 = Σ上架记录 = $R（期望 t）"
expect_block "03 R3 入库行 sku_id 不存在（fk_inbl_sku）" "BEGIN; INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3197,3190,9,999999,'KG'); COMMIT;" "fk_inbl_sku"
echo "=== 2j-clock. 03 时间约定：非属主写入一律改成库时钟（PG）；属主豁免见上 ==="
R=$(psql -q -t -A -c "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); SET LOCAL ROLE wms_app; INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,'2020-01-01 00:00:00'); RESET ROLE; SELECT approved_at <> '2020-01-01 00:00:00' AND abs(extract(epoch FROM approved_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 FROM inbound_correction WHERE id=3320; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 B3 wms_app 更正单 approved_at 倒签 '2020-01-01 00:00:00' → 库时钟覆盖" || bad "03 B3 wms_app 更正单 approved_at 倒签 '2020-01-01 00:00:00' → 库时钟覆盖：$R"
R=$(psql -q -t -A -c "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); SET LOCAL ROLE wms_app; INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,'2099-01-01 00:00:00'); RESET ROLE; SELECT approved_at <> '2099-01-01 00:00:00' AND abs(extract(epoch FROM approved_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 FROM inbound_correction WHERE id=3320; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 B3 wms_app 更正单 approved_at 预签 '2099-01-01 00:00:00' → 库时钟覆盖" || bad "03 B3 wms_app 更正单 approved_at 预签 '2099-01-01 00:00:00' → 库时钟覆盖：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; UPDATE inbound_order SET status='COMPLETED', closed_at='2020-01-01 00:00:00' WHERE id=3190; RESET ROLE; SELECT abs(extract(epoch FROM closed_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 FROM inbound_order WHERE id=3190; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 时间 wms_app 关单 closed_at 倒签 → 库时钟覆盖" || bad "03 时间 wms_app 关单 closed_at 倒签 → 库时钟覆盖：$R"
R=$(psql -q -t -A -c "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; SET LOCAL ROLE wms_app; UPDATE inbound_order SET supplier_reconciled_at='2099-01-01 00:00:00' WHERE id=3300; RESET ROLE; SELECT abs(extract(epoch FROM supplier_reconciled_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 FROM inbound_order WHERE id=3300; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 时间 wms_app 对账时间预签 → 库时钟覆盖" || bad "03 时间 wms_app 对账时间预签 → 库时钟覆盖：$R"
expect_block "03 B3 wms_app 倒签到对账之前也绕不过（批准时间被改成 now ≥ 对账时间）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; UPDATE inbound_order SET supplier_reconciled_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '10 minutes' WHERE id=3300; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); SET LOCAL ROLE wms_app; INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '20 minutes'); COMMIT;" "inbound_correction_reconciled"
expect_block "03 B2 更正单 requested_at 带小数秒（属主写入也拒）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300) + interval '0.5 seconds',9,NULL,date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')); COMMIT;" "ck_irc_ts"
expect_block "03 B2 关单时间带小数秒" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at='2026-10-15 01:00:00.4' WHERE id=3300; COMMIT;" "ck_inb_ts"
expect_block "03 pg_temp：wms_app 建同名临时表 inbound_order 冒充未对账（函数 search_path 末尾显式 pg_temp）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; UPDATE inbound_order SET supplier_reconciled_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '10 minutes' WHERE id=3300; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); SET LOCAL ROLE wms_app; CREATE TEMP TABLE inbound_order (id BIGINT, status VARCHAR(24), supplier_reconciled_at TIMESTAMP); INSERT INTO pg_temp.inbound_order VALUES (3300,'COMPLETED',NULL); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM public.inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM public.inbound_order WHERE id=3300),9,NULL,date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')); COMMIT;" "inbound_correction_reconciled"
expect_block "03 状态迁移：RECEIVING → CREATED（回退）" "BEGIN; UPDATE inbound_order SET status='CREATED' WHERE id=3190; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：RECEIVING → ARRIVED（回退）" "BEGIN; UPDATE inbound_order SET status='ARRIVED' WHERE id=3190; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：RECEIVED → RECEIVING（回退）" "BEGIN; UPDATE inbound_order SET status='RECEIVED' WHERE id=3190; UPDATE inbound_order SET status='RECEIVING' WHERE id=3190; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：PUTTING_AWAY → RECEIVED（回退）" "BEGIN; UPDATE inbound_order SET status='PUTTING_AWAY' WHERE id=3190; UPDATE inbound_order SET status='RECEIVED' WHERE id=3190; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：CANCELLED 终态 → RECEIVING" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date,closed_at) VALUES (3196,'INB-3196',1,'PURCHASE','ERP','PO-3196','CANCELLED','2026-10-15','2026-10-15 01:00:00'); UPDATE inbound_order SET status='RECEIVING' WHERE id=3196; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：CANCELLED 终态 → COMPLETED" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date,closed_at) VALUES (3196,'INB-3196',1,'PURCHASE','ERP','PO-3196','CANCELLED','2026-10-15','2026-10-15 01:00:00'); UPDATE inbound_order SET status='COMPLETED' WHERE id=3196; COMMIT;" "inbound_order_state_forward_only"
expect_block "03 状态迁移：COMPLETED 终态 → RECEIVING（关单守卫先拦）" "BEGIN; UPDATE inbound_order SET status='RECEIVING' WHERE id=3100; COMMIT;" "inbound_order_closed_immutable"
expect_allow "03 状态迁移：RECEIVING → RECEIVED → PUTTING_AWAY（前进）（已回滚）" "BEGIN; UPDATE inbound_order SET status='RECEIVED' WHERE id=3190; UPDATE inbound_order SET status='PUTTING_AWAY' WHERE id=3190; ROLLBACK;"
expect_block "03 created_at 建后不可改" "BEGIN; UPDATE inbound_order SET created_at='2026-10-14 00:00:00' WHERE id=3190; COMMIT;" "inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at"
expect_block "03 库写时间改成 NULL：created_at" "BEGIN; UPDATE inbound_order SET created_at=NULL WHERE id=3190; COMMIT;" "inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at"
expect_block "03 库写时间改成 NULL：已关单 closed_at（closed_at 属 (id, closed_at) 唯一键，回填后不可改）" "BEGIN; UPDATE inbound_order SET closed_at=NULL WHERE id=3100; COMMIT;" "inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE"
expect_block "03 库写时间改成 NULL：更正单 approved_at" "BEGIN; UPDATE inbound_correction SET approved_at=NULL WHERE id=3220; COMMIT;" "append_only_violation: inbound_correction"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00','2099-01-01 00:00:00'); RESET ROLE; SELECT abs(extract(epoch FROM created_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 FROM inbound_temp_check WHERE id=3306; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 created_at wms_app 预签 2099 → 库时钟 UTC" || bad "03 created_at wms_app 预签 2099 → 库时钟 UTC：$R"
R=$(psql -q -t -A -c "BEGIN; INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00','2026-10-15 01:00:00.7'); SELECT created_at FROM inbound_temp_check WHERE id=3306; ROLLBACK;" 2>&1)
[ "$R" = "2026-10-15 01:00:00" ] && ok "03 created_at 属主写小数秒 → 截到整秒" || bad "03 created_at 属主写小数秒 → 截到整秒：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL TIME ZONE 'Asia/Shanghai'; SET LOCAL ROLE wms_app; UPDATE inbound_order SET status='COMPLETED', closed_at=localtimestamp WHERE id=3190; RESET ROLE; SELECT abs(extract(epoch FROM closed_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 AND localtimestamp - closed_at > interval '7 hours 59 minutes' FROM inbound_order WHERE id=3190; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 时区：SET TIME ZONE Asia/Shanghai 后 wms_app 关单，closed_at 存 UTC（比上海本地早 8h）" || bad "03 时区：SET TIME ZONE Asia/Shanghai 后 wms_app 关单，closed_at 存 UTC（比上海本地早 8h）：$R"
R=$(psql -q -t -A -c "BEGIN; SET LOCAL TIME ZONE 'Asia/Shanghai'; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3197,'INB-3197',1,'PURCHASE','ERP','PO-3197','CREATED','2026-10-15'); SELECT abs(extract(epoch FROM created_at - date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'))) <= 1 AND localtimestamp - created_at > interval '7 hours 59 minutes' FROM inbound_order WHERE id=3197; ROLLBACK;" 2>&1)
[ "$R" = "t" ] && ok "03 时区：Asia/Shanghai 会话下属主建单，created_at 默认值存 UTC" || bad "03 时区：Asia/Shanghai 会话下属主建单，created_at 默认值存 UTC：$R"
R=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name LIKE 'inbound%' AND data_type = 'timestamp with time zone'")
[ "$R" = "0" ] && ok "03 时间列全部是 TIMESTAMP（without time zone）" || bad "03 有 timestamptz 列：$R"
expect_block "03 日期：work_date 2026-02-30" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3198,'INB-3198',1,'PURCHASE','ERP','PO-3198','CREATED','2026-02-30'); COMMIT;" "out of range"
echo "=== 2j-sp. 03 函数固定 search_path（目录断言 + 同名表劫持）==="
R=$(psql -t -A -c "SELECT string_agg(p.proname || '=' || COALESCE(array_to_string(p.proconfig, ','), 'NONE') || CASE WHEN p.prosecdef THEN '/definer' ELSE '' END, ' ' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname IN ('trg_iqf_guard','trg_inb_closed_guard','trg_inbl_closed_guard','trg_irc_guard','trg_inbp_apply','trg_inbl_counter_guard','trg_inb_time_now','trg_inb_created_now','trg_inb_forward')")
EXP03="trg_inb_closed_guard=search_path=pg_catalog, public, pg_temp trg_inb_created_now=search_path=pg_catalog, public, pg_temp trg_inb_forward=search_path=pg_catalog, public, pg_temp trg_inb_time_now=search_path=pg_catalog, public, pg_temp trg_inbl_closed_guard=search_path=pg_catalog, public, pg_temp trg_inbl_counter_guard=search_path=pg_catalog, public, pg_temp trg_inbp_apply=search_path=pg_catalog, public, pg_temp/definer trg_iqf_guard=search_path=pg_catalog, public, pg_temp trg_irc_guard=search_path=pg_catalog, public, pg_temp"
[ "$R" = "$EXP03" ] && ok "03 的 10 个 PG 函数 proconfig 均为 search_path=pg_catalog, public, pg_temp（仅 trg_inbp_apply 为 SECURITY DEFINER）" || bad "03 函数 proconfig 不符：$R"
# 劫持：rogue schema 放一张同名 inbound_order（未对账），public 里 3300 已对账。固定后 trg_irc_guard 只看 public → 拒绝；被劫持则放行。整段 ROLLBACK。
expect_block "03 trg_irc_guard 不受调用方 search_path 里的同名 inbound_order 劫持（已回滚）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15'); INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000); INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00'); INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL); INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00'); UPDATE inbound_order SET status='COMPLETED', closed_at=date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC') - interval '1 hour' WHERE id=3300; UPDATE inbound_order SET supplier_reconciled_at=(SELECT closed_at FROM inbound_order WHERE id=3300) + interval '10 minutes' WHERE id=3300; CREATE SCHEMA t03_rogue; CREATE TABLE t03_rogue.inbound_order (id BIGINT, status VARCHAR(24), supplier_reconciled_at TIMESTAMP); INSERT INTO t03_rogue.inbound_order VALUES (3300,'COMPLETED',NULL); SET LOCAL search_path = t03_rogue, public; INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL); UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4; INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL); INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP); INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING'); INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM public.inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM public.inbound_order WHERE id=3300),9,NULL,date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')); ROLLBACK;" "inbound_correction_reconciled"
[ "$(psql -t -A -c "SELECT count(*) FROM pg_namespace WHERE nspname='t03_rogue'")" = "0" ] && ok "03 劫持检查回滚后无残留 schema" || bad "t03_rogue 残留"

echo "--- 03/18 去重键不可改、计数器只增（PG） ---"
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE id IS NOT NULL; UPDATE inbound_order SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_order WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) ok "03/18 PG 改 inbound_order.id（去重键） → 拦";; *) bad "03/18 PG 改 inbound_order.id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('closed_at,source_system,source_order_no,code', 'closed_at', 'version'); UPDATE inbound_order SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_order WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) bad "03/18 PG 变异未变红：inbound_order.id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE closed_at IS NOT NULL; UPDATE inbound_order SET closed_at = closed_at + interval '1 day' WHERE ctid = (SELECT ctid FROM inbound_order WHERE closed_at IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE closed_at"*) ok "03/18 PG 改 inbound_order.closed_at（去重键） → 拦";; *) bad "03/18 PG 改 inbound_order.closed_at（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,source_system,source_order_no,code', 'closed_at', 'version'); UPDATE inbound_order SET closed_at = closed_at + interval '1 day' WHERE ctid = (SELECT ctid FROM inbound_order WHERE closed_at IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE closed_at"*) bad "03/18 PG 变异未变红：inbound_order.closed_at（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.closed_at（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE source_system IS NOT NULL; UPDATE inbound_order SET source_system = source_system || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE source_system IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE source_system"*) ok "03/18 PG 改 inbound_order.source_system（去重键） → 拦";; *) bad "03/18 PG 改 inbound_order.source_system（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,closed_at,source_order_no,code', 'closed_at', 'version'); UPDATE inbound_order SET source_system = source_system || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE source_system IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE source_system"*) bad "03/18 PG 变异未变红：inbound_order.source_system（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.source_system（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE source_order_no IS NOT NULL; UPDATE inbound_order SET source_order_no = source_order_no || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE source_order_no IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE source_order_no"*) ok "03/18 PG 改 inbound_order.source_order_no（去重键） → 拦";; *) bad "03/18 PG 改 inbound_order.source_order_no（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,closed_at,source_system,code', 'closed_at', 'version'); UPDATE inbound_order SET source_order_no = source_order_no || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE source_order_no IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE source_order_no"*) bad "03/18 PG 变异未变红：inbound_order.source_order_no（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.source_order_no（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE code IS NOT NULL; UPDATE inbound_order SET code = code || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE code IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE code"*) ok "03/18 PG 改 inbound_order.code（去重键） → 拦";; *) bad "03/18 PG 改 inbound_order.code（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,closed_at,source_system,source_order_no', 'closed_at', 'version'); UPDATE inbound_order SET code = code || '~R' WHERE ctid = (SELECT ctid FROM inbound_order WHERE code IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE code"*) bad "03/18 PG 变异未变红：inbound_order.code（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.code（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_order WHERE version IS NOT NULL; UPDATE inbound_order SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_order WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 inbound_order.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_order.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_order ON inbound_order; CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,closed_at,source_system,source_order_no,code', 'closed_at', ''); UPDATE inbound_order SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_order WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_order_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：inbound_order.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_order.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE id IS NOT NULL; UPDATE inbound_line SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) ok "03/18 PG 改 inbound_line.id（去重键） → 拦";; *) bad "03/18 PG 改 inbound_line.id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) bad "03/18 PG 变异未变红：inbound_line.id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE inbound_id IS NOT NULL; UPDATE inbound_line SET inbound_id = inbound_id + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE inbound_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE inbound_id"*) ok "03/18 PG 改 inbound_line.inbound_id（去重键） → 拦";; *) bad "03/18 PG 改 inbound_line.inbound_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET inbound_id = inbound_id + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE inbound_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE inbound_id"*) bad "03/18 PG 变异未变红：inbound_line.inbound_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.inbound_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE line_no IS NOT NULL; UPDATE inbound_line SET line_no = line_no + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE line_no IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE line_no"*) ok "03/18 PG 改 inbound_line.line_no（去重键） → 拦";; *) bad "03/18 PG 改 inbound_line.line_no（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET line_no = line_no + 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE line_no IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE line_no"*) bad "03/18 PG 变异未变红：inbound_line.line_no（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.line_no（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE received_qty_milli IS NOT NULL; UPDATE inbound_line SET received_qty_milli = received_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE received_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC received_qty_milli"*) ok "03/18 PG 改 inbound_line.received_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.received_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET received_qty_milli = received_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE received_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC received_qty_milli"*) bad "03/18 PG 变异未变红：inbound_line.received_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.received_qty_milli（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE rejected_qty_milli IS NOT NULL; UPDATE inbound_line SET rejected_qty_milli = rejected_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE rejected_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC rejected_qty_milli"*) ok "03/18 PG 改 inbound_line.rejected_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.rejected_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET rejected_qty_milli = rejected_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE rejected_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC rejected_qty_milli"*) bad "03/18 PG 变异未变红：inbound_line.rejected_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.rejected_qty_milli（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE qc_passed_qty_milli IS NOT NULL; UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE qc_passed_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC qc_passed_qty_milli"*) ok "03/18 PG 改 inbound_line.qc_passed_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.qc_passed_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE qc_passed_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC qc_passed_qty_milli"*) bad "03/18 PG 变异未变红：inbound_line.qc_passed_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.qc_passed_qty_milli（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE qc_failed_qty_milli IS NOT NULL; UPDATE inbound_line SET qc_failed_qty_milli = qc_failed_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE qc_failed_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC qc_failed_qty_milli"*) ok "03/18 PG 改 inbound_line.qc_failed_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.qc_failed_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,putaway_qty_milli,version'); UPDATE inbound_line SET qc_failed_qty_milli = qc_failed_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE qc_failed_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC qc_failed_qty_milli"*) bad "03/18 PG 变异未变红：inbound_line.qc_failed_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.qc_failed_qty_milli（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE putaway_qty_milli IS NOT NULL; UPDATE inbound_line SET putaway_qty_milli = putaway_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE putaway_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC putaway_qty_milli"*) ok "03/18 PG 改 inbound_line.putaway_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.putaway_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,version'); UPDATE inbound_line SET putaway_qty_milli = putaway_qty_milli - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE putaway_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC putaway_qty_milli"*) bad "03/18 PG 变异未变红：inbound_line.putaway_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.putaway_qty_milli（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_line WHERE version IS NOT NULL; UPDATE inbound_line SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 inbound_line.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_line.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_line ON inbound_line; CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli'); UPDATE inbound_line SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_line WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：inbound_line.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_line.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_quality_feedback WHERE id IS NOT NULL; UPDATE inbound_quality_feedback SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) ok "03/18 PG 改 inbound_quality_feedback.id（去重键） → 拦";; *) bad "03/18 PG 改 inbound_quality_feedback.id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_quality_feedback ON inbound_quality_feedback; CREATE TRIGGER trg_0keylock_inbound_quality_feedback BEFORE UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_keylock('code', '', 'version'); UPDATE inbound_quality_feedback SET id = id + 1 WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) bad "03/18 PG 变异未变红：inbound_quality_feedback.id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_quality_feedback.id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_quality_feedback WHERE code IS NOT NULL; UPDATE inbound_quality_feedback SET code = code || '~R' WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE code IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE code"*) ok "03/18 PG 改 inbound_quality_feedback.code（去重键） → 拦";; *) bad "03/18 PG 改 inbound_quality_feedback.code（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_quality_feedback ON inbound_quality_feedback; CREATE TRIGGER trg_0keylock_inbound_quality_feedback BEFORE UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_keylock('id', '', 'version'); UPDATE inbound_quality_feedback SET code = code || '~R' WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE code IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE code"*) bad "03/18 PG 变异未变红：inbound_quality_feedback.code（去重键）";; *) ok "03/18 PG 变异：守卫去掉 inbound_quality_feedback.code（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM inbound_quality_feedback WHERE version IS NOT NULL; UPDATE inbound_quality_feedback SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 inbound_quality_feedback.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 inbound_quality_feedback.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_inbound_quality_feedback ON inbound_quality_feedback; CREATE TRIGGER trg_0keylock_inbound_quality_feedback BEFORE UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,code', '', ''); UPDATE inbound_quality_feedback SET version = version - 1 WHERE ctid = (SELECT ctid FROM inbound_quality_feedback WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"inbound_quality_feedback_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：inbound_quality_feedback.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 inbound_quality_feedback.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM sku_live_param WHERE sku_id IS NOT NULL; UPDATE sku_live_param SET sku_id = sku_id + 1 WHERE ctid = (SELECT ctid FROM sku_live_param WHERE sku_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"sku_live_param_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE sku_id"*) ok "03/18 PG 改 sku_live_param.sku_id（去重键） → 拦";; *) bad "03/18 PG 改 sku_live_param.sku_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_sku_live_param ON sku_live_param; CREATE TRIGGER trg_0keylock_sku_live_param BEFORE UPDATE ON sku_live_param FOR EACH ROW EXECUTE FUNCTION trg_keylock('', '', 'version'); UPDATE sku_live_param SET sku_id = sku_id + 1 WHERE ctid = (SELECT ctid FROM sku_live_param WHERE sku_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"sku_live_param_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE sku_id"*) bad "03/18 PG 变异未变红：sku_live_param.sku_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 sku_live_param.sku_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM sku_live_param WHERE version IS NOT NULL; UPDATE sku_live_param SET version = version - 1 WHERE ctid = (SELECT ctid FROM sku_live_param WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"sku_live_param_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 sku_live_param.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 sku_live_param.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_sku_live_param ON sku_live_param; CREATE TRIGGER trg_0keylock_sku_live_param BEFORE UPDATE ON sku_live_param FOR EACH ROW EXECUTE FUNCTION trg_keylock('sku_id', '', ''); UPDATE sku_live_param SET version = version - 1 WHERE ctid = (SELECT ctid FROM sku_live_param WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"sku_live_param_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：sku_live_param.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 sku_live_param.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_tank WHERE location_id IS NOT NULL; UPDATE live_tank SET location_id = location_id + 1 WHERE ctid = (SELECT ctid FROM live_tank WHERE location_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE location_id"*) ok "03/18 PG 改 live_tank.location_id（去重键） → 拦";; *) bad "03/18 PG 改 live_tank.location_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_tank ON live_tank; CREATE TRIGGER trg_0keylock_live_tank BEFORE UPDATE ON live_tank FOR EACH ROW EXECUTE FUNCTION trg_keylock('', '', 'version'); UPDATE live_tank SET location_id = location_id + 1 WHERE ctid = (SELECT ctid FROM live_tank WHERE location_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE location_id"*) bad "03/18 PG 变异未变红：live_tank.location_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_tank.location_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_tank WHERE version IS NOT NULL; UPDATE live_tank SET version = version - 1 WHERE ctid = (SELECT ctid FROM live_tank WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 live_tank.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 live_tank.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_tank ON live_tank; CREATE TRIGGER trg_0keylock_live_tank BEFORE UPDATE ON live_tank FOR EACH ROW EXECUTE FUNCTION trg_keylock('location_id', '', ''); UPDATE live_tank SET version = version - 1 WHERE ctid = (SELECT ctid FROM live_tank WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：live_tank.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 live_tank.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_stock_count WHERE stock_id IS NOT NULL; UPDATE live_stock_count SET stock_id = stock_id + 1 WHERE ctid = (SELECT ctid FROM live_stock_count WHERE stock_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_stock_count_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE stock_id"*) ok "03/18 PG 改 live_stock_count.stock_id（去重键） → 拦";; *) bad "03/18 PG 改 live_stock_count.stock_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_stock_count ON live_stock_count; CREATE TRIGGER trg_0keylock_live_stock_count BEFORE UPDATE ON live_stock_count FOR EACH ROW EXECUTE FUNCTION trg_keylock('', '', 'version'); UPDATE live_stock_count SET stock_id = stock_id + 1 WHERE ctid = (SELECT ctid FROM live_stock_count WHERE stock_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_stock_count_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE stock_id"*) bad "03/18 PG 变异未变红：live_stock_count.stock_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_stock_count.stock_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_stock_count WHERE version IS NOT NULL; UPDATE live_stock_count SET version = version - 1 WHERE ctid = (SELECT ctid FROM live_stock_count WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_stock_count_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) ok "03/18 PG 改 live_stock_count.version（计数器 −1） → 拦";; *) bad "03/18 PG 改 live_stock_count.version（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_stock_count ON live_stock_count; CREATE TRIGGER trg_0keylock_live_stock_count BEFORE UPDATE ON live_stock_count FOR EACH ROW EXECUTE FUNCTION trg_keylock('stock_id', '', ''); UPDATE live_stock_count SET version = version - 1 WHERE ctid = (SELECT ctid FROM live_stock_count WHERE version IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_stock_count_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC version"*) bad "03/18 PG 变异未变红：live_stock_count.version（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 live_stock_count.version（计数器 −1） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_tank_hold WHERE id IS NOT NULL; UPDATE live_tank_hold SET id = id + 1 WHERE ctid = (SELECT ctid FROM live_tank_hold WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) ok "03/18 PG 改 live_tank_hold.id（去重键） → 拦";; *) bad "03/18 PG 改 live_tank_hold.id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_tank_hold ON live_tank_hold; CREATE TRIGGER trg_0keylock_live_tank_hold BEFORE UPDATE ON live_tank_hold FOR EACH ROW EXECUTE FUNCTION trg_keylock('location_id', '', ''); UPDATE live_tank_hold SET id = id + 1 WHERE ctid = (SELECT ctid FROM live_tank_hold WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) bad "03/18 PG 变异未变红：live_tank_hold.id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_tank_hold.id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_tank_hold WHERE location_id IS NOT NULL; UPDATE live_tank_hold SET location_id = location_id + 1 WHERE ctid = (SELECT ctid FROM live_tank_hold WHERE location_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE location_id"*) ok "03/18 PG 改 live_tank_hold.location_id（去重键） → 拦";; *) bad "03/18 PG 改 live_tank_hold.location_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_tank_hold ON live_tank_hold; CREATE TRIGGER trg_0keylock_live_tank_hold BEFORE UPDATE ON live_tank_hold FOR EACH ROW EXECUTE FUNCTION trg_keylock('id', '', ''); UPDATE live_tank_hold SET location_id = location_id + 1 WHERE ctid = (SELECT ctid FROM live_tank_hold WHERE location_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE location_id"*) bad "03/18 PG 变异未变红：live_tank_hold.location_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_tank_hold.location_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_death WHERE id IS NOT NULL; UPDATE live_death SET id = id + 1 WHERE ctid = (SELECT ctid FROM live_death WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) ok "03/18 PG 改 live_death.id（去重键） → 拦";; *) bad "03/18 PG 改 live_death.id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_death ON live_death; CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('movement_id,device_instance_id,client_op_id', 'movement_id', 'deducted_qty_milli'); UPDATE live_death SET id = id + 1 WHERE ctid = (SELECT ctid FROM live_death WHERE id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE id"*) bad "03/18 PG 变异未变红：live_death.id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_death.id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_death WHERE movement_id IS NOT NULL; UPDATE live_death SET movement_id = movement_id + 1 WHERE ctid = (SELECT ctid FROM live_death WHERE movement_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE movement_id"*) ok "03/18 PG 改 live_death.movement_id（去重键） → 拦";; *) bad "03/18 PG 改 live_death.movement_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_death ON live_death; CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,device_instance_id,client_op_id', 'movement_id', 'deducted_qty_milli'); UPDATE live_death SET movement_id = movement_id + 1 WHERE ctid = (SELECT ctid FROM live_death WHERE movement_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE movement_id"*) bad "03/18 PG 变异未变红：live_death.movement_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_death.movement_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_death WHERE device_instance_id IS NOT NULL; UPDATE live_death SET device_instance_id = device_instance_id || '~R' WHERE ctid = (SELECT ctid FROM live_death WHERE device_instance_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE device_instance_id"*) ok "03/18 PG 改 live_death.device_instance_id（去重键） → 拦";; *) bad "03/18 PG 改 live_death.device_instance_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_death ON live_death; CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,movement_id,client_op_id', 'movement_id', 'deducted_qty_milli'); UPDATE live_death SET device_instance_id = device_instance_id || '~R' WHERE ctid = (SELECT ctid FROM live_death WHERE device_instance_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE device_instance_id"*) bad "03/18 PG 变异未变红：live_death.device_instance_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_death.device_instance_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_death WHERE client_op_id IS NOT NULL; UPDATE live_death SET client_op_id = client_op_id || '~R' WHERE ctid = (SELECT ctid FROM live_death WHERE client_op_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE client_op_id"*) ok "03/18 PG 改 live_death.client_op_id（去重键） → 拦";; *) bad "03/18 PG 改 live_death.client_op_id（去重键） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_death ON live_death; CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,movement_id,device_instance_id', 'movement_id', 'deducted_qty_milli'); UPDATE live_death SET client_op_id = client_op_id || '~R' WHERE ctid = (SELECT ctid FROM live_death WHERE client_op_id IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE client_op_id"*) bad "03/18 PG 变异未变红：live_death.client_op_id（去重键）";; *) ok "03/18 PG 变异：守卫去掉 live_death.client_op_id（去重键） → 变红";; esac
R=$(psql -q -t -A -c "BEGIN; SELECT 'N=' || count(*) FROM live_death WHERE deducted_qty_milli IS NOT NULL; UPDATE live_death SET deducted_qty_milli = deducted_qty_milli - 1 WHERE ctid = (SELECT ctid FROM live_death WHERE deducted_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC deducted_qty_milli"*) ok "03/18 PG 改 live_death.deducted_qty_milli（计数器 −1） → 拦";; *) bad "03/18 PG 改 live_death.deducted_qty_milli（计数器 −1） 未拦：$R";; esac
R=$(psql -q -t -A -c "BEGIN; DROP TRIGGER trg_0keylock_live_death ON live_death; CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,movement_id,device_instance_id,client_op_id', 'movement_id', ''); UPDATE live_death SET deducted_qty_milli = deducted_qty_milli - 1 WHERE ctid = (SELECT ctid FROM live_death WHERE deducted_qty_milli IS NOT NULL LIMIT 1); ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"live_death_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC deducted_qty_milli"*) bad "03/18 PG 变异未变红：live_death.deducted_qty_milli（计数器 −1）";; *) ok "03/18 PG 变异：守卫去掉 live_death.deducted_qty_milli（计数器 −1） → 变红";; esac
echo "--- 03 / 18 冻结基线（PG）：本篇触发器与索引一个都不能少 ---"
R=$(psql -q -t -A -c "SELECT COALESCE(string_agg(n, ' ' ORDER BY n), '') FROM ((SELECT unnest(ARRAY['trg_0keylock_inbound_line','trg_0keylock_inbound_order','trg_0keylock_inbound_quality_feedback','trg_inb_closed_guard','trg_inb_created_now','trg_inb_forward','trg_inb_time_now','trg_inbl_closed_guard','trg_inbl_counter_guard','trg_inbp_append_only','trg_inbp_apply','trg_inbp_created_now','trg_inbp_no_truncate','trg_iqf_created_now','trg_iqf_forward','trg_iqf_guard','trg_irc_append_only','trg_irc_created_now','trg_irc_guard','trg_irc_no_truncate','trg_itc_append_only','trg_itc_created_now','trg_itc_no_truncate','trg_rcp_append_only','trg_rcp_created_now','trg_rcp_no_truncate']) n EXCEPT SELECT tgname::text FROM pg_trigger WHERE NOT tgisinternal) UNION ALL (SELECT unnest(ARRAY['ix_inb_wh_status','ix_inbl_sku','ix_inbp_line','ix_inbp_rcp','ix_iqf_line','ix_iqf_open','ix_irc_line','ix_itc_order','ix_rcp_line']) EXCEPT SELECT indexname::text FROM pg_indexes WHERE schemaname='public')) x" 2>&1)
[ -z "$R" ] && ok "03 冻结基线：PG 触发器 26 + 索引 9 全在" || bad "03 冻结基线缺：$R"
R=$(psql -q -t -A -c "BEGIN; DROP INDEX ix_inb_wh_status; SELECT COALESCE(string_agg(n, ' ' ORDER BY n), '') FROM ((SELECT unnest(ARRAY['trg_0keylock_inbound_line','trg_0keylock_inbound_order','trg_0keylock_inbound_quality_feedback','trg_inb_closed_guard','trg_inb_created_now','trg_inb_forward','trg_inb_time_now','trg_inbl_closed_guard','trg_inbl_counter_guard','trg_inbp_append_only','trg_inbp_apply','trg_inbp_created_now','trg_inbp_no_truncate','trg_iqf_created_now','trg_iqf_forward','trg_iqf_guard','trg_irc_append_only','trg_irc_created_now','trg_irc_guard','trg_irc_no_truncate','trg_itc_append_only','trg_itc_created_now','trg_itc_no_truncate','trg_rcp_append_only','trg_rcp_created_now','trg_rcp_no_truncate']) n EXCEPT SELECT tgname::text FROM pg_trigger WHERE NOT tgisinternal) UNION ALL (SELECT unnest(ARRAY['ix_inb_wh_status','ix_inbl_sku','ix_inbp_line','ix_inbp_rcp','ix_iqf_line','ix_iqf_open','ix_irc_line','ix_itc_order','ix_rcp_line']) EXCEPT SELECT indexname::text FROM pg_indexes WHERE schemaname='public')) x; ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"ix_inb_wh_status"*) ok "03 变异（PG）：DROP INDEX ix_inb_wh_status → 冻结基线断言变红";; *) bad "03 PG 冻结基线变异未变红：$R";; esac
R=$(psql -q -t -A -c "SELECT COALESCE(string_agg(n, ' ' ORDER BY n), '') FROM ((SELECT unnest(ARRAY['trg_0keylock_live_death','trg_0keylock_live_stock_count','trg_0keylock_live_tank','trg_0keylock_live_tank_hold','trg_0keylock_sku_live_param','trg_lcl_append_only','trg_lcl_no_truncate','trg_ld_append_only','trg_ld_no_truncate','trg_ld_zclock','trg_li_append_only','trg_li_no_truncate','trg_li_zclock','trg_lsc_guard','trg_lsc_no_truncate','trg_lss_append_only','trg_lss_no_truncate','trg_lt_guard','trg_lt_no_truncate','trg_lt_type','trg_lth_guard','trg_lth_no_truncate','trg_lth_zclock','trg_lw_append_only','trg_lw_no_truncate','trg_lw_zclock','trg_slp_guard','trg_slp_no_truncate']) n EXCEPT SELECT tgname::text FROM pg_trigger WHERE NOT tgisinternal) UNION ALL (SELECT unnest(ARRAY['ix_ld_pending','ix_ld_tank_day','ix_li_tank','uq_lth_active','uq_lw_key']) EXCEPT SELECT indexname::text FROM pg_indexes WHERE schemaname='public')) x" 2>&1)
[ -z "$R" ] && ok "18 冻结基线：PG 触发器 28 + 索引 5 全在" || bad "18 冻结基线缺：$R"
R=$(psql -q -t -A -c "BEGIN; DROP INDEX ix_ld_pending; SELECT COALESCE(string_agg(n, ' ' ORDER BY n), '') FROM ((SELECT unnest(ARRAY['trg_0keylock_live_death','trg_0keylock_live_stock_count','trg_0keylock_live_tank','trg_0keylock_live_tank_hold','trg_0keylock_sku_live_param','trg_lcl_append_only','trg_lcl_no_truncate','trg_ld_append_only','trg_ld_no_truncate','trg_ld_zclock','trg_li_append_only','trg_li_no_truncate','trg_li_zclock','trg_lsc_guard','trg_lsc_no_truncate','trg_lss_append_only','trg_lss_no_truncate','trg_lt_guard','trg_lt_no_truncate','trg_lt_type','trg_lth_guard','trg_lth_no_truncate','trg_lth_zclock','trg_lw_append_only','trg_lw_no_truncate','trg_lw_zclock','trg_slp_guard','trg_slp_no_truncate']) n EXCEPT SELECT tgname::text FROM pg_trigger WHERE NOT tgisinternal) UNION ALL (SELECT unnest(ARRAY['ix_ld_pending','ix_ld_tank_day','ix_li_tank','uq_lth_active','uq_lw_key']) EXCEPT SELECT indexname::text FROM pg_indexes WHERE schemaname='public')) x; ROLLBACK;" 2>&1 | tr -d '\n')
case "$R" in *"ix_ld_pending"*) ok "18 变异（PG）：DROP INDEX ix_ld_pending → 冻结基线断言变红";; *) bad "18 PG 冻结基线变异未变红：$R";; esac
echo "=== 2g-t. 第 12 篇时间加固（自查 B2/B3）+ fk_udb_approval + device_reconnect + 第 3 篇审批类型（PG；非属主写入由库覆盖、属主豁免）==="
H12=$(printf 'a%.0s' $(seq 64))
APR12="INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at"
q1() { psql -t -A -q -c "$1"; }
# 时区用例：会话 Asia/Shanghai + wms_app，调用方填 created_at=2000、不传 expires_at → 库写 UTC 整秒，补 created_at + 2h
R=$(psql -t -A <<TZSQL | grep '^TZ#'
SET TIME ZONE 'Asia/Shanghai';
SET ROLE wms_app;
$APR12,created_at) VALUES (1201,'APR-WHSH01-20261015-001201','CANCEL_AFTER_PICK',1,'OUTBOUND','1201','{}','$H12','r',201,NULL,'2000-01-01 00:00:00');
RESET ROLE;
SELECT 'TZ#' || (abs(extract(epoch FROM created_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND created_at = date_trunc('second', created_at))::text || '#' || extract(epoch FROM expires_at - created_at)::bigint FROM approval_request WHERE id=1201;
TZSQL
)
IFS='#' read -r _ T1 T2 <<< "$R"
[ "$T1" = "true" ] && ok "12 B3-1 会话 Asia/Shanghai + wms_app 填 created_at=2000：库改写成 UTC 整秒的当前时间（不是 +8h）" || bad "12 B3-1 created_at 不是库时钟 UTC 整秒：$R"
[ "$T2" = "7200" ] && ok "12 B3-1 拣后取消不传 expires_at：库补 created_at + 2h（$T2 s）" || bad "12 B3-1 expires_at 补算 = $T2（期望 7200）"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_apr_zclock ON approval_request;
SET LOCAL ROLE wms_app;
DO $m$ BEGIN INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at,created_at) VALUES (1299,'APR-WHSH01-20261015-001299','POD_CORRECT',1,'POD','1299','{}',repeat('a',64),'r',201,'2000-01-01 12:00:00','2000-01-01 00:00:00'); PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_apr_zclock 后 wms_app 写入 created_at=2000 的审批成功（B3-1 断言能抓到）" || bad "变异没变红：去掉 trg_apr_zclock 后仍是 $R"
expect_block "12 B3-1 wms_app 审批 expires_at=2999（永不过期）" "SET ROLE wms_app; $APR12) VALUES (1202,'APR-WHSH01-20261015-001202','POD_CORRECT',1,'POD','1202','{}','$H12','r',201,'2999-01-01 00:00:00');" "ck_apr_ttl"
expect_block "12 B3-1 属主审批 expires_at = created_at + 24h + 1s" "$APR12,created_at) VALUES (1202,'APR-WHSH01-20261015-001202','POD_CORRECT',1,'POD','1202','{}','$H12','r',201,'2026-10-16 00:00:01','2026-10-15 00:00:00');" "ck_apr_ttl"
expect_block "12 B3-1 拣后取消 expires_at 超 2h 上限" "SET ROLE wms_app; $APR12) VALUES (1202,'APR-WHSH01-20261015-001202','CANCEL_AFTER_PICK',1,'OUTBOUND','1202','{}','$H12','r',201,date_trunc('second', now() AT TIME ZONE 'UTC') + interval '2 hours 1 second');" "ck_apr_ttl"
expect_block "12 审批 expires_at 小数秒" "$APR12) VALUES (1202,'APR-WHSH01-20261015-001202','POD_CORRECT',1,'POD','1202','{}','$H12','r',201,date_trunc('second', now() AT TIME ZONE 'UTC') + interval '1 hour 0.5 second');" "ck_apr_ts"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
ALTER TABLE approval_request DROP CONSTRAINT ck_apr_ttl;
SET LOCAL ROLE wms_app;
DO $m$ BEGIN INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1299,'APR-WHSH01-20261015-001299','POD_CORRECT',1,'POD','1299','{}',repeat('a',64),'r',201,'2999-01-01 00:00:00'); PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 ck_apr_ttl 后 expires_at=2999 的审批写入成功" || bad "变异没变红：去掉 ck_apr_ttl 后仍是 $R"
expect_allow "12 §6.8-6 正向：wms_app 缩短有效期（+60 s）" "SET ROLE wms_app; $APR12) VALUES (1202,'APR-WHSH01-20261015-001202','POD_CORRECT',1,'POD','1202','{}','$H12','r',201,date_trunc('second', now() AT TIME ZONE 'UTC') + interval '60 seconds');"
expect_block "12 属主把审批 expires_at 改成 NULL" "UPDATE approval_request SET expires_at=NULL WHERE id=1202;" "approval_final"
R=$(q1 "SELECT attnotnull FROM pg_attribute WHERE attrelid='approval_request'::regclass AND attname='expires_at'")
[ "$R" = "t" ] && ok "12 approval_request.expires_at NOT NULL（库补算在 BEFORE 触发器里）" || bad "12 expires_at NOT NULL = $R"
# B3-2：wms_app 审批时填 1999，落库是库时钟
psql -q -c "SET ROLE wms_app; UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='1999-01-01 00:00:00', decided_at='1999-01-01 00:00:00' WHERE id=1202;" >/dev/null 2>&1
R=$(q1 "SELECT status || '#' || (abs(extract(epoch FROM first_approved_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text || '#' || (abs(extract(epoch FROM decided_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM approval_request WHERE id=1202")
[ "$R" = "APPROVED#true#true" ] && ok "12 B3-2 wms_app 填 first_approved_at/decided_at=1999：落库为库时钟（$R）" || bad "12 B3-2 审批时间没被库覆盖：$R"
psql -q -c "$APR12) VALUES (1203,'APR-WHSH01-20261015-001203','POD_CORRECT',1,'POD','1203','{}','$H12','r',201,NULL);" >/dev/null
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_apr_zclock ON approval_request;
SET LOCAL ROLE wms_app;
UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='1999-01-01 00:00:00', decided_at='1999-01-01 00:00:00' WHERE id=1203;
SELECT 'MUT#' || first_approved_at::text FROM approval_request WHERE id=1203;
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#1999-01-01 00:00:00" ] && ok "变异：去掉 trg_apr_zclock 后 wms_app 审批时间 1999 原样落库" || bad "变异没变红：$R"
# 第 3 篇审批类型
seed "INSERT INTO sys_permission (id,code,name,module) VALUES (1231,'inbound.receipt.adjust.approve','收货更正审批','03'),(1232,'inbound.sod.waive','收货上架职责分离放宽','03');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,1231),(1,1232);"
seed "$APR12) VALUES (1211,'APR-WHSH01-20261015-001211','INBOUND_CORRECTION',1,'INBOUND_RECEIPT','1211','{}','$H12','r',201,NULL),(1212,'APR-WHSH01-20261015-001212','INBOUND_SOD_WAIVER',1,'INBOUND_ORDER','1212','{}','$H12','r',201,NULL);"
for P in 1211:INBOUND_CORRECTION 1212:INBOUND_SOD_WAIVER; do
  I=${P%%:*}; T=${P#*:}
  APP="UPDATE approval_request SET status='APPROVED', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00'"
  expect_block "12 $T：质检主管 205 无审批权限点" "$APP, first_approver_id=205, first_approver_role='QC_SUPERVISOR' WHERE id=$I;" "approval_perm_not_held"
  expect_block "12 $T：申请人 201 自批" "$APP, first_approver_id=201, first_approver_role='WH_SUPERVISOR' WHERE id=$I;" "ck_apr_sod"
  expect_allow "12 $T 正向：本仓主管 202 审批" "$APP, first_approver_id=202, first_approver_role='WH_SUPERVISOR' WHERE id=$I;"
done
# B3-4 绑定 + fk_udb_approval + user_device_binding_time_immutable
psql -q -c "SET ROLE wms_app; INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,bound_at) VALUES (1201,'DEV-T1','PDA',101,1,'2000-01-01 00:00:00');" >/dev/null 2>&1
R=$(q1 "SELECT (abs(extract(epoch FROM bound_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM user_device_binding WHERE id=1201")
[ "$R" = "true" ] && ok "12 B3-4 wms_app 填 bound_at=2000：落库为库时钟" || bad "12 B3-4 bound_at 没被覆盖：$R"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_udb_zclock ON user_device_binding;
SET LOCAL ROLE wms_app;
INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,bound_at) VALUES (1299,'DEV-T9','PDA',101,1,'2000-01-01 00:00:00');
SELECT 'MUT#' || bound_at::text FROM user_device_binding WHERE id=1299;
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#2000-01-01 00:00:00" ] && ok "变异：去掉 trg_udb_zclock 后 bound_at=2000 原样落库" || bad "变异没变红：$R"
expect_block "12 FK：吊销时挂不存在的审批 999999（触发器都放行，只有 fk_udb_approval 能拦）" "UPDATE user_device_binding SET status='REVOKED', revoked_at='2026-10-15 10:00:00', revoke_reason='LOST', approval_id=999999 WHERE id=1201;" "fk_udb_approval"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
ALTER TABLE user_device_binding DROP CONSTRAINT fk_udb_approval;
DO $m$ BEGIN UPDATE user_device_binding SET status='REVOKED', revoked_at='2026-10-15 10:00:00', revoke_reason='LOST', approval_id=999999 WHERE id=1201; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 fk_udb_approval 后挂不存在的审批成功" || bad "变异没变红：$R"
psql -q -c "SET ROLE wms_app; UPDATE user_device_binding SET status='REVOKED', revoked_at='2000-01-01 00:00:00', revoke_reason='LOST' WHERE id=1201;" >/dev/null 2>&1
R=$(q1 "SELECT status || '#' || (abs(extract(epoch FROM revoked_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM user_device_binding WHERE id=1201")
[ "$R" = "REVOKED#true" ] && ok "12 B3-4 wms_app 吊销填 revoked_at=2000：落库为库时钟（$R）" || bad "12 B3-4 revoked_at：$R"
seed "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1202,'DEV-T2','PDA',101,1);"
seed "$APR12) VALUES (1221,'APR-WHSH01-20261015-001221','DEVICE_BIND',1,'DEVICE_BINDING','1202','{}','$H12','r',201,NULL);"
seed "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1221;"
psql -q -c "SET ROLE wms_app; UPDATE user_device_binding SET status='ACTIVE', approval_id=1221, activated_at='2000-01-01 00:00:00' WHERE id=1202;" >/dev/null 2>&1
R=$(q1 "SELECT status || '#' || (abs(extract(epoch FROM activated_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM user_device_binding WHERE id=1202")
[ "$R" = "ACTIVE#true" ] && ok "12 B3-4 wms_app 激活填 activated_at=2000：落库为库时钟（$R）" || bad "12 B3-4 activated_at：$R"
expect_block "12 激活后改 activated_at（属主也不行）" "UPDATE user_device_binding SET activated_at='2026-01-01 00:00:00' WHERE id=1202;" "user_device_binding_time_immutable"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_udb_zclock ON user_device_binding;
DO $m$ BEGIN UPDATE user_device_binding SET activated_at='2026-01-01 00:00:00' WHERE id=1202; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_udb_zclock 后激活时间可改" || bad "变异没变红：$R"
# B3-3 离线令牌
OT12="INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES"
expect_block "12 B3-3 wms_app 签发 issued_at=2030、expires=2030+12h（库把 issued_at 改成 now，超 12h 上限）" "SET ROLE wms_app; $OT12 (1201,'J1201',1202,101,'DEV-T2',1,1,'2030-01-01 00:00:00','2030-01-01 12:00:00');" "ck_offline_max_ttl"
psql -q -c "SET ROLE wms_app; $OT12 (1201,'J1201',1202,101,'DEV-T2',1,1,'2030-01-01 00:00:00',date_trunc('second', now() AT TIME ZONE 'UTC') + interval '1 hour');" >/dev/null 2>&1
R=$(q1 "SELECT (abs(extract(epoch FROM issued_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM offline_token WHERE id=1201")
[ "$R" = "true" ] && ok "12 B3-3 wms_app 填 issued_at=2030：落库为库时钟" || bad "12 B3-3 issued_at：$R"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_offline_zclock ON offline_token;
SET LOCAL ROLE wms_app;
INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1299,'J1299',1202,101,'DEV-T2',1,1,'2030-01-01 00:00:00','2030-01-01 12:00:00');
SELECT 'MUT#' || issued_at::text FROM offline_token WHERE id=1299;
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#2030-01-01 00:00:00" ] && ok "变异：去掉 trg_offline_zclock 后 issued_at=2030 原样落库" || bad "变异没变红：$R"
# device_reconnect
DR12="INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti,occurred_at) VALUES"
psql -q -c "SET ROLE wms_app; $DR12 (1201,1,1202,'J1201','2000-01-01 00:00:00');" >/dev/null 2>&1
R=$(q1 "SELECT (abs(extract(epoch FROM occurred_at - (now() AT TIME ZONE 'UTC'))) <= 5 AND occurred_at = date_trunc('second', occurred_at))::text FROM device_reconnect WHERE id=1201")
[ "$R" = "true" ] && ok "12 device_reconnect wms_app 填 occurred_at=2000：落库为库时钟 UTC 整秒" || bad "12 device_reconnect occurred_at：$R"
expect_allow "12 device_reconnect 正向：没有离线令牌" "SET ROLE wms_app; $DR12 (1202,1,1202,NULL,DEFAULT);"
expect_block "12 device_reconnect 用别的绑定的离线令牌 J1" "SET ROLE wms_app; $DR12 (1203,1,1202,'J1',DEFAULT);" "device_reconnect_binding_mismatch"
expect_block "12 device_reconnect 仓不一致" "SET ROLE wms_app; $DR12 (1203,2,1202,NULL,DEFAULT);" "device_reconnect_binding_mismatch"
expect_block "12 device_reconnect 绑定不存在" "SET ROLE wms_app; $DR12 (1203,1,999999,NULL,DEFAULT);" "device_reconnect_binding_mismatch"
expect_block "12 device_reconnect 只追加（属主 UPDATE）" "UPDATE device_reconnect SET occurred_at='2000-01-01 00:00:00' WHERE id=1201;" "append_only_violation: device_reconnect"
expect_block "12 device_reconnect 只追加（属主 DELETE）" "DELETE FROM device_reconnect WHERE id=1201;" "append_only_violation: device_reconnect"
expect_block "12 device_reconnect 只追加（TRUNCATE）" "TRUNCATE device_reconnect;" "append_only_violation: device_reconnect"
expect_block "12 device_reconnect wms_app 不能 UPDATE（无授权）" "SET ROLE wms_app; UPDATE device_reconnect SET offline_jti=NULL WHERE id=1201;" "permission denied for table device_reconnect"
expect_block "12 device_reconnect 同 id 重复" "SET ROLE wms_app; $DR12 (1201,1,1202,NULL,DEFAULT);" "device_reconnect_pkey"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_drc_append_only ON device_reconnect;
DO $m$ BEGIN UPDATE device_reconnect SET occurred_at='2000-01-01 00:00:00' WHERE id=1201; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_drc_append_only 后属主可改 occurred_at" || bad "变异没变红：$R"
# pg_temp 劫持（00 §6.9）：wms_app 建同名临时表 user_device_binding，把绑定 1202 伪造成仓 2；fixed 必须仍按 public 真表拒，去掉 pg_temp 的变异必须放行
R=$(psql -q -t -A <<'PTSQL' | grep '^PT#'
BEGIN;
SET LOCAL ROLE wms_app;
CREATE TEMP TABLE user_device_binding (id BIGINT, warehouse_id BIGINT) ON COMMIT DROP;
INSERT INTO pg_temp.user_device_binding VALUES (1202, 2);
SET LOCAL search_path = public;
CREATE FUNCTION pg_temp.pt_try(q text, k text) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'PT_PASSED'; EXCEPTION WHEN OTHERS THEN PERFORM set_config(k, SQLERRM, true); END; END $f$;
SELECT pg_temp.pt_try($q$INSERT INTO public.device_reconnect (id,warehouse_id,binding_id) VALUES (1290,2,1202)$q$, 'pt.a0');
RESET ROLE;
ALTER FUNCTION public.trg_drc_guard() SET search_path = pg_catalog, public;
SET LOCAL ROLE wms_app;
SET LOCAL search_path = public;
SELECT pg_temp.pt_try($q$INSERT INTO public.device_reconnect (id,warehouse_id,binding_id) VALUES (1290,2,1202)$q$, 'pt.a1');
RESET ROLE;
SELECT 'PT#' || current_setting('pt.a0') || '#' || current_setting('pt.a1');
ROLLBACK;
PTSQL
)
IFS='#' read -r _ A0 A1 <<< "$R"
[ "$A0" = "device_reconnect_binding_mismatch" ] && ok "pg_temp 劫持 12 trg_drc_guard：wms_app 临时表 user_device_binding 把绑定伪造成仓 2，函数仍读 public → $A0" || bad "12 trg_drc_guard pg_temp 劫持：$A0"
[ "$A1" != "$A0" ] && ok "变异：trg_drc_guard 去掉 pg_temp 后临时表劫持生效（$A1）" || bad "变异没变红：trg_drc_guard 去掉 pg_temp 后仍是 $A1"
R=$(q1 "SELECT count(*) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('trg_apr_zclock','trg_udb_zclock','trg_offline_zclock','trg_drc_guard') AND 'search_path=pg_catalog, public, pg_temp' = ANY(p.proconfig)")
[ "$R" = "4" ] && ok "12 新增 4 个函数 search_path = pg_catalog, public, pg_temp（$R/4）" || bad "12 新函数 search_path 合规 $R/4"
echo "=== 2g-k. 第 12 篇键列不可改 + 计数器只增（PG；no-REPLACE 是 SQLite 专属，PG 用 ON CONFLICT 不删行）==="
seed "INSERT INTO sys_user (id,username,password_hash) VALUES (1301,'u1301','x'),(1305,'u1305','x'); INSERT INTO sys_role (id,code,name) VALUES (1301,'R1301','r'); INSERT INTO sys_permission (id,code,name,module) VALUES (1301,'p.1301','p','12'); INSERT INTO sys_user_role VALUES (1301,1301); INSERT INTO sys_role_perm VALUES (1301,1301); INSERT INTO sys_user_warehouse VALUES (1301,1); INSERT INTO api_credential (id,api_key,secret_encrypted,source_system) VALUES (1301,'K1301','s','ERP');"
seed "$APR12) VALUES (1301,'APR-WHSH01-20261015-001301','POD_CORRECT',1,'POD','1301','{}','$H12','r',201,NULL); INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1301,'DEV-R1','PDA',101,1); INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1301,'J1301',1202,101,'DEV-T2',1,1,date_trunc('second', now() AT TIME ZONE 'UTC'),date_trunc('second', now() AT TIME ZONE 'UTC') + interval '1 hour');"
for SPEC in "sys_user|id=1301|id=1399|username='u1399'" "approval_request|id=1301|id=1399|code='APR-X'|approval_type='DEVICE_BIND'|target_type='X'|target_id='9'" "user_device_binding|id=1301|id=1399|device_instance_id='DEV-R8'" "offline_token|id=1301|id=1399|jti='J1399'" "sys_role|id=1301|id=1399|code='R1399'" "sys_permission|id=1301|id=1399|code='p.1399'" "sys_user_role|user_id=1301|user_id=102|role_id=1" "sys_role_perm|role_id=1301|role_id=1|perm_id=1231" "sys_user_warehouse|user_id=1301|user_id=102|warehouse_id=2" "api_credential|id=1301|id=1399|api_key='K1399'"; do
  IFS='|' read -r TB W REST <<< "$SPEC"; IFS='|' read -r -a SETS <<< "$REST"
  for S in "${SETS[@]}"; do case $TB in approval_request|user_device_binding|offline_token|sys_user_role|sys_role_perm|sys_user_warehouse) AS="";; *) AS="SET ROLE wms_app; ";; esac; expect_block "12 键列不可改（${AS:+wms_app}${AS:-属主；wms_app 列级无 UPDATE 授权}）：$TB.$S" "${AS}UPDATE $TB SET $S WHERE $W;" "${TB}_key_immutable"; done
  LAST=${SETS[-1]}
  R=$(psql -t -A <<MUTSQL | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_0_key_lock ON $TB;
DROP TRIGGER IF EXISTS trg_apr_final ON approval_request; DROP TRIGGER IF EXISTS trg_udb_guard ON user_device_binding; DROP TRIGGER IF EXISTS trg_offline_guard ON offline_token;
DO \$m\$ BEGIN UPDATE $TB SET $LAST WHERE $W; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END \$m\$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
  [ "$R" = "MUT#PASSED" ] && ok "变异：去掉 $TB 的 trg_0_key_lock（及该表原有守卫）后改 $TB.${LAST%%=*} 成功" || bad "变异没变红：$TB key_lock 去掉后仍是 $R"
done
expect_allow "12 计数器正向：approval_request.version +1" "UPDATE approval_request SET version=version+1 WHERE id=1301;"
expect_block "12 计数器只增：approval_request.version 回退" "UPDATE approval_request SET version=version-1 WHERE id=1301;" "approval_request_version_regress"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_apr_version ON approval_request;
DO $m$ BEGIN UPDATE approval_request SET version=version-1 WHERE id=1301; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_apr_version 后 version 回退成功" || bad "变异没变红：$R"
echo "=== 2g-u. 第 12 篇用户停用 + 权限映射只经 SECURITY DEFINER 函数（PG；调用人取自会话、审计 id / node_seq 库分配、审计单次消费）==="
seed "INSERT INTO sys_permission (id,code,name,module) VALUES (1311,'sys.user.role.grant','授角色','12'),(1312,'sys.user.role.revoke','收角色','12'),(1313,'sys.role.perm.grant','角色加权限','12'),(1314,'sys.role.perm.revoke','角色减权限','12'),(1315,'sys.user.warehouse.grant','授仓','12'),(1316,'sys.user.warehouse.revoke','收仓','12'),(1317,'x.rb.test','测试点','12');"
seed "INSERT INTO sys_role (id,code,name) VALUES (1311,'RB_ADMIN','权限管理员'),(1312,'RB_TARGET','目标角色');"
seed "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1311,1311),(1311,1312),(1311,1313),(1311,1314),(1311,1315),(1311,1316);"
seed "INSERT INTO sys_user (id,username,password_hash) VALUES (1311,'rb_admin','x'),(1312,'rb_target','x'),(1313,'rb_noperm','x'),(1314,'rb_admin2','x');"
seed "INSERT INTO sys_user_role (user_id,role_id) VALUES (1311,1311),(1314,1311),(1312,1312);"
RBF="public.rbac_mapping_change(text,text,bigint,bigint,text,text)"
pv() { q1 "SELECT perm_version FROM sys_user WHERE id=$1"; }
sess() { echo "SET LOCAL wms.actor_id = '$1'; SET LOCAL wms.node_id = '13'; SET LOCAL wms.actor_perm_version = '${2:-$(pv $1)}'; SET LOCAL ROLE wms_app;"; }
rb() {  # $1 前置 SQL，$2 表达式，$3 COMMIT|ROLLBACK
psql -t -A <<RBSQL | grep '^RB#'
BEGIN;
$1
DO \$m\$ DECLARE r text; BEGIN SELECT ($2)::text INTO r; PERFORM set_config('m.r','OK:'||coalesce(r,''),true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END \$m\$;
RESET ROLE;
SELECT 'RB#' || current_setting('m.r');
${3:-COMMIT};
RBSQL
}
mutf() { echo "DO \$x\$ BEGIN EXECUTE replace(pg_get_functiondef('$RBF'::regprocedure), \$a\$$1\$a\$, \$b\$$2\$b\$); END \$x\$;"; }
for T in "sys_user_role:1312,1311" "sys_role_perm:1312,1317" "sys_user_warehouse:1312,2"; do
  TB=${T%%:*}; V=${T#*:}
  expect_block "12 wms_app 直接 INSERT $TB（只留 SELECT）" "SET ROLE wms_app; INSERT INTO $TB VALUES ($V);" "permission denied for table $TB"
  expect_block "12 wms_app 直接 DELETE $TB" "SET ROLE wms_app; DELETE FROM $TB;" "permission denied for table $TB"
done
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
GRANT DELETE ON sys_user_role TO wms_app;
SET LOCAL ROLE wms_app;
DELETE FROM sys_user_role WHERE user_id=1312 AND role_id=1312;
RESET ROLE;
SELECT 'MUT#' || count(*) FROM sys_user_role WHERE user_id=1312 AND role_id=1312;
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#0" ] && ok "变异：把 DELETE 授回 wms_app 后直接收角色成功" || bad "变异没变红：$R"
# 调用人身份
R=$(rb "SET LOCAL ROLE wms_app;" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#rbac_actor_unset" ] && ok "12 会话没设 wms.actor_id → rbac_actor_unset" || bad "12 未设身份：$R"
R=$(rb "SET LOCAL wms.actor_id = '1311'; SET LOCAL wms.actor_perm_version = '$(pv 1311)'; SET LOCAL ROLE wms_app;" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#rbac_actor_unset" ] && ok "12 会话没设 wms.node_id → rbac_actor_unset" || bad "12 未设节点：$R"
R=$(rb "$(mutf "NULLIF(current_setting('wms.actor_id', true), '')::bigint" "coalesce(NULLIF(current_setting('wms.actor_id', true), '')::bigint, 1311)") SET LOCAL wms.node_id = '13'; SET LOCAL wms.actor_perm_version = '$(pv 1311)'; SET LOCAL ROLE wms_app;" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#OK:1" ] && ok "变异：身份缺省回落到管理员后，未设身份的会话授角色成功（未设即拒的断言能抓到）" || bad "变异没变红（未设身份）：$R"
R=$(rb "$(sess 1311 999)" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#rbac_actor_stale" ] && ok "12 劫持：应用冒充管理员 1311 但带的权限版本不对 → rbac_actor_stale" || bad "12 冒充（版本不对）：$R"
R=$(rb "$(sess 99999 1)" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#rbac_actor_stale" ] && ok "12 劫持：应用冒充不存在的用户 99999 → rbac_actor_stale" || bad "12 冒充（不存在）：$R"
R=$(rb "$(mutf 'IF NOT EXISTS (SELECT 1 FROM sys_user u WHERE u.id = actor' 'IF false AND NOT EXISTS (SELECT 1 FROM sys_user u WHERE u.id = actor') $(sess 1311 999)" "public.sys_user_role_grant(1312,1311,'REQ-0','x')" ROLLBACK)
[ "$R" = "RB#OK:1" ] && ok "变异：去掉身份版本核对后，带错误版本的冒充会话授角色成功" || bad "变异没变红（版本核对）：$R"
R=$(psql -t -A -c "SET ROLE wms_app; SELECT public.sys_user_role_grant(1311,1312,1311,13101,13,2001,'x');" 2>&1)
case "$R" in *"does not exist"*) ok "12 应用传审计 id / node_seq / 调用人的旧签名不存在（这些值只由库和会话决定）";; *) bad "12 旧签名仍可调：$R";; esac
# 函数路径
P0=$(pv 1312); MAXID=$(q1 "SELECT coalesce(max(id),0) FROM audit_log"); MAXSEQ=$(q1 "SELECT coalesce(max(node_seq),0) FROM audit_log WHERE node_id=13")
R=$(rb "$(sess 1311)" "public.sys_user_role_grant(1312,1311,'REQ-1','授角色')")
[ "$R" = "RB#OK:1" ] && ok "12 函数路径：会话身份 1311 给 1312 授角色 1311" || bad "12 sys_user_role_grant：$R"
R=$(q1 "SELECT (SELECT count(*) FROM sys_user_role WHERE user_id=1312 AND role_id=1311) || '#' || (SELECT perm_version FROM sys_user WHERE id=1312) - $P0 || '#' || (SELECT (id = $MAXID + 1)::text || '/' || (node_seq = $MAXSEQ + 1)::text || '/' || action || '/' || target_id || '/' || actor_id || '/' || trace_id || '/' || (abs(extract(epoch FROM occurred_at - (now() AT TIME ZONE 'UTC'))) <= 5)::text FROM audit_log WHERE action='sys.user.role.grant' AND trace_id='REQ-1')")
[ "$R" = "1#1#true/true/sys.user.role.grant/1312:1311/1311/REQ-1/true" ] && ok "12 授角色：映射在、perm_version +1、审计 id / node_seq 由库分配（max+1）、调用人取自会话（$R）" || bad "12 授角色结果：$R"
R=$(rb "$(sess 1311)" "public.sys_user_role_revoke(1312,1311,'REQ-2','收角色')")
[ "$R#$(q1 "SELECT count(*) FROM sys_user_role WHERE user_id=1312 AND role_id=1311")" = "RB#OK:1#0" ] && ok "12 函数路径收角色" || bad "12 收角色：$R"
R=$(rb "$(sess 1311)" "public.sys_user_role_grant(1312,1311,'REQ-1','重放')" ROLLBACK)
[ "$R" = "RB#audit_log_rbac_replay" ] && ok "12 审计单次消费：同一 (授角色, 1312:1311, REQ-1) 重放 → audit_log_rbac_replay（40910 RBAC_AUDIT）" || bad "12 重放：$R"
R=$(rb "$(mutf 'IF EXISTS (SELECT 1 FROM audit_log WHERE action = perm' 'IF false AND EXISTS (SELECT 1 FROM audit_log WHERE action = perm') $(sess 1311)" "public.sys_user_role_grant(1312,1311,'REQ-1','重放')" ROLLBACK)
case "$R" in *uq_audit_rbac_once*) ok "12 去掉函数内重放检查后，uq_audit_rbac_once 兜底仍拒（$R）";; *) bad "12 uq_audit_rbac_once 兜底：$R";; esac
R=$(rb "DROP INDEX uq_audit_rbac_once; $(mutf 'IF EXISTS (SELECT 1 FROM audit_log WHERE action = perm' 'IF false AND EXISTS (SELECT 1 FROM audit_log WHERE action = perm') $(sess 1311)" "public.sys_user_role_grant(1312,1311,'REQ-1','重放')" ROLLBACK)
[ "$R" = "RB#OK:1" ] && ok "变异：去掉重放检查和 uq_audit_rbac_once 后同一请求号重放成功" || bad "变异没变红（单次消费）：$R"
R=$(rb "$(sess 1311)" "public.sys_user_role_grant(1312,1311,'REQ-3','换请求号再授')")
[ "$R" = "RB#OK:1" ] && ok "12 换新请求号可以再次授同一角色（单次消费只针对同一请求）" || bad "12 新请求号再授：$R"
R=$(rb "$(sess 1311)" "public.sys_user_role_revoke(1312,1312,'REQ-4','x')" COMMIT)
R=$(rb "$(sess 1311)" "public.sys_user_role_revoke(1312,1312,'REQ-5','再收')" ROLLBACK)
[ "$R" = "RB#sys_user_role_absent" ] && ok "12 收不存在的角色 → sys_user_role_absent" || bad "12 收不存在：$R"
R=$(rb "$(sess 1313)" "public.sys_user_role_grant(1312,1312,'REQ-6','x')" ROLLBACK)
[ "$R" = "RB#rbac_perm_not_held" ] && ok "12 会话身份 1313 无 sys.user.role.grant → rbac_perm_not_held" || bad "12 无权限点：$R"
R=$(rb "$(sess 1311)" "public.sys_user_role_grant(1311,1312,'REQ-6','x')" ROLLBACK)
[ "$R" = "RB#rbac_self_change" ] && ok "12 给自己授角色 → rbac_self_change" || bad "12 自授：$R"
R=$(rb "$(sess 1311)" "public.sys_role_perm_grant(1311,1317,'REQ-6','x')" ROLLBACK)
[ "$R" = "RB#rbac_self_change" ] && ok "12 给自己所在角色加权限 → rbac_self_change" || bad "12 自加权限：$R"
P0=$(pv 1312)
R=$(rb "$(sess 1311)" "public.sys_role_perm_grant(1311,1317,'REQ-7','x')" ROLLBACK)
R=$(rb "$(sess 1311)" "public.sys_user_role_grant(1312,1312,'REQ-8','x')")
P0=$(pv 1312)
R=$(rb "$(sess 1311)" "public.sys_role_perm_grant(1312,1317,'REQ-9','加权限')")
[ "$R#$(( $(pv 1312) - P0 ))" = "RB#OK:1#1" ] && ok "12 角色加权限：持有该角色的用户 perm_version +1" || bad "12 sys_role_perm_grant：$R"
R=$(rb "$(sess 1311)" "public.sys_role_perm_revoke(1312,1317,'REQ-10','减权限')")
[ "$R" = "RB#OK:1" ] && ok "12 角色减权限" || bad "12 sys_role_perm_revoke：$R"
R=$(rb "$(sess 1311)" "public.sys_user_warehouse_grant(1312,2,'REQ-11','授仓')"); R2=$(rb "$(sess 1311)" "public.sys_user_warehouse_revoke(1312,2,'REQ-12','收仓')")
[ "$R#$R2" = "RB#OK:1#RB#OK:1" ] && ok "12 用户-仓授 / 收经函数" || bad "12 sys_user_warehouse_*：$R $R2"
R=$(rb "$(mutf 'IF NOT EXISTS (SELECT 1 FROM sys_user u JOIN' 'IF false AND NOT EXISTS (SELECT 1 FROM sys_user u JOIN') $(sess 1313)" "public.sys_user_role_grant(1314,1312,'REQ-90','x')" ROLLBACK)
[ "$R" = "RB#OK:1" ] && ok "变异：去掉权限点检查后无权限的 1313 授角色成功" || bad "变异没变红（权限点）：$R"
R=$(rb "$(mutf "IF (p_kind <> 'ROLE_PERM' AND p_a = actor)" "IF false AND (p_kind <> 'ROLE_PERM' AND p_a = actor)") $(sess 1311)" "public.sys_user_role_grant(1311,1312,'REQ-90','x')" ROLLBACK)
[ "$R" = "RB#OK:1" ] && ok "变异：去掉自改检查后给自己授角色成功" || bad "变异没变红（自改）：$R"
R=$(psql -t -A <<MUTSQL | grep '^MUT#'
BEGIN;
DO \$x\$ BEGIN EXECUTE regexp_replace(pg_get_functiondef('$RBF'::regprocedure), 'UPDATE sys_user SET perm_version = perm_version \\+ 1 WHERE id = p_a;\\s+/\\*BUMP\\*/', '/*BUMP removed*/'); END \$x\$;
$(sess 1311)
SELECT public.sys_user_role_grant(1314,1312,'REQ-91','x');
RESET ROLE;
SELECT 'MUT#' || (SELECT perm_version FROM sys_user WHERE id=1314) - $(pv 1314);
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#0" ] && ok "变异：去掉 perm_version +1 后授角色不递增" || bad "变异没变红（递增）：$R"
R=$(psql -t -A <<MUTSQL | grep '^MUT#'
BEGIN;
DO \$x\$ BEGIN EXECUTE replace(replace(pg_get_functiondef('$RBF'::regprocedure), 'INSERT INTO audit_log (id,', 'IF false THEN INSERT INTO audit_log (id,'), 'p_reason, node, aseq);', 'p_reason, node, aseq); END IF;'); END \$x\$;
$(sess 1311)
SELECT public.sys_user_role_grant(1314,1312,'REQ-92','x');
RESET ROLE;
SELECT 'MUT#' || count(*) FROM audit_log WHERE trace_id='REQ-92';
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#0" ] && ok "变异：去掉审计写入后授角色没有审计行" || bad "变异没变红（审计）：$R"
# 停用
P0=$(pv 1314)
psql -q -c "SET ROLE wms_app; UPDATE sys_user SET status='DISABLED' WHERE id=1314;" >/dev/null
[ "$(( $(pv 1314) - P0 ))" = "1" ] && ok "12 停用用户 1314：perm_version 由库 +1" || bad "12 停用没有递增 perm_version"
R=$(rb "$(sess 1314)" "public.sys_user_role_grant(1312,1311,'REQ-13','x')" ROLLBACK)
[ "$R" = "RB#rbac_perm_not_held" ] && ok "12 停用的管理员 1314（会话版本已更新）不能再授角色" || bad "12 停用管理员：$R"
R=$(rb "$(sess 1314 $(( $(pv 1314) - 1 )))" "public.sys_user_role_grant(1312,1311,'REQ-13','x')" ROLLBACK)
[ "$R" = "RB#rbac_actor_stale" ] && ok "12 停用前签发的会话（旧权限版本）→ rbac_actor_stale" || bad "12 停用前会话：$R"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_user_status_bump ON sys_user;
CREATE TEMP TABLE pv0 AS SELECT perm_version FROM sys_user WHERE id=1313;
UPDATE sys_user SET status='DISABLED' WHERE id=1313;
SELECT 'MUT#' || (SELECT perm_version FROM sys_user WHERE id=1313) - (SELECT perm_version FROM pv0);
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#0" ] && ok "变异：去掉 trg_user_status_bump 后停用不递增 perm_version" || bad "变异没变红：$R"
expect_block "12 登录名不可改（释放旧名）" "SET ROLE wms_app; UPDATE sys_user SET username='rb_x' WHERE id=1314;" "sys_user_key_immutable"
expect_block "12 登录名不可复用（停用后同名新用户）" "SET ROLE wms_app; INSERT INTO sys_user (id,username,password_hash) VALUES (1319,'rb_admin2','x');" "uq_user_name"
# pg_temp 劫持：临时表伪造 1313 持有 sys.user.role.grant
R=$(psql -q -t -A <<PTSQL | grep '^PT#'
BEGIN;
$(sess 1313)
CREATE TEMP TABLE sys_user (id BIGINT, status TEXT, deleted_at TIMESTAMP, perm_version BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE sys_user_role (user_id BIGINT, role_id BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE sys_role_perm (role_id BIGINT, perm_id BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE sys_permission (id BIGINT, code TEXT) ON COMMIT DROP;
INSERT INTO pg_temp.sys_user VALUES (1313,'ACTIVE',NULL,$(pv 1313)); INSERT INTO pg_temp.sys_user_role VALUES (1313,9); INSERT INTO pg_temp.sys_role_perm VALUES (9,9); INSERT INTO pg_temp.sys_permission VALUES (9,'sys.user.role.grant');
GRANT ALL ON pg_temp.sys_user, pg_temp.sys_user_role, pg_temp.sys_role_perm, pg_temp.sys_permission TO PUBLIC;
SET LOCAL search_path = public;
CREATE FUNCTION pg_temp.pt_try(q text, k text) RETURNS void LANGUAGE plpgsql AS \$f\$ BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'PT_PASSED'; EXCEPTION WHEN OTHERS THEN PERFORM set_config(k, SQLERRM, true); END; END \$f\$;
SELECT pg_temp.pt_try(\$q\$SELECT public.sys_user_role_grant(1312,1312,'REQ-98','x')\$q\$, 'pt.a0');
RESET ROLE;
ALTER FUNCTION $RBF SET search_path = pg_catalog, public;
SET LOCAL ROLE wms_app;
SET LOCAL search_path = public;
SELECT pg_temp.pt_try(\$q\$SELECT public.sys_user_role_grant(1312,1312,'REQ-98','x')\$q\$, 'pt.a1');
RESET ROLE;
SELECT 'PT#' || current_setting('pt.a0') || '#' || current_setting('pt.a1');
ROLLBACK;
PTSQL
)
IFS='#' read -r _ A0 A1 <<< "$R"
[ "$A0" = "rbac_perm_not_held" ] && ok "pg_temp 劫持 rbac_mapping_change：临时表伪造 1313 持有权限点，函数仍读 public → $A0" || bad "rbac pg_temp 劫持：$A0"
[ -n "$A1" ] && [ "$A1" != "$A0" ] && ok "变异：rbac_mapping_change 去掉 pg_temp 后劫持生效（$A1）" || bad "变异没变红：rbac 去掉 pg_temp 后仍是 $A1"
R=$(q1 "SELECT count(*) || '/' || count(*) FILTER (WHERE 'search_path=pg_catalog, public, pg_temp' = ANY(p.proconfig)) || '/' || count(*) FILTER (WHERE p.prosecdef) || '/' || count(*) FILTER (WHERE pg_get_userbyid(p.proowner)='wms_rbac_owner') FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('trg_user_status_bump','rbac_mapping_change','sys_user_role_grant','sys_user_role_revoke','sys_role_perm_grant','sys_role_perm_revoke','sys_user_warehouse_grant','sys_user_warehouse_revoke')")
[ "$R" = "8/8/6/7" ] && ok "12 新函数 8 个都 search_path 含 pg_temp；6 个包装 SECURITY DEFINER；7 个属主 wms_rbac_owner（$R）" || bad "12 rbac 函数目录：$R（期望 8/8/6/7）"
R=$(q1 "SELECT has_function_privilege('wms_app','$RBF','EXECUTE')::text || '/' || has_function_privilege('wms_app','public.sys_user_role_revoke(bigint,bigint,text,text)','EXECUTE')::text")
[ "$R" = "false/true" ] && ok "12 wms_app 不能直接调核心函数、只能调包装（$R）" || bad "12 EXECUTE 授权：$R"
# 第 12 篇触发器 / 索引名冻结基线（缺任何一个就红；新增要同步补进基线）
T12="'sys_user','sys_role','sys_permission','sys_user_role','sys_role_perm','sys_user_warehouse','api_credential','user_device_binding','offline_token','approval_request','device_reconnect'"
TRG12_BASE="api_credential.trg_0_key_lock approval_request.trg_0_key_lock approval_request.trg_apr_final approval_request.trg_apr_insert approval_request.trg_apr_no_delete approval_request.trg_apr_no_truncate approval_request.trg_apr_version approval_request.trg_apr_zclock audit_log.trg_audit_append_only audit_log.trg_audit_node_required device_reconnect.trg_drc_append_only device_reconnect.trg_drc_guard device_reconnect.trg_drc_no_truncate offline_token.trg_0_key_lock offline_token.trg_offline_guard offline_token.trg_offline_zclock sys_permission.trg_0_key_lock sys_role.trg_0_key_lock sys_role_perm.trg_0_key_lock sys_user.trg_0_key_lock sys_user.trg_user_no_delete sys_user.trg_user_no_truncate sys_user.trg_user_perm_ver sys_user.trg_user_status_bump sys_user_role.trg_0_key_lock sys_user_warehouse.trg_0_key_lock user_device_binding.trg_0_key_lock user_device_binding.trg_udb_guard user_device_binding.trg_udb_no_delete user_device_binding.trg_udb_no_truncate user_device_binding.trg_udb_zclock"
IDX12_BASE="api_credential.api_credential_pkey api_credential.uq_api_key approval_request.approval_request_pkey approval_request.ix_apr_requester approval_request.ix_apr_wh approval_request.uq_apr_code approval_request.uq_apr_open audit_log.uq_audit_node_seq device_reconnect.device_reconnect_pkey device_reconnect.ix_drc_binding device_reconnect.ix_drc_jti device_reconnect.uq_drc_id_binding offline_token.ix_offline_binding offline_token.offline_token_pkey offline_token.uq_offline_jti sys_permission.sys_permission_pkey sys_permission.uq_perm_code sys_role.sys_role_pkey sys_role.uq_role_code sys_role_perm.sys_role_perm_pkey sys_user.ix_user_openid sys_user.sys_user_pkey sys_user.uq_user_name sys_user_role.sys_user_role_pkey sys_user_warehouse.sys_user_warehouse_pkey user_device_binding.ix_udb_user user_device_binding.uq_udb_active user_device_binding.user_device_binding_pkey"
TRG12_NOW=$(q1 "SELECT string_agg(c.relname || '.' || t.tgname, ' ' ORDER BY 1) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal AND (c.relname IN ($T12) OR (c.relname = 'audit_log' AND t.tgname IN ('trg_audit_node_required','trg_audit_append_only')))")
IDX12_NOW=$(q1 "SELECT string_agg(tablename || '.' || indexname, ' ' ORDER BY 1) FROM pg_indexes WHERE schemaname = 'public' AND (tablename IN ($T12) OR indexname = 'uq_audit_node_seq')")
MISS=""; for x in $TRG12_BASE $IDX12_BASE; do case " $TRG12_NOW $IDX12_NOW " in *" $x "*) ;; *) MISS="$MISS $x";; esac; done
[ -z "$MISS" ] && [ -n "$TRG12_BASE" ] && ok "12 触发器 / 索引冻结基线齐全（$(wc -w <<< "$TRG12_BASE") 触发器、$(wc -w <<< "$IDX12_BASE") 索引）" || bad "12 冻结基线缺：$MISS ｜实测触发器：$TRG12_NOW ｜实测索引：$IDX12_NOW"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_drc_append_only ON device_reconnect;
SELECT 'MUT#' || count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relname = 'device_reconnect' AND t.tgname = 'trg_drc_append_only';
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#0" ] && case " $TRG12_BASE " in *" device_reconnect.trg_drc_append_only "*) ok "变异：删 trg_drc_append_only 后它在基线里、实测里没有 → 基线断言会变红";; *) bad "基线里没有 device_reconnect.trg_drc_append_only";; esac || bad "基线变异前置：$R"
expect_block "12 计数器行：属主 DELETE sys_user" "DELETE FROM sys_user WHERE id=1301;" "append_only_violation: sys_user"
expect_block "12 计数器行：属主 TRUNCATE sys_user" "TRUNCATE sys_user CASCADE;" "append_only_violation: sys_user"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_user_no_delete ON sys_user;
DO $m$ BEGIN DELETE FROM sys_user WHERE id=1305; PERFORM set_config('m.r','PASSED',true); EXCEPTION WHEN OTHERS THEN PERFORM set_config('m.r',SQLERRM,true); END $m$;
SELECT 'MUT#' || current_setting('m.r');
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_user_no_delete 后属主删用户成功" || bad "变异没变红：$R"
R=$(q1 "SELECT count(*) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('trg_12_key_lock','trg_apr_version') AND 'search_path=pg_catalog, public, pg_temp' = ANY(p.proconfig)")
[ "$R" = "2" ] && ok "12 trg_12_key_lock / trg_apr_version search_path 含 pg_temp（$R/2）" || bad "12 key_lock 函数 search_path $R/2"
echo "=== 2g-fa. audit_log 外键（Doro 裁定：fk_audit_actor 在 12_auth 末尾 ALTER；fk_audit_approval 在 12b）==="
R=$(psql -t -A -c "SELECT string_agg(conname || ':' || confrelid::regclass::text, ' ' ORDER BY conname) FROM pg_constraint WHERE conrelid = 'audit_log'::regclass AND contype = 'f' AND conname IN ('fk_audit_actor','fk_audit_approval')")
[ "$R" = "fk_audit_actor:sys_user fk_audit_approval:approval_request" ] && ok "audit_log 外键已声明：$R" || bad "audit_log 外键缺：$R"
expect_block "12 外键：audit_log.actor_id 指向不存在的用户" "INSERT INTO audit_log (id,actor_id,action,node_id,node_seq) VALUES (779801,999999,'t12.fk',7,779801);" "fk_audit_actor"
expect_block "12 外键：audit_log.approval_id 指向不存在的审批单" "INSERT INTO audit_log (id,approval_id,action,node_id,node_seq) VALUES (779802,999999,'t12.fk',7,779802);" "fk_audit_approval"
echo "=== 2i. 第 1 篇主数据不变量（sell_days / 温区 0.1 ℃ / 水位 milli / 换算 milli / 仓编码 / 时间默认值）==="
# 每条库层不变量都是三件套：正向放行 + 反向按名拦截 + 变异（去掉约束后原被拒语句通过）。与 verify_sqlite.py 同一套断言。
SKU_COLS="id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days,natural_loss_tolerance_ppm"
expect_allow "01 sku.sell_days=10 且 ≤ 保质期 30 天（冷藏）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8011,'SKU-T-SD','x','KG','CHILLED',30,0,10,0); ROLLBACK;"
expect_block "01 sku.sell_days 超保质期（31 > 30）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8012,'SKU-T-SD2','x','KG','CHILLED',30,0,31,0); ROLLBACK;" "ck_sku_sell_days"
expect_block "01 sku.sell_days=0（可售天数是正数）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8013,'SKU-T-SD3','x','KG','CHILLED',30,0,0,0); ROLLBACK;" "ck_sku_sell_days"
expect_block "01 冷藏 SKU 没有 sell_days（sell_deadline 会永远为空）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8014,'SKU-T-SD4','x','KG','CHILLED',30,0,NULL,0); ROLLBACK;" "ck_sku_sell_days_req"
expect_allow "01 常温 SKU 允许不设 sell_days" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8015,'SKU-T-SD5','x','KG','AMBIENT',30,0,NULL,0); ROLLBACK;"
expect_allow "01 损耗容差正好 50000 ppm（5%）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8016,'SKU-T-PPM','x','KG','CHILLED',30,0,10,50000); ROLLBACK;"
expect_block "01 损耗容差 50001 ppm（绕过 09 报损审批）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8017,'SKU-T-PPM2','x','KG','CHILLED',30,0,10,50001); ROLLBACK;" "ck_sku_loss_ppm"
expect_block "01 禁发期 6 天 > 保质期 5 天" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8018,'SKU-T-SL','x','KG','CHILLED',5,6,1,0); ROLLBACK;" "ck_sku_shelf_life"
expect_allow "01 禁发期与收货允收期都等于保质期（放行）" "BEGIN; INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,receive_min_shelf_life,ship_min_shelf_life,sell_days) VALUES (8019,'SKU-T-SL2','x','KG','CHILLED',5,5,5,1); ROLLBACK;"
pg_drop_mut() {  # $1 表  $2 约束名  $3 描述  $4 变异后应通过的 SQL（不带结尾分号）
  local R
  R=$(psql -t -A <<MUTSQL | grep '^MUT#'
BEGIN;
ALTER TABLE $1 DROP CONSTRAINT $2;
$4;
SELECT 'MUT#PASSED';
ROLLBACK;
MUTSQL
)
  [ "$R" = "MUT#PASSED" ] && ok "变异：去掉 $2 后 $3（断言能抓到）" || bad "变异没变红：$2 → $R"
}
pg_drop_mut sku ck_sku_sell_days "sell_days 超保质期被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8091,'SKU-M1','x','KG','CHILLED',30,0,31,0)"
pg_drop_mut sku ck_sku_sell_days_req "冷藏 SKU 缺 sell_days 被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8092,'SKU-M2','x','KG','CHILLED',30,0,NULL,0)"
pg_drop_mut sku ck_sku_loss_ppm "损耗容差 50001 被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8093,'SKU-M3','x','KG','CHILLED',30,0,10,50001)"
pg_drop_mut sku ck_sku_shelf_life "禁发期超保质期被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8094,'SKU-M4','x','KG','CHILLED',5,6,1,0)"
pg_drop_mut sku ck_sku_temp "温区小写 'chilled' 被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8095,'SKU-MT1','x','KG','chilled',30,0,NULL,0)"
pg_drop_mut sku ck_sku_temp "温区尾空格 'FROZEN ' 被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8096,'SKU-MT2','x','KG','FROZEN ',30,0,NULL,0)"
pg_drop_mut sku ck_sku_temp "温区未知值 'CHILL' 被放行" "INSERT INTO sku ($SKU_COLS) VALUES (8097,'SKU-MT3','x','KG','CHILL',30,0,NULL,0)"
# 镜鉴 I-1（食品安全）：取值域 CHECK —— 大小写 / 尾空格 / 未知值一律拒，别再靠精确匹配的 ck_sku_sell_days_req 兜
expect_allow "01 SKU 温区取值域内 5 个值全放行（AMBIENT / CHILLED / FROZEN / FRESH / LIVE）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8021,'SKU-T-T1','x','KG','AMBIENT',30,0,NULL,0),(8022,'SKU-T-T2','x','KG','CHILLED',30,0,10,0),(8023,'SKU-T-T3','x','KG','FROZEN',30,0,10,0),(8024,'SKU-T-T4','x','KG','FRESH',30,0,NULL,0),(8025,'SKU-T-T5','x','KG','LIVE',30,0,NULL,0); ROLLBACK;"
expect_block "01 SKU 温区绕过值 'chilled'（小写，且不填 sell_days）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8031,'SKU-T-TB1','x','KG','chilled',30,0,NULL,0); ROLLBACK;" "ck_sku_temp"
expect_block "01 SKU 温区绕过值 'FROZEN '（尾空格，且不填 sell_days）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8032,'SKU-T-TB2','x','KG','FROZEN ',30,0,NULL,0); ROLLBACK;" "ck_sku_temp"
expect_block "01 SKU 温区绕过值 'CHILL'（未知值，且不填 sell_days）" "BEGIN; INSERT INTO sku ($SKU_COLS) VALUES (8033,'SKU-T-TB3','x','KG','CHILL',30,0,NULL,0); ROLLBACK;" "ck_sku_temp"
ZONE_COLS="id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10"
expect_allow "01 冷冻区 -18.0 ℃ ~ -15.0 ℃（c10 整数）" "BEGIN; INSERT INTO zone ($ZONE_COLS) VALUES (8101,1,'Z-T1','x','FROZEN','STORAGE',-180,-150); ROLLBACK;"
expect_block "01 温区上下限相等（等于没有区间）" "BEGIN; INSERT INTO zone ($ZONE_COLS) VALUES (8102,1,'Z-T2','x','FROZEN','STORAGE',-150,-150); ROLLBACK;" "ck_zone_temp"
expect_block "01 温区只给下限不给上限" "BEGIN; INSERT INTO zone ($ZONE_COLS) VALUES (8103,1,'Z-T3','x','FROZEN','STORAGE',-180,NULL); ROLLBACK;" "ck_zone_temp"
expect_block "01 温区下限大于上限" "BEGIN; INSERT INTO zone ($ZONE_COLS) VALUES (8104,1,'Z-T4','x','FROZEN','STORAGE',-150,-180); ROLLBACK;" "ck_zone_temp"
expect_allow "01 温区两列都为空（不控温库区）" "BEGIN; INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8105,1,'Z-T5','x','AMBIENT','STAGE'); ROLLBACK;"
# 镜鉴 I-2：空区间只允许 AMBIENT；控温库区（CHILLED/FROZEN）必须给区间
expect_block "01 控温库区 CHILLED 不给温度区间" "BEGIN; INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8106,1,'Z-T6','x','CHILLED','STORAGE'); ROLLBACK;" "ck_zone_temp"
expect_block "01 控温库区 FROZEN 不给温度区间" "BEGIN; INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8107,1,'Z-T7','x','FROZEN','STORAGE'); ROLLBACK;" "ck_zone_temp"
expect_block "01 空区间只允许 AMBIENT（FRESH 也不例外）" "BEGIN; INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8108,1,'Z-T8','x','FRESH','STORAGE'); ROLLBACK;" "ck_zone_temp"
pg_drop_mut zone ck_zone_temp "温区上下限相等被放行" "INSERT INTO zone ($ZONE_COLS) VALUES (8096,1,'Z-M1','x','FROZEN','STORAGE',-150,-150)"
pg_drop_mut zone ck_zone_temp "CHILLED 库区不给温度区间被放行" "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8094,1,'Z-M2','x','CHILLED','STORAGE')"
LOC_COLS="id,warehouse_id,zone_id,code,location_type,min_level_milli,max_level_milli"
expect_allow "01 补货水位 0 ≤ 下限 ≤ 上限（milli）" "BEGIN; INSERT INTO location ($LOC_COLS) VALUES (8111,1,1,'L-T1','BIN',0,100000); ROLLBACK;"
expect_block "01 补货水位下限 > 上限" "BEGIN; INSERT INTO location ($LOC_COLS) VALUES (8112,1,1,'L-T2','BIN',100000,50000); ROLLBACK;" "ck_loc_level"
expect_block "01 补货水位下限为负" "BEGIN; INSERT INTO location ($LOC_COLS) VALUES (8113,1,1,'L-T3','BIN',-1,0); ROLLBACK;" "ck_loc_level"
pg_drop_mut location ck_loc_level "补货水位下限 > 上限被放行" "INSERT INTO location ($LOC_COLS) VALUES (8097,1,1,'L-M1','BIN',100000,50000)"
expect_allow "01 仓编码 WHSH02（[A-Z0-9]、2–16 位）" "BEGIN; INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8121,'WHSH02','x','20:00'); ROLLBACK;"
expect_block "01 仓编码含小写字母" "BEGIN; INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8122,'wh02','x','20:00'); ROLLBACK;" "ck_wh_code"
expect_block "01 仓编码含 '-'（会与审批单号分段冲突）" "BEGIN; INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8123,'AB-C1','x','20:00'); ROLLBACK;" "ck_wh_code"
expect_block "01 仓编码只有 1 位" "BEGIN; INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8124,'A','x','20:00'); ROLLBACK;" "ck_wh_code"
expect_block "01 仓编码 17 位" "BEGIN; INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8125,'ABCDEFGH123456789','x','20:00'); ROLLBACK;" "ck_wh_code"
pg_drop_mut warehouse ck_wh_code "仓编码含小写被放行" "INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (8098,'wh02','x','20:00')"
SU_COLS="id,sku_id,uom,base_qty_milli"
expect_allow "01 换算系数 1 BOX = 12.500 KG（12500 milli）" "BEGIN; INSERT INTO sku_unit ($SU_COLS) VALUES (8131,1,'BOX12',12500); ROLLBACK;"
expect_block "01 换算系数为 0" "BEGIN; INSERT INTO sku_unit ($SU_COLS) VALUES (8132,1,'BOX0',0); ROLLBACK;" "ck_unit_ratio"
expect_block "01 换算系数为负" "BEGIN; INSERT INTO sku_unit ($SU_COLS) VALUES (8133,1,'BOXN',-1); ROLLBACK;" "ck_unit_ratio"
pg_drop_mut sku_unit ck_unit_ratio "换算系数为 0 被放行" "INSERT INTO sku_unit ($SU_COLS) VALUES (8099,1,'BOXM',0)"
# 旧口径列必须消失、新口径列必须在且类型正确（R2；温区与第 18 篇同 *_c10 口径）
R=$(psql -t -A -c "SELECT COALESCE(string_agg(table_name || '.' || column_name, ',' ORDER BY table_name, column_name), '') FROM information_schema.columns WHERE table_schema='public' AND ((table_name='zone' AND column_name IN ('temp_min','temp_max')) OR (table_name='sku' AND column_name='natural_loss_pct') OR (table_name='location' AND column_name IN ('min_level','max_level')) OR (table_name='sku_unit' AND column_name='ratio_to_base'))")
[ -z "$R" ] && ok "01 旧口径列已全部改名（zone.temp_min/temp_max、sku.natural_loss_pct、location.min_level/max_level、sku_unit.ratio_to_base 都不在）" || bad "01 旧口径列还在：$R"
R=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND ((table_name='zone' AND column_name IN ('temp_min_c10','temp_max_c10') AND data_type='integer') OR (table_name='sku' AND column_name IN ('sell_days','natural_loss_tolerance_ppm')) OR (table_name='location' AND column_name IN ('min_level_milli','max_level_milli')) OR (table_name='sku_unit' AND column_name='base_qty_milli'))")
[ "$R" = "7" ] && ok "01 新口径列齐全，温区上下限是 integer（7/7）" || bad "01 新口径列：$R（期望 7）"
R=$(psql -t -A -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND ((table_name='location' AND column_name IN ('min_level_milli','max_level_milli') AND data_type='bigint') OR (table_name='sku_unit' AND column_name='base_qty_milli' AND data_type='bigint') OR (table_name='sku' AND column_name='natural_loss_tolerance_ppm' AND data_type='bigint'))")
[ "$R" = "4" ] && ok "01 水位 / 换算 / 损耗容差列都是 BIGINT（R2：不用 NUMERIC）" || bad "01 口径列类型：$R（期望 4）"
# 00 §6.8 第 3 条：服务端时间由库写 UTC 整秒
T01="'warehouse','zone','location','sku','lot','supplier','customer','vehicle','driver','device'"
R=$(psql -t -A -c "SELECT count(*) || '/' || count(*) FILTER (WHERE column_default LIKE '%date_trunc%now() AT TIME ZONE ''UTC''%') FROM information_schema.columns WHERE table_schema='public' AND table_name IN ($T01) AND column_name IN ('created_at','updated_at')")
[ "$R" = "20/20" ] && ok "01 的 20 个 created_at / updated_at 默认值都是 date_trunc('second', now() AT TIME ZONE 'UTC')（$R）" || bad "01 时间默认值：$R（期望 20/20）"
R=$(psql -t -A <<'MUTSQL' | grep '^MUT#'
BEGIN;
ALTER TABLE sku ALTER COLUMN updated_at SET DEFAULT now();
SELECT 'MUT#' || count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('warehouse','zone','location','sku','lot','supplier','customer','vehicle','driver','device') AND column_name IN ('created_at','updated_at') AND column_default LIKE '%date_trunc%now() AT TIME ZONE ''UTC''%';
ROLLBACK;
MUTSQL
)
[ "$R" = "MUT#19" ] && ok "变异：把 sku.updated_at 改回裸 now() → 合规时间默认值 20 → 19（断言能抓到）" || bad "变异没变红：$R"
echo "=== 2a-01L. 01 增量台账五表（supplier / customer / vehicle / driver / device）==="
mut01() { expect_allow "01 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3 ROLLBACK;"; }
expect_allow "01 台账正向：五张表各一条（车牌不做格式校验、车厢温区可同空）" "INSERT INTO supplier (id,code,name) VALUES (8801,'SUP001','山东果蔬供应商'); INSERT INTO customer (id,code,name,store_type) VALUES (8802,'STORE001','门店 A','STORE'); INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8803,'沪A12345','REFRIGERATED'); INSERT INTO driver (id,name,phone) VALUES (8804,'张师傅','13800138000'); INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8805,'D-PDA-8805','PDA',1);"
expect_allow "01 台账正向：批次挂已存在的供应商（lot.supplier_id 外键）" "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,supplier_id) VALUES (8806,1,'LOT-SUP-8806','2026-12-01','2026-10-15',8801);"
expect_block "01 拒绝：ck_supplier_code 小写编码" "INSERT INTO supplier (id,code,name) VALUES (8811,'sup001','x');" "ck_supplier_code"
mut01 "ck_supplier_code" "supplier" "INSERT INTO supplier (id,code,name) VALUES (8811,'sup001','x');"
expect_block "01 拒绝：ck_supplier_status 未知状态" "INSERT INTO supplier (id,code,name,status) VALUES (8812,'SUP002','x','PENDING');" "ck_supplier_status"
expect_block "01 拒绝：ck_customer_type 未知门店类型" "INSERT INTO customer (id,code,name,store_type) VALUES (8813,'STORE002','x','KIOSK');" "ck_customer_type"
expect_block "01 拒绝：ck_vehicle_temp 只给上限（两列必须同空或同填）" "INSERT INTO vehicle (id,plate_no,vehicle_type,temp_max_c10) VALUES (8814,'沪A99999','REFRIGERATED',40);" "ck_vehicle_temp"
mut01 "ck_vehicle_temp" "vehicle" "INSERT INTO vehicle (id,plate_no,vehicle_type,temp_max_c10) VALUES (8814,'沪A99999','REFRIGERATED',40);"
expect_block "01 拒绝：ck_driver_phone 10 位号码" "INSERT INTO driver (id,name,phone) VALUES (8815,'李师傅','1380013800');" "ck_driver_phone"
mut01 "ck_driver_phone" "driver" "INSERT INTO driver (id,name,phone) VALUES (8815,'李师傅','1380013800');"
expect_block "01 拒绝：ck_device_instance 全空白实例号" "INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8816,'   ',1);" "ck_device_instance"
mut01 "ck_device_instance" "device" "INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8816,'   ',1);"
expect_block "01 拒绝：fk_lot_supplier 批次挂不存在的供应商" "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,supplier_id) VALUES (8817,1,'LOT-SUP-8817','2026-12-02','2026-10-15',999999);" "fk_lot_supplier"
mut01 "fk_lot_supplier" "lot" "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,supplier_id) VALUES (8817,1,'LOT-SUP-8817','2026-12-02','2026-10-15',999999);"
# 镜鉴 I2（覆盖补齐）：把台账 19 个新约束的三件套补全——新增 CHECK / 5 个唯一键 / device.warehouse_id 外键
expect_block "01 拒绝：ck_customer_code 小写门店编码" "INSERT INTO customer (id,code,name) VALUES (8821,'store-x','x');" "ck_customer_code"
mut01 "ck_customer_code" "customer" "INSERT INTO customer (id,code,name) VALUES (8821,'store-x','x');"
expect_block "01 拒绝：ck_customer_status 未知状态" "INSERT INTO customer (id,code,name,status) VALUES (8822,'STORE003','x','PENDING');" "ck_customer_status"
expect_block "01 拒绝：ck_vehicle_type 未知车型" "INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8823,'沪A88888','SHIP');" "ck_vehicle_type"
expect_block "01 拒绝：ck_vehicle_status 未知状态" "INSERT INTO vehicle (id,plate_no,vehicle_type,status) VALUES (8824,'沪A88889','VAN','PENDING');" "ck_vehicle_status"
expect_block "01 拒绝：ck_vehicle_cap 载重为 0" "INSERT INTO vehicle (id,plate_no,vehicle_type,capacity_kg) VALUES (8825,'沪A88890','VAN',0);" "ck_vehicle_cap"
mut01 "ck_vehicle_cap" "vehicle" "INSERT INTO vehicle (id,plate_no,vehicle_type,capacity_kg) VALUES (8825,'沪A88890','VAN',0);"
expect_block "01 拒绝：ck_driver_status 未知状态" "INSERT INTO driver (id,name,phone,status) VALUES (8826,'王师傅','13900139000','PENDING');" "ck_driver_status"
expect_block "01 拒绝：ck_device_type 未知设备类型" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8827,'D-PDA-8827','ROBOT',1);" "ck_device_type"
mut01 "ck_device_type" "device" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8827,'D-PDA-8827','ROBOT',1);"
expect_block "01 拒绝：ck_device_status 未知状态" "INSERT INTO device (id,device_instance_id,device_type,status,warehouse_id) VALUES (8828,'D-PDA-8828','PDA','PENDING',1);" "ck_device_status"
expect_block "01 拒绝：ck_device_seen 心跳早于建档" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id,created_at,last_seen_at) VALUES (8829,'D-PDA-8829','PDA',1,'2026-10-15 10:00:00','2026-10-15 09:00:00');" "ck_device_seen"
mut01 "ck_device_seen" "device" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id,created_at,last_seen_at) VALUES (8829,'D-PDA-8829','PDA',1,'2026-10-15 10:00:00','2026-10-15 09:00:00');"
expect_block "01 拒绝：fk_device_warehouse 设备挂不存在的仓" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8830,'D-PDA-8830','PDA',999999);" "fk_device_warehouse"
expect_block "01 拒绝：uq_supplier_code 编码重复" "INSERT INTO supplier (id,code,name) VALUES (8831,'SUP001','重复编码');" "uq_supplier_code"
expect_block "01 拒绝：uq_customer_code 门店编码重复" "INSERT INTO customer (id,code,name) VALUES (8832,'STORE001','重复门店');" "uq_customer_code"
expect_block "01 拒绝：uq_vehicle_plate 车牌重复" "INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8833,'沪A12345','VAN');" "uq_vehicle_plate"
expect_block "01 拒绝：uq_driver_phone 手机号重复" "INSERT INTO driver (id,name,phone) VALUES (8834,'赵师傅','13800138000');" "uq_driver_phone"
expect_block "01 拒绝：uq_device_instance 实例号重复" "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8835,'D-PDA-8805','PDA',1);" "uq_device_instance"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_lot_supplier'")
[ "$R" = "1" ] && ok "01 目录断言：ix_lot_supplier（lot.supplier_id 外键列索引）存在（$R）" || bad "01 ix_lot_supplier 缺：$R（期望 1）"
echo "=== 2a-FK. 跨篇 FK 收口（03 supplier / 10 supplier / 04 customer+driver / 12b device，共 5 条命名外键）==="
expect_block "跨篇 FK：inbound_order.supplier_id 指向不存在的供应商" "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8901,'INB-FK1',1,'PURCHASE','ERP','PO-FK1','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',999999,'RECEIVING','2026-10-15');" "fk_inb_supplier"
expect_allow "跨篇 FK 正向：inbound_order.supplier_id = 501（父行在种子里）" "BEGIN; INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8902,'INB-FK2',1,'PURCHASE','ERP','PO-FK2','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',501,'RECEIVING','2026-10-15'); ROLLBACK;"
expect_block "跨篇 FK：supplier_return.supplier_id 指向不存在的供应商" "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8903,'SRN-8903',1,999999,14,1,1,5000,'SLOW_MOVING','CT-FK',false,'DISCOUNT','FRESH',date_trunc('second', now() AT TIME ZONE 'UTC'),NULL,31);" "fk_srtn_supplier"
expect_block "跨篇 FK：outbound_order.customer_id 指向不存在的客户" "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8904,'OBT-FK1',1,'SALE','MALL','M-FK1','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',999999,'CREATED','2026-10-16');" "fk_obo_customer"
expect_block "跨篇 FK：outbound_order.driver_id 指向不存在的司机" "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8905,'OBT-FK2',1,'SALE','MALL','M-FK2','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,999999,'CREATED','2026-10-16');" "fk_obo_driver"
expect_block "跨篇 FK：user_device_binding.device_id 指向不存在的设备" "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8906,'DEV-FK1','PDA',101,1,999999);" "fk_udb_device"
expect_allow "跨篇 FK 正向：user_device_binding.device_id 指向同事务内新建的设备" "BEGIN; INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8907,'D-FK-8907','PDA',1); INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8908,'DEV-FK2','PDA',101,1,8907); ROLLBACK;"
expect_allow "跨篇 FK 正向：user_device_binding.device_id = NULL（司机自有手机，设备列可空）" "BEGIN; INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (8916,'D-FK-8916','PDA',101,1); ROLLBACK;"
# 镜鉴 r65 重要 I1：本笔 5 条命名外键补齐**第三件（变异）**，并配「删父行被拦 / 去掉外键后删父行通过」。
# 变异 = 同一事务里 DROP 掉该外键后再执行原被拒语句；通过 = 证明拦它的确实是这条 FK（随后 ROLLBACK）。
# 删父行断言的父行一律在本事务内自建（9501–9504），保证事务里只有本事务这一条子行 → 命中的外键唯一、断言不抖。
mut_fk() { expect_allow "跨篇 FK 变异：去掉 $1 后，$2（随后回滚）" "BEGIN; ALTER TABLE $3 DROP CONSTRAINT $1; $4 ROLLBACK;"; }
mut_fk_del() { expect_allow "跨篇 FK 变异：去掉 $1 后，$2（随后回滚）" "BEGIN; ALTER TABLE $3 DROP CONSTRAINT $1; $4 $5 DELETE FROM $6 WHERE id=$7; ROLLBACK;"; }
_FKH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_FK_X_INB="INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8901,'INB-FK1',1,'PURCHASE','ERP','PO-FK1','$_FKH',999999,'RECEIVING','2026-10-15');"
_FK_X_SRTN="INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8903,'SRN-8903',1,999999,14,1,1,5000,'SLOW_MOVING','CT-FK',false,'DISCOUNT','FRESH',date_trunc('second', now() AT TIME ZONE 'UTC'),NULL,31);"
_FK_X_OBO_C="INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8904,'OBT-FK1',1,'SALE','MALL','M-FK1','$_FKH',999999,'CREATED','2026-10-16');"
_FK_X_OBO_D="INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8905,'OBT-FK2',1,'SALE','MALL','M-FK2','$_FKH',1,999999,'CREATED','2026-10-16');"
_FK_X_UDB="INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8906,'D-FK-8906','PDA',101,1,999999);"
_FK_P_SUP="INSERT INTO supplier (id,code,name) VALUES (9501,'SUP9501','变异用父行');"
_FK_P_CUS="INSERT INTO customer (id,code,name) VALUES (9502,'STORE9502','变异用门店');"
_FK_P_DRV="INSERT INTO driver (id,name,phone) VALUES (9503,'变异司机','13900139001');"
_FK_P_DEV="INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (9504,'D-FK-9504','PDA',1);"
_FK_C_INB="INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8911,'INB-FK3',1,'PURCHASE','ERP','PO-FK3','$_FKH',9501,'RECEIVING','2026-10-15');"
_FK_C_SRTN="INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8912,'SRN-8912',1,9501,14,1,1,5000,'SLOW_MOVING','CT-FK',false,'DISCOUNT','FRESH',date_trunc('second', now() AT TIME ZONE 'UTC'),NULL,31);"
_FK_C_OBO_C="INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8913,'OBT-FK3',1,'SALE','MALL','M-FK3','$_FKH',9502,'CREATED','2026-10-16');"
_FK_C_OBO_D="INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8914,'OBT-FK4',1,'SALE','MALL','M-FK4','$_FKH',9502,9503,'CREATED','2026-10-16');"
_FK_C_UDB="INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8915,'D-FK-9504','PDA',101,1,9504);"
mut_fk "fk_inb_supplier" "悬空 supplier_id 的入库单写入通过" "inbound_order" "$_FK_X_INB"
mut_fk "fk_srtn_supplier" "悬空 supplier_id 的退供单写入通过" "supplier_return" "$_FK_X_SRTN"
mut_fk "fk_obo_customer" "悬空 customer_id 的出库单写入通过" "outbound_order" "$_FK_X_OBO_C"
mut_fk "fk_obo_driver" "悬空 driver_id 的出库单写入通过" "outbound_order" "$_FK_X_OBO_D"
mut_fk "fk_udb_device" "悬空 device_id 的设备绑定写入通过" "user_device_binding" "$_FK_X_UDB"
expect_block "跨篇 FK：删被 inbound_order 引用的供应商被拦" "BEGIN; $_FK_P_SUP $_FK_C_INB DELETE FROM supplier WHERE id=9501; ROLLBACK;" "fk_inb_supplier"
mut_fk_del "fk_inb_supplier" "自建父行与子行后删供应商通过" "inbound_order" "$_FK_P_SUP" "$_FK_C_INB" "supplier" "9501"
expect_block "跨篇 FK：删被 supplier_return 引用的供应商被拦" "BEGIN; $_FK_P_SUP $_FK_C_SRTN DELETE FROM supplier WHERE id=9501; ROLLBACK;" "fk_srtn_supplier"
mut_fk_del "fk_srtn_supplier" "自建父行与子行后删供应商通过" "supplier_return" "$_FK_P_SUP" "$_FK_C_SRTN" "supplier" "9501"
expect_block "跨篇 FK：删被 outbound_order 引用的门店被拦" "BEGIN; $_FK_P_CUS $_FK_C_OBO_C DELETE FROM customer WHERE id=9502; ROLLBACK;" "fk_obo_customer"
mut_fk_del "fk_obo_customer" "自建父行与子行后删门店通过" "outbound_order" "$_FK_P_CUS" "$_FK_C_OBO_C" "customer" "9502"
expect_block "跨篇 FK：删被 outbound_order 引用的司机被拦" "BEGIN; $_FK_P_CUS $_FK_P_DRV $_FK_C_OBO_D DELETE FROM driver WHERE id=9503; ROLLBACK;" "fk_obo_driver"
mut_fk_del "fk_obo_driver" "自建父行与子行后删司机通过" "outbound_order" "$_FK_P_CUS $_FK_P_DRV" "$_FK_C_OBO_D" "driver" "9503"
expect_block "跨篇 FK：删被 user_device_binding 引用的设备被拦" "BEGIN; $_FK_P_DEV $_FK_C_UDB DELETE FROM device WHERE id=9504; ROLLBACK;" "fk_udb_device"
mut_fk_del "fk_udb_device" "自建父行与子行后删设备通过" "user_device_binding" "$_FK_P_DEV" "$_FK_C_UDB" "device" "9504"
echo "=== 2t. docs/05 波次与拣货：本轮新增 12 个 CHECK / 8 个外键 / ix_pt_handover 的三件套（正向 / 按名拒绝 / 变异）==="
# 变异 = 同一事务里去掉该约束再执行原被拒语句，必须变成通过，然后 ROLLBACK（证明拒绝确实来自该约束）
mut05() { expect_allow "05 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3 ROLLBACK;"; }
seed "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9101,'W-9101',1,'2026-10-15','CHILLED','R1','PLANNED');"
expect_allow "05 正向：波次 + 任务 + 任务行（12 个 CHECK / 8 个外键全满足）" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type,zone_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9101,'PT-9101',9101,1,'PICK',1,'EXECUTING',41,'D9101',1,0); INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9101,9101,1,1,1,1,11,1,1000,1000,'KG','DONE');"
expect_block "05 拒绝：ck_wave_status 非法状态值" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9102,'W-9102',1,'2026-10-15','CHILLED','R1','BOGUS');" "ck_wave_status"
mut05 "ck_wave_status" "wave" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9102,'W-9102',1,'2026-10-15','CHILLED','R1','BOGUS');"
expect_block "05 拒绝：ck_wave_strategy 非法拣货策略" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,pick_strategy) VALUES (9103,'W-9103',1,'2026-10-15','CHILLED','R1','BOGUS');" "ck_wave_strategy"
mut05 "ck_wave_strategy" "wave" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,pick_strategy) VALUES (9103,'W-9103',1,'2026-10-15','CHILLED','R1','BOGUS');"
expect_block "05 拒绝：ck_wave_parent 自指父波次" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,parent_wave_id) VALUES (9104,'W-9104',1,'2026-10-15','CHILLED','R1',9104);" "ck_wave_parent"
expect_allow "05 变异：去掉 ck_wave_parent 与环守卫后，自指波次通过（随后回滚）" "BEGIN; ALTER TABLE wave DROP CONSTRAINT ck_wave_parent; DROP TRIGGER trg_wave_parent_cycle ON wave; INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,parent_wave_id) VALUES (9104,'W-9104',1,'2026-10-15','CHILLED','R1',9104); ROLLBACK;"
expect_block "05 拒绝：ck_wave_count 汇总量为负" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,order_count) VALUES (9105,'W-9105',1,'2026-10-15','CHILLED','R1',-1);" "ck_wave_count"
mut05 "ck_wave_count" "wave" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,order_count) VALUES (9105,'W-9105',1,'2026-10-15','CHILLED','R1',-1);"
expect_block "05 拒绝：ck_pt_type 非法任务类型" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type) VALUES (9104,'PT-9104',9101,1,'BOGUS');" "ck_pt_type"
mut05 "ck_pt_type" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type) VALUES (9104,'PT-9104',9101,1,'BOGUS');"
expect_block "05 拒绝：ck_pt_status 非法任务状态" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9105,'PT-9105',9101,1,'BOGUS');" "ck_pt_status"
mut05 "ck_pt_status" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9105,'PT-9105',9101,1,'BOGUS');"
expect_block "05 拒绝：ck_pt_exec EXECUTING 没有持有人与设备" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9106,'PT-9106',9101,1,'EXECUTING');" "ck_pt_exec"
mut05 "ck_pt_exec" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9106,'PT-9106',9101,1,'EXECUTING');"
expect_block "05 拒绝：ck_pt_count done_count 大于 line_count" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,line_count,done_count) VALUES (9107,'PT-9107',9101,1,1,2);" "ck_pt_count"
mut05 "ck_pt_count" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,line_count,done_count) VALUES (9107,'PT-9107',9101,1,1,2);"
expect_block "05 拒绝：ck_pt_handover 交接来源指向自身" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,handover_from_task_id) VALUES (9108,'PT-9108',9101,1,9108);" "ck_pt_handover"
expect_allow "05 变异：去掉 ck_pt_handover 与环守卫后，自指交接通过（随后回滚）" "BEGIN; ALTER TABLE pick_task DROP CONSTRAINT ck_pt_handover; DROP TRIGGER trg_pt_handover_cycle ON pick_task; INSERT INTO pick_task (id,code,wave_id,warehouse_id,handover_from_task_id) VALUES (9108,'PT-9108',9101,1,9108); ROLLBACK;"
expect_block "05 拒绝：ck_ptl_status 非法任务行状态" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9102,9101,2,1,1,1,11,1000,'KG','BOGUS');" "ck_ptl_status"
mut05 "ck_ptl_status" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9102,9101,2,1,1,1,11,1000,'KG','BOGUS');"
expect_block "05 拒绝：ck_ptl_short SHORT 行缺原因码" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9103,9101,3,1,1,1,11,1000,'KG','SHORT');" "ck_ptl_short"
mut05 "ck_ptl_short" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9103,9101,3,1,1,1,11,1000,'KG','SHORT');"
expect_block "05 拒绝：ck_ptl_short 原因码不在白名单" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,short_reason_code) VALUES (9105,9101,5,1,1,1,11,1000,'KG','BOGUS');" "ck_ptl_short"
mut05 "ck_ptl_short" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,short_reason_code) VALUES (9105,9101,5,1,1,1,11,1000,'KG','BOGUS');"
expect_block "05 拒绝：ck_ptl_override 越权原因缺越权人" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,override_reason) VALUES (9104,9101,4,1,1,1,11,1000,'KG','FEFO_SKIP');" "ck_ptl_override"
mut05 "ck_ptl_override" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,override_reason) VALUES (9104,9101,4,1,1,1,11,1000,'KG','FEFO_SKIP');"
expect_block "05 拒绝：fk_pt_wave 任务挂不存在的波次" "INSERT INTO pick_task (id,code,wave_id,warehouse_id) VALUES (9109,'PT-9109',999999,1);" "fk_pt_wave"
mut05 "fk_pt_wave" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id) VALUES (9109,'PT-9109',999999,1);"
expect_block "05 拒绝：fk_pt_zone 任务挂不存在的库区" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,zone_id) VALUES (9110,'PT-9110',9101,1,999999);" "fk_pt_zone"
mut05 "fk_pt_zone" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,zone_id) VALUES (9110,'PT-9110',9101,1,999999);"
expect_block "05 拒绝：fk_ptl_task 任务行挂不存在的任务" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9106,999999,1,1,1,1,11,1000,'KG');" "fk_ptl_task"
mut05 "fk_ptl_task" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9106,999999,1,1,1,1,11,1000,'KG');"
expect_block "05 拒绝：fk_ptl_stock 任务行挂不存在的库存行" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9107,9101,6,1,1,1,999999,1000,'KG');" "fk_ptl_stock"
mut05 "fk_ptl_stock" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9107,9101,6,1,1,1,999999,1000,'KG');"
expect_block "05 拒绝：fk_ptl_location 任务行挂不存在的库位" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9108,9101,7,999999,1,1,11,1000,'KG');" "fk_ptl_location"
mut05 "fk_ptl_location" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9108,9101,7,999999,1,1,11,1000,'KG');"
expect_block "05 拒绝：fk_ptl_sku 任务行挂不存在的 SKU" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9109,9101,8,1,999999,1,11,1000,'KG');" "fk_ptl_sku"
mut05 "fk_ptl_sku" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9109,9101,8,1,999999,1,11,1000,'KG');"
expect_block "05 拒绝：fk_ptl_lot 任务行挂不存在的批次" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9110,9101,9,1,1,999999,11,1000,'KG');" "fk_ptl_lot"
mut05 "fk_ptl_lot" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9110,9101,9,1,1,999999,11,1000,'KG');"
expect_block "05 拒绝：fk_ptl_obl 任务行挂不存在的出库行" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,uom) VALUES (9111,9101,10,1,1,1,11,999999,1000,'KG');" "fk_ptl_obl"
mut05 "fk_ptl_obl" "pick_task_line" "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,uom) VALUES (9111,9101,10,1,1,1,11,999999,1000,'KG');"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_pt_handover' AND indexdef LIKE '%handover_from_task_id IS NOT NULL%'")
[ "$R" = "1" ] && ok "05 目录：ix_pt_handover 存在且是 handover_from_task_id 的部分索引" || bad "05 目录：ix_pt_handover = $R"
expect_allow "05 变异：去掉 ix_pt_handover 后，目录断言会变红（随后回滚）" "BEGIN; DROP INDEX ix_pt_handover; ROLLBACK;"
# P25-2（可证伪）：SKIP / ABNORMAL 行不算完成——任务不得凭它们进 DONE（否则该行余量既不 release 也不转 SHORT，04 会当成拣满）
seed "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9301,'PT-9301',9101,1,'EXECUTING',41,'D9101',1,0);"
seed "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9301,9301,1,1,1,1,11,1000,0,'KG','SKIP');"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task SET status='DONE' WHERE id=9301 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9301 AND l.status IN ('PENDING','SKIP','ABNORMAL')) RETURNING 1) SELECT count(*) FROM u")
[ "$R" = "0" ] && ok "05 P25-2：任务里有 SKIP 行（confirmed < planned）时 T-done 守卫命中 0 行（不得进 DONE）" || bad "05 P25-2：T-done 守卫 = $R 行（期望 0）"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task SET status='DONE' WHERE id=9301 AND status='EXECUTING' RETURNING 1) SELECT count(*) FROM u")
[ "$R" = "1" ] && ok "05 P25-2 变异：去掉 NOT EXISTS 守卫后同一 UPDATE 命中 1 行（守卫是拦它的那条）" || bad "05 P25-2 变异：$R 行（期望 1）"
echo "=== 2u. docs/06 复核装箱发货：本轮新增 4 个 CHECK / 9 个外键的三件套（正向 / 按名拒绝 / 变异）==="
# 变异 = 同一事务里去掉该约束再执行原被拒语句，必须变成通过，然后 ROLLBACK（证明拒绝确实来自该约束）
mut06() { expect_allow "06 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3 ROLLBACK;"; }
expect_allow "06 正向：交接车次 HANDED_OVER + 箱 SEALED + 箱明细（4 个 CHECK / 9 个外键全满足）" "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9201,'SHP-9201',1,'HANDED_OVER'); INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,1); INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id,stage_location_id,box_type,weight_g,sealed,checker_id,packed_at) VALUES (9201,'BOX-9201',1,1,9201,1,'CARTON',1500.00,true,41,'2026-10-15 09:00:00'); INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9201,9201,1,0,1000,'KG');"
expect_allow "06 正向：车次 CANCELLED" "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9202,'SHP-9202',1,'CANCELLED');"
expect_block "06 拒绝：ck_box_type 非法箱型" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,box_type) VALUES (9203,'BOX-9203',1,1,'BOGUS');" "ck_box_type"
mut06 "ck_box_type" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,box_type) VALUES (9203,'BOX-9203',1,1,'BOGUS');"
expect_block "06 拒绝：ck_box_weight 重量为负" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,weight_g) VALUES (9204,'BOX-9204',1,1,-1);" "ck_box_weight"
mut06 "ck_box_weight" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,weight_g) VALUES (9204,'BOX-9204',1,1,-1);"
expect_block "06 拒绝：ck_box_sealed 未封箱却标封箱" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,sealed) VALUES (9205,'BOX-9205',1,1,true);" "ck_box_sealed"
mut06 "ck_box_sealed" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,sealed) VALUES (9205,'BOX-9205',1,1,true);"
expect_block "06 拒绝：ck_shp_status 非法车次状态" "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9203,'SHP-9203',1,'BOGUS');" "ck_shp_status"
mut06 "ck_shp_status" "shipment" "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9203,'SHP-9203',1,'BOGUS');"
expect_block "06 拒绝：fk_shp_wh 车次挂不存在的仓" "INSERT INTO shipment (id,code,warehouse_id) VALUES (9204,'SHP-9204',999999);" "fk_shp_wh"
mut06 "fk_shp_wh" "shipment" "INSERT INTO shipment (id,code,warehouse_id) VALUES (9204,'SHP-9204',999999);"
expect_block "06 拒绝：fk_sho_shipment 挂单指向不存在的车次" "INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (999999,1);" "fk_sho_shipment"
mut06 "fk_sho_shipment" "shipment_order" "INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (999999,1);"
expect_block "06 拒绝：fk_sho_outbound 挂单指向不存在的出库单" "INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,999999);" "fk_sho_outbound"
mut06 "fk_sho_outbound" "shipment_order" "INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,999999);"
expect_block "06 拒绝：fk_box_wh 箱挂不存在的仓" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9206,'BOX-9206',999999,1);" "fk_box_wh"
mut06 "fk_box_wh" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9206,'BOX-9206',999999,1);"
expect_block "06 拒绝：fk_box_outbound 箱挂不存在的出库单" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9207,'BOX-9207',1,999999);" "fk_box_outbound"
mut06 "fk_box_outbound" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9207,'BOX-9207',1,999999);"
expect_block "06 拒绝：fk_box_shipment 箱挂不存在的车次" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id) VALUES (9208,'BOX-9208',1,1,999999);" "fk_box_shipment"
mut06 "fk_box_shipment" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id) VALUES (9208,'BOX-9208',1,1,999999);"
expect_block "06 拒绝：fk_box_stage 箱挂不存在的集货位" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,stage_location_id) VALUES (9209,'BOX-9209',1,1,999999);" "fk_box_stage"
mut06 "fk_box_stage" "pack_box" "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,stage_location_id) VALUES (9209,'BOX-9209',1,1,999999);"
expect_block "06 拒绝：fk_bxl_box 箱明细挂不存在的箱" "INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9202,999999,1,0,1000,'KG');" "fk_bxl_box"
mut06 "fk_bxl_box" "pack_box_line" "INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9202,999999,1,0,1000,'KG');"
expect_block "06 拒绝：fk_bxl_sku 箱明细挂不存在的 SKU" "INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9203,9201,999999,0,1000,'KG');" "fk_bxl_sku"
mut06 "fk_bxl_sku" "pack_box_line" "INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9203,9201,999999,0,1000,'KG');"
echo "=== 2g-12t. 第 12 篇时间加固第二轮：正向放行 + 反向按名拦截 + 变异（两库对称）==="
# 三件套：① 正向（非属主写入被库覆盖成 now）② 反向（按错误名精确命中）③ 变异（去掉守卫后原被拒语句必须通过）
# 触发器只对非属主生效（属主 = 迁移/种子角色，有意豁免），所以全部用 SET LOCAL ROLE wms_app。
R=$(psql -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash,created_at) VALUES (779901,'t12t1','x','2000-01-01 00:00:00'); SELECT 'TS#' || (created_at = date_trunc('second', now() AT TIME ZONE 'UTC'))::text FROM sys_user WHERE id = 779901; ROLLBACK;" | grep '^TS#')
[ "$R" = "TS#true" ] && ok "12t 正向：wms_app 建号 created_at 传 2000 → 由库写为 now" || bad "12t 正向 created_at 未被库写：$R"
R=$(psql -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash) VALUES (779902,'t12t2','x'); UPDATE sys_user SET last_login_at = date_trunc('second', now() AT TIME ZONE 'UTC') WHERE id = 779902; SELECT 'TS#' || (last_login_at = date_trunc('second', now() AT TIME ZONE 'UTC'))::text FROM sys_user WHERE id = 779902; ROLLBACK;" | grep '^TS#')
[ "$R" = "TS#true" ] && ok "12t 正向：wms_app 写登录时间 = now → 通过且与库值一致" || bad "12t 正向 last_login_at：$R"
R=$(psql -t -A -c "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash) VALUES (779903,'t12t3','x'); UPDATE sys_user SET deleted_at = date_trunc('second', now() AT TIME ZONE 'UTC') WHERE id = 779903; SELECT 'TS#' || (deleted_at = date_trunc('second', now() AT TIME ZONE 'UTC'))::text FROM sys_user WHERE id = 779903; ROLLBACK;" | grep '^TS#')
[ "$R" = "TS#true" ] && ok "12t 正向：wms_app 写停用时间 = now → 通过；trg_user_status_bump 同步升 perm_version" || bad "12t 正向 deleted_at：$R"
expect_block "12t 反向：INSERT sys_user 带 last_login_at（新用户没登录过）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash,last_login_at) VALUES (779904,'t12t4','x','2000-01-01 00:00:00'); ROLLBACK;" "sys_user_insert_time_set"
expect_block "12t 反向：INSERT sys_user 带 deleted_at（新用户不是停用态）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash,deleted_at) VALUES (779905,'t12t5','x','2000-01-01 00:00:00'); ROLLBACK;" "sys_user_insert_time_set"
expect_block "12t 反向：UPDATE sys_user 改建号时间（created_at 不可改）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash) VALUES (779906,'t12t6','x'); UPDATE sys_user SET created_at = '2000-01-01 00:00:00' WHERE id = 779906; ROLLBACK;" "sys_user_created_at_immutable"
expect_block "12t 反向：UPDATE sys_user 清空停用时间（停用是事实，不可回退）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO sys_user (id,username,password_hash) VALUES (779907,'t12t7','x'); UPDATE sys_user SET deleted_at = date_trunc('second', now() AT TIME ZONE 'UTC') WHERE id = 779907; UPDATE sys_user SET deleted_at = NULL WHERE id = 779907; ROLLBACK;" "sys_user_deleted_at_immutable"
expect_block "12t 反向：INSERT api_credential 带 last_used_at（新凭证没用过）" "BEGIN; SET LOCAL ROLE wms_app; INSERT INTO api_credential (id,api_key,secret_encrypted,source_system,last_used_at) VALUES (779908,'K779908','s','ERP','2000-01-01 00:00:00'); ROLLBACK;" "api_credential_insert_time_set"
expect_block "12t 反向：属主建号 created_at 带小数秒（属主豁免覆盖，但整秒 CHECK 仍管）" "INSERT INTO sys_user (id,username,password_hash,created_at) VALUES (779909,'t12t9','x','2026-10-15 08:00:00.5');" "ck_user_ts"
R=$(psql -t -A <<MUT12T | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_user_zclock ON sys_user;
SET LOCAL ROLE wms_app;
INSERT INTO sys_user (id,username,password_hash,last_login_at) VALUES (779911,'t12tm1','x','2000-01-01 00:00:00');
SELECT 'MUT#PASSED';
ROLLBACK;
MUT12T
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_user_zclock 后带 last_login_at 的 INSERT 通过（断言能抓到）" || bad "变异没变红：trg_user_zclock → $R"
R=$(psql -t -A <<MUT12T | grep '^MUT#'
BEGIN;
DROP TRIGGER trg_api_zclock ON api_credential;
SET LOCAL ROLE wms_app;
INSERT INTO api_credential (id,api_key,secret_encrypted,source_system,last_used_at) VALUES (779912,'K779912','s','ERP','2000-01-01 00:00:00');
SELECT 'MUT#PASSED';
ROLLBACK;
MUT12T
)
[ "$R" = "MUT#PASSED" ] && ok "变异：去掉 trg_api_zclock 后带 last_used_at 的 INSERT 通过（断言能抓到）" || bad "变异没变红：trg_api_zclock → $R"
echo "=== 2v. docs/08 盘点与调整：本轮新增 10 个 CHECK / 8 个外键 / 5 条索引 + uq_adjl 的三件套（正向 / 按名拒绝 / 变异）==="
# 变异 = 同一事务里去掉该约束再执行原被拒语句，必须变成通过，然后 ROLLBACK（证明拒绝确实来自该约束）。
# ck_cnt_int / ck_adj_int（量必须整 milli）在 PG 侧由列类型 BIGINT 直接保证：CHECK 恒真，写 1.5 只会被四舍五入，
# 没有可证伪的"被拒语句"，所以这两条在 PG 只做目录断言；SQLite 侧的 1.5 反证见 "2e. count_line 整数约束"。
mut08() { expect_allow "08 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3 ROLLBACK;"; }
expect_allow "08 正向：盘点单 + 盘点行（COUNTING/RECOUNTED，ck_cnt_*、ck_cntl_*、fk_cnt_wh/fk_cntl_* 全满足）" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at,created_by) VALUES (9401,'CNT-SH01-9401-20261015-000001',1,'CYCLE','{}','COUNTING','2026-10-15 02:00:00',41); INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,recount_qty_milli,status,counted_by,counted_at) VALUES (9411,9401,1,1,1,100000,-30000,68000,69000,'RECOUNTED',41,'2026-10-15 03:00:00');"
expect_allow "08 正向：调整单 + 调整行（ck_adj_*、fk_adj_wh/fk_adjl_order 全满足）" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9421,'ADJ-SH01-9401-20261015-000001',1,'COUNT_LOSS','COUNT_DIFF','PENDING',41); INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9431,9421,1,11,-2000);"
expect_allow "08 正向：盘点行回指调整单 + 同一调整单第 2 行（fk_cntl_adjust / uq_adjl 多行不撞）" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at,adjust_id) VALUES (9412,9401,2,1,1,1000,0,900,'COUNTED',41,'2026-10-15 03:05:00',9421); INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9432,9421,2,12,3000);"
expect_block "08 拒绝：ck_cnt_type 非法盘点类型" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9402,'CNT-SH01-9402-20261015-000002',1,'BOGUS','{}','2026-10-15 02:00:00');" "ck_cnt_type"
mut08 "ck_cnt_type" "count_order" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9402,'CNT-SH01-9402-20261015-000002',1,'BOGUS','{}','2026-10-15 02:00:00');"
expect_block "08 拒绝：ck_cnt_status 非法盘点单状态" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (9403,'CNT-SH01-9403-20261015-000003',1,'FULL','{}','BOGUS','2026-10-15 02:00:00');" "ck_cnt_status"
mut08 "ck_cnt_status" "count_order" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (9403,'CNT-SH01-9403-20261015-000003',1,'FULL','{}','BOGUS','2026-10-15 02:00:00');"
expect_block "08 拒绝：ck_cnt_approved 盘点审批人与创建人同一人" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at,created_by,approved_by) VALUES (9404,'CNT-SH01-9404-20261015-000004',1,'FULL','{}','2026-10-15 02:00:00',41,41);" "ck_cnt_approved"
mut08 "ck_cnt_approved" "count_order" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at,created_by,approved_by) VALUES (9404,'CNT-SH01-9404-20261015-000004',1,'FULL','{}','2026-10-15 02:00:00',41,41);"
expect_block "08 拒绝：ck_adj_type 非法调整类型" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9422,'ADJ-SH01-9402-20261015-000002',1,'BOGUS','COUNT_DIFF',41);" "ck_adj_type"
mut08 "ck_adj_type" "adjust_order" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9422,'ADJ-SH01-9402-20261015-000002',1,'BOGUS','COUNT_DIFF',41);"
expect_block "08 拒绝：ck_adj_status 非法调整单状态" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9423,'ADJ-SH01-9403-20261015-000003',1,'MANUAL','COUNT_DIFF','BOGUS',41);" "ck_adj_status"
mut08 "ck_adj_status" "adjust_order" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9423,'ADJ-SH01-9403-20261015-000003',1,'MANUAL','COUNT_DIFF','BOGUS',41);"
expect_block "08 拒绝：ck_adj_sod 调整单审批人与申请人同一人" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id,approver_id) VALUES (9424,'ADJ-SH01-9404-20261015-000004',1,'MANUAL','COUNT_DIFF',41,41);" "ck_adj_sod"
mut08 "ck_adj_sod" "adjust_order" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id,approver_id) VALUES (9424,'ADJ-SH01-9404-20261015-000004',1,'MANUAL','COUNT_DIFF',41,41);"
expect_block "08 拒绝：ck_adj_delta 调整量为 0（既不盘盈也不盘亏）" "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9433,9421,3,11,0);" "ck_adj_delta"
mut08 "ck_adj_delta" "adjust_line" "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9433,9421,3,11,0);"
expect_block "08 拒绝：ck_cntl_status 非法盘点行状态" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at) VALUES (9413,9401,3,1,2,1000,0,1000,'BOGUS',41,'2026-10-15 03:10:00');" "ck_cntl_status"
mut08 "ck_cntl_status" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at) VALUES (9413,9401,3,1,2,1000,0,1000,'BOGUS',41,'2026-10-15 03:10:00');"
expect_block "08 拒绝：ck_cntl_counted 已盘点却没写实盘量" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,status,counted_at) VALUES (9414,9401,3,2,1,1000,0,'COUNTED','2026-10-15 03:15:00');" "ck_cntl_counted"
mut08 "ck_cntl_counted" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,status,counted_at) VALUES (9414,9401,3,2,1,1000,0,'COUNTED','2026-10-15 03:15:00');"
expect_block "08 拒绝：ck_cntl_recount 未实盘就写复盘量" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,recount_qty_milli) VALUES (9415,9401,2,1,2,1000,0,1000);" "ck_cntl_recount"
mut08 "ck_cntl_recount" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,recount_qty_milli) VALUES (9415,9401,2,1,2,1000,0,1000);"
R=$(psql -t -A -c "SELECT count(*) FROM pg_constraint WHERE conname='ck_cnt_int' AND contype='c'")
[ "$R" = "1" ] && ok "08 目录：ck_cnt_int 存在（基准/期间/实盘/复盘量必须是整 milli；SQLite 侧另有 1.5 反证）" || bad "08 目录：ck_cnt_int = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_constraint WHERE conname='ck_adj_int' AND contype='c'")
[ "$R" = "1" ] && ok "08 目录：ck_adj_int 存在（调整量必须是整 milli；SQLite 侧另有 1.5 反证）" || bad "08 目录：ck_adj_int = $R"
expect_block "08 拒绝：fk_cnt_wh 盘点单挂不存在的仓" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9405,'CNT-SH01-9405-20261015-000005',999999,'FULL','{}','2026-10-15 02:00:00');" "fk_cnt_wh"
mut08 "fk_cnt_wh" "count_order" "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9405,'CNT-SH01-9405-20261015-000005',999999,'FULL','{}','2026-10-15 02:00:00');"
expect_block "08 拒绝：fk_adj_wh 调整单挂不存在的仓" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9425,'ADJ-SH01-9405-20261015-000005',999999,'MANUAL','COUNT_DIFF',41);" "fk_adj_wh"
mut08 "fk_adj_wh" "adjust_order" "INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9425,'ADJ-SH01-9405-20261015-000005',999999,'MANUAL','COUNT_DIFF',41);"
expect_block "08 拒绝：fk_adjl_order 调整行挂不存在的调整单" "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9434,999999,9,11,100);" "fk_adjl_order"
mut08 "fk_adjl_order" "adjust_line" "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9434,999999,9,11,100);"
expect_block "08 拒绝：fk_cntl_count 盘点行挂不存在的盘点单" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9416,999999,1,1,1,1000);" "fk_cntl_count"
mut08 "fk_cntl_count" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9416,999999,1,1,1,1000);"
expect_block "08 拒绝：fk_cntl_adjust 盘点行挂不存在的调整单" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,adjust_id) VALUES (9417,9401,3,1,3,1000,999999);" "fk_cntl_adjust"
mut08 "fk_cntl_adjust" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,adjust_id) VALUES (9417,9401,3,1,3,1000,999999);"
expect_block "08 拒绝：fk_cntl_loc 盘点行挂不存在的库位" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9418,9401,999999,1,1,1000);" "fk_cntl_loc"
mut08 "fk_cntl_loc" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9418,9401,999999,1,1,1000);"
expect_block "08 拒绝：fk_cntl_sku 盘点行挂不存在的 SKU" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9419,9401,1,999999,1,1000);" "fk_cntl_sku"
mut08 "fk_cntl_sku" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9419,9401,1,999999,1,1000);"
expect_block "08 拒绝：fk_cntl_lot 盘点行挂不存在的批次" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9420,9401,1,1,999999,1000);" "fk_cntl_lot"
mut08 "fk_cntl_lot" "count_line" "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9420,9401,1,1,999999,1000);"
expect_block "08 拒绝：uq_adjl 同一调整单同一 line_no 重复（02 记账幂等键 {biz_no}:{line_no}）" "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9435,9421,1,13,500);" "uq_adjl"
R=$(psql -t -A -c "SELECT count(*) FROM pg_constraint WHERE conname='uq_adjl' AND contype='u'")
[ "$R" = "1" ] && ok "08 目录：uq_adjl 存在（02 记账幂等键 {biz_no}:{line_no}:D{op_no}:{leg} 的行号唯一）" || bad "08 目录：uq_adjl = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_wh' AND tablename='count_order' AND indexdef LIKE '%(warehouse_id, status, created_at)%'")
[ "$R" = "1" ] && ok "08 目录：ix_cnt_wh 存在且挂在 count_order(warehouse_id, status, created_at)" || bad "08 目录：ix_cnt_wh = $R"
R=$(psql -t -A -c "BEGIN; DROP INDEX ix_cnt_wh; SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_wh'; ROLLBACK;" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$R" = "0" ] && ok "08 变异：去掉 ix_cnt_wh 后目录断言命中 0（随后回滚）" || bad "08 变异：去掉 ix_cnt_wh 后 = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_adj_wh' AND tablename='adjust_order' AND indexdef LIKE '%(warehouse_id, status, created_at)%'")
[ "$R" = "1" ] && ok "08 目录：ix_adj_wh 存在且挂在 adjust_order(warehouse_id, status, created_at)" || bad "08 目录：ix_adj_wh = $R"
R=$(psql -t -A -c "BEGIN; DROP INDEX ix_adj_wh; SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_adj_wh'; ROLLBACK;" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$R" = "0" ] && ok "08 变异：去掉 ix_adj_wh 后目录断言命中 0（随后回滚）" || bad "08 变异：去掉 ix_adj_wh 后 = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_adj_src' AND tablename='adjust_order' AND indexdef LIKE '%(source_type, source_id)%'")
[ "$R" = "1" ] && ok "08 目录：ix_adj_src 存在且挂在 adjust_order(source_type, source_id)" || bad "08 目录：ix_adj_src = $R"
R=$(psql -t -A -c "BEGIN; DROP INDEX ix_adj_src; SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_adj_src'; ROLLBACK;" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$R" = "0" ] && ok "08 变异：去掉 ix_adj_src 后目录断言命中 0（随后回滚）" || bad "08 变异：去掉 ix_adj_src 后 = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_line_count' AND tablename='count_line' AND indexdef LIKE '%(count_id, status)%'")
[ "$R" = "1" ] && ok "08 目录：ix_cnt_line_count 存在且挂在 count_line(count_id, status)" || bad "08 目录：ix_cnt_line_count = $R"
R=$(psql -t -A -c "BEGIN; DROP INDEX ix_cnt_line_count; SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_line_count'; ROLLBACK;" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$R" = "0" ] && ok "08 变异：去掉 ix_cnt_line_count 后目录断言命中 0（随后回滚）" || bad "08 变异：去掉 ix_cnt_line_count 后 = $R"
R=$(psql -t -A -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_line_loc' AND tablename='count_line' AND indexdef LIKE '%(location_id)%'")
[ "$R" = "1" ] && ok "08 目录：ix_cnt_line_loc 存在且挂在 count_line(location_id)" || bad "08 目录：ix_cnt_line_loc = $R"
R=$(psql -t -A -c "BEGIN; DROP INDEX ix_cnt_line_loc; SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='ix_cnt_line_loc'; ROLLBACK;" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$R" = "0" ] && ok "08 变异：去掉 ix_cnt_line_loc 后目录断言命中 0（随后回滚）" || bad "08 变异：去掉 ix_cnt_line_loc 后 = $R"
echo "=== 2t2. docs/05 增量：空串设备号 / 父子链·改派链环守卫 / 撤销回退行状态（正向 / 按名拒绝 / 变异）==="
# 变异 = 同一事务里去掉该守卫再执行原被拒语句，必须变成通过，然后 ROLLBACK（证明拒绝确实来自该守卫）
mut_trg05() { expect_allow "05 增量变异：去掉触发器 $1 后，原被拒语句通过（随后回滚）" "BEGIN; DROP TRIGGER $1 ON $2; $3 ROLLBACK;"; }
# ① 空串设备号（镜鉴 r5 重要项①）：ck_pt_device 与 ck_pt_exec 各管一件事，EXECUTING + 空串必须撞 ck_pt_device
expect_block "05 增量①：ck_pt_device 拒非空的空串设备号" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9401,'PT-9401',9101,1,'');" "ck_pt_device"
mut05 "ck_pt_device" "pick_task" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9401,'PT-9401',9101,1,'');"
expect_block "05 增量①：EXECUTING + 空串设备也一样撞 ck_pt_device（旧 ck_pt_exec 放行的那条）" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id) VALUES (9402,'PT-9402',9101,1,'EXECUTING',41,'');" "ck_pt_device"
# r6 加固（镜鉴）：'' 之外，全空格与制表符也必须拒（否则 P{设备}.{op_seq} 仍会退化）
expect_block "05 增量①r6：ck_pt_device 拒全空格设备号" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9406,'PT-9406',9101,1,'   ');" "ck_pt_device"
expect_block "05 增量①r6：ck_pt_device 拒制表符/换行组成的设备号" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9407,'PT-9407',9101,1,E'\t\n');" "ck_pt_device"
expect_allow "05 增量①r6 正向：设备号两侧带空格的合法值仍可落库" "INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9408,'PT-9408',9101,1,' D9408 ');"
# ② 环守卫（镜鉴 r5 重要项②）：合法链通过，两点成环在 UPDATE / INSERT 两条路径上都被拒
seed "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9201,'W-9201',1,'2026-10-15','CHILLED','R1','PLANNED',NULL);"
seed "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9202,'W-9202',1,'2026-10-15','CHILLED','R1','PLANNED',9201);"
expect_allow "05 增量②正向：合法父子链（9203 → 9202 → 9201）" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9203,'W-9203',1,'2026-10-15','CHILLED','R1','PLANNED',9202);"
expect_block "05 增量②：trg_wave_parent_cycle 拒两点成环（UPDATE 闭合 9201 → 9202）" "UPDATE wave SET parent_wave_id=9202 WHERE id=9201;" "wave_parent_cycle"
mut_trg05 "trg_wave_parent_cycle" "wave" "UPDATE wave SET parent_wave_id=9202 WHERE id=9201;"
expect_allow "05 增量②：悬空父指针仍可落库（无自引用外键，见 §12 Q14）" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9206,'W-9206',1,'2026-10-15','CHILLED','R1','PLANNED',9205);"
expect_block "05 增量②：INSERT 补上第二条边成环也被拒（9205 → 9206 → 9205）" "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9205,'W-9205',1,'2026-10-15','CHILLED','R1','PLANNED',9206);" "wave_parent_cycle"
# r6 加固（镜鉴）：旧 SQLite 递归只走 64 行，65 节链闭合会漏检——两库对 65 节链都必须报 cycle；
# 已存在的 >64 节深链（触发器禁用期间造的）两库都必须报 depth，不许静默放行。
seed "INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) SELECT g, 'W-C'||g, 1, '2026-10-15', 'CHILLED', 'R1', 'PLANNED', CASE WHEN g=9601 THEN NULL ELSE g-1 END FROM generate_series(9601,9665) g;"
expect_block "05 增量②r6：65 节链闭合报 wave_parent_cycle（旧 SQLite 递归上限漏检的那条）" "UPDATE wave SET parent_wave_id=9665 WHERE id=9601;" "wave_parent_cycle"
expect_block "05 增量②r6：已存在的 66 节深链再闭合报 wave_parent_cycle_depth（两库同口径）" "BEGIN; ALTER TABLE wave DISABLE TRIGGER trg_wave_parent_cycle; INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) SELECT g, 'W-E'||g, 1, '2026-10-15', 'CHILLED', 'R1', 'PLANNED', CASE WHEN g=9701 THEN NULL ELSE g-1 END FROM generate_series(9701,9766) g; ALTER TABLE wave ENABLE TRIGGER trg_wave_parent_cycle; UPDATE wave SET parent_wave_id=9766 WHERE id=9701; ROLLBACK;" "wave_parent_cycle_depth"
seed "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id) VALUES (9403,'PT-9403',9201,1,'EXECUTING',41,'D9403');"
seed "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,handover_from_task_id) VALUES (9404,'PT-9404',9201,1,'EXECUTING',42,'D9404',9403);"
expect_block "05 增量②：trg_pt_handover_cycle 拒改派链成环（9403 → 9404 → 9403）" "UPDATE pick_task SET handover_from_task_id=9404 WHERE id=9403;" "pick_task_handover_cycle"
mut_trg05 "trg_pt_handover_cycle" "pick_task" "UPDATE pick_task SET handover_from_task_id=9404 WHERE id=9403;"
R=$(psql -t -A -c "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_wave_parent_cycle','trg_pt_handover_cycle')")
[ "$R" = "2" ] && ok "05 增量②目录：两个环守卫触发器都在（$R）" || bad "05 增量②目录：$R（期望 2）"
R=$(psql -t -A -c "SELECT count(*) FILTER (WHERE proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[])::text || '/' || count(*)::text FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_wave_parent_cycle','trg_pt_handover_cycle')")
[ "$R" = "2/2" ] && ok "05 增量②：两个触发器函数 proconfig 都是 search_path=pg_catalog, public, pg_temp（$R）" || bad "05 增量② search_path 目录：$R（期望 2/2）"
R=$(psql -q -t -A -c "BEGIN; ALTER FUNCTION public.trg_wave_parent_cycle() RESET search_path; SELECT count(*) FILTER (WHERE proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[])::text || '/' || count(*)::text FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_wave_parent_cycle','trg_pt_handover_cycle'); ROLLBACK;" | head -1)
[ "$R" = "1/2" ] && ok "05 增量②变异：RESET 一个函数的 search_path 后目录断言变红（$R）" || bad "05 增量② search_path 变异：$R（期望 1/2）"
# ③ 撤销回退行状态（镜鉴 r5 重要项③）：§6.5 的撤销必须与数量同一条 UPDATE 回退 status，否则 T-done 仍判拣满
seed "INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9405,'PT-9405',9201,1,'EXECUTING',41,'D9405',1,1);"
seed "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9405,9405,1,1,1,1,11,1,1000,1000,'KG','DONE');"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task_line SET confirmed_qty_milli=confirmed_qty_milli-300, status=CASE WHEN status='DONE' AND confirmed_qty_milli-300 < planned_qty_milli THEN 'PENDING' ELSE status END WHERE id=9405 AND confirmed_qty_milli>=300 RETURNING status) SELECT count(*)::text || '/' || COALESCE(max(status),'-') FROM u")
[ "$R" = "1/PENDING" ] && ok "05 增量③：撤销同一条 UPDATE 把 DONE 行回退成 PENDING（$R）" || bad "05 增量③ 撤销回退：$R（期望 1/PENDING）"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task SET status='DONE' WHERE id=9405 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9405 AND l.status IN ('PENDING','SKIP','ABNORMAL')) RETURNING 1) SELECT count(*) FROM u")
[ "$R" = "0" ] && ok "05 增量③：回退后 T-done 守卫命中 0 行（任务不得进 DONE）" || bad "05 增量③ T-done：$R（期望 0）"
seed "UPDATE pick_task_line SET confirmed_qty_milli=1000, status='DONE' WHERE id=9405;"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task_line SET confirmed_qty_milli=confirmed_qty_milli-300 WHERE id=9405 AND confirmed_qty_milli>=300 RETURNING status) SELECT count(*)::text || '/' || COALESCE(max(status),'-') FROM u")
[ "$R" = "1/DONE" ] && ok "05 增量③变异：只减量不回退状态的旧写法，行仍是 DONE（$R）" || bad "05 增量③变异旧写法：$R（期望 1/DONE）"
R=$(psql -t -A -c "WITH u AS (UPDATE pick_task SET status='DONE' WHERE id=9405 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9405 AND l.status IN ('PENDING','SKIP','ABNORMAL')) RETURNING 1) SELECT count(*) FROM u")
[ "$R" = "1" ] && ok "05 增量③变异：不回退状态时同一任务被判 DONE（证明回退是拦它的那条）" || bad "05 增量③变异 T-done：$R（期望 1）"
echo "=== 2w. docs/16 配送与签收：38 CHECK / 19 外键 / 3 部分唯一索引的三件套（正向 / 按名拒绝 / 变异）==="
# 父行：warehouse 1 / sku 1 / lot 9610（前文已有）+ shipment / waybill / outbound / pod_op（本段 96xx）
seed "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (9610,1,'LOT-16-9610','2026-12-01','2026-10-15','QUALIFIED',30);"
seed "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9610,'SHP-9610',1,'CREATED'),(9611,'SHP-9611',1,'CREATED'),(9612,'SHP-9612',1,'CREATED'),(9613,'SHP-9613',1,'CREATED'),(9614,'SHP-9614',1,'CREATED'),(9615,'SHP-9615',1,'CREATED'),(9616,'SHP-9616',1,'CREATED');"
seed "INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9610,'WB-16-9610',9610,1,'2026-10-15','IN_TRANSIT');"
seed "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (9610,'OBT-16-9610',1,'SALE','MALL','M-16-9610','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9611,'OBT-16-9611',1,'SALE','MALL','M-16-9611','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9612,'OBT-16-9612',1,'SALE','MALL','M-16-9612','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9613,'OBT-16-9613',1,'SALE','MALL','M-16-9613','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9614,'OBT-16-9614',1,'SALE','MALL','M-16-9614','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9615,'OBT-16-9615',1,'SALE','MALL','M-16-9615','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9616,'OBT-16-9616',1,'SALE','MALL','M-16-9616','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15');"
seed "INSERT INTO outbound_line (id,outbound_id,line_no,sku_id,order_qty_milli,picked_qty_milli,uom) VALUES (9610,9610,1,1,10000,10000,'KG');"
seed "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9610,'WB-16-9610',1,'D9610',1,'POD_SIGN',repeat('a',64),200,'0',40,'2026-10-15 02:00:00','2026-10-16 02:00:00');"
seed "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9611,'WB-16-9610',0,'D9611',2,'LOAD',repeat('a',64),200,'0'),(9612,'WB-16-9610',0,'D9612',3,'LOAD',repeat('a',64),200,'0'),(9613,'WB-16-9610',0,'D9613',4,'LOAD',repeat('a',64),200,'0'),(9614,'WB-16-9610',0,'D9614',5,'LOAD',repeat('a',64),200,'0'),(9615,'WB-16-9610',0,'D9615',6,'LOAD',repeat('a',64),200,'0');"
seed "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9670,9610,1,90,'OPEN'),(9671,9610,1,91,'OPEN'),(9672,9610,1,92,'OPEN'),(9673,9610,1,93,'OPEN'),(9674,9610,1,94,'OPEN'),(9675,9610,1,95,'OPEN'),(9676,9610,1,96,'OPEN');"
# 正向：9 张表各一条（含默认值路径）
expect_allow "16 正向：waybill（CREATED + 快照列）" "INSERT INTO waybill (id,code,shipment_id,warehouse_id,driver_name,vehicle_no,work_date,status) VALUES (9671,'WB-16-9671',9611,1,'司机甲','沪A16','2026-10-15','CREATED')"
expect_allow "16 正向：delivery_stop" "INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9671,9610,1,'PENDING')"
expect_allow "16 正向：delivery_order（SHIPPED，无生效签收）" "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9671,9611,9610,1,'SHIPPED')"
expect_allow "16 正向：pod_op（LOAD）" "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9671,'WB-16-9610',0,'D9671',1,'LOAD',repeat('a',64),200,'0')"
expect_allow "16 正向：pod_line" "INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9671,9610,9610,9610,10000,0,40)"
expect_allow "16 正向：pod_correction（PENDING + 202）" "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9671,9610,9610,9610,9612,1,'00000000-0000-4000-8000-000000009671',repeat('a',64),202,0)"
expect_allow "16 正向：pod_tolerance_config" "INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9671,1,'CHILLED',500,100)"
expect_allow "16 正向：delivery_return（OPEN）" "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9677,9610,1,1,'OPEN')"
expect_allow "16 正向：delivery_return_line" "INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9671,9670,1,9610,5000)"
mut16() { expect_allow "16 变异：去掉 $1 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE $2 DROP CONSTRAINT $1; $3; ROLLBACK;"; }
mut16i() { expect_allow "16 变异：去掉索引 $1 后，原被拒语句通过（随后回滚）" "BEGIN; DROP INDEX $1; $2; ROLLBACK;"; }
while IFS='|' read -r _kind _name _tbl _stmt; do
  case "$_kind" in
    ck|fk) expect_block "16 拒绝：$_name" "$_stmt" "$_name"; mut16 "$_name" "$_tbl" "$_stmt";;
    idx)   expect_block "16 拒绝：$_name" "$_stmt" "$_name"; mut16i "$_name" "$_stmt";;
  esac
done <<'S16EOF'
ck|ck_wb_status|waybill|INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9681,'WB-16-9681',9612,1,'2026-10-15','PENDING')
ck|ck_wb_version|waybill|INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status,waybill_version) VALUES (9682,'WB-16-9682',9613,1,'2026-10-15','CREATED',-1)
ck|ck_wb_signed|waybill|INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9683,'WB-16-9683',9614,1,'2026-10-15','CLOSED')
fk|fk_wb_shipment|waybill|INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9684,'WB-16-9684',999999,1,'2026-10-15','CREATED')
fk|fk_wb_wh|waybill|INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9685,'WB-16-9685',9615,999999,'2026-10-15','CREATED')
ck|ck_dstop_no|delivery_stop|INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9681,9610,0,'PENDING')
ck|ck_dstop_st|delivery_stop|INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9682,9610,2,'X')
fk|fk_dstop_wb|delivery_stop|INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9683,999999,1,'PENDING')
ck|ck_dord_cseq|delivery_order|INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status,correct_seq) VALUES (9682,9613,9610,1,'SHIPPED',-1)
ck|ck_dord_pod|delivery_order|INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status,valid_pod_id) VALUES (9683,9614,9610,1,'SHIPPED',9610)
fk|fk_dord_out|delivery_order|INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9684,999999,9610,1,'SHIPPED')
fk|fk_dord_wb|delivery_order|INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9685,9615,999999,1,'SHIPPED')
ck|ck_pod_op_type|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9681,'WB-16-9610',1,'D96A',1,'X',repeat('a',64),200,'0')
ck|ck_pod_op_hash|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9682,'WB-16-9610',1,'D96B',1,'LOAD','abc',200,'0')
ck|ck_pod_op_seq|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9683,'WB-16-9610',1,'D96C',-1,'LOAD',repeat('a',64),200,'0')
ck|ck_pod_op_cache|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9684,'WB-16-9610',1,'D96D',1,'LOAD',repeat('a',64),200,'X')
ck|ck_pod_op_temp|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9685,'WB-16-9610',1,'D96E',1,'POD_SIGN',repeat('a',64),200,'0',NULL,'2026-10-15 02:00:00','2026-10-16 02:00:00')
ck|ck_pod_op_cdl|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10) VALUES (9686,'WB-16-9610',1,'D96F',1,'POD_SIGN',repeat('a',64),200,'0',40)
ck|ck_pod_op_cdl24|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9687,'WB-16-9610',1,'D96G',1,'POD_SIGN',repeat('a',64),200,'0',40,'2026-10-15 02:00:00','2026-10-15 03:00:00')
ck|ck_pod_op_cct|pod_op|INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,client_occurred_at) VALUES (9688,'WB-16-9610',0,'D96H',9,'LOAD',repeat('a',64),200,'0','2026-10-15 02:00:00.5')
ck|ck_podl_qty|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9681,9671,9610,9610,10000,20000,'QUALITY',40)
ck|ck_podl_rsn|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9682,9611,9610,9610,10000,5000,40)
ck|ck_podl_rsn_v|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9683,9612,9610,9610,10000,5000,'X',40)
ck|ck_podl_temp|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9684,9613,9610,9610,10000,0,700)
fk|fk_podl_pod|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9685,999999,9610,9610,10000,0,40)
fk|fk_podl_obl|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9686,9614,999999,9610,10000,0,40)
fk|fk_podl_lot|pod_line|INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9687,9615,9610,999999,10000,0,40)
ck|ck_podc_client|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9681,9610,9610,9610,9613,1,'00000000-0000-4000-8000-00000000967',repeat('a',64),202,0)
ck|ck_podc_hash|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9682,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009682',repeat('a',63),202,0)
ck|ck_podc_status|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance) VALUES (9683,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009683',repeat('a',64),'X',202,0)
ck|ck_podc_http|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9684,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009684',repeat('a',64),200,0)
ck|ck_podc_auto|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance,tolerance_version) VALUES (9685,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009685',repeat('a',64),200,1,NULL)
ck|ck_podc_seq|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9686,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009686',repeat('a',64),'APPLIED',202,0,0,2,'2026-10-15 09:00:00')
ck|ck_podc_sod|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9687,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009687',repeat('a',64),'APPLIED',202,0,1,1,'2026-10-15 09:00:00')
ck|ck_podc_decide|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq) VALUES (9688,9610,9610,9610,9614,1,'00000000-0000-4000-8000-000000009688',repeat('a',64),'APPLIED',202,0,1)
fk|fk_podc_op|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9689,999999,9610,9610,9615,1,'00000000-0000-4000-8000-000000009689',repeat('a',64),202,0)
fk|fk_podc_root|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9690,9610,9610,999999,9615,1,'00000000-0000-4000-8000-000000009690',repeat('a',64),202,0)
fk|fk_podc_out|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9691,9610,9610,9610,999999,1,'00000000-0000-4000-8000-000000009691',repeat('a',64),202,0)
fk|fk_podc_apr|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9692,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009692',repeat('a',64),999999,202,0)
ck|ck_podt_cat|pod_tolerance_config|INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9681,1,' X',500,100)
ck|ck_podt_abs|pod_tolerance_config|INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9682,1,'A',-1,100)
ck|ck_podt_pct|pod_tolerance_config|INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9683,1,'B',500,10001)
ck|ck_podt_notblank|pod_tolerance_config|INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9684,1,'C',0,0)
fk|fk_podt_wh|pod_tolerance_config|INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9685,999999,'D',500,100)
ck|ck_dret_seq|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9681,9610,2,0,'OPEN')
ck|ck_dret_status|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9682,9610,2,2,'X')
ck|ck_dret_cnt|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9683,9610,2,3,'COUNTED')
ck|ck_dret_cancel|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9684,9610,2,4,'CANCELLED')
fk|fk_dret_wb|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9685,999999,1,5,'OPEN')
fk|fk_dret_rtn|delivery_return|INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status,rtn_inbound_id) VALUES (9686,9610,2,6,'OPEN',999999)
ck|ck_dretl_qty|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9681,9671,1,9610,-1)
ck|ck_dretl_exc|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli,counted_qty_milli) VALUES (9682,9672,1,9610,5000,4000)
fk|fk_dretl_ret|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9683,999999,1,9610,5000)
fk|fk_dretl_sku|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9684,9673,999999,9610,5000)
fk|fk_dretl_lot|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9685,9674,1,999999,5000)
fk|fk_dretl_exc|delivery_return_line|INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli,counted_qty_milli,exception_case_id) VALUES (9686,9675,1,9610,5000,5000,999999)
idx|uq_podc_approval|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9693,9610,9701,9610,9616,1,'00000000-0000-4000-8000-000000009693',repeat('a',64),(SELECT min(id) FROM approval_request),202,0); INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9694,9610,9702,9610,9616,1,'00000000-0000-4000-8000-000000009694',repeat('a',64),(SELECT min(id) FROM approval_request),202,0)
idx|uq_podc_pending|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9695,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009695',repeat('a',64),202,0); INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9696,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009696',repeat('a',64),202,0)
idx|uq_podc_seq|pod_correction|INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9697,9610,9610,9610,9616,1,'00000000-0000-4000-8000-000000009697',repeat('a',64),'APPLIED',202,0,1,2,'2026-10-15 09:00:00'); INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9698,9610,9610,9610,9616,1,'00000000-0000-4000-8000-000000009698',repeat('a',64),'APPLIED',202,0,1,2,'2026-10-15 09:00:00')
S16EOF
# ck_dord_status 被 ck_dord_pod 遮蔽：任何不在 {SHIPPED, DELIVERED} 的 status 先被 ck_dord_pod 拦（语义上两者重叠，保留两条约束、按实际拦它的那条断言）
expect_block "16 拒绝：ck_dord_status（被 ck_dord_pod 遮蔽，实际由后者拦）" "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9681,9612,9610,1,'X')" "ck_dord_pod"
expect_allow "16 变异：同时去掉 ck_dord_pod 与 ck_dord_status 后，原被拒语句通过（随后回滚）" "BEGIN; ALTER TABLE delivery_order DROP CONSTRAINT ck_dord_pod; ALTER TABLE delivery_order DROP CONSTRAINT ck_dord_status; INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9681,9612,9610,1,'X'); ROLLBACK;"
echo "=== 汇总 ==="
echo "  通过 $pass 项 / 失败 $fail 项"
cleanup
[ "$fail" = "0" ]
