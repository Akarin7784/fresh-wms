# fresh-wms 项目交接文档

> 作者：大肥鱼（项目经理） · 日期：2026-10-15 · 基线：`main@8ed5f0c`
> **进度与待办以 [issue #14](https://github.com/Akarin7784/fresh-wms/issues/14) 为准**，本文只做背景与设计导读，不替代 #14。
> 写本文时项目处于暂停状态：13 个设计 PR（#1–#13）均未合并，无进行中的改动。

## 1. 项目背景

- **是什么**：生鲜配送中心 WMS，服务 B2B 生鲜城配（商超、餐饮门店、社区团购履约点）。单仓起步，模型按多仓设计。设计目标优先级：**账实一致 > 作业效率 > 可扩展到多仓**。
- **调研标准**：业务口径以盒马为对标（如可售天数下架转损耗对标盒马日日鲜、门店退货的退货预约 + 盲收）。
- **工作方式**：**先完成全部详细设计文档，再开始开发**。每篇设计配 PostgreSQL 16 / SQLite 双库 DDL 与可证伪的验证脚本。
- **评审**：对抗式评审，测试工程师 **小赵**、**小吴** 实测双库攻击设计主张；评审结论按「阻断/严重/建议」计数贴在各 PR。
- **系统外（只做集成）**：采购合同、销售定价、财务结算、车辆调度、路径规划（ERP / TMS / 财务系统）。

### 人员分工

| 人员 | 角色 | 负责 |
|---|---|---|
| 大肥鱼 | 项目经理 | 00 总体设计、01 主数据、02 库存核心（04 出库与分配随 #2） |
| 小钱 | 后端开发 | 09 效期与损耗、10 退货与异常、11 接口集成、16 配送与签收、17 加工中心 |
| 小李 | 后端开发 | 06 复核装箱发货、18 活鲜暂存，及 #7（05 波次与拣货） |
| 小周 | 前端开发 | 13 管理后台、14 分拣 H5/PDA、15 司机端/商城端 |
| 小赵、小吴 | 测试 | 对抗式评审 |

## 2. 总体设计要点（00 篇，#2）

- **冲突规则**：模块文档与 00 冲突时以 00 为准，改规则先改 00。
- **技术栈**：Python 3.12 + FastAPI + Pydantic v2；SQLAlchemy 2.0 + Alembic（batch 模式）；SQLite ≥ 3.35（开发、边缘节点）/ PostgreSQL 16（中心、生产）；APScheduler；Vue 3（后台 Element Plus、分拣端 Vant H5）；司机端/商城端小程序 / uni-app；Docker Compose；pytest + hypothesis + 双库矩阵。
- **Redis 可选**：只做缓存和 JWT 吊销黑名单；**ID、单号、幂等都不依赖 Redis**（离线边缘节点没有 Redis）。
- **分层**：api → service → repository → db，domain 为纯逻辑；import-linter 卡依赖方向。service 管事务边界，任何模块不得绕过第 2 篇库存原语写 `stock`。
- **双库建模规则 R1–R12**：雪花 `BIGINT` 主键；数量 `*_qty_milli BIGINT`、金额存分，**不用 NUMERIC**；时间存 UTC、业务日期按仓库时区；不用 JSONB/数组/ENUM；不用外键级联；并发扣减只用条件 UPDATE + rowcount，禁止 `SELECT FOR UPDATE`；进入 UNIQUE 的列 NOT NULL + 哨兵值。
- **单仓单写库**、边缘节点（SQLite）形态、离线与写节点切换见 00 §6.1a、§9.1。
- **职责分离**：拣货人 ≠ 复核人、收货人 ≠ 上架人、冻结人 ≠ 解冻人、封箱人必须是复核人等，写进模型层并审计。

## 3. 各篇设计摘要（按 PR 分支上的文档）

| 篇 | PR / head | 内容要点 |
|---|---|---|
| 00 总体设计 | #2 `7dbd566` | 范围、技术选型、分层、R1–R12、ID/单号/数量/错误码/幂等/权限/时间全局约定、离线与 `paused_actions` |
| 01 主数据 | #8 `5d8c877` | 仓/温区/库位/SKU/单位条码/批次；新增往来方、车辆司机、设备与 `node_registry`；主数据下发 `md_change_log`；停用守卫与停用期间动作白名单；`zone.temp_min_c10/temp_max_c10`、`sku.sell_days` |
| 02 库存核心 | #2 `7dbd566` | `Quantity` 值对象；`stock`、占用 `stock_reservation`、冻结 `stock_hold`（新增）、流水 `stock_movement` + 去重键 + 分录、日终快照与对账告警；库存原语统一事务模板；拣货扣减、预占、移库流程 |
| 04 出库与分配 | #2 `7dbd566` | 出库单/行、FEFO 单事务分配、越权分配 `allocation_override`、待回库 `return_record` 约束与闭环（补传被拒、拣后取消） |
| 05 波次与拣货 | #7 `7f83be0` | 波次、拣货任务/行状态机；释放单事务；拣货确认最热路径；离线补传被拒转待回库；改派、撤销拣货；`pick_op`、`wave_capacity_config` |
| 06 复核装箱发货 | #11 `914b194` | 复核单/扫描、`check_picker`、箱 `pack_box`（封箱后不可改）、`box_void_request`、车次 `shipment` / `shipment_order`；`wms_app` 最小权限 |
| 09 效期与损耗 | #4 `1a0b4bb` | 日期口径 `domain/expiry.py`；每日效期扫描；可售天数到期下架转损耗；报损单 `scrap_order/scrap_line` 审批过账；交接报损、已出库待报损、误报作废；`uq_scr_source` |
| 10 退货与异常 | #5 `f1f512b` | 拒收回仓 → 退货入库、清点差异、退货质检、门店退货预约 + 盲收；异常码字典与异常单、超时升级 |
| 11 接口集成 | #6 `78862ee` | 上游推单、`outbox_event` 出站投递、`upstream_push_log`；边缘回传与写节点、切换后单据核对；`stale_stock_policy` 与 §6.7 暂停（50304）；`offline_paper_record` 纸质单补录 |
| 12 权限与审计 | #9 `d43f3c7` | 令牌、PDA/司机端设备绑定、离线令牌、写入 epoch；角色权限点矩阵、按仓隔离；SoD 与主管审批 `approval_request`；只追加审计日志 |
| 13 管理后台前端 | #1 `72d0b2f` | 页面路由、ProTable、页面→接口映射、错误码处理（50301/50303 自动重发一次后提示）、待回库看板、审批中心、箱作废与签收容差等 |
| 14 分拣 H5/PDA | #1 `72d0b2f` | 现场交互硬性要求、离线 outbox 与幂等、补交冲突、写节点切换、设备绑定、断网可用清单、盲收登记 |
| 15 司机端/商城端 | #3 `1ae433a`（#1 含概要） | 司机签收/更正/离线 outbox、错误码→前端处理、边缘节点部署形态、商城端 |
| 16 配送与签收 | #10 `b5f1ec1` | 运单/站点、签收 `pod_op/pod_line`（逐行温度必录）、签收更正 `pod_correction` 与容差配置、回仓交接、设备序号水位 |
| 17 加工中心 | #13 `b36c530` | BOM、加工单、领用、报工、产出；守恒校验、出成率由库重算（偏离需审批号）、冲回上限、保质期上限、批次双向追溯；`stock_hold` 增 `PROCESSING` |
| 18 活鲜暂存 | #12 `11b566c` | 双数量（只数/重量）、暂养池 `live_tank` 与锁池、巡检、出池称重、死亡登记、日失重结算，9 张新表 |

## 4. 已定规则

### 4.1 数量、ID、时间
- 数量库内存 `BIGINT` 千分位（`*_qty_milli`）；**接口出参固定 3 位小数字符串**（如 `"12.500"`），入参只收字符串、最多 3 位小数，超出返回 400，不四舍五入，全程不经过 float。
- ID 用应用层雪花算法，**不依赖 Redis**；时钟回拨拒绝发号返回 `50302`。单号格式 `{类型}-{仓前缀}-{节点号4位}-{yyyyMMdd}-{序号}`。
- 时间戳存 UTC；业务日期按仓库时区。`box_void_request` 只返回最近一次申请，时间用 UTC。

### 4.2 错误码（00 §6.4 为准）
| 码 | 含义 |
|---|---|
| 40910 | 幂等冲突，`detail.key_type` 必填：`IDEMPOTENCY_KEY` / `PDA_OP` / `POD_OP` / `POD_CORRECT` / `SOURCE_ORDER` / `LIVE_WEIGH`；第 17 篇拟增 `PROCESS_REPORT` / `PROCESS_ISSUE`（待拍板） |
| 40930 | 非法状态流转；`reason=SEALER_NOT_CHECKER` 封箱人必须是复核人（已占用） |
| 40938 | `LIVE_DEATH_OVER_APPROVAL_REQUIRED`（第 18 篇，待登记进 00） |
| 42214 | `OVER_QTY`，`reason` 必带（`OVER_PICK`/`OVER_CHECK`/`SELL_EXPIRED`/`OVER_REVERSE`；第 18 篇锁池时 `LIVE_HOLD`） |
| 42215 | `STAGING_TEMP_ZONE_MISMATCH` 集货位温区不符 |
| 42216 | `POD_TEMP_OUT_OF_RANGE` 签收温度超温区 |
| 42217 | `WEIGH_OUT_OF_TOLERANCE` 称重超容差（第 17/18 篇） |
| 50301 | 写库不可用，重取写地址后按原键重提 |
| 50302 | `ID_CLOCK_BACKWARD` |
| 50303 | `STALE_WRITE_NODE`，后台自动重发一次后转手动 |
| 50304 | `STALE_STOCK_PAUSED`，暂停码；客户端不重试、不重取写地址 |

### 4.3 业务规则
- **可售天数**：`sku.sell_days` 修改只对新批次生效；`lot.sell_deadline` 建批次时写入，**不回溯已有批次**，只能往前改。
- **报损去重 `uq_scr_source (source_type, source_id, source_date)`** 覆盖全部来源（取消 `uq_scr_sell`）：白名单 `SELL_EXPIRED`、`LIVE_SHRINK` 的 `source_date` 填作业日期；其余来源（含 `LIVE_DEATH`）固定 `1970-01-01`，建单后不可改。
- **温区**：上下限在 `zone.temp_min_c10/temp_max_c10`，允许只填一边；两边都填时下限 < 上限。签收 42216 只校验填了的一边，两边都空不校验，但 `receive_temp_c10` 始终必填。
- **签收更正**：签收后 24 小时内可申请，超窗返回 40951 并生成异常单；容差内（`pod_tolerance_config`）直接生效，超容差走主管审批。
- **离线**：最长离线 12 小时，超过后服务端把 `PICK_CONFIRM/CHECK/SHIP/RECEIVE/POD` 加入 `paused_actions`；恢复联网后 24 小时内完成纸质单补录（`PAPER_BACKFILL`），超时转异常单。
- **`paused_actions`** 共 8 值：`ALLOCATE`、`TRANSFER`、`WAVE_RELEASE`（PAUSE 期间即下发）+ 上述 5 个（离线超 12h）。已定新增 `LIVE_WEIGH_OUT`（离线超 12h 档，待登记进 00）。
- **系统锁** `PROCESSING`、`LIVE_HOLD`：不可手工解冻（40933）、不计入可用量。
- **第 18 篇 Q1–Q8 定案**：称重幂等键 `(task_id, weigh_client_id)`；`shrink_tolerance_bp` 默认 100；死亡率分母取当天 0 点在池只数；锁池时已拣未称重的货随池锁定，返回 42214 `reason=LIVE_HOLD`，判死走 `LIVE_DEATH`。

## 5. PR 现状、合并顺序与待办

**权威清单见 [issue #14](https://github.com/Akarin7784/fresh-wms/issues/14)**（各 PR head、评审状态、每人待办）。摘要：

- 合并顺序：#2 → #5 → #6 → #4 → #8 → #9 → #7 → #10 → #11 → #12 → #13；#1、#3 在 #2 之后。每合并一个 PR 重新生成 `schema_sqlite.sql`。
- 已通过：#2（小赵）、#8（小吴）；其余待复审最新 head。
- 冲突以普通 merge 提交解决，**不 force push**。
- #14 之外的补充项：**小钱 #4 补 `PROCESS_LOSS` 报损来源**（第 17 篇副产品损耗）。

## 6. 如何验证

脚本在 `wms-design/sql/`，退出码非 0 即表示设计文档中的某条主张不成立：

```bash
# PostgreSQL 16：有连接时直连（需 psql，请用空库）
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=xxx PGDATABASE=postgres bash wms-design/sql/verify.sh
# 未设置 PGHOST 时自动起一次性 Docker PG16 容器
bash wms-design/sql/verify.sh

# SQLite：把 PG DDL 机械翻译成 SQLite 并跑相同断言
python wms-design/sql/verify_sqlite.py
```

- `verify.sh` 中 `EXPECT_TABLES` / `EXPECT_INDEXES` 需随 DDL 同步修改。
- 各 PR 描述里记录了该 head 的双库断言通过数（如 PG 272/272、SQLite 276/276）。
