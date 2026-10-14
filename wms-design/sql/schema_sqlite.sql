-- 本文件由 sql/verify_sqlite.py 从 schema_postgres.sql 机械生成，请勿手改。
-- 翻译产生的改动共 3 类：
--   1. 删除 1 条 COMMENT ON（SQLite 无该语法，注释降级到行内）
--   2. 34 处 DEFAULT now() → DEFAULT (datetime('now'))（表达式默认值需括号）
--   3. 去掉显式 BEGIN/COMMIT（由 executescript 管理）

-- =============================================================================
--  生鲜配送中心 WMS —— 核心表结构（PostgreSQL 16 方言）
--
--  说明：
--  1. 本文件是《WMS详细设计说明书》§3 的可执行落地版，覆盖库存主链路的 12 张表。
--  2. 生产建表走 Alembic；本文件用于评审、文档附件和快速验证索引设计。
--  3. SQLite 差异见每张表末尾的 "-- [SQLite]" 注释，以及 §3.1 的十条规则。
--  4. 所有主键由应用层生成（号段），不用数据库自增 —— 见 D1/R1。
-- =============================================================================



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
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    deleted_at          TIMESTAMP,
    CONSTRAINT uq_warehouse_code UNIQUE (code)
);



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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    created_at          TIMESTAMP     NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP     NOT NULL DEFAULT (datetime('now')),
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
    created_at                  TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at                  TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    production_date     TIMESTAMP,
    expiry_date         TIMESTAMP    NOT NULL,          -- FEFO 排序键
    receive_date        TIMESTAMP    NOT NULL,
    supplier_id         BIGINT,
    origin_batch        VARCHAR(64),
    quality_status      VARCHAR(16)  NOT NULL DEFAULT 'QUALIFIED',
    remaining_life_days SMALLINT     NOT NULL DEFAULT 9999,  -- 冗余，定时刷新
    cert_no             VARCHAR(64),                    -- 检疫合格证等
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_lot UNIQUE (sku_id, lot_code, expiry_date)
);
CREATE INDEX ix_lot_expiry ON lot(sku_id, expiry_date) WHERE quality_status = 'QUALIFIED';
CREATE INDEX ix_lot_aging  ON lot(remaining_life_days, sku_id);
-- [SQLite] 两个部分索引均支持；ix_lot_aging 支撑效期预警列表

-- -----------------------------------------------------------------------------
-- 库存（核心）
-- -----------------------------------------------------------------------------

CREATE TABLE stock (
    id                BIGINT          PRIMARY KEY,
    warehouse_id      BIGINT          NOT NULL,
    location_id       BIGINT          NOT NULL,
    sku_id            BIGINT          NOT NULL,
    lot_id            BIGINT          NOT NULL,
    container_id      BIGINT          NOT NULL DEFAULT 0,   -- 0 = 散货无容器（哨兵值，见下）
    uom               VARCHAR(16)     NOT NULL,

    on_hand           NUMERIC(14,3)   NOT NULL DEFAULT 0,
    allocated         NUMERIC(14,3)   NOT NULL DEFAULT 0,
    reserved          NUMERIC(14,3)   NOT NULL DEFAULT 0,
    quality_hold      NUMERIC(14,3)   NOT NULL DEFAULT 0,
    frozen            NUMERIC(14,3)   NOT NULL DEFAULT 0,

    version           BIGINT          NOT NULL DEFAULT 0,
    created_at        TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at        TIMESTAMP       NOT NULL DEFAULT (datetime('now')),

    CONSTRAINT uq_stock_dim UNIQUE (warehouse_id, location_id, sku_id, lot_id, container_id),
    -- ⚠ container_id 必须是 NOT NULL DEFAULT 0 而不是可空：
    --   唯一约束里含 NULL 列时，PG 与 SQLite 都把 NULL 视为互不相等，
    --   实测两引擎都允许同一 (wh,loc,sku,lot) 插入多行 NULL 容器行 → 不变量 I6 失效。
    --   用 0 作"无容器"哨兵值是唯一在两个引擎上都成立的写法（R1–R10 交集原则）。
    CONSTRAINT ck_stock_container CHECK (container_id >= 0),
    -- 数据库层兜底不变量：即使 Service 写错，也不会出现负数或超占
    CONSTRAINT ck_stock_nonneg CHECK (
        on_hand >= 0 AND allocated >= 0 AND reserved >= 0
        AND quality_hold >= 0 AND frozen >= 0
        AND (allocated + reserved + quality_hold + frozen) <= on_hand
    )
);
CREATE INDEX ix_stock_sku_avail ON stock(sku_id, warehouse_id, lot_id) WHERE on_hand > 0;
CREATE INDEX ix_stock_loc       ON stock(location_id, sku_id);
CREATE INDEX ix_stock_wh        ON stock(warehouse_id, sku_id);
-- [SQLite] CHECK 约束 SQLite 同样支持且强制执行 —— 这是双库交集内，务必保留
-- [SQLite] 部分索引支持；NUMERIC(14,3) 亲和性为 NUM，需应用层用整数"厘"存取（R2）

