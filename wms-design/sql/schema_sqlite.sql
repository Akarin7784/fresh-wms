-- 本文件由 sql/verify_sqlite.py 从 schema_postgres.sql 机械生成，请勿手改。
-- 翻译产生的改动共 4 类：
--   1. 删除 1 条 COMMENT ON（SQLite 无该语法，注释降级到行内）
--   2. 46 处 DEFAULT now() → DEFAULT (datetime('now'))（表达式默认值需括号）
--   3. 方言专属行：删除 104 行 @pg-only（分区、plpgsql 触发器、角色权限），启用 35 行 @sqlite-only（等价触发器）
--   4. 去掉显式 BEGIN/COMMIT（由 executescript 管理）

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
    production_date     DATE,                           -- 日历日（04 I5）
    expiry_date         DATE         NOT NULL,          -- FEFO 排序键；日历日，禁发期按仓库时区自然日计算（04 I5）
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
    created_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),

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
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
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
    hold_type           VARCHAR(16)     NOT NULL,   -- QUALITY、RETURN_QC → stock.quality_hold_qty_milli；MANUAL、RETURN_PENDING、SCRAP_PENDING → stock.hold_qty_milli
    reason_code         VARCHAR(24)     NOT NULL,   -- 见 ck_hold_reason；新增原因走迁移
    source_type         VARCHAR(24)     NOT NULL,   -- INBOUND_QC/QC/COUNT/RETURN/EXCEPTION/MANUAL/RETURN_RECORD/SCRAP
    source_id           BIGINT          NOT NULL DEFAULT 0,
    op_key              VARCHAR(80)     NOT NULL,   -- RETURN_PENDING 固定为 RRH:{return_record_id}；convert_hold 新建的明细固定为 CVT:{原 hold_id}
    hold_qty_milli      BIGINT          NOT NULL,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'HELD',      -- HELD/RELEASED，由余量决定
    operator_id         BIGINT          NOT NULL,   -- 系统冻结填 0
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_hold_op UNIQUE (op_key),
    CONSTRAINT ck_hold_type CHECK (hold_type IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING')),
    -- 一套方案：hold_type 是大类（决定计入哪一列），reason_code 是细分原因，二者成对约束
    CONSTRAINT ck_hold_reason CHECK (
        hold_type NOT IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING')      -- 类型非法交给 ck_hold_type 报，避免两条约束同时报
        OR (hold_type = 'QUALITY'        AND reason_code IN ('QC_PENDING','COUNT_LOCK'))
        OR (hold_type = 'RETURN_QC'      AND reason_code = 'RETURN_QC')     -- 退货待检（A3：系统冻结，只能由质检 release_qc_hold 释放）
        OR (hold_type = 'MANUAL'      AND reason_code IN ('DAMAGE','EXCEPTION','OTHER'))
        OR (hold_type = 'RETURN_PENDING' AND reason_code = 'RETURN_PENDING')
        OR (hold_type = 'SCRAP_PENDING'  AND reason_code = 'SCRAP')        -- 报损待处置（convert_hold 自 RETURN_PENDING 转入，docs/02 §7.1.1）
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
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_hr_op UNIQUE (op_key),
    CONSTRAINT fk_hr_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),   -- 小赵 S6：释放记录必须挂在真实冻结上
    CONSTRAINT ck_hr_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT))
);
CREATE INDEX ix_hr_hold ON stock_hold_release(hold_id);
CREATE TRIGGER trg_hr_no_update BEFORE UPDATE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
CREATE TRIGGER trg_hr_no_delete BEFORE DELETE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- 小赵 Q1：REPLACE 冲突删旧行不触发 DELETE 触发器，同 trg_hold_no_replace 用 BEFORE INSERT 先拦（重放撞这里，按 op_key 查回）
CREATE TRIGGER trg_hr_no_replace BEFORE INSERT ON stock_hold_release
WHEN EXISTS (SELECT 1 FROM stock_hold_release r WHERE r.id = NEW.id OR r.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;
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
    recorded_at                 TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
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
;
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
    created_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (biz_no, line_no),
    CONSTRAINT ck_sll_kind CHECK (
        (src_kind = 'DOC' AND owner_device_instance_id IS NULL)
        OR (src_kind = 'PDA' AND owner_device_instance_id IS NOT NULL)
    )
);

