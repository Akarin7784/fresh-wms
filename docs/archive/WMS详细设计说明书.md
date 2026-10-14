# 生鲜配送中心 WMS 详细设计说明书

版本 v1.0 ｜ 状态：设计定稿 ｜ 适用范围：单仓起步、多仓扩展

> **已归档（2026-10-15）**：本文档已拆分为 [`docs/00-总体设计.md`](../00-总体设计.md) 与各模块详细设计，以拆分后的文档为准。建表与验证脚本仍在 [`wms-design/sql/`](../../wms-design/sql/)。正文中命令 `sql/verify.sh` 等路径相对 `wms-design/` 目录。

---

## 0. 文档说明

### 0.1 设计目标

为一家做 **B2B 生鲜城配**（给商超、餐饮门店、社区团购履约点供货）的企业，设计一套自研 WMS，并配套分拣端、司机端、商城端三个作业/交易入口。

设计上要同时满足三件事，它们的优先级从高到低是：

1. **账实一致**。库存数量在任何时刻、任何并发下都不能错。生鲜仓错一次账，损失的是货 + 信任，所以这是硬约束。
2. **作业效率**。分拣员的动线、扫码次数、异常处理路径决定人效，人效决定这个仓能不能赚钱。
3. **可扩展到多仓 / 第三方仓**。第一版只跑一个仓，但模型不能写死单仓。

### 0.2 关键设计决策一览（面试可当作"主张"直接讲）

| # | 决策 | 选择 | 被否决的备选 | 否决理由 |
|---|---|---|---|---|
| D1 | 库存记账模型 | **数量 + 预留（reservation）行**，不冻结库存行 | 每笔占用生成一条"冻结库存"行 | 冻结行方案在 SQLite 上无法用 `SELECT FOR UPDATE`，且盘点/合并逻辑爆炸 |
| D2 | 库存并发控制 | **单条 `UPDATE ... WHERE on_hand >= ?` 条件更新 + 受影响行数判定** | 悲观行锁 / 乐观版本号重试 | 团队同时用 SQLite 与 PostgreSQL，条件更新是唯一在两边语义一致的写法 |
| D3 | 金额与数量单位 | 数量用 `NUMERIC(14,3)`，金额用"分"存 `BIGINT` | float / Decimal 存金额 | float 累加误差；Decimal 在 SQLite 退化为 TEXT 排序错乱 |
| D4 | 状态机位置 | 状态迁移收敛在 **domain 层单一函数**，Service 不许直接改 status 字段 | 各 Service 分散 `if status in (...)` | 分散判断是 WMS 最典型的脏数据来源 |
| D5 | 双数据库支持 | SQLAlchemy 2.0 ORM-only + Alembic 双方言迁移，**禁写方言 SQL** | 只支持 PG，SQLite 当玩具 | 团队现实是 SQLite 起步。必须让"换库"是配置项而不是重构项 |
| D6 | 波次生成时机 | **定时 + 手动双触发**，按"路由/温区/承运商"聚波 | 来单一即波 | 生鲜要凑整车，单波拣货效率低 30% 以上 |
| D7 | 批次与效期 | 批次是**一等实体**，出库强制 FEFO，允许人工越权但记录原因 | 效期只当 SKU 属性 | 越权必须有审计，否则食安追溯断链 |
| D8 | 对外集成 | Webhook 推送 + 幂等表 + 死信重放 | 定时轮询拉单 | 轮询延迟高、峰值打爆上游 |
| D9 | 前端 | Vue 3 + TS + Vite + Element Plus | React + AntD | 国内管理后台生态、招人成本；两者都熟，选 Vue |
| D10 | 多端接入 | **同一套 API + `client_type` 声明 + 功能开关**，不为每端开一套接口 | 每端一套 BFF | 三端逻辑高度重叠，BFF 会复制三份 bug |

### 0.3 阅读路径

- 只关心**库存怎么不写错**：读 §3（数据模型）、§4（库存核心）。
- 只关心**业务流程能不能跑通**：读 §5（流程与状态机）。
- 只关心**工程落地**：读 §6–§11。
- 想确认**这些结论是跑出来的还是想出来的**：直接看 §16 附录 A，含可复现命令、实测数字、以及验证过程中抓出来的 3 个 bug。
- 建表脚本单独放在 [`sql/schema_postgres.sql`](../../wms-design/sql/schema_postgres.sql)。

---

## 1. 岗位要求逐条拆解

JD 的任职要求不是并列的，它有主次。下面把每一条翻译成"这个项目必须拿出什么证据"。

### 1.1 「2 年以上全栈或后端开发经验，按实际能力定级」

这条不要求你证明会写代码，要求你证明**能做技术决策并承担后果**。所以文档里每个决策都带"被否决的备选 + 理由"，这是初级和中级最明显的分水岭：初级写"我用了什么"，中级写"我为什么不用另一个"。

### 1.2 「有仓储（WMS）、供应链、电商、生鲜履约会开发经验者优先」

"者优先"意味着这是加分项，但它同时暴露了团队在做什么：**生鲜履约 + WMS 的混合系统**。四个领域同时列出来，几乎可以确定是"电商下单 → 仓内作业 → 冷链配送"一条链。

对应到设计里，必须体现这三样东西，否则一看就是照着开源 ERP 改的：

- **效期与 FEFO**：生鲜仓和普通仓最大的差别。同一 SKU 不同到货日期，出库顺序不同，且临期要能主动预警和折价出清。
- **温区**：常温 / 冷藏 0–8℃ / 冷冻 -18℃。库位有温区，订单有温区要求，**波次不能跨温区**，否则分拣员开门进出损失冷链。
- **短保与损耗**：叶菜保质期 2–3 天，作业窗口是凌晨 2 点到 6 点。这决定了系统必须支持"昨日下单、今日凌晨拣、今早发"的**预作业**模式，而不是下单即拣。

### 1.3 「熟练掌握 Python，具备良好工程习惯（分层、可测试、可维护）」

这条是**硬性主技能**，权重最高。"分层、可测试、可维护"三个词是自我暴露——说明他们被不分层、不可测的代码坑过。WMS 恰恰是最容易写出"一坨"的系统，因为业务分支极多。

设计要求：

- 四层结构（api / service / repository / domain），依赖方向单向，**Service 不 import FastAPI，Repository 不 import Service**。
- 事务边界只在 Service 层，Repository 只提供查询和持久化原语。
- 核心不变量（库存不能为负、状态不能跳变）写成 domain 层的纯函数 + 属性测试，可以脱离数据库跑。
- §11 给出测试策略，其中"库存守恒"用 property-based test 覆盖并发场景。

### 1.4 「熟悉主流前端框架（Vue / React 其一），能独立完成管理后台类页面」

"能独立完成"= 不需要前端配合。所以考察的是 CRUD 后台的完整闭环：列表页（查询/分页/排序/导出）、表单页（校验/联动/草稿）、权限渲染、批量操作、异常态。§8 给的是这套抽象，而不是页面截图。

### 1.5 「具备关系型数据库表结构设计能力（团队实际使用 SQLite 与 PostgreSQL）」

这条最有信息量。**同时用 SQLite 和 PostgreSQL 的团队，只有一种典型画像**：小团队、产品形态包含"可私有化部署的单机版"，或者客户端/边缘节点（门店端、仓库本地服务器）用 SQLite 离线跑，中心用 PG。

这意味着设计必须回答一个别人不会主动想的问题：**同一套 schema 和同一套并发语义，怎么在两个差异很大的数据库上都成立。**

- SQLite 不支持 `SELECT ... FOR UPDATE`，写锁是库级的；PG 支持行级锁。
- SQLite 的 `NUMERIC` 亲和性会把 Decimal 转成 REAL；PG 的 `NUMERIC` 是精确的。
- `SERIAL`/`IDENTITY`、`JSONB`、`RETURNING`、部分索引、`ON CONFLICT` 两边支持程度不同。

§3.1 和 §4.3 专门处理这件事。这是全篇最能体现"表结构设计能力"的地方——不是画 ER 图，而是**知道同一张表在两个引擎上会怎么坏掉**。

### 1.6 「了解 Docker 与基本部署运维，能自己把服务跑起来」

"能自己把服务跑起来"= 不需要运维。要求交付的是可复现的启动方式。§10 给一份 `docker-compose.yml`，一条命令拉起 PG + API + 前端 + 初始化数据。

### 1.7 「小程序 / H5 / Flutter 端经验加分（分拣端、司机端、商城端）」

三个端的名字直接给出了系统的对外契约。§9 逐端设计，其中**分拣端**是难点（弱网、扫码、误触、效率优先），**司机端**是签收与回单，**商城端**是订单来源。

---

## 2. 系统总览

### 2.1 业务范围与边界

```
        ┌──────────────────────────────────────────────────────┐
        │                      本 WMS 系统                      │
        │                                                      │
 采购 ──▶│  入库 ─▶ 上架 ─▶ 库存 ─▶ 波次 ─▶ 拣货 ─▶ 复核 ─▶ 发货 │──▶ 配送(司机端)
 销售 ──▶│  (商城端下单)                                        │
 退货 ──▶│  盘点 ─ 移库 ─ 补货 ─ 批次/效期 ─ 损耗 ─ 计费          │──▶ 结算(财务)
        │                                                      │
        └──────────────────────────────────────────────────────┘
              ▲                          │
              │                          ▼
        ERP / 采购系统              TMS 承运商 / 电子面单
```

**系统内**：库内作业全链路 + 库存账 + 批次效期 + 三个作业端。

**系统外（只做集成）**：采购合同、销售定价、财务对账、车辆调度算法、路径规划。这些由 ERP / TMS / 外部 API 承担，WMS 通过 §7 的接口对接。

边界要划清楚，因为面试里"这个你做不做"是必问的。把计费做成"记录作业量，账单由财务系统算"，把配送做成"下发运单、回传签收"，是合理且能自圆其说的切法。

### 2.2 端与角色

| 角色 | 使用端 | 主要动作 | 关键约束 |
|---|---|---|---|
| 仓管员 | 管理后台 / 分拣端 | 收货、上架、移库、补货 | 只能操作自己有权限的仓库 |
| 分拣员 | 分拣端（H5/PDA） | 领取任务、扫码拣货、异常上报 | 只看自己的任务，界面极简、大按钮 |
| 复核员 | 分拣端 | 扫码复核、称重、装箱、贴面单 | 复核与拣货**必须不同人**（职责分离） |
| 司机 | 司机端（小程序） | 接单、装车确认、到达签收、回单拍照 | 离线可用，签收要能补传 |
| 客户（门店/团长） | 商城端（H5/小程序） | 下单、查订单、查对账、发起退货 | 只能看自己的单 |
| 仓经理 | 管理后台 | 波次策略、人员排班、异常处理、报表 | 有审批权限 |
| 系统管理员 | 管理后台 | 主数据、权限、字典、接口配置 | 无业务操作权限（避免越权改账） |

**职责分离（SoD）规则**要在模型层写死，不靠自觉：同一张出库单，`picker_id != checker_id`；同一张入库单，`receiver_id != putaway_operator_id`（小仓可放宽，通过配置项控制）。

### 2.3 技术选型

| 层 | 选型 | 版本基线 | 选型理由 |
|---|---|---|---|
| 语言 | Python | 3.12 | 团队主栈 |
| Web 框架 | FastAPI + Uvicorn | 0.115 | 类型驱动、自动 OpenAPI，前端可直接生成 TS 客户端 |
| ORM | SQLAlchemy 2.0 | 2.0.x | 双方言支持最成熟；`async` 可选 |
| 迁移 | Alembic | 1.13+ | 支持 `render_as_batch`（SQLite 改表能力弱，必须开） |
| 数据校验 | Pydantic | v2 | 请求/响应/配置三用 |
| 任务队列 | Celery + Redis（或 APScheduler 起步） | — | 波次生成、效期扫描、单据推送重试 |
| 数据库 | SQLite（开发/边缘）→ PostgreSQL 16（生产） | — | 见 §1.5 |
| 缓存/锁 | Redis 7 | — | 编号发号、分布式锁、会话 |
| 管理后台 | Vue 3 + TypeScript + Vite + Element Plus + Pinia | — | 见 D9 |
| 分拣端 | Vue 3 + Vant（H5，可嵌 PDA WebView） | — | PDA 通常是 Android + 浏览器内核 |
| 司机端 | 微信小程序（原生或 Taro） | — | 司机不接受装 App，小程序是唯一现实选择 |
| 商城端 | uni-app 或 Taro（H5 + 小程序双端） | — | 客户既在微信也在浏览器下单 |
| 部署 | Docker Compose（起步）→ K8s（多仓） | — | 见 §10 |
| 测试 | pytest + hypothesis + testcontainers | — | 见 §11 |

**为什么后端不用 Django**：JD 强调"分层"，Django 的 ORM 和 admin 会把人往"约定优先"的方向带，SQLite/PG 双方言下 Django 的 migration 自动行为更难控。FastAPI + SQLAlchemy 显式分层，更容易做到 §1.3 的要求。代价是要自己搭权限、分页、审计这些通用件——这恰好是能被考察到的工程量。

### 2.4 工程结构

```
wms/
├── pyproject.toml
├── alembic/
│   └── versions/                 # 迁移脚本（人工审核后入库）
├── src/wms/
│   ├── main.py                   # 仅装配：DI 容器、中间件、路由注册
│   ├── config.py                 # Pydantic Settings，环境变量驱动
│   ├── api/                      # ← 只做 HTTP 翻译，不写业务
│   │   ├── deps.py               # 当前用户/仓库/权限点注入
│   │   ├── v1/
│   │   │   ├── inbound.py
│   │   │   ├── outbound.py
│   │   │   ├── inventory.py
│   │   │   ├── wave.py
│   │   │   ├── picking.py
│   │   │   ├── master.py
│   │   │   └── integrations.py
│   │   └── schemas/              # Pydantic 请求/响应模型
│   ├── service/                  # ← 业务编排 + 事务边界
│   │   ├── inbound_service.py
│   │   ├── putaway_service.py
│   │   ├── allocation_service.py # 库存分配（FEFO/温区）
│   │   ├── wave_service.py
│   │   ├── picking_service.py
│   │   ├── check_pack_service.py
│   │   ├── shipping_service.py
│   │   ├── inventory_service.py
│   │   ├── count_service.py      # 盘点
│   │   └── numbering_service.py  # 单号
│   ├── repository/               # ← 只有查询与持久化原语
│   │   ├── base.py
│   │   └── inventory_repo.py
│   ├── domain/                   # ← 纯逻辑，零框架依赖，可单测
│   │   ├── models.py             # 领域对象（非 ORM 类）
│   │   ├── state_machines.py     # 所有状态迁移表
│   │   ├── invariants.py         # 库存守恒等不变量断言
│   │   └── fefo.py               # 批次选择算法
│   ├── db/
│   │   ├── base.py               # engine/session 工厂，方言适配
│   │   ├── types.py              # Money / Decimal 兼容列类型
│   │   └── models/               # ORM 映射类，按模块拆分
│   ├── integration/              # ERP / 面单 / 微信
│   │   ├── erp_client.py
│   │   ├── waybill_client.py
│   │   └── wechat.py
│   ├── jobs/                     # Celery/APScheduler 任务
│   └── common/                   # 异常、错误码、日志、工具
├── web/                          # 管理后台（Vue）
├── h5-picker/                    # 分拣端
├── miniprogram-driver/           # 司机端
├── docker-compose.yml
└── tests/
    ├── unit/                     # domain 层，无 DB
    ├── integration/              # 真库（parametrize: sqlite / postgres）
    └── property/                 # hypothesis 库存守恒
```