CREATE TABLE stock_reservation (
    id                BIGINT          PRIMARY KEY,
    stock_id          BIGINT          NOT NULL,
    source_type       VARCHAR(24)     NOT NULL,   -- OUTBOUND_LINE/WAVE/COUNT/MANUAL
    source_id         BIGINT          NOT NULL,
    source_line_id    BIGINT,
    quantity          NUMERIC(14,3)   NOT NULL,
    consumed          NUMERIC(14,3)   NOT NULL DEFAULT 0,
    status            VARCHAR(16)     NOT NULL DEFAULT 'RESERVED',  -- RESERVED/CONSUMED/RELEASED
    expires_at        TIMESTAMP,                  -- 超时自动释放，防死锁
    created_at        TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at        TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_res CHECK (consumed >= 0 AND consumed <= quantity)
);
CREATE INDEX ix_res_stock  ON stock_reservation(stock_id, status);
CREATE INDEX ix_res_source ON stock_reservation(source_type, source_id);
CREATE INDEX ix_res_exp    ON stock_reservation(expires_at) WHERE status = 'RESERVED';

CREATE TABLE stock_movement (
    id                  BIGINT          PRIMARY KEY,
    biz_no              VARCHAR(64)     NOT NULL,
    biz_type            VARCHAR(24)     NOT NULL,
    direction           SMALLINT        NOT NULL,   -- 1 入 / -1 出 / 0 移库或事件
    warehouse_id        BIGINT          NOT NULL,
    location_id         BIGINT          NOT NULL,
    from_location_id    BIGINT,
    sku_id              BIGINT          NOT NULL,
    lot_id              BIGINT          NOT NULL,
    quantity            NUMERIC(14,3)   NOT NULL,
    on_hand_before      NUMERIC(14,3)   NOT NULL,
    on_hand_after       NUMERIC(14,3)   NOT NULL,
    operator_id         BIGINT,
    device              VARCHAR(32),
    occurred_at         TIMESTAMP       NOT NULL,
    cost_amount         BIGINT,                     -- 分
    idempotency_key     VARCHAR(80)     NOT NULL,
    remark              VARCHAR(256),
    CONSTRAINT uq_mv_idem UNIQUE (idempotency_key),
    CONSTRAINT ck_mv_pos    CHECK (quantity > 0),
    CONSTRAINT ck_mv_balance CHECK (on_hand_after = on_hand_before + quantity * direction)
);
CREATE INDEX ix_mv_biz      ON stock_movement(biz_type, biz_no);
CREATE INDEX ix_mv_time     ON stock_movement(warehouse_id, occurred_at DESC);
CREATE INDEX ix_mv_sku_time ON stock_movement(sku_id, occurred_at DESC);
-- 这张表只 INSERT，REVOKE UPDATE/DELETE。I5 不变量由 ck_mv_balance 在库层兜底。
-- 数据量大：PG 侧按月 RANGE 分区；SQLite 侧按月归档导出。