-- 去重表与归属表绑定：写入 key 时，该单据行的归属必须已存在、来源一致，PDA 行还必须是当前持有设备（两库各一份触发器，语义相同）
CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key
WHEN NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind
                 AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id))
BEGIN SELECT RAISE(ABORT, 'ledger_line_owner_mismatch'); END;

-- 归属行的来源不可改（小赵 C3）：src_kind / biz_no / line_no 写入后禁止 UPDATE，否则把 PDA 行改成 DOC 就能绕过互斥
CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line
WHEN NEW.src_kind IS NOT OLD.src_kind OR NEW.biz_no IS NOT OLD.biz_no OR NEW.line_no IS NOT OLD.line_no
BEGIN SELECT RAISE(ABORT, 'ledger_line_immutable'); END;

-- 冻结明细写入后不可改（小赵 N1）：只放行释放路径要写的 released_qty_milli / status / version / updated_at。
-- 类型转换只走 convert_hold（关旧建新），任何路径都不需要改 hold_type；否则先把 SCRAP_PENDING 改成 MANUAL 就能绕过 40933
-- R2：冻结明细不可删除（wms_app 本就没有 DELETE/TRUNCATE 权限；这里兜底超级用户/迁移脚本，与流水表写法一致）
-- stock_hold_release 只追加（A3）；TRUNCATE 也拦（小赵 S5）
CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold
WHEN NEW.id IS NOT OLD.id OR NEW.stock_id IS NOT OLD.stock_id OR NEW.hold_type IS NOT OLD.hold_type OR NEW.reason_code IS NOT OLD.reason_code
  OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.op_key IS NOT OLD.op_key
  OR NEW.hold_qty_milli IS NOT OLD.hold_qty_milli OR NEW.operator_id IS NOT OLD.operator_id OR NEW.created_at IS NOT OLD.created_at
  OR NEW.released_qty_milli < OLD.released_qty_milli OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED')
BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- R2（SQLite）：拒删除；REPLACE 冲突时删旧行在 recursive_triggers=OFF（默认，且是连接级开关）下不触发 DELETE 触发器，
-- 所以另用 BEFORE INSERT 在 id / op_key 已存在时直接 ABORT，REPLACE 走不到删除那一步（库级生效，不依赖连接设置）
CREATE TRIGGER trg_hold_no_delete BEFORE DELETE ON stock_hold BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
CREATE TRIGGER trg_hold_no_replace BEFORE INSERT ON stock_hold
WHEN EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.id OR h.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;

-- 只追加：流水表与去重表禁止 UPDATE / DELETE。PG 侧收回应用角色权限 + 触发器（防超级用户/运维脚本误操作）；SQLite 侧触发器
-- TRUNCATE 不触发行级触发器，单独加语句级触发器拦（小赵 C5）；归档走 DETACH PARTITION，不用 TRUNCATE
-- 应用角色授权清单（小赵 C3，docs/02 §4.9）：库存类表只给 SELECT/INSERT/UPDATE，不给 DELETE/TRUNCATE；
-- stock_ledger_line 只能改换主相关列（第 5 篇改派/重新领取），来源与单据行由 trg_sll_immutable 再拦一道（防超级用户/迁移脚本）
-- stock_hold 只授释放相关列（小赵 N1）；其余列由 trg_hold_immutable 再拦一道（防超级用户/迁移脚本）
CREATE TRIGGER trg_mv_no_update  BEFORE UPDATE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
CREATE TRIGGER trg_mv_no_delete  BEFORE DELETE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
CREATE TRIGGER trg_mvk_no_update BEFORE UPDATE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
CREATE TRIGGER trg_mvk_no_delete BEFORE DELETE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
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
    created_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
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
    detected_at             TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    last_seen_at            TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_recon_status CHECK (status IN ('OPEN','ACKED','RESOLVED')),
    CONSTRAINT ck_recon_code CHECK (check_code IN ('I3a','I3b','I3c','I3d','I3e','I4','I5','SNAP'))   -- 码表见 docs/02 §4.6；新增走迁移（小赵 C4）
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
    created_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at              TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
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
-- 配送与签收（docs/16）：运单、站点、出库单签收状态、司机端作业（POD_OP 业务键）、
-- 签收行、签收更正（POD_CORRECT，经第 12 篇审批）、拒收回仓交接。数量一律 *_qty_milli（00 R2）。
-- 新增 8 表 / 25 索引（8 PK + 9 UNIQUE 约束 + 2 部分唯一 uq_podc_pending/uq_podc_seq + 6 普通/部分）。
-- -----------------------------------------------------------------------------