依赖方向（违反即 CI 失败，用 import-linter 约束）：

```
api  →  service  →  repository  →  db
  ↘        ↘            ↘
     domain  ←──────────┘        # domain 不依赖任何人
```

---

## 3. 数据模型

### 3.1 双数据库约束下的建模规则

这是整个数据模型的前提，先立规矩。以下规则**必须写进 code review 清单**，因为违反它们不会报错，只会在换库时炸。

| 规则 | 原因 |
|---|---|
| R1 所有表用 `id BIGINT`（应用层雪花/号段生成）而非数据库自增主键 | SQLite 自增是 `INTEGER PRIMARY KEY`，PG 是 `BIGSERIAL`，两者 DDL 不兼容；且分库/数据迁移时自增会撞 |
| R2 金额一律 `BIGINT` 存"分"；数量一律 `NUMERIC(14,3)`，通过自定义 `Money`/`Quantity` 列类型读写 | SQLite 的 NUMERIC 亲和性会退化为 REAL 产生浮点误差；自定义类型在 SQLite 侧存整数最小单位（"厘"）规避 |
| R3 时间戳存 UTC，列类型 `TIMESTAMP`，业务侧统一用 `datetime.now(UTC)`；展示层转 `Asia/Shanghai` | SQLite 无时区概念，`TIMESTAMPTZ` 只在 PG 存在，混用会导致凌晨作业的时间错位 |
| R4 不使用 `JSONB`、数组列、`ENUM` 类型。需要枚举时用 `VARCHAR(32)` + Python `StrEnum` | 三者都是 PG-only 或行为差异大 |
| R5 不使用数据库外键约束做级联删除，只建索引；删除语义由 Service 层控制 | SQLite 默认不启用 FK（需 `PRAGMA foreign_keys=ON`），依赖 FK 会导致两边行为不一致 |
| R6 所有软删除用 `deleted_at TIMESTAMP NULL` + 部分唯一索引改为**普通唯一索引 + 墓碑值** | PG 支持部分索引 `WHERE deleted_at IS NULL`，SQLite 也支持，但 SQLAlchemy 的 `index_where` 在迁移里易丢，统一用 `uq_code_deleted_at` 组合唯一 |
| R7 并发扣减只用条件 UPDATE，禁止 `SELECT FOR UPDATE` | SQLite 不支持 |
| R8 所有 DDL 变更走 Alembic，且 `render_as_batch=True` | SQLite `ALTER TABLE` 能力极弱，不 batch 会直接失败 |
| R9 布尔用 `SMALLINT` 0/1（SQLAlchemy `Boolean` 默认行为），列名 `is_xxx` | 两边一致 |
| R10 全文搜索不建数据库触发器，PG 用 `pg_trgm`（可选、有开关），SQLite 侧降级为 `LIKE` | 方言差异最大的地方，隔离在 repository 的一个方法里 |
| **R11** 任何进入 `UNIQUE` 约束的列必须 `NOT NULL` + 哨兵默认值（`0` / `''` / `-1`），**不许用 NULL 表达"无"** | 实测两引擎都把唯一约束中的 NULL 当作互不相等，NULL 参与唯一键 = 该约束静默失效（见 §4.1 的 `container_id` 教训） |
| **R12** 核心不变量除应用层断言外，必须在库里放一份 `CHECK`（超占、流水平衡、职责分离） | 应用层有 bug 或被绕过时，库是最后一道防线；两引擎都强制执行 CHECK，属于交集内能力 |

> 讲给面试官的一句话：**"我们不是先设计再兼容两个库，而是把设计限制在两个库的交集上，代价是放弃 PG 的一些高级类型，换来的是本地 SQLite 跑起来的集成测试和生产 PG 行为一致。"**

### 3.2 ER 总览

```mermaid
erDiagram
  WAREHOUSE ||--o{ ZONE : has
  ZONE ||--o{ LOCATION : has
  SKU ||--o{ SKU_UNIT : has
  SKU ||--o{ LOT : has
  LOCATION ||--o{ STOCK : holds
  LOT ||--o{ STOCK : holds
  INBOUND_ORDER ||--|{ INBOUND_LINE : contains
  INBOUND_LINE ||--o{ STOCK : "creates"
  OUTBOUND_ORDER ||--|{ OUTBOUND_LINE : contains
  OUTBOUND_ORDER }o--|| WAVE : joins
  WAVE ||--o{ PICK_TASK : generates
  PICK_TASK ||--|{ PICK_TASK_LINE : contains
  PICK_TASK_LINE ||--o{ STOCK : "consumes"
  OUTBOUND_ORDER ||--o{ SHIPMENT : "ships_in"
  SHIPMENT ||--o{ DRIVER : assigned
  STOCK ||--o{ STOCK_MOVEMENT : logs
  COUNT_ORDER ||--o{ COUNT_LINE : contains
```

### 3.3 主数据表

#### warehouse 仓库

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGINT PK | |
| code | VARCHAR(32) UK | 仓库编码，如 `WH-SH-01` |
| name | VARCHAR(64) | |
| status | VARCHAR(16) | `ACTIVE` / `SUSPENDED` / `CLOSED` |
| timezone | VARCHAR(32) | 默认 `Asia/Shanghai`，多仓必备 |
| cutoff_time | TIME | 截单时间，如 `20:00`，决定订单进哪个作业日 |
| work_date_offset | SMALLINT | 作业日偏移。`-1` 表示"今天凌晨拣的是昨天截单的货" |
| address / contact / phone | VARCHAR | |
| geohash | VARCHAR(12) | 司机端调度、电子围栏用 |
| created_at / updated_at | TIMESTAMP | |

`work_date_offset` 是生鲜仓的特殊字段，普通 WMS 没有。它把"作业日"和"自然日"分开——凌晨 3 点拣货，业务上属于"今天（配送日）的货"，但数据库记录发生在昨天。不引入这个概念，所有报表口径都会错。

**作业日计算**：`work_date = date_of(shift_start)`，其中 `shift_start` 由仓库配置（例：每日 00:30 为作业日切换点）。所有单据落 `work_date` 字段，报表按它聚合，不按 `created_at`。

#### zone 库区

| 字段 | 类型 | 说明 |
|---|---|---|
| id / warehouse_id | BIGINT | |
| code / name | VARCHAR | |
| temp_zone | VARCHAR(16) | `AMBIENT` 常温 / `CHILLED` 冷藏 0-8℃ / `FROZEN` 冷冻 / `FRESH` 鲜活 |
| temp_min / temp_max | NUMERIC(5,2) | 温度阈值，用于告警 |
| zone_type | VARCHAR(16) | `RECEIVE` 收货暂存 / `STORAGE` 存储 / `PICK` 拣货 / `STAGE` 集货 / `SHIP` 发货 / `RETURN` 退货 / `QUARANTINE` 质检隔离 |
| pick_sequence | VARCHAR(32) | 动线序号，字符串按自然序设计（`A010`、`A020`…） |

`zone_type` 与 `temp_zone` 是正交的两个维度：拣货区可以是冷藏也可以是常温。这个拆分让"补货"逻辑清晰——从 `STORAGE` 补到 `PICK`。

#### location 库位

| 字段 | 类型 | 说明 |
|---|---|---|
| id / warehouse_id / zone_id | BIGINT | |
| code | VARCHAR(32) UK(warehouse) | `A01-02-03` 区-排-层，扫码即定位 |
| location_type | VARCHAR(16) | `PALLET` 托盘位 / `SHELF` 货架位 / `FLOOR` 地堆 / `BIN` 料盒 |
| capacity_weight | NUMERIC(12,3) | 承重 kg |
| capacity_volume | NUMERIC(14,3) | 体积 m³ |
| max_lots | SMALLINT | **该库位允许的最大批次数**。拣货位设 1–2，强制先进先出、减少分拣员找货时间 |
| mix_sku | BOOLEAN | 是否允许混 SKU。拣货位通常 `false`（一位一 SKU） |
| pickable | BOOLEAN | 是否参与拣货分配 |
| abc_class | VARCHAR(2) | A/B/C 动销分类，影响上架推荐 |
| status | VARCHAR(16) | `AVAILABLE` / `LOCKED`（盘点或异常冻结）/ `DISABLED` |
| lat / lng | NUMERIC(10,7) | 大型仓 PDA 定位辅助 |

`max_lots` 和 `mix_sku` 是"上架推荐"算法的核心约束，也是最能体现真做过仓的字段。没有它们，上架推荐就退化成"找个空位塞进去"。

#### sku 商品

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGINT | |
| code | VARCHAR(32) UK | 商品编码（对接 ERP） |
| barcode | VARCHAR(64) | 主条码；一 SKU 多条码走 `sku_barcode` 子表 |
| name / spec | VARCHAR | `山东 红富士 80# 5kg/箱` |
| category_id | BIGINT | 分类树 |
| brand | VARCHAR(64) | |
| base_uom | VARCHAR(16) | 库存基本单位：`KG` / `PCS` / `EA` |
| temperature_required | VARCHAR(16) | 该 SKU 要求的最低温区（拣货时校验库位温区兼容） |
| shelf_life_days | SMALLINT | 保质期天数 |
| receive_min_shelf_life | SMALLINT | **收货允收期**：剩余保质期 < N 天拒收 |
| ship_min_shelf_life | SMALLINT | **出库禁发期**：剩余保质期 < N 天不允许正常出库（可转折价/报损） |
| is_weighing | BOOLEAN | 是否称重品（散称，需实际重量结算） |
| avg_weight_g / weight_tolerance_pct | NUMERIC | 称重品的单件标重与允差，复核时校验 |
| unit_gross_weight | NUMERIC(12,3) | 毛重 kg/基本单位 |
| unit_volume | NUMERIC(14,6) | 体积 m³/基本单位 |
| hs_code / origin | VARCHAR | 进口/溯源需要 |
| status | VARCHAR(16) | `ACTIVE` / `DISCONTINUED` |

**生鲜 SKU 的三个坑，必须在设计里体现**：

1. **多单位**：采购按"箱"、库存按"KG"、销售按"份"。用 `sku_unit` 表存换算：`{sku_id, uom: CASE, ratio_to_base: 5.000, base_uom: KG, is_pick_uom: true}`。库存永远只存基本单位，展示和录入按作业单位换算，**换算只在入口做一次**。
2. **称重品的数量精度**：`NUMERIC(14,3)`，3 位小数（克）。绝不能用整数。
3. **越库（cross-dock）**：部分生鲜不上架，收货后直接进集货区。用 `sku.cross_dock = true` + 收货时直接生成出库分配，跳过上架。

#### lot 批次

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGINT | |
| sku_id | BIGINT | |
| lot_code | VARCHAR(64) UK(sku) | 供应商批次号或自编码 |
| production_date | TIMESTAMP | 生产日期 |
| expiry_date | TIMESTAMP | 到期日 —— **FEFO 排序键** |
| receive_date | TIMESTAMP | 入库日期 |
| supplier_id | BIGINT | |
| origin_batch | VARCHAR(64) | 溯源上游批次 |
| quality_status | VARCHAR(16) | `QUALIFIED` 合格 / `PENDING` 待检 / `REJECTED` 不合格 / `RELEASED` 让步放行 |
| remaining_life_days | SMALLINT | 冗余字段，定时任务刷新，供临期预警查询走索引 |

批次唯一键：`(sku_id, lot_code, expiry_date)`。同一批次号不同效期视为不同批次（现实中供应商会混）。

### 3.4 库存表（核心）

#### stock 库存主表

```sql
CREATE TABLE stock (
    id              BIGINT       PRIMARY KEY,
    warehouse_id    BIGINT       NOT NULL,
    location_id     BIGINT       NOT NULL,
    sku_id          BIGINT       NOT NULL,
    lot_id          BIGINT       NOT NULL,
    container_id    BIGINT       NOT NULL DEFAULT 0,  -- 0 = 散货无容器（哨兵值，见 §4.1 注）
    uom             VARCHAR(16)  NOT NULL,      -- 恒为 base_uom

    on_hand         NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 在库总量
    allocated       NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 已分配未拣
    reserved        NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 已预占（波次前锁定）
    quality_hold    NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 质检/盘点冻结
    frozen          NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 人工冻结（异常待处理）

    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL,
    updated_at      TIMESTAMP    NOT NULL,

    CONSTRAINT uq_stock_dim UNIQUE (warehouse_id, location_id, sku_id, lot_id, container_id),
    -- 数据库层兜底不变量：即使 Service 写错，也不会出现负数或超占
    CONSTRAINT ck_stock_nonneg CHECK (
        on_hand >= 0 AND allocated >= 0 AND reserved >= 0
        AND quality_hold >= 0 AND frozen >= 0
        AND (allocated + reserved + quality_hold + frozen) <= on_hand
    )
);
```

**四个数量列的语义，这是全系统最需要讲清楚的地方：**

```
可用量 available = on_hand - allocated - reserved - quality_hold - frozen
账面量 book     = on_hand                        （盘点比对基准）
实际可拣量 pickable = on_hand - quality_hold - frozen - allocated   （不含 reserved，波次可抢）
```

- `on_hand`：物理在库量。只有收货、发货、盘盈盘亏、报损会改它。
- `allocated`：已经绑定到具体拣货任务行，等着被拣走。
- `reserved`：被出库单"意向锁定"但还没生成拣货任务。用于防止超卖。
- `quality_hold`：质检或盘点冻结，不能动但算在库。
- `frozen`：人工冻结，异常处理中。

**为什么不冻结库存行（D1 的理由）**：假设 100 个出库单各占 1 个库存行，如果每次占用都插一条"冻结库存"，`stock` 表行数会变成 `库位×SKU×批次×单据` 的量级，盘点时要把它们全部聚合回来才知道"这个库位实际有多少"，聚合成本极高，而且中间态一旦泄漏（单据取消但冻结行没删）就是永久脏数据。用数量列，`stock` 表行数恒等于 `库位×SKU×批次` 的组合数，盘点直接读一行。

**代价**：无法从 `stock` 表反查"这 5 个 KG 被哪个订单占了"。所以引入 `stock_reservation` 表记录占用明细，`allocated/reserved` 两列是它的**物化汇总**，两者必须一致（不变量 I3）。

#### stock_reservation 占用明细

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGINT PK | |
| stock_id | BIGINT | 被占用的库存行 |
| source_type | VARCHAR(24) | `OUTBOUND_LINE` / `WAVE` / `COUNT` / `MANUAL` |
| source_id / source_line_id | BIGINT | |
| quantity | NUMERIC(14,3) | 占用数量 |
| consumed | NUMERIC(14,3) | 已消耗（拣货确认时增加） |
| status | VARCHAR(16) | `RESERVED` / `CONSUMED` / `RELEASED` |
| expires_at | TIMESTAMP | 预占过期时间，超时自动释放（防死锁） |

