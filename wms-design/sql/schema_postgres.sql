-- =============================================================================
--  生鲜配送中心 WMS —— 核心表结构（PostgreSQL 16 方言）
--
--  说明：
--  1. 本文件是《WMS详细设计说明书》§3 的可执行落地版，覆盖库存主链路的 12 张表。
--  2. 生产建表走 Alembic；本文件用于评审、文档附件和快速验证索引设计。
--  3. SQLite 差异见每张表末尾的 "-- [SQLite]" 注释，以及 §3.1 的十条规则。
--  4. 所有主键由应用层生成（号段），不用数据库自增 —— 见 D1/R1。
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 主数据
-- -----------------------------------------------------------------------------

CREATE TABLE warehouse (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(32)  NOT NULL,
    name                VARCHAR(64)  NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    timezone            VARCHAR(32)  NOT NULL DEFAULT 'Asia/Shanghai',
    cutoff_time         TIME         NOT NULL,           -- 截单时间
    work_date_offset    SMALLINT     NOT NULL DEFAULT 0, -- 作业日偏移（生鲜仓关键）
    day_switch_time     TIME         NOT NULL DEFAULT '00:30',
    address             VARCHAR(256),
    contact_name        VARCHAR(64),
    contact_phone       VARCHAR(32),
    geohash             VARCHAR(12),
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMP,
    CONSTRAINT uq_warehouse_code UNIQUE (code)
);
COMMENT ON COLUMN warehouse.work_date_offset IS '凌晨作业归属哪一天：-1 表示今日凌晨拣昨日截单的货';


CREATE TABLE zone (
    id              BIGINT       PRIMARY KEY,
    warehouse_id    BIGINT       NOT NULL,
    code            VARCHAR(32)  NOT NULL,
    name            VARCHAR(64)  NOT NULL,
    temp_zone       VARCHAR(16)  NOT NULL,   -- AMBIENT/CHILLED/FROZEN/FRESH
    temp_min        NUMERIC(5,2),
    temp_max        NUMERIC(5,2),
    zone_type       VARCHAR(16)  NOT NULL,   -- RECEIVE/STORAGE/PICK/STAGE/SHIP/RETURN/QUARANTINE
    pick_sequence   VARCHAR(32),
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMP,
    CONSTRAINT uq_zone_code UNIQUE (warehouse_id, code)
);
CREATE INDEX ix_zone_wh_type ON zone(warehouse_id, zone_type, temp_zone);


CREATE TABLE location (
    id                  BIGINT        PRIMARY KEY,
    warehouse_id        BIGINT        NOT NULL,
    zone_id             BIGINT        NOT NULL,
    code                VARCHAR(32)   NOT NULL,
    location_type       VARCHAR(16)   NOT NULL,   -- PALLET/SHELF/FLOOR/BIN
    capacity_weight     NUMERIC(12,3) NOT NULL DEFAULT 0,
    capacity_volume     NUMERIC(14,3) NOT NULL DEFAULT 0,
    used_weight         NUMERIC(12,3) NOT NULL DEFAULT 0,
    used_volume         NUMERIC(14,3) NOT NULL DEFAULT 0,
    max_lots            SMALLINT      NOT NULL DEFAULT 4,  -- 拣货位设 1~2 强制 FEFO
    mix_sku             BOOLEAN       NOT NULL DEFAULT false,
    pickable            BOOLEAN       NOT NULL DEFAULT true,
    abc_class           VARCHAR(2),
    status              VARCHAR(16)   NOT NULL DEFAULT 'AVAILABLE', -- AVAILABLE/LOCKED/DISABLED
    lock_reason         VARCHAR(64),
    min_level           NUMERIC(14,3) NOT NULL DEFAULT 0,  -- 拣货位补货水位
    max_level           NUMERIC(14,3) NOT NULL DEFAULT 0,
    pick_sequence       VARCHAR(32),
    created_at          TIMESTAMP     NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP     NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMP,
    CONSTRAINT uq_location_code UNIQUE (warehouse_id, code)
);
-- 待补货扫描：available < min_level 且 pickable
CREATE INDEX ix_loc_replen ON location(zone_id, pick_sequence) WHERE pickable = true AND status = 'AVAILABLE';
-- [SQLite] 部分索引需 3.8+，语义一致；BOOLEAN 在 SQLite 存为 INTEGER 0/1

CREATE TABLE sku (
    id                          BIGINT       PRIMARY KEY,
    code                        VARCHAR(32)  NOT NULL,
    name                        VARCHAR(128) NOT NULL,
    spec                        VARCHAR(128),
    category_id                 BIGINT,
    brand                       VARCHAR(64),
    base_uom                    VARCHAR(16)  NOT NULL,          -- KG/PCS/EA
    temperature_required        VARCHAR(16)  NOT NULL DEFAULT 'AMBIENT',
    shelf_life_days             SMALLINT     NOT NULL DEFAULT 0,
    receive_min_shelf_life      SMALLINT     NOT NULL DEFAULT 0,-- 收货允收期
    ship_min_shelf_life         SMALLINT     NOT NULL DEFAULT 0,-- 出库禁发期
    is_weighing                 BOOLEAN      NOT NULL DEFAULT false,
    avg_weight_g                NUMERIC(10,2),
    weight_tolerance_pct        NUMERIC(5,2) NOT NULL DEFAULT 5,
    natural_loss_pct            NUMERIC(5,2) NOT NULL DEFAULT 0, -- 自然损耗容差 RK7
    unit_gross_weight           NUMERIC(12,3) NOT NULL DEFAULT 0,
    unit_volume                 NUMERIC(14,6) NOT NULL DEFAULT 0,
    cross_dock                  BOOLEAN      NOT NULL DEFAULT false,
    need_quality_check          BOOLEAN      NOT NULL DEFAULT false,
    abc_class                   VARCHAR(2),
    status                      VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    created_at                  TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at                  TIMESTAMP,
    CONSTRAINT uq_sku_code UNIQUE (code)
);
CREATE INDEX ix_sku_category ON sku(category_id, status);

CREATE TABLE sku_barcode (
    id          BIGINT      PRIMARY KEY,
    sku_id      BIGINT      NOT NULL,
    barcode     VARCHAR(64) NOT NULL,
    uom         VARCHAR(16) NOT NULL DEFAULT 'EA',   -- 该条码对应的包装层级
    is_primary  BOOLEAN     NOT NULL DEFAULT false,
    CONSTRAINT uq_barcode UNIQUE (barcode)
);
-- PDA 扫码解析：条码 → SKU，必须走唯一索引，一次命中

CREATE TABLE sku_unit (
    id              BIGINT        PRIMARY KEY,
    sku_id          BIGINT        NOT NULL,
    uom             VARCHAR(16)   NOT NULL,
    ratio_to_base   NUMERIC(14,6) NOT NULL,
    is_pick_uom     BOOLEAN       NOT NULL DEFAULT false,
    is_receive_uom  BOOLEAN       NOT NULL DEFAULT false,
    barcode_level   SMALLINT      NOT NULL DEFAULT 1,
    CONSTRAINT uq_sku_uom UNIQUE (sku_id, uom)
);

CREATE TABLE lot (
    id                  BIGINT       PRIMARY KEY,
    sku_id              BIGINT       NOT NULL,
    lot_code            VARCHAR(64)  NOT NULL,
    production_date     DATE,                           -- 日历日（04 I5）
    expiry_date         DATE         NOT NULL,          -- FEFO 排序键；日历日，禁发期按仓库时区自然日计算（04 I5）
    receive_date        TIMESTAMP    NOT NULL,
    supplier_id         BIGINT,
    origin_batch        VARCHAR(64),
    quality_status      VARCHAR(16)  NOT NULL DEFAULT 'QUALIFIED',
    remaining_life_days SMALLINT     NOT NULL DEFAULT 9999,  -- 冗余，定时刷新
    sell_deadline       DATE,                           -- 可售截止日 = COALESCE(production_date, receive_date 的日期) + sku.sell_days；sku.sell_days 为空时为 NULL（服务层建批次时写入，跨表不建 CHECK）
    cert_no             VARCHAR(64),                    -- 检疫合格证等
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_lot UNIQUE (sku_id, lot_code, expiry_date)
);
CREATE INDEX ix_lot_expiry ON lot(sku_id, expiry_date) WHERE quality_status = 'QUALIFIED';
CREATE INDEX ix_lot_aging  ON lot(remaining_life_days, sku_id);
-- [SQLite] 两个部分索引均支持；ix_lot_aging 支撑效期预警列表

-- -----------------------------------------------------------------------------
-- 库存（核心）
-- -----------------------------------------------------------------------------

-- 数量口径（docs/02-库存核心.md §4，PM 裁决）：库存四张表的数量一律 BIGINT，
-- 单位 = SKU base_uom 的 1/1000，列名统一 *_qty_milli 后缀。KG 计即"克"，PCS 计即 0.001 个。
-- ck_*_int：SQLite 的 BIGINT 是 INTEGER 亲和性，3.5 / '12.500' 会被静默存成 REAL，
--   用 x = CAST(x AS BIGINT) 拦截非整数写入；PG 侧列型已是 bigint，该 CHECK 恒真，无副作用。

CREATE TABLE stock (
    id                      BIGINT          PRIMARY KEY,
    warehouse_id            BIGINT          NOT NULL,
    location_id             BIGINT          NOT NULL,
    sku_id                  BIGINT          NOT NULL,
    lot_id                  BIGINT          NOT NULL,
    container_id            BIGINT          NOT NULL DEFAULT 0,   -- 0 = 散货无容器（哨兵值，见下）
    uom                     VARCHAR(16)     NOT NULL,             -- 恒为 sku.base_uom

    on_hand_qty_milli       BIGINT          NOT NULL DEFAULT 0,   -- 在库总量
    allocated_qty_milli     BIGINT          NOT NULL DEFAULT 0,   -- 已分配未拣（= ALLOCATE 占用汇总）
    reserved_qty_milli      BIGINT          NOT NULL DEFAULT 0,   -- 已预占（= RESERVE 占用汇总）
    quality_hold_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- 质检/盘点冻结（= QUALITY + RETURN_QC 冻结汇总）
    hold_qty_milli        BIGINT          NOT NULL DEFAULT 0,   -- 冻结（= MANUAL + RETURN_PENDING + SCRAP_PENDING 冻结汇总），从 available 扣除，FEFO 分不到

    ledger_seq              BIGINT          NOT NULL DEFAULT 0,   -- 本行 on_hand 变更计数，与流水 stock_seq 一一对应（快照水位线）；期初/迁移行的第 1 条流水是 OPENING
    version                 BIGINT          NOT NULL DEFAULT 0,
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP       NOT NULL DEFAULT now(),

    CONSTRAINT uq_stock_dim UNIQUE (warehouse_id, location_id, sku_id, lot_id, container_id),
    -- ⚠ container_id 必须是 NOT NULL DEFAULT 0 而不是可空：
    --   唯一约束里含 NULL 列时，PG 与 SQLite 都把 NULL 视为互不相等，
    --   实测两引擎都允许同一 (wh,loc,sku,lot) 插入多行 NULL 容器行 → 不变量 I6 失效。
    --   用 0 作"无容器"哨兵值是唯一在两个引擎上都成立的写法（R1–R10 交集原则）。
    CONSTRAINT ck_stock_container CHECK (container_id >= 0),
    CONSTRAINT ck_stock_int CHECK (
        on_hand_qty_milli = CAST(on_hand_qty_milli AS BIGINT)
        AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT)
        AND reserved_qty_milli = CAST(reserved_qty_milli AS BIGINT)
        AND quality_hold_qty_milli = CAST(quality_hold_qty_milli AS BIGINT)
        AND hold_qty_milli = CAST(hold_qty_milli AS BIGINT)
    ),
    -- 数据库层兜底不变量 I1/I2：即使 Service 写错，也不会出现负数或超占
    CONSTRAINT ck_stock_nonneg CHECK (
        on_hand_qty_milli >= 0 AND allocated_qty_milli >= 0 AND reserved_qty_milli >= 0
        AND quality_hold_qty_milli >= 0 AND hold_qty_milli >= 0
        AND (allocated_qty_milli + reserved_qty_milli + quality_hold_qty_milli + hold_qty_milli) <= on_hand_qty_milli
    )
);
CREATE INDEX ix_stock_sku_avail ON stock(sku_id, warehouse_id, lot_id) WHERE on_hand_qty_milli > 0;
CREATE INDEX ix_stock_loc       ON stock(location_id, sku_id);
CREATE INDEX ix_stock_wh        ON stock(warehouse_id, sku_id);
-- [SQLite] CHECK 约束 SQLite 同样支持且强制执行 —— 这是双库交集内，务必保留
-- [SQLite] BIGINT 为 INTEGER 亲和性，比较为整数比较；ck_stock_int 拦截 REAL/TEXT 混入