CREATE TABLE waybill (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,          -- waybill_no：WB-{仓}-{节点}-{作业日}-{序号}（00 §6.2）
    warehouse_id    BIGINT       NOT NULL,
    shipment_id     BIGINT       NOT NULL,          -- 第 6 篇发运单，1:1
    driver_id       BIGINT       NOT NULL,
    route_code      VARCHAR(32),
    work_date       DATE         NOT NULL,          -- 仓库时区作业日（00 R3）
    status          VARCHAR(16)  NOT NULL DEFAULT 'CREATED',
    waybill_version INT          NOT NULL DEFAULT 1, -- 运单包版本，改派/改站点 +1（第 15 篇 waybill_version）
    version         BIGINT       NOT NULL DEFAULT 0,
    departed_at     TIMESTAMP,
    returned_at     TIMESTAMP,
    closed_at       TIMESTAMP,
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_wb_code     UNIQUE (code),
    CONSTRAINT uq_wb_shipment UNIQUE (shipment_id),
    CONSTRAINT ck_wb_status   CHECK (status IN ('CREATED','LOADING','IN_TRANSIT','RETURNED','CLOSED','CANCELLED'))
);
CREATE INDEX ix_wb_driver ON waybill(driver_id, work_date, status);

CREATE TABLE delivery_stop (
    id              BIGINT       PRIMARY KEY,
    waybill_id      BIGINT       NOT NULL,
    stop_no         SMALLINT     NOT NULL,
    customer_id     BIGINT       NOT NULL,
    display_status  VARCHAR(20)  NOT NULL DEFAULT 'PENDING', -- 只是展示汇总（Q14），由站点下出库单 delivery_result（04）推导，任何业务判断不得读它
    arrived_at      TIMESTAMP,
    departed_at     TIMESTAMP,
    arrive_note     VARCHAR(256),                   -- 定位偏差说明，仅备注（第 15 篇 GeoStamp）
    CONSTRAINT uq_dstop     UNIQUE (waybill_id, stop_no),
    CONSTRAINT ck_dstop_no  CHECK (stop_no > 0),
    CONSTRAINT ck_dstop_st  CHECK (display_status IN ('PENDING','ARRIVED','DEPARTED_UNSIGNED','FULL','PARTIAL_REJECT','FULL_REJECT','MIXED'))
);

CREATE TABLE delivery_order (
    id              BIGINT       PRIMARY KEY,
    waybill_id      BIGINT       NOT NULL,
    stop_no         SMALLINT     NOT NULL,
    outbound_id     BIGINT       NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'SHIPPED',   -- 与 outbound_order 同步 SHIPPED→DELIVERED（04 T17）；签收结论在 outbound_order.delivery_result（04 列，本篇只引用）
    valid_pod_id    BIGINT,                         -- 当前生效签收 id（首签 = pod_op.id；更正后 = pod_correction.id）；更正执行的条件更新以它为栅栏
    root_pod_id     BIGINT,                         -- 首次签收的 pod_id，更正后不变；异常单 source_key = POD:{root_pod_id}:{correct_seq}
    correct_seq     SMALLINT     NOT NULL DEFAULT 0, -- 首次签收 0；更正执行时由服务端 +1 分配
    version         BIGINT       NOT NULL DEFAULT 0,
    signed_at       TIMESTAMP,
    CONSTRAINT uq_dord_outbound UNIQUE (outbound_id),          -- 一张出库单只在一张有效运单上（改派=换 waybill_id）
    CONSTRAINT ck_dord_status CHECK (status IN ('SHIPPED','DELIVERED')),
    CONSTRAINT ck_dord_pod    CHECK ((status = 'SHIPPED') = (valid_pod_id IS NULL) AND (valid_pod_id IS NULL) = (root_pod_id IS NULL)),
    CONSTRAINT ck_dord_cseq   CHECK (correct_seq >= 0 AND (root_pod_id IS NOT NULL OR correct_seq = 0))
);
CREATE INDEX ix_dord_stop ON delivery_order(waybill_id, stop_no);