#### stock_movement 库存流水（不可变，只追加）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGINT PK | |
| biz_no | VARCHAR(64) | 业务单号 |
| biz_type | VARCHAR(24) | `RECEIVE`/`PUTAWAY`/`PICK`/`SHIP`/`MOVE`/`ADJUST`/`COUNT`/`RETURN`/`SCRAP`/`CROSS_DOCK` |
| direction | SMALLINT | `1` 入 / `-1` 出 / `0` 移库 |
| warehouse_id / location_id / sku_id / lot_id | BIGINT | |
| from_location_id | BIGINT NULL | 移库/拣货的来源位 |
| quantity | NUMERIC(14,3) | 恒为正，方向由 `direction` 决定 |
| on_hand_before / on_hand_after | NUMERIC(14,3) | **审计与对账关键字段** |
| operator_id | BIGINT | |
| device | VARCHAR(32) | `WEB` / `PDA-xxx` / `MP` |
| occurred_at | TIMESTAMP | 业务发生时间（≠ 落库时间） |
| idempotency_key | VARCHAR(80) UK | 防重复记账 |
| cost_amount | BIGINT NULL | 成本（分），财务对账用 |

流水表是 WMS 的"区块链"。任何库存争议，以流水为准回放出任意时点的账面。**这张表禁止 UPDATE 和 DELETE**，包括管理员。数据量最大，按月分区（PG）或按月建表（SQLite 侧用归档任务）。

### 3.5 单据表族

WMS 所有单据统一"**单头 + 单行**"结构，共性抽到 `doc_header` 概念（物理上各表独立，字段规范统一），便于：通用审批、通用附件、通用操作日志、通用导出。

| 单据 | 表 | 前缀 | 生命周期 |
|---|---|---|---|
| 采购入库单 | `inbound_order` / `inbound_line` | `ASN` | 预约 → 收货 → 上架 → 完成 |
| 退货入库单 | 同上（`order_type=RETURN`） | `RTN` | |
| 销售出库单 | `outbound_order` / `outbound_line` | `OBT` | 创建 → 分配 → 波次 → 拣货 → 复核 → 发货 |
| 波次 | `wave` | `WV` | 生成 → 释放 → 拣货中 → 完成 |
| 拣货任务 | `pick_task` / `pick_task_line` | `PK` | 待领取 → 执行中 → 完成 / 异常 |
| 复核装箱 | `pack_box` / `pack_box_line` | `BOX` | |
| 发运单 | `shipment` / `shipment_order` | `SHP` | 创建 → 装车 → 在途 → 签收 |
| 移库单 | `move_order` | `MV` | |
| 盘点单 | `count_order` / `count_line` | `CNT` | |
| 库存调整单 | `adjust_order` | `ADJ` | 需审批 |
| 报损单 | `scrap_order` | `SCR` | 需审批 |

#### outbound_order 出库单（字段节选）

| 字段 | 类型 | 说明 |
|---|---|---|
| id / code UK | | `OBT20261015000123` |
| warehouse_id | BIGINT | |
| order_type | VARCHAR(24) | `SALE` / `TRANSFER` 调拨 / `SAMPLE` 样品 / `SCRAP_OUT` |
| source_system | VARCHAR(24) | `MALL` / `ERP` / `MANUAL` / `API` |
| source_order_no | VARCHAR(64) | 外部单号，与 `source_system` 组成**幂等唯一键** |
| customer_id | BIGINT | |
| route_code | VARCHAR(32) | 配送线路 —— 波次聚合的主要维度 |
| required_delivery_date | TIMESTAMP | 要求送达时间 |
| work_date | DATE | 作业日（见 §3.3） |
| cutoff_at | TIMESTAMP | 截单时刻 |
| priority | SMALLINT | 0–9，加急单 |
| temperature_required | VARCHAR(16) | 整单温区要求 |
| status | VARCHAR(24) | 见 §5.2 状态机 |
| total_qty / picked_qty / shipped_qty / short_qty | NUMERIC(14,3) | 冗余汇总，由 Service 维护 |
| total_amount | BIGINT | 分 |
| wave_id | BIGINT NULL | |
| picker_id / checker_id / driver_id | BIGINT NULL | |
| short_ship_policy | VARCHAR(16) | `ALLOW_SHORT` 允许缺发 / `FORBID_SHORT` 整单等齐 / `SPLIT` 拆单 |
| address_snapshot | VARCHAR(512) | 下单时地址快照，不随客户资料变更 |
| remark / tags | VARCHAR | |

`address_snapshot` 是踩过坑才加的字段：客户改了地址，历史单据跟着变，司机按新地址送到空房子。所有"单据上的联系信息"都必须快照。

#### pick_task_line 拣货任务行

| 字段 | 说明 |
|---|---|
| pick_task_id / seq | 任务内序号 = 动线顺序 |
| location_id / sku_id / lot_id | 精确到批次，分拣员不需要思考 |
| plan_qty | 应拣量 |
| actual_qty | 实拣量（扫码/输入确认） |
| uom | 作业单位（箱），`plan_qty_base` 为基本单位 |
| barcode_expected | 期望条码，扫码比对 |
| status | `PENDING` / `DONE` / `SHORT` / `SKIP` / `ABNORMAL` |
| short_reason_code | `STOCK_OUT` / `DAMAGED` / `EXPIRED` / `WRONG_LOC` / `OTHER` |
| scanned_at | 扫码时间，用于人效统计 |

**设计要点**：拣货任务行必须**指定到批次和库位**，不能让分拣员自己找。这是"分配"和"拣货"分离的价值——分配算法（FEFO + 温区 + 动线）在后台算好，前端只给指令。分拣员的操作是"走到 A01-02-03，扫码，拿 3 箱"，没有决策。

---

## 4. 库存核心设计

### 4.1 库存维度与不变量

库存的最小记账维度：`仓库 + 库位 + SKU + 批次 (+ 容器)`。

容器（托盘/周转筐）作为维度而不是属性，是因为生鲜仓的周转筐要回收管理，且整托移动时不想拆散批次行。散货用 `container_id = 0` 这个哨兵值表示"无容器"，**不用 NULL**。

> ⚠ **这里踩过一个坑，值得单独讲。** 最初 `container_id` 设计成可空（"散货直接落库位"），认为 `uq_stock_dim` 能保证"同一维度只有一行库存"。实测发现 **PG 16.15 与 SQLite 3.50.4 都把唯一约束中的 NULL 视为互不相等**，于是同一 `(仓库,库位,SKU,批次)` 可以插入任意多行 `container_id IS NULL` 的库存记录，不变量 I6 完全失效——而散货恰恰是生鲜仓的主要形态。
>
> 两个引擎行为一致，所以这不是"方言差异"，是**建模错误**，靠双库矩阵测试才暴露出来。修法是 0 哨兵值（也可用两库都支持的部分唯一索引，但哨兵值让 `uq_stock_dim` 保持单一约束、查询少一个 `IS NULL` 分支）。同类问题在 `pack_box_line.lot_id` 上复查了一遍，一并改掉。**结论：任何进了 UNIQUE 的列都必须 NOT NULL + 哨兵默认值，这条要加进 §3.1 的规则表。**

**必须始终成立的不变量**（写在 `domain/invariants.py`，每次库存变更后断言，CI 中用 hypothesis 随机操作序列验证）：

```
I1  on_hand >= 0
I2  allocated + reserved + quality_hold + frozen <= on_hand
I3  stock.allocated == SUM(stock_reservation.quantity - consumed)  WHERE status='RESERVED'
I4  SUM(stock.on_hand) WHERE warehouse_id=W  ==  SUM(stock_movement.quantity * direction) WHERE warehouse_id=W
I5  任一 stock_movement 行：on_hand_after == on_hand_before + quantity * direction
I6  同一 (location, sku, lot, container) 只有一行 stock
I7  单据状态 != COMPLETED 时，其占用的 reservation 不能是 CONSUMED 之外且数量归零
```

I4 是**总账对账**，最值钱也最容易被忽略。生产上每天凌晨跑一次全仓 I4 校验，不一致直接告警到群，因为这表示有 bug 或有人绕过系统改了库。

### 4.2 库存操作矩阵

| 操作 | on_hand | allocated | reserved | quality_hold | 生成流水 |
|---|---|---|---|---|---|
| 收货（入暂存位） | +q | 0 | 0 | 0（待检则 hold+q） | `RECEIVE` +q |
| 上架（暂存→存储位） | 目标+q，来源-q | 0 | 0 | 0 | `PUTAWAY` 两条（一移库） |
| 出库单预占 | 0 | 0 | +q | 0 | 无（只写 reservation） |
| 波次分配 | 0 | +q，reserved-q | | 0 | 无 |
| 拣货确认 | -q | -q | 0 | 0 | `PICK` -q |
| 复核 | 0 | 0 | 0 | 0 | 无（只改单据） |
| 发货 | -q（若拣货已扣则 0） | 0 | 0 | 0 | `SHIP`（见 §4.6） |
| 移库 | A-q, B+q | 0 | 0 | 0 | `MOVE` 两条 |
| 盘盈 | +q | 0 | 0 | 0 | `COUNT` +q |
| 盘亏 | -q | 0 | 0 | 0 | `COUNT` -q |
| 报损 | -q | 0 | 0 | 0 | `SCRAP` -q |
| 退货入库 | +q | 0 | 0 | hold+q（待质检） | `RETURN` +q |
| 冻结 | 0 | 0 | 0 | +q | 无（记 `stock_freeze`） |

**关键选择：拣货扣减还是发货扣减？**

设计取"**拣货即扣 `on_hand`，发货只改单据状态**"。理由：拣货完成后货已经离开库位，如果等到发货才扣，中间几小时账面虚高，此时来新单会超卖。发货环节只做 `stock_movement` 的 `SHIP` 记录（`direction=0`，纯事件），用于对账和财务收入确认。

代价：拣货后订单取消，货要"倒回库位"，走 `REVERSE_PICK` 移库回原库位（若原库位已被别的批次占用，则回集货位并标记待归位）。这个代价可接受，取消已拣订单是小概率事件。

### 4.3 并发扣减（D2 的完整论证）

**目标**：多个分拣员同时拣同一库位同一批次、或多个订单同时抢同一批次库存时，不能超卖、不能死锁、不能丢更新，且 **SQLite 和 PG 行为一致**。

**方案：条件更新 + 受影响行数判定，一次一条 SQL 完成扣减。**

```python
class InventoryRepo:
    def try_decrement(self, stock_id: int, qty: Decimal, *, field: str = "on_hand") -> bool:
        """原子扣减。返回 False 表示库存不足，由上层决定重试/缺货。"""
        stmt = (
            update(Stock)
            .where(
                Stock.id == stock_id,
                text(f"{field} >= :qty"),          # 关键：把校验放进 WHERE
            )
            .values(
                **{field: text(f"{field} - :qty")},
                version=Stock.version + 1,
                updated_at=utcnow(),
            )
            .bindparams(qty=float(qty))
        )
        return self.session.execute(stmt).rowcount == 1
```

生成的 SQL 在两个库上都是：

```sql
UPDATE stock SET on_hand = on_hand - :qty, version = version + 1, updated_at = :now
WHERE id = :id AND on_hand >= :qty
```

`rowcount == 0` → 库存不足，走缺货分支。没有 `SELECT FOR UPDATE`，没有版本号重试循环，没有应用层锁。

**为什么它天然正确**：数据库对单行 UPDATE 的加锁和"读-改-写"是原子的，`WHERE on_hand >= :qty` 与 `SET on_hand = on_hand - :qty` 在同一语句内求值，不存在 TOCTOU 窗口。

**必须配套的三条纪律**，否则条件更新也会错：

1. **同一事务内不得先读后写同一行做判断**。允许"读出来展示"，不允许"读出来判断够不够"。判断只能靠 `rowcount`。
2. **多行扣减按 `stock_id` 升序执行**。两个事务以不同顺序扣 A、B 两行会死锁（PG 会报 deadlock detected，SQLite 会 `database is locked`）。排序后不会。
3. **一次事务只锁一个库位组**。拣货任务天然按 `pick_task_id` 划分，同一任务只有一人执行（靠 §4.5 的任务领取保证），冲突面被压到最小。

**SQLite 侧的额外处理**：

```python
# db/base.py —— SQLite 连接建立时
PRAGMA journal_mode = WAL;      -- 读写不互斥，否则一个查询就能阻塞写
PRAGMA busy_timeout = 5000;     -- 撞锁时等 5s 而不是立刻抛错
PRAGMA synchronous = NORMAL;    -- WAL 下安全且快
PRAGMA foreign_keys = ON;
```

WAL 模式下 SQLite 支持"多读一写"。库存扣减是短事务，实测（本机 Windows + Python 3.14.8 + SQLite 3.50.4，`synchronous=NORMAL`）：**单连接串行提交 30,016 TPS**；**8 线程争抢同一行时降到 916 TPS**，且 2,400 次并发提交后 `version` 与扣减总量精确吻合，无丢更新。也就是说单行热点才是 SQLite 的真实瓶颈，不是并发连接数——对策见 §12.2 第 1 条（把量摊到多批次/多库位），而不是换库。一个仓 80 个分拣员分散在几百个库位上，单行争抢远达不到这个强度。写冲突靠 `busy_timeout` + 上层最多 3 次退避重试。

**PG 侧**：默认 `READ COMMITTED` 即可，条件更新在 PG 下会自动对行加锁并在冲突时等待重判，语义完全一致。不需要 `SERIALIZABLE`。

### 4.4 FEFO 分配算法

`domain/fefo.py`，纯函数，无 DB 依赖，可 100% 单测。

```python
def allocate(
    demand: list[DemandLine],        # (sku_id, qty, allow_short, min_expiry_days)
    supply: list[StockSlice],        # (stock_id, location, lot, expiry, available, temp_zone, abc, pickable)
    policy: AllocationPolicy,
) -> AllocationResult:
    ...
```

**排序键（决定先出哪批货）**，按优先级：

1. `quality_status == QUALIFIED` 优先（待检/不合格的不参与自动分配）
2. `expiry_date ASC` —— **FEFO 主键**
3. `production_date ASC` —— 效期相同时先产前出
4. `receive_date ASC`
5. `location.pick_sequence ASC` —— 都相同时先拣近的，减少动线
6. `stock_id ASC` —— 稳定排序，保证结果可复现（测试友好）

**过滤条件**：

- `expiry_date - now >= sku.ship_min_shelf_life`（禁发期）。不满足的批次不分配，除非 `policy.allow_near_expiry` 且操作人显式越权（记 `allocation_override` 审计）。
- `zone.temp_zone` 满足 `sku.temperature_required` 和 `order.temperature_required`。
- `stock.pickable == true`（存储位不直接拣，需先补货）。
- `location.status != LOCKED`（盘点冻结的库位跳过）。

**拣货位优先于存储位**：先消耗 `zone_type == PICK` 的库存，不足再考虑从 STORAGE 补货（生成补货任务，本波次等待或标记缺货）。

**整箱优先拆零**：同一批次既有整托位又有散货位时，若 `demand_qty >= 整箱倍数`，优先从整箱位出，减少拆零工作量。用 `pick_from_case_first` 开关控制。

**输出**：`AllocationResult = list[Allocation(stock_id, qty, reason)] + list[Shortage(sku, qty, cause)]`。`reason` 字段用于前端展示"为什么出了这批"，追溯和客服解释都要用。

**复杂度**：单 SKU 候选批次通常 < 20，全仓一次波次几千行，排序 + 贪心即可，不需要背包算法。**明确不做**"最小化拣货行数"的组合优化——贪心 FEFO 已经够好，优化的收益低于引入 bug 的风险。这是一个能讲的"决定不做什么"。

### 4.5 任务领取与并发（PDA 场景）

分拣端最典型的并发：**两个分拣员同时点"领取任务 A"**。

```sql
UPDATE pick_task
   SET status = 'EXECUTING', assigned_to = :uid, claimed_at = :now, version = version + 1
 WHERE id = :tid AND status = 'PENDING' AND assigned_to IS NULL
```

