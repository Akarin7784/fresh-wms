# schema 按篇加载

`verify.sh` 与 `verify_sqlite.py` 按下面的文件名顺序拼接后执行。PostgreSQL 源以这些文件为准；`schema_sqlite.sql` 由翻译器生成，不要手改。`schema_postgres.sql` 只是指针。

各篇只改自己的 `sql/schema/NN_*.sql`（编号与篇号对齐）。不要改别人的篇文件，也不要恢复成单文件 `schema_postgres.sql`。

下游 PR 把自己的文件加进 **两个** verify 的加载列表（`verify.sh` 的 `SCHEMA_PARTS` 和 `verify_sqlite.py` 的 `SCHEMA_PARTS`），两处名单和顺序必须一致，并在本表补一行。文件插在 `90_available_view.sql` 之前。本篇表的 `GRANT` 写在自己文件末尾（`-- @pg-only`）。

| 文件 | 内容 |
|---|---|
| `00_preamble.sql` | 文件头、`BEGIN`、角色 `wms_app`（必须先于任何 GRANT） |
| `01_master.sql` | 仓库、库区、库位、SKU、批次，含 `sell_deadline` 不可回溯 |
| `02_inventory.sql` | 库存、占用、冻结、流水、快照、对账 |
| `03_inbound.sql` | 入库单 / 入库行 |
| `04_outbound.sql` | 出库单 / 出库行 |
| `05_picking.sql` | 波次、拣货任务 |
| `06_pack_ship.sql` | 装箱、发运 |
| `08_count.sql` | 盘点、调整 |
| `10_returns.sql` | 退货与异常：异常码、异常单、退货预约、盲收、退供应商（supplier_return）；对 03、01 sku 的 ALTER（见跨篇加列） |
| `09_scrap.sql` | 报损单、报损行（含 SELL_EXPIRED / LIVE_* / PROCESS_LOSS / SUPPLIER_RETURN 来源）；对 10 supplier_return 的 ALTER（见跨篇加列） |
| `11_integration.sql` | 幂等、入站消息、outbox、审计、取号 |
| `12_auth.sql` | 用户、角色、权限、API 凭证 |
| `12b_auth_audit.sql` | 设备绑定、离线令牌、审批单；audit_log 节点列与只追加；sys_user.perm_version |
| `17_processing.sql` | 加工 BOM、加工单、领料、产出、冲回、批次追溯 |
| `18_live.sql` | 第 18 篇活鲜暂存：池扩展、只数账、巡检、锁池单、出池称重、死亡、日失重（只建本篇表，不改 02 约束；跨篇外键待补见 docs/18 §4.11） |
| `90_available_view.sql` | `v_stock_available`，然后 `COMMIT` |
| `99_grants.sql` | 事务外执行：`wms_purge_owner` / `wms_cleaner` / `purge_expired()` |

`COMMIT` 在 `90_available_view.sql` 里，视图建完就结束事务。`99_grants.sql` 排在它后面，在事务外执行：清理函数要等所有表建完，而且 `CREATE ROLE` 一类语句放在已提交的库上。新篇章插在 90 之前，所以仍在同一个事务里建表、授权。

## 跨篇加列

需要给别篇的表加列或加约束时，在**自己的** `NN_*.sql` 里写 `ALTER TABLE`（PostgreSQL 和 SQLite 两条都要写，SQLite 侧用 `-- @sqlite-only` / `-- @pg-only` 拆开），并在下面的登记表写上名字和原因。不要直接改那张表所在的篇文件。

