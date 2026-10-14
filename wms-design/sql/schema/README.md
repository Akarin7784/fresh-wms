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
| `11_integration.sql` | 幂等、入站消息、outbox、审计、取号 |
| `12_auth.sql` | 用户、角色、权限、API 凭证 |
| `90_available_view.sql` | `v_stock_available`，然后 `COMMIT` |
| `99_grants.sql` | 事务外执行：`wms_purge_owner` / `wms_cleaner` / `purge_expired()` |

`COMMIT` 在 `90_available_view.sql` 里，视图建完就结束事务。`99_grants.sql` 排在它后面，在事务外执行：清理函数要等所有表建完，而且 `CREATE ROLE` 一类语句放在已提交的库上。新篇章插在 90 之前，所以仍在同一个事务里建表、授权。

## 跨篇加列

需要给别篇的表加列或加约束时，在**自己的** `NN_*.sql` 里写 `ALTER TABLE`（PostgreSQL 和 SQLite 两条都要写，SQLite 侧用 `-- @sqlite-only` / `-- @pg-only` 拆开），并在下面的登记表写上名字和原因。不要直接改那张表所在的篇文件。

| 对象 | 表 | 由哪一篇的文件 ALTER | 原因 | 状态 |
|---|---|---|---|---|
| `received_qty_milli`、`qc_passed_qty_milli`、`qc_failed_qty_milli` | `inbound_line` | 第 10 篇 `10_returns.sql`（尚未加入加载列表） | 02 §7.1.3 `release_qc_hold` 按这三列累加质检合格量。不登记 `claimed_qty_milli`。`03_inbound.sql` 里现有的 `received_qty` 仍是 `NUMERIC(14,3)`，本篇不改 03 | 待 #5 落库 |
| `ck_inbl_int`、`ck_inbl_qc` | `inbound_line` | 第 10 篇 `10_returns.sql` | `ck_inbl_int`：上述 milli 列为整数。`ck_inbl_qc`：非负，且 `qc_passed_qty_milli + qc_failed_qty_milli ≤ received_qty_milli` | 待 #5 落库 |
| `ck_inb_rtn_src` | `inbound_order` | 第 10 篇 `10_returns.sql`（对 03 入库单 ALTER） | 限制退货入库来源。PostgreSQL 用 CHECK；SQLite 用触发器 | 待 #5 落库 |
| `upstream_push_log` 的 SELECT、DELETE 给 `wms_purge_owner`；`purge_push_log()` 的 EXECUTE 给 `wms_cleaner` | `upstream_push_log` | `99_grants.sql`（目录检查，表或函数不存在则跳过） | 第 11 篇清理角色。本分支还没有这张表和这个函数，两笔 GRANT 当前都跳过 | 待 #11 落库（当前跳过） |
