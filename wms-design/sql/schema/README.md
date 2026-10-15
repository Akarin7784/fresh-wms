# schema 按篇加载

`verify.sh` 与 `verify_sqlite.py` 按下面的文件名顺序拼接后执行。PostgreSQL 源以这些文件为准；`schema_sqlite.sql` 由翻译器生成，不要手改。`schema_postgres.sql` 只是指针。

各篇只改自己的 `sql/schema/NN_*.sql`（编号与篇号对齐）。不要改别人的篇文件，也不要恢复成单文件 `schema_postgres.sql`。

下游 PR 把自己的文件加进 **两个** verify 的加载列表（`verify.sh` 的 `SCHEMA_PARTS` 和 `verify_sqlite.py` 的 `SCHEMA_PARTS`），两处名单和顺序必须一致，并在本表补一行。文件插在 `90_available_view.sql` 之前。本篇表的 `GRANT` 写在自己文件末尾（`-- @pg-only`）。

| 文件 | 内容 |
|---|---|
| `00_preamble.sql` | 文件头、`BEGIN`、角色 `wms_app`（必须先于任何 GRANT） |
| `01_master.sql` | 第 1 篇主数据：仓库（`ck_wh_code`）、库区 / 温区（`temp_min_c10` / `temp_max_c10` + `ck_zone_temp`，0.1 ℃）、库位（`min_level_milli` / `max_level_milli` + `ck_loc_level`）、SKU（`sell_days` + `ck_sku_sell_days` + `ck_sku_sell_days_req`、`natural_loss_tolerance_ppm` + `ck_sku_loss_ppm`、`ck_sku_shelf_life`）、条码、单位换算（`base_qty_milli` + `ck_unit_ratio`）、批次（`sell_deadline` 不可回溯）；7 张表的 10 个时间列默认 UTC 整秒（00 §6.8）；`sku_unit` 仍在 00 §6.10 `REPLACE_OK` 名单里（表级豁免，理由见 docs/01 §4.6 / §12 Q8） |
| `02_inventory.sql` | 库存、占用、冻结、流水、快照、对账 |
| `03_inbound.sql` | 第 3 篇入库：入库单 / 入库行（milli 三列与 ck_inbl_int/ck_inbl_qc/ck_inb_rtn_src 仍由 10 ALTER）、到货测温、收货记录、收货更正单 `inbound_correction`（关单后正/反向 ADJUST 流水，24h 主管 / 7d 双审 / 超窗或已对账转 08，收货人不能审批）、上架记录、入库后质量反馈（报损/退供待处置走 hold(SCRAP_PENDING)）；已关单单头与行锁定 |
| `04_outbound.sql` | 出库单 / 出库行 |
| `05_picking.sql` | 波次、拣货任务 |
| `06_pack_ship.sql` | 装箱、发运 |
| `08_count.sql` | 盘点、调整 |
| `10_returns.sql` | 退货与异常：异常码、异常单、退货预约、盲收、退供应商（supplier_return）；对 03、01 sku 的 ALTER（见跨篇加列） |
| `09_scrap.sql` | 报损单、报损行（含 SELL_EXPIRED / LIVE_* / PROCESS_LOSS / SUPPLIER_RETURN 来源）；对 10 supplier_return 的 ALTER（见跨篇加列） |
| `11_integration.sql` | 幂等、入站消息、outbox、审计、取号 |
| `12_auth.sql` | 用户、角色、权限、API 凭证 |
| `12b_auth_audit.sql` | 设备绑定、离线令牌、审批单、设备恢复联网记录 `device_reconnect`（只追加，第 11 篇纸单补录引用）；audit_log 节点列与只追加；sys_user.perm_version；第 12 篇时间加固（服务端时间由库写：PG `trg_apr_zclock` / `trg_udb_zclock` / `trg_offline_zclock` / `trg_drc_guard` 对非表属主覆盖，表属主豁免；SQLite ±300 s 时钟窗口 + 整秒格式 CHECK；审批 `expires_at` 由库按类型补上限、只许缩短）；用户停用自动递增 perm_version；权限映射只经 6 个 SECURITY DEFINER 函数（属主 wms_rbac_owner，SQLite 为先审计后删的库强制契约）；12 张表的 FK 全部写在建表语句里（approval_request 提前到绑定表之前） |
| `17_processing.sql` | 加工 BOM、加工单、领料、产出、冲回、批次追溯 |
| `18_live.sql` | 第 18 篇活鲜暂存：池扩展、只数账、巡检、锁池单、出池称重、死亡、日失重（只建本篇表，不改 02 约束；跨篇外键待补见 docs/18 §4.11） |
| `90_available_view.sql` | `v_stock_available`，然后 `COMMIT` |
| `99_grants.sql` | 事务外执行：`wms_purge_owner` / `wms_cleaner` / `purge_expired()` |

