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
| `10_returns.sql` | 退货与异常：异常码、异常单、退货预约、盲收；对 03 的 ALTER（见跨篇加列） |
| `09_scrap.sql` | 报损单、报损行（含 SELL_EXPIRED / LIVE_* / PROCESS_LOSS 来源） |
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
| `upstream_push_log` 的 SELECT、DELETE 给 `wms_purge_owner`；`purge_push_log()` 的 EXECUTE 给 `wms_cleaner` | `upstream_push_log` | `99_grants.sql`（目录检查，表或函数不存在则跳过） | 第 11 篇清理角色。本分支还没有这张表和这个函数，两笔 GRANT 当前都跳过 | 待 #11 落库（当前跳过） |
| `ALTER FUNCTION purge_push_log() OWNER TO wms_purge_owner` | `purge_push_log()` | `99_grants.sql`（`to_regprocedure` 查目录，函数不存在则跳过） | 第 11 篇 `trg_upl_append_only` 只放行 `current_user = wms_purge_owner` 删除已过 `retain_until` 的行。函数是 SECURITY DEFINER，属主才是触发器看到的当前用户。角色在本文件开头创建，表上的 SELECT、DELETE 已按目录检查授予。函数体和触发器归第 11 篇，本文件不建 | 待 #11 落库（当前跳过） |

## 触发器 search_path 与 outbox 插入

本篇定义的 10 个函数都固定 `SET search_path = pg_catalog, public`。`purge_expired()` 原本就有。另外 9 个是触发器函数，不是 SECURITY DEFINER，按调用方身份执行：`trg_mvk_line_kind`、`trg_sll_immutable`、`trg_hold_immutable`、`trg_hold_no_delete`、`trg_append_only`（`02_inventory.sql`），`trg_lot_sell_deadline`（`01_master.sql`），`trg_purge_guard`、`trg_expiry_forward`、`trg_outbox_insert_pending`（`11_integration.sql`）。

`trg_outbox_insert_pending` 不按 `current_user = 'wms_app'` 判断。`wms_app` 是 NOLOGIN，应用用继承它的登录角色。不是 `outbox_event` 表属主的角色，插入时 `status` 必须是 `PENDING` 且 `sent_at` 为空，否则拒绝（`outbox_insert_not_pending`），不把状态改写成 `PENDING`。表属主可以插入其他状态，供种子和迁移使用。SQLite 没有角色，也没有 search_path；同名触发器拒绝一切非 PENDING 或带 `sent_at` 的插入，包括 `FAILED`。