`rowcount == 1` 才算领取成功，否则提示"任务已被领取"。同一个模式复用在：波次释放、盘点任务领取、装车确认、退货单接收。**统一封装成 `service/claim.py::claim(model, pk, filters, actor)`**，避免每个人各写一遍。

### 4.6 幂等设计

WMS 里"重复提交"是常态：PDA 网络重连、用户狂点按钮、上游重推订单。所有写接口必须幂等，分三层：

**① 接口层幂等（防重复点击/重试）**

```
Header: Idempotency-Key: <client 生成，一次操作一个>
```

```sql
CREATE TABLE idempotency_record (
    idem_key    VARCHAR(80) PRIMARY KEY,
    req_hash    VARCHAR(64) NOT NULL,     -- SHA256(method+path+body)
    response    TEXT        NOT NULL,     -- 缓存的响应体
    status_code INT         NOT NULL,
    created_at  TIMESTAMP   NOT NULL,
    expires_at  TIMESTAMP   NOT NULL
);
-- 唯一索引即锁。插入成功 → 执行业务；冲突 → 比对 req_hash
--   相同：返回缓存 response
--   不同：409 IDEMPOTENCY_KEY_REUSED
```

**② 业务层幂等（防上游重复推单）**

`outbound_order` 上 `UNIQUE(source_system, source_order_no)`。ERP 重推同一订单，第二次插入冲突，直接返回已存在的单号和当前状态，HTTP 200 而不是 409（对上游友好）。

**③ 记账层幂等（防库存重复扣减）**

`stock_movement.idempotency_key UK`，key = `{biz_type}:{biz_no}:{line_no}:{op_seq}`。库存变更与流水插入在同一事务，流水插不进去则整个事务回滚，绝不可能出现"扣了两次库存但只有一条流水"。

**过期清理**：`idempotency_record` 保留 24h，定时任务删除。

### 4.7 单号生成

规则：`{前缀}{yyyyMMdd}{6位序列}`，如 `PK20261015000842`。

**不用**数据库序列表 + 行锁（SQLite 上会成瓶颈，且是全局串行点）。**用** Redis `INCR` + 号段预取：

```python
class NumberingService:
    def next(self, prefix: str, date: str) -> str:
        key = f"seq:{prefix}:{date}"
        # 号段：一次取 100 个在内存里发，Redis 挂掉时降级到 DB 表兜底
        seg = self._local_buffer.get(key)
        if seg is None or seg.exhausted():
            seg = Segment(start=self.redis.incrby(key, 100) - 99, size=100)
            self._local_buffer[key] = seg
        return f"{prefix}{date}{seg.take():06d}"
```

**唯一约束兜底**：所有 `code` 列都有 UK，号段服务异常导致重号时插入失败，捕获后取新号重试 1 次。

**跨日/重启的重复风险**：号段 key 带日期，重启丢失内存号段只浪费号不重号。Redis 持久化关闭也无所谓，因为 `INCRBY` 的 key 若丢失会从 1 重新开始 —— 这是**真实风险**，所以 Redis 必须开 AOF（`appendfsync everysec`），或改用"DB 号段表 + `UPDATE ... SET next = next + 100 WHERE ...` 条件更新取段"。生产取后者，Redis 只做缓存。这个坑值得在面试里主动讲。

### 4.8 库存快照与对账

- **日终快照**：`stock_snapshot_daily(work_date, warehouse_id, sku_id, lot_id, on_hand, allocated, ...)`，每天作业日切换点全量落一份。用途：任意一天可回溯、报表、和 ERP 对账。
- **实时对账任务**：每 5 分钟校验 I3（reservation 汇总 vs allocated 列）和 I5（流水连续性），不一致 → 告警 + 自动定位到 `stock_id`。
- **与 ERP 对账**：每日比对 `SUM(stock.on_hand)` by SKU vs ERP 库存账。差异生成 `recon_diff` 记录，人工处理。**不要试图自动抹平差异**——差异是发现 bug 的唯一信号。

---

## 5. 核心流程与状态机

### 5.1 入库流程

```mermaid
flowchart TD
  A["采购单/预约<br/>(ERP 推送)"] --> B["到货登记<br/>扫采购单/车牌"]
  B --> C{"是否越库<br/>cross_dock?"}
  C -- 是 --> CD["直接进集货位<br/>生成出库分配"]
  C -- 否 --> D["收货称重/计数<br/>录批次·效期·数量"]
  D --> E{"需要质检?"}
  E -- 是 --> F["入待检区<br/>quality_hold += q"]
  F --> G{"质检结论"}
  G -- 不合格 --> H["隔离/退货<br/>SCRAP 或 RTN_OUT"]
  G -- 合格/让步放行 --> I["释放 hold"]
  E -- 否 --> I
  I --> J["上架<br/>系统推荐库位 → 扫码确认"]
  J --> K["入库单完成<br/>回传 ERP"]
  CD --> K
```

**收货环节的生鲜特有校验**（都在 service 层，不在前端）：

| 校验 | 规则 | 失败处理 |
|---|---|---|
| 超收 | `received_qty > ordered_qty * (1 + tolerance)` | 拒绝，需仓经理权限放行 |
| 允收期 | `expiry_date - today >= sku.receive_min_shelf_life` | 拒绝，可让步放行（记录原因 + 审批人） |
| 温度 | 冷藏车到货实测中心温 0–8℃ | 超温 → 整批转待检，不自动入库 |
| 单证 | 供应商批次号、检疫合格证编号（肉禽）必填 | 阻断提交 |

**上架推荐算法**（`service/putaway_service.py`）：

打分排序，取最高分库位：

```
score = w1 * 温区匹配（不匹配 = -∞，直接淘汰）
      + w2 * 同 SKU 同批次聚集度（已有该批次库存的库位加分，减少库位碎片）
      + w3 * 空容量利用率（优先填满已有货的库位，而不是开新位）
      + w4 * ABC 分类匹配（A 类动销品优先拣货位、低层、近通道）
      + w5 * 承重/体积余量
      - w6 * 与在拣任务的冲突（该库位正在拣货则降权）
```

约束硬过滤：`mix_sku == false` 的库位若已有别的 SKU → 淘汰；`max_lots` 已达上限 → 淘汰；重量/体积超载 → 淘汰。

推荐结果给前 3 个候选，分拣员可手动改（改了就记 `putaway_override`，用于事后分析推荐质量）。**这是"系统推荐 + 人工兜底"而不是"强制"**，因为仓内实际情况（临时堆货、通道路障）系统看不到。

### 5.2 出库流程与状态机

```mermaid
stateDiagram-v2
  [*] --> CREATED: 接单/手工创建
  CREATED --> CUTOFF: 到达截单时间
  CUTOFF --> ALLOCATING: 触发分配
  ALLOCATING --> ALLOCATED: 全部分配成功
  ALLOCATING --> SHORT: 可用库存不足
  SHORT --> ALLOCATING: 补货后重分配
  SHORT --> CANCELLED: 客户取消/整单缺货
  ALLOCATED --> WAVED: 加入波次
  WAVED --> PICKING: 波次释放
  PICKING --> PICKED: 全部任务行完成
  PICKED --> CHECKED: 复核装箱通过
  CHECKED --> STAGED: 入集货位
  STAGED --> SHIPPED: 装车发运
  SHIPPED --> DELIVERED: 司机端签收
  DELIVERED --> COMPLETED: 回传 ERP/结算
  PICKING --> SHORT: 现场缺货
  PICKED --> CANCELLED: 发货前取消(需回库)
  COMPLETED --> [*]
  CANCELLED --> [*]
```

**状态机实现**（`domain/state_machines.py`），全系统唯一允许修改 `status` 的地方：

```python
OUTBOUND_TRANSITIONS: dict[str, set[str]] = {
    "CREATED":    {"ALLOCATING", "CANCELLED"},
    "CUTOFF":     {"ALLOCATING", "CANCELLED"},
    "ALLOCATING": {"ALLOCATED", "SHORT", "CANCELLED"},
    "SHORT":      {"ALLOCATING", "CANCELLED"},
    "ALLOCATED":  {"WAVED", "CANCELLED"},
    "WAVED":      {"PICKING", "ALLOCATED"},      # 允许撤波
    "PICKING":    {"PICKED", "SHORT", "CANCELLED"},
    "PICKED":     {"CHECKED", "CANCELLED", "SHORT"},
    "CHECKED":    {"STAGED", "PICKED"},          # 复核不通过退回重拣
    "STAGED":     {"SHIPPED", "CHECKED"},
    "SHIPPED":    {"DELIVERED"},
    "DELIVERED":  {"COMPLETED"},
    "COMPLETED":  set(),                          # 终态，只能红冲
    "CANCELLED":  set(),
}

def transit(doc, to: str, actor: Actor, reason: str | None = None):
    cur = doc.status
    if to not in OUTBOUND_TRANSITIONS[cur]:
        raise IllegalTransition(cur, to, doc.code)
    if to == "CANCELLED" and cur in {"SHIPPED", "COMPLETED"}:
        raise CannotCancelAfterShip(doc.code)
    if to == "CANCELLED" and cur in {"PICKED", "CHECKED", "STAGED"}:
        require_permission(actor, "outbound.cancel_after_pick")
        if not reason: raise ReasonRequired()
    doc.status = to
    doc.status_changed_at = utcnow()
    audit.log(doc, cur, to, actor, reason)
```

**为什么值得单独抽一层**：WMS 的 bug 有相当比例是"状态被非法跳转"——比如已发货的单被改成取消，库存凭空消失。把迁移表集中成一份数据，好处是：① 可以画出完整可达性图做静态检查；② 单元测试穷举所有 `(from, to)` 组合断言合法/非法；③ 新人改代码时无法绕过。

`SHIPPED` 之后不允许取消，只能走红冲（`return_order` 退货入库）。**没有"删除"这个操作**，任何系统里都没有。

### 5.3 波次（Wave）设计

波次是把"一堆订单"变成"一批可高效执行的拣货任务"的过程，是 WMS 效率的核心。

**触发方式**：

1. **定时**：按仓库波次策略（如每 15 分钟扫描一次待波次订单池）。
2. **手动**：仓经理在后台勾选订单点"生成波次"。
3. **阈值**：订单池积压 > N 单 或 最早订单等待 > M 分钟，自动触发并告警。

**聚波维度**（同一波次内必须一致）：

```
warehouse_id  +  work_date  +  temperature_zone  +  route_code  +  carrier
```

- 温区不混：混了分拣员要反复进出冷库，实测损失 20%+ 效率，且有断链风险。
- 线路不混：同一线路的订单拣完直接装车，不需要二次分拨。
- 承运商不混：三方快递要单独交接。

**拣货策略**（`wave.pick_strategy`）：

| 策略 | 适用 | 说明 |
|---|---|---|
| `DISCRETE` 按单拣 | 订单少、SKU 多、易混 | 一人一单，最简单，不易错 |
| `BATCH` 合并拣（**默认**） | 生鲜城配主力 | 同一 SKU 多订单合并总量拣货，到分播墙再按单分 |
| `ZONE` 分区拣 | 大仓 | 每区拣自己那部分，流水集货 |
| `WAVE_AND_SPIT` 波次+分播 | 订单量大 | 合并拣 → 分播墙（播种）→ 按单装箱 |

生鲜城配的典型形态是 **合并拣 + 分播墙**：一辆车 60 家门店，"土豆"这个 SKU 60 单共 800 KG，一次推到拣货位称 800 KG，拉到分播墙按 60 个格口分发。人走的距离从 60 次降到 1 次。

**波次容量约束**：

```
wave.max_order_count      默认 200
wave.max_pick_lines       默认 1500
wave.max_volume_m3        受拣货车辆/暂存区面积限制
wave.split_by_abc         A 类单独成波（快进快出）
```

超限时自动拆波，拆出的子波次 `parent_wave_id` 指向原波，保证"一车一波"的可追溯性。

**波次状态机**：`PLANNED → RELEASED → PICKING → COMPLETED`，加 `HOLD`（异常挂起）和 `CANCELLED`（未释放前可取消）。释放（RELEASE）是幂等点——释放后才生成拣货任务和库存 `allocated`，释放前只是计划，可随意改。

### 5.4 拣货 → 复核 → 装箱 → 发货

```mermaid
sequenceDiagram
  autonumber
  participant P as 分拣端(PDA)
  participant API as WMS API
  participant INV as 库存服务
  participant C as 复核台
  participant D as 司机端

  P->>API: 领取波次任务 (claim)
  API-->>P: 任务行列表(按动线排序) + 库位/批次/数量
  loop 每一行
    P->>API: 扫库位码 → 扫商品码 → 输入/称重数量
    API->>API: 校验库位·条码·效期·允差
    API->>INV: 条件更新扣减 on_hand, allocated
    INV-->>API: stock_movement(PICK, -q)
    API-->>P: OK / SHORT(选原因) / 校验失败
  end
  P->>API: 提交任务完成
  API->>API: 全部行完成 → 出库单 PICKED
  C->>API: 扫周转筐/箱码 → 逐件扫码复核
  API->>C: 应复核清单
  C->>API: 复核通过 + 称重 + 打印箱码
  API->>API: CHECKED → 推荐集货位(按线路)
  D->>API: 扫运单号 → 装车确认(逐箱扫)
  API->>API: STAGED → SHIPPED, 生成交接单
  D->>API: 到达 → 客户签收(扫码/拍照/电子签名)
  API->>API: SHIPPED → DELIVERED → 回传 ERP
```

**分拣端交互设计的硬性要求**（这些细节决定"是不是真做过仓"）：

1. **三步扫码，不许合并**：扫库位 → 扫商品 → 输数量。扫库位是为了防止"在错误库位拣了正确商品"——这种错账最难查，因为库存数对得上，只是两个库位互相串了。
2. **大按钮 + 键盘可输**：PDA 屏幕小、戴手套。主按钮 ≥ 56dp，数量输入支持数字键盘和 +/- 步进。
3. **断网可用**：任务预下载（`GET /picking/tasks?preload=1` 返回完整任务包 + 条码白名单），本地暂存操作，恢复后按序上传，服务端靠 `idempotency_key` 去重。冷库房内经常没信号。
4. **异常优先，不阻断**：缺货时选原因跳过该行，任务继续，缺货部分进 `short_qty` 并触发补货/采购建议。绝不能让一个缺货卡住整波。
5. **误触可撤销**：同一行 30 秒内可"撤销上一次确认"，撤销走反向流水而不是删流水。
6. **语音/震动反馈**：扫对"嘀"，扫错长鸣。戴手套看不清屏幕时靠听觉。

**复核（Check & Pack）**：

- 复核是**最后一道防线**，必须与拣货不同人（§2.2 SoD）。
- 逐件扫码，数量与应发比对。称重品比对重量：`|actual - expected| > avg_weight * tolerance_pct` → 阻断，需人工确认。
- 装箱生成 `pack_box`，箱码唯一，箱内明细落 `pack_box_line`。整单可多箱，箱可挂运单。
- 打印：箱码标签（含二维码，司机端和客户端都能扫）、面单（对接三方快递 API）、随货同行单（生鲜必须有品名、规格、生产日期、保质期、供应商）。
- 复核不通过 → 退回 `PICKED`，重新拣该箱。

**发货（Shipping）**：