`COMMIT` 在 `90_available_view.sql` 里，视图建完就结束事务。`99_grants.sql` 排在它后面，在事务外执行：清理函数要等所有表建完，而且 `CREATE ROLE` 一类语句放在已提交的库上。新篇章插在 90 之前，所以仍在同一个事务里建表、授权。

## 跨篇加列

需要给别篇的表加列或加约束时，在**自己的** `NN_*.sql` 里写 `ALTER TABLE`（PostgreSQL 和 SQLite 两条都要写，SQLite 侧用 `-- @sqlite-only` / `-- @pg-only` 拆开），并在下面的登记表写上名字和原因。不要直接改那张表所在的篇文件。

| 对象 | 表 | 由哪一篇的文件 ALTER | 原因 | 状态 |
|---|---|---|---|---|
| `received_qty_milli`、`qc_passed_qty_milli`、`qc_failed_qty_milli` | `inbound_line` | 第 10 篇 `10_returns.sql` | 02 §7.1.3 `release_qc_hold` 按这三列累加质检合格量。不登记 `claimed_qty_milli`。`03_inbound.sql` 自 docs/03 改稿起不再有 NUMERIC 数量列，也不重复定义这三列和两条约束 | #5 已落库 |
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
| 00 §6.10 防 REPLACE：SQLite `trg_upl_no_replace`（主键，错误名 `append_only_violation: upstream_push_log`）、`trg_paper_no_replace`（主键 + `uq_paper_bizkey`，错误名 `paper_duplicate` → 40910（`detail.key_type = OFFLINE_PAPER`，新 key_type 已加进 00 §6.5 枚举））；`verify_sqlite.py` 豁免名单和冻结基线删掉 `upstream_push_log`（第十二轮表级 5 → 4），00 §6.10 第 5 条名单同步；同时删 `outbox_event` 两个键级豁免（8 → 6）和 REPLACE_TODO 里的 `offline_paper_record` / `inbound_message` / `numbering_segment`（24 → 21） | `upstream_push_log` / `offline_paper_record` | 第 11 篇 `11_integration.sql` | 只追加/时间不可改的表不能被 REPLACE 整行改写 | 本增量（`paper_duplicate` 已写入 00 §6.4） |
| 第 11 篇 §6.10 逐唯一键（小玛丽 pr2-r11 X2） | `trg_outbox_no_replace` WHEN 增补 `uq_outbox_seq`（seq>0）与 `uq_outbox_dead_bizkey`（status='DEAD'）两个部分唯一索引子句；本篇其余受锁表 PK/UNIQUE 已全覆盖；verify_sqlite 2i5 逐键行为测试 + 变异 | 第 12 轮 2z3 逐索引扫描将复核（Doro） |
| 第 11 篇号段只许前进 / 入站判重键不可改（小玛丽 blocker） | `numbering_segment`：PG `trg_numbering_guard`（BEFORE UPDATE OR DELETE）+ `trg_numbering_no_truncate`；SQLite `trg_numbering_regress` / `trg_numbering_key_immutable` / `trg_numbering_no_delete` / `trg_numbering_no_replace`。`inbound_message`：PG `trg_in_msg_key_immutable`；SQLite `trg_in_msg_key_immutable` / `trg_in_msg_no_replace`。两表因此进入 §6.10 受锁集合（第十二轮 2z3：受锁 43、已防护 39，静态逐键与 2z3b 实打全部通过；2z3b 需要的 DEAD 样本由 2i5 种子提供）；PG 固定 search_path 函数 56→58；错误名 numbering_regress / numbering_key_immutable / inbound_message_key_immutable → 40930，inbound_message_duplicate → 40910 INBOUND_MESSAGE | 已登记 00 §6.4（本增量） |
| 第 11 篇外键（配合 #2 第十三轮） | `audit_log.warehouse_id`、`offline_paper_record.warehouse_id` → `warehouse(id)`，两库都写在 CREATE TABLE 里；种子孤儿 0。`outbox_event` / `upstream_push_log` 的 `warehouse_id` 默认 0（= 未归属哨兵，不是真实引用）不加；`inbound_message` / `idempotency_record` 无仓 / SKU / 库位列。`audit_log.actor_id` → `sys_user(id)`（Doro 裁定，不挪文件不改加载顺序）：SQLite 已写进 11 的 CREATE TABLE（SQLite 建表不检查父表，可前向引用），verify_sqlite 断言 `pragma foreign_key_list` + 孤儿插入被拒；PG 由爱弥斯在 `12_auth.sql` 末尾 `ALTER TABLE audit_log ADD CONSTRAINT fk_audit_actor FOREIGN KEY (actor_id) REFERENCES sys_user(id)` 补上，随第 12 篇的 PR 一起落库（负责人：爱弥斯；触发条件：第 12 篇 PR 合并；12 的 verify 查 `pg_constraint` 断言 `fk_audit_actor` 存在 + 孤儿 actor_id 插入被拒）。`audit_log.approval_id` → `approval_request`：列和外键都在 12b，待爱弥斯（PG ALTER ADD CONSTRAINT，SQLite ALTER ADD COLUMN … REFERENCES） | actor_id SQLite 已落库，PG 待爱弥斯（12_auth 末尾 ALTER `fk_audit_actor`，随第 12 篇 PR）；approval_id 待爱弥斯（12b） |
| 第 11 篇触发器 / 索引名冻结基线 | verify.sh / verify_sqlite.py 2z4-11（7 张表含 audit_log；PG 21 触发器 / 23 索引，SQLite 34 / 23），少一个 = 红，带变异 | 本增量 |
| T2（Doro 裁定，00 §6.8 第 7 条）：`audit_log`、`inbound_message` 加 `client_occurred_at TIMESTAMP`（可空，设备原始时间，只展示/排障，不参与任何 CHECK、清理、比较；格式 CHECK `ck_audit_cts` / `ck_in_msg_cts`，无容差）；PG `trg_11_recv_server_time`（触发器 `trg_audit_server_time` / `trg_in_msg_server_time`，表属主豁免）强制 `occurred_at` / `received_at` 为库时间；SQLite `trg_audit_occurred_now` / `trg_in_msg_received_now`（±300s） | `audit_log` / `inbound_message` | 第 11 篇 `11_integration.sql`（`audit_log` 是本篇建的表；第 12 篇的节点列 ALTER 不变） | 小玛丽 time-scan 11-6 / B3-5：审计与入站时间不能倒填 | 本增量（规则已在 00 §6.8 第 7 条） |
| 第 11 篇时间加固：`trg_upl_server_time`、`trg_idem_server_time`、`trg_paper_server_time`（PG，`SET search_path = pg_catalog, public, pg_temp`，表属主豁免）；SQLite `trg_upl_received_now`、`trg_idem_created_now`、`trg_idem_expires_past`、`trg_idem_expires_ttl`、`trg_paper_submitted_now`、`trg_paper_approved_now`、`trg_paper_time_immutable`；`idempotency_record.ttl_seconds` + `ck_idem_ttl`；SQLite `ck_paper_ts`，`ck_upl_retain` / `ck_paper_deadline` / `ck_paper_window` / `ck_paper_expired` 改整数秒 | `upstream_push_log` / `idempotency_record` / `offline_paper_record` | 第 11 篇 `11_integration.sql`（本篇自有表） | 小玛丽 time-scan 11-1…11-5：接收/去重/补录/审批时间由库写，00 §6.8 | 本增量 |
| `audit_log.occurred_at`、`inbound_message.received_at`、`numbering_segment.updated_at` 默认值 `DEFAULT now()` → `DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC'))`；`idempotency_record.created_at`、`outbox_event.created_at` / `next_retry_at`、`offline_paper_record.submitted_at` / `created_at` 补整秒 | 同左 | 第 11 篇 `11_integration.sql` | 11-6：原默认值是会话时区、带微秒（00 §6.8）。`audit_log` 的节点列归第 12 篇，本篇只改本篇建的列；列型本来就是 `TIMESTAMP`，无 timestamptz，无需 ALTER | 本增量 |
| 错误码 `upl_received_not_now`、`idem_created_not_now`、`idem_expires_in_past`、`idem_expires_not_ttl`、`paper_submitted_not_now`、`paper_approved_not_now`、`audit_occurred_not_now`、`inbound_received_not_now`（SQLite） → 40003；`paper_duplicate` → 40910（`detail.key_type = OFFLINE_PAPER`，新 key_type 已加进 00 §6.5 枚举） CLIENT_TIME_INVALID；`paper_time_immutable` → 40004 TIME_FIELD_IMMUTABLE（23514） | 第 11 篇三张表 | 第 11 篇 | 复用 00 §6.4 已有码，不新开码；库层名 → 对外码映射行由本增量写入 00 §6.4（Doro 同意本次例外） | 已登记 00 §6.4（本增量） |

