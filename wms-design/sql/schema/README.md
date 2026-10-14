# schema 按篇加载

`verify.sh` 与 `verify_sqlite.py` 按下面的文件名顺序拼接后执行。PostgreSQL 源以这些文件为准；`schema_sqlite.sql` 由翻译器生成，不要手改。`schema_postgres.sql` 只是指针。

后续篇章只新增自己的 `NN_*.sql`（编号与篇号对齐），在本清单和两个 verify 脚本的加载列表里按序插进去，并在该文件末尾写本篇表的 `GRANT`（`-- @pg-only`）。不要再改别人的篇文件，也不要恢复成单文件 `schema_postgres.sql`。

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
| `90_available_view.sql` | `v_stock_available`、`COMMIT` |
| `99_grants.sql` | `wms_purge_owner` / `wms_cleaner` / `purge_expired()` |

第 7、9、10、13–18 篇的表加在对应编号的新文件里，插在 `90_available_view.sql` 之前（视图和 COMMIT 保持在最后两档之前）。清理函数仍放在 `99_grants.sql`，因为它要等所有表建完。