CREATE TABLE stock_snapshot_daily (
    work_date       DATE            NOT NULL,
    warehouse_id    BIGINT          NOT NULL,
    sku_id          BIGINT          NOT NULL,
    lot_id          BIGINT          NOT NULL,
    on_hand         NUMERIC(14,3)   NOT NULL,
    allocated       NUMERIC(14,3)   NOT NULL,
    reserved        NUMERIC(14,3)   NOT NULL,
    quality_hold    NUMERIC(14,3)   NOT NULL,
    cost_amount     BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (work_date, warehouse_id, sku_id, lot_id)
);

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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    production_date TIMESTAMP,
    expiry_date     TIMESTAMP,
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
    status                  VARCHAR(24)     NOT NULL,
    wave_id                 BIGINT,
    short_ship_policy       VARCHAR(16)     NOT NULL DEFAULT 'ALLOW_SHORT',
    total_qty               NUMERIC(14,3)   NOT NULL DEFAULT 0,
    allocated_qty           NUMERIC(14,3)   NOT NULL DEFAULT 0,
    picked_qty              NUMERIC(14,3)   NOT NULL DEFAULT 0,
    shipped_qty             NUMERIC(14,3)   NOT NULL DEFAULT 0,
    short_qty               NUMERIC(14,3)   NOT NULL DEFAULT 0,
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
    created_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    status_changed_at       TIMESTAMP,
    shipped_at              TIMESTAMP,
    delivered_at            TIMESTAMP,
    created_by              BIGINT,
    CONSTRAINT uq_obo_code UNIQUE (code),
    CONSTRAINT uq_obo_src  UNIQUE (source_system, source_order_no),
    CONSTRAINT ck_obo_sod  CHECK (checker_id IS NULL OR picker_id IS NULL OR picker_id <> checker_id)
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
    order_qty       NUMERIC(14,3)   NOT NULL,
    allocated_qty   NUMERIC(14,3)   NOT NULL DEFAULT 0,
    picked_qty      NUMERIC(14,3)   NOT NULL DEFAULT 0,
    shipped_qty     NUMERIC(14,3)   NOT NULL DEFAULT 0,
    short_qty       NUMERIC(14,3)   NOT NULL DEFAULT 0,
    uom             VARCHAR(16)     NOT NULL,
    unit_price      BIGINT          NOT NULL DEFAULT 0,
    amount          BIGINT          NOT NULL DEFAULT 0,
    short_reason    VARCHAR(24),
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
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    plan_qty            NUMERIC(14,3)   NOT NULL,
    plan_qty_base       NUMERIC(14,3)   NOT NULL,
    actual_qty          NUMERIC(14,3)   NOT NULL DEFAULT 0,
    uom                 VARCHAR(16)     NOT NULL,
    barcode_expected    VARCHAR(64),
    status              VARCHAR(16)     NOT NULL DEFAULT 'PENDING',
    short_reason_code   VARCHAR(24),
    scanned_at          TIMESTAMP,
    override_reason     VARCHAR(128),               -- FEFO 越权原因（RK4）
    override_by         BIGINT,
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
    quantity    NUMERIC(14,3)   NOT NULL,
    uom         VARCHAR(16)     NOT NULL,
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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_cnt_code UNIQUE (code)
);

CREATE TABLE count_line (
    id              BIGINT          PRIMARY KEY,
    count_id        BIGINT          NOT NULL,
    location_id     BIGINT          NOT NULL,
    sku_id          BIGINT          NOT NULL,
    lot_id          BIGINT          NOT NULL,
    book_qty        NUMERIC(14,3)   NOT NULL,   -- 基准账面
    movement_qty    NUMERIC(14,3)   NOT NULL DEFAULT 0, -- 期间净流水
    actual_qty      NUMERIC(14,3),              -- 实盘（NULL = 未盘）
    diff_qty        NUMERIC(14,3) GENERATED ALWAYS AS (actual_qty - book_qty - movement_qty) STORED,
    recount_qty     NUMERIC(14,3),
    status          VARCHAR(16)     NOT NULL DEFAULT 'PENDING',
    counted_by      BIGINT,
    counted_at      TIMESTAMP,
    adjust_id       BIGINT,
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
    created_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
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
    created_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    expires_at   TIMESTAMP    NOT NULL
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
    received_at     TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    next_retry_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    last_error      VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    sent_at         TIMESTAMP
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
CREATE INDEX ix_outbox_bizkey  ON outbox_event(biz_key, id);   -- 同键串行发送

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
    occurred_at     TIMESTAMP    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX ix_audit_target ON audit_log(target_type, target_id, occurred_at DESC);
CREATE INDEX ix_audit_actor  ON audit_log(actor_id, occurred_at DESC);

CREATE TABLE numbering_segment (
    biz_prefix   VARCHAR(16)  NOT NULL,
    date_key     VARCHAR(8)   NOT NULL,
    next_value   BIGINT       NOT NULL,
    step         INT          NOT NULL DEFAULT 100,
    updated_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
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
    s.on_hand,
    s.allocated,
    s.reserved,
    s.quality_hold,
    s.frozen,
    (s.on_hand - s.allocated - s.reserved - s.quality_hold - s.frozen)  AS available_qty,
    (s.on_hand - s.quality_hold - s.frozen - s.allocated)               AS pickable_qty
FROM stock s
JOIN location l ON l.id = s.location_id
JOIN zone z     ON z.id = l.zone_id
JOIN lot lo     ON lo.id = s.lot_id
WHERE s.on_hand > 0 AND l.status = 'AVAILABLE' AND l.deleted_at IS NULL;
-- FEFO 分配走这个视图，排序键在应用层（domain/fefo.py）实现，保证可单测
-- [SQLite] 视图支持一致；now() 在 SQLite 侧用 datetime('now')，故未在本文件使用


