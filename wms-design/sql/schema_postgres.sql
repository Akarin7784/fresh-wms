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
    quality_hold_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- 质检/盘点冻结（= QUALITY 冻结汇总）
    hold_qty_milli        BIGINT          NOT NULL DEFAULT 0,   -- 冻结（= MANUAL + RETURN_PENDING 冻结汇总），从 available 扣除，FEFO 分不到

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
    hold_type           VARCHAR(16)     NOT NULL,   -- QUALITY → stock.quality_hold_qty_milli；MANUAL、RETURN_PENDING → stock.hold_qty_milli
    reason_code         VARCHAR(24)     NOT NULL,   -- 见 ck_hold_reason；新增原因走迁移
    source_type         VARCHAR(24)     NOT NULL,   -- INBOUND_QC/COUNT/RETURN/EXCEPTION/MANUAL/RETURN_RECORD
    source_id           BIGINT          NOT NULL DEFAULT 0,
    op_key              VARCHAR(80)     NOT NULL,   -- RETURN_PENDING 固定为 RRH:{return_record_id}
    hold_qty_milli      BIGINT          NOT NULL,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'HELD',      -- HELD/RELEASED，由余量决定
    operator_id         BIGINT          NOT NULL,   -- 系统冻结填 0
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_hold_op UNIQUE (op_key),
    CONSTRAINT ck_hold_type CHECK (hold_type IN ('QUALITY','MANUAL','RETURN_PENDING')),
    -- 一套方案：hold_type 是大类（决定计入哪一列），reason_code 是细分原因，二者成对约束
    CONSTRAINT ck_hold_reason CHECK (
        hold_type NOT IN ('QUALITY','MANUAL','RETURN_PENDING')      -- 类型非法交给 ck_hold_type 报，避免两条约束同时报
        OR (hold_type = 'QUALITY'        AND reason_code IN ('QC_PENDING','RETURN_QC','COUNT_LOCK'))
        OR (hold_type = 'MANUAL'      AND reason_code IN ('DAMAGE','EXCEPTION','OTHER'))
        OR (hold_type = 'RETURN_PENDING' AND reason_code = 'RETURN_PENDING')
    ),
    -- RETURN_PENDING 是系统冻结：必须挂在一条待回库记录上、operator_id=0；人工解冻接口拒绝它（应用层），只能由 confirm/resolve 同事务释放
    CONSTRAINT ck_hold_return CHECK (
        hold_type <> 'RETURN_PENDING'
        OR (source_type = 'RETURN_RECORD' AND source_id > 0 AND operator_id = 0)
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
CREATE UNIQUE INDEX uq_hold_return ON stock_hold(source_id) WHERE source_type = 'RETURN_RECORD';
-- ↑ 一条待回库记录最多一条 RETURN_PENDING 冻结（重复拒收复用已有记录，不会重复冻结）
-- 原文档 §4.2"冻结记 stock_freeze"在此落地为 stock_hold，使 quality_hold/frozen 与 allocated/reserved 一样可对账（I3）

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
    CONSTRAINT ck_mv_opening CHECK (biz_type <> 'OPENING' OR (direction = 1 AND stock_seq = 1 AND on_hand_before_qty_milli = 0))
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
    )
);
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
    check_code              VARCHAR(16)     NOT NULL,   -- I3a/I3b/I3c/I3d/I4/I5/SNAP
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
    CONSTRAINT ck_recon_status CHECK (status IN ('OPEN','ACKED','RESOLVED'))
);
CREATE INDEX ix_recon_open ON stock_recon_alert(warehouse_id, status, detected_at DESC);
CREATE UNIQUE INDEX uq_recon_open ON stock_recon_alert(check_code, warehouse_id, stock_id) WHERE status <> 'RESOLVED';
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
    source_hash             VARCHAR(64)     NOT NULL DEFAULT '',  -- 上游单据内容摘要，同号不同 hash → 40910（04 I1）
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
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP       NOT NULL DEFAULT now(),
    status_changed_at       TIMESTAMP,
    shipped_at              TIMESTAMP,
    delivered_at            TIMESTAMP,
    created_by              BIGINT,
    CONSTRAINT uq_obo_code UNIQUE (code),
    CONSTRAINT uq_obo_src  UNIQUE (source_system, source_order_no),
    CONSTRAINT ck_obo_sod  CHECK (checker_id IS NULL OR picker_id IS NULL OR picker_id <> checker_id),
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
    order_qty       NUMERIC(14,3)   NOT NULL,
    allocated_qty   NUMERIC(14,3)   NOT NULL DEFAULT 0,
    picked_qty      NUMERIC(14,3)   NOT NULL DEFAULT 0,
    shipped_qty     NUMERIC(14,3)   NOT NULL DEFAULT 0,
    short_qty       NUMERIC(14,3)   NOT NULL DEFAULT 0,
    uom             VARCHAR(16)     NOT NULL,
    unit_price      BIGINT          NOT NULL DEFAULT 0,
    amount          BIGINT          NOT NULL DEFAULT 0,
    short_reason    VARCHAR(24),
    alloc_round     INT             NOT NULL DEFAULT 0,   -- 每次重新分配 +1，进入占用幂等键（04 B1）
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