| 对象 | 表 | 由哪一篇的文件 ALTER | 原因 | 状态 |
|---|---|---|---|---|
| `received_qty_milli`、`qc_passed_qty_milli`、`qc_failed_qty_milli` | `inbound_line` | 第 10 篇 `10_returns.sql` | 02 §7.1.3 `release_qc_hold` 按这三列累加质检合格量。不登记 `claimed_qty_milli`。`03_inbound.sql` 里现有的 `received_qty` 仍是 `NUMERIC(14,3)`，本篇不改 03 | #5 已落库 |
| `node_id`、`node_seq`、`device_instance_id`、`approval_id` | `audit_log` | 第 12 篇 `12b_auth_audit.sql` | 边缘回传按 (node_id,node_seq) 去重、审批关联（12 §6）；DEFAULT 0 只兼容存量，新插入 ≤0 由 trg_audit_node_required 拦（40001） | 已落库 |
| `approval_no` → `approval_request.code` | `stock_hold` | 第 12 篇 `12b_auth_audit.sql` | 00 审批单号关联真实审批单。PG 外键 `fk_hold_approval_no`；SQLite 用 AFTER INSERT/UPDATE 触发器（不能 ALTER 加外键） | 已落库 |
| `ck_inbl_int`、`ck_inbl_qc` | `inbound_line` | 第 10 篇 `10_returns.sql` | `ck_inbl_int`：上述 milli 列为整数。`ck_inbl_qc`：非负，且 `qc_passed_qty_milli + qc_failed_qty_milli ≤ received_qty_milli` | #5 已落库 |
| `ck_inb_rtn_src` | `inbound_order` | 第 10 篇 `10_returns.sql`（对 03 入库单 ALTER） | 限制退货入库来源。PostgreSQL 用 CHECK；SQLite 用触发器 | #5 已落库 |
| `return_as_fresh`、`ck_sku_rtn_fresh` | `sku` | 第 10 篇 `10_returns.sql` | 退供提货时限：常温 SKU 可标「按生鲜退」（T+24h）。CHECK 只允许 `temperature_required = 'AMBIENT'` 的 SKU 置真。PG ADD COLUMN + ADD CONSTRAINT；SQLite 列级 CHECK 挂在新列上。`trg_srtn_temp`（第 10 篇自有触发器，只读 sku）按 FROZEN→FROZEN、CHILLED→FRESH、AMBIENT→STANDARD（标记时 FRESH）核对 `supplier_return.temp_class` | 本增量（pr-supplier-return）落库 |
| `fk_srtn_scrap`、`uq_srtn_scrap`、`trg_srtn_overdue`（SQLite 另有 `trg_srtn_overdue_ins`、`trg_srtn_overdue_lock`、`trg_srtn_scrap_fk`） | `supplier_return` | 第 9 篇 `09_scrap.sql`（对 10 退供单 ALTER） | 退供超期未提转第 9 篇报损单（source_type=SUPPLIER_RETURN，reason_code=PICKUP_OVERDUE）并经 02 原语 `hold(SCRAP_PENDING)` 冻结（op_key=SRTO:{id}）。`scrap_order` 在 10 之后建，外键和「转 OVERDUE_SCRAP 前必须已有报损单 + SCRAP_PENDING 冻结」的守卫只能写在 09。PG 外键 + 触发器（固定 search_path）；SQLite 不能 ALTER 加外键，用触发器 | 本增量（pr-supplier-return）落库 |
| 错误码 `srtn_overdue_no_scrap_hold`、`srtn_overdue_immutable`（23514）；报损来源 `SUPPLIER_RETURN`、原因 `PICKUP_OVERDUE`；`uq_scr_srtn` | `supplier_return` / `scrap_order` | 第 9 篇 `09_scrap.sql`（来源/原因/索引在本篇自有表上） | 退供超期守卫的库层错误名；对外 API 码未分配。00 §6.4 报损来源枚举需登记 `SUPPLIER_RETURN`（及 `PICKUP_OVERDUE`、上述错误码映射） | 已登记 00 §6.4（#2 第九轮） |
| `ck_srtn_ts`、`trg_srtn_zclock`（SQLite：`trg_srtn_time_lock`、`trg_srtn_ins_open`、`trg_srtn_clock_ins` / `_upd`）；`wms_app` 列级 `UPDATE (status, picked_up_at, overdue_at, scrap_order_id, version)` | `supplier_return` | 第 10 篇 `10_returns.sql` | 时间约定（第 10 篇 §3.6）：只收整秒 ISO；PG 对非属主强制改写为库时钟并重算截止，属主豁免；SQLite 拒非 ISO，要求与 now 相差 ≤ 300 s；ready_at / 截止只写一次；不授整表 UPDATE。不涉及 11 audit_log | 本增量（pr-supplier-return）落库 |
| `trg_srtn_forward`（PG + SQLite 同名）；`created_at` 纳入时间约定；本增量 5 个 PG 函数 `SET search_path = pg_catalog, public, pg_temp` | `supplier_return` | 第 10 篇 `10_returns.sql`（`trg_scr_srtn` / `trg_srtn_overdue` 在 09） | 小玛丽终审 B1/B2/N1：状态白名单（第 10 篇 §5）；created_at 由库时钟写、只写一次；pg_temp 显式最后，防临时表冒充。主干其余函数的 pg_temp 由 Doro 在 #2 统一改 | 本增量（pr-supplier-return）落库 |
| `trg_scr_srtn`（SQLite：`trg_scr_srtn_ins` / `_upd`） | `scrap_order` | 第 9 篇 `09_scrap.sql` | 防 0 行静默成功：只能为 AWAITING_PICKUP 的退供单开报损单；退供单未转超期并指回本单时，报损单只能取消或驳回 | 本增量（pr-supplier-return）落库 |
| 错误码 `srtn_state_forward_only`、`srtn_clock_skew`、`srtn_time_immutable`、`srtn_insert_open_only`、`srtn_scrap_not_awaiting`、`srtn_scrap_orphan`（23514） | `supplier_return` / `scrap_order` | 第 10 篇 / 第 9 篇 | 上述守卫的库层错误名；对外 API 码未分配（0 行冲突由服务端返回 40930） | 已登记 00 §6.4（#2 第九轮） |
| `upstream_push_log` 的 SELECT、DELETE 给 `wms_purge_owner`；`purge_push_log()` 的 EXECUTE 给 `wms_cleaner` | `upstream_push_log` | `99_grants.sql`（目录检查，表或函数不存在则跳过） | 第 11 篇清理角色。本分支还没有这张表和这个函数，两笔 GRANT 当前都跳过 | 待 #11 落库（当前跳过） |
| `ALTER FUNCTION purge_push_log() OWNER TO wms_purge_owner` | `purge_push_log()` | `99_grants.sql`（`to_regprocedure` 查目录，函数不存在则跳过） | 第 11 篇 `trg_upl_append_only` 只放行 `current_user = wms_purge_owner` 删除已过 `retain_until` 的行。函数是 SECURITY DEFINER，属主才是触发器看到的当前用户。角色在本文件开头创建，表上的 SELECT、DELETE 已按目录检查授予。函数体和触发器归第 11 篇，本文件不建 | 待 #11 落库（当前跳过） |