- 一个 `shipment` 关联多张出库单、多个箱。
- 装车逐箱扫码，扫齐才允许"发车"。漏件是生鲜投诉的头号来源。
- 电子围栏：司机端"到达"时校验 GPS 与客户地址距离 > 500m 时要求补充说明。
- 签收：客户扫码/签名/拍照，任一即可，全部留存。拒收要选原因（质量/缺货/时间不合），拒收货走退货入库流程。

### 5.5 补货（Replenishment）

拣货位被拣空会导致波次中断，所以补货是独立子系统。

**两种触发**：

1. **波次前预补货**：分配阶段发现 `PICK` 区可用量不足但 `STORAGE` 区有余量 → 生成补货任务，波次 `HOLD` 等补货完成。
2. **安全库存补货**：定时扫描 `pick_location.available < min_level` → 生成补货任务。

**补货量计算**：

```
target_qty = max(min_level, forecast_daily_sales * replenish_cycle_days + safety_stock)
replenish_qty = ceil_to_case(target_qty - current_pick_qty)   -- 按整箱向上取整
```

**补货源库位选择**：优先整箱位 → 效期最早的批次（FEFO，和出库一致）→ 距离最近的存储位。

补货任务复用 `pick_task` 表（`task_type = REPLENISH`），不新建一套任务模型 —— 领取、扫码、确认、流水的逻辑完全一样。**这是"少建一张表"的正确例子**，能讲出复用理由。

### 5.6 盘点

**盘点方式对比与选型**：

| 方式 | 覆盖 | 停工 | 选用 |
|---|---|---|---|
| 全盘（Annual/Periodic Full） | 100% | 高 | 季度/年度，或换系统时 |
| 循环盘点（Cycle Count） | 按 ABC 频次滚动 | 无 | **主力**，A 类月盘、B 类季盘、C 类半年 |
| 动碰盘点（Dynamic） | 有变动的库位 | 无 | 每日盘"昨日有流水的库位"，成本低、抓错快 |
| 抽盘（Sample） | 随机 | 无 | 稽核用 |

**流程**：

```
创建盘点单(范围: 库区/库位/SKU/批次)
  → 冻结范围(库位 status=LOCKED, quality_hold 不动 on_hand)
  → 打印/下发盲盘任务(不显示账面数量 —— 防止"照着账面抄")
  → 实盘录入(支持多次累计: 3+5+2=10)
  → 差异计算(数量差、金额差、批次差)
  → 复盘(差异超阈值的行二次盘点)
  → 审批(超 X 元需仓经理, 超 Y 元需财务)
  → 生成调整单 → 更新 on_hand + 写 COUNT 流水
  → 解冻库位
```

**关键设计点**：

- **冻结不等于停作业**。生鲜仓不能因为盘点就不发货。做法：盘点期间该库位 `status = LOCKED`，新分配跳过它，但已在执行的拣货任务允许完成，盘点数量取"实盘数"，差异计算时**扣除期间流水**：`expected = book_at_start + movements_during_count`。这个公式是盘点模块最容易写错的地方。
- **盲盘（blind count）**：任务里不下发账面数。下发账面数会让盘点形同虚设。
- **批次差异也是差异**：数量对但批次不对（把 10/12 批次的货当成 10/08 拣了），要单独生成 `lot_diff`，因为效期错了比数量错了更严重。
- **盘盈盘亏必须走审批单**（`adjust_order`），不允许盘点单直接改库存。审计要求，也防止操作员自己抹平自己的错。

### 5.7 效期与临期管理

生鲜仓的独有模块，普通 WMS 没有。

**定时任务**（每日 06:00 + 每次出库分配后）：

```sql
-- 刷新冗余列，让预警查询走索引
UPDATE lot l JOIN sku s ON s.id = l.sku_id
   SET remaining_life_days = DATEDIFF(l.expiry_date, CURRENT_DATE)
 WHERE ...
```

**分级与动作**：

| 剩余效期 | 分级 | 自动动作 |
|---|---|---|
| > 2/3 保质期 | 正常 | — |
| 1/3 – 2/3 | 关注 | 波次分配时排在后面（可配置） |
| < `ship_min_shelf_life` | **禁发** | 从 FEFO 候选池剔除，生成"待处理"任务 |
| < 1/3 且 > 0 | 临期 | 推送给运营：折价促销 / 转赠品 / 报损 |
| <= 0 | 过期 | 强制 `quality_hold`，禁止任何出库，生成报损任务 |

**看板**：临期库存金额 TOP N、按 SKU/供应商聚合的临期分布、过期损失趋势。这是老板真正会看的报表。

### 5.8 退货与异常处理

**退货入库**：司机端发起（客户拒收）或商城端发起（客户申请）→ 生成 `RTN` 入库单 → 收货 → **强制质检**（生鲜退货大部分直接报损，能二次销售的很少）→ 合格转 `QUALIFIED` 入库，不合格 `SCRAP`。

**异常类型清单**（做成字典表 `exception_code`，不要硬编码）：

```
SHORT_STOCK      库存不足/实物少
DAMAGED          破损
EXPIRED          过期/临期不可发
WRONG_LOC        库位无货（账实不符）
WRONG_SKU        串货
WEIGHT_OVER      超重
WEIGHT_UNDER     欠重
CUSTOMER_REJECT  客户拒收
TEMP_BREACH      温控异常
```

每个异常码绑定：**处理动作**（是否自动补货、是否通知采购、是否生成调整单）+ **责任归属**（仓库/供应商/承运商/客户）+ **升级路径**。异常必须闭环，超时未处理自动升级到仓经理。

---

## 6. API 设计

### 6.1 通用约定

**Base**：`/api/v1`，版本放路径（不放 Header，便于网关和日志区分）。

**认证**：`Authorization: Bearer <JWT>`。JWT 载荷：`{sub: user_id, wid: warehouse_id, ct: client_type, exp, jti}`。`jti` 支持主动吊销（Redis 黑名单，TTL = token 剩余时间）。

**多租户/多仓**：`X-Warehouse-Id` Header 可覆盖当前仓库上下文，但服务端必须校验该用户对该仓库有权限 —— **绝不信任前端传来的 warehouse_id**，越权访问是后台系统最常见的安全漏洞。

**统一响应体**：

```json
{
  "code": "0",
  "message": "ok",
  "trace_id": "b7c3...",
  "data": { },
  "server_time": "2026-10-15T02:13:44Z"
}
```

失败：

```json
{
  "code": "WMS-40902",
  "message": "库存不足，无法完成拣货确认",
  "trace_id": "b7c3...",
  "data": null,
  "detail": { "stock_id": 8812, "available": "2.500", "required": "3.000" }
}
```

**HTTP 状态码与业务码并用**：状态码表达类别（400/401/403/404/409/422/500），业务码表达具体原因（前端按码做交互，如 40902 弹"是否发起补货"）。**不要全部返回 200**，网关监控和重试策略会失效。

**分页**：

```
GET /outbound-orders?page=1&size=50&sort=-required_delivery_date,code
→ data: { items: [...], page: 1, size: 50, total: 1284, has_more: true }
```

深分页（`page > 1000`）强制改游标：`?cursor=<last_id>&size=50`。后台导出走异步任务，不占用同步接口。

**字段与命名**：JSON 用 `snake_case`（与 Python 一致，避免 camel/snake 转换层带来的 bug 和性能损耗）；时间是 ISO8601 UTC 带 `Z`；数量是**字符串**（`"12.500"`）避免 JS Number 精度问题，前端展示时再解析；金额是整数分。

> 数量用字符串是个会被质疑的点，理由要讲清：JS 的 `Number.MAX_SAFE_INTEGER` 是 2^53，`NUMERIC(14,3)` 转成"厘"整数最大 10^17，超过安全范围；且 `0.1 + 0.2 !== 0.3` 在前端做汇总会重现同样的问题。让前端用 `decimal.js` 或直接字符串展示，比后端悄悄丢精度好。

**错误码分段**：

| 段 | 含义 | 例 |
|---|---|---|
| `0` | 成功 | |
| `WMS-1xxxx` | 通用/参数 | 10001 参数校验失败，10002 幂等键冲突 |
| `WMS-2xxxx` | 认证与权限 | 20001 未登录，20003 无该仓库权限 |
| `WMS-3xxxx` | 单据与状态 | 30004 非法状态迁移，30010 单据已锁定 |
| `WMS-4xxxx` | 库存 | 40901 库存不存在，40902 库存不足，40903 批次效期不符 |
| `WMS-5xxxx` | 作业 | 50001 任务已被领取，50002 条码不匹配，50003 复核数量不符 |
| `WMS-6xxxx` | 主数据 | 60001 SKU 不存在，60002 库位容量不足 |
| `WMS-7xxxx` | 集成 | 70001 ERP 推送失败，70002 面单获取失败 |
| `WMS-9xxxx` | 系统 | 90001 内部错误，90002 依赖服务不可用 |

错误码是常量，集中定义在 `common/errors.py`，一个码只出现一次（CI 检查重复）。

**幂等**：所有 `POST` 要求 `Idempotency-Key`（除登录类）。`PUT` 天然幂等。`PATCH` 带 `version` 做乐观锁。

### 6.2 接口清单（节选，完整 120+ 个）

**认证与上下文**

```
POST   /auth/login                        账号密码登录
POST   /auth/mp-login                     小程序 code 换 token
POST   /auth/refresh
GET    /auth/me                           用户信息 + 权限点 + 可访问仓库
GET    /auth/warehouses                   切换仓库列表
```

**主数据**

```
GET    /skus            ?keyword=&category_id=&status=&page=
POST   /skus            PUT /skus/{id}   DELETE /skus/{id}   (软删)
GET    /skus/{id}
POST   /skus/import     批量导入（异步任务，返回 task_id）
GET    /warehouses /zones /locations
POST   /locations/batch-create            按"区-排-层"规则批量生成库位
GET    /locations/recommend?sku_id=&qty=  上架推荐（供 PDA 调用）
```

**入库**

```
GET    /inbound-orders                    ?type=&status=&supplier=&work_date=&page=
POST   /inbound-orders                    手工创建（ASN 由 ERP 推送）
GET    /inbound-orders/{code}
POST   /inbound-orders/{code}/receive     收货确认（PDA）
POST   /inbound-orders/{code}/putaway     上架确认（PDA）
POST   /inbound-orders/{code}/close       关单（允许少收）
POST   /inbound-orders/{code}/cancel
```

**库存**

```
GET    /inventory                         库存查询（多维度聚合）
GET    /inventory/movements               流水查询
GET    /inventory/reservations            占用明细
GET    /inventory/summary                 看板汇总（总量/临期/冻结/缺货 SKU 数）
GET    /inventory/expiry-alert            效期预警列表
POST   /inventory/move                    移库
POST   /inventory/freeze  /unfreeze       冻结/解冻
GET    /inventory/recon                   对账差异
```

**出库与作业**

```
GET    /outbound-orders / POST /outbound-orders / GET /outbound-orders/{code}
POST   /outbound-orders/{code}/cancel
POST   /outbound-orders/allocate          批量分配（同步，小批量）
POST   /waves                             生成波次（传 order_codes 或 filter）
POST   /waves/{id}/release                释放 → 生成拣货任务
POST   /waves/{id}/hold | /resume | /cancel
GET    /picking/tasks?mine=1&status=PENDING
POST   /picking/tasks/{id}/claim          领取（条件更新，防抢）
POST   /picking/tasks/{id}/lines/{seq}/confirm   扫码确认
POST   /picking/tasks/{id}/lines/{seq}/short     报缺（带原因）
POST   /picking/tasks/{id}/lines/{seq}/undo      撤销
POST   /picking/tasks/{id}/complete
POST   /checking/scan                     复核扫码
POST   /checking/pack                     装箱 + 打印
GET    /checking/pending-boxes
POST   /shipments                         创建运单
POST   /shipments/{code}/load             装车扫码
POST   /shipments/{code}/depart | /deliver | /reject
GET    /shipments/{code}/manifest         随货同行单 PDF
```

**盘点与调整**

```
POST   /counts                            创建盘点单（范围）
GET    /counts/{code}/tasks?mine=1        盲盘任务
POST   /counts/{code}/lines/{id}/submit   实盘提交
POST   /counts/{code}/recalculate         差异计算（含期间流水扣除）
POST   /counts/{code}/approve             审批 → 生成调整单
POST   /adjusts | /scraps                 调整/报损（需审批）
```

**集成与管理**

```
POST   /integrations/erp/orders           ERP 推单（签名校验 + 幂等）
POST   /integrations/erp/inbound          ERP 推采购单
POST   /integrations/webhook/subscriptions
GET    /admin/users /roles /permissions /audit-logs /dicts /jobs
GET    /reports/pick-performance          人效
GET    /reports/inventory-aging           库龄
GET    /reports/short-analysis            缺货归因
```

### 6.3 关键接口契约示例

**`POST /picking/tasks/{id}/lines/{seq}/confirm`**

Request：

```json
{
  "scanned_location_code": "A01-02-03",
  "scanned_barcode": "6901234567890",
  "confirmed_qty": "3.000",
  "uom": "CASE",
  "lot_code": "LOT20261012-SH",
  "device": "PDA-07",
  "client_time": "2026-10-15T02:13:41Z"
}
```

Response 200：

```json
{
  "code": "0",
  "data": {
    "line_status": "DONE",
    "remaining_lines": 4,
    "next_line": {
      "seq": 5, "location_code": "A01-03-01", "sku_name": "山东红富士 80#",
      "plan_qty": "2.000", "uom": "CASE", "lot_code": "LOT20261010-SH",
      "expiry_date": "2026-10-25", "barcode_expected": "6901234567890"
    },
    "task_status": "EXECUTING"
  }
}
```

**服务端校验顺序**（顺序本身就是设计，先便宜的后贵的）：

1. 任务归属校验：`assigned_to == current_user` → 否则 `WMS-50001`
2. 行状态校验：`status == PENDING` → 否则幂等返回已处理结果
3. 库位码比对：`scanned_location_code == task_line.location.code` → 否则 `WMS-50002`（防串位）
4. 条码比对：查 `sku_barcode` 白名单 → 否则 `WMS-50002`
5. 批次比对：若 PDA 传了 `lot_code`，必须等于分配批次 → 否则 `WMS-40903`
6. 单位换算：`confirmed_qty * ratio_to_base = qty_base`
7. 效期校验：`expiry_date - today >= sku.ship_min_shelf_life`，越权需 `picking.override_expiry` 权限
8. 库存扣减：条件更新 → `rowcount == 0` 则 `WMS-40902`
9. 写流水 + 更新行状态 + 更新任务/单据汇总，**同一事务**
10. 事务提交后异步：若任务全部完成，推进单据状态；若触发拣货位低水位，投递补货任务

**响应里直接带 `next_line`** —— 这是一个小的但很实用的设计：PDA 不需要再发一次"取下一行"请求，弱网下少一次往返，且保证"展示的下一行"和"服务端认为的下一行"绝对一致。

### 6.4 权限模型

**RBAC + 数据权限**，两张核心关系：

```
user ──< user_role >── role ──< role_permission >── permission(权限点)
user ──< user_warehouse >── warehouse     (数据权限：能操作哪些仓)
role ──< role_data_scope >── {ALL | WAREHOUSE | ZONE | SELF}
```

**权限点命名**：`{模块}.{资源}.{动作}`，如 `outbound.order.cancel_after_pick`、`inventory.adjust.approve`。全量权限点定义在代码里（枚举），**不允许在界面上自由新增权限点**——权限点必须是代码里真实校验过的，否则会出现"有权限但没实现"的假象。