## 触发器 search_path 与 outbox 插入

本篇定义的 10 个函数都固定 `SET search_path = pg_catalog, public, pg_temp`（#2 第九轮起 pg_temp 必须显式且最后，见 00 §6.9）。`purge_expired()` 原本就有。另外 9 个是触发器函数，不是 SECURITY DEFINER，按调用方身份执行：`trg_mvk_line_kind`、`trg_sll_immutable`、`trg_hold_immutable`、`trg_hold_no_delete`、`trg_append_only`（`02_inventory.sql`），`trg_lot_sell_deadline`（`01_master.sql`），`trg_purge_guard`、`trg_expiry_forward`、`trg_outbox_insert_pending`（`11_integration.sql`）。

`trg_outbox_insert_pending` 不按 `current_user = 'wms_app'` 判断。`wms_app` 是 NOLOGIN，应用用继承它的登录角色。不是 `outbox_event` 表属主的角色，插入时 `status` 必须是 `PENDING` 且 `sent_at` 为空，否则拒绝（`outbox_insert_not_pending`），不把状态改写成 `PENDING`。表属主可以插入其他状态，供种子和迁移使用。SQLite 没有角色，也没有 search_path；同名触发器拒绝一切非 PENDING 或带 `sent_at` 的插入，包括 `FAILED`。

第 3 篇 `03_inbound.sql` 新增的 4 个 PG 函数也固定 `SET search_path = pg_catalog, public`：`trg_iqf_guard`、`trg_inb_closed_guard`、`trg_inbl_closed_guard`、`trg_irc_guard`（都是触发器函数，不是 SECURITY DEFINER）。verify.sh 第 2j-sp 段做目录断言和同名表劫持检查。