-- 司机端每一次现场写操作（LOAD/ARRIVE/POD_SIGN/POD_REJECT/DEPART/CONTAINER/RETURN_COUNT）一行，可离线排队补传。
-- 业务唯一键 (waybill_no, stop_no, device_instance_id, op_seq)（00 §6.5）；同键同 req_hash → 回放 response；
-- 同键不同 req_hash → 40910 key_type=POD_OP。签收更正不走这里（只能在线 POST /approvals，第 12 篇）。
-- 只缓存确定性结果：HTTP 2xx、400（400xx）、409（409xx）；422/5xx/429/401/403 不落行（随事务回滚）。
CREATE TABLE pod_op (
    id                  BIGINT       PRIMARY KEY,   -- 签收类操作的 id 即 pod_id
    warehouse_id        BIGINT       NOT NULL,
    waybill_no          VARCHAR(64)  NOT NULL,
    stop_no             SMALLINT     NOT NULL,      -- 运单级操作（LOAD/RETURN_COUNT/CONTAINER）用 0
    device_instance_id  VARCHAR(64)  NOT NULL,
    op_seq              BIGINT       NOT NULL,
    op_type             VARCHAR(16)  NOT NULL,
    user_id             BIGINT       NOT NULL,
    req_hash            VARCHAR(64)  NOT NULL,      -- 规范化请求体 SHA-256（object_key+sha256，不含 Idempotency-Key）
    http_status         SMALLINT     NOT NULL,
    biz_code            VARCHAR(8)   NOT NULL,      -- "0" 或 400xx/409xx
    response            TEXT         NOT NULL,
    signer_type         VARCHAR(16),                -- CUSTOMER_SCAN / DRIVER_PROXY（仅签收类）
    media_json          TEXT,                       -- [{object_key, sha256}]
    client_created_at   TIMESTAMP,                  -- 只展示，不参与排序与记账
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_pod_op_key  UNIQUE (waybill_no, stop_no, device_instance_id, op_seq),
    CONSTRAINT ck_pod_op_type CHECK (op_type IN ('LOAD','ARRIVE','POD_SIGN','POD_REJECT','DEPART','CONTAINER','RETURN_COUNT')),
    CONSTRAINT ck_pod_op_seq  CHECK (op_seq > 0 AND stop_no >= 0),
    CONSTRAINT ck_pod_op_cache CHECK ((http_status BETWEEN 200 AND 299 AND biz_code = '0')
                                   OR (http_status = 400 AND biz_code LIKE '400__')
                                   OR (http_status = 409 AND biz_code LIKE '409__'))
);
CREATE INDEX ix_pod_op_dev ON pod_op(device_instance_id, waybill_no, stop_no, op_seq);   -- GET /devices/{id}/op-seq-hwm（Q13）
CREATE INDEX ix_pod_op_stop ON pod_op(waybill_no, stop_no, created_at);