**三层校验，缺一不可**：

| 层 | 手段 | 防什么 |
|---|---|---|
| 前端 | 路由守卫 + `v-permission` 指令隐藏按钮 | 防误操作（**不是安全边界**） |
| 接口 | FastAPI `Depends(require_perm("..."))` | 真正的安全边界 |
| 数据 | 查询强制注入 `warehouse_id IN (user.warehouses)` | 防越权访问他仓数据 |

数据权限用 SQLAlchemy `do_orm_execute` 事件全局注入，**不靠每个查询手写 where**。这是防漏的关键设计：漏写一个 where 就是数据泄露，而全局过滤器让"忘记"变得不可能。例外情况（管理员跨仓查询）显式 `with_loader_criteria(..., opts={"skip_wd": True})` 并记审计日志。

**超级管理员不能做业务操作**（§2.2）。权限点上把"配置权限"和"改账权限"分开授予，避免一个账号既能改库存配置又能直接调账。

---

## 7. 集成设计

### 7.1 集成全景

```
┌─────────┐  订单/采购单推送   ┌──────────┐
│   ERP   │ ────────────────▶ │          │
└─────────                    │          │  回传：入库完成/发货完成/签收
┌─────────┐  下单/取消         │   WMS    │──────────────▶ ERP
│  商城   │ ────────────────▶ │  中台    │
└─────────┘                    │          │  回传：库存快照（每分钟）
┌─────────┐  面单获取/轨迹     │          │──────────────▶ 商城
│ 快递/承运│ ◀────────────────▶│          │
└─────────┘                    │          │  回传：作业量/温控记录
┌─────────┐  小票/标签打印     │          │──────────────▶ 财务
│  硬件    │ ◀────────────────▶│          │
└─────────┘  PDA扫码/电子秤    └──────────
```

### 7.2 入站（外部 → WMS）

**统一入口**：`POST /api/v1/integrations/{source}/{biz_type}`

**安全**：HMAC-SHA256 签名。

```
X-Api-Key: <接入方标识>
X-Timestamp: 1760000000            # 与服务端时差 > 300s 拒绝（防重放）
X-Signature: base64(HMAC_SHA256(secret, method + "\n" + path + "\n" + timestamp + "\n" + sha256(body)))
```

签名校验在中间件完成，失败直接 401，不进业务逻辑。`X-Api-Key` 与 `secret` 存 `api_credential` 表，secret 加密存储（AES-GCM，密钥来自环境变量/KMS）。

**可靠性**：入站消息先落 `inbound_message` 表（原始报文 + 状态），再异步消费处理。好处：① 上游只需拿到 202 即可，不被 WMS 的处理耗时拖住；② 报文留档，扯皮时可回放；③ 处理失败可重放，不用求上游重推。

```sql
CREATE TABLE inbound_message (
  id BIGINT PK, source VARCHAR(24), biz_type VARCHAR(32),
  external_no VARCHAR(64), payload TEXT, payload_sha VARCHAR(64),
  status VARCHAR(16),   -- RECEIVED / PROCESSING / DONE / FAILED / DEAD
  retry_count SMALLINT, next_retry_at TIMESTAMP,
  error TEXT, received_at TIMESTAMP, processed_at TIMESTAMP,
  CONSTRAINT uq_inbound UNIQUE (source, biz_type, external_no)
);
```

`uq_inbound` 就是 §4.6 的业务层幂等键。

### 7.3 出站（WMS → 外部）

**Outbox 模式**，绝不在业务事务里直接调外部 HTTP。

```
业务事务:  UPDATE 单据状态 + INSERT outbox_event(同一事务)
异步 worker: 轮询 outbox_event (status=PENDING) → 调用外部 → 标记 SENT / FAILED
```

为什么用 outbox 而不是消息队列：Redis/MQ 和数据库不是同一事务，"库存扣了但消息没发出去"或"消息发了但事务回滚了"这两个窗口无法消除。outbox 把事件写入和业务写入绑在同一个数据库事务里，**至少一次投递**由数据库保证，消费端靠幂等去重。起步阶段不需要引入 Kafka，一张表 + 一个 worker 足够，日后可平滑替换。

```sql
CREATE TABLE outbox_event (
  id BIGINT PK, topic VARCHAR(64), biz_key VARCHAR(64),
  payload TEXT, headers TEXT,
  status VARCHAR(16),   -- PENDING / SENDING / SENT / FAILED / DEAD
  retry_count SMALLINT DEFAULT 0, next_retry_at TIMESTAMP,
  last_error VARCHAR(512), created_at TIMESTAMP, sent_at TIMESTAMP
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
```

**重试策略**：指数退避 `1m, 5m, 15m, 1h, 6h, 24h`，超过 6 次转 `DEAD`，进死信列表，后台提供"重放"按钮（人工判断上游是否恢复）。**并发上限**：同一 `biz_key` 串行发送（按 id 顺序，前一条未 SENT 不发后一条），保证 ERP 收到的事件顺序正确 —— 乱序的"发货完成"晚于"签收"会让上游状态机错乱。

**死信处理**是运维的日常工作，所以后台必须有"集成监控"页面：待发送数、失败数、最老未发送事件年龄、按 topic 分组。**"最老事件年龄 > 10 分钟"是必配告警**。

### 7.4 硬件与外部服务

| 设备/服务 | 接入方式 | 要点 |
|---|---|---|
| PDA 扫码 | WebView 监听键盘输入（扫码枪模拟键盘） | 扫码枪后缀回车；H5 需处理"输入框焦点丢失" |
| 电子秤 | 蓝牙（Web Bluetooth / JSBridge）或串口服务器转 TCP | 读数不稳定，需"稳定 3 秒后取值"逻辑；去皮/清零 |
| 标签打印机 | 蓝牙 ESC/POS 或云打印 API | 模板存后台，支持变量；打印失败可重打并记录重打次数 |
| 面单 | 快递鸟/菜鸟/顺丰 API | 获取失败降级为手工填写，不阻断发货 |
| 温控 | IoT 平台 webhook 或温湿度记录仪批量上传 | 断链超 30 分钟告警；温度数据挂到 shipment 上做证据 |
| 微信 | 小程序登录 `code2session`、订阅消息（司机到达通知） | access_token 集中管理，Redis 缓存，提前 5 分钟刷新 |
| 短信 | 阿里云/腾讯云 | 验证码限流：同手机号 60s 一次，同 IP 每小时 20 次 |

---

## 8. 管理后台前端设计

### 8.1 技术栈与结构

Vue 3 + TypeScript + Vite + Element Plus + Pinia + Vue Router。

```
web/src/
├── api/                  # 由 OpenAPI 自动生成的 TS 客户端 + 手写补充
│   ├── generated/        # openapi-typescript-codegen 产物，不手改
│   └── index.ts
├── components/
│   ├── ProTable/         # 列表页通用组件（核心抽象）
│   ├── ProForm/          # 表单通用组件
│   ├── DictSelect/       # 字典下拉
│   ├── SkuPicker/        # 商品选择器（弹窗 + 搜索 + 多选）
│   ├── LocationPicker/   # 库位选择器
│   ├── WarehouseSwitcher/
│   ├── AmountText/  QuantityText/  DateTimeText/   # 格式化展示
│   └── PermissionButton/ # v-permission 指令 + 组件双支持
├── composables/
│   ├── useTable.ts       # 查询/分页/排序/列设置/导出
│   ├── useDict.ts        # 字典缓存
│   ├── usePermission.ts
│   └── useWarehouse.ts   # 当前仓库上下文
├── views/
│   ├── master/  inbound/  inventory/  outbound/  wave/
│   ├── picking/ count/  report/  integration/  system/
├── stores/  router/  utils/  styles/
└── main.ts
```

**为什么从 OpenAPI 生成 TS 客户端**：FastAPI 自带 `/openapi.json`，用 `openapi-typescript` 生成类型后，**后端改字段前端立刻编译报错**。这消灭了前后端联调最常见的一类 bug（字段名/类型不一致），比任何"接口文档维护规范"都有效。CI 里加一步：`npm run gen:api && git diff --exit-code src/api/generated`，提醒开发者重新生成并提交。

### 8.2 列表页抽象（ProTable）

WMS 后台 80% 的页面是"筛选 + 表格 + 行操作 + 批量操作 + 导出"。抽象成一个组件，业务页面只写配置：

```ts
const columns: ColumnDef<OutboundOrder>[] = [
  { prop: 'code', label: '单号', width: 180, copyable: true,
    render: (v, row) => h(RouterLink, { to: `/outbound/${v}` }, () => v) },
  { prop: 'customer_name', label: '客户', minWidth: 160, ellipsis: true },
  { prop: 'status', label: '状态', width: 110,
    dict: 'OUTBOUND_STATUS',          // 自动渲染彩色 Tag
    filterable: true },
  { prop: 'total_qty', label: '总数量', width: 110, align: 'right',
    formatter: formatQty },
  { prop: 'required_delivery_date', label: '要求送达', width: 160,
    formatter: formatDateTime, sortable: 'custom' },
  { prop: 'short_qty', label: '缺发', width: 90, align: 'right',
    formatter: (v) => v > 0 ? h('span', { class: 'text-danger' }, formatQty(v)) : '—' },
  { type: 'actions', actions: [
      { label: '详情', perm: 'outbound.order.view' },
      { label: '取消', perm: 'outbound.order.cancel',
        show: (row) => ['CREATED','ALLOCATED'].includes(row.status),
        confirm: '取消后不可恢复，确认？' },
  ]},
]
```

**必须内建的能力**（这些是"独立完成后台"的真实门槛）：

| 能力 | 说明 |
|---|---|
| 查询条件持久化 | 存 URL query，刷新/分享/回退不丢条件。WMS 运营天天在几个筛选间来回跳 |
| 列设置 | 用户自选显示列 + 宽度，存 localStorage（后端可存偏好表） |
| 多排序 | `sort=-a,b`，出库单常按"送达时间升 + 优先级降" |
| 批量操作 | 跨页选择（保留选中集）、批量取消/加入波次/导出，操作前二次确认 + 结果明细（成功 48 失败 2，失败原因可下载） |
| 异步导出 | 大数据量走后端任务，前端轮询 + 下载中心，不阻塞页面 |
| 空态/加载/错误三态 | 错误态必须带"重试"按钮和 `trace_id`（客服排障时用户能直接报出） |
| 防重复提交 | 按钮 loading + 禁用，且带 `Idempotency-Key`（前端生成 uuid，重试沿用同一个） |
| 数字/金额/时间格式化 | 统一在 `utils/format.ts`，禁止页面里手写 `toFixed` |
| 权限渲染 | 无权限的按钮不渲染（不是禁用），无权限的路由不进菜单 |

### 8.3 状态与实时性

- Pinia store 只放**跨页面共享且变化慢**的东西：用户信息、权限点、字典、当前仓库。列表数据不进 store（每次进页面重新拉，避免脏数据）。
- 看板类页面用轮询（30s）而不是 WebSocket，简单且够用。作业监控页可上 SSE。
- 字典统一缓存 + 版本号失效（`/dicts?since=<version>`）。

### 8.4 关键页面清单

| 模块 | 页面 | 复杂度要点 |
|---|---|---|
| 作业看板 | 首页驾驶舱 | 今日待拣/拣货中/待发/已发漏斗、缺货 TOP、人效、异常 |
| 入库 | 入库单列表/详情、收货记录、上架追踪 | 详情要显示"计划-已收-已上架"三段进度 |
| 库存 | 库存查询、流水查询、占用查询、效期预警、库龄分析 | 库存查询要支持"按 SKU 汇总 / 按库位明细"两种视图切换 |
| 出库 | 订单列表/详情、订单池、波次管理、拣货任务、复核记录 | 波次管理需要拖拽调单（把订单在波次间移动） |
| 盘点 | 盘点计划、盘点单、差异处理、调整审批 | 差异行支持"仅看差异"筛选 |
| 主数据 | SKU、库位（含批量生成）、仓库、供应商、客户 | 库位批量生成要有预览 |
| 集成 | 接口日志（入站/出站）、死信重放、凭证管理 | 报文原文可展开、可复制、可重放 |
| 系统 | 用户、角色、权限树、操作审计、任务调度 | 审计日志必须能按 trace_id 串起来 |
| 报表 | 人效、缺货归因、损耗、供应商履约、周转率 | |

---

## 9. 多端设计

### 9.1 统一策略（D10）

三端共用 §6 的 API，差异通过三个机制处理，**不复制接口**：

1. **`client_type`**（JWT 声明）：`WEB` / `PDA` / `MP_DRIVER` / `H5_MALL`。服务端据此裁剪响应（如 PDA 只要必要字段，减小报文）和记录 `device` 到流水。
2. **功能开关**：`/auth/me` 返回该端的 `features` 字典，前端按开关注册路由。
3. **接口版本 + 端版本兼容**：小程序有审核延迟和老版本残留，服务端**必须向后兼容至少 2 个客户端版本**。做法：只加字段不删字段、不改变已有字段语义；确需破坏性变更时新增接口并给老接口设下线日期，通过 `/auth/me` 返回的 `min_client_version` 强制升级弹窗。

### 9.2 分拣端（PDA / H5）

**技术**：Vue 3 + Vant，打包成 H5 部署，PDA 用 WebView 壳（或直接用 PDA 自带浏览器）。壳提供：蓝牙打印、电子秤、扫码广播、离线存储、开机自启。

**核心设计：离线优先。**

```
领取任务 → 任务包全量下载到 IndexedDB（含库位/条码/批次白名单）
   ↓
现场作业 → 每次确认先写本地 outbox（带 uuid 幂等键），UI 立即反馈
   ↓
网络可用 → 后台按序上传，服务端逐条幂等处理
   ↓
冲突（库存不足/任务被撤销）→ 服务端返回该条失败，UI 标红并提示人工处理
```

**为什么本地先写**：冷库和仓库深处经常没信号。如果每次扫码都要等网络，作业效率直接腰斩，且分拣员会重复点。本地队列 + 幂等键让"离线 30 分钟"变成可接受的正常状态。

**风险与对策**：离线意味着"本地认为拣到了，服务端可能扣不了"。所以：① 上传冲突时**绝不静默丢弃**，必须让分拣员看到红条并现场处理（找货或报缺）；② 任务领取时服务端做一次"预扣"（`allocated += 任务量`），把冲突概率压到很低；③ 离线超过 2 小时未上传，任务自动回收并告警。

**交互细节**：单手可操作（底部大按钮）、字号 ≥ 16sp、高对比度（仓库光线差）、扫码结果即时语音播报、错误用长震动而非弹窗（不打断节奏）。

### 9.3 司机端（微信小程序）

**功能**：接单 → 装车核对（扫箱码）→ 导航 → 到店签收（扫码/签名/拍照）→ 异常登记（拒收/缺货）→ 回单上传 → 交接班（周转筐/冷藏箱回收数）。

**要点**：

- **签收**：三种方式并存 —— 客户扫箱码自助签收、司机代签（拍照 + 手写签名 canvas）、拒收（选原因 + 拍照）。签名图片上传后转 OSS/MinIO，单据上只存 key。
- **定位**：`wx.getLocation` 只在"到达""离开"两个动作时取，不做持续上报（省电、隐私合规、审核友好）。持续轨迹需要司机显式开启"行程记录"。
- **离线**：司机在地库/山区。运单和线路任务预下载，签收结果本地暂存 + 补传。
- **周转筐回收**：生鲜配送的隐性成本，司机端有独立的"筐/箱交接"记录，与库存的 `container` 维度呼应。
- **订阅消息**：新任务、超时未签收提醒。