## 触发器 search_path 与 outbox 插入

本篇定义的 10 个函数都固定 `SET search_path = pg_catalog, public, pg_temp`（#2 第九轮起 pg_temp 必须显式且最后，见 00 §6.9）。`purge_expired()` 原本就有。另外 9 个是触发器函数，不是 SECURITY DEFINER，按调用方身份执行：`trg_mvk_line_kind`、`trg_sll_immutable`、`trg_hold_immutable`、`trg_hold_no_delete`、`trg_append_only`（`02_inventory.sql`），`trg_lot_sell_deadline`（`01_master.sql`），`trg_purge_guard`、`trg_expiry_forward`、`trg_outbox_insert_pending`（`11_integration.sql`）。

`trg_outbox_insert_pending` 不按 `current_user = 'wms_app'` 判断。`wms_app` 是 NOLOGIN，应用用继承它的登录角色。不是 `outbox_event` 表属主的角色，插入时 `status` 必须是 `PENDING` 且 `sent_at` 为空，否则拒绝（`outbox_insert_not_pending`），不把状态改写成 `PENDING`。表属主可以插入其他状态，供种子和迁移使用。SQLite 没有角色，也没有 search_path；同名触发器拒绝一切非 PENDING 或带 `sent_at` 的插入，包括 `FAILED`。