-- 签收结论的行明细：对每条出库行记 实收 / 司机登记拒收。拒收数只是暂记，入账以回仓实点为准（Q15）
CREATE TABLE pod_line (
    id                   BIGINT   PRIMARY KEY,
    pod_id               BIGINT   NOT NULL,         -- 签收 id：pod_op.id（POD_SIGN / POD_REJECT）或 pod_correction.id（审批通过执行的更正）
    outbound_id          BIGINT   NOT NULL,
    outbound_line_id     BIGINT   NOT NULL,
    sku_id               BIGINT   NOT NULL,
    lot_id               BIGINT   NOT NULL,         -- 装车明细带出，回仓 RTN 必须带批次（第 10 篇）
    shipped_qty_milli    BIGINT   NOT NULL,
    rejected_qty_milli   BIGINT   NOT NULL DEFAULT 0,
    reject_reason        VARCHAR(32),
    CONSTRAINT uq_podl      UNIQUE (pod_id, outbound_line_id, lot_id),
    CONSTRAINT ck_podl_int  CHECK (shipped_qty_milli = CAST(shipped_qty_milli AS BIGINT) AND rejected_qty_milli = CAST(rejected_qty_milli AS BIGINT)),
    CONSTRAINT ck_podl_qty  CHECK (shipped_qty_milli > 0 AND rejected_qty_milli >= 0 AND rejected_qty_milli <= shipped_qty_milli),
    CONSTRAINT ck_podl_rsn  CHECK (rejected_qty_milli = 0 OR reject_reason IS NOT NULL)
);