### 9.4 商城端（H5 + 小程序，uni-app/Taro）

商城端不是 WMS 的一部分，但它是订单来源，接口契约必须定清楚。

**与 WMS 的交互**：

```
商城 → WMS：下单（带 SKU、数量、要求送达时间、地址、客户）
WMS → 商城：库存可售量查询（下单前校验，防止超卖）
WMS → 商城：订单状态变更事件（已分配/已拣/已发/已签收/缺发）
WMS → 商城：缺发通知（触发退款/补发流程）
```

**可售库存 vs 账面库存**：商城看到的可售量 = `on_hand - allocated - reserved - quality_hold - frozen - 未下发订单占用`，且要减去**安全水位**（生鲜不能卖到零，留 5% 应对现场损耗）。可售量每分钟由定时任务算好写入 `sku_sellable_stock` 表 + Redis，商城查询走缓存，**绝不让商城实时查 WMS 主表**（一个秒杀/团购活动就能把 WMS 数据库打穿）。

**下单时间 → 作业日映射**：客户在商城选"10 月 16 日送达"，WMS 侧生成 `work_date = 10-16`、`cutoff_at = 10-15 20:00` 的出库单。15 日 20:00 后下的单，自动顺延到下一个作业日，并回写商城"预计送达时间已变更"。**这个顺延逻辑必须在 WMS 侧算**，因为只有 WMS 知道仓库的截单时间和产能。

---

## 10. 部署与运维

### 10.1 本地一键起（面试演示用）

`docker-compose.yml`：

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: wms
      POSTGRES_USER: wms
      POSTGRES_PASSWORD: wms_dev_pwd
    ports: ["5432:5432"]
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U wms -d wms"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--appendonly", "yes"]   # 号段服务需要持久化，见 §4.7
    ports: ["6379:6379"]
    volumes: [redisdata:/data]

  api:
    build: { context: ., dockerfile: Dockerfile, target: runtime }
    env_file: .env.dev
    environment:
      WMS_DB__DIALECT: postgres
      WMS_DB__DSN: postgresql+psycopg://wms:wms_dev_pwd@postgres:5432/wms
      WMS_REDIS__URL: redis://redis:6379/0
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_started }
    ports: ["8000:8000"]
    command: >
      sh -c "alembic upgrade head &&
             python -m wms.jobs.seed --profile demo &&
             uvicorn wms.main:app --host 0.0.0.0 --port 8000"

  worker:
    build: { context: ., dockerfile: Dockerfile, target: runtime }
    env_file: .env.dev
    command: celery -A wms.jobs.celery_app worker -l info -Q default,push
    depends_on: [api, redis]

  web:
    build: { context: ./web, dockerfile: Dockerfile }
    ports: ["5173:80"]
    depends_on: [api]

volumes: { pgdata: {}, redisdata: {} }
```

SQLite 模式（无 Docker 依赖，演示"边缘部署"）：

```bash
WMS_DB__DIALECT=sqlite WMS_DB__DSN="sqlite:///./wms.db" alembic upgrade head
WMS_DB__DIALECT=sqlite uvicorn wms.main:app --reload
```

同一套迁移在两个方言上都能 `upgrade head` 成功，是 §3.1 那十条规则的可验证证明 —— **这条要写进 CI**：`pytest --db=sqlite` 和 `pytest --db=postgres` 跑同一套集成测试。

### 10.2 Dockerfile（多阶段）

```dockerfile
FROM python:3.12-slim AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
COPY pyproject.toml poetry.lock ./
RUN pip install "poetry==1.8.3" && poetry export -f requirements.txt -o req.txt \
 && pip install -r req.txt --target /install