CREATE TABLE stock_reservation (
    id                  BIGINT          PRIMARY KEY,
    stock_id            BIGINT          NOT NULL,
    stage               VARCHAR(16)     NOT NULL,   -- RESERVE（计入 reserved）/ ALLOCATE（计入 allocated）
    source_type         VARCHAR(24)     NOT NULL,   -- OUTBOUND_LINE/WAVE/COUNT/MANUAL
    source_id           BIGINT          NOT NULL,
    source_line_id      BIGINT          NOT NULL DEFAULT 0,   -- R11：0 哨兵
    op_key              VARCHAR(80)     NOT NULL,   -- RES:{doc_no}:{line_no}:{alloc_round}:{stock_id}；alloc_round 在出库行上，每次重新分配 +1
    reserve_qty_milli   BIGINT          NOT NULL,
    consumed_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'RESERVED',  -- RESERVED/CONSUMED/RELEASED，由余量决定
    expires_at          TIMESTAMP,                  -- 超时自动释放，防死锁
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_res_op  UNIQUE (op_key),
    CONSTRAINT ck_res_stage CHECK (stage IN ('RESERVE','ALLOCATE')),
    CONSTRAINT ck_res_int CHECK (
        reserve_qty_milli = CAST(reserve_qty_milli AS BIGINT)
        AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)
        AND released_qty_milli = CAST(released_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_res CHECK (
        reserve_qty_milli > 0 AND consumed_qty_milli >= 0 AND released_qty_milli >= 0
        AND consumed_qty_milli + released_qty_milli <= reserve_qty_milli
    ),
    -- 状态与余量绑定（超量由 ck_res 单独拦）：余量>0 ⇔ RESERVED；余量=0 时有消耗为 CONSUMED，否则 RELEASED。
    -- 这样过期任务按 status='RESERVED'（ix_res_exp）一定能找到所有还占着量的记录
    CONSTRAINT ck_res_status CHECK (
        (status = 'RESERVED' AND consumed_qty_milli + released_qty_milli < reserve_qty_milli)
        OR (status = 'CONSUMED' AND consumed_qty_milli + released_qty_milli >= reserve_qty_milli AND consumed_qty_milli > 0)
        OR (status = 'RELEASED' AND consumed_qty_milli + released_qty_milli >= reserve_qty_milli AND consumed_qty_milli = 0)
    )
);
CREATE INDEX ix_res_stock  ON stock_reservation(stock_id, stage, status);
CREATE INDEX ix_res_source ON stock_reservation(source_type, source_id, source_line_id);
CREATE INDEX ix_res_exp    ON stock_reservation(expires_at) WHERE status = 'RESERVED';

CREATE TABLE stock_hold (
    id                  BIGINT          PRIMARY KEY,
    stock_id            BIGINT          NOT NULL,
    hold_type           VARCHAR(16)     NOT NULL,   -- QUALITY、RETURN_QC → stock.quality_hold_qty_milli；MANUAL、RETURN_PENDING、SCRAP_PENDING、PROCESSING（docs/17）→ stock.hold_qty_milli
    reason_code         VARCHAR(24)     NOT NULL,   -- 见 ck_hold_reason；新增原因走迁移
    source_type         VARCHAR(24)     NOT NULL,   -- INBOUND_QC/QC/COUNT/RETURN/EXCEPTION/MANUAL/RETURN_RECORD/SCRAP
    source_id           BIGINT          NOT NULL DEFAULT 0,
    op_key              VARCHAR(80)     NOT NULL,   -- RETURN_PENDING 固定为 RRH:{return_record_id}；convert_hold 新建的明细固定为 CVT:{原 hold_id}
    hold_qty_milli      BIGINT          NOT NULL,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'HELD',      -- HELD/RELEASED，由余量决定
    operator_id         BIGINT          NOT NULL,   -- 系统冻结填 0
    approval_type       VARCHAR(24),                -- 需要审批的转换才填：SCRAP_MISREPORT（SCRAP_PENDING → RETURN_QC 误报回转）
    approval_no         VARCHAR(64),                -- 审批单号
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_hold_op UNIQUE (op_key),
    CONSTRAINT ck_hold_type CHECK (hold_type IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING')),   -- PROCESSING：第 17 篇加工领料（00 §6.4 40933）
    -- 一套方案：hold_type 是大类（决定计入哪一列），reason_code 是细分原因，二者成对约束
    CONSTRAINT ck_hold_reason CHECK (
        hold_type NOT IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING')      -- 类型非法交给 ck_hold_type 报，避免两条约束同时报
        OR (hold_type = 'QUALITY'        AND reason_code IN ('QC_PENDING','COUNT_LOCK'))
        OR (hold_type = 'RETURN_QC'      AND reason_code = 'RETURN_QC')     -- 退货待检（A3：系统冻结，只能由质检 release_qc_hold 释放）
        OR (hold_type = 'MANUAL'      AND reason_code IN ('DAMAGE','EXCEPTION','OTHER'))
        OR (hold_type = 'RETURN_PENDING' AND reason_code = 'RETURN_PENDING')
        OR (hold_type = 'SCRAP_PENDING'  AND reason_code = 'SCRAP')        -- 报损待处置（convert_hold 自 RETURN_PENDING 转入，docs/02 §7.1.1）
        OR (hold_type = 'PROCESSING'     AND reason_code = 'PROCESSING')   -- 加工中（docs/17 §4.4）
    ),
    -- PROCESSING 系统冻结（docs/17）：挂加工单（source_type=PROCESS_ORDER）、operator_id=0、op_key=PRCI:{process_order_id}:{issue_client_id}（= process_issue.op_key）；人工解冻拒绝（40933），只能由第 17 篇完工/冲回释放
    CONSTRAINT ck_hold_process CHECK (
        hold_type <> 'PROCESSING'
        OR (source_type = 'PROCESS_ORDER' AND source_id > 0 AND operator_id = 0 AND op_key LIKE 'PRCI:%')
    ),
    -- RETURN_PENDING 是系统冻结：必须挂在一条待回库记录上、operator_id=0；人工解冻接口拒绝它（应用层），只能由 confirm/resolve 同事务释放
    CONSTRAINT ck_hold_return CHECK (
        hold_type <> 'RETURN_PENDING'
        OR (source_type = 'RETURN_RECORD' AND source_id > 0 AND operator_id = 0)
    ),
    -- SCRAP_PENDING 也是系统冻结：挂报损单（source_type=SCRAP）、operator_id=0；人工解冻拒绝（40933，应用层），只能由第 9 篇报损完成/撤销释放
    -- RETURN_QC 系统冻结（A3）：挂质检单（source_type=QC，source_id=质检单 id）、operator_id=0；人工解冻拒绝（40933），只能由 release_qc_hold 释放
    CONSTRAINT ck_hold_retqc CHECK (
        hold_type <> 'RETURN_QC'
        OR (source_type = 'QC' AND source_id > 0 AND operator_id = 0)
    ),
    -- 误报回转（SCRAP_PENDING → RETURN_QC，convert_hold 生成 op_key=CVT:{原 hold_id}）必须带 SCRAP_MISREPORT 审批单号；其余明细不带审批
    CONSTRAINT ck_hold_approval CHECK (
        (NOT (hold_type = 'RETURN_QC' AND op_key LIKE 'CVT:%') AND approval_type IS NULL AND approval_no IS NULL)
        OR (hold_type = 'RETURN_QC' AND op_key LIKE 'CVT:%'
            AND approval_type = 'SCRAP_MISREPORT' AND approval_no IS NOT NULL AND length(approval_no) > 0)
    ),
    -- 审批单号格式 APR-{仓库编码}-{yyyyMMdd}-{6 位数字}；仓库编码字符集 [A-Z0-9]{2,16}（以第 1 篇 #8 为准）
    CONSTRAINT ck_hold_approval_no CHECK (approval_no IS NULL OR approval_no ~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$'),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_hold_approval_no CHECK (approval_no IS NULL OR (
-- @sqlite-only         length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
-- @sqlite-only         AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only         AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only         AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
-- @sqlite-only         AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]'))),
    CONSTRAINT ck_hold_scrap CHECK (
        hold_type <> 'SCRAP_PENDING'
        OR (source_type = 'SCRAP' AND source_id > 0 AND operator_id = 0)
    ),
    CONSTRAINT ck_hold_int CHECK (
        hold_qty_milli = CAST(hold_qty_milli AS BIGINT)
        AND released_qty_milli = CAST(released_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_hold CHECK (hold_qty_milli > 0 AND released_qty_milli >= 0 AND released_qty_milli <= hold_qty_milli),
    CONSTRAINT ck_hold_status CHECK (
        (status = 'HELD' AND released_qty_milli < hold_qty_milli)
        OR (status = 'RELEASED' AND released_qty_milli >= hold_qty_milli)   -- 超释放由 ck_hold 单独拦
    )
);
CREATE INDEX ix_hold_stock ON stock_hold(stock_id, hold_type, status);
CREATE UNIQUE INDEX uq_hold_return ON stock_hold(source_id) WHERE hold_type = 'RETURN_PENDING';

-- 冻结部分释放的操作去重（A3，release_qc_hold）：一次释放一行，op_key 由质检行操作生成（如 QCR:{qc_line_id}:{op_no}），
-- 与质检行 qc_passed 累加、stock_hold 释放、stock.quality_hold 扣减同一事务；重放撞 uq_hr_op → 整个事务回滚，不重复解冻。只追加。
CREATE TABLE stock_hold_release (
    id                  BIGINT          PRIMARY KEY,
    hold_id             BIGINT          NOT NULL,
    op_key              VARCHAR(80)     NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_hr_op UNIQUE (op_key),
    CONSTRAINT fk_hr_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),   -- 小赵 S6：释放记录必须挂在真实冻结上
    CONSTRAINT ck_hr_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT))
);
CREATE INDEX ix_hr_hold ON stock_hold_release(hold_id);
-- @sqlite-only CREATE TRIGGER trg_hr_no_update BEFORE UPDATE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_hr_no_delete BEFORE DELETE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- 小赵 Q1：REPLACE 冲突删旧行不触发 DELETE 触发器，同 trg_hold_no_replace 用 BEFORE INSERT 先拦（重放撞这里，按 op_key 查回）
-- @sqlite-only CREATE TRIGGER trg_hr_no_replace BEFORE INSERT ON stock_hold_release
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM stock_hold_release r WHERE r.id = NEW.id OR r.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;
-- ↑ 一条待回库记录最多一条 RETURN_PENDING 冻结（重复拒收复用已有记录，不会重复冻结）。
--   只约束 RETURN_PENDING：convert_hold 转出的报损明细（SCRAP_PENDING/SCRAP）不受它约束（小赵 D1）
-- 原文档 §4.2"冻结记 stock_freeze"在此落地为 stock_hold，使 quality_hold/frozen 与 allocated/reserved 一样可对账（I3）

-- 记账去重表：不分区，承载所有流水业务唯一键。每条流水在同一事务里写一行，撞任一唯一键 → 整个事务回滚。
CREATE TABLE stock_movement_key (
    movement_id         BIGINT          PRIMARY KEY,    -- = stock_movement.id（雪花 ID 跨分区也唯一）
    idempotency_key     VARCHAR(160)    NOT NULL,       -- 唯一格式 {biz_no}:{line_no}:{op_ref}:{leg}，op_ref = D{op_no} | P{device_instance_id}.{op_seq}
    biz_no              VARCHAR(64)     NOT NULL,
    line_no             INT             NOT NULL,
    op_no               INT             NOT NULL,
    leg                 SMALLINT        NOT NULL,
    src_kind            VARCHAR(8)      NOT NULL,
    src_task_id         BIGINT,
    src_line_no         INT,
    device_instance_id  VARCHAR(64),
    src_op_seq          INT,
    stock_id            BIGINT          NOT NULL,
    stock_seq           BIGINT          NOT NULL,
    direction           SMALLINT        NOT NULL,
    occurred_at         TIMESTAMP       NOT NULL,       -- 冗余，便于按 key 找到所在分区
    CONSTRAINT uq_mvk_idem UNIQUE (idempotency_key),
    CONSTRAINT ck_mvk_kind CHECK (
        (src_kind = 'DOC' AND src_task_id IS NULL AND src_line_no IS NULL AND device_instance_id IS NULL AND src_op_seq IS NULL AND op_no >= 1)
        OR (src_kind = 'PDA' AND src_task_id IS NOT NULL AND src_line_no IS NOT NULL AND device_instance_id IS NOT NULL AND src_op_seq IS NOT NULL AND op_no = 0)
    ),
    -- 流水外键 fk_mv_key 的被引用键：流水的 id 与全部非空业务列必须和 key 行逐列一致（小赵 C2）
    CONSTRAINT uq_mvk_mv UNIQUE (movement_id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
);
-- 流水主表：只追加。PG 侧按月 RANGE 分区（分区表的唯一约束必须含分区键，只能保证分区内唯一），
-- 所以所有业务唯一键都放到不分区的 stock_movement_key，同一事务写入（见 docs/02 §4.4）。
CREATE TABLE stock_movement (
    id                          BIGINT          NOT NULL,
    biz_no                      VARCHAR(64)     NOT NULL,
    line_no                     INT             NOT NULL,   -- 业务单据行号；无行的单据填 1
    op_no                       INT             NOT NULL DEFAULT 1,  -- 非 PDA：调用方在该行上的第几次操作（如分批收货）；PDA 恒 0
    leg                         SMALLINT        NOT NULL DEFAULT 1,  -- 同一操作的第几条腿：拣货/收货恒 1；移库/上架 1=出 2=入
    src_kind                    VARCHAR(8)      NOT NULL,   -- DOC / PDA
    biz_type                    VARCHAR(24)     NOT NULL,   -- RECEIVE/PUTAWAY/PICK/REVERSE_PICK/SHIP/MOVE/ADJUST/COUNT/RETURN/SCRAP/CROSS_DOCK/OPENING
    direction                   SMALLINT        NOT NULL,   -- 1 入 / -1 出 / 0 纯事件（如 SHIP，不改 on_hand）
    stock_id                    BIGINT          NOT NULL,   -- 记账到哪一行库存，按行回放的依据
    stock_seq                   BIGINT          NOT NULL,   -- = 该次条件 UPDATE 后的 stock.ledger_seq；direction=0 时填当前 ledger_seq（不入链）
    warehouse_id                BIGINT          NOT NULL,
    location_id                 BIGINT          NOT NULL,
    from_location_id            BIGINT,
    sku_id                      BIGINT          NOT NULL,
    lot_id                      BIGINT          NOT NULL,
    container_id                BIGINT          NOT NULL DEFAULT 0,
    -- PDA 作业来源 = 00 总体设计 §6.5 四元组 (task_id, line_no, device_instance_id, op_seq)；DOC 行四列全 NULL
    src_task_id                 BIGINT,
    src_line_no                 INT,
    device_instance_id          VARCHAR(64),
    src_op_seq                  INT,
    move_qty_milli              BIGINT          NOT NULL,
    on_hand_before_qty_milli    BIGINT          NOT NULL,
    on_hand_after_qty_milli     BIGINT          NOT NULL,
    operator_id                 BIGINT,
    device                      VARCHAR(32),
    occurred_at                 TIMESTAMP       NOT NULL,
    recorded_at                 TIMESTAMP       NOT NULL DEFAULT now(),
    cost_amount                 BIGINT,                     -- 分
    idempotency_key             VARCHAR(160)    NOT NULL,   -- 唯一格式见 stock_movement_key
    remark                      VARCHAR(256),
    PRIMARY KEY (id, occurred_at),
    CONSTRAINT ck_mv_dir     CHECK (direction IN (-1, 0, 1)),
    CONSTRAINT ck_mv_kind    CHECK (
        (src_kind = 'DOC' AND src_task_id IS NULL AND src_line_no IS NULL AND device_instance_id IS NULL AND src_op_seq IS NULL AND op_no >= 1)
        OR (src_kind = 'PDA' AND src_task_id IS NOT NULL AND src_line_no IS NOT NULL AND device_instance_id IS NOT NULL AND src_op_seq IS NOT NULL AND op_no = 0)
    ),
    CONSTRAINT ck_mv_int     CHECK (
        move_qty_milli = CAST(move_qty_milli AS BIGINT)
        AND on_hand_before_qty_milli = CAST(on_hand_before_qty_milli AS BIGINT)
        AND on_hand_after_qty_milli = CAST(on_hand_after_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_mv_pos     CHECK (move_qty_milli > 0 AND on_hand_after_qty_milli >= 0),
    CONSTRAINT ck_mv_balance CHECK (on_hand_after_qty_milli = on_hand_before_qty_milli + move_qty_milli * direction),
    CONSTRAINT ck_mv_opening CHECK (biz_type <> 'OPENING' OR (direction = 1 AND stock_seq = 1 AND on_hand_before_qty_milli = 0)),
    -- 库层绑定（小赵 C2）：没有对应 key 行、或 key 行内容对不上，流水写不进去。
    -- 只列 NOT NULL 列：MATCH SIMPLE 下任一列为 NULL 会跳过整条外键检查；PDA 四元组由 ck_mv_kind / ck_mvk_kind + uq_mvk_pda_op 管。
    -- DEFERRABLE INITIALLY DEFERRED：提交时检查，同一事务内流水与 key 的写入顺序不限。
    -- PG 11+ 支持分区表引用普通表的外键，所以这里不用触发器；SQLite 需每个连接 PRAGMA foreign_keys = ON（docs/02 §4.8）。
    CONSTRAINT fk_mv_key FOREIGN KEY (id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
        REFERENCES stock_movement_key (movement_id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
        DEFERRABLE INITIALLY DEFERRED
)
PARTITION BY RANGE (occurred_at);   -- @pg-only
-- @sqlite-only ;
CREATE TABLE stock_movement_p202610 PARTITION OF stock_movement FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');   -- @pg-only
CREATE TABLE stock_movement_p202611 PARTITION OF stock_movement FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');   -- @pg-only
CREATE TABLE stock_movement_pdefault PARTITION OF stock_movement DEFAULT;   -- @pg-only
CREATE INDEX ix_mv_biz      ON stock_movement(biz_type, biz_no);
CREATE INDEX ix_mv_stock    ON stock_movement(stock_id, stock_seq);
CREATE INDEX ix_mv_time     ON stock_movement(warehouse_id, occurred_at DESC);
CREATE INDEX ix_mv_sku_time ON stock_movement(sku_id, occurred_at DESC);
-- 数据量大：PG 侧按月 RANGE 分区（分区由运维任务提前一个月建好，DEFAULT 分区兜底）；SQLite 侧按月归档导出。

CREATE UNIQUE INDEX uq_mvk_biz_line  ON stock_movement_key(biz_no, line_no, op_no, leg) WHERE src_kind = 'DOC';
CREATE UNIQUE INDEX uq_mvk_pda_op    ON stock_movement_key(src_task_id, src_line_no, device_instance_id, src_op_seq, leg) WHERE src_kind = 'PDA';
CREATE UNIQUE INDEX uq_mvk_stock_seq ON stock_movement_key(stock_id, stock_seq) WHERE direction <> 0;
-- ↑ 每行库存的记账链无分叉；direction=0 的事件流水不入链

-- 单据行的记账来源归属：一行单据只能由 DOC 或 PDA 其中一种来源记账，二者互斥（docs/02 §8.4）
CREATE TABLE stock_ledger_line (
    biz_no          VARCHAR(64)     NOT NULL,
    line_no         INT             NOT NULL,
    src_kind        VARCHAR(8)      NOT NULL,
    owner_device_instance_id VARCHAR(64),           -- PDA 行：当前唯一允许记账的设备实例；改派/重新领取时由第 5 篇条件更新换主
    post_count      INT             NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT now(),
    PRIMARY KEY (biz_no, line_no),
    CONSTRAINT ck_sll_kind CHECK (
        (src_kind = 'DOC' AND owner_device_instance_id IS NULL)
        OR (src_kind = 'PDA' AND owner_device_instance_id IS NOT NULL)
    )
);

-- 去重表与归属表绑定：写入 key 时，该单据行的归属必须已存在、来源一致，PDA 行还必须是当前持有设备（两库各一份触发器，语义相同）
CREATE FUNCTION trg_mvk_line_kind() RETURNS trigger LANGUAGE plpgsql AS $$                                 -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM stock_ledger_line l                                                         -- @pg-only
                    WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind  -- @pg-only
                      AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id)) THEN  -- @pg-only
        RAISE EXCEPTION 'ledger_line_owner_mismatch' USING ERRCODE = '23514';                                -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key FOR EACH ROW EXECUTE FUNCTION trg_mvk_line_kind();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key
-- @sqlite-only WHEN NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind
-- @sqlite-only                  AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ledger_line_owner_mismatch'); END;

-- 归属行的来源不可改（小赵 C3）：src_kind / biz_no / line_no 写入后禁止 UPDATE，否则把 PDA 行改成 DOC 就能绕过互斥
CREATE FUNCTION trg_sll_immutable() RETURNS trigger LANGUAGE plpgsql AS $$                                 -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.src_kind IS DISTINCT FROM OLD.src_kind OR NEW.biz_no IS DISTINCT FROM OLD.biz_no                   -- @pg-only
       OR NEW.line_no IS DISTINCT FROM OLD.line_no THEN                                                       -- @pg-only
        RAISE EXCEPTION 'ledger_line_immutable' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line FOR EACH ROW EXECUTE FUNCTION trg_sll_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line
-- @sqlite-only WHEN NEW.src_kind IS NOT OLD.src_kind OR NEW.biz_no IS NOT OLD.biz_no OR NEW.line_no IS NOT OLD.line_no
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ledger_line_immutable'); END;

-- 冻结明细写入后不可改（小赵 N1）：只放行释放路径要写的 released_qty_milli / status / version / updated_at。
-- 类型转换只走 convert_hold（关旧建新），任何路径都不需要改 hold_type；否则先把 SCRAP_PENDING 改成 MANUAL 就能绕过 40933
CREATE FUNCTION trg_hold_immutable() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.stock_id IS DISTINCT FROM OLD.stock_id                           -- @pg-only
       OR NEW.hold_type IS DISTINCT FROM OLD.hold_type OR NEW.reason_code IS DISTINCT FROM OLD.reason_code    -- @pg-only
       OR NEW.source_type IS DISTINCT FROM OLD.source_type OR NEW.source_id IS DISTINCT FROM OLD.source_id    -- @pg-only
       OR NEW.op_key IS DISTINCT FROM OLD.op_key OR NEW.hold_qty_milli IS DISTINCT FROM OLD.hold_qty_milli   -- @pg-only
       OR NEW.operator_id IS DISTINCT FROM OLD.operator_id OR NEW.created_at IS DISTINCT FROM OLD.created_at  -- @pg-only
       OR NEW.approval_type IS DISTINCT FROM OLD.approval_type OR NEW.approval_no IS DISTINCT FROM OLD.approval_no  -- @pg-only
       OR NEW.released_qty_milli < OLD.released_qty_milli  -- R1 释放量只增不减 -- @pg-only
       OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED') THEN  -- R1 RELEASED 不能回 HELD -- @pg-only
        RAISE EXCEPTION 'hold_immutable' USING ERRCODE = '23514';                                            -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold FOR EACH ROW EXECUTE FUNCTION trg_hold_immutable();  -- @pg-only
-- R2：冻结明细不可删除（wms_app 本就没有 DELETE/TRUNCATE 权限；这里兜底超级用户/迁移脚本，与流水表写法一致）
CREATE FUNCTION trg_hold_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'hold_immutable' USING ERRCODE = '23514';                                                -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_hold_no_delete   BEFORE DELETE   ON stock_hold FOR EACH ROW       EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
CREATE TRIGGER trg_hold_no_truncate BEFORE TRUNCATE ON stock_hold FOR EACH STATEMENT EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
-- stock_hold_release 只追加（A3）；TRUNCATE 也拦（小赵 S5）
CREATE TRIGGER trg_hr_no_truncate BEFORE TRUNCATE ON stock_hold_release FOR EACH STATEMENT EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
CREATE TRIGGER trg_hr_append_only BEFORE UPDATE OR DELETE ON stock_hold_release FOR EACH ROW EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold
-- @sqlite-only WHEN NEW.id IS NOT OLD.id OR NEW.stock_id IS NOT OLD.stock_id OR NEW.hold_type IS NOT OLD.hold_type OR NEW.reason_code IS NOT OLD.reason_code
-- @sqlite-only   OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.op_key IS NOT OLD.op_key
-- @sqlite-only   OR NEW.hold_qty_milli IS NOT OLD.hold_qty_milli OR NEW.operator_id IS NOT OLD.operator_id OR NEW.created_at IS NOT OLD.created_at
-- @sqlite-only   OR NEW.approval_type IS NOT OLD.approval_type OR NEW.approval_no IS NOT OLD.approval_no
-- @sqlite-only   OR NEW.released_qty_milli < OLD.released_qty_milli OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- R2（SQLite）：拒删除；REPLACE 冲突时删旧行在 recursive_triggers=OFF（默认，且是连接级开关）下不触发 DELETE 触发器，
-- 所以另用 BEFORE INSERT 在 id / op_key 已存在时直接 ABORT，REPLACE 走不到删除那一步（库级生效，不依赖连接设置）
-- @sqlite-only CREATE TRIGGER trg_hold_no_delete BEFORE DELETE ON stock_hold BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_hold_no_replace BEFORE INSERT ON stock_hold
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.id OR h.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;

-- 只追加：流水表与去重表禁止 UPDATE / DELETE。PG 侧收回应用角色权限 + 触发器（防超级用户/运维脚本误操作）；SQLite 侧触发器
CREATE FUNCTION trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                       -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_mv_append_only  BEFORE UPDATE OR DELETE ON stock_movement     FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_mvk_append_only BEFORE UPDATE OR DELETE ON stock_movement_key FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_app') THEN CREATE ROLE wms_app NOLOGIN; END IF; END $$;  -- @pg-only
GRANT SELECT, INSERT ON stock_movement, stock_movement_key TO wms_app;                                       -- @pg-only
REVOKE UPDATE, DELETE, TRUNCATE ON stock_movement, stock_movement_key FROM wms_app;                          -- @pg-only
-- TRUNCATE 不触发行级触发器，单独加语句级触发器拦（小赵 C5）；归档走 DETACH PARTITION，不用 TRUNCATE
CREATE TRIGGER trg_mv_no_truncate  BEFORE TRUNCATE ON stock_movement     FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_mvk_no_truncate BEFORE TRUNCATE ON stock_movement_key FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- 应用角色授权清单（小赵 C3，docs/02 §4.9）：库存类表只给 SELECT/INSERT/UPDATE，不给 DELETE/TRUNCATE；
-- stock_ledger_line 只能改换主相关列（第 5 篇改派/重新领取），来源与单据行由 trg_sll_immutable 再拦一道（防超级用户/迁移脚本）
GRANT USAGE ON SCHEMA public TO wms_app;                                                                      -- @pg-only
GRANT SELECT, INSERT, UPDATE ON stock, stock_reservation TO wms_app;                                         -- @pg-only
-- stock_hold 只授释放相关列（小赵 N1）；其余列由 trg_hold_immutable 再拦一道（防超级用户/迁移脚本）
GRANT SELECT, INSERT ON stock_hold, stock_hold_release TO wms_app;                                                                -- @pg-only
GRANT UPDATE (released_qty_milli, status, version, updated_at) ON stock_hold TO wms_app;                     -- @pg-only
GRANT SELECT, INSERT ON stock_ledger_line TO wms_app;                                                         -- @pg-only
GRANT UPDATE (owner_device_instance_id, post_count, updated_at) ON stock_ledger_line TO wms_app;             -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mv_no_update  BEFORE UPDATE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- @sqlite-only CREATE TRIGGER trg_mv_no_delete  BEFORE DELETE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- @sqlite-only CREATE TRIGGER trg_mvk_no_update BEFORE UPDATE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
-- @sqlite-only CREATE TRIGGER trg_mvk_no_delete BEFORE DELETE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
-- 归档：PG 侧按分区 DETACH（DDL，不触发行级触发器，需 DBA 权限）；SQLite 侧导出后由维护脚本 DROP 触发器→删除→重建，全程审计

CREATE TABLE stock_snapshot_daily (
    work_date               DATE            NOT NULL,
    stock_id                BIGINT          NOT NULL,
    warehouse_id            BIGINT          NOT NULL,
    location_id             BIGINT          NOT NULL,
    sku_id                  BIGINT          NOT NULL,
    lot_id                  BIGINT          NOT NULL,
    container_id            BIGINT          NOT NULL DEFAULT 0,
    on_hand_qty_milli       BIGINT          NOT NULL,
    allocated_qty_milli     BIGINT          NOT NULL,
    reserved_qty_milli      BIGINT          NOT NULL,
    quality_hold_qty_milli  BIGINT          NOT NULL,
    hold_qty_milli        BIGINT          NOT NULL,
    ledger_seq              BIGINT          NOT NULL,   -- 快照水位线：回放该行 stock_seq <= ledger_seq 的流水应等于 on_hand
    cost_amount             BIGINT          NOT NULL DEFAULT 0,
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    PRIMARY KEY (work_date, stock_id)
);
CREATE INDEX ix_snap_sku ON stock_snapshot_daily(work_date, warehouse_id, sku_id, lot_id);

CREATE TABLE stock_recon_alert (
    id                      BIGINT          PRIMARY KEY,
    check_code              VARCHAR(24)     NOT NULL,   -- 码表见 ck_recon_code；CHECK_BOX_MISMATCH 18 位，16 放不下
    warehouse_id            BIGINT          NOT NULL,
    stock_id                BIGINT          NOT NULL DEFAULT 0,   -- 0 = 仓级汇总差异（R11）
    expected_qty_milli      BIGINT          NOT NULL,
    actual_qty_milli        BIGINT          NOT NULL,
    watermark_ledger_seq    BIGINT          NOT NULL DEFAULT 0,
    hit_count               INT             NOT NULL DEFAULT 1,   -- 同一差异重复检出只累加，不新建
    status                  VARCHAR(16)     NOT NULL DEFAULT 'OPEN',   -- OPEN/ACKED/RESOLVED
    resolved_by             BIGINT,
    resolution              VARCHAR(256),
    detected_at             TIMESTAMP       NOT NULL DEFAULT now(),
    last_seen_at            TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT ck_recon_status CHECK (status IN ('OPEN','ACKED','RESOLVED')),
    CONSTRAINT ck_recon_code CHECK (check_code IN ('I3a','I3b','I3c','I3d','I3e','I4','I5','SNAP','RR_HOLD_FAILED','RR_HOLD_MISMATCH','CHECK_BOX_MISMATCH','SHIP_EVENT_MISSING'))   -- 码表见 docs/02 §4.6；新增走迁移（小赵 C4）
);
CREATE INDEX ix_recon_open ON stock_recon_alert(warehouse_id, status, detected_at DESC);
CREATE UNIQUE INDEX uq_recon_open ON stock_recon_alert(check_code, warehouse_id, stock_id) WHERE status <> 'RESOLVED';
GRANT SELECT, INSERT, UPDATE ON stock_recon_alert TO wms_app;   -- @pg-only
-- ↑ 未闭环的同一差异只有一条；对账任务用 INSERT … ON CONFLICT DO UPDATE SET hit_count = hit_count + 1, last_seen_at = …
--   （PG 与 SQLite ≥ 3.24 写法相同；部分唯一索引作冲突目标时两库都要求带同样的 WHERE）

-- 对账只告警不修数：本表只记录差异，任何修正必须走调整单（adjust_order）+ 审批生成新流水

-- -----------------------------------------------------------------------------
-- 单据
-- -----------------------------------------------------------------------------

CREATE TABLE inbound_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    order_type      VARCHAR(24)  NOT NULL,   -- PURCHASE/RETURN/TRANSFER_IN
    source_system   VARCHAR(24)  NOT NULL,
    source_order_no VARCHAR(64)  NOT NULL,
    supplier_id     BIGINT,
    status          VARCHAR(24)  NOT NULL,   -- CREATED/ARRIVED/RECEIVING/RECEIVED/PUTTING_AWAY/COMPLETED/CANCELLED
    work_date       DATE         NOT NULL,
    expected_at     TIMESTAMP,
    received_at     TIMESTAMP,
    closed_at       TIMESTAMP,
    total_qty       NUMERIC(14,3) NOT NULL DEFAULT 0,
    received_qty    NUMERIC(14,3) NOT NULL DEFAULT 0,
    putaway_qty     NUMERIC(14,3) NOT NULL DEFAULT 0,
    vehicle_no      VARCHAR(24),
    temperature_in  NUMERIC(5,2),            -- 到货实测中心温
    receiver_id     BIGINT,
    putaway_op_id   BIGINT,                  -- SoD：与 receiver_id 不同
    remark          VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now(),
    created_by      BIGINT,
    CONSTRAINT uq_inb_code  UNIQUE (code),
    CONSTRAINT uq_inb_src   UNIQUE (source_system, source_order_no)   -- 业务层幂等
);
CREATE INDEX ix_inb_wh_status ON inbound_order(warehouse_id, status, work_date DESC);

CREATE TABLE inbound_line (
    id              BIGINT          PRIMARY KEY,
    inbound_id      BIGINT          NOT NULL,
    line_no         SMALLINT        NOT NULL,
    sku_id          BIGINT          NOT NULL,
    ordered_qty     NUMERIC(14,3)   NOT NULL DEFAULT 0,
    received_qty    NUMERIC(14,3)   NOT NULL DEFAULT 0,
    putaway_qty     NUMERIC(14,3)   NOT NULL DEFAULT 0,
    rejected_qty    NUMERIC(14,3)   NOT NULL DEFAULT 0,
    uom             VARCHAR(16)     NOT NULL,
    lot_id          BIGINT,
    production_date DATE,
    expiry_date     DATE,
    location_id     BIGINT,
    cost_amount     BIGINT,
    quality_status  VARCHAR(16),
    CONSTRAINT uq_inb_line UNIQUE (inbound_id, line_no)
);

CREATE TABLE outbound_order (
    id                      BIGINT          PRIMARY KEY,
    code                    VARCHAR(64)     NOT NULL,
    warehouse_id            BIGINT          NOT NULL,
    order_type              VARCHAR(24)     NOT NULL,
    source_system           VARCHAR(24)     NOT NULL,
    source_order_no         VARCHAR(64)     NOT NULL,
    customer_id             BIGINT          NOT NULL,
    route_code              VARCHAR(32),                 -- 波次聚合维度
    temperature_required    VARCHAR(16)     NOT NULL DEFAULT 'AMBIENT',
    required_delivery_date  TIMESTAMP,
    work_date               DATE            NOT NULL,
    cutoff_at               TIMESTAMP,
    priority                SMALLINT        NOT NULL DEFAULT 5,
    status                  VARCHAR(24)     NOT NULL,   -- 迁移表见 docs/04 §5.1
    source_hash             VARCHAR(64)     NOT NULL,   -- 上游单据规范化内容的 SHA-256 hex；同号不同 hash → 40910（04 I1）；无默认值（小赵 D6）
    wave_id                 BIGINT,
    short_ship_policy       VARCHAR(16)     NOT NULL DEFAULT 'ALLOW_SHORT',
    total_qty_milli         BIGINT          NOT NULL DEFAULT 0,   -- 以下汇总量均为基本单位 milli（00 R2），由 Service 维护
    allocated_qty_milli     BIGINT          NOT NULL DEFAULT 0,
    picked_qty_milli        BIGINT          NOT NULL DEFAULT 0,
    shipped_qty_milli       BIGINT          NOT NULL DEFAULT 0,
    short_qty_milli         BIGINT          NOT NULL DEFAULT 0,
    total_amount            BIGINT          NOT NULL DEFAULT 0,
    picker_id               BIGINT,
    checker_id              BIGINT,
    driver_id               BIGINT,
    consignee_name          VARCHAR(64),                 -- 以下均为下单时快照
    consignee_phone         VARCHAR(32),
    address_snapshot        VARCHAR(512),
    lat                     NUMERIC(10,7),
    lng                     NUMERIC(10,7),
    tags                    VARCHAR(128),
    remark                  VARCHAR(512),
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP       NOT NULL DEFAULT now(),
    status_changed_at       TIMESTAMP,
    reserve_expires_at      TIMESTAMP,                   -- 预占过期时刻（04 T6）
    version                 BIGINT          NOT NULL DEFAULT 0,   -- 状态条件更新时 +1
    shipped_at              TIMESTAMP,
    delivered_at            TIMESTAMP,
    created_by              BIGINT,
    CONSTRAINT uq_obo_code UNIQUE (code),
    CONSTRAINT uq_obo_src  UNIQUE (source_system, source_order_no),
    CONSTRAINT ck_obo_sod  CHECK (checker_id IS NULL OR picker_id IS NULL OR picker_id <> checker_id),
    -- 小写十六进制 64 位（小赵 N4）。两库通用写法：不用 PG 的 ~、也不用 SQLite 的 GLOB，嵌套 replace 去掉 0-9a-f 后必须为空串；
    -- 大写 A-F、非 hex、汉字都会剩下字符。生成器原样输出到 SQLite，两库约束文本一致
    CONSTRAINT ck_obo_hash CHECK (length(source_hash) = 64 AND lower(source_hash) = source_hash AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(source_hash,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = ''),
    CONSTRAINT ck_obo_qty CHECK (
        total_qty_milli >= 0 AND allocated_qty_milli >= 0 AND picked_qty_milli >= 0
        AND shipped_qty_milli >= 0 AND short_qty_milli >= 0
        AND total_qty_milli = CAST(total_qty_milli AS BIGINT) AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT)
        AND picked_qty_milli = CAST(picked_qty_milli AS BIGINT) AND shipped_qty_milli = CAST(shipped_qty_milli AS BIGINT)
        AND short_qty_milli = CAST(short_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_obo_status CHECK (status IN ('CREATED','PENDING_ALLOC','ALLOCATED','SHORT','WAVED','PICKING','PICKED',
                                               'CHECKED','STAGED','SHIPPED','DELIVERED','COMPLETED','CANCELLED'))
);
CREATE INDEX ix_obo_pool   ON outbound_order(warehouse_id, route_code, temperature_required, priority)
    WHERE status = 'ALLOCATED';                          -- 波次待处理池
CREATE INDEX ix_obo_wh     ON outbound_order(warehouse_id, status, work_date DESC);
CREATE INDEX ix_obo_wave   ON outbound_order(wave_id) WHERE wave_id IS NOT NULL;
CREATE INDEX ix_obo_cust   ON outbound_order(customer_id, created_at DESC);

CREATE TABLE outbound_line (
    id              BIGINT          PRIMARY KEY,
    outbound_id     BIGINT          NOT NULL,
    line_no         SMALLINT        NOT NULL,
    sku_id          BIGINT          NOT NULL,
    order_qty_milli     BIGINT      NOT NULL,             -- 基本单位 milli（00 R2）
    reserved_qty_milli  BIGINT      NOT NULL DEFAULT 0,
    allocated_qty_milli BIGINT      NOT NULL DEFAULT 0,
    picked_qty_milli    BIGINT      NOT NULL DEFAULT 0,   -- 累计拣出量（不因撤销/回冲减少）
    shipped_qty_milli   BIGINT      NOT NULL DEFAULT 0,
    short_qty_milli     BIGINT      NOT NULL DEFAULT 0,
    uom             VARCHAR(16)     NOT NULL,
    unit_price      BIGINT          NOT NULL DEFAULT 0,
    amount          BIGINT          NOT NULL DEFAULT 0,
    short_reason    VARCHAR(24),
    alloc_round     INT             NOT NULL DEFAULT 0,   -- 每次重新分配 +1，进入占用幂等键（04 B1）
    reversed_qty_milli  BIGINT      NOT NULL DEFAULT 0,   -- 已撤销/回冲累计量；条件更新 reversed + qty <= picked，否则 42214（04 §6.3）
    CONSTRAINT ck_obl_int CHECK (
        order_qty_milli = CAST(order_qty_milli AS BIGINT) AND reserved_qty_milli = CAST(reserved_qty_milli AS BIGINT)
        AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT) AND picked_qty_milli = CAST(picked_qty_milli AS BIGINT)
        AND shipped_qty_milli = CAST(shipped_qty_milli AS BIGINT) AND short_qty_milli = CAST(short_qty_milli AS BIGINT)
        AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_obl_nonneg CHECK (
        order_qty_milli > 0 AND reserved_qty_milli >= 0 AND allocated_qty_milli >= 0 AND picked_qty_milli >= 0
        AND shipped_qty_milli >= 0 AND short_qty_milli >= 0 AND reversed_qty_milli >= 0
    ),
    CONSTRAINT ck_obl_reversed CHECK (reversed_qty_milli <= picked_qty_milli),   -- 库层兜底：回冲不超过拣出（04 D4）
    CONSTRAINT ck_obl_sum CHECK (
        (picked_qty_milli - reversed_qty_milli) + short_qty_milli <= order_qty_milli
        AND reserved_qty_milli + allocated_qty_milli + (picked_qty_milli - reversed_qty_milli) <= order_qty_milli
        AND shipped_qty_milli <= picked_qty_milli - reversed_qty_milli
    ),
    CONSTRAINT uq_obo_line UNIQUE (outbound_id, line_no)
);
CREATE INDEX ix_obl_sku ON outbound_line(sku_id);

CREATE TABLE wave (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    work_date           DATE         NOT NULL,
    temperature_zone    VARCHAR(16)  NOT NULL,
    route_code          VARCHAR(32)  NOT NULL,
    carrier_code        VARCHAR(32),
    pick_strategy       VARCHAR(24)  NOT NULL DEFAULT 'BATCH',
    status              VARCHAR(16)  NOT NULL DEFAULT 'PLANNED',
    order_count         INT          NOT NULL DEFAULT 0,
    pick_line_count     INT          NOT NULL DEFAULT 0,
    parent_wave_id      BIGINT,
    released_at         TIMESTAMP,
    completed_at        TIMESTAMP,
    created_by          BIGINT,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_wave_code UNIQUE (code)
);
CREATE INDEX ix_wave_wh ON wave(warehouse_id, status, work_date DESC);

CREATE TABLE pick_task (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    wave_id         BIGINT       NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    task_type       VARCHAR(24)  NOT NULL DEFAULT 'PICK',   -- PICK/REPLENISH（补货复用本表）
    zone_id         BIGINT,
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING',-- PENDING/EXECUTING/DONE/ABNORMAL/CANCELLED
    assigned_to     BIGINT,
    claimed_at      TIMESTAMP,
    started_at      TIMESTAMP,
    finished_at     TIMESTAMP,
    line_count      INT          NOT NULL DEFAULT 0,
    done_count      INT          NOT NULL DEFAULT 0,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_pt_code UNIQUE (code)
);
-- 领取队列：待领取 + 按动线优先级
CREATE INDEX ix_pt_claim ON pick_task(wave_id, status, zone_id) WHERE status = 'PENDING';
CREATE INDEX ix_pt_mine  ON pick_task(assigned_to, status);

CREATE TABLE pick_task_line (
    id                  BIGINT          PRIMARY KEY,
    pick_task_id        BIGINT          NOT NULL,
    seq                 SMALLINT        NOT NULL,   -- 动线顺序，前端按它渲染
    location_id         BIGINT          NOT NULL,
    sku_id              BIGINT          NOT NULL,
    lot_id              BIGINT          NOT NULL,
    stock_id            BIGINT          NOT NULL,
    outbound_line_id    BIGINT,                     -- 分播墙按单分发时用
    planned_qty_milli   BIGINT          NOT NULL,   -- 应拣量，基本单位 milli（原 plan_qty_base）
    confirmed_qty_milli BIGINT          NOT NULL DEFAULT 0,  -- 已确认量；条件更新 confirmed + qty <= planned，否则 42214（00 §6.5）
    uom                 VARCHAR(16)     NOT NULL,   -- 作业单位，仅展示
    barcode_expected    VARCHAR(64),
    status              VARCHAR(16)     NOT NULL DEFAULT 'PENDING',
    short_reason_code   VARCHAR(24),
    scanned_at          TIMESTAMP,
    override_reason     VARCHAR(128),               -- FEFO 越权原因（RK4）
    override_by         BIGINT,
    CONSTRAINT ck_ptl_qty CHECK (
        planned_qty_milli > 0 AND confirmed_qty_milli >= 0 AND confirmed_qty_milli <= planned_qty_milli
        AND planned_qty_milli = CAST(planned_qty_milli AS BIGINT) AND confirmed_qty_milli = CAST(confirmed_qty_milli AS BIGINT)
    ),
    CONSTRAINT uq_ptl UNIQUE (pick_task_id, seq)
);
CREATE INDEX ix_ptl_loc ON pick_task_line(location_id, status);

CREATE TABLE pack_box (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,          -- 箱码，司机端逐箱扫
    warehouse_id    BIGINT       NOT NULL,
    outbound_id     BIGINT       NOT NULL,
    shipment_id     BIGINT,
    stage_location_id BIGINT,                       -- 集货位
    box_type        VARCHAR(24)  NOT NULL DEFAULT 'CARTON',  -- CARTON/TURNBOX（周转筐）
    weight_g        NUMERIC(10,2),
    sealed          BOOLEAN      NOT NULL DEFAULT false,
    checker_id      BIGINT,
    packed_at       TIMESTAMP,
    CONSTRAINT uq_box_code UNIQUE (code)
);

CREATE TABLE pack_box_line (
    id          BIGINT          PRIMARY KEY,
    box_id      BIGINT          NOT NULL,
    sku_id      BIGINT          NOT NULL,
    lot_id      BIGINT          NOT NULL DEFAULT 0,   -- 0 = 未记批次；同 stock.container_id，不可空（uq 含 NULL 会失效）
    qty_milli   BIGINT          NOT NULL,   -- 基本单位 milli
    uom         VARCHAR(16)     NOT NULL,
    CONSTRAINT ck_box_line_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT uq_box_line UNIQUE (box_id, sku_id, lot_id)
);

CREATE TABLE shipment (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    carrier_code    VARCHAR(32),
    vehicle_no      VARCHAR(24),
    driver_id       BIGINT,
    driver_name     VARCHAR(64),
    driver_phone    VARCHAR(32),
    status          VARCHAR(16)  NOT NULL DEFAULT 'CREATED', -- CREATED/LOADING/DEPARTED/DELIVERING/SIGNED/CLOSED
    planned_depart_at TIMESTAMP,
    departed_at     TIMESTAMP,
    signed_at       TIMESTAMP,
    temp_log_ref    VARCHAR(128),                   -- 温控记录对象存储 key
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_shp_code UNIQUE (code)
);
CREATE INDEX ix_shp_driver ON shipment(driver_id, status, planned_depart_at);

CREATE TABLE shipment_order (
    shipment_id BIGINT NOT NULL,
    outbound_id BIGINT NOT NULL,
    PRIMARY KEY (shipment_id, outbound_id)
);

-- -----------------------------------------------------------------------------
-- 盘点 / 调整
-- -----------------------------------------------------------------------------

CREATE TABLE count_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    count_type      VARCHAR(24)  NOT NULL,   -- FULL/CYCLE/DYNAMIC/SAMPLE
    scope_json      TEXT         NOT NULL,   -- 盘点范围（不用 JSONB，R4）
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',
    frozen_at       TIMESTAMP,
    book_at         TIMESTAMP    NOT NULL,   -- 账面基准时点（差异要加回期间流水）
    started_at      TIMESTAMP,
    finished_at     TIMESTAMP,
    approved_by     BIGINT,
    approved_at     TIMESTAMP,
    created_by      BIGINT,
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_cnt_code UNIQUE (code)
);

CREATE TABLE count_line (
    id              BIGINT          PRIMARY KEY,
    count_id        BIGINT          NOT NULL,
    location_id     BIGINT          NOT NULL,
    sku_id          BIGINT          NOT NULL,
    lot_id          BIGINT          NOT NULL,
    book_qty_milli      BIGINT      NOT NULL,           -- 基准账面（1/1000 base_uom，见 docs/02）
    movement_qty_milli  BIGINT      NOT NULL DEFAULT 0, -- 期间净流水
    actual_qty_milli    BIGINT,                         -- 实盘（NULL = 未盘）
    diff_qty_milli      BIGINT GENERATED ALWAYS AS (actual_qty_milli - book_qty_milli - movement_qty_milli) STORED,
    recount_qty_milli   BIGINT,
    status          VARCHAR(16)     NOT NULL DEFAULT 'PENDING',
    counted_by      BIGINT,
    counted_at      TIMESTAMP,
    adjust_id       BIGINT,
    CONSTRAINT ck_cnt_int CHECK (
        book_qty_milli = CAST(book_qty_milli AS BIGINT)
        AND movement_qty_milli = CAST(movement_qty_milli AS BIGINT)
        AND (actual_qty_milli IS NULL OR actual_qty_milli = CAST(actual_qty_milli AS BIGINT))
        AND (recount_qty_milli IS NULL OR recount_qty_milli = CAST(recount_qty_milli AS BIGINT))
    ),
    CONSTRAINT uq_cnt_line UNIQUE (count_id, location_id, sku_id, lot_id)
);
-- [SQLite] GENERATED 列 SQLite 3.31+ 支持 STORED；若低于该版本改为应用层计算 + 普通列

CREATE TABLE adjust_order (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,
    warehouse_id    BIGINT          NOT NULL,
    adjust_type     VARCHAR(24)     NOT NULL,   -- COUNT_GAIN/COUNT_LOSS/SCRAP/MANUAL/REVERSE_PICK
    reason_code     VARCHAR(24)     NOT NULL,
    source_type     VARCHAR(24),
    source_id       BIGINT,
    status          VARCHAR(16)     NOT NULL DEFAULT 'PENDING',
    amount_impact   BIGINT          NOT NULL DEFAULT 0,
    applicant_id    BIGINT          NOT NULL,
    approver_id     BIGINT,
    approved_at     TIMESTAMP,
    applied_at      TIMESTAMP,
    created_at      TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_adj_code UNIQUE (code)
);

CREATE TABLE adjust_line (
    id              BIGINT          PRIMARY KEY,
    adjust_id       BIGINT          NOT NULL,
    stock_id        BIGINT          NOT NULL,
    delta_qty       NUMERIC(14,3)   NOT NULL,   -- 正入负出
    CONSTRAINT ck_adj_delta CHECK (delta_qty <> 0)
);

-- -----------------------------------------------------------------------------
-- 幂等 / 集成 / 审计
-- -----------------------------------------------------------------------------

CREATE TABLE idempotency_record (
    idem_key     VARCHAR(80)  PRIMARY KEY,
    req_hash     VARCHAR(64)  NOT NULL,
    response     TEXT         NOT NULL,
    status_code  INT          NOT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- 一律存 UTC（P1）
    expires_at   TIMESTAMP    NOT NULL                -- UTC；写入后只许往后改（trg_idem_expiry_fwd，P2）
);
CREATE INDEX ix_idem_exp ON idempotency_record(expires_at);

CREATE TABLE inbound_message (
    id              BIGINT       PRIMARY KEY,
    source          VARCHAR(24)  NOT NULL,
    biz_type        VARCHAR(32)  NOT NULL,
    external_no     VARCHAR(64)  NOT NULL,
    payload         TEXT         NOT NULL,
    payload_sha     VARCHAR(64)  NOT NULL,
    status          VARCHAR(16)  NOT NULL DEFAULT 'RECEIVED',
    retry_count     SMALLINT     NOT NULL DEFAULT 0,
    next_retry_at   TIMESTAMP,
    error           VARCHAR(512),
    received_at     TIMESTAMP    NOT NULL DEFAULT now(),
    processed_at    TIMESTAMP,
    CONSTRAINT uq_in_msg UNIQUE (source, biz_type, external_no)
);
CREATE INDEX ix_in_msg_retry ON inbound_message(status, next_retry_at);

CREATE TABLE outbox_event (
    id              BIGINT       PRIMARY KEY,
    topic           VARCHAR(64)  NOT NULL,
    biz_key         VARCHAR(64)  NOT NULL,
    payload         TEXT         NOT NULL,
    headers         TEXT,
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    retry_count     SMALLINT     NOT NULL DEFAULT 0,
    next_retry_at   TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC
    last_error      VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC
    sent_at         TIMESTAMP,                          -- UTC；写入后只许往后改（P2）
    CONSTRAINT ck_outbox_sent CHECK (status <> 'SENT' OR sent_at IS NOT NULL)   -- P3
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
CREATE INDEX ix_outbox_bizkey  ON outbox_event(biz_key, id);   -- 同键串行发送

-- 小赵 Q2：去重记录与 outbox 只能清理"已过期 / 已投递且过保留期"的行（两库触发器，条件与 purge_expired() 一致）
CREATE FUNCTION trg_purge_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'TRUNCATE' THEN RAISE EXCEPTION 'purge_not_allowed: %', TG_TABLE_NAME USING ERRCODE = '42501'; END IF;  -- @pg-only
    IF TG_TABLE_NAME = 'idempotency_record' THEN                                                              -- @pg-only
        IF NOT COALESCE(OLD.expires_at < (now() AT TIME ZONE 'UTC'), false) THEN                                                            -- @pg-only
            RAISE EXCEPTION 'purge_not_allowed: idempotency_record' USING ERRCODE = '42501';                 -- @pg-only
        END IF;                                                                                               -- @pg-only
    ELSIF NOT COALESCE(OLD.status = 'SENT' AND OLD.sent_at < (now() AT TIME ZONE 'UTC') - interval '7 days', false) THEN   -- outbox_event  -- @pg-only
        RAISE EXCEPTION 'purge_not_allowed: outbox_event' USING ERRCODE = '42501';                           -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN OLD;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_idem_purge_guard    BEFORE DELETE   ON idempotency_record FOR EACH ROW       EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_idem_no_truncate    BEFORE TRUNCATE ON idempotency_record FOR EACH STATEMENT EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_outbox_purge_guard  BEFORE DELETE   ON outbox_event       FOR EACH ROW       EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_outbox_no_truncate  BEFORE TRUNCATE ON outbox_event       FOR EACH STATEMENT EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_idem_purge_guard BEFORE DELETE ON idempotency_record WHEN NOT COALESCE(OLD.expires_at < datetime('now'), 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: idempotency_record'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_purge_guard BEFORE DELETE ON outbox_event WHEN NOT COALESCE(OLD.status = 'SENT' AND OLD.sent_at < datetime('now', '-7 days'), 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: outbox_event'); END;
-- 九轮 P2：过期/投递时间写入后只许往后改，不许改早；created_at 不可改；SENT 是终态；sent_at 首次写入不得早于 created_at
CREATE FUNCTION trg_expiry_forward() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN                                                    -- @pg-only
        RAISE EXCEPTION 'expiry_backdate: created_at' USING ERRCODE = '42501'; END IF;                        -- @pg-only
    IF TG_TABLE_NAME = 'idempotency_record' THEN                                                              -- @pg-only
        IF NEW.expires_at < OLD.expires_at THEN                                                               -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: expires_at' USING ERRCODE = '42501'; END IF;                    -- @pg-only
    ELSE                                                                                                      -- @pg-only
        -- R1：变成 SENT 的那次写入，sent_at 必须是当前 UTC 时间（容差 5 秒）                                    -- @pg-only
        IF NEW.status = 'SENT' AND OLD.status <> 'SENT'                                                       -- @pg-only
           AND abs(extract(epoch FROM NEW.sent_at - (now() AT TIME ZONE 'UTC'))) > 5 THEN                     -- @pg-only
            RAISE EXCEPTION 'sent_at_not_now' USING ERRCODE = '42501'; END IF;                                -- @pg-only
        IF OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR NEW.sent_at < OLD.sent_at) THEN                -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: sent_at' USING ERRCODE = '42501'; END IF;                       -- @pg-only
        IF OLD.sent_at IS NULL AND NEW.sent_at < OLD.created_at THEN                                          -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: sent_at' USING ERRCODE = '42501'; END IF;                       -- @pg-only
        IF OLD.status = 'SENT' AND NEW.status <> 'SENT' THEN                                                  -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: status' USING ERRCODE = '42501'; END IF;                        -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_idem_expiry_fwd   BEFORE UPDATE ON idempotency_record FOR EACH ROW EXECUTE FUNCTION trg_expiry_forward();  -- @pg-only
CREATE TRIGGER trg_outbox_expiry_fwd BEFORE UPDATE ON outbox_event       FOR EACH ROW EXECUTE FUNCTION trg_expiry_forward();  -- @pg-only
-- 十六轮 R1 补洞：wms_app 只能以初始状态 PENDING（不带 sent_at）插入 outbox；SENT 只能经 UPDATE 写入（受 sent_at_not_now 约束）。
-- 种子/迁移用超级用户或迁移角色写入，不受此限
CREATE FUNCTION trg_outbox_insert_pending() RETURNS trigger LANGUAGE plpgsql AS $$                         -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF current_user = 'wms_app' AND (NEW.status IS DISTINCT FROM 'PENDING' OR NEW.sent_at IS NOT NULL) THEN   -- @pg-only
        RAISE EXCEPTION 'outbox_insert_not_pending' USING ERRCODE = '42501'; END IF;                          -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event FOR EACH ROW EXECUTE FUNCTION trg_outbox_insert_pending();  -- @pg-only
-- SQLite 没有角色：应用只能插入 PENDING（不带 sent_at）；验证脚本造 SENT 种子时临时 DROP 本触发器、写完重建（单独的种子路径）
-- @sqlite-only CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event WHEN NEW.status IS NOT 'PENDING' OR NEW.sent_at IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_insert_not_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_idem_expiry_fwd BEFORE UPDATE ON idempotency_record WHEN NEW.created_at IS NOT OLD.created_at OR NEW.expires_at < OLD.expires_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'expiry_backdate: idempotency_record'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_expiry_fwd BEFORE UPDATE ON outbox_event WHEN NEW.created_at IS NOT OLD.created_at OR (OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR NEW.sent_at < OLD.sent_at)) OR (OLD.sent_at IS NULL AND NEW.sent_at < OLD.created_at) OR (OLD.status = 'SENT' AND NEW.status <> 'SENT')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'expiry_backdate: outbox_event'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_sent_now BEFORE UPDATE ON outbox_event WHEN NEW.status = 'SENT' AND OLD.status <> 'SENT' AND abs(julianday(NEW.sent_at) - julianday('now')) * 86400 > 5
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sent_at_not_now'); END;
-- SQLite REPLACE 冲突删旧行不触发 DELETE 触发器 → BEFORE INSERT 主键已存在就中止（应用把 idem_duplicate 当作"键已存在"处理，与 PG 23505 同分支）
-- @sqlite-only CREATE TRIGGER trg_idem_no_replace BEFORE INSERT ON idempotency_record WHEN EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'idem_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_no_replace BEFORE INSERT ON outbox_event WHEN EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_duplicate'); END;

CREATE TABLE audit_log (
    id              BIGINT       PRIMARY KEY,
    actor_id        BIGINT,
    actor_name      VARCHAR(64),
    client_type     VARCHAR(16),
    action          VARCHAR(64)  NOT NULL,   -- outbound.cancel_after_pick / lot.expiry_override ...
    target_type     VARCHAR(32),
    target_id       VARCHAR(64),
    before_json     TEXT,
    after_json      TEXT,
    reason          VARCHAR(256),
    warehouse_id    BIGINT,
    trace_id        VARCHAR(32),
    ip              VARCHAR(45),
    occurred_at     TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_target ON audit_log(target_type, target_id, occurred_at DESC);
CREATE INDEX ix_audit_actor  ON audit_log(actor_id, occurred_at DESC);

CREATE TABLE numbering_segment (
    biz_prefix   VARCHAR(16)  NOT NULL,
    date_key     VARCHAR(8)   NOT NULL,
    next_value   BIGINT       NOT NULL,
    step         INT          NOT NULL DEFAULT 100,
    updated_at   TIMESTAMP    NOT NULL DEFAULT now(),
    PRIMARY KEY (biz_prefix, date_key)
);
-- 取号（号段预取，两库语义一致）：
--   UPDATE numbering_segment SET next_value = next_value + step WHERE biz_prefix=? AND date_key=?
--   然后 SELECT next_value - step 作为本段起点。多实例安全，不依赖 Redis 持久化。

-- -----------------------------------------------------------------------------
-- 权限（RBAC + 数据权限）
-- -----------------------------------------------------------------------------

CREATE TABLE sys_user (
    id              BIGINT       PRIMARY KEY,
    username        VARCHAR(64)  NOT NULL,
    password_hash   VARCHAR(256) NOT NULL,
    real_name       VARCHAR(64),
    phone           VARCHAR(32),
    mp_openid       VARCHAR(64),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    last_login_at   TIMESTAMP,
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMP,
    CONSTRAINT uq_user_name UNIQUE (username)
);
CREATE INDEX ix_user_openid ON sys_user(mp_openid) WHERE mp_openid IS NOT NULL;

CREATE TABLE sys_role (
    id           BIGINT       PRIMARY KEY,
    code         VARCHAR(64)  NOT NULL,
    name         VARCHAR(64)  NOT NULL,
    data_scope   VARCHAR(16)  NOT NULL DEFAULT 'WAREHOUSE',  -- ALL/WAREHOUSE/ZONE/SELF
    is_builtin   BOOLEAN      NOT NULL DEFAULT false,
    remark       VARCHAR(256),
    CONSTRAINT uq_role_code UNIQUE (code)
);

CREATE TABLE sys_permission (
    id           BIGINT       PRIMARY KEY,
    code         VARCHAR(96)  NOT NULL,   -- module.resource.action
    name         VARCHAR(64)  NOT NULL,
    module       VARCHAR(32)  NOT NULL,
    type         VARCHAR(16)  NOT NULL DEFAULT 'API',        -- API/BUTTON/MENU
    CONSTRAINT uq_perm_code UNIQUE (code)
);

CREATE TABLE sys_user_role     (user_id BIGINT NOT NULL, role_id BIGINT NOT NULL, PRIMARY KEY(user_id, role_id));
CREATE TABLE sys_role_perm     (role_id BIGINT NOT NULL, perm_id BIGINT NOT NULL, PRIMARY KEY(role_id, perm_id));
CREATE TABLE sys_user_warehouse(user_id BIGINT NOT NULL, warehouse_id BIGINT NOT NULL, PRIMARY KEY(user_id, warehouse_id));

CREATE TABLE api_credential (
    id               BIGINT       PRIMARY KEY,
    api_key          VARCHAR(64)  NOT NULL,
    secret_encrypted VARCHAR(256) NOT NULL,
    source_system    VARCHAR(24)  NOT NULL,
    status           VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    ip_whitelist     VARCHAR(256),
    last_used_at     TIMESTAMP,
    CONSTRAINT uq_api_key UNIQUE (api_key)
);

-- -----------------------------------------------------------------------------
-- 视图：可用量（避免每个查询手写减法，也避免算错）
-- -----------------------------------------------------------------------------

CREATE VIEW v_stock_available AS
SELECT
    s.id                AS stock_id,
    s.warehouse_id,
    s.location_id,
    l.code              AS location_code,
    l.pick_sequence,
    z.zone_type,
    z.temp_zone,
    s.sku_id,
    s.lot_id,
    lo.lot_code,
    lo.expiry_date,
    lo.remaining_life_days,
    lo.quality_status,
    s.uom,
    s.on_hand_qty_milli,
    s.allocated_qty_milli,
    s.reserved_qty_milli,
    s.quality_hold_qty_milli,
    s.hold_qty_milli,
    (s.on_hand_qty_milli - s.allocated_qty_milli - s.reserved_qty_milli - s.quality_hold_qty_milli - s.hold_qty_milli) AS available_qty_milli,
    (s.on_hand_qty_milli - s.quality_hold_qty_milli - s.hold_qty_milli - s.allocated_qty_milli)                        AS pickable_qty_milli
FROM stock s
JOIN location l ON l.id = s.location_id
JOIN zone z     ON z.id = l.zone_id
JOIN lot lo     ON lo.id = s.lot_id
WHERE s.on_hand_qty_milli > 0 AND l.status = 'AVAILABLE' AND l.deleted_at IS NULL;
-- FEFO 分配走这个视图，排序键在应用层（domain/fefo.py）实现，保证可单测
-- [SQLite] 视图支持一致；now() 在 SQLite 侧用 datetime('now')，故未在本文件使用

COMMIT;

-- ============================================================
-- wms_app 授权清单（其余表，docs/02 §4.4.4）：public 下每张表/视图都必须对 wms_app 有显式授权，
-- verify.sh 按 pg_class 逐表检查，缺一张就失败。新增表必须在这里（或表旁）写 GRANT，按需最小授权；不给 TRUNCATE。
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON warehouse, zone, location, sku, sku_unit, sku_barcode, lot, numbering_segment,  -- @pg-only
    inbound_order, inbound_line, outbound_order, outbound_line, wave, pick_task, pick_task_line,                  -- @pg-only
    pack_box, pack_box_line, shipment, shipment_order, count_order, count_line, adjust_order, adjust_line,       -- @pg-only
    sys_user, sys_role, sys_permission, sys_role_perm, sys_user_role, sys_user_warehouse, api_credential,        -- @pg-only
    inbound_message TO wms_app;                                                                                   -- @pg-only
GRANT SELECT, INSERT, UPDATE ON idempotency_record, outbox_event TO wms_app;           -- 无 DELETE/TRUNCATE（小赵 Q2）-- @pg-only
-- 清理只能经 purge_expired()：属主 wms_purge_owner（非超级用户、NOLOGIN，只有这两张表的 SELECT/DELETE），
-- 调用方 wms_cleaner 只有 EXECUTE，对表没有任何权限；删除条件写死在函数里，不接受参数
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_purge_owner') THEN CREATE ROLE wms_purge_owner NOLOGIN NOSUPERUSER NOINHERIT; END IF; END $$;  -- @pg-only
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_cleaner') THEN CREATE ROLE wms_cleaner NOLOGIN NOSUPERUSER; END IF; END $$;  -- @pg-only
GRANT USAGE ON SCHEMA public TO wms_purge_owner, wms_cleaner;                          -- @pg-only
GRANT SELECT, DELETE ON idempotency_record, outbox_event TO wms_purge_owner;           -- @pg-only
CREATE FUNCTION public.purge_expired(OUT idem_deleted BIGINT, OUT outbox_deleted BIGINT)  -- @pg-only
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$          -- @pg-only
BEGIN                                                                                  -- @pg-only
    DELETE FROM public.idempotency_record WHERE expires_at < (now() AT TIME ZONE 'UTC');  -- @pg-only
    GET DIAGNOSTICS idem_deleted = ROW_COUNT;                                          -- @pg-only
    DELETE FROM public.outbox_event WHERE status = 'SENT' AND sent_at < (now() AT TIME ZONE 'UTC') - interval '7 days';  -- @pg-only
    GET DIAGNOSTICS outbox_deleted = ROW_COUNT;                                        -- @pg-only
END $$;                                                                                -- @pg-only
ALTER FUNCTION public.purge_expired() OWNER TO wms_purge_owner;                        -- @pg-only
REVOKE ALL ON FUNCTION public.purge_expired() FROM PUBLIC;                             -- @pg-only
GRANT EXECUTE ON FUNCTION public.purge_expired() TO wms_cleaner;                       -- @pg-only
GRANT SELECT, INSERT ON audit_log, stock_snapshot_daily TO wms_app;                    -- 只追加 -- @pg-only
GRANT SELECT ON v_stock_available TO wms_app;                                          -- @pg-only

-- =============================================================================
-- 加工中心（docs/17，小钱）：BOM / 出成率、加工单、原料领用（含 LIVE_TANK 池位）、报工产出、损耗、批次追溯、冲回
--   数量一律 *_qty_milli（00 §6.3）；出成率、容差一律万分比整数 *_bp（10000 = 100%）。
--   领用的原料移到加工中心库位并挂 stock_hold(hold_type=PROCESSING)，系统锁、不可用、不可手工解冻（40933）。
-- =============================================================================

CREATE TABLE process_bom (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(32)  NOT NULL,           -- BOM 编码，同编码多版本
    bom_version         INTEGER      NOT NULL,
    name                VARCHAR(128) NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',   -- DRAFT/ACTIVE/RETIRED
    yield_min_bp        INTEGER      NOT NULL,           -- 成品出成率下限（成品净重 / 原料净领用）
    yield_max_bp        INTEGER      NOT NULL,           -- 上限；超出上下限不拦，转 PROCESS_YIELD_DEVIATION 审批
    balance_tol_bp      INTEGER      NOT NULL DEFAULT 50,  -- 守恒容差（称重误差），万分比；超出 42218
    created_by          BIGINT       NOT NULL,
    activated_at        TIMESTAMP,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_pbom UNIQUE (warehouse_id, code, bom_version),
    CONSTRAINT ck_pbom_status CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    CONSTRAINT ck_pbom_ver    CHECK (bom_version >= 1),
    CONSTRAINT ck_pbom_yield  CHECK (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000),
    CONSTRAINT ck_pbom_tol    CHECK (balance_tol_bp >= 0 AND balance_tol_bp <= 1000),
    CONSTRAINT ck_pbom_act    CHECK (status = 'DRAFT' OR activated_at IS NOT NULL)
);
-- 同仓同编码只能有一个 ACTIVE 版本
CREATE UNIQUE INDEX uq_pbom_active ON process_bom(warehouse_id, code) WHERE status = 'ACTIVE';

CREATE TABLE process_bom_line (
    id                  BIGINT       PRIMARY KEY,
    bom_id              BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    line_role           VARCHAR(16)  NOT NULL,           -- INPUT 原料 / FINISHED 成品 / BYPRODUCT 副产品
    sku_id              BIGINT       NOT NULL,
    std_qty_milli       BIGINT       NOT NULL,           -- 每批标准量（按 base_uom 的 1/1000）
    CONSTRAINT uq_pboml UNIQUE (bom_id, line_no),
    CONSTRAINT uq_pboml_sku UNIQUE (bom_id, line_role, sku_id),
    CONSTRAINT ck_pboml_role CHECK (line_role IN ('INPUT','FINISHED','BYPRODUCT')),
    CONSTRAINT ck_pboml_qty  CHECK (std_qty_milli > 0 AND std_qty_milli = CAST(std_qty_milli AS BIGINT) AND line_no >= 1)
);
-- BOM 生效后只读：改配方 = 新版本（加工单下达时另有快照，双保险）
CREATE FUNCTION trg_pboml_frozen() RETURNS trigger LANGUAGE plpgsql AS $$                                  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF EXISTS (SELECT 1 FROM process_bom b WHERE b.id = COALESCE(NEW.bom_id, OLD.bom_id) AND b.status <> 'DRAFT')   -- @pg-only
       OR (TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM process_bom b WHERE b.id = OLD.bom_id AND b.status <> 'DRAFT')) THEN  -- @pg-only
        RAISE EXCEPTION 'bom_frozen' USING ERRCODE = '23514';                                                -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN COALESCE(NEW, OLD);                                                                                -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_pboml_frozen BEFORE INSERT OR UPDATE OR DELETE ON process_bom_line FOR EACH ROW EXECUTE FUNCTION trg_pboml_frozen();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_i BEFORE INSERT ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = NEW.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_u BEFORE UPDATE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id IN (OLD.bom_id, NEW.bom_id) AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_d BEFORE DELETE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = OLD.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;

CREATE TABLE process_order (
    id                      BIGINT       PRIMARY KEY,
    warehouse_id            BIGINT       NOT NULL,
    code                    VARCHAR(48)  NOT NULL,       -- PRC-{仓}-{节点}-{作业日}-{序号}（00 §6.2）
    work_date               DATE         NOT NULL,
    bom_id                  BIGINT       NOT NULL,
    process_location_id     BIGINT       NOT NULL,       -- 加工中心库位（location_type=PROCESS，第 1 篇待加）
    planned_input_qty_milli BIGINT       NOT NULL,
    status                  VARCHAR(20)  NOT NULL DEFAULT 'CREATED',  -- CREATED/RELEASED/IN_PROGRESS/PENDING_APPROVAL/COMPLETED/CANCELLED
    -- 下达快照（Q1 待确认）：下达时从 BOM 复制，之后只读（trg_prc_snapshot）
    bom_code                VARCHAR(32),
    bom_version             INTEGER,
    bom_snapshot            TEXT,                        -- BOM 行 JSON
    yield_min_bp            INTEGER,
    yield_max_bp            INTEGER,
    balance_tol_bp          INTEGER,
    -- 汇总（服务层与明细同事务条件更新）
    issued_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 累计领用
    reversed_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 累计领用冲回
    output_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 成品净额（扣除产出冲回）
    byproduct_qty_milli     BIGINT       NOT NULL DEFAULT 0,  -- 副产品净额
    loss_qty_milli          BIGINT       NOT NULL DEFAULT 0,  -- 损耗净额（含容差内称重差）
    yield_bp                INTEGER,                      -- 完工时计算 = output * 10000 / (issued - reversed)，整除
    approval_no             VARCHAR(40),                  -- PROCESS_YIELD_DEVIATION 审批单号
    created_by              BIGINT       NOT NULL,
    released_at             TIMESTAMP,
    completed_at            TIMESTAMP,
    cancel_reason           VARCHAR(128),
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prc_code UNIQUE (code),
    CONSTRAINT ck_prc_status CHECK (status IN ('CREATED','RELEASED','IN_PROGRESS','PENDING_APPROVAL','COMPLETED','CANCELLED')),
    CONSTRAINT ck_prc_int CHECK (
        planned_input_qty_milli = CAST(planned_input_qty_milli AS BIGINT)
        AND issued_qty_milli = CAST(issued_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
        AND output_qty_milli = CAST(output_qty_milli AS BIGINT) AND byproduct_qty_milli = CAST(byproduct_qty_milli AS BIGINT)
        AND loss_qty_milli = CAST(loss_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_prc_nonneg CHECK (
        planned_input_qty_milli > 0 AND issued_qty_milli >= 0 AND reversed_qty_milli >= 0
        AND output_qty_milli >= 0 AND byproduct_qty_milli >= 0 AND loss_qty_milli >= 0
    ),
    -- 冲回量不能超过领用量（服务层 0 行 → 42214 OVER_REVERSE）
    CONSTRAINT ck_prc_reverse CHECK (reversed_qty_milli <= issued_qty_milli),
    -- 产出不能超过净领用（进行中也成立；完工时再要求严格相等）
    CONSTRAINT ck_prc_cap CHECK (reversed_qty_milli > issued_qty_milli   -- 超冲回交给 ck_prc_reverse 报，避免两条同时报
        OR output_qty_milli + byproduct_qty_milli + loss_qty_milli <= issued_qty_milli - reversed_qty_milli),
    -- 下达后必须带快照
    CONSTRAINT ck_prc_snapshot CHECK (
        status = 'CREATED'
        OR (status = 'CANCELLED' AND released_at IS NULL)
        OR (released_at IS NOT NULL AND bom_code IS NOT NULL AND bom_version IS NOT NULL AND bom_snapshot IS NOT NULL
            AND yield_min_bp IS NOT NULL AND yield_max_bp IS NOT NULL AND balance_tol_bp IS NOT NULL)
    ),
    CONSTRAINT ck_prc_yrange CHECK (yield_min_bp IS NULL OR (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000)),
    -- 守恒：完工（含待审批）时 净领用 = 成品 + 副产 + 损耗，严格相等（容差内的称重差已由服务层记入损耗）
    CONSTRAINT ck_prc_balance CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (issued_qty_milli - reversed_qty_milli > 0
            AND issued_qty_milli - reversed_qty_milli = output_qty_milli + byproduct_qty_milli + loss_qty_milli)
    ),
    -- 出成率由净额算出，不信任应用传值
    CONSTRAINT ck_prc_yield CHECK (
        (status NOT IN ('PENDING_APPROVAL','COMPLETED') AND yield_bp IS NULL)
        OR (status IN ('PENDING_APPROVAL','COMPLETED') AND issued_qty_milli - reversed_qty_milli > 0
            AND yield_bp = output_qty_milli * 10000 / (issued_qty_milli - reversed_qty_milli))
    ),
    -- 出成率偏差：越界 ⇔ 必须有审批单；PENDING_APPROVAL 只给越界单；界内单不挂审批
    CONSTRAINT ck_prc_dev CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (yield_bp BETWEEN yield_min_bp AND yield_max_bp AND approval_no IS NULL AND status = 'COMPLETED')
        OR ((yield_bp < yield_min_bp OR yield_bp > yield_max_bp) AND approval_no IS NOT NULL)
    ),
    CONSTRAINT ck_prc_done CHECK ((status = 'COMPLETED') = (completed_at IS NOT NULL)),
    -- 撤销：领用全部冲回、产出全部冲回
    CONSTRAINT ck_prc_cancel CHECK (
        status <> 'CANCELLED'
        OR (issued_qty_milli = reversed_qty_milli AND output_qty_milli = 0 AND byproduct_qty_milli = 0 AND loss_qty_milli = 0
            AND cancel_reason IS NOT NULL AND length(cancel_reason) > 0)
    ),
    -- 审批单号格式同 00 / 02（APR-{仓库编码}-{yyyyMMdd}-{6 位}）
    CONSTRAINT ck_prc_apr CHECK (approval_no IS NULL OR approval_no ~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$')  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_prc_apr CHECK (approval_no IS NULL OR (
-- @sqlite-only         length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
-- @sqlite-only         AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only         AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only         AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
-- @sqlite-only         AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]')))
);
CREATE INDEX ix_prc_status ON process_order(warehouse_id, status, work_date);
-- 一张加工单只有一个待审批的偏差审批（审批单号全局唯一）
CREATE UNIQUE INDEX uq_prc_apr ON process_order(approval_no) WHERE approval_no IS NOT NULL;
-- 快照只读、终态只读、汇总只增（冲回走 reversed_*/净额减少，见 §6.5）
CREATE FUNCTION trg_prc_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$                                  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF (OLD.status <> 'CREATED' AND (NEW.bom_id IS DISTINCT FROM OLD.bom_id OR NEW.bom_code IS DISTINCT FROM OLD.bom_code  -- @pg-only
         OR NEW.bom_version IS DISTINCT FROM OLD.bom_version OR NEW.bom_snapshot IS DISTINCT FROM OLD.bom_snapshot      -- @pg-only
         OR NEW.yield_min_bp IS DISTINCT FROM OLD.yield_min_bp OR NEW.yield_max_bp IS DISTINCT FROM OLD.yield_max_bp    -- @pg-only
         OR NEW.balance_tol_bp IS DISTINCT FROM OLD.balance_tol_bp OR NEW.released_at IS DISTINCT FROM OLD.released_at))  -- @pg-only
       OR OLD.status IN ('COMPLETED','CANCELLED')                                                             -- @pg-only
       OR NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id            -- @pg-only
       OR NEW.issued_qty_milli < OLD.issued_qty_milli OR NEW.reversed_qty_milli < OLD.reversed_qty_milli THEN  -- @pg-only
        RAISE EXCEPTION 'process_order_frozen' USING ERRCODE = '23514';                                      -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prc_snapshot BEFORE UPDATE ON process_order FOR EACH ROW EXECUTE FUNCTION trg_prc_snapshot();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prc_snapshot BEFORE UPDATE ON process_order
-- @sqlite-only WHEN (OLD.status <> 'CREATED' AND (NEW.bom_id IS NOT OLD.bom_id OR NEW.bom_code IS NOT OLD.bom_code
-- @sqlite-only        OR NEW.bom_version IS NOT OLD.bom_version OR NEW.bom_snapshot IS NOT OLD.bom_snapshot
-- @sqlite-only        OR NEW.yield_min_bp IS NOT OLD.yield_min_bp OR NEW.yield_max_bp IS NOT OLD.yield_max_bp
-- @sqlite-only        OR NEW.balance_tol_bp IS NOT OLD.balance_tol_bp OR NEW.released_at IS NOT OLD.released_at))
-- @sqlite-only   OR OLD.status IN ('COMPLETED','CANCELLED')
-- @sqlite-only   OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
-- @sqlite-only   OR NEW.issued_qty_milli < OLD.issued_qty_milli OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_order_frozen'); END;

-- 原料领用：一行 = 从一个来源 stock 行领一个批次；原料移到加工中心库位并挂 PROCESSING 冻结
CREATE TABLE process_issue (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,           -- PRCI:{process_order_id}:{issue_client_id}（PDA 生成的 UUID），与 stock_hold.op_key 相同
    src_location_id     BIGINT       NOT NULL,
    src_location_type   VARCHAR(16)  NOT NULL,           -- 冗余来源库位类型；LIVE_TANK = 活鲜池（第 18 篇）
    src_stock_id        BIGINT       NOT NULL,
    pc_stock_id         BIGINT       NOT NULL,           -- 加工中心库位上的 stock 行
    hold_id             BIGINT       NOT NULL,           -- stock_hold(PROCESSING).id
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    lot_expiry_date     DATE         NOT NULL,           -- 冗余原料批次到期日（算成品到期上限用）
    issue_qty_milli     BIGINT       NOT NULL,           -- 净重
    issue_count         INTEGER,                         -- 尾数：LIVE_TANK 必填（第 18 篇双计量）
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0,
    issued_by           BIGINT       NOT NULL,
    issued_at           TIMESTAMP    NOT NULL DEFAULT now(),
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_prci UNIQUE (process_order_id, line_no),
    CONSTRAINT uq_prci_op UNIQUE (op_key),
    CONSTRAINT uq_prci_hold UNIQUE (hold_id),
    CONSTRAINT ck_prci_int CHECK (issue_qty_milli = CAST(issue_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prci_qty CHECK (issue_qty_milli > 0 AND reversed_qty_milli >= 0 AND line_no >= 1),
    CONSTRAINT ck_prci_reverse CHECK (reversed_qty_milli <= issue_qty_milli),   -- 42214 OVER_REVERSE
    CONSTRAINT ck_prci_op CHECK (op_key LIKE 'PRCI:%'),
    CONSTRAINT ck_prci_live CHECK (
        (src_location_type = 'LIVE_TANK' AND issue_count IS NOT NULL AND issue_count > 0)
        OR (src_location_type <> 'LIVE_TANK' AND issue_count IS NULL)
    )
);
CREATE INDEX ix_prci_lot ON process_issue(lot_id);

-- 报工（一次提交 = 一行）：业务键 (process_order_id, report_client_id)，长期保留；只缓存成功结果（Q4 待确认）
CREATE TABLE process_report (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_client_id    VARCHAR(36)  NOT NULL,           -- 客户端 UUID
    request_hash        VARCHAR(64)  NOT NULL,           -- 规范化请求体 SHA-256；同键不同 hash → 40910 key_type=PROCESS_REPORT
    report_seq          INTEGER      NOT NULL,           -- 服务端分配，单内从 1 递增
    is_final            BOOLEAN      NOT NULL DEFAULT false,  -- 完工报工
    response_http       INTEGER      NOT NULL,
    response            TEXT         NOT NULL,           -- 首次响应体，重放原样返回
    reported_by         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prcr_client UNIQUE (process_order_id, report_client_id),
    CONSTRAINT uq_prcr_seq UNIQUE (process_order_id, report_seq),
    CONSTRAINT ck_prcr_client CHECK (length(report_client_id) = 36 AND substr(report_client_id, 9, 1) = '-' AND substr(report_client_id, 14, 1) = '-'
                                     AND substr(report_client_id, 19, 1) = '-' AND substr(report_client_id, 24, 1) = '-'),
    CONSTRAINT ck_prcr_hash CHECK (length(request_hash) = 64),
    CONSTRAINT ck_prcr_seq  CHECK (report_seq >= 1),
    CONSTRAINT ck_prcr_http CHECK (response_http IN (200, 202))   -- 202 = 完工且出成率越界、已转审批
);
-- 完工报工可能不止一条：偏差审批驳回后单据回到 IN_PROGRESS，冲回/补报后再次完工（§5.1）

-- 产出明细：成品 / 副产品（新批次入库）/ 损耗（第 9 篇报损单，来源 PROCESS_LOSS）
CREATE TABLE process_output (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_id           BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    output_role         VARCHAR(16)  NOT NULL,           -- FINISHED/BYPRODUCT/LOSS
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT,                          -- 新建批次；LOSS 为空
    to_location_id      BIGINT,                          -- 入库库位；LOSS 为空
    gross_qty_milli     BIGINT       NOT NULL,           -- 毛重（称重原值留痕）
    tare_qty_milli      BIGINT       NOT NULL DEFAULT 0, -- 皮重
    qty_milli           BIGINT       NOT NULL,           -- 净重 = 毛重 − 皮重
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0,
    processed_at        TIMESTAMP    NOT NULL,           -- 加工完成时刻（UTC），成品保质期起算
    expiry_date         DATE,                            -- = min(加工日 + shelf_life_days, earliest_raw_expiry)
    sell_deadline       DATE,                            -- = min(加工日 + sell_days, expiry_date)；sku.sell_days 为空时为空
    earliest_raw_expiry DATE,                            -- 本单净领用原料批次中最早到期日
    scrap_order_id      BIGINT,                          -- LOSS：第 9 篇报损单
    loss_reason         VARCHAR(24),                     -- LOSS：TRIM 修整 / DRIP 滴水 / WEIGH_DIFF 容差内称重差 / DEFECT 次品
    CONSTRAINT uq_prco UNIQUE (report_id, line_no),
    CONSTRAINT ck_prco_role CHECK (output_role IN ('FINISHED','BYPRODUCT','LOSS')),
    CONSTRAINT ck_prco_int CHECK (gross_qty_milli = CAST(gross_qty_milli AS BIGINT) AND tare_qty_milli = CAST(tare_qty_milli AS BIGINT)
                                  AND qty_milli = CAST(qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prco_net CHECK (qty_milli > 0 AND tare_qty_milli >= 0 AND qty_milli = gross_qty_milli - tare_qty_milli),
    CONSTRAINT ck_prco_reverse CHECK (reversed_qty_milli >= 0 AND reversed_qty_milli <= qty_milli),
    CONSTRAINT ck_prco_kind CHECK (
        (output_role IN ('FINISHED','BYPRODUCT') AND lot_id IS NOT NULL AND to_location_id IS NOT NULL
             AND expiry_date IS NOT NULL AND earliest_raw_expiry IS NOT NULL AND scrap_order_id IS NULL AND loss_reason IS NULL)
        OR (output_role = 'LOSS' AND lot_id IS NULL AND to_location_id IS NULL AND expiry_date IS NULL AND sell_deadline IS NULL
             AND scrap_order_id IS NOT NULL AND loss_reason IN ('TRIM','DRIP','WEIGH_DIFF','DEFECT'))
    ),
    -- 保质期按加工时间重算，但不能晚于最早原料到期日；可售截止不晚于到期日
    CONSTRAINT ck_prco_expiry CHECK (expiry_date IS NULL OR expiry_date <= earliest_raw_expiry),
    CONSTRAINT ck_prco_sell   CHECK (sell_deadline IS NULL OR (expiry_date IS NOT NULL AND sell_deadline <= expiry_date))
);
CREATE INDEX ix_prco_order ON process_output(process_order_id, output_role);
CREATE UNIQUE INDEX uq_prco_lot ON process_output(lot_id) WHERE lot_id IS NOT NULL;   -- 一个产出行一个新批次，批次不复用

-- 批次追溯：成品/副产批次 ↔ 原料批次，多对多；召回双向查（§6.6，递归 CTE 支持多级加工）
CREATE TABLE process_lot_trace (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    output_id           BIGINT       NOT NULL,
    output_lot_id       BIGINT       NOT NULL,
    issue_id            BIGINT       NOT NULL,
    raw_lot_id          BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_plt UNIQUE (output_id, issue_id),
    CONSTRAINT ck_plt_self CHECK (output_lot_id <> raw_lot_id)
);
CREATE INDEX ix_plt_out ON process_lot_trace(output_lot_id, raw_lot_id);
CREATE INDEX ix_plt_raw ON process_lot_trace(raw_lot_id, output_lot_id);

-- 冲回记录：领用冲回（原料退回来源库位）/ 产出冲回（成品出库存、未出库才可）；只追加
CREATE TABLE process_reversal (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,           -- PRCR:{reversal_client_id}
    reversal_type       VARCHAR(16)  NOT NULL,           -- ISSUE/OUTPUT
    issue_id            BIGINT,
    output_id           BIGINT,
    qty_milli           BIGINT       NOT NULL,
    reason              VARCHAR(128) NOT NULL,
    operator_id         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prcv_op UNIQUE (op_key),
    CONSTRAINT ck_prcv_type CHECK (
        (reversal_type = 'ISSUE' AND issue_id IS NOT NULL AND output_id IS NULL)
        OR (reversal_type = 'OUTPUT' AND output_id IS NOT NULL AND issue_id IS NULL)
    ),
    CONSTRAINT ck_prcv_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT) AND length(reason) > 0)
);
CREATE INDEX ix_prcv_order ON process_reversal(process_order_id, created_at);

-- 报工、追溯、冲回只追加
CREATE TRIGGER trg_prcr_append_only BEFORE UPDATE OR DELETE ON process_report    FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_plt_append_only  BEFORE UPDATE OR DELETE ON process_lot_trace FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_prcv_append_only BEFORE UPDATE OR DELETE ON process_reversal  FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prcr_no_update BEFORE UPDATE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
-- @sqlite-only CREATE TRIGGER trg_prcr_no_delete BEFORE DELETE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
-- @sqlite-only CREATE TRIGGER trg_plt_no_update  BEFORE UPDATE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
-- @sqlite-only CREATE TRIGGER trg_plt_no_delete  BEFORE DELETE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
-- @sqlite-only CREATE TRIGGER trg_prcv_no_update BEFORE UPDATE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
-- @sqlite-only CREATE TRIGGER trg_prcv_no_delete BEFORE DELETE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
-- 产出行：关键列建单后只读，只允许 reversed_qty_milli 只增
CREATE FUNCTION trg_prco_immutable() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'DELETE' OR NEW.qty_milli IS DISTINCT FROM OLD.qty_milli OR NEW.gross_qty_milli IS DISTINCT FROM OLD.gross_qty_milli  -- @pg-only
       OR NEW.tare_qty_milli IS DISTINCT FROM OLD.tare_qty_milli OR NEW.lot_id IS DISTINCT FROM OLD.lot_id     -- @pg-only
       OR NEW.output_role IS DISTINCT FROM OLD.output_role OR NEW.expiry_date IS DISTINCT FROM OLD.expiry_date  -- @pg-only
       OR NEW.sell_deadline IS DISTINCT FROM OLD.sell_deadline OR NEW.sku_id IS DISTINCT FROM OLD.sku_id        -- @pg-only
       OR NEW.reversed_qty_milli < OLD.reversed_qty_milli THEN                                                -- @pg-only
        RAISE EXCEPTION 'process_output_immutable' USING ERRCODE = '23514';                                  -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prco_immutable BEFORE UPDATE OR DELETE ON process_output FOR EACH ROW EXECUTE FUNCTION trg_prco_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prco_immutable BEFORE UPDATE ON process_output
-- @sqlite-only WHEN NEW.qty_milli IS NOT OLD.qty_milli OR NEW.gross_qty_milli IS NOT OLD.gross_qty_milli OR NEW.tare_qty_milli IS NOT OLD.tare_qty_milli
-- @sqlite-only   OR NEW.lot_id IS NOT OLD.lot_id OR NEW.output_role IS NOT OLD.output_role OR NEW.expiry_date IS NOT OLD.expiry_date
-- @sqlite-only   OR NEW.sell_deadline IS NOT OLD.sell_deadline OR NEW.sku_id IS NOT OLD.sku_id OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_prco_no_delete BEFORE DELETE ON process_output BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;

GRANT SELECT, INSERT, UPDATE ON process_bom, process_bom_line, process_order, process_issue, process_output TO wms_app;   -- @pg-only
GRANT SELECT, INSERT ON process_report, process_lot_trace, process_reversal TO wms_app;                                    -- 只追加 -- @pg-only