-- 签收更正：只能在线提交 POST /api/v1/approvals（type=POD_CORRECT，第 12 篇 approval_request），按审批单号关联；
-- 审批通过时同一事务执行更正（条件更新 delivery_order … AND valid_pod_id=:corrected_pod_id），correct_seq 由服务端此时分配。
-- 状态镜像审批单：PENDING / APPLIED / REJECTED / WITHDRAWN / EXPIRED / VOID（执行时原签收已变 → 40951，审批显示作废）
CREATE TABLE pod_correction (
    id                BIGINT       PRIMARY KEY,     -- 也是更正后的签收 id（valid_pod_id、pod_line.pod_id 指向它）
    approval_id       BIGINT       NOT NULL,        -- 第 12 篇 approval_request.id
    corrected_pod_id  BIGINT       NOT NULL,
    outbound_id       BIGINT       NOT NULL,
    status            VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    requested_by      BIGINT       NOT NULL,
    approver_id       BIGINT,
    reason            VARCHAR(256) NOT NULL,
    decided_at        TIMESTAMP,
    correct_seq       SMALLINT,                     -- APPLIED 时 = delivery_order.correct_seq 新值（≥1），服务端分配
    created_at        TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_podc_approval UNIQUE (approval_id),
    CONSTRAINT ck_podc_status CHECK (status IN ('PENDING','APPLIED','REJECTED','WITHDRAWN','EXPIRED','VOID')),
    CONSTRAINT ck_podc_sod    CHECK (approver_id IS NULL OR approver_id <> requested_by),
    CONSTRAINT ck_podc_decide CHECK (status = 'PENDING'
                                  OR (status IN ('APPLIED','REJECTED','VOID') AND approver_id IS NOT NULL AND decided_at IS NOT NULL)
                                  OR (status IN ('WITHDRAWN','EXPIRED') AND decided_at IS NOT NULL)),
    CONSTRAINT ck_podc_seq    CHECK ((status = 'APPLIED') = (correct_seq IS NOT NULL) AND (correct_seq IS NULL OR correct_seq > 0))
);
CREATE UNIQUE INDEX uq_podc_pending ON pod_correction(corrected_pod_id, outbound_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX uq_podc_seq     ON pod_correction(outbound_id, correct_seq) WHERE status = 'APPLIED';

-- 拒收回仓交接：司机登记数（暂记） vs 交接员实点数（为准）；生成第 10 篇 RTN，差异推第 10 篇异常单
CREATE TABLE delivery_return (
    id              BIGINT       PRIMARY KEY,
    warehouse_id    BIGINT       NOT NULL,
    waybill_id      BIGINT       NOT NULL,
    stop_no         SMALLINT     NOT NULL,
    handover_seq    SMALLINT     NOT NULL DEFAULT 1,  -- RTN source_order_no = {waybill_no}:{stop_no}:{handover_seq}（第 10 篇 §1）
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN',
    rtn_inbound_id  BIGINT,
    counted_by      BIGINT,
    counted_at      TIMESTAMP,
    CONSTRAINT uq_dret      UNIQUE (waybill_id, stop_no, handover_seq),
    CONSTRAINT ck_dret_st   CHECK (status IN ('OPEN','COUNTED','CANCELLED')),
    CONSTRAINT ck_dret_cnt  CHECK (status <> 'COUNTED' OR (rtn_inbound_id IS NOT NULL AND counted_by IS NOT NULL))
);
CREATE INDEX ix_dret_wh ON delivery_return(warehouse_id, status);

CREATE TABLE delivery_return_line (
    id                   BIGINT   PRIMARY KEY,
    return_id            BIGINT   NOT NULL,
    pod_line_id          BIGINT   NOT NULL,
    sku_id               BIGINT   NOT NULL,
    lot_id               BIGINT   NOT NULL,
    reported_qty_milli   BIGINT   NOT NULL,         -- 司机登记拒收数（= pod_line.rejected_qty_milli）
    counted_qty_milli    BIGINT,                    -- 交接员实点；入账与 RTN 实收以此为准
    exception_case_id    BIGINT,                    -- 差异 ≠ 0 时第 10 篇 intake 返回
    CONSTRAINT uq_dretl     UNIQUE (return_id, pod_line_id),
    CONSTRAINT ck_dretl_int CHECK (reported_qty_milli = CAST(reported_qty_milli AS BIGINT) AND (counted_qty_milli IS NULL OR counted_qty_milli = CAST(counted_qty_milli AS BIGINT))),
    CONSTRAINT ck_dretl_qty CHECK (reported_qty_milli >= 0 AND (counted_qty_milli IS NULL OR counted_qty_milli >= 0)),
    CONSTRAINT ck_dretl_exc CHECK (counted_qty_milli IS NULL OR counted_qty_milli = reported_qty_milli OR exception_case_id IS NOT NULL)
);
CREATE INDEX ix_dretl_exc ON delivery_return_line(exception_case_id) WHERE exception_case_id IS NOT NULL;
-- 授权（docs/16 §4.9）：pod_op 是业务键 + 回放缓存，只追加；其余表应用层可改（状态由条件更新保证）
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

-- 小赵 Q2：去重记录与 outbox 只能清理"已过期 / 已投递且过保留期"的行（两库触发器，条件与 purge_expired() 一致）
CREATE TRIGGER trg_idem_purge_guard BEFORE DELETE ON idempotency_record WHEN NOT (OLD.expires_at < datetime('now'))
BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: idempotency_record'); END;
CREATE TRIGGER trg_outbox_purge_guard BEFORE DELETE ON outbox_event WHEN NOT (OLD.status = 'SENT' AND OLD.sent_at < datetime('now', '-7 days'))
BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: outbox_event'); END;
-- SQLite REPLACE 冲突删旧行不触发 DELETE 触发器 → BEFORE INSERT 主键已存在就中止（应用把 idem_duplicate 当作"键已存在"处理，与 PG 23505 同分支）
CREATE TRIGGER trg_idem_no_replace BEFORE INSERT ON idempotency_record WHEN EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key)
BEGIN SELECT RAISE(ABORT, 'idem_duplicate'); END;
CREATE TRIGGER trg_outbox_no_replace BEFORE INSERT ON outbox_event WHEN EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'outbox_duplicate'); END;

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



-- ============================================================
-- wms_app 授权清单（其余表，docs/02 §4.4.4）：public 下每张表/视图都必须对 wms_app 有显式授权，
-- verify.sh 按 pg_class 逐表检查，缺一张就失败。新增表必须在这里（或表旁）写 GRANT，按需最小授权；不给 TRUNCATE。
-- ============================================================
-- 清理只能经 purge_expired()：属主 wms_purge_owner（非超级用户、NOLOGIN，只有这两张表的 SELECT/DELETE），
-- 调用方 wms_cleaner 只有 EXECUTE，对表没有任何权限；删除条件写死在函数里，不接受参数