-- 第 11 篇 集成：上游入站推送日志（只追加，部署在中心侧；保留期 ≥ 全量备份周期，默认 7 天）。
-- 每次推送都记一行（含重推），供 00 §9.1 故障恢复按时间窗对账；对不上的进第 10 篇异常队列 FAILOVER_GAP。
CREATE TABLE upstream_push_log (
    id              BIGINT       PRIMARY KEY,
    source_system   VARCHAR(24)  NOT NULL,
    biz_type        VARCHAR(32)  NOT NULL,
    source_order_no VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL DEFAULT 0,
    payload_sha     VARCHAR(64)  NOT NULL,   -- 规范化报文 SHA-256（= 业务侧 source_hash）
    payload         TEXT         NOT NULL,   -- 原文（脱敏后）
    received_at     TIMESTAMP    NOT NULL,   -- 中心接收时间（UTC）
    result_status   VARCHAR(16)  NOT NULL,   -- ACCEPTED/DUPLICATE/CONFLICT/REJECTED/FAILED
    result_code     VARCHAR(8)   NOT NULL DEFAULT '0',
    wms_doc_no      VARCHAR(64),
    inbound_message_id BIGINT    NOT NULL DEFAULT 0,
    retain_until    TIMESTAMP    NOT NULL,   -- ≥ received_at + max(配置保留天数, 全量备份周期)
    CONSTRAINT ck_upl_result CHECK (result_status IN ('ACCEPTED','DUPLICATE','CONFLICT','REJECTED','FAILED')),
    CONSTRAINT ck_upl_retain CHECK (retain_until > received_at)
);
CREATE INDEX ix_upl_time ON upstream_push_log(warehouse_id, received_at);
CREATE INDEX ix_upl_src  ON upstream_push_log(source_system, source_order_no, received_at);

-- -----------------------------------------------------------------------------
-- 幂等 / 集成 / 审计
-- -----------------------------------------------------------------------------

CREATE TABLE idempotency_record (
    idem_key     VARCHAR(80)  PRIMARY KEY,
    req_hash     VARCHAR(64)  NOT NULL,
    response     TEXT         NOT NULL,
    status_code  INT          NOT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT now(),
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
    received_at     TIMESTAMP    NOT NULL DEFAULT now(),
    processed_at    TIMESTAMP,
    biz_ref         VARCHAR(64),                 -- 第 11 篇：处理成功后生成的 WMS 单号
    CONSTRAINT uq_in_msg UNIQUE (source, biz_type, external_no),
    CONSTRAINT ck_in_msg_status CHECK (status IN ('RECEIVED','PROCESSING','DONE','FAILED','DEAD','REJECTED'))
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
    next_retry_at   TIMESTAMP    NOT NULL DEFAULT now(),
    last_error      VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    sent_at         TIMESTAMP,
    -- 第 11 篇：节点内单调序号（00 §9.1 边缘回传按 (node_id, seq) 严格顺序，缺口暂停）
    warehouse_id    BIGINT       NOT NULL DEFAULT 0,
    node_id         INT          NOT NULL DEFAULT 0,
    seq             BIGINT       NOT NULL DEFAULT 0,
    replay_count    SMALLINT     NOT NULL DEFAULT 0,   -- 死信人工重放次数（重放沿用原 id，下游按事件 id 幂等）
    CONSTRAINT ck_outbox_status CHECK (status IN ('PENDING','SENDING','SENT','FAILED','DEAD')),
    CONSTRAINT ck_outbox_seq    CHECK (seq >= 0)
);
CREATE UNIQUE INDEX uq_outbox_seq ON outbox_event(node_id, seq) WHERE seq > 0;
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