FROM python:3.12-slim AS runtime
RUN groupadd -r app && useradd -r -g app app
WORKDIR /app
COPY --from=builder /install /usr/local/lib/python3.12/site-packages
COPY src/ ./src/
COPY alembic.ini alembic/ ./
ENV PYTHONPATH=/app/src PYTHONUNBUFFERED=1
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"
ENTRYPOINT ["uvicorn", "wms.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

要点：非 root 运行、多阶段（镜像从 ~900MB 降到 ~180MB）、`HEALTHCHECK` 供编排判断、依赖层与代码层分离（改代码不重装依赖）。

### 10.3 环境规划

| 环境 | 数据库 | 用途 | 数据 |
|---|---|---|---|
| local | SQLite | 开发 | 种子数据 |
| ci | SQLite + PG 矩阵 | 自动化测试 | 工厂生成 |
| staging | PostgreSQL 单实例 | 联调、验收 | 生产脱敏副本 |
| prod | PostgreSQL 主 + 流复制备 | 生产 | 真实 |

### 10.4 生产拓扑（单仓起步）

```
                    ┌────────────┐
   用户/三端 ──────▶│  Nginx/SLB │  TLS 终止、限流、静态资源
                    └─────┬──────┘
              ┌───────────┼───────────┐
        ┌─────▼─────┐ ┌───▼────┐ ────▼─────┐
        │ api ×2    │ │ web    │ │ worker ×2│
        │ (uvicorn) │ │ (静态) │ │ celery   │
        └─────┬─────┘ └────────┘ └────┬─────┘
              │                       │
        ┌─────▼──────────┐      ┌─────▼─────┐
        │ PG 主 ──▶ 流复制备│      │ Redis(AOF)│
        └────────────────┘      └───────────┘
```

**为什么 API 要 2 个实例**：滚动发布不中断；单实例崩溃时 PDA 不会全停。注意 §4.5 的号段服务和任务领取都设计成多实例安全的，所以扩容不需要改代码。

**规模演进**：单仓 → 多仓时，`warehouse_id` 已经是所有表的第一个维度，加一层"仓 → 数据库实例"的路由即可（分库不做分表）。当单仓日订单 > 5 万，`stock_movement` 按月分区，查询走 PG 分区裁剪。

### 10.5 配置与密钥

`pydantic-settings`，环境变量前缀 `WMS_`，嵌套用 `__`：

```
WMS_DB__DIALECT=postgres
WMS_DB__POOL_SIZE=10
WMS_SECURITY__JWT_SECRET=<从 KMS/Secrets Manager 注入，不进 git>
WMS_FEATURE__ALLOW_EXPIRY_OVERRIDE=false
```

`.env` 不入库，仓库里放 `.env.example`。CI 检查：`git grep -I -E "(secret|password|token)\s*=\s*['\"][^'\"]{8,}"` 命中即失败（防误提交）。

### 10.6 备份与恢复

| 项 | 策略 | RPO | RTO |
|---|---|---|---|
| PG 全量 | `pg_basebackup` 每日 + WAL 归档到对象存储 | 5 min | 30 min |
| 逻辑备份 | `pg_dump -Fc` 每日，保留 30 天 | 24 h | 2 h |
| SQLite（边缘） | 每日 `VACUUM INTO` + 上传对象存储，带校验和 | 24 h | 15 min |
| 恢复演练 | **每季度一次**，恢复到 staging 并跑对账脚本 | — | — |

**没做过的恢复不算有备份**。恢复演练要验证：数据能起来、`I4` 对账通过、能登录、能出一单。

### 10.7 发布流程

```
PR 合并 main → CI（lint + type + test 双库矩阵 + 构建镜像）
            → 推镜像（tag = git sha）
            → 自动部署 staging → 冒烟用例（下单→拣→发的端到端脚本）
            → 人工确认 → 生产滚动发布
```

**迁移纪律**（WMS 最容易出事故的地方）：

1. **迁移与代码分两次发布**：先上"只加列/加表"的迁移（向后兼容旧代码），再上新代码，最后再上"删列"的清理迁移。三步走，任何一步都能单独回滚。
2. **禁止在迁移里写数据修复脚本**，除非带 `-- dry-run` 输出影响行数并人工审核。
3. **Alembic 加 SQLite batch 模式**：`render_as_batch=True`，且 `compare_type=True`。
4. **迁移前自动检查**：CI 里跑 `alembic upgrade head --sql`（离线 SQL 预览）+ 在一个从生产快照还原的库上真实执行一次迁移，超时或报错则阻断发布。

---

## 11. 测试策略

### 11.1 分层

| 层 | 工具 | 覆盖目标 | 数量占比 |
|---|---|---|---|
| 单元（domain 纯函数） | pytest | FEFO 算法、状态机迁移、效期计算、单位换算、上架打分 | 60% |
| 属性测试 | hypothesis | 库存不变量 I1–I7 在随机操作序列下恒成立 | 5% |
| 集成（真库） | pytest + 双库 parametrize | Service 层完整用例，含并发 | 30% |
| 端到端 | Playwright（web）+ httpx 脚本（PDA 流） | 关键业务链路 | 5% |

```python
@pytest.mark.parametrize("dialect", ["sqlite", "postgres"])
def test_concurrent_pick_never_oversells(session_factory, dialect):
    """50 个协程同时拣同一批次 100 KG，每个要 3 KG —— 最多 33 个成功，且 on_hand >= 0"""
    stock_id = seed_stock(session_factory, on_hand=Decimal("100.000"))
    results = run_concurrent(50, lambda: pick_one(session_factory, stock_id, Decimal("3.000")))
    ok = sum(1 for r in results if r.ok)
    assert ok == 33
    assert load_stock(stock_id).on_hand == Decimal("1.000")
    assert check_invariants(session_factory) == []          # I1–I7 全过
```

```python
@given(ops=st.lists(inventory_op_strategy(), max_size=60))
def test_inventory_conservation(ops):
    """任意顺序的收货/拣货/移库/盘点操作序列，最终 SUM(on_hand) 必须等于流水净额"""
    ...
```

属性测试是这份设计里最能体现"可测试"的一条：**并发和边界情况用枚举用例是写不完的，用不变量 + 随机操作序列才守得住。**

### 11.2 测试数据

- `tests/factories.py` 用 `factory_boy` 造数据，禁止依赖 SQL 快照文件（快照难维护、难读）。
- 集成测试每个用例独立事务 + 回滚；PG 用 `testcontainers` 起真库，SQLite 用 `:memory:`（注意内存库每个连接是独立库，必须用 `StaticPool`）。
- 演示数据：`python -m wms.jobs.seed --profile demo` 造 1 个仓、3 个温区、80 个 SKU、500 库位、2000 批次、3 天共 12000 张订单及其作业流水。有了它，面试演示和压测都能立刻开始。

### 11.3 质量门禁

| 检查 | 工具 | 阈值 |
|---|---|---|
| 格式 + 静态错误 | ruff | 0 error |
| 类型 | mypy `--strict`（domain/service 层），api 层可 `--follow-imports=skip` 渐进 | 0 error |
| 分层依赖 | import-linter | 违反即失败 |
| 覆盖率 | pytest-cov | domain ≥ 90%，service ≥ 80%，整体 ≥ 70% |
| 迁移可执行 | `alembic upgrade head` on 双库 | 必须成功 |
| 错误码唯一 | 自研脚本 | 无重复 |
| 密钥泄漏 | grep 规则 | 无命中 |
| 前端类型 | `vue-tsc --noEmit` | 0 error |

---

## 12. 性能与容量

### 12.1 负载假设（单仓，日订单 8000）

| 场景 | 峰值 | 说明 |
|---|---|---|
| 接单（ERP/商城推送） | 60 TPS，凌晨 00:00–02:00 集中 | 截单后批量下发 |
| 波次生成 | 一次 500 单，耗时目标 < 5s | 分配算法是 CPU 密集 |
| 拣货确认 | 80 TPS（80 个分拣员并发） | 写密集，库存扣减集中在这里 |
| 库存查询 | 200 QPS | 读多，走只读副本/缓存 |
| 商城可售量查询 | 2000 QPS | **绝不查主表**，走 Redis（§9.4） |

### 12.2 关键优化点

1. **库存热点行**：一个爆品批次被大量任务同时扣 → 行锁排队。对策：① 分配阶段就把量摊到多批次/多库位（FEFO 天然分散）；② 同一波次的拣货任务按库位分片给不同人，天然串行化；③ 极端爆品可临时"预拆"到多个拣货位。
2. **`stock_movement` 膨胀**：日 8000 单 × 平均 8 行 × 2 次流水 ≈ 13 万行/天，年 4700 万。对策：PG 按月分区 + 冷数据归档到 `stock_movement_archive`；SQLite 侧按月导出后删除。**保留期：流水永久，明细在线 13 个月。**
3. **列表查询**：所有列表页查询必须命中复合索引。核心索引设计：

```sql
-- 单据类：仓库 + 状态 + 作业日（后台默认筛选）
CREATE INDEX ix_obo_wh_status_work ON outbound_order(warehouse_id, status, work_date DESC);
-- 波次待处理池
CREATE INDEX ix_obo_wave_pending ON outbound_order(warehouse_id, route_code, temperature_required)
  WHERE status = 'ALLOCATED';
-- 库存查询：SKU 维度汇总
CREATE INDEX ix_stock_sku_wh ON stock(sku_id, warehouse_id) WHERE on_hand > 0;
-- 库存查询：库位维度
CREATE INDEX ix_stock_loc ON stock(location_id, sku_id, lot_id);
-- 流水：单号回查
CREATE INDEX ix_mv_biz ON stock_movement(biz_type, biz_no);
-- 流水：时间范围（对账、报表）
CREATE INDEX ix_mv_occurred ON stock_movement(warehouse_id, occurred_at DESC);
-- 效期预警
CREATE INDEX ix_lot_remaining ON lot(remaining_life_days, sku_id) WHERE quality_status = 'QUALIFIED';
```

`WHERE status='ALLOCATED'` 是 PG 部分索引，SQLite 3.8+ 同样支持 —— 符合 §3.1 交集原则，但**必须在集成测试里验证两个方言都能建起来**（这正是把双库矩阵放进 CI 的价值）。

4. **报表**：绝不在业务库跑大报表。日终 ETL 到 `dws_*` 汇总表（同库不同 schema 起步，量大后独立分析库）。
5. **N+1**：所有列表接口用 `selectinload`/`joinedload` 显式声明加载策略；CI 里用 SQLAlchemy `event.listens_for(engine, "before_cursor_execute")` 计数，单请求超过 15 次查询打 warning，测试中直接断言失败。

---

## 13. 可观测性

### 13.1 日志

结构化 JSON，字段固定：

```json
{"ts":"2026-10-15T02:13:44.123Z","level":"INFO","logger":"wms.service.picking",
 "msg":"pick_line_confirmed","trace_id":"b7c3...","span_id":"...",
 "user_id":812,"warehouse_id":3,"client_type":"PDA","device":"PDA-07",
 "biz_no":"PK20261015000842","line_seq":5,"sku_id":4471,"qty":"3.000","dur_ms":42}
```

- `trace_id` 由中间件生成或从 `X-Trace-Id` 继承，贯穿 API → Service → 流水 → 出站事件 → 前端展示（错误响应里带 `trace_id`）。
- **业务关键动作必须落审计表 `audit_log`**（数据库里，不是日志文件）：改主数据、越权放行、手工调账、取消已拣单、重放集成消息。日志会被冲掉，审计表不能。
- 敏感字段（手机号、地址）脱敏后输出。

### 13.2 指标（Prometheus）

| 指标 | 类型 | 告警阈值 |
|---|---|---|
| `wms_http_request_duration_seconds` | histogram | p99 > 1s 持续 5min |
| `wms_inventory_invariant_check_total{result="fail"}` | counter | **> 0 立即告警**（最高优先级） |
| `wms_outbox_lag_seconds` | gauge | > 600s |
| `wms_outbox_dead_total` | counter | > 0 |
| `wms_wave_generation_duration_seconds` | histogram | p95 > 10s |
| `wms_pick_short_rate` | gauge | 单波次 > 5% |
| `wms_expiry_breach_lot_count` | gauge | > 0（过期批次仍有库存） |
| `wms_db_pool_checked_out` | gauge | > 80% pool_size |
| `wms_pda_offline_upload_backlog` | gauge | > 200 条 |
| `wms_shipment_overdue_count` | gauge | > 0 |

`wms_inventory_invariant_check_total{result="fail"}` 是**唯一的 P0 业务指标**：账实不一致意味着系统在错，必须立刻知道。

### 13.3 追踪与告警

- OpenTelemetry 自动埋点 FastAPI + SQLAlchemy，接 Jaeger/Tempo。拣货一次操作跨 PDA→API→DB→worker，没有 trace 排不了障。
- 告警分级：P0（库存不变量失败、数据库不可用、发不出去货）电话；P1（outbox 积压、波次超时）企业微信群 5 分钟；P2（慢查询、重试增多）日报。
- 每天 06:30 自动推送"昨日作业日报"到群里：单量、准时率、缺发率、损耗金额、盘点差异。让系统"被使用"，也是发现问题的最低成本方式。

---

## 14. 风险清单与演进路线

### 14.1 已识别风险

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| RK1 | SQLite 写锁在并发拣货下成为瓶颈 | 作业卡住 | WAL + 短事务 + 冲突重试。**实测单连接 30k TPS 够用，但 8 线程争抢同一行只剩 916 TPS（附录 A.3）**，所以真正的门槛是"单行热点"而非连接数：靠 FEFO 天然分散 + 波次按库位分片来避免争抢；超过 20 并发且热点无法分散时强制上 PG |
| RK2 | 双库方言交集限制功能（无 JSONB、无数组） | 表达力下降 | 接受；复杂查询下沉到 repository 单点，PG-only 特性用 feature flag 隔离 |
| RK3 | 离线 PDA 与服务端冲突 | 账实不符 | §9.2：预扣 + 冲突不静默 + 超时回收 |
| RK4 | 分配算法与现场不一致（批次被人为替换） | FEFO 失效、追溯断链 | 越权需权限 + 原因 + 审计；每周报表看越权率，> 5% 说明算法或库位规划有问题 |
| RK5 | 单仓模型隐含假设（编号、路由、时区） | 多仓改造成本高 | 所有表首列 `warehouse_id`，编号带仓前缀可配，时区取仓库配置而非服务器 |
| RK6 | 集成方（ERP/快递）不稳定 | 发货受阻 | outbox + 死信重放 + 降级手工（面单可手填、发货可跳过回传） |
| RK7 | 生鲜损耗无法精确记账（水分蒸发、修整） | 账面长期偏正 | 引入 `tolerance_pct`（按 SKU 配置自然损耗率），流水允许在容差内自动调整，超出走报损单 |
| RK8 | 凌晨作业窗口，发布必须不停机 | 变更窗口极窄 | 滚动发布 + 迁移三步走（§10.7）；作业时段（00:00–07:00）禁止发布，流水线硬卡 |

### 14.2 演进路线

| 阶段 | 周期 | 范围 | 可验证成果 |
|---|---|---|---|
| M0 骨架 | 1 周 | 工程结构、双库迁移、认证权限、主数据 CRUD、Docker Compose | 一条命令起环境，双库测试通过 |
| M1 入库+库存 | 2 周 | 收货、批次效期、上架推荐、库存查询、流水 | 能收货、能查账、不变量测试通过 |
| M2 出库主线 | 3 周 | 接单、分配、波次、拣货任务、PDA 端 | **端到端能发一单**（这是第一个可演示里程碑） |
| M3 复核发运 | 2 周 | 复核装箱、打印、运单、司机端签收 | 完整链路 + 回传 ERP |
| M4 盘点与异常 | 2 周 | 循环盘点、动碰盘点、调整审批、异常闭环 | 账实差异可归因 |
| M5 报表与效期 | 2 周 | 看板、效期预警、人效、库龄、损耗 | 老板能看的页面 |
| M6 商城端对接 | 2 周 | 可售库存、订单下发、作业日映射 | 三端齐活 |
| M7 多仓 | 后续 | 仓间调拨、跨仓路由、分库 | — |

**M2 结束就是可演示、可写进简历的状态**。如果只能做一半，做到 M2，别把 M1–M7 都做成半成品。

---

## 15. 面试可讲点映射

设计文档不是给人"看过"的，是给人"讲出来"的。下面把 JD 的每条要求映射到这份设计里能讲的具体内容。

| JD 要求 | 讲什么 | 一句话钩子 |
|---|---|---|
| 仓储/生鲜履约经验 | §5.7 效期分级动作、§5.3 波次不跨温区、§3.3 `work_date_offset` | "生鲜仓的报表口径必须按作业日而不是自然日，因为凌晨三点拣的货业务上属于今天" |
| Python 分层可测试 | §2.4 依赖方向 + import-linter、§4.4 FEFO 纯函数、§11.1 属性测试 | "我把状态迁移表集中成一份数据，这样能静态检查可达性，也能穷举测试所有非法跳转" |
| 表结构设计 | §3.1 十二条双库规则、§3.4 四个数量列的语义、§4.1 七条不变量 | "我不用冻结库存行，因为盘点时聚合成本会爆炸；我改用数量列加占用明细表，代价是多一张表，收益是账永远能对上" |
| 验证与自我纠错 | 附录 A：PG 12/12、SQLite 16/16 实测，以及 A.4 里"唯一约束含 NULL 导致不变量静默失效"这个自己抓出来的 bug | "两引擎都把唯一约束里的 NULL 当成互不相等，所以原本可空的 container_id 让'一位一行'完全失效——这不是方言差异，是建模错误，只有真跑一遍才发现" |
| Vue 管理后台 | §8.2 ProTable 的九项内建能力、§8.1 OpenAPI 生成类型 | "我从 OpenAPI 生成 TS 类型，后端改字段前端编译期就报错，比任何接口文档规范都管用" |
| Docker 部署 | §10.1 一条命令起、§10.7 迁移三步走 | "迁移和代码分开发布，先加列、再上代码、最后删列，任何一步都能单独回滚" |
| 多端经验 | §9.2 离线优先 + 幂等补传、§9.4 可售量走缓存 | "冷库里没信号，所以扫码先写本地队列；冲突绝不静默丢，必须让分拣员看到红条" |
| 工程判断力 | §4.3 条件更新、§4.7 号段的 Redis 风险、§12.2 热点行 | "SQLite 没有 SELECT FOR UPDATE，所以我用条件更新加受影响行数判断，这是两个库语义唯一一致的写法" |

**最后一条建议**：这份文档本身要能撑起 30 分钟讲解。准备的时候按这个顺序讲 —— 先讲库存四个数量列和不变量（证明你懂 WMS 的命门），再讲双库十二条规则和附录 A 里那个 NULL 唯一约束的 bug（证明你懂表结构设计不只是画 ER，而且会验证自己的设计），最后讲 FEFO + 波次 + 离线 PDA（证明你懂生鲜和现场）。技术选型一笔带过，那部分没人想听。

---

## 16. 附录 A：验证结果（全部为本机实测，非估算）

设计文档里"看起来对"的东西不值钱，能跑一遍的才值钱。这一节记录**实际执行过的验证**、环境、以及验证过程中暴露并修掉的问题。

### A.1 验证环境

| 组件 | 版本 | 获取方式 |
|---|---|---|
| 操作系统 | Windows 11 x64 | 本机 |
| PostgreSQL | 16.15 (musl alpine) | `docker run postgres:16-alpine` |
| SQLite | 3.50.4 | Python 3.14.8 内置 `sqlite3` |
| Docker | 29.8.2 | 本机 |

### A.2 可复现命令

```bash
bash sql/verify.sh              # PG 侧：建表 + 12 项断言（含 50 连接并发防超卖）
python sql/verify_sqlite.py     # SQLite 侧：翻译 + 建表 + 16 项断言（含 8 线程并发）
```

两个脚本都以退出码表达结果，失败项直接打印偏离值，可直接挂进 CI。

### A.3 实测结果

| 验证项 | 结果 |
|---|---|
| `schema_postgres.sql` 在 PG 16.15 全量执行（`ON_ERROR_STOP=1`） | 通过，无告警输出 |
| 产出对象数 | **38 张表 / 99 个索引 / 1 个视图** |
| PG 侧断言 `sql/verify.sh` | **12 / 12 通过** |
| SQLite 侧断言 `sql/verify_sqlite.py` | **16 / 16 通过** |
| PG → SQLite 机械翻译产生的改动 | **仅 3 类**：删 1 条 `COMMENT ON`、34 处 `DEFAULT now()` → `DEFAULT (datetime('now'))`、去掉显式 `BEGIN/COMMIT`。**无一处需要改列型、改语义或删功能** |
| 部分索引（`CREATE INDEX ... WHERE`）在两引擎均可建 | 通过（PG 与 SQLite 3.50.4 都支持，含 `ix_obo_pool`、`ix_lot_expiry`） |
| `GENERATED ALWAYS AS ... STORED` 差异列 | 通过，`diff_qty = 68 − 100 − (−30) = −2.000` |
| 库层 CHECK 兜底（超占 / 流水平衡 / 职责分离） | 两引擎均拦截，报错类型一致 |
| 三层幂等（记账键 / 业务键） | 两引擎均拦截重复 |
| **§4.3 条件更新防超卖** | 起始 100 KG、每次扣 3 KG、**50 个独立并发方**：成功 **33** / 拒绝 **17** / 剩余 **1.000** / `version` **33**。PG（50 个独立连接）与 SQLite（50 线程 + WAL）**结果完全相同** |
| §4.4 FEFO 排序 | 出库序列 `LOT-1008 → LOT-1008 → LOT-1012 → LOT-1014`，两引擎一致；同批次内先拣货位 `A01-03-01` 后存储位 `B02-01-05` |
| §3.1 R2 精度规则 | SQLite 存入 `1.2345678` 到 `NUMERIC(14,3)`，取回 `typeof = real` 且值未截断；`0.1+0.2+0.3 = 0.6000000000000001`。改用整数最小单位（厘）后累加 = `600/1000 = 0.6` 精确 → **R2 成立** |
| §4.3 SQLite 吞吐 | 单连接串行提交 **30,016 TPS**；8 线程争抢**同一行**降至 **916 TPS**，2,400 次并发提交后 `version` 与扣减总量精确吻合（无丢更新）→ 单行热点是真瓶颈，连接数不是 |

### A.4 验证过程中发现并已修正的问题

这一小节比上面的通过项更有价值——**它们都是"看代码看不出来、跑一遍才暴露"的问题**。

**问题 1（严重）：唯一约束中的 NULL 让不变量 I6 静默失效。**

`stock` 的 `uq_stock_dim UNIQUE (warehouse_id, location_id, sku_id, lot_id, container_id)` 里 `container_id` 原本可空（表示散货无容器）。实测 **PG 16.15 与 SQLite 3.50.4 都把唯一约束中的 NULL 视为互不相等**，同一 `(仓库,库位,SKU,批次)` 可以插入 3 行、30 行 `container_id IS NULL` 的库存记录而完全不报错。散货是生鲜仓的主要形态，等于"一位多行"的脏数据可以无阻碍产生，盘点、对账、FEFO 分配全部失真。

- 修法：`container_id BIGINT NOT NULL DEFAULT 0`，用 `0` 作"无容器"哨兵值；`pack_box_line.lot_id` 同类问题一并改为 `NOT NULL DEFAULT 0`。
- 沉淀为规则 **R11**：任何进入 `UNIQUE` 的列必须 `NOT NULL` + 哨兵默认值。
- 注意这**不是方言差异**（两引擎行为一致），是建模错误。只有把双库矩阵跑起来、并且专门写一条"重复维度插入应被拦截"的断言，才会暴露——最初的 12 项断言里没有这条，是补上的。

**问题 2：`v_stock_available` 视图缺 `lot_code`。**

PDA 要显示批次号（`pick_task_line.lot_code` 的展示来源），但视图只透出 `lot_id / expiry_date / remaining_life_days / quality_status`。第一次跑 FEFO 查询直接 `column "lot_code" does not exist`。已补入视图列。

**问题 3：验证脚本自身的判定 bug（两例）。**

- `set -o pipefail` + `psql | grep -q ERROR`：`grep -q` 命中即退出会给上游发 SIGPIPE，管道整体状态被污染成"失败"，导致 6 项**实际已拦截**的断言被误报为"设计有洞"。改为先把输出捕获到变量再做字符串匹配。
- `expect_allow` 的函数签名只取 `$1`，调用处却按"描述 + SQL"两个参数传，于是把中文描述当成 SQL 执行，连锁导致下一条幂等断言因前置数据未写入而误报。

这三例的共同点：**失败的是验证，不是设计**。所以"跑一遍"这件事本身也需要被验证——断言全绿之前，先确认它变红的原因是对的（我用手工逐条回放确认了 6 项误报，才去修脚本）。

### A.5 尚未验证的部分（明确标出，不要当成已完成）

| 项 | 状态 | 说明 |
|---|---|---|
| Python 后端代码 | **未开始** | 本附录只验证了数据模型层。§2.4 的工程结构、§4.4 的 `domain/fefo.py` 纯函数、§5.2 状态机均尚未落地 |
| §12.1 的 TPS/QPS 假设 | **估算值** | 60 TPS 接单、80 TPS 拣货等来自业务规模推算，未做压测 |
| §10.1 `docker-compose.yml` | **未执行** | 文件内容按 PG 16 / Redis 7 现行镜像写，但没在本机 `up` 过 |
| outbox 重试与死信 | **未验证** | 表结构已建并通过建表验证，投递/重试逻辑未实现 |
| Alembic 双方言迁移 | **未验证** | R1–R12 目前靠"手工翻译 + 全量建表"证明可移植，还没验证 `alembic revision --autogenerate` 在 SQLite 上的 batch 模式行为 |
| 前端 / PDA / 小程序 | **未开始** | §8、§9 是设计，无代码 |

**下一步该做哪件事**：把 §4.3 的条件更新 + §4.4 的 FEFO 纯函数 + §5.2 状态机这三块写成可运行的 Python（约 600 行 + 单测），因为它们是全系统正确性的支点，也是这份设计里唯一"讲不出代码就等于没做"的部分。

---

## 附录 B：文件清单

| 文件 | 说明 |
|---|---|
| [`WMS详细设计说明书.md`](WMS详细设计说明书.md) | 本文档 |
| [`sql/schema_postgres.sql`](../../wms-design/sql/schema_postgres.sql) | 核心表结构（38 表 / 99 索引 / 1 视图），PG 16.15 实测可执行 |
| [`sql/schema_sqlite.sql`](../../wms-design/sql/schema_sqlite.sql) | 由脚本从 PG 版机械生成，勿手改 |
| [`sql/verify.sh`](../../wms-design/sql/verify.sh) | PG 侧验证：建表 + 12 项断言 |
| [`sql/verify_sqlite.py`](../../wms-design/sql/verify_sqlite.py) | SQLite 侧验证：翻译 + 16 项断言 + 并发压测 |
