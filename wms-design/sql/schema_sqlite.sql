-- 本文件由 sql/verify_sqlite.py 从 sql/schema/*.sql 按加载顺序机械生成，请勿手改。
-- 翻译产生的改动共 4 类：
--   1. 删除 1 条 COMMENT ON（SQLite 无该语法，注释降级到行内）
--   2. 33 处 DEFAULT now()、42 处 DEFAULT (now() AT TIME ZONE 'UTC') / (date_trunc('second', now() AT TIME ZONE 'UTC')) → DEFAULT (datetime('now'))（表达式默认值需括号；SQLite 恒为 UTC）
--   3. 方言专属行：删除 1187 行 @pg-only（分区、plpgsql 触发器、角色权限），启用 765 行 @sqlite-only（等价触发器）
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
    warehouse_id    BIGINT       NOT NULL REFERENCES warehouse(id),
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
    warehouse_id        BIGINT        NOT NULL REFERENCES warehouse(id),
    zone_id             BIGINT        NOT NULL REFERENCES zone(id),
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
    sku_id      BIGINT      NOT NULL REFERENCES sku(id),
    barcode     VARCHAR(64) NOT NULL,
    uom         VARCHAR(16) NOT NULL DEFAULT 'EA',   -- 该条码对应的包装层级
    is_primary  BOOLEAN     NOT NULL DEFAULT false,
    CONSTRAINT uq_barcode UNIQUE (barcode)
);
-- PDA 扫码解析：条码 → SKU，必须走唯一索引，一次命中
-- #2 第十二轮（00 §6.10 扩到全部带唯一键的表）：REPLACE 同条码会静默删掉别的 SKU 的条码行（条码被"抢"走）→ 两个唯一键都先拦
CREATE TRIGGER trg_bc_no_replace BEFORE INSERT ON sku_barcode WHEN EXISTS (SELECT 1 FROM sku_barcode b WHERE b.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'barcode_duplicate: sku_barcode.id'); END;
CREATE TRIGGER trg_bc_no_replace_code BEFORE INSERT ON sku_barcode WHEN EXISTS (SELECT 1 FROM sku_barcode b WHERE b.barcode = NEW.barcode) BEGIN SELECT RAISE(ABORT, 'barcode_duplicate: sku_barcode.barcode'); END;

CREATE TABLE sku_unit (
    id              BIGINT        PRIMARY KEY,
    sku_id          BIGINT        NOT NULL REFERENCES sku(id),
    uom             VARCHAR(16)   NOT NULL,
    ratio_to_base   NUMERIC(14,6) NOT NULL,
    is_pick_uom     BOOLEAN       NOT NULL DEFAULT false,
    is_receive_uom  BOOLEAN       NOT NULL DEFAULT false,
    barcode_level   SMALLINT      NOT NULL DEFAULT 1,
    CONSTRAINT uq_sku_uom UNIQUE (sku_id, uom)
);

CREATE TABLE lot (
    id                  BIGINT       PRIMARY KEY,
    sku_id              BIGINT       NOT NULL REFERENCES sku(id),
    lot_code            VARCHAR(64)  NOT NULL,
    production_date     DATE,                           -- 日历日（04 I5）
    expiry_date         DATE         NOT NULL,          -- FEFO 排序键；日历日，禁发期按仓库时区自然日计算（04 I5）
    receive_date        DATE         NOT NULL,          -- #2 第十一轮：纯日期（收货自然日），不带时间；00 §6.8
    supplier_id         BIGINT,
    origin_batch        VARCHAR(64),
    quality_status      VARCHAR(16)  NOT NULL DEFAULT 'QUALIFIED',
    remaining_life_days SMALLINT     NOT NULL DEFAULT 9999,  -- 冗余，定时刷新
    sell_deadline       DATE,                           -- 可售截止日 = COALESCE(production_date, receive_date 的日期) + sku.sell_days；sku.sell_days 为空时为 NULL。建档写入后不可改（trg_lot_sell_deadline：含 NULL→日期、改早、改晚、清空）
    cert_no             VARCHAR(64),                    -- 检疫合格证等
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_lot_date CHECK (
        (production_date IS NULL OR (production_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(production_date) IS production_date))
        AND expiry_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(expiry_date) IS expiry_date
        AND (sell_deadline IS NULL OR (sell_deadline GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(sell_deadline) IS sell_deadline))),
    CONSTRAINT ck_lot_recv_ts CHECK (receive_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(receive_date) IS receive_date),   -- #2 第十一轮：只收 YYYY-MM-DD，拒时间/24:00/偏移/斜杠/紧凑写法/非法日期
    CONSTRAINT uq_lot UNIQUE (sku_id, lot_code, expiry_date)
);
CREATE INDEX ix_lot_expiry ON lot(sku_id, expiry_date) WHERE quality_status = 'QUALIFIED';
CREATE INDEX ix_lot_aging  ON lot(remaining_life_days, sku_id);
-- [SQLite] 两个部分索引均支持；ix_lot_aging 支撑效期预警列表
-- sell_deadline 建档固定、不回溯：其余列仍可更新，只有这一列（含 NULL）写入后不可改
-- search_path 固定为 pg_catalog, public。IS DISTINCT FROM 用的 =(date,date) 来自 pg_catalog，调用方 schema 里的同名运算符不生效。
CREATE TRIGGER trg_lot_sell_deadline BEFORE UPDATE ON lot
WHEN NEW.sell_deadline IS NOT OLD.sell_deadline
BEGIN SELECT RAISE(ABORT, 'sell_deadline_immutable'); END;
-- #2 第十二轮：REPLACE 撞 id 或 uq_lot 会删旧批次再插新行，绕过 trg_lot_sell_deadline（00 §6.10）→ 两个唯一键都先拦
CREATE TRIGGER trg_lot_no_replace BEFORE INSERT ON lot WHEN EXISTS (SELECT 1 FROM lot l WHERE l.id = NEW.id
  OR (l.sku_id = NEW.sku_id AND l.lot_code = NEW.lot_code AND l.expiry_date = NEW.expiry_date))
BEGIN SELECT RAISE(ABORT, 'lot_duplicate'); END;
-- #2 第十二轮（小玛丽 r12 B2）：主数据按业务键换 id REPLACE 会静默删掉父行；子表 sku_id / location_id / zone_id 很多没声明外键（见 #14），删掉就是孤儿 → 每个唯一键都拦
CREATE TRIGGER trg_warehouse_no_replace BEFORE INSERT ON warehouse WHEN EXISTS (SELECT 1 FROM warehouse x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: warehouse.id'); END;
CREATE TRIGGER trg_warehouse_no_replace_code BEFORE INSERT ON warehouse WHEN EXISTS (SELECT 1 FROM warehouse x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: warehouse.code'); END;
CREATE TRIGGER trg_zone_no_replace BEFORE INSERT ON zone WHEN EXISTS (SELECT 1 FROM zone x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: zone.id'); END;
CREATE TRIGGER trg_zone_no_replace_code BEFORE INSERT ON zone WHEN EXISTS (SELECT 1 FROM zone x WHERE x.warehouse_id = NEW.warehouse_id AND x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: zone.warehouse_id, zone.code'); END;
CREATE TRIGGER trg_location_no_replace BEFORE INSERT ON location WHEN EXISTS (SELECT 1 FROM location x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: location.id'); END;
CREATE TRIGGER trg_location_no_replace_code BEFORE INSERT ON location WHEN EXISTS (SELECT 1 FROM location x WHERE x.warehouse_id = NEW.warehouse_id AND x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: location.warehouse_id, location.code'); END;
CREATE TRIGGER trg_sku_no_replace BEFORE INSERT ON sku WHEN EXISTS (SELECT 1 FROM sku x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: sku.id'); END;
CREATE TRIGGER trg_sku_no_replace_code BEFORE INSERT ON sku WHEN EXISTS (SELECT 1 FROM sku x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: sku.code'); END;
-- -----------------------------------------------------------------------------
-- 库存（核心）
-- -----------------------------------------------------------------------------

-- 数量口径（docs/02-库存核心.md §4，PM 裁决）：库存四张表的数量一律 BIGINT，
-- 单位 = SKU base_uom 的 1/1000，列名统一 *_qty_milli 后缀。KG 计即"克"，PCS 计即 0.001 个。
-- ck_*_int：SQLite 的 BIGINT 是 INTEGER 亲和性，3.5 / '12.500' 会被静默存成 REAL，
--   用 x = CAST(x AS BIGINT) 拦截非整数写入；PG 侧列型已是 bigint，该 CHECK 恒真，无副作用。

CREATE TABLE stock (
    id                      BIGINT          PRIMARY KEY,
    warehouse_id            BIGINT          NOT NULL REFERENCES warehouse(id),
    location_id             BIGINT          NOT NULL REFERENCES location(id),
    sku_id                  BIGINT          NOT NULL REFERENCES sku(id),
    lot_id                  BIGINT          NOT NULL,
    container_id            BIGINT          NOT NULL DEFAULT 0,   -- 0 = 散货无容器（哨兵值，见下）
    uom                     VARCHAR(16)     NOT NULL,             -- 恒为 sku.base_uom

    on_hand_qty_milli       BIGINT          NOT NULL DEFAULT 0,   -- 在库总量
    allocated_qty_milli     BIGINT          NOT NULL DEFAULT 0,   -- 已分配未拣（= ALLOCATE 占用汇总）
    reserved_qty_milli      BIGINT          NOT NULL DEFAULT 0,   -- 已预占（= RESERVE 占用汇总）
    quality_hold_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- 质检/盘点冻结（= QUALITY + RETURN_QC 冻结汇总）
    hold_qty_milli        BIGINT          NOT NULL DEFAULT 0,   -- 冻结（= MANUAL + RETURN_PENDING + SCRAP_PENDING + PROCESSING + LIVE_HOLD 冻结汇总），从 available 扣除，FEFO 分不到

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
-- #2 第十二轮（00 §6.10 扩到全部表）：stock 行带 version / 各数量，REPLACE 撞 id 或 uq_stock_dim 会把余额和版本整行重置 → 先拦
CREATE TRIGGER trg_stock_no_replace BEFORE INSERT ON stock WHEN EXISTS (SELECT 1 FROM stock s WHERE s.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'stock_duplicate: stock.id'); END;
CREATE TRIGGER trg_stock_no_replace_dim BEFORE INSERT ON stock WHEN EXISTS (SELECT 1 FROM stock s WHERE s.warehouse_id = NEW.warehouse_id AND s.location_id = NEW.location_id AND s.sku_id = NEW.sku_id AND s.lot_id = NEW.lot_id AND s.container_id = NEW.container_id)
BEGIN SELECT RAISE(ABORT, 'stock_duplicate: stock.warehouse_id, stock.location_id, stock.sku_id, stock.lot_id, stock.container_id'); END;
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
    expires_at          TIMESTAMP,                  -- 超时自动释放，防死锁。#2 第九轮：由库计算（created_at + 最长 TTL 24h），调用方不能填永不过期
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_res_op  UNIQUE (op_key),
    CONSTRAINT ck_res_stage CHECK (stage IN ('RESERVE','ALLOCATE')),
    -- #2 第九轮 TTL 上界：expires_at 只能落在 (created_at, created_at + 24h]；允许缩短（更早释放更安全），不许超过 24h。
    -- 不能为 NULL（NULL = 永不过期）：PG 列 NOT NULL（BEFORE INSERT 触发器先补算）；SQLite 由 AFTER INSERT 补算，trg_res_expires_lock 拒 UPDATE 成 NULL
    CONSTRAINT ck_res_ttl CHECK (expires_at IS NULL OR (strftime('%s', created_at) IS NOT NULL AND strftime('%s', expires_at) IS NOT NULL
        AND expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(expires_at, 12, 2) <= '23'
        AND CAST(strftime('%s', expires_at) AS INTEGER) - CAST(strftime('%s', created_at) AS INTEGER) BETWEEN 1 AND 86400)),
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
-- #2 第九轮：预占过期时间由库计算。PG：INSERT 时 created_at 强制为库时钟（UTC 整秒），expires_at 为空则补 created_at + 24h；
-- 调用方显式给的值由 ck_res_ttl 校验上界（不能超过 24h，不能早于建单）；UPDATE 不许改 created_at。
-- SQLite：created_at 只收与 now 相差 ≤ 300s 的整秒 UTC；AFTER INSERT 补 expires_at；上界同样由 ck_res_ttl 拦。
-- B1：PG 补算在 BEFORE 触发器里，NOT NULL 检查在其后，调用方 / 属主都不能把它改成 NULL
CREATE TRIGGER trg_res_clock BEFORE INSERT ON stock_reservation
WHEN NEW.created_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' OR substr(NEW.created_at, 12, 2) > '23' OR strftime('%s', NEW.created_at) IS NULL
  OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'reservation_clock_skew'); END;
CREATE TRIGGER trg_res_ttl_fill AFTER INSERT ON stock_reservation WHEN NEW.expires_at IS NULL
BEGIN UPDATE stock_reservation SET expires_at = datetime(NEW.created_at, '+24 hours') WHERE id = NEW.id; END;
-- SQLite REPLACE 冲突是删旧行再插新行，不经过 UPDATE 触发器（小玛丽 r10 R1：可借此无限续期）→ 同 trg_idem_no_replace，主键已存在就中止
--   主键和 op_key 都查：REPLACE 撞 op_key（换 id）同样会删旧行重建。同 op_key 的普通重复插入也由本触发器先拦（reservation_duplicate），uq_res_op 兜底
CREATE TRIGGER trg_res_no_replace BEFORE INSERT ON stock_reservation WHEN EXISTS (SELECT 1 FROM stock_reservation r WHERE r.id = NEW.id OR r.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'reservation_duplicate'); END;
CREATE TRIGGER trg_res_expires_lock BEFORE UPDATE OF expires_at ON stock_reservation WHEN NEW.expires_at IS NULL
BEGIN SELECT RAISE(ABORT, 'reservation_expires_null'); END;
CREATE TRIGGER trg_res_created_lock BEFORE UPDATE OF created_at ON stock_reservation WHEN NEW.created_at IS NOT OLD.created_at
BEGIN SELECT RAISE(ABORT, 'reservation_created_at_immutable'); END;

CREATE TABLE stock_hold (
    id                  BIGINT          PRIMARY KEY,
    stock_id            BIGINT          NOT NULL,
    hold_type           VARCHAR(16)     NOT NULL,   -- QUALITY、RETURN_QC → quality_hold；MANUAL、RETURN_PENDING、SCRAP_PENDING、PROCESSING、LIVE_HOLD → hold_qty
    reason_code         VARCHAR(24)     NOT NULL,   -- 见 ck_hold_reason；新增原因走迁移
    source_type         VARCHAR(24)     NOT NULL,   -- INBOUND_QC/QC/COUNT/RETURN/EXCEPTION/MANUAL/RETURN_RECORD/SCRAP/PROCESS_ORDER/LIVE_TANK_HOLD
    source_id           BIGINT          NOT NULL DEFAULT 0,
    op_key              VARCHAR(80)     NOT NULL,   -- RETURN_PENDING 固定 RRH:{return_record_id}；convert_hold 的 op_key 由调用方传入（全量常用 CVT:{原 hold_id}，部分用 CVT:{line_id}:{op_seq}）；PROCESSING 必须 PRCI:（大小写敏感）
    hold_qty_milli      BIGINT          NOT NULL,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'HELD',      -- HELD/RELEASED，由余量决定
    operator_id         BIGINT          NOT NULL,   -- 系统冻结填 0
    approval_type       VARCHAR(24),                -- 需要审批的转换才填：SCRAP_MISREPORT（SCRAP_PENDING → RETURN_QC 误报回转）
    approval_no         VARCHAR(64),                -- 审批单号
    is_reversal         BOOLEAN         NOT NULL DEFAULT false,  -- 误报回转明细（SCRAP_PENDING → RETURN_QC）显式标记，替代 op_key LIKE 'CVT:%' 识别（小赵 N1）
    from_hold_id        BIGINT,                 -- convert_hold 子明细指向被转出的父冻结；一条父冻结可多次部分转出。I3e 按此汇总，不再用 op_key = 'CVT:' || id
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_hold_op UNIQUE (op_key),
    CONSTRAINT ck_hold_type CHECK (hold_type IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')),
    -- 一套方案：hold_type 是大类（决定计入哪一列），reason_code 是细分原因，二者成对约束。
    -- PROCESSING / LIVE_HOLD 由本篇统一收进码表；#12/#13 不要再改这条 CHECK。
    CONSTRAINT ck_hold_reason CHECK (
        hold_type NOT IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')      -- 类型非法交给 ck_hold_type 报，避免两条约束同时报
        OR (hold_type = 'QUALITY'        AND reason_code IN ('QC_PENDING','COUNT_LOCK'))
        OR (hold_type = 'RETURN_QC'      AND reason_code = 'RETURN_QC')     -- 退货待检（A3：系统冻结，只能由质检 release_qc_hold 释放）
        OR (hold_type = 'MANUAL'      AND reason_code IN ('DAMAGE','EXCEPTION','OTHER'))
        OR (hold_type = 'RETURN_PENDING' AND reason_code = 'RETURN_PENDING')
        OR (hold_type = 'SCRAP_PENDING'  AND reason_code = 'SCRAP')        -- 报损待处置（convert_hold 自 RETURN_PENDING 转入，docs/02 §7.1.1）
        OR (hold_type = 'PROCESSING'     AND reason_code = 'PROCESSING')   -- 加工领料系统锁（第 17 篇 place_hold）
        OR (hold_type = 'LIVE_HOLD'      AND reason_code = 'LIVE_HOLD')    -- 活鲜暂存系统锁（第 18 篇 place_hold）
    ),
    -- RETURN_PENDING 是系统冻结：必须挂在一条待回库记录上、operator_id=0；人工解冻接口拒绝它（应用层），只能由 confirm/resolve 同事务释放
    CONSTRAINT ck_hold_return CHECK (
        hold_type <> 'RETURN_PENDING'
        OR (source_type = 'RETURN_RECORD' AND source_id > 0 AND operator_id = 0)
    ),
    -- SCRAP_PENDING 也是系统冻结：挂报损单 id（source_type=SCRAP，source_id=报损单 id，不是报损行 id）、operator_id=0；人工解冻拒绝（40933），只能由第 9 篇报损完成/撤销释放。不走 place_hold，继续用 hold(SCRAP_PENDING)
    -- RETURN_QC 系统冻结（A3）：挂质检单（source_type=QC，source_id=质检单 id）、operator_id=0；人工解冻拒绝（40933），只能由 release_qc_hold 释放
    CONSTRAINT ck_hold_retqc CHECK (
        hold_type <> 'RETURN_QC'
        OR (source_type = 'QC' AND source_id > 0 AND operator_id = 0)
    ),
    -- 误报回转（SCRAP_PENDING → RETURN_QC，convert_hold 生成 op_key=CVT:{原 hold_id}）必须带 SCRAP_MISREPORT 审批单号；其余明细不带审批
    CONSTRAINT ck_hold_approval CHECK (
        (NOT is_reversal AND approval_type IS NULL AND approval_no IS NULL)
        OR (is_reversal AND approval_type = 'SCRAP_MISREPORT' AND approval_no IS NOT NULL AND length(approval_no) > 0)
    ),
    -- 回转标记与类型/op_key 双向一致：只有 RETURN_QC 能是回转，RETURN_QC 的 CVT 明细必须标回转（防止不带审批伪造回转）
    -- LIKE 在 PG 区分大小写、在 SQLite 默认不区分；回转前缀用 GLOB（SQLite 区分大小写）对齐，避免 'cvt:' 在 SQLite 被当成回转
    CONSTRAINT ck_hold_reversal_key CHECK (is_reversal = (hold_type = 'RETURN_QC' AND op_key GLOB 'CVT:*')),
    -- 审批单号格式 APR-{仓库编码}-{yyyyMMdd}-{6 位数字}；仓库编码字符集 [A-Z0-9]{2,16}（以第 1 篇 #8 为准）
    CONSTRAINT ck_hold_approval_no CHECK (approval_no IS NULL OR (
        length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
        AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
        AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
        AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
        AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]')
        -- 真实日历日（N1）：SQLite date() 会把 02-30 规范成 03-02，与原串不等即拒
        AND substr(approval_no, -15, 4) <> '0000'
        AND date(substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)) = substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2))),
    CONSTRAINT ck_hold_scrap CHECK (
        hold_type <> 'SCRAP_PENDING'
        OR (source_type = 'SCRAP' AND source_id > 0 AND operator_id = 0)
    ),
    CONSTRAINT fk_hold_from FOREIGN KEY (from_hold_id) REFERENCES stock_hold(id),
    CONSTRAINT ck_hold_from CHECK (from_hold_id IS NULL OR from_hold_id <> id),
    -- PROCESSING：挂加工单、系统操作员、op_key 前缀 PRCI:（大小写敏感，同 CVT 的方言拆分）
    CONSTRAINT ck_hold_process CHECK (
        hold_type <> 'PROCESSING'
        OR (source_type = 'PROCESS_ORDER' AND source_id > 0 AND operator_id = 0 AND op_key GLOB 'PRCI:*')
    ),
    -- LIVE_HOLD：挂活鲜暂养冻结单。不强制 op_key 前缀（第 18 篇没有规定前缀，强制会拒掉合法插入）
    CONSTRAINT ck_hold_live CHECK (
        hold_type <> 'LIVE_HOLD'
        OR (source_type = 'LIVE_TANK_HOLD' AND source_id > 0 AND operator_id = 0)
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
-- 非唯一：一条父冻结可以多次部分转出，多条子明细共享同一个 from_hold_id
CREATE INDEX ix_hold_from ON stock_hold(from_hold_id) WHERE from_hold_id IS NOT NULL;

-- 冻结部分释放的操作去重（A3，release_qc_hold / release_hold / release_live_hold）：一次释放一行，op_key 由调用方传入（质检如 QCR:{inbound_line_id}:{op_seq}；整池解锁如 LTH:{live_tank_hold_id}:{inspection_id}:{hold_id}），
-- 与 inbound_line.qc_passed 累加、stock_hold 释放、stock.quality_hold 扣减同一事务；重放撞 uq_hr_op → 整个事务回滚，不重复解冻。只追加。
-- 没有 qc_line 表。质检单 = inbound_order，质检行 = inbound_line（第 3/10 篇）。本表 source 不存行 id。
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
    occurred_at         TIMESTAMP       NOT NULL DEFAULT (datetime('now')),  -- 冗余，便于按 key 找到所在分区；#2 第十一轮：服务端时间（trg_mvk_zclock）
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
    biz_type                    VARCHAR(24)     NOT NULL,   -- RECEIVE/PUTAWAY/PICK/REVERSE_PICK/SHIP/MOVE/ADJUST/COUNT/RETURN/SCRAP/CROSS_DOCK/OPENING/PROCESS_ISSUE/PROCESS_CONSUME/PROCESS_OUTPUT/PROCESS_REVERSE（无 CHECK，第 17 篇登记）
    direction                   SMALLINT        NOT NULL,   -- 1 入 / -1 出 / 0 纯事件（如 SHIP，不改 on_hand）
    stock_id                    BIGINT          NOT NULL,   -- 记账到哪一行库存，按行回放的依据
    hold_id                     BIGINT,                     -- 冻结类流水指向单条 stock_hold；非冻结流水 NULL。I3f/I3g 按此对账，不按 stock 汇总
    stock_seq                   BIGINT          NOT NULL,   -- = 该次条件 UPDATE 后的 stock.ledger_seq；direction=0 时填当前 ledger_seq（不入链）
    warehouse_id                BIGINT          NOT NULL REFERENCES warehouse(id),
    location_id                 BIGINT          NOT NULL REFERENCES location(id),
    from_location_id            BIGINT REFERENCES location(id),
    sku_id                      BIGINT          NOT NULL REFERENCES sku(id),
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
    occurred_at                 TIMESTAMP       NOT NULL DEFAULT (datetime('now')),  -- #2 第十一轮：服务端时间（trg_mv_zclock），00 §6.8 第 7 条
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
    CONSTRAINT fk_mv_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
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
CREATE INDEX ix_mv_hold     ON stock_movement(hold_id) WHERE hold_id IS NOT NULL;
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
-- search_path 固定为 pg_catalog, public。函数体里的 stock_ledger_line 不写 schema，在这条路径下只解析到 public；调用方把自己的 schema 放在前面也看不见。
CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key
WHEN NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind
                 AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id))
BEGIN SELECT RAISE(ABORT, 'ledger_line_owner_mismatch'); END;

-- 归属行的来源不可改（小赵 C3）：src_kind / biz_no / line_no 写入后禁止 UPDATE，否则把 PDA 行改成 DOC 就能绕过互斥
-- search_path 固定为 pg_catalog, public。函数体只比较 NEW/OLD，没有名字查找。
CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line
WHEN NEW.src_kind IS NOT OLD.src_kind OR NEW.biz_no IS NOT OLD.biz_no OR NEW.line_no IS NOT OLD.line_no
BEGIN SELECT RAISE(ABORT, 'ledger_line_immutable'); END;

-- 冻结明细写入后不可改（小赵 N1）：只放行释放路径要写的 released_qty_milli / status / version / updated_at。
-- 类型转换只走 convert_hold（关旧建新），任何路径都不需要改 hold_type；否则先把 SCRAP_PENDING 改成 MANUAL 就能绕过 40933。
-- convert_hold 加锁顺序（docs/02 §7.1.1、§8.2；PG 与 SQLite 同一条）：
--   先锁 stock 行（SELECT … WHERE id = :stock_id ORDER BY id），再锁 stock_hold（ORDER BY id），
--   然后才改 released/status、插入子明细；跨列时最后改 stock 数量。
--   同列转换不改 stock 数量和 version，也要先锁 stock，避免和 release/consume 交叉等锁。
--   PG 在这两条 SELECT 上加 FOR UPDATE；SQLite 没有行锁，语句顺序相同，写事务用 BEGIN IMMEDIATE。
-- search_path 固定为 pg_catalog, public。函数体只比较 NEW/OLD，没有名字查找。
-- R2：冻结明细不可删除（wms_app 本就没有 DELETE/TRUNCATE 权限；这里兜底超级用户/迁移脚本，与流水表写法一致）
-- search_path 固定为 pg_catalog, public。函数体只 RAISE，没有名字查找。
-- stock_hold_release 只追加（A3）；TRUNCATE 也拦（小赵 S5）
CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold
WHEN NEW.id IS NOT OLD.id OR NEW.stock_id IS NOT OLD.stock_id OR NEW.hold_type IS NOT OLD.hold_type OR NEW.reason_code IS NOT OLD.reason_code
  OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.op_key IS NOT OLD.op_key
  OR NEW.hold_qty_milli IS NOT OLD.hold_qty_milli OR NEW.operator_id IS NOT OLD.operator_id OR NEW.created_at IS NOT OLD.created_at
  OR NEW.approval_type IS NOT OLD.approval_type OR NEW.approval_no IS NOT OLD.approval_no OR NEW.is_reversal IS NOT OLD.is_reversal
  OR NEW.from_hold_id IS NOT OLD.from_hold_id
  OR NEW.released_qty_milli < OLD.released_qty_milli OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED')
BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- R2（SQLite）：拒删除；REPLACE 冲突时删旧行在 recursive_triggers=OFF（默认，且是连接级开关）下不触发 DELETE 触发器，
-- 所以另用 BEFORE INSERT 在 id / op_key 已存在时直接 ABORT，REPLACE 走不到删除那一步（库级生效，不依赖连接设置）
CREATE TRIGGER trg_hold_no_delete BEFORE DELETE ON stock_hold BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
CREATE TRIGGER trg_hold_no_replace BEFORE INSERT ON stock_hold
WHEN EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.id OR h.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;
-- 第十二轮（r11 X1/X2）：uq_hold_return（部分索引，同谓词）
CREATE TRIGGER trg_hold_no_replace_ret BEFORE INSERT ON stock_hold WHEN EXISTS (SELECT 1 FROM stock_hold h WHERE NEW.hold_type = 'RETURN_PENDING' AND h.hold_type = 'RETURN_PENDING' AND h.source_id = NEW.source_id)
BEGIN SELECT RAISE(ABORT, 'hold_duplicate: stock_hold.source_id'); END;

-- 只追加：流水表与去重表禁止 UPDATE / DELETE。PG 侧收回应用角色权限 + 触发器（防超级用户/运维脚本误操作）；SQLite 侧触发器
-- search_path 固定为 pg_catalog, public。函数体只用 TG_TABLE_NAME。
-- #2 第十一轮（小玛丽 r10 R2）：流水与 key 的 occurred_at 由 02 原语写，是服务端时间（00 §6.8 第 7 条）。
-- PG：非表属主写入一律改成 date_trunc('second', now() AT TIME ZONE 'UTC')（同一事务内 now() 不变，key 与流水取到同一值，fk_mv_key 对得上）。
--     stock_movement 按月分区，BEFORE 行触发器建在父表上（PG13+ 自动克隆到各分区），在路由之后执行，不能把行改到别的分区：
--     调用方的值与库时钟不在同一个月时直接拒 movement_clock_skew（→ 40003），同月则覆盖。原语不传 occurred_at（走 DEFAULT）就不会撞上。
--     表属主（迁移 / 期初导入 / verify 种子）不受约束，同 10 trg_srtn_zclock、11 trg_outbox_insert_pending 的属主口径。
-- SQLite（不能改 NEW）：trg_mv_clock / trg_mvk_clock 拒非整秒 UTC 或与 now 相差 > 300 s（movement_clock_skew → 40003）。
CREATE TRIGGER trg_mv_clock BEFORE INSERT ON stock_movement
WHEN NEW.occurred_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' OR substr(NEW.occurred_at, 12, 2) > '23' OR strftime('%s', NEW.occurred_at) IS NULL
  OR abs(CAST(strftime('%s', NEW.occurred_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'movement_clock_skew'); END;
CREATE TRIGGER trg_mvk_clock BEFORE INSERT ON stock_movement_key
WHEN NEW.occurred_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' OR substr(NEW.occurred_at, 12, 2) > '23' OR strftime('%s', NEW.occurred_at) IS NULL
  OR abs(CAST(strftime('%s', NEW.occurred_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'movement_clock_skew'); END;
-- TRUNCATE 不触发行级触发器，单独加语句级触发器拦（小赵 C5）；归档走 DETACH PARTITION，不用 TRUNCATE
-- 应用角色授权清单（小赵 C3，docs/02 §4.9）：库存类表只给 SELECT/INSERT/UPDATE，不给 DELETE/TRUNCATE；
-- stock_ledger_line 只能改换主相关列（第 5 篇改派/重新领取），来源与单据行由 trg_sll_immutable 再拦一道（防超级用户/迁移脚本）
-- stock_hold 只授释放相关列（小赵 N1）；其余列由 trg_hold_immutable 再拦一道（防超级用户/迁移脚本）
CREATE TRIGGER trg_mv_no_update  BEFORE UPDATE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- #2 第十一轮：只追加表也要防 REPLACE（REPLACE 删旧行不触发 DELETE 触发器）。
-- #2 第十二轮（小玛丽 r11 X1）：表上**每个**唯一键都要拦，不只主键——REPLACE 撞任意唯一键都会删掉那一行，且 SQLite 的隐式删除不做外键检查。
-- 部分唯一索引按索引谓词收窄（与索引同条件），否则会误拦合法行。
CREATE TRIGGER trg_mv_no_replace  BEFORE INSERT ON stock_movement     WHEN EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = NEW.id AND m.occurred_at = NEW.occurred_at) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- 每个唯一键一个触发器，报错尾部与 UNIQUE 冲突同名（便于两库用例按同一键断言）。SQLite 后建的触发器先触发：seq 放最后，多键同撞时先报账序分叉，与 UNIQUE 判定顺序一致
CREATE TRIGGER trg_mvk_no_replace BEFORE INSERT ON stock_movement_key WHEN EXISTS (SELECT 1 FROM stock_movement_key k WHERE k.movement_id = NEW.movement_id) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
CREATE TRIGGER trg_mvk_no_replace_idem BEFORE INSERT ON stock_movement_key WHEN EXISTS (SELECT 1 FROM stock_movement_key k WHERE k.idempotency_key = NEW.idempotency_key) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key.idempotency_key'); END;
CREATE TRIGGER trg_mvk_no_replace_biz BEFORE INSERT ON stock_movement_key WHEN EXISTS (SELECT 1 FROM stock_movement_key k WHERE NEW.src_kind = 'DOC' AND k.src_kind = 'DOC' AND k.biz_no = NEW.biz_no AND k.line_no = NEW.line_no AND k.op_no = NEW.op_no AND k.leg = NEW.leg) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key.biz_no, stock_movement_key.line_no, stock_movement_key.op_no, stock_movement_key.leg'); END;
CREATE TRIGGER trg_mvk_no_replace_pda BEFORE INSERT ON stock_movement_key WHEN EXISTS (SELECT 1 FROM stock_movement_key k WHERE NEW.src_kind = 'PDA' AND k.src_kind = 'PDA' AND k.src_task_id = NEW.src_task_id AND k.src_line_no = NEW.src_line_no AND k.device_instance_id = NEW.device_instance_id AND k.src_op_seq = NEW.src_op_seq AND k.leg = NEW.leg) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key.src_task_id, stock_movement_key.src_line_no, stock_movement_key.device_instance_id, stock_movement_key.src_op_seq, stock_movement_key.leg'); END;
CREATE TRIGGER trg_mvk_no_replace_seq BEFORE INSERT ON stock_movement_key WHEN EXISTS (SELECT 1 FROM stock_movement_key k WHERE NEW.direction <> 0 AND k.direction <> 0 AND k.stock_id = NEW.stock_id AND k.stock_seq = NEW.stock_seq) BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key.stock_id, stock_movement_key.stock_seq'); END;
-- stock_ledger_line：第十二轮起 02 原语改成"先查再插"（INSERT … SELECT … WHERE NOT EXISTS），重放不再产生插入，所以可以加防 REPLACE
CREATE TRIGGER trg_sll_no_replace BEFORE INSERT ON stock_ledger_line WHEN EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no)
BEGIN SELECT RAISE(ABORT, 'ledger_line_duplicate'); END;
CREATE TRIGGER trg_mv_no_delete  BEFORE DELETE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
CREATE TRIGGER trg_mvk_no_update BEFORE UPDATE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
CREATE TRIGGER trg_mvk_no_delete BEFORE DELETE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
-- 归档：PG 侧按分区 DETACH（DDL，不触发行级触发器，需 DBA 权限）；SQLite 侧导出后由维护脚本 DROP 触发器→删除→重建，全程审计

CREATE TABLE stock_snapshot_daily (
    work_date               DATE            NOT NULL,
    stock_id                BIGINT          NOT NULL,
    warehouse_id            BIGINT          NOT NULL REFERENCES warehouse(id),
    location_id             BIGINT          NOT NULL REFERENCES location(id),
    sku_id                  BIGINT          NOT NULL REFERENCES sku(id),
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
    CONSTRAINT ck_ssd_date CHECK (work_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(work_date) IS work_date),
    PRIMARY KEY (work_date, stock_id)
);
-- #2 第十二轮：日快照一天一行，REPLACE 会改写历史快照 → 先拦（重跑快照任务按主键先查）
CREATE TRIGGER trg_snap_no_replace BEFORE INSERT ON stock_snapshot_daily WHEN EXISTS (SELECT 1 FROM stock_snapshot_daily d WHERE d.work_date = NEW.work_date AND d.stock_id = NEW.stock_id)
BEGIN SELECT RAISE(ABORT, 'snapshot_duplicate: stock_snapshot_daily.work_date, stock_snapshot_daily.stock_id'); END;
CREATE INDEX ix_snap_sku ON stock_snapshot_daily(work_date, warehouse_id, sku_id, lot_id);

CREATE TABLE stock_recon_alert (
    id                      BIGINT          PRIMARY KEY,
    check_code              VARCHAR(24)     NOT NULL,   -- 码表见 ck_recon_code；CHECK_BOX_MISMATCH 18 位，16 放不下
    warehouse_id            BIGINT          NOT NULL REFERENCES warehouse(id),
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
    CONSTRAINT ck_recon_code CHECK (check_code IN ('I3a','I3b','I3c','I3d','I3e','I4','I5','SNAP','RR_HOLD_FAILED','RR_HOLD_MISMATCH','CHECK_BOX_MISMATCH','SHIP_EVENT_MISSING','LIVE_COUNT_WEIGHT','LIVE_COUNT_LEDGER','LIVE_HOLD_MISMATCH','LIVE_INSPECT_OVERDUE'))   -- 码表见 docs/02 §4.6；活鲜四码见第 18 篇 §9 / Q6
);
CREATE INDEX ix_recon_open ON stock_recon_alert(warehouse_id, status, detected_at DESC);
CREATE UNIQUE INDEX uq_recon_open ON stock_recon_alert(check_code, warehouse_id, stock_id) WHERE status <> 'RESOLVED';
-- #2 第十二轮（r12 非阻塞 1）：RESOLVED 是终态，闭环后的 resolved_by / resolution / stock_id / detected_at 不能再改（UPDATE 拒，REPLACE 撞 id 拒）。
-- 未闭环告警仍走 INSERT … ON CONFLICT (uq_recon_open) DO UPDATE 累加 hit_count，所以 uq_recon_open 不加 BEFORE INSERT 守卫（键级豁免，见 00 §6.10）；
-- 经 uq_recon_open 的 REPLACE 只能碰到未闭环行（索引谓词 status <> 'RESOLVED'），会把未闭环告警整行重写（hit_count、detected_at 重置）——与 UPDATE 本来就能做的一样，不涉及库存数量。
CREATE TRIGGER trg_recon_resolved_lock BEFORE UPDATE ON stock_recon_alert WHEN OLD.status = 'RESOLVED' BEGIN SELECT RAISE(ABORT, 'recon_resolved_immutable'); END;
CREATE TRIGGER trg_recon_no_delete BEFORE DELETE ON stock_recon_alert WHEN OLD.status = 'RESOLVED' BEGIN SELECT RAISE(ABORT, 'recon_resolved_immutable'); END;
CREATE TRIGGER trg_recon_no_replace BEFORE INSERT ON stock_recon_alert WHEN EXISTS (SELECT 1 FROM stock_recon_alert a WHERE a.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'recon_duplicate: stock_recon_alert.id'); END;
-- ↑ 未闭环的同一差异只有一条；对账任务用 INSERT … ON CONFLICT DO UPDATE SET hit_count = hit_count + 1, last_seen_at = …
--   （PG 与 SQLite ≥ 3.24 写法相同；部分唯一索引作冲突目标时两库都要求带同样的 WHERE）

-- 对账只告警不修数：本表只记录差异，任何修正必须走调整单（adjust_order）+ 审批生成新流水
-- =============================================================================
-- 第 3 篇 入库：收货、质检、上架（docs/03-入库.md）
--   库存只经第 2 篇原语：收货 post_in(RECEIVE) + hold(QUALITY, QC_PENDING)（UC1）；质检放行 unhold / 不合格 convert_hold → SCRAP_PENDING
--   （UC9；不合格、待处置一律 hold(SCRAP_PENDING)，挂 09 报损单）；上架 move(PUTAWAY)（UC2）；关单后收货更正单 post_in / post_out(ADJUST)。本文件不写 stock。
--   数量一律 BIGINT *_qty_milli（00 R2）；温度一律 *_c10（0.1 ℃ 整数）；时长一律 *_sec。
--   #5（10_returns.sql）对 inbound_order / inbound_line 的 ALTER（ck_inb_rtn_src、received/qc_passed/qc_failed 三列、
--   ck_inbl_int、ck_inbl_qc）已在基线落库，本篇不重复定义，也不改 10_returns.sql；本篇自己的整数约束叫 ck_inbl_int3。
--   本篇新建的 PG 函数一律 SET search_path = pg_catalog, public。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 入库单头
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,   -- INB-/RTN- 前缀 + 00 §6.2 单号
    warehouse_id    BIGINT       NOT NULL,
    order_type      VARCHAR(24)  NOT NULL,   -- PURCHASE / RETURN / TRANSFER_IN
    source_system   VARCHAR(24)  NOT NULL,
    source_order_no VARCHAR(64)  NOT NULL,
    source_hash     CHAR(64),                -- 上游推单内容哈希（00 §6.5），小写 hex；内部生成的单（拒收回仓、盲收）可空
    supplier_id     BIGINT,
    status          VARCHAR(24)  NOT NULL DEFAULT 'CREATED',   -- 见 ck_inb_status
    work_date       DATE         NOT NULL,
    expected_at     TIMESTAMP,               -- 上游给的预计到货；预约到货 / 月台排班未定（03 §12 Q1），不建表
    dock_code       VARCHAR(32),             -- 实际卸货月台（自由文本，不做排班）
    vehicle_no      VARCHAR(24),
    arrived_at      TIMESTAMP,               -- 车辆到场（登记到货）
    unload_start_at TIMESTAMP,               -- 开始卸货 = 离开车厢冷链的起点（默认值，行上可覆盖）
    received_at     TIMESTAMP,
    closed_at       TIMESTAMP,
    supplier_reconciled_at TIMESTAMP,        -- 供应商对账结算时间（11 回写）；非空后不再接受收货更正（转 08）
    remark          VARCHAR(512),
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    created_by      BIGINT,
    CONSTRAINT uq_inb_code  UNIQUE (code),
    CONSTRAINT uq_inb_src   UNIQUE (source_system, source_order_no),   -- 业务层幂等（00 §6.5）
    CONSTRAINT ck_inb_type  CHECK (order_type IN ('PURCHASE','RETURN','TRANSFER_IN')),
    CONSTRAINT ck_inb_status CHECK (status IN ('CREATED','ARRIVED','RECEIVING','RECEIVED','PUTTING_AWAY','COMPLETED','CANCELLED')),
    CONSTRAINT ck_inb_hash  CHECK (source_hash IS NULL OR (length(source_hash) = 64 AND lower(source_hash) = source_hash)),
    -- 退货入库来源白名单 ck_inb_rtn_src 由 10_returns.sql ALTER（README 跨篇登记表），本篇不重复
    CONSTRAINT ck_inb_closed CHECK (status NOT IN ('COMPLETED','CANCELLED') OR closed_at IS NOT NULL),
    CONSTRAINT ck_inb_recon  CHECK (supplier_reconciled_at IS NULL OR (status = 'COMPLETED' AND supplier_reconciled_at >= closed_at)),
    CONSTRAINT fk_inb_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    -- 时间列整秒（B2）：PG 不许小数秒；SQLite 只收 'YYYY-MM-DD HH:MM:SS'（拒非 ISO、时区偏移、小数秒）。时区约定见 docs/03 §12 Q11
    CONSTRAINT ck_inb_ts CHECK ((closed_at IS NULL OR (typeof(closed_at) = 'text' AND length(closed_at) = 19 AND datetime(closed_at) IS closed_at)) AND (supplier_reconciled_at IS NULL OR (typeof(supplier_reconciled_at) = 'text' AND length(supplier_reconciled_at) = 19 AND datetime(supplier_reconciled_at) IS supplier_reconciled_at))),
    CONSTRAINT ck_inb_ts2 CHECK ((expected_at IS NULL OR (typeof(expected_at) = 'text' AND length(expected_at) = 19 AND datetime(expected_at) IS expected_at)) AND (arrived_at IS NULL OR (typeof(arrived_at) = 'text' AND length(arrived_at) = 19 AND datetime(arrived_at) IS arrived_at)) AND (unload_start_at IS NULL OR (typeof(unload_start_at) = 'text' AND length(unload_start_at) = 19 AND datetime(unload_start_at) IS unload_start_at)) AND (received_at IS NULL OR (typeof(received_at) = 'text' AND length(received_at) = 19 AND datetime(received_at) IS received_at))),
    CONSTRAINT ck_inb_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_inb_date CHECK ((work_date IS NULL OR (typeof(work_date) = 'text' AND length(work_date) = 10 AND date(work_date) IS work_date))),
    CONSTRAINT uq_inb_closed UNIQUE (id, closed_at)   -- 收货更正单组合外键：关单时间快照必须是真值
);
CREATE INDEX ix_inb_wh_status ON inbound_order(warehouse_id, status, work_date DESC);

-- -----------------------------------------------------------------------------
-- 入库行（也是质检行：02 §7.1.3 release_qc_hold 在这里累加 qc_passed）
--   received_qty_milli / qc_passed_qty_milli / qc_failed_qty_milli 三列和 ck_inbl_int、ck_inbl_qc 由 10_returns.sql ALTER 加（基线已有）。
--   received_qty_milli = Σ 收货记录（关单前维护）；关单后行不再改，净实收 = received_qty_milli + Σ inbound_correction(direction × qty)
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_line (
    id                  BIGINT       PRIMARY KEY,
    inbound_id          BIGINT       NOT NULL,   -- inbound_order.id（02 §7.1.3 写作 inbound_order_id，指的就是这一列）
    line_no             SMALLINT     NOT NULL,
    sku_id              BIGINT       NOT NULL,
    uom                 VARCHAR(16)  NOT NULL,   -- = sku.base_uom
    temp_zone           VARCHAR(16),             -- 下单时快照 sku.temperature_required：AMBIENT/CHILLED/FROZEN/FRESH
    ordered_qty_milli   BIGINT       NOT NULL DEFAULT 0,
    rejected_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 月台拒收（不入账）
    putaway_qty_milli   BIGINT       NOT NULL DEFAULT 0,
    lot_id              BIGINT,
    production_date     DATE,
    expiry_date         DATE,
    cost_amount_fen     BIGINT,
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_inb_line UNIQUE (inbound_id, line_no),
    CONSTRAINT uq_inbl_ord UNIQUE (id, inbound_id),          -- 子表组合外键用：记录必须挂在本单的行上
    CONSTRAINT fk_inbl_order FOREIGN KEY (inbound_id) REFERENCES inbound_order(id),
    CONSTRAINT fk_inbl_sku   FOREIGN KEY (sku_id) REFERENCES sku(id),   -- R3：sku_id 补外键（小玛丽 r12）
    CONSTRAINT ck_inbl_tz  CHECK (temp_zone IS NULL OR temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_inbl_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_inbl_int3 CHECK (ordered_qty_milli = CAST(ordered_qty_milli AS BIGINT)
        AND rejected_qty_milli = CAST(rejected_qty_milli AS BIGINT) AND putaway_qty_milli = CAST(putaway_qty_milli AS BIGINT)),
    CONSTRAINT ck_inbl_date CHECK ((production_date IS NULL OR (typeof(production_date) = 'text' AND length(production_date) = 10 AND date(production_date) IS production_date)) AND (expiry_date IS NULL OR (typeof(expiry_date) = 'text' AND length(expiry_date) = 10 AND date(expiry_date) IS expiry_date))),
    CONSTRAINT ck_inbl_qty CHECK (ordered_qty_milli >= 0 AND rejected_qty_milli >= 0 AND putaway_qty_milli >= 0)
    -- 「上架 ≤ 质检合格」要引用 qc_passed_qty_milli（10 的 ALTER 列，03 建表时还不存在），改由上架原语条件更新兜底，见 docs/03 §6.3
);
CREATE INDEX ix_inbl_sku ON inbound_line(sku_id, inbound_id);

-- -----------------------------------------------------------------------------
-- 到货测温（只追加）：scope=ZONE 按温区整车/整批测一次；scope=LINE 按行测（冷藏/冷冻行必测）
--   上下限是测温当时从温区配置取的快照；result 必须和读数一致；不合格只能拒收或转质检冻结
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_temp_check (
    id              BIGINT       PRIMARY KEY,
    warehouse_id    BIGINT       NOT NULL,
    inbound_id      BIGINT       NOT NULL,
    scope           VARCHAR(8)   NOT NULL,   -- ZONE / LINE
    temp_zone       VARCHAR(16)  NOT NULL,
    inbound_line_id BIGINT,                  -- scope=LINE 必填
    measured_c10    INTEGER      NOT NULL,   -- 实测中心温度 ×10
    min_c10         INTEGER,                 -- 快照；AMBIENT 可空
    max_c10         INTEGER,
    result          VARCHAR(8)   NOT NULL,   -- PASS / FAIL
    disposition     VARCHAR(8)   NOT NULL,   -- ACCEPT / QC_HOLD / REJECT
    op_key          VARCHAR(80)  NOT NULL,   -- TMP:{inbound_id}:{client_uuid}
    measured_by     BIGINT       NOT NULL,
    measured_at     TIMESTAMP    NOT NULL,
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_itc_op   UNIQUE (op_key),
    CONSTRAINT uq_itc_ref  UNIQUE (id, inbound_id, disposition),
    CONSTRAINT fk_itc_order FOREIGN KEY (inbound_id) REFERENCES inbound_order(id),
    CONSTRAINT fk_itc_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT ck_itc_scope CHECK ((scope = 'ZONE' AND inbound_line_id IS NULL) OR (scope = 'LINE' AND inbound_line_id IS NOT NULL)),
    CONSTRAINT ck_itc_tz   CHECK (temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_itc_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_itc_range CHECK (measured_c10 BETWEEN -600 AND 600 AND (min_c10 IS NULL OR max_c10 IS NULL OR min_c10 <= max_c10)
        AND (temp_zone = 'AMBIENT' OR (min_c10 IS NOT NULL OR max_c10 IS NOT NULL))),
    CONSTRAINT ck_itc_result CHECK (
        (result = 'PASS' AND (min_c10 IS NULL OR measured_c10 >= min_c10) AND (max_c10 IS NULL OR measured_c10 <= max_c10))
        OR (result = 'FAIL' AND ((min_c10 IS NOT NULL AND measured_c10 < min_c10) OR (max_c10 IS NOT NULL AND measured_c10 > max_c10)))),
    CONSTRAINT ck_itc_ts CHECK ((measured_at IS NULL OR (typeof(measured_at) = 'text' AND length(measured_at) = 19 AND datetime(measured_at) IS measured_at))),
    CONSTRAINT ck_itc_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_itc_disp CHECK (disposition IN ('ACCEPT','QC_HOLD','REJECT') AND (result = 'PASS' OR disposition <> 'ACCEPT'))
);
CREATE INDEX ix_itc_order ON inbound_temp_check(inbound_id, temp_zone);

-- -----------------------------------------------------------------------------
-- 收货记录（只追加，UC1）：一次收货 = post_in(RECEIVE) 到收货暂存位 + hold(QUALITY, QC_PENDING) 同量
--   冷链：offchain_sec = 离开车厢冷链到进入收货暂存冷区的秒数；上限是温区配置快照（未查到盒马 DC 标准，可配置）
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_receipt (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,   -- RCV:{inbound_line_id}:{op_seq}；PDA 另走流水四元组
    qty_milli           BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,   -- 收货暂存位库存行（post_in 目标）
    hold_id             BIGINT       NOT NULL,   -- 同事务 hold(QUALITY, QC_PENDING)
    movement_biz_no     VARCHAR(64)  NOT NULL,   -- 流水 biz_no（= inbound_order.code）
    lot_id              BIGINT,
    temp_zone           VARCHAR(16)  NOT NULL,
    temp_check_id       BIGINT,                  -- 非 AMBIENT 必填，且只能引用 ACCEPT / QC_HOLD 的测温
    temp_check_disp     VARCHAR(8),
    offchain_start_at   TIMESTAMP,
    offchain_end_at     TIMESTAMP,
    offchain_sec        INTEGER,
    offchain_limit_sec  INTEGER,                 -- 快照（可配置）
    is_offchain_over    SMALLINT     NOT NULL DEFAULT 0,
    received_by         BIGINT       NOT NULL,
    received_at         TIMESTAMP    NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_rcp_op   UNIQUE (op_key),
    CONSTRAINT uq_rcp_hold UNIQUE (hold_id),
    CONSTRAINT uq_rcp_ref  UNIQUE (id, inbound_line_id, received_by),   -- 上架记录 SoD 组合外键用
    CONSTRAINT fk_rcp_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_rcp_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_rcp_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_rcp_temp FOREIGN KEY (temp_check_id, inbound_id, temp_check_disp) REFERENCES inbound_temp_check(id, inbound_id, disposition),
    CONSTRAINT ck_rcp_qty  CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_rcp_tz   CHECK (temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_rcp_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_rcp_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_rcp_temp CHECK (
        (temp_check_id IS NULL AND temp_check_disp IS NULL AND temp_zone = 'AMBIENT')
        OR (temp_check_id IS NOT NULL AND temp_check_disp IN ('ACCEPT','QC_HOLD'))),
    CONSTRAINT ck_rcp_ts CHECK ((offchain_start_at IS NULL OR (typeof(offchain_start_at) = 'text' AND length(offchain_start_at) = 19 AND datetime(offchain_start_at) IS offchain_start_at)) AND (offchain_end_at IS NULL OR (typeof(offchain_end_at) = 'text' AND length(offchain_end_at) = 19 AND datetime(offchain_end_at) IS offchain_end_at)) AND (received_at IS NULL OR (typeof(received_at) = 'text' AND length(received_at) = 19 AND datetime(received_at) IS received_at))),
    CONSTRAINT ck_rcp_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_rcp_chain CHECK (
        (temp_zone = 'AMBIENT' AND offchain_sec IS NULL AND is_offchain_over = 0)
        OR (temp_zone <> 'AMBIENT' AND offchain_start_at IS NOT NULL AND offchain_end_at IS NOT NULL
            AND offchain_sec IS NOT NULL AND offchain_sec >= 0 AND offchain_limit_sec IS NOT NULL AND offchain_limit_sec > 0
            AND is_offchain_over = (CASE WHEN offchain_sec > offchain_limit_sec THEN 1 ELSE 0 END)))
);
CREATE INDEX ix_rcp_line ON inbound_receipt(inbound_line_id, received_at);

-- -----------------------------------------------------------------------------
-- 收货更正单（只追加，盒马「收货更正」对应物；fresh-rules-decisions §5）：关单后不改原单、不改收货记录、不改入库行，
--   只经 02 原语补一条正/反向流水：+ post_in(ADJUST)，− post_out(ADJUST)（biz_type=ADJUST，biz_no = 本更正单号），movement_id 挂这条流水。
--   一行 = 一张已终审、已过账的更正单（审批在 12 审批单 approval_no 上走完再落本表）。审批窗口按 approved_at − 关单时间：
--     ≤ 24h：approval_tier=SUPERVISOR（仓库主管）；> 24h 且 ≤ 7d：DUAL（主管 + 采购）；> 7d 或已对账结算：拒绝，改走 08 盘点差异/库存调整。
--   收货人（received_by，经组合外键从收货记录带过来）不能当任何一级审批人；申请人也不能自批。
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_correction (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(64)  NOT NULL,   -- IRC- 前缀单号（00 §6.2），也是流水 biz_no
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    receipt_id          BIGINT       NOT NULL,   -- 被更正的收货记录（不改它）
    received_by         BIGINT       NOT NULL,   -- = 该收货记录的 received_by（fk_irc_rcp）
    order_closed_at     TIMESTAMP    NOT NULL,   -- = inbound_order.closed_at（fk_irc_closed），窗口起点
    op_key              VARCHAR(80)  NOT NULL,   -- IRC:{receipt_id}:{op_seq}
    direction           SMALLINT     NOT NULL,   -- 1 正向补收 / -1 反向冲减
    qty_milli           BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,   -- 过账的库存行
    movement_id         BIGINT       NOT NULL,   -- 02 原语写出的 ADJUST 流水（trg_irc_guard 核对方向、数量、库存行、biz_no）
    reason_code         VARCHAR(16)  NOT NULL,   -- COUNT_ERROR / WEIGHT_ERROR / WRONG_SKU / WRONG_BATCH / QUALITY_FOUND / OTHER
    reason_note         VARCHAR(512),            -- OTHER 必填
    approval_no         VARCHAR(64)  NOT NULL,   -- 12 审批单号 APR-…
    approval_tier       VARCHAR(16)  NOT NULL,   -- SUPERVISOR / DUAL
    requested_by        BIGINT       NOT NULL,
    requested_at        TIMESTAMP    NOT NULL,
    supervisor_id       BIGINT       NOT NULL,
    purchasing_id       BIGINT,                  -- DUAL 必填
    approved_at         TIMESTAMP    NOT NULL,   -- 终审 = 过账时间（B3）：PG 非属主写入由 trg_irc_guard 覆盖成库时钟（statement_timestamp，整秒 UTC）；SQLite 须在 now ±300s 内（trg_irc_now），窗口按落库 approved_at 算
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_irc_code UNIQUE (code),
    CONSTRAINT uq_irc_op   UNIQUE (op_key),
    CONSTRAINT uq_irc_mv   UNIQUE (movement_id),   -- 一条流水只能挂一张更正单
    CONSTRAINT fk_irc_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_irc_rcp FOREIGN KEY (receipt_id, inbound_line_id, received_by) REFERENCES inbound_receipt(id, inbound_line_id, received_by),
    CONSTRAINT fk_irc_closed FOREIGN KEY (inbound_id, order_closed_at) REFERENCES inbound_order(id, closed_at),
    CONSTRAINT fk_irc_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_irc_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id),
    CONSTRAINT ck_irc_dir CHECK (direction IN (1, -1)),
    CONSTRAINT ck_irc_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_irc_reason CHECK (reason_code IN ('COUNT_ERROR','WEIGHT_ERROR','WRONG_SKU','WRONG_BATCH','QUALITY_FOUND','OTHER')
        AND (reason_code <> 'OTHER' OR (reason_note IS NOT NULL AND length(trim(reason_note)) >= 4))),
    CONSTRAINT ck_irc_apr CHECK (approval_no LIKE 'APR-%' AND length(approval_no) BETWEEN 22 AND 36),
    CONSTRAINT ck_irc_tier CHECK ((approval_tier = 'SUPERVISOR' AND purchasing_id IS NULL)
        OR (approval_tier = 'DUAL' AND purchasing_id IS NOT NULL AND purchasing_id <> supervisor_id)),
    -- 职责分离（§5.2）：收货人不能审批（任何一级）
    CONSTRAINT ck_irc_receiver_sod CHECK (supervisor_id <> received_by AND (purchasing_id IS NULL OR purchasing_id <> received_by)),
    -- 申请人不能自批
    CONSTRAINT ck_irc_self_apr CHECK (supervisor_id <> requested_by AND (purchasing_id IS NULL OR purchasing_id <> requested_by)),
    CONSTRAINT ck_irc_time CHECK (requested_at <= approved_at),
    CONSTRAINT fk_irc_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_irc_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_irc_ts CHECK ((order_closed_at IS NULL OR (typeof(order_closed_at) = 'text' AND length(order_closed_at) = 19 AND datetime(order_closed_at) IS order_closed_at)) AND (requested_at IS NULL OR (typeof(requested_at) = 'text' AND length(requested_at) = 19 AND datetime(requested_at) IS requested_at)) AND (approved_at IS NULL OR (typeof(approved_at) = 'text' AND length(approved_at) = 19 AND datetime(approved_at) IS approved_at)))
);
CREATE INDEX ix_irc_line ON inbound_correction(inbound_line_id);

-- -----------------------------------------------------------------------------
-- 上架记录（只追加，UC2）：move(PUTAWAY) 暂存位 → 存储位。received_by 经组合外键从收货记录带过来，
--   ck_inbp_sod 在库层拦「收货人 = 上架人」（00 §2 SoD）。小仓放宽须带审批单号（00：放宽本身要记审计），格式同 12b ck_apr_code（ck_inbp_waiver，两库都区分大小写）。
--   计数：trg_inbp_apply（AFTER INSERT，PG SECURITY DEFINER）累加 inbound_line.putaway_qty_milli，超 qc_passed 或单已关即报错；wms_app 不能直接 UPDATE 计数列
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_putaway (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    receipt_id          BIGINT       NOT NULL,
    received_by         BIGINT       NOT NULL,   -- 必须等于该收货记录的 received_by（fk_inbp_rcp）
    putaway_by          BIGINT       NOT NULL,
    sod_waiver_no       VARCHAR(64),             -- 放宽 SoD 的审批单号；为空即强制分离
    op_key              VARCHAR(80)  NOT NULL,   -- PUT:{receipt_id}:{op_seq}
    from_stock_id       BIGINT       NOT NULL,
    to_location_id      BIGINT       NOT NULL,
    qty_milli           BIGINT       NOT NULL,
    movement_biz_no     VARCHAR(64)  NOT NULL,
    offchain_sec        INTEGER,                 -- 暂存位 → 存储位途中离开冷链的秒数（非 AMBIENT 必填）
    putaway_at          TIMESTAMP    NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_inbp_op  UNIQUE (op_key),
    CONSTRAINT fk_inbp_rcp FOREIGN KEY (receipt_id, inbound_line_id, received_by) REFERENCES inbound_receipt(id, inbound_line_id, received_by),
    CONSTRAINT fk_inbp_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_inbp_loc FOREIGN KEY (to_location_id) REFERENCES location(id),
    CONSTRAINT ck_inbp_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_inbp_sod CHECK (putaway_by <> received_by OR sod_waiver_no IS NOT NULL),
    CONSTRAINT fk_inbp_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_inbp_waiver CHECK (sod_waiver_no IS NULL OR (length(sod_waiver_no) BETWEEN 22 AND 36 AND substr(sod_waiver_no, 1, 4) = 'APR-' AND substr(sod_waiver_no, 5, length(sod_waiver_no) - 20) NOT GLOB '*[^A-Z0-9]*' AND substr(sod_waiver_no, 5, length(sod_waiver_no) - 20) <> '' AND substr(sod_waiver_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' AND (substr(sod_waiver_no, -11, 2) GLOB '0[1-9]' OR substr(sod_waiver_no, -11, 2) GLOB '1[0-2]') AND (substr(sod_waiver_no, -9, 2) GLOB '0[1-9]' OR substr(sod_waiver_no, -9, 2) GLOB '[12][0-9]' OR substr(sod_waiver_no, -9, 2) GLOB '3[01]'))),
    CONSTRAINT ck_inbp_ts CHECK ((putaway_at IS NULL OR (typeof(putaway_at) = 'text' AND length(putaway_at) = 19 AND datetime(putaway_at) IS putaway_at))),
    CONSTRAINT ck_inbp_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_inbp_chain CHECK (offchain_sec IS NULL OR offchain_sec >= 0)
);
CREATE INDEX ix_inbp_line ON inbound_putaway(inbound_line_id);
CREATE INDEX ix_inbp_rcp  ON inbound_putaway(receipt_id);

-- -----------------------------------------------------------------------------
-- 入库后质量反馈（盒马「质量反馈单」对应物）：上架复检或在库发现来货质量问题，冻结受影响库存并向上游反馈
--   发现时 hold(QUALITY, QC_PENDING, source_type=INBOUND_FB)；处置：SCRAP（convert_hold → SCRAP_PENDING，第 9 篇）、
--   RETURN_SUPPLIER（退供：同样先 convert_hold → SCRAP_PENDING 待处置，退供/报废由 10/09 完成）、REJECTED（反馈驳回，unhold）、CLAIM_ONLY（只索赔，库存另行处理）
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_quality_feedback (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(64)  NOT NULL,   -- IQF- 前缀单号
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    lot_id              BIGINT,
    stage               VARCHAR(16)  NOT NULL,   -- PUTAWAY_RECHECK / IN_STOCK
    issue_code          VARCHAR(16)  NOT NULL,   -- ROT / DAMAGE / TEMP / SPEC / SHORT_WEIGHT / FOREIGN / OTHER
    affected_qty_milli  BIGINT       NOT NULL,
    stock_id            BIGINT,
    hold_id             BIGINT,                  -- CLAIM_ONLY 可无冻结
    scrap_hold_id       BIGINT,                  -- SCRAP / RETURN_SUPPLIER：convert_hold 出的 hold(SCRAP_PENDING)（挂 09 报损单），trg_iqf_guard 核对类型
    status              VARCHAR(16)  NOT NULL DEFAULT 'OPEN',      -- OPEN / CLOSED
    disposition         VARCHAR(24)  NOT NULL DEFAULT 'PENDING',   -- PENDING / SCRAP / RETURN_SUPPLIER / REJECTED / CLAIM_ONLY
    reported_by         BIGINT       NOT NULL,
    found_at            TIMESTAMP    NOT NULL,
    closed_by           BIGINT,
    closed_at           TIMESTAMP,
    remark              VARCHAR(512),
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_iqf_code UNIQUE (code),
    CONSTRAINT fk_iqf_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_iqf_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_iqf_scrap FOREIGN KEY (scrap_hold_id) REFERENCES stock_hold(id),
    CONSTRAINT ck_iqf_scrap CHECK ((disposition IN ('SCRAP','RETURN_SUPPLIER')) = (scrap_hold_id IS NOT NULL)),
    CONSTRAINT ck_iqf_stage CHECK (stage IN ('PUTAWAY_RECHECK','IN_STOCK')),
    CONSTRAINT ck_iqf_issue CHECK (issue_code IN ('ROT','DAMAGE','TEMP','SPEC','SHORT_WEIGHT','FOREIGN','OTHER')),
    CONSTRAINT ck_iqf_qty CHECK (affected_qty_milli > 0 AND affected_qty_milli = CAST(affected_qty_milli AS BIGINT)),
    CONSTRAINT ck_iqf_disp CHECK (disposition IN ('PENDING','SCRAP','RETURN_SUPPLIER','REJECTED','CLAIM_ONLY')),
    CONSTRAINT ck_iqf_hold CHECK (disposition = 'CLAIM_ONLY' OR hold_id IS NOT NULL),
    CONSTRAINT fk_iqf_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_iqf_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_iqf_stock FOREIGN KEY (stock_id) REFERENCES stock(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_iqf_ts CHECK ((found_at IS NULL OR (typeof(found_at) = 'text' AND length(found_at) = 19 AND datetime(found_at) IS found_at)) AND (closed_at IS NULL OR (typeof(closed_at) = 'text' AND length(closed_at) = 19 AND datetime(closed_at) IS closed_at))),
    CONSTRAINT ck_iqf_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_iqf_close CHECK (
        (status = 'OPEN' AND disposition = 'PENDING' AND closed_by IS NULL AND closed_at IS NULL)
        OR (status = 'CLOSED' AND disposition <> 'PENDING' AND closed_by IS NOT NULL AND closed_at IS NOT NULL AND closed_by <> reported_by))
);
CREATE INDEX ix_iqf_line ON inbound_quality_feedback(inbound_line_id);
CREATE INDEX ix_iqf_open ON inbound_quality_feedback(warehouse_id, status, found_at DESC);

-- -----------------------------------------------------------------------------
-- 只追加：测温、收货、更正单、上架四张记录表（复用第 2 篇 trg_append_only；SQLite 等价触发器；TRUNCATE 另拦）
-- 质量反馈单：关单后不能再改；发现时的事实列（行、数量、冻结、发现人）任何时候不能改；SCRAP / RETURN_SUPPLIER 必须挂 hold(SCRAP_PENDING)
-- 已关单（COMPLETED）的入库单和它的行：不能再改、删、加行；单头只许把 supplier_reconciled_at 由空补上（11 回写对账）
-- 本篇 9 个 PG 函数都固定 search_path = pg_catalog, public, pg_temp（pg_temp 显式放最后：不写时 PG 会先查会话临时表，可被 CREATE TEMP TABLE 冒充）（trg_iqf_guard / trg_inb_closed_guard / trg_inbl_closed_guard / trg_irc_guard / trg_inbp_apply / trg_inbl_counter_guard / trg_inb_time_now / trg_inb_created_now / trg_inb_forward）
-- 时间约定（Doro 09:10）：服务端生成的审批 / 状态时间（inbound_order.closed_at、supplier_reconciled_at，质量反馈 closed_at，更正单 approved_at）
--   PG 在 BEFORE 触发器里把非属主写入覆盖成 date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')（表属主豁免：种子 / 迁移，同 10 trg_srtn_zclock）；
--   SQLite 不能改 NEW：CHECK 只收 length 19 且 datetime(x) IS x 的整秒 'YYYY-MM-DD HH:MM:SS'，触发器再要求与 now 相差 ≤ 300 秒（strftime 为 NULL 也报 inbound_clock_skew）。
--   窗口 / 对账比较用落库值按整秒：PG 原生 TIMESTAMP（ck_*_ts 保证整秒），SQLite 一律 CAST(strftime('%s', x) AS INTEGER)。
--   设备 / 业务上报时间（测温、收货、上架、发现、离冷链、预计 / 到场 / 卸货、申请时间）不强制 now，SQLite 只校验格式。比较一律按整秒。
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_itc_no_update BEFORE UPDATE ON inbound_temp_check BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
CREATE TRIGGER trg_itc_no_delete BEFORE DELETE ON inbound_temp_check BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
CREATE TRIGGER trg_rcp_no_update BEFORE UPDATE ON inbound_receipt BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
CREATE TRIGGER trg_rcp_no_delete BEFORE DELETE ON inbound_receipt BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
CREATE TRIGGER trg_irc_no_update BEFORE UPDATE ON inbound_correction BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
CREATE TRIGGER trg_irc_no_delete BEFORE DELETE ON inbound_correction BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
CREATE TRIGGER trg_inbp_no_update BEFORE UPDATE ON inbound_putaway BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
CREATE TRIGGER trg_inbp_no_delete BEFORE DELETE ON inbound_putaway BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
-- trg_inb_rec_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_irc_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inbp_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_itc_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
CREATE TRIGGER trg_iqf_guard_upd BEFORE UPDATE ON inbound_quality_feedback
WHEN OLD.status = 'CLOSED' OR NEW.id <> OLD.id OR NEW.inbound_line_id <> OLD.inbound_line_id OR NEW.affected_qty_milli <> OLD.affected_qty_milli
  OR NEW.hold_id IS NOT OLD.hold_id OR NEW.reported_by <> OLD.reported_by OR NEW.found_at <> OLD.found_at
BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;
CREATE TRIGGER trg_iqf_no_delete BEFORE DELETE ON inbound_quality_feedback BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;
-- trg_iqf_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inb_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inbl_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
CREATE TRIGGER trg_iqf_scrap_ins BEFORE INSERT ON inbound_quality_feedback WHEN NEW.scrap_hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.scrap_hold_id AND h.hold_type = 'SCRAP_PENDING') BEGIN SELECT RAISE(ABORT, 'iqf_scrap_hold_not_scrap_pending'); END;
CREATE TRIGGER trg_iqf_scrap_upd BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.scrap_hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.scrap_hold_id AND h.hold_type = 'SCRAP_PENDING') BEGIN SELECT RAISE(ABORT, 'iqf_scrap_hold_not_scrap_pending'); END;
CREATE TRIGGER trg_inb_closed_upd BEFORE UPDATE ON inbound_order
WHEN OLD.status = 'COMPLETED' AND (NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.order_type IS NOT OLD.order_type
  OR NEW.source_system IS NOT OLD.source_system OR NEW.source_order_no IS NOT OLD.source_order_no OR NEW.source_hash IS NOT OLD.source_hash
  OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.status IS NOT OLD.status OR NEW.work_date IS NOT OLD.work_date OR NEW.expected_at IS NOT OLD.expected_at
  OR NEW.dock_code IS NOT OLD.dock_code OR NEW.vehicle_no IS NOT OLD.vehicle_no OR NEW.arrived_at IS NOT OLD.arrived_at OR NEW.unload_start_at IS NOT OLD.unload_start_at
  OR NEW.received_at IS NOT OLD.received_at OR NEW.closed_at IS NOT OLD.closed_at OR NEW.remark IS NOT OLD.remark OR NEW.created_at IS NOT OLD.created_at
  OR NEW.created_by IS NOT OLD.created_by OR (OLD.supplier_reconciled_at IS NOT NULL AND NEW.supplier_reconciled_at IS NOT OLD.supplier_reconciled_at))
BEGIN SELECT RAISE(ABORT, 'inbound_order_closed_immutable'); END;
CREATE TRIGGER trg_inb_closed_del BEFORE DELETE ON inbound_order WHEN OLD.status = 'COMPLETED' BEGIN SELECT RAISE(ABORT, 'inbound_order_closed_immutable'); END;
CREATE TRIGGER trg_inbl_closed_ins BEFORE INSERT ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
CREATE TRIGGER trg_inbl_closed_upd BEFORE UPDATE ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.status = 'COMPLETED' AND o.id IN (OLD.inbound_id, NEW.inbound_id)) BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
CREATE TRIGGER trg_inbl_closed_del BEFORE DELETE ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = OLD.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
CREATE TRIGGER trg_irc_not_closed BEFORE INSERT ON inbound_correction WHEN NOT EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_correction_order_not_closed'); END;
CREATE TRIGGER trg_irc_reconciled BEFORE INSERT ON inbound_correction WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.supplier_reconciled_at IS NOT NULL AND CAST(strftime('%s', o.supplier_reconciled_at) AS INTEGER) <= CAST(strftime('%s', NEW.approved_at) AS INTEGER)) BEGIN SELECT RAISE(ABORT, 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust'); END;
CREATE TRIGGER trg_irc_now BEFORE INSERT ON inbound_correction WHEN strftime('%s', NEW.approved_at) IS NULL OR substr(NEW.approved_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300 BEGIN SELECT RAISE(ABORT, 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at'); END;
CREATE TRIGGER trg_irc_before_close BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) < 0 BEGIN SELECT RAISE(ABORT, 'inbound_correction_before_close'); END;
CREATE TRIGGER trg_irc_window BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) > 604800 BEGIN SELECT RAISE(ABORT, 'inbound_correction_window_closed: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust'); END;
CREATE TRIGGER trg_irc_dual BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) > 86400 AND (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) <= 604800 AND NEW.approval_tier <> 'DUAL' BEGIN SELECT RAISE(ABORT, 'inbound_correction_dual_approval_required'); END;
CREATE TRIGGER trg_irc_tier BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) >= 0 AND (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) <= 86400 AND NEW.approval_tier <> 'SUPERVISOR' BEGIN SELECT RAISE(ABORT, 'inbound_correction_tier_mismatch'); END;
CREATE TRIGGER trg_irc_movement BEFORE INSERT ON inbound_correction WHEN NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = NEW.movement_id AND m.biz_type = 'ADJUST' AND m.biz_no = NEW.code AND m.direction = NEW.direction AND m.move_qty_milli = NEW.qty_milli AND m.stock_id = NEW.stock_id) BEGIN SELECT RAISE(ABORT, 'inbound_correction_movement_mismatch'); END;
CREATE TRIGGER trg_inbp_closed BEFORE INSERT ON inbound_putaway WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_putaway_closed_immutable'); END;
CREATE TRIGGER trg_inbp_over BEFORE INSERT ON inbound_putaway WHEN NOT EXISTS (SELECT 1 FROM inbound_line l WHERE l.id = NEW.inbound_line_id AND l.putaway_qty_milli + NEW.qty_milli <= l.qc_passed_qty_milli) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_over_qty: 42214 OVER_QTY reason=OVER_PUTAWAY'); END;
CREATE TRIGGER trg_inbp_apply AFTER INSERT ON inbound_putaway BEGIN UPDATE inbound_line SET putaway_qty_milli = putaway_qty_milli + NEW.qty_milli, version = version + 1 WHERE id = NEW.inbound_line_id; END;
CREATE TRIGGER trg_inbl_put_qc BEFORE UPDATE ON inbound_line WHEN NEW.putaway_qty_milli > NEW.qc_passed_qty_milli BEGIN SELECT RAISE(ABORT, 'inbound_putaway_over_qc_passed'); END;
CREATE TRIGGER trg_inbl_put_sum BEFORE UPDATE ON inbound_line WHEN NEW.putaway_qty_milli IS NOT OLD.putaway_qty_milli AND NEW.putaway_qty_milli <= NEW.qc_passed_qty_milli AND NEW.putaway_qty_milli <> (SELECT COALESCE(sum(p.qty_milli), 0) FROM inbound_putaway p WHERE p.inbound_line_id = NEW.id) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_counter_mismatch'); END;
CREATE TRIGGER trg_inbl_put_ins BEFORE INSERT ON inbound_line WHEN NEW.putaway_qty_milli <> 0 BEGIN SELECT RAISE(ABORT, 'inbound_putaway_counter_mismatch'); END;
CREATE TRIGGER trg_inb_closed_tol_ins BEFORE INSERT ON inbound_order WHEN NEW.status IN ('COMPLETED','CANCELLED') AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
CREATE TRIGGER trg_inb_closed_tol_upd BEFORE UPDATE ON inbound_order WHEN NEW.status IN ('COMPLETED','CANCELLED') AND OLD.status NOT IN ('COMPLETED','CANCELLED') AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
CREATE TRIGGER trg_inb_recon_tol BEFORE UPDATE ON inbound_order WHEN OLD.supplier_reconciled_at IS NULL AND (NEW.supplier_reconciled_at IS NOT NULL AND (strftime('%s', NEW.supplier_reconciled_at) IS NULL OR substr(NEW.supplier_reconciled_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.supplier_reconciled_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID supplier_reconciled_at'); END;
CREATE TRIGGER trg_inb_recon_tol_ins BEFORE INSERT ON inbound_order WHEN (NEW.supplier_reconciled_at IS NOT NULL AND (strftime('%s', NEW.supplier_reconciled_at) IS NULL OR substr(NEW.supplier_reconciled_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.supplier_reconciled_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID supplier_reconciled_at'); END;
CREATE TRIGGER trg_iqf_closed_tol BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.status = 'CLOSED' AND OLD.status <> 'CLOSED' AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
CREATE TRIGGER trg_iqf_closed_tol_ins BEFORE INSERT ON inbound_quality_feedback WHEN NEW.status = 'CLOSED' AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
CREATE TRIGGER trg_inb_created_tol BEFORE INSERT ON inbound_order WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_inb_created_lock BEFORE UPDATE ON inbound_order WHEN NEW.created_at IS NOT OLD.created_at BEGIN SELECT RAISE(ABORT, 'inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at'); END;
CREATE TRIGGER trg_itc_created_tol BEFORE INSERT ON inbound_temp_check WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_temp_check_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_rcp_created_tol BEFORE INSERT ON inbound_receipt WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_receipt_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_irc_created_tol BEFORE INSERT ON inbound_correction WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_inbp_created_tol BEFORE INSERT ON inbound_putaway WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_iqf_created_tol BEFORE INSERT ON inbound_quality_feedback WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_iqf_created_lock BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.created_at IS NOT OLD.created_at BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at'); END;
CREATE TRIGGER trg_inb_forward BEFORE UPDATE ON inbound_order WHEN NEW.status <> OLD.status AND NOT ((OLD.status = 'CREATED' AND NEW.status IN ('ARRIVED','RECEIVING','CANCELLED')) OR (OLD.status = 'ARRIVED' AND NEW.status IN ('RECEIVING','CANCELLED')) OR (OLD.status = 'RECEIVING' AND NEW.status IN ('RECEIVED','PUTTING_AWAY','COMPLETED','CANCELLED')) OR (OLD.status = 'RECEIVED' AND NEW.status IN ('PUTTING_AWAY','COMPLETED')) OR (OLD.status = 'PUTTING_AWAY' AND NEW.status = 'COMPLETED')) BEGIN SELECT RAISE(ABORT, 'inbound_order_state_forward_only'); END;
CREATE TRIGGER trg_iqf_forward BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.status <> OLD.status AND NOT (OLD.status = 'OPEN' AND NEW.status = 'CLOSED') BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_state_forward_only'); END;
-- B1：inbound_line 不给表级 UPDATE；计数列（received / rejected / qc_passed / qc_failed / putaway）只能走守卫路径
-- X1/X2：no-replace 触发器（WHEN 覆盖本表全部 PK / UNIQUE，部分索引带谓词；由 genreplace 生成）
CREATE TRIGGER trg_inb_no_replace BEFORE INSERT ON inbound_order WHEN EXISTS (SELECT 1 FROM inbound_order k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.closed_at = NEW.closed_at) OR (k.source_system = NEW.source_system AND k.source_order_no = NEW.source_order_no) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'inbound_order_duplicate'); END;
CREATE TRIGGER trg_inbl_no_replace BEFORE INSERT ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_line k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_id = NEW.inbound_id) OR (k.inbound_id = NEW.inbound_id AND k.line_no = NEW.line_no)) BEGIN SELECT RAISE(ABORT, 'inbound_line_duplicate'); END;
CREATE TRIGGER trg_itc_no_replace BEFORE INSERT ON inbound_temp_check WHEN EXISTS (SELECT 1 FROM inbound_temp_check k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_id = NEW.inbound_id AND k.disposition = NEW.disposition) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
CREATE TRIGGER trg_inb_rec_no_replace BEFORE INSERT ON inbound_receipt WHEN EXISTS (SELECT 1 FROM inbound_receipt k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_line_id = NEW.inbound_line_id AND k.received_by = NEW.received_by) OR (k.hold_id = NEW.hold_id) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
CREATE TRIGGER trg_irc_no_replace BEFORE INSERT ON inbound_correction WHEN EXISTS (SELECT 1 FROM inbound_correction k WHERE (k.id = NEW.id) OR (k.movement_id = NEW.movement_id) OR (k.op_key = NEW.op_key) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
CREATE TRIGGER trg_inbp_no_replace BEFORE INSERT ON inbound_putaway WHEN EXISTS (SELECT 1 FROM inbound_putaway k WHERE (k.id = NEW.id) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
CREATE TRIGGER trg_iqf_no_replace BEFORE INSERT ON inbound_quality_feedback WHEN EXISTS (SELECT 1 FROM inbound_quality_feedback k WHERE (k.id = NEW.id) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;

-- 去重键不可改、计数器只增（由 genlock 生成；PG 触发器名 trg_0keylock_* 让它按字母序最先执行）
CREATE TRIGGER trg_inbound_order_keylock BEFORE UPDATE ON inbound_order WHEN NEW.id IS NOT OLD.id OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at) OR NEW.source_system IS NOT OLD.source_system OR NEW.source_order_no IS NOT OLD.source_order_no OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_inbound_order_monotonic BEFORE UPDATE ON inbound_order WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_order_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_inbound_line_keylock BEFORE UPDATE ON inbound_line WHEN NEW.id IS NOT OLD.id OR NEW.inbound_id IS NOT OLD.inbound_id OR NEW.line_no IS NOT OLD.line_no BEGIN SELECT RAISE(ABORT, 'inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_inbound_line_monotonic BEFORE UPDATE ON inbound_line WHEN NEW.received_qty_milli < OLD.received_qty_milli OR NEW.rejected_qty_milli < OLD.rejected_qty_milli OR NEW.qc_passed_qty_milli < OLD.qc_passed_qty_milli OR NEW.qc_failed_qty_milli < OLD.qc_failed_qty_milli OR NEW.putaway_qty_milli < OLD.putaway_qty_milli OR NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_inbound_quality_feedback_keylock BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_inbound_quality_feedback_monotonic BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
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
-- 第 10 篇 退货与异常（#5）。本文件只建第 10 篇自己的表；对第 3 篇 inbound_order / inbound_line 的改动一律用 ALTER 写在这里，
-- 并登记在 README「跨篇 ALTER 登记表」（不改 03_inbound.sql 的 CREATE TABLE）。
-- ① inbound_order：退货入库单（RTN）来源白名单。WMS_DELIVERY=第 16 篇拒收回仓；STORE_RETURN=门店退货回仓；STORE_BLIND=盲收；
--    SCRAP_MISREPORT=第 9 篇交接误报回转的质检单（不 post_in）；MALL/ERP=客户退货经第 11 篇
CREATE TRIGGER trg_inb_rtn_src_ins BEFORE INSERT ON inbound_order
WHEN NEW.order_type = 'RETURN' AND NEW.source_system NOT IN ('WMS_DELIVERY','STORE_RETURN','STORE_BLIND','SCRAP_MISREPORT','MALL','ERP')
BEGIN SELECT RAISE(ABORT, 'ck_inb_rtn_src'); END;
CREATE TRIGGER trg_inb_rtn_src_upd BEFORE UPDATE ON inbound_order
WHEN NEW.order_type = 'RETURN' AND NEW.source_system NOT IN ('WMS_DELIVERY','STORE_RETURN','STORE_BLIND','SCRAP_MISREPORT','MALL','ERP')
BEGIN SELECT RAISE(ABORT, 'ck_inb_rtn_src'); END;
-- ② inbound_line：03 里只有 NUMERIC 的 received_qty，没有任何 *_qty_milli 列。这里只补 02 §7.1.3 release_qc_hold 用到的三列
--    received / qc_passed / qc_failed（与 README 跨篇 ALTER 登记表一致）。对方声称数不放在 inbound_line：门店退货在
--    return_reservation_line.qty_milli，拒收差异在 exception_case.claimed_qty_milli。
--    退货入库（docs/10 I3）数量一律 *_qty_milli（00 R2）。第 3 篇的 NUMERIC 列按 00 §9.2「加列 → 双写 → 删旧」迁移；
--    退货（order_type='RETURN'）只读写这三列，入账 post_in 只用 received_qty_milli；质检通过 release_qc_hold 与 qc_passed 累加同事务。
--    SQLite 的 ALTER 不能加表级约束，两条 CHECK 挂在最后一列上（SQLite 允许列级 CHECK 引用同表其他列），约束名两库一致。
ALTER TABLE inbound_line ADD COLUMN received_qty_milli  BIGINT NOT NULL DEFAULT 0;   -- 仓管实点（入账以此为准）
ALTER TABLE inbound_line ADD COLUMN qc_passed_qty_milli BIGINT NOT NULL DEFAULT 0;
ALTER TABLE inbound_line ADD COLUMN qc_failed_qty_milli BIGINT NOT NULL DEFAULT 0
    CONSTRAINT ck_inbl_int CHECK (received_qty_milli = CAST(received_qty_milli AS BIGINT) AND qc_passed_qty_milli = CAST(qc_passed_qty_milli AS BIGINT) AND qc_failed_qty_milli = CAST(qc_failed_qty_milli AS BIGINT))
    CONSTRAINT ck_inbl_qc CHECK (received_qty_milli >= 0 AND qc_passed_qty_milli >= 0 AND qc_failed_qty_milli >= 0 AND qc_passed_qty_milli + qc_failed_qty_milli <= received_qty_milli);
-- CAST 对 BIGINT 在 PG 上恒为真，只在 SQLite（REAL/TEXT 亲和）起作用，写法与 02 相同
-- ③ 质检通过走第 2 篇 release_qc_hold(hold_id, inbound_order_id, inbound_line_id, qty, op_key)：RETURN_QC 冻结 source_type='QC'、
--    source_id = inbound_order.id（RTN 单头 id，不是行 id，也没有 qc_line 表）；op_key = QCR:{inbound_line_id}:{op_seq}。

-- 第 10 篇 退货与异常：异常码字典 + 异常单（EXC）。退货入库单复用 inbound_order(order_type='RETURN')。
CREATE TABLE exception_code (
    code            VARCHAR(32)     PRIMARY KEY,   -- SHORT_STOCK/DAMAGED/EXPIRED/WRONG_LOC/WRONG_SKU/CUSTOMER_REJECT/RETURN_COUNT_DIFF/TEMP_BREACH ...
    name            VARCHAR(64)     NOT NULL,
    action          VARCHAR(32)     NOT NULL,      -- NONE/ADJUST/SCRAP/REPLENISH/NOTIFY_PURCHASE
    liability       VARCHAR(16)     NOT NULL,      -- WAREHOUSE/SUPPLIER/CARRIER/CUSTOMER/UNKNOWN
    escalate_minutes INT            NOT NULL DEFAULT 240,
    is_active       SMALLINT        NOT NULL DEFAULT 1,
    CONSTRAINT ck_exc_liab CHECK (liability IN ('WAREHOUSE','SUPPLIER','CARRIER','CUSTOMER','UNKNOWN'))
);

CREATE TABLE exception_case (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,      -- EXC-{仓}-{节点}-{作业日}-{序号}
    warehouse_id    BIGINT          NOT NULL,
    exception_code  VARCHAR(32)     NOT NULL REFERENCES exception_code(code),   -- I1：外键到字典
    source_type     VARCHAR(24)     NOT NULL,      -- 取值见 ck_exc_src_type
    source_key      VARCHAR(96)     NOT NULL,      -- DELIVERY_RETURN：POD:{pod_id}:{correct_seq}（16，首签 0）；FAILOVER_GAP：FG:{failover_id}:{source_system}:{source_order_no}
    source_hash     VARCHAR(64)     NOT NULL,      -- 规范化内容 SHA-256：同键不同内容 → 40910 SOURCE_ORDER
    sku_id          BIGINT          NOT NULL DEFAULT 0,
    lot_id          BIGINT          NOT NULL DEFAULT 0,
    claimed_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 对方声称（如司机拒收登记数）
    counted_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 仓库实点数（以此为准）
    diff_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- counted − claimed，应用层写入
    liable_party    VARCHAR(16)     NOT NULL DEFAULT 'UNKNOWN',   -- 责任方：WAREHOUSE/CARRIER/STORE/UNKNOWN（字典 exception_code.liability 只是建议值，落单时映射）
    link_deadline_at TIMESTAMP,                    -- UTC；关联单据截止：盲收 = created_at + 48h，超时升级主管（escalated=1）；只能往后改
    status          VARCHAR(16)     NOT NULL DEFAULT 'OPEN',
    escalated       SMALLINT        NOT NULL DEFAULT 0,
    due_at          TIMESTAMP       NOT NULL,
    assignee_id     BIGINT,
    resolution      VARCHAR(32),                   -- ACCEPT_COUNT/ADJUST/SCRAP/CLAIM_CARRIER/CLAIM_CUSTOMER/NO_ACTION
    resolution_doc  VARCHAR(64),                   -- 生成的调整单/报损单号
    reporter_id     BIGINT          NOT NULL,
    closed_by       BIGINT,
    closed_at       TIMESTAMP,
    version         BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_exc_code   UNIQUE (code),
    CONSTRAINT uq_exc_src    UNIQUE (source_type, source_key),
    CONSTRAINT ck_exc_status CHECK (status IN ('OPEN','PROCESSING','RESOLVED','CLOSED','CANCELLED')),
    CONSTRAINT ck_exc_int    CHECK (counted_qty_milli = CAST(counted_qty_milli AS BIGINT) AND diff_qty_milli = CAST(diff_qty_milli AS BIGINT)),
    CONSTRAINT ck_exc_diff   CHECK (diff_qty_milli = counted_qty_milli - claimed_qty_milli),
    CONSTRAINT ck_exc_close  CHECK (status NOT IN ('RESOLVED','CLOSED') OR (resolution IS NOT NULL AND closed_by IS NOT NULL)),
    -- 小赵复评建议 1：处置结论取值；调整 / 报损必须带生成的单号
    CONSTRAINT ck_exc_resol  CHECK (resolution IS NULL OR resolution IN ('ACCEPT_COUNT','ADJUST','SCRAP','CLAIM_CARRIER','CLAIM_CUSTOMER','NO_ACTION')),
    CONSTRAINT ck_exc_resdoc CHECK (resolution IS NULL OR resolution NOT IN ('ADJUST','SCRAP') OR (resolution_doc IS NOT NULL AND length(resolution_doc) > 0)),
    CONSTRAINT ck_exc_liable CHECK (liable_party IN ('WAREHOUSE','CARRIER','STORE','UNKNOWN')),
    CONSTRAINT ck_exc_blind  CHECK (source_type <> 'BLIND_RETURN' OR link_deadline_at IS NOT NULL),
    CONSTRAINT ck_exc_src_type CHECK (source_type IN ('DELIVERY_RETURN','STORE_RETURN','BLIND_RETURN','SCRAP_MISREPORT','RETURN_INBOUND','RR_HOLD_FAILED','FAILOVER_GAP','PICK','COUNT','MANUAL','PROCESS_LOSS','LIVE_DEATH')),
    -- 第 17 篇加工损耗未获批部分（审批 REJECTED / 12h 过期 EXPIRED_TO_EXCEPTION）转本篇异常：source_type 与 00 报损来源同名 PROCESS_LOSS，
    -- source_key = PRCL:{process_output.id}（损耗行 id，一行只转一次，uq_exc_src 去重）；转异常后损耗结论以本篇为准（ERP 等 wms.exception.closed）
    -- 第 18 篇活鲜死亡延迟扣减任务（deduct_status = EXCEPTION）转本篇异常：source_type 与 00 报损来源同名 LIVE_DEATH，
    -- source_key = LDTH:{live_death.id}（死亡登记 id，一条只转一次，uq_exc_ldth_key 去重；幂等返回规则同 PROCESS_LOSS）
    -- 键格式：前缀后必须是不带前导零的正整数 [1-9][0-9]*（PG 正则；SQLite 用 substr + GLOB 等价判断）
    CONSTRAINT ck_exc_ldth_key CHECK (source_type <> 'LIVE_DEATH' OR (substr(source_key, 1, 5) = 'LDTH:' AND length(source_key) >= 6 AND substr(source_key, 6, 1) BETWEEN '1' AND '9' AND substr(source_key, 6) NOT GLOB '*[^0-9]*' AND sku_id > 0)),
    CONSTRAINT ck_exc_pl_key CHECK (source_type <> 'PROCESS_LOSS' OR (substr(source_key, 1, 5) = 'PRCL:' AND length(source_key) >= 6 AND substr(source_key, 6, 1) BETWEEN '1' AND '9' AND substr(source_key, 6) NOT GLOB '*[^0-9]*' AND sku_id > 0)),
    CONSTRAINT ck_exc_hash   CHECK (length(source_hash) = 64 AND lower(source_hash) = source_hash AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(source_hash,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = '')
);
CREATE INDEX ix_exc_wh_status ON exception_case(warehouse_id, status, due_at);
-- 第 17 篇加工损耗转异常的幂等键（Doro 定）：一条损耗行 PRCL:{process_output.id} 只有一张异常单（两库同一部分唯一索引）。
-- 审批驳回回调（含重放）与 12h 过期任务可能并发处理同一损耗行：后到者不报错，返回已存在的 exception_no，且不再写 outbox。
--   PG：INSERT … ON CONFLICT (source_key) WHERE source_type = 'PROCESS_LOSS' DO NOTHING RETURNING code → 0 行则 SELECT code；
--   SQLite（单写者，BEGIN IMMEDIATE 串行）：INSERT … SELECT … WHERE NOT EXISTS (…) → changes() = 0 则 SELECT code。
--   （SQLite 的 trg_exc_no_replace 会让 INSERT OR IGNORE / ON CONFLICT DO NOTHING 直接 ABORT，所以 SQLite 侧不用 DO NOTHING。）
--   wms.process.loss_settled 只由真正插入异常单的一方在同事务写出 → 每条损耗行只发一次。
CREATE UNIQUE INDEX uq_exc_pl_key ON exception_case(source_key) WHERE source_type = 'PROCESS_LOSS';
-- 第 18 篇活鲜死亡（LDTH:{live_death.id}）同一套：部分唯一索引兜底，后到者返回已有 exception_no、不报错
CREATE UNIQUE INDEX uq_exc_ldth_key ON exception_case(source_key) WHERE source_type = 'LIVE_DEATH';
-- 异常单库层守卫（小赵 I2 / 复评 L1–L3，大肥鱼定案）
-- L1 状态白名单：OPEN→PROCESSING/RESOLVED/CANCELLED，PROCESSING→RESOLVED/CANCELLED，RESOLVED→CLOSED；其余一律拒（含 RESOLVED→PROCESSING、
--    OPEN/PROCESSING→CLOSED）。下游单据被驳回（原 X4）不再退回处理中，而是新开一张异常单（source_type=MANUAL，payload 引用原单号）。
-- L2 建单后 code / warehouse_id / exception_code / source_type / source_key / source_hash / reporter_id 不可改；
--    进入 RESOLVED 后声称、实点、差异、处置结论、处置单号、责任方、关闭人不可改，closed_at 只能从 NULL 写一次；CLOSED / CANCELLED 整行只读（含 version）。
-- L3 不许 DELETE / TRUNCATE；SQLite 另拦 REPLACE（id 或 (source_type, source_key) 已存在即拒），去重键永不释放。
-- 建议 2：SQLite 外键依赖 PRAGMA foreign_keys=ON，边缘连接漏开也要拦：exception_code 存在性用触发器再校验一次。
CREATE TRIGGER trg_exc_forward BEFORE UPDATE ON exception_case
WHEN NEW.status <> OLD.status AND NEW.status IN ('OPEN','PROCESSING','RESOLVED','CLOSED','CANCELLED') AND NOT ((OLD.status = 'OPEN' AND NEW.status IN ('PROCESSING','RESOLVED','CANCELLED'))
  OR (OLD.status = 'PROCESSING' AND NEW.status IN ('RESOLVED','CANCELLED'))
  OR (OLD.status = 'RESOLVED' AND NEW.status = 'CLOSED'))
BEGIN SELECT RAISE(ABORT, 'exc_state_forward_only'); END;
CREATE TRIGGER trg_exc_immutable BEFORE UPDATE ON exception_case
WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.exception_code IS NOT OLD.exception_code
  OR NEW.source_type IS NOT OLD.source_type OR NEW.source_key IS NOT OLD.source_key OR NEW.source_hash IS NOT OLD.source_hash
  OR NEW.reporter_id IS NOT OLD.reporter_id
  OR (OLD.status IN ('CLOSED','CANCELLED') AND (NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
  OR NEW.exception_code IS NOT OLD.exception_code OR NEW.source_type IS NOT OLD.source_type
  OR NEW.source_key IS NOT OLD.source_key OR NEW.source_hash IS NOT OLD.source_hash OR NEW.sku_id IS NOT OLD.sku_id
  OR NEW.lot_id IS NOT OLD.lot_id OR NEW.claimed_qty_milli IS NOT OLD.claimed_qty_milli
  OR NEW.counted_qty_milli IS NOT OLD.counted_qty_milli OR NEW.diff_qty_milli IS NOT OLD.diff_qty_milli
  OR NEW.liable_party IS NOT OLD.liable_party OR NEW.escalated IS NOT OLD.escalated
  OR NEW.due_at IS NOT OLD.due_at OR NEW.assignee_id IS NOT OLD.assignee_id OR NEW.resolution IS NOT OLD.resolution
  OR NEW.resolution_doc IS NOT OLD.resolution_doc OR NEW.reporter_id IS NOT OLD.reporter_id
  OR NEW.closed_by IS NOT OLD.closed_by OR NEW.closed_at IS NOT OLD.closed_at OR NEW.version IS NOT OLD.version
  OR NEW.link_deadline_at IS NOT OLD.link_deadline_at OR NEW.created_at IS NOT OLD.created_at))
  OR (OLD.status = 'RESOLVED' AND (NEW.claimed_qty_milli IS NOT OLD.claimed_qty_milli OR NEW.counted_qty_milli IS NOT OLD.counted_qty_milli
      OR NEW.diff_qty_milli IS NOT OLD.diff_qty_milli OR NEW.resolution IS NOT OLD.resolution OR NEW.resolution_doc IS NOT OLD.resolution_doc
      OR NEW.liable_party IS NOT OLD.liable_party OR NEW.closed_by IS NOT OLD.closed_by
      OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at)))
BEGIN SELECT RAISE(ABORT, 'exc_immutable'); END;
CREATE TRIGGER trg_exc_no_delete BEFORE DELETE ON exception_case BEGIN SELECT RAISE(ABORT, 'exc_no_delete'); END;
CREATE TRIGGER trg_exc_no_replace BEFORE INSERT ON exception_case
WHEN EXISTS (SELECT 1 FROM exception_case e WHERE e.id = NEW.id OR (e.source_type = NEW.source_type AND e.source_key = NEW.source_key))
BEGIN SELECT RAISE(ABORT, 'exc_duplicate'); END;
CREATE TRIGGER trg_exc_code_ins BEFORE INSERT ON exception_case
WHEN NOT EXISTS (SELECT 1 FROM exception_code c WHERE c.code = NEW.exception_code)
BEGIN SELECT RAISE(ABORT, 'exc_code_unknown'); END;
-- 盲收异常单：link_deadline_at 建单时必须 = created_at + 48h（截止只能往后改，见 trg_exc_forward / trg_exc_deadline）
CREATE TRIGGER trg_exc_blind_ins BEFORE INSERT ON exception_case
WHEN NEW.source_type = 'BLIND_RETURN' AND NEW.link_deadline_at IS NOT NULL AND NEW.link_deadline_at IS NOT datetime(NEW.created_at, '+48 hours')
BEGIN SELECT RAISE(ABORT, 'exc_blind_deadline'); END;
CREATE TRIGGER trg_exc_deadline BEFORE UPDATE ON exception_case
WHEN OLD.link_deadline_at IS NOT NULL AND (NEW.link_deadline_at IS NULL OR NEW.link_deadline_at < OLD.link_deadline_at)
BEGIN SELECT RAISE(ABORT, 'exc_deadline_backward'); END;
-- I4：授权。字典只读写不删；异常单不删（取消走状态）
-- -----------------------------------------------------------------------------
-- 第 10 篇：门店退货「退货预约 + 盲收」（大肥鱼定案，对标盒马）
--   原因码与容器码必填；没有容器码的货现场补贴新标签再收。
-- -----------------------------------------------------------------------------
-- 退货预约：门店建（returns.reservation.create），仓库收货员收（returns.reservation.receive），收货后库存挂 RETURN_QC。
-- 状态：CREATED → RECEIVED / CANCELLED，只进不退；建单键不可改；终态整行只读；不许 DELETE / TRUNCATE；SQLite 另拦 REPLACE。
CREATE TABLE return_reservation (
    id                  BIGINT          PRIMARY KEY,
    code                VARCHAR(32)     NOT NULL,      -- RSV-{yyyyMMdd}-{seq}
    warehouse_id        BIGINT          NOT NULL,
    store_code          VARCHAR(32)     NOT NULL,
    outbound_order_id   BIGINT          NOT NULL,      -- 原出库单（门店只能退本店收过的单，服务端校验）
    status              VARCHAR(16)     NOT NULL DEFAULT 'CREATED',
    rtn_inbound_id      BIGINT,                        -- 收货生成的 RTN（inbound_order，source_system=STORE_RETURN）
    created_by          BIGINT          NOT NULL,
    received_by         BIGINT,
    received_at         TIMESTAMP,
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_rrsv_code   UNIQUE (code),
    CONSTRAINT ck_rrsv_status CHECK (status IN ('CREATED','RECEIVED','CANCELLED')),
    CONSTRAINT ck_rrsv_store  CHECK (length(store_code) > 0),
    CONSTRAINT ck_rrsv_recv   CHECK ((status = 'RECEIVED') = (rtn_inbound_id IS NOT NULL AND received_by IS NOT NULL AND received_at IS NOT NULL))
);
CREATE INDEX ix_rrsv_store ON return_reservation(warehouse_id, store_code, status);
CREATE TABLE return_reservation_line (
    id                  BIGINT          PRIMARY KEY,
    reservation_id      BIGINT          NOT NULL REFERENCES return_reservation(id),
    line_no             INTEGER         NOT NULL,
    sku_id              BIGINT          NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    reason_code         VARCHAR(24)     NOT NULL,
    container_code      VARCHAR(64)     NOT NULL,
    received_qty_milli  BIGINT,                        -- 收货时写一次（实点）
    CONSTRAINT uq_rrsl_line   UNIQUE (reservation_id, line_no),
    CONSTRAINT ck_rrsl_qty    CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)
                                     AND (received_qty_milli IS NULL OR (received_qty_milli >= 0 AND received_qty_milli = CAST(received_qty_milli AS BIGINT)))),
    CONSTRAINT ck_rrsl_ctn    CHECK (length(container_code) > 0),
    CONSTRAINT ck_rrsl_reason CHECK (reason_code IN ('QUALITY','DAMAGED','EXPIRED','NEAR_EXPIRY','WRONG_ITEM','OVERSTOCK','TEMP_ABNORMAL','PACKAGING','OTHER'))
);
-- 盲收记录：不预约直接收（inbound.return.blind），只追加：整行不可改、不可删；同事务生成 RTN（source_system=STORE_BLIND）与异常单（source_type=BLIND_RETURN）。
CREATE TABLE return_blind_receipt (
    id                  BIGINT          PRIMARY KEY,
    code                VARCHAR(32)     NOT NULL,      -- BRC-{yyyyMMdd}-{seq}，接口返回的收货记录号
    warehouse_id        BIGINT          NOT NULL,
    sku_id              BIGINT          NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    store_code          VARCHAR(32),                   -- 可空：不知道哪家门店
    container_code      VARCHAR(64)     NOT NULL,
    reason_code         VARCHAR(24)     NOT NULL,
    photo_ids           TEXT            NOT NULL DEFAULT '[]',   -- JSON 数组，第 12 篇文件服务 id
    rtn_inbound_id      BIGINT          NOT NULL,
    exception_case_id   BIGINT          NOT NULL,
    op_key              VARCHAR(80)     NOT NULL,      -- Idempotency-Key
    received_by         BIGINT          NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_rbr_code    UNIQUE (code),
    CONSTRAINT uq_rbr_op      UNIQUE (op_key),
    CONSTRAINT ck_rbr_qty     CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_rbr_ctn     CHECK (length(container_code) > 0 AND (store_code IS NULL OR length(store_code) > 0)),
    CONSTRAINT ck_rbr_reason  CHECK (reason_code IN ('QUALITY','DAMAGED','EXPIRED','NEAR_EXPIRY','WRONG_ITEM','OVERSTOCK','TEMP_ABNORMAL','PACKAGING','OTHER'))
);
CREATE TRIGGER trg_rrsv_forward BEFORE UPDATE ON return_reservation
WHEN NEW.status <> OLD.status AND NOT (OLD.status = 'CREATED' AND NEW.status IN ('RECEIVED','CANCELLED'))
BEGIN SELECT RAISE(ABORT, 'rrsv_state_forward_only'); END;
CREATE TRIGGER trg_rrsv_immutable BEFORE UPDATE ON return_reservation
WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.store_code IS NOT OLD.store_code
  OR NEW.outbound_order_id IS NOT OLD.outbound_order_id OR NEW.created_by IS NOT OLD.created_by OR NEW.created_at IS NOT OLD.created_at
  OR (OLD.status <> 'CREATED' AND NEW.status = OLD.status AND (NEW.rtn_inbound_id IS NOT OLD.rtn_inbound_id
      OR NEW.received_by IS NOT OLD.received_by OR NEW.received_at IS NOT OLD.received_at OR NEW.version IS NOT OLD.version))
BEGIN SELECT RAISE(ABORT, 'rrsv_immutable'); END;
CREATE TRIGGER trg_rrsv_no_delete BEFORE DELETE ON return_reservation BEGIN SELECT RAISE(ABORT, 'return_no_delete'); END;
CREATE TRIGGER trg_rrsv_no_replace BEFORE INSERT ON return_reservation
WHEN EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = NEW.id OR r.code = NEW.code)
BEGIN SELECT RAISE(ABORT, 'rrsv_duplicate'); END;
CREATE TRIGGER trg_rrsl_ins BEFORE INSERT ON return_reservation_line
WHEN EXISTS (SELECT 1 FROM return_reservation_line l WHERE l.id = NEW.id OR (l.reservation_id = NEW.reservation_id AND l.line_no = NEW.line_no))
  OR NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = NEW.reservation_id AND r.status = 'CREATED')
BEGIN SELECT RAISE(ABORT, 'rrsl_locked'); END;
CREATE TRIGGER trg_rrsl_upd BEFORE UPDATE ON return_reservation_line
WHEN NEW.id IS NOT OLD.id OR NEW.reservation_id IS NOT OLD.reservation_id OR NEW.line_no IS NOT OLD.line_no
  OR NEW.sku_id IS NOT OLD.sku_id OR NEW.qty_milli IS NOT OLD.qty_milli OR NEW.reason_code IS NOT OLD.reason_code
  OR NEW.container_code IS NOT OLD.container_code OR OLD.received_qty_milli IS NOT NULL
  OR NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = OLD.reservation_id AND r.status = 'CREATED')
BEGIN SELECT RAISE(ABORT, 'rrsl_locked'); END;
CREATE TRIGGER trg_rrsl_no_delete BEFORE DELETE ON return_reservation_line BEGIN SELECT RAISE(ABORT, 'return_no_delete'); END;
CREATE TRIGGER trg_rbr_no_upd BEFORE UPDATE ON return_blind_receipt BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
CREATE TRIGGER trg_rbr_no_del BEFORE DELETE ON return_blind_receipt BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
CREATE TRIGGER trg_rbr_no_replace BEFORE INSERT ON return_blind_receipt
WHEN EXISTS (SELECT 1 FROM return_blind_receipt b WHERE b.id = NEW.id OR b.code = NEW.code OR b.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
-- -----------------------------------------------------------------------------
-- 第 10 篇：退供应商（supplier_return，SRN）—— Alex 定案
--   R1 原因只限 QUALITY（质量）/ RECALL（召回）/ WRONG_DELIVERY（错送）；SLOW_MOVING（滞销）不退，合同另有约定的除外（contract_ref 必填）。
--   R2 处置方式必填：RETURN 退供 / SCRAP 报废 / DISCOUNT 折价 / EXCHANGE 换货；食安问题（food_safety）只能 RETURN 或 SCRAP。
--      召回（RECALL）一律食安；合同允许的滞销（SLOW_MOVING）一律非食安，四种处置都可以（Doro 定）。
--   R3 提货时限（只对 RETURN）：T = ready_at（货备好、通知供应商的时刻，UTC），生鲜 FRESH T+24h、冷冻 FROZEN T+7d、常温 STANDARD T+15d；
--      pickup_deadline_at 建单时按 temp_class 写定，库里校验；按时提货 picked_up_at ≤ 截止。temp_class 按 sku 温区映射，库层 trg_srtn_temp 核对（见下）。
--   R4 超期未提 → 第 9 篇报损单（source_type=SUPPLIER_RETURN，source_id=本表 id，reason_code=PICKUP_OVERDUE），同事务调 02 原语
--      hold(SCRAP_PENDING)（source_type=SCRAP，source_id=报损单 id，operator_id=0，op_key=SRTO:{supplier_return.id}），状态 AWAITING_PICKUP → OVERDUE_SCRAP。
--      报损单外键与「必须先有冻结」的守卫在 09_scrap.sql（scrap_order 在 10 之后建），见 README 跨篇 ALTER 登记。
-- 时间（小玛丽 pr03 B2/B3/N5 同类问题，本篇预先修）：
--   ck_srtn_ts：五个时间列（含 created_at）只收整秒、规范格式。PG TIMESTAMP 拒小数秒（= date_trunc('second')）；SQLite 要求恰好 'YYYY-MM-DD HH:MM:SS'
--   （length = 19 且 datetime(x) 原样返回）：'2026/10/30 10:00'、'zzzz'、'T' 分隔、'+08:00' 偏移、小数秒、2 月 30 日一律拒。
--   PG 的 TIMESTAMP 在解析时直接丢掉偏移（'…08:00:00+08:00' 存成 08:00），库里看不到原串；约定：接口只收不带偏移的 UTC 串，服务端校验，
--   非属主写入的服务端时间一律被 trg_srtn_zclock 覆盖成库时钟，偏移进不来；属主写入自行保证 UTC。
--   服务端时间（Doro 定）：ready_at、picked_up_at、overdue_at、created_at 都是服务端产生的时间（created_at：小玛丽终审 N1）。
--   search_path（小玛丽终审 B1）：本增量新增的函数一律 SET search_path = pg_catalog, public, pg_temp，pg_temp 显式放最后，防 wms_app 用临时表冒充真表。
--   PG：trg_srtn_zclock（BEFORE）对非表属主写入强制覆盖成 date_trunc('second', now() AT TIME ZONE 'UTC')（00 时间约定，Doro：不用裸 now()，与会话 TimeZone 无关），pickup_deadline_at 随之由触发器推出；
--   SQLite（不能改 NEW）：先由 ck_srtn_ts 拒非 ISO，再由 trg_srtn_clock_ins / _upd 要求与 datetime('now') 相差 ≤ 300 秒（按 strftime('%s') 整秒比，不按文本序）。
--   所有时间比较按整秒：PG TIMESTAMP 原生比较（ck_srtn_ts 保证整秒）；SQLite 一律 strftime('%s', x) 数值比较。ready_at / pickup_deadline_at 建单后任何人不可改（srtn_time_immutable）。非属主只能以 OPEN 建单（srtn_insert_open_only）。
--   表属主（迁移/种子角色）不受时钟窗口约束，同第 11 篇 trg_outbox_insert_pending 的属主口径；SQLite 没有角色，时钟触发器对所有写入生效。
-- -----------------------------------------------------------------------------
CREATE TABLE supplier_return (
    id                  BIGINT          PRIMARY KEY,
    code                VARCHAR(64)     NOT NULL,      -- SRN-{仓}-{节点}-{作业日}-{序号}
    warehouse_id        BIGINT          NOT NULL,
    supplier_id         BIGINT          NOT NULL,
    stock_id            BIGINT          NOT NULL,
    sku_id              BIGINT          NOT NULL,
    lot_id              BIGINT          NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    reason_code         VARCHAR(24)     NOT NULL,
    contract_ref        VARCHAR(64),                   -- 滞销退货的合同条款号
    food_safety         BOOLEAN         NOT NULL DEFAULT false,
    disposition         VARCHAR(16)     NOT NULL,
    temp_class          VARCHAR(16)     NOT NULL,
    ready_at            TIMESTAMP       NOT NULL,      -- 提货时限起点 T（UTC）
    pickup_deadline_at  TIMESTAMP,                     -- 只有 RETURN 有
    status              VARCHAR(16)     NOT NULL DEFAULT 'OPEN',
    picked_up_at        TIMESTAMP,
    overdue_at          TIMESTAMP,                     -- 超期扫描转报损的时刻
    scrap_order_id      BIGINT,                        -- 超期转的报损单（09）
    created_by          BIGINT          NOT NULL,
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_srtn_code      UNIQUE (code),
    CONSTRAINT ck_srtn_qty       CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_srtn_reason    CHECK (reason_code IN ('QUALITY','RECALL','WRONG_DELIVERY','SLOW_MOVING')),
    CONSTRAINT ck_srtn_slow      CHECK (reason_code <> 'SLOW_MOVING' OR (contract_ref IS NOT NULL AND length(contract_ref) > 0)),
    CONSTRAINT ck_srtn_disp      CHECK (disposition IN ('RETURN','SCRAP','DISCOUNT','EXCHANGE')),
    CONSTRAINT ck_srtn_recall_fs CHECK (reason_code <> 'RECALL' OR food_safety),   -- 召回一律食安 → 只能 RETURN / SCRAP（ck_srtn_fsafe）
    CONSTRAINT ck_srtn_slow_fs   CHECK (reason_code <> 'SLOW_MOVING' OR NOT food_safety),   -- 合同滞销不是食安，四种处置都可以
    CONSTRAINT ck_srtn_fsafe     CHECK (NOT food_safety OR disposition IN ('RETURN','SCRAP')),
    CONSTRAINT ck_srtn_temp      CHECK (temp_class IN ('FRESH','FROZEN','STANDARD')),
    CONSTRAINT ck_srtn_deadline  CHECK (CASE WHEN COALESCE(disposition, '') <> 'RETURN' THEN pickup_deadline_at IS NULL WHEN temp_class = 'FRESH' THEN COALESCE(CAST(strftime('%s', pickup_deadline_at) AS INTEGER) = CAST(strftime('%s', ready_at) AS INTEGER) + 86400, false) WHEN temp_class = 'FROZEN' THEN COALESCE(CAST(strftime('%s', pickup_deadline_at) AS INTEGER) = CAST(strftime('%s', ready_at) AS INTEGER) + 604800, false) ELSE COALESCE(CAST(strftime('%s', pickup_deadline_at) AS INTEGER) = CAST(strftime('%s', ready_at) AS INTEGER) + 1296000, false) END),
    CONSTRAINT ck_srtn_status    CHECK (status IN ('OPEN','AWAITING_PICKUP','PICKED_UP','OVERDUE_SCRAP','DISPOSED','CANCELLED')),
    CONSTRAINT ck_srtn_st_disp   CHECK (status NOT IN ('AWAITING_PICKUP','PICKED_UP','OVERDUE_SCRAP') OR disposition = 'RETURN'),
    CONSTRAINT ck_srtn_picked    CHECK ((status = 'PICKED_UP') = (picked_up_at IS NOT NULL) AND (picked_up_at IS NULL OR CAST(strftime('%s', picked_up_at) AS INTEGER) <= CAST(strftime('%s', pickup_deadline_at) AS INTEGER))),
    CONSTRAINT ck_srtn_ts        CHECK ((length(ready_at) = 19 AND datetime(ready_at) IS ready_at) AND (pickup_deadline_at IS NULL OR (length(pickup_deadline_at) = 19 AND datetime(pickup_deadline_at) IS pickup_deadline_at)) AND (picked_up_at IS NULL OR (length(picked_up_at) = 19 AND datetime(picked_up_at) IS picked_up_at)) AND (overdue_at IS NULL OR (length(overdue_at) = 19 AND datetime(overdue_at) IS overdue_at)) AND (length(created_at) = 19 AND datetime(created_at) IS created_at)),
    CONSTRAINT ck_srtn_overdue   CHECK ((status = 'OVERDUE_SCRAP') = (overdue_at IS NOT NULL) AND (status = 'OVERDUE_SCRAP') = (scrap_order_id IS NOT NULL) AND (overdue_at IS NULL OR CAST(strftime('%s', overdue_at) AS INTEGER) > CAST(strftime('%s', pickup_deadline_at) AS INTEGER)))
);
-- 超期扫描：WHERE status = 'AWAITING_PICKUP' AND pickup_deadline_at < :now
CREATE INDEX ix_srtn_due ON supplier_return(warehouse_id, status, pickup_deadline_at);

-- 温区 → 退供提货时限类别（Doro 定）：sku.temperature_required FROZEN → FROZEN（T+7d）；CHILLED → FRESH（T+24h）；
--   AMBIENT → STANDARD（T+15d），AMBIENT 且 sku.return_as_fresh（常温生鲜，如常温果蔬）→ FRESH。其他温区值一律拒（未定义映射）。
--   跨篇 ALTER（第 1 篇 sku，README 登记）：return_as_fresh 只允许常温 SKU（ck_sku_rtn_fresh）。
--   库层校验：trg_srtn_temp 在建单 / 改 sku_id、temp_class 时按 sku 当前值核对；建单后 temp_class 是快照，SKU 主数据之后再改不回溯。
ALTER TABLE sku ADD COLUMN return_as_fresh BOOLEAN NOT NULL DEFAULT false CONSTRAINT ck_sku_rtn_fresh CHECK (NOT return_as_fresh OR temperature_required = 'AMBIENT');
CREATE TRIGGER trg_srtn_temp_ins BEFORE INSERT ON supplier_return
WHEN NOT EXISTS (SELECT 1 FROM sku k WHERE k.id = NEW.sku_id AND NEW.temp_class = CASE WHEN k.temperature_required = 'FROZEN' THEN 'FROZEN'
  WHEN k.temperature_required = 'CHILLED' THEN 'FRESH' WHEN k.temperature_required = 'AMBIENT' AND k.return_as_fresh THEN 'FRESH'
  WHEN k.temperature_required = 'AMBIENT' THEN 'STANDARD' END)
BEGIN SELECT RAISE(ABORT, 'srtn_temp_class_mismatch'); END;
CREATE TRIGGER trg_srtn_temp_upd BEFORE UPDATE OF sku_id, temp_class ON supplier_return
WHEN NOT EXISTS (SELECT 1 FROM sku k WHERE k.id = NEW.sku_id AND NEW.temp_class = CASE WHEN k.temperature_required = 'FROZEN' THEN 'FROZEN'
  WHEN k.temperature_required = 'CHILLED' THEN 'FRESH' WHEN k.temperature_required = 'AMBIENT' AND k.return_as_fresh THEN 'FRESH'
  WHEN k.temperature_required = 'AMBIENT' THEN 'STANDARD' END)
BEGIN SELECT RAISE(ABORT, 'srtn_temp_class_mismatch'); END;
-- 时钟窗口 + 时间列只写一次（见表头注释）。触发器名带 z：PG 同表 BEFORE 触发器按名字顺序执行，让业务守卫（temp / overdue）先报
    -- 服务端时间（Doro 定）：非属主写入一律由库时钟覆盖，调用方传什么都不算；截止随 ready_at 同步推出
-- 状态机（同 09 trg_scr_forward 口径，对所有角色生效，含表属主）：
--   OPEN → AWAITING_PICKUP / CANCELLED；OPEN → DISPOSED 只限非 RETURN 处置；AWAITING_PICKUP → PICKED_UP / OVERDUE_SCRAP；
--   PICKED_UP / OVERDUE_SCRAP / DISPOSED / CANCELLED 为终态。非法迁移 srtn_state_forward_only。
--   PICKED_UP 后 picked_up_at 不可改（srtn_time_immutable，见 trg_srtn_zclock / trg_srtn_time_lock）。
CREATE TRIGGER trg_srtn_forward BEFORE UPDATE OF status ON supplier_return
WHEN NEW.status IS NOT OLD.status AND NOT ((OLD.status = 'OPEN' AND NEW.status IN ('AWAITING_PICKUP','CANCELLED'))
  OR (OLD.status = 'OPEN' AND NEW.status = 'DISPOSED' AND OLD.disposition <> 'RETURN')
  OR (OLD.status = 'AWAITING_PICKUP' AND NEW.status IN ('PICKED_UP','OVERDUE_SCRAP')))
BEGIN SELECT RAISE(ABORT, 'srtn_state_forward_only'); END;
CREATE TRIGGER trg_srtn_time_lock BEFORE UPDATE ON supplier_return
WHEN NEW.ready_at IS NOT OLD.ready_at OR NEW.pickup_deadline_at IS NOT OLD.pickup_deadline_at OR NEW.created_at IS NOT OLD.created_at
  OR (NEW.status IS OLD.status AND OLD.picked_up_at IS NOT NULL AND NEW.picked_up_at IS NOT OLD.picked_up_at)
BEGIN SELECT RAISE(ABORT, 'srtn_time_immutable'); END;
CREATE TRIGGER trg_srtn_ins_open BEFORE INSERT ON supplier_return
WHEN NEW.status IS NOT 'OPEN'
BEGIN SELECT RAISE(ABORT, 'srtn_insert_open_only'); END;
CREATE TRIGGER trg_srtn_clock_ins BEFORE INSERT ON supplier_return
WHEN strftime('%s', NEW.ready_at) IS NULL OR abs(CAST(strftime('%s', NEW.ready_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
  OR strftime('%s', NEW.created_at) IS NULL OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'srtn_clock_skew'); END;
CREATE TRIGGER trg_srtn_clock_upd BEFORE UPDATE ON supplier_return
WHEN (NEW.picked_up_at IS NOT OLD.picked_up_at AND NEW.picked_up_at IS NOT NULL
      AND (strftime('%s', NEW.picked_up_at) IS NULL OR abs(CAST(strftime('%s', NEW.picked_up_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300))
  OR (NEW.overdue_at IS NOT OLD.overdue_at AND NEW.overdue_at IS NOT NULL
      AND (strftime('%s', NEW.overdue_at) IS NULL OR abs(CAST(strftime('%s', NEW.overdue_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300))
BEGIN SELECT RAISE(ABORT, 'srtn_clock_skew'); END;
-- 授权：不给整表 UPDATE。建单后可写的只有状态推进相关列；ready_at / pickup_deadline_at / temp_class / sku_id / stock_id / qty_milli /
-- reason_code / food_safety / disposition 等受守卫的列不给 wms_app 直接 UPDATE（改错走取消重建）
-- =============================================================================
-- 09_scrap.sql —— 第 9 篇 效期与损耗（PR #4，米雪儿接手）自有 DDL
-- 加载顺序：08_count.sql 之后、11_integration.sql 之前。不改别篇文件；跨篇 ALTER 只有文末对第 10 篇 supplier_return 的外键与超期守卫（README 登记）。
-- 基线 #2 6008032：convert_hold(hold_id, qty, to_hold_type, to_source, op_key) 支持部分转换；可售期到期（SELL_EXPIRED）按 02（6008032）§表 SCRAP_PENDING 行：直接 hold(SCRAP_PENDING)（op_key=SELLEXP:{lot_id}:{date}，operator_id=0），不走 convert_hold，也不走 place_hold（place_hold 只收 PROCESSING / LIVE_HOLD）。
-- 记账型来源（record_only）：PROCESS_LOSS（第 17 篇，原料已随报工 consume_process_hold 扣过）、LIVE_DEATH / LIVE_SHRINK（第 18 篇 consume_live_hold 直接扣，Doro P1）
--   —— 报损单只记账：不冻结（hold_id=0）、行 ledger_mode=NONE、过账不调 post_out。
-- =============================================================================
-- 第 9 篇 效期与损耗：报损单（SCR）。审批通过后由服务端按行调 02 原语 post_out(SCRAP)；
-- SCRAP_PENDING 冻结 source_type='SCRAP'、source_id=本表 id（04 N2）（op_key = SCRH:{scrap_line_id}），审批出账与解冻同事务。
CREATE TABLE scrap_order (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,   -- SCR-{仓}-{节点}-{作业日}-{序号}
    warehouse_id    BIGINT          NOT NULL,
    source_type     VARCHAR(24)     NOT NULL,   -- 取值见 ck_scr_src_type；SELL_EXPIRED：可售天数到期扫描（source_id=lot_id，来源键 SELL_EXPIRED:{lot_id}:{date}，落库 source_id=lot_id + source_date=作业日，见 uq_scr_source；冻结 op_key SELLEXP:{lot_id}:{date}）；RETURN_HANDOVER：04 交接，source_id=待回库记录 id；RETURN_QC：10 质检不合格，source_id=inbound_line.id；SUPPLIER_RETURN：10 退供超期未提，source_id=supplier_return.id，reason_code=PICKUP_OVERDUE
    source_id       BIGINT          NOT NULL DEFAULT 0,
    source_date     DATE            NOT NULL DEFAULT '1970-01-01',   -- 00 §6.4 D3：按日去重白名单（SELL_EXPIRED / LIVE_SHRINK）写仓库作业日；其余来源固定 '1970-01-01'
    reason_code     VARCHAR(24)     NOT NULL,   -- 取值见 ck_scr_reason
    status          VARCHAR(16)     NOT NULL DEFAULT 'DRAFT',
    work_date       DATE            NOT NULL,   -- 仓库时区作业日
    amount_impact   BIGINT          NOT NULL DEFAULT 0,   -- 分
    applicant_id    BIGINT          NOT NULL,
    approver_id     BIGINT,
    approved_at     TIMESTAMP,
    posted_at       TIMESTAMP,
    void_approval_no VARCHAR(64),
    void_ref        VARCHAR(80),                -- PROCESS_LOSS 作废：17 process_reversal.op_key（PRCR:{order}:{uuid}）
    record_only     BOOLEAN         GENERATED ALWAYS AS (source_type IN ('PROCESS_LOSS','LIVE_DEATH','LIVE_SHRINK')) STORED,   -- 记账型（不冻结、不出账）；由来源推出，应用写不进               -- 交接误报作废（SCRAP_MISREPORT 审批单号，第 12 篇）；只有 VOIDED 才有
    version         BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_scr_code   UNIQUE (code),
    CONSTRAINT ck_scr_status CHECK (status IN ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED','REJECTED','CANCELLED','VOIDED')),
    CONSTRAINT ck_scr_void   CHECK ((status = 'VOIDED') = ((void_approval_no IS NOT NULL AND length(void_approval_no) > 0) OR void_ref IS NOT NULL)),
    -- 审批单号全局格式 APR-{仓库编码 [A-Z0-9]{2,16}}-{yyyyMMdd}-{6位序号}（Q17，与 02 ck_hold_approval_no 一致）
    CONSTRAINT ck_scr_apr_fmt CHECK (void_approval_no IS NULL OR (length(void_approval_no) BETWEEN 22 AND 36 AND void_approval_no GLOB 'APR-?*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' AND substr(void_approval_no, 5, length(void_approval_no) - 20) NOT GLOB '*[^A-Z0-9]*')),
    CONSTRAINT ck_scr_sod    CHECK (approver_id IS NULL OR approver_id <> applicant_id),
    -- 小赵复评 S1：审批 / 过账后的人员与时间必须齐
    -- 记账型在容差内可 DRAFT → POSTED 直接过账（无人审）；超容差走 PENDING_APPROVAL（PROCESS_LOSS 的审批即 17 的 PROCESS_YIELD_DEVIATION 合并单）
    CONSTRAINT ck_scr_appr   CHECK (status NOT IN ('APPROVED','POSTED') OR (approver_id IS NOT NULL AND approved_at IS NOT NULL)
                                    OR (record_only AND status = 'POSTED' AND approver_id IS NULL AND approved_at IS NULL)),
    CONSTRAINT ck_scr_posted CHECK (status <> 'POSTED' OR posted_at IS NOT NULL),
    CONSTRAINT ck_scr_src_type CHECK (source_type IN ('EXPIRY_SCAN','SELL_EXPIRED','MANUAL','RETURN_QC','RETURN_HANDOVER','COUNT','EXCEPTION','LIVE_DEATH','LIVE_SHRINK','PROCESS_LOSS','SUPPLIER_RETURN')),
    -- 00 §6.4 D3（大肥鱼定）：按日去重白名单 SELL_EXPIRED / LIVE_SHRINK 的 source_date = work_date；其余来源（含 LIVE_DEATH）固定 '1970-01-01'
    CONSTRAINT ck_scr_src_date CHECK (CASE WHEN source_type IN ('SELL_EXPIRED','LIVE_SHRINK') THEN source_date = work_date ELSE source_date = '1970-01-01' END),
    CONSTRAINT ck_scr_reason CHECK (reason_code IN ('EXPIRED','NEAR_EXPIRY','SELL_EXPIRED','DAMAGED','QC_REJECT','NATURAL_LOSS','OTHER',
                                                  'TRIM','DRIP','WEIGH_DIFF','DEFECT','LIVE_DEATH','PICKUP_OVERDUE')),
    -- 加工损耗原因只给 PROCESS_LOSS 用；PROCESS_LOSS 只收这 4 个（17 process_output.loss_reason 一一对应，不再映射成 NATURAL_LOSS）
    CONSTRAINT ck_scr_reason_src CHECK (
        (source_type = 'PROCESS_LOSS') = (reason_code IN ('TRIM','DRIP','WEIGH_DIFF','DEFECT'))
        AND (reason_code <> 'LIVE_DEATH' OR source_type = 'LIVE_DEATH')
        AND (reason_code <> 'PICKUP_OVERDUE' OR source_type = 'SUPPLIER_RETURN')   -- 第 10 篇退供超期未提（Alex 定案）
    ),
    -- PROCESS_LOSS 作废（17 损耗改原因/改数量）挂 17 冲回键 void_ref=PRCR:…，不走 SCRAP_MISREPORT
    CONSTRAINT ck_scr_void_ref CHECK (void_ref IS NULL OR (source_type = 'PROCESS_LOSS' AND status = 'VOIDED' AND void_ref LIKE 'PRCR:%'))
);
CREATE INDEX ix_scr_wh_status ON scrap_order(warehouse_id, status, work_date);
-- 00 §6.4 D3：三列唯一，对所有来源生效；SELL_EXPIRED 靠 source_date 实现「同一批次同一天一张」
CREATE UNIQUE INDEX uq_scr_source ON scrap_order(source_type, source_id, source_date) WHERE source_id <> 0 AND status NOT IN ('REJECTED','CANCELLED');
-- ↑ 同一来源（效期扫描任务、待回库记录等）最多一张有效报损单

CREATE TABLE scrap_line (
    id              BIGINT          PRIMARY KEY,
    scrap_id        BIGINT          NOT NULL REFERENCES scrap_order(id),
    line_no         INT             NOT NULL,
    stock_id        BIGINT          NOT NULL,
    sku_id          BIGINT          NOT NULL,
    lot_id          BIGINT          NOT NULL,
    scrap_qty_milli BIGINT          NOT NULL,
    hold_id         BIGINT          NOT NULL DEFAULT 0,   -- SCRAP_PENDING 冻结；0 = 已出库待报损（不冻结）
    ledger_mode     VARCHAR(16)     NOT NULL DEFAULT 'POST_OUT',   -- POST_OUT 出账 / NONE 已扣账只记损耗
    cost_amount     BIGINT          NOT NULL DEFAULT 0,
    CONSTRAINT uq_scr_line   UNIQUE (scrap_id, line_no),
    CONSTRAINT ck_scrl_int   CHECK (scrap_qty_milli = CAST(scrap_qty_milli AS BIGINT)),   -- CAST 只在 SQLite 起作用，PG 恒真
    CONSTRAINT ck_scrl_qty   CHECK (scrap_qty_milli > 0),
    CONSTRAINT ck_scrl_mode  CHECK (ledger_mode IN ('POST_OUT','NONE'))
);
CREATE INDEX ix_scrl_stock ON scrap_line(stock_id);
-- 报损单库层守卫（小赵 I3 / 复评 K1–K4、S1；大肥鱼定案）
-- 状态白名单：DRAFT→PENDING_APPROVAL/CANCELLED，PENDING_APPROVAL→APPROVED/REJECTED/DRAFT，APPROVED→POSTED；POSTED/REJECTED/CANCELLED/VOIDED 是终态。
-- K1：锁定来源 = RETURN_HANDOVER（待回库交接）和 RETURN_QC（质检不合格）：不许撤回 / 取消 / 驳回（scrap_handover_no_revoke → 40930），
--     release_scrap_hold(REVOKED) 也拒绝（02 f802a41）；质检或交接判错只走 SCRAP_MISREPORT 审批 → VOIDED（与 convert_hold SCRAP_PENDING→RETURN_QC 同事务）。
-- K3：code / warehouse_id / source_* / applicant_id 建单后不可改；approver_id / approved_at / posted_at 只能从 NULL 写一次；终态整行只读。
-- S1：INSERT 只能是 DRAFT。K2：不许 DELETE / TRUNCATE（PG 兜超级用户和迁移脚本），SQLite 另拦 REPLACE。
-- 报损行（K3/K4）：只能在 DRAFT 单下新增或修改；单据离开 DRAFT 后整行只读；
-- 带冻结的行（hold_id≠0）数量必须等于冻结余量、库存一致；锁定来源（交接 / 质检）的行冻结写定后数量、库存、hold_id 都不能改
CREATE TRIGGER trg_scr_handover BEFORE UPDATE ON scrap_order
WHEN OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC') AND NEW.status <> OLD.status AND NEW.status IN ('DRAFT','CANCELLED','REJECTED')
BEGIN SELECT RAISE(ABORT, 'scrap_handover_no_revoke'); END;
CREATE TRIGGER trg_scr_forward BEFORE UPDATE ON scrap_order
WHEN (NEW.status <> OLD.status AND NOT ((OLD.status = 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','CANCELLED'))
       OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('APPROVED','REJECTED','DRAFT'))
       OR (OLD.status = 'APPROVED' AND NEW.status = 'POSTED')
       OR (OLD.record_only AND OLD.status = 'DRAFT' AND NEW.status = 'POSTED')
       OR (OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC') AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED') AND NEW.status = 'VOIDED')
       OR (OLD.source_type = 'PROCESS_LOSS' AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED') AND NEW.status = 'VOIDED')))
  OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.source_date IS NOT OLD.source_date
BEGIN SELECT RAISE(ABORT, 'scrap_state_forward_only'); END;
CREATE TRIGGER trg_scr_immutable BEFORE UPDATE ON scrap_order
WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.applicant_id IS NOT OLD.applicant_id
  OR (OLD.approver_id IS NOT NULL AND NEW.approver_id IS NOT OLD.approver_id)
  OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NOT OLD.approved_at)
  OR (OLD.posted_at IS NOT NULL AND NEW.posted_at IS NOT OLD.posted_at)
  OR (OLD.status IN ('POSTED','REJECTED','CANCELLED','VOIDED') AND (NEW.reason_code IS NOT OLD.reason_code
      OR NEW.amount_impact IS NOT OLD.amount_impact OR NEW.void_approval_no IS NOT OLD.void_approval_no OR NEW.work_date IS NOT OLD.work_date))
BEGIN SELECT RAISE(ABORT, 'scrap_immutable'); END;
CREATE TRIGGER trg_scr_ins_draft BEFORE INSERT ON scrap_order
WHEN NEW.status <> 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','APPROVED','POSTED','REJECTED','CANCELLED','VOIDED')
BEGIN SELECT RAISE(ABORT, 'scrap_insert_draft_only'); END;
CREATE TRIGGER trg_scr_no_replace BEFORE INSERT ON scrap_order
WHEN EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'scrap_duplicate'); END;
CREATE TRIGGER trg_scr_no_delete BEFORE DELETE ON scrap_order BEGIN SELECT RAISE(ABORT, 'scrap_no_delete'); END;
CREATE TRIGGER trg_scrl_no_replace BEFORE INSERT ON scrap_line
WHEN EXISTS (SELECT 1 FROM scrap_line l WHERE l.id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'scrap_duplicate'); END;
CREATE TRIGGER trg_scrl_no_delete BEFORE DELETE ON scrap_line BEGIN SELECT RAISE(ABORT, 'scrap_no_delete'); END;
CREATE TRIGGER trg_scrl_draft_ins BEFORE INSERT ON scrap_line
WHEN NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.status = 'DRAFT')
BEGIN SELECT RAISE(ABORT, 'scrap_line_locked'); END;
CREATE TRIGGER trg_scrl_draft_upd BEFORE UPDATE ON scrap_line
WHEN (NEW.scrap_id IS NOT OLD.scrap_id OR NEW.line_no IS NOT OLD.line_no OR NEW.stock_id IS NOT OLD.stock_id OR NEW.sku_id IS NOT OLD.sku_id
      OR NEW.lot_id IS NOT OLD.lot_id OR NEW.scrap_qty_milli IS NOT OLD.scrap_qty_milli OR NEW.hold_id IS NOT OLD.hold_id
      OR NEW.ledger_mode IS NOT OLD.ledger_mode OR NEW.cost_amount IS NOT OLD.cost_amount)
  AND NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.status = 'DRAFT')
BEGIN SELECT RAISE(ABORT, 'scrap_line_locked'); END;
CREATE TRIGGER trg_scrl_hold_lock BEFORE UPDATE ON scrap_line
WHEN OLD.hold_id <> 0 AND (NEW.scrap_qty_milli <> OLD.scrap_qty_milli OR NEW.stock_id <> OLD.stock_id OR NEW.hold_id <> OLD.hold_id)
  AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.source_type IN ('RETURN_HANDOVER','RETURN_QC'))
BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_locked'); END;
CREATE TRIGGER trg_scrl_record_only BEFORE INSERT ON scrap_line
WHEN (NEW.hold_id <> 0 OR NEW.ledger_mode <> 'NONE') AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.record_only)
BEGIN SELECT RAISE(ABORT, 'scrap_line_record_only'); END;
CREATE TRIGGER trg_scrl_record_only_u BEFORE UPDATE ON scrap_line
WHEN (NEW.hold_id <> 0 OR NEW.ledger_mode <> 'NONE') AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.record_only)
BEGIN SELECT RAISE(ABORT, 'scrap_line_record_only'); END;
CREATE TRIGGER trg_scrl_hold_ins BEFORE INSERT ON scrap_line
WHEN NEW.hold_id <> 0 AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.hold_id AND h.stock_id = NEW.stock_id
      AND h.status = 'HELD' AND h.hold_qty_milli - h.released_qty_milli = NEW.scrap_qty_milli)
BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_mismatch'); END;
CREATE TRIGGER trg_scrl_hold_upd BEFORE UPDATE ON scrap_line
WHEN NEW.hold_id <> 0 AND OLD.hold_id = 0
  AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.hold_id AND h.stock_id = NEW.stock_id
      AND h.status = 'HELD' AND h.hold_qty_milli - h.released_qty_milli = NEW.scrap_qty_milli)
BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_mismatch'); END;
-- 授权（I4）：不给 DELETE/TRUNCATE，作废走状态
-- -----------------------------------------------------------------------------
-- 跨篇 ALTER（第 10 篇 supplier_return，README 登记）：退供超期未提 → 本篇报损单 + 02 原语 hold(SCRAP_PENDING)
--   supplier_return 在 10_returns.sql 建，scrap_order 在本文件建，所以外键和守卫写在这里。
--   AWAITING_PICKUP → OVERDUE_SCRAP 时必须已有：本篇报损单（source_type=SUPPLIER_RETURN，source_id=退供单 id，reason_code=PICKUP_OVERDUE，未驳回/取消）
--   和该单下的 SCRAP_PENDING 冻结（02 hold：source_type=SCRAP，source_id=报损单 id，op_key=SRTO:{退供单 id}，同库存行，HELD，冻结量 = 退供数量）。
--   其他状态不能转入 OVERDUE_SCRAP，INSERT 也不能直接写 OVERDUE_SCRAP。错误 srtn_overdue_no_scrap_hold（23514）。
--   进入 OVERDUE_SCRAP 后终态：status / scrap_order_id / overdue_at / stock_id / qty_milli 不可改（srtn_overdue_immutable），防转超期后换挂报损单绕过冻结校验。
--   op_key 由守卫按 'SRTO:' || id 精确比较（大小写敏感、无前导零、无空白）；重放 hold 撞 02 uq_hold_op，重放转超期 WHERE status='AWAITING_PICKUP' 影响 0 行。
-- -----------------------------------------------------------------------------
-- 一张退供单最多挂一张报损单、一张报损单最多挂一张退供单（并发转超期只成一张，含已取消/驳回的旧单：uq_scr_source 放过它们，本索引不放）
CREATE UNIQUE INDEX uq_scr_srtn ON scrap_order(source_id) WHERE source_type = 'SUPPLIER_RETURN';
CREATE UNIQUE INDEX uq_srtn_scrap ON supplier_return(scrap_order_id) WHERE scrap_order_id IS NOT NULL;
-- 退供报损单的来源守卫（小玛丽 pr03 B1 同类：条件更新 0 行静默成功）：
--   INSERT：来源退供单必须正处于 AWAITING_PICKUP（srtn_scrap_not_awaiting），已提货 / 未进待提货的不能开报损单。
--   之后任何「向前」迁移（提交 / 审批 / 过账；CANCELLED、REJECTED 除外）都要求退供单已是 OVERDUE_SCRAP 且 scrap_order_id 指向本单
--   （srtn_scrap_orphan）。服务端转超期的条件更新若影响 0 行却照样提交，留下的报损单只能取消（同事务 release_scrap_hold），永远过不了账。
--   服务端仍须按 00 §6.7 检查 rowcount、0 行返回 40930 并回滚整个事务；库层这条只兜底「不会因此误报损出账」。
CREATE TRIGGER trg_scr_srtn_ins BEFORE INSERT ON scrap_order
WHEN NEW.source_type = 'SUPPLIER_RETURN' AND NOT EXISTS (SELECT 1 FROM supplier_return r WHERE r.id = NEW.source_id AND r.status = 'AWAITING_PICKUP')
BEGIN SELECT RAISE(ABORT, 'srtn_scrap_not_awaiting'); END;
CREATE TRIGGER trg_scr_srtn_upd BEFORE UPDATE ON scrap_order
WHEN NEW.source_type = 'SUPPLIER_RETURN' AND NEW.status IS NOT OLD.status AND NEW.status NOT IN ('CANCELLED','REJECTED')
  AND NOT EXISTS (SELECT 1 FROM supplier_return r WHERE r.id = NEW.source_id AND r.status = 'OVERDUE_SCRAP' AND r.scrap_order_id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'srtn_scrap_orphan'); END;
CREATE TRIGGER trg_srtn_overdue_ins BEFORE INSERT ON supplier_return
WHEN NEW.status = 'OVERDUE_SCRAP'
BEGIN SELECT RAISE(ABORT, 'srtn_overdue_no_scrap_hold'); END;
CREATE TRIGGER trg_srtn_overdue BEFORE UPDATE ON supplier_return
WHEN NEW.status = 'OVERDUE_SCRAP' AND OLD.status <> 'OVERDUE_SCRAP' AND (OLD.status <> 'AWAITING_PICKUP'
  OR NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_order_id AND o.source_type = 'SUPPLIER_RETURN'
      AND o.source_id = NEW.id AND o.reason_code = 'PICKUP_OVERDUE' AND o.status NOT IN ('REJECTED','CANCELLED'))
  OR NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.hold_type = 'SCRAP_PENDING' AND h.source_type = 'SCRAP'
      AND h.source_id = NEW.scrap_order_id AND h.stock_id = NEW.stock_id AND h.op_key = 'SRTO:' || NEW.id
      AND h.status = 'HELD' AND h.hold_qty_milli = NEW.qty_milli))
BEGIN SELECT RAISE(ABORT, 'srtn_overdue_no_scrap_hold'); END;
CREATE TRIGGER trg_srtn_overdue_lock BEFORE UPDATE ON supplier_return
WHEN OLD.status = 'OVERDUE_SCRAP' AND (NEW.status IS NOT OLD.status OR NEW.id IS NOT OLD.id OR NEW.scrap_order_id IS NOT OLD.scrap_order_id
  OR NEW.overdue_at IS NOT OLD.overdue_at OR NEW.stock_id IS NOT OLD.stock_id OR NEW.qty_milli IS NOT OLD.qty_milli)
BEGIN SELECT RAISE(ABORT, 'srtn_overdue_immutable'); END;
CREATE TRIGGER trg_srtn_scrap_fk BEFORE UPDATE ON supplier_return
WHEN NEW.scrap_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_order_id)
BEGIN SELECT RAISE(ABORT, 'fk_srtn_scrap'); END;
-- -----------------------------------------------------------------------------
-- 幂等 / 集成 / 审计
-- -----------------------------------------------------------------------------

-- ===== 第 11 篇（#6）新增：upstream_push_log / offline_paper_record =====
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
    received_at     TIMESTAMP    NOT NULL,   -- 中心接收时间（UTC 整秒）。时间加固：PG 非属主插入由 trg_upl_server_time 强制为服务端时间；SQLite 只收 now±300s
    result_status   VARCHAR(16)  NOT NULL,   -- ACCEPTED/DUPLICATE/CONFLICT/REJECTED/FAILED
    result_code     VARCHAR(8)   NOT NULL DEFAULT '0',
    wms_doc_no      VARCHAR(64),
    inbound_message_id BIGINT    NOT NULL DEFAULT 0,
    retain_until    TIMESTAMP    NOT NULL,   -- ≥ received_at + 90 天（= 长期 requestNo 去重 TTL；且 ≥ 全量备份周期 + 1 天，由启动自检保证）
    CONSTRAINT ck_upl_result CHECK (result_status IN ('ACCEPTED','DUPLICATE','CONFLICT','REJECTED','FAILED')),
    -- 小赵 I1 / 项目经理决定：保留期下限 90 天库层落地。PG 用 interval；SQLite 时间列是 TEXT，用 julianday 做等价比较
    -- （同时接受 'YYYY-MM-DD HH:MM:SS' 与 ISO 'T' 写法），并要求两列都能被解析，防止乱写的字符串让比较结果为 NULL 而放行
    CONSTRAINT ck_upl_retain CHECK ((typeof(received_at) = 'text' AND length(received_at) = 19 AND received_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(received_at) IS received_at AND substr(received_at, 12, 2) <= '23') AND (typeof(retain_until) = 'text' AND length(retain_until) = 19 AND retain_until GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(retain_until) IS retain_until AND substr(retain_until, 12, 2) <= '23') AND CAST(strftime('%s', retain_until) AS INTEGER) - CAST(strftime('%s', received_at) AS INTEGER) >= 7776000),   -- 时间加固：只收标准整秒格式，按整数秒比较
    -- D6 口径：规范化报文 SHA-256，64 位小写十六进制（与 ck_obo_hash 同写法，两库通用）
    CONSTRAINT ck_upl_sha CHECK (length(payload_sha) = 64 AND lower(payload_sha) = payload_sha AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(payload_sha,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = '')
);
CREATE INDEX ix_upl_time ON upstream_push_log(warehouse_id, received_at);
CREATE INDEX ix_upl_src  ON upstream_push_log(source_system, source_order_no, received_at);
-- 小赵 B1：只追加在库层落地（写法同 stock_movement）。wms_app 只有 SELECT/INSERT；
-- 唯一能删的是清理函数 purge_push_log()（属主 wms_purge_owner，与 02 purge_expired 同一套），且只能删 retain_until 已过（按 UTC）的行；UPDATE、TRUNCATE 对任何角色都拦。
-- 第 11 篇 Q1 定案：离线纸质单事后补录（00 §6.6.1 PAPER_BACKFILL，§6.6.2 backfill_deadline_at）。
-- 一行 = 一张纸质单。补录产生的库存事件走 02 post_event，biz_key 与在线事件同一规则，由 uq_mvk_biz_line 去重；本表另按 (warehouse_id, biz_key) 防同单重复补录。
CREATE TABLE offline_paper_record (
    id                   BIGINT       PRIMARY KEY,
    warehouse_id         BIGINT       NOT NULL REFERENCES warehouse(id),
    device_id            VARCHAR(64)  NOT NULL,                 -- 离线的终端
    action_type          VARCHAR(24)  NOT NULL,                 -- 拣货确认 / 收货登记 / 签收
    biz_key              VARCHAR(128) NOT NULL,                 -- 与在线事件同一 biz_key 规则
    occurred_at          TIMESTAMP    NOT NULL,                 -- UTC，纸面记录的作业时间
    operator_id          BIGINT       NOT NULL,                 -- 纸面上的实际作业人
    payload              TEXT         NOT NULL,
    photo_ids            TEXT,
    approval_type        VARCHAR(24)  NOT NULL DEFAULT 'PAPER_BACKFILL',
    applicant_id         BIGINT       NOT NULL,                 -- 补录申请人（offline.paper.backfill）
    approver_id          BIGINT,                                -- 主管（offline.paper.approve）
    approved_at          TIMESTAMP,
    status               VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    offline_since        TIMESTAMP    NOT NULL,                 -- UTC，该设备本次离线起点
    reconnected_at       TIMESTAMP    NOT NULL,                 -- UTC，恢复联网时间
    backfill_deadline_at TIMESTAMP    NOT NULL,                 -- UTC，= reconnected_at + 24h（服务端下发值，00 §6.6.2）
    submitted_at         TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    exception_case_id    BIGINT,                                -- 过期补录转的异常单（第 10 篇）
    created_at           TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_paper_bizkey   UNIQUE (warehouse_id, biz_key),
    CONSTRAINT ck_paper_type     CHECK (approval_type = 'PAPER_BACKFILL'),
    CONSTRAINT ck_paper_action   CHECK (action_type IN ('PICK_CONFIRM','RECEIVE_REGISTER','POD_SIGN')),
    CONSTRAINT ck_paper_status   CHECK (status IN ('PENDING','APPROVED','REJECTED','EXPIRED')),
    CONSTRAINT ck_paper_deadline CHECK (COALESCE(CAST(strftime('%s', backfill_deadline_at) AS INTEGER) = CAST(strftime('%s', reconnected_at) AS INTEGER) + 86400, 0)),   -- 时间加固：整数秒；解析不了 → 0（不放行）
    CONSTRAINT ck_paper_ts CHECK ((typeof(occurred_at) = 'text' AND length(occurred_at) = 19 AND occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(occurred_at) IS occurred_at AND substr(occurred_at, 12, 2) <= '23') AND (typeof(offline_since) = 'text' AND length(offline_since) = 19 AND offline_since GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(offline_since) IS offline_since AND substr(offline_since, 12, 2) <= '23') AND (typeof(reconnected_at) = 'text' AND length(reconnected_at) = 19 AND reconnected_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(reconnected_at) IS reconnected_at AND substr(reconnected_at, 12, 2) <= '23') AND (typeof(backfill_deadline_at) = 'text' AND length(backfill_deadline_at) = 19 AND backfill_deadline_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(backfill_deadline_at) IS backfill_deadline_at AND substr(backfill_deadline_at, 12, 2) <= '23') AND (typeof(submitted_at) = 'text' AND length(submitted_at) = 19 AND submitted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(submitted_at) IS submitted_at AND substr(submitted_at, 12, 2) <= '23') AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(created_at) IS created_at AND substr(created_at, 12, 2) <= '23') AND (approved_at IS NULL OR (typeof(approved_at) = 'text' AND length(approved_at) = 19 AND approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(approved_at) IS approved_at AND substr(approved_at, 12, 2) <= '23'))),
    -- 过期：提交晚于 backfill_deadline_at 只能落 EXPIRED，且必须挂异常单；未过期不能是 EXPIRED
    CONSTRAINT ck_paper_window   CHECK (COALESCE(CAST(strftime('%s', reconnected_at) AS INTEGER) > CAST(strftime('%s', offline_since) AS INTEGER) AND CAST(strftime('%s', occurred_at) AS INTEGER) >= CAST(strftime('%s', offline_since) AS INTEGER) AND CAST(strftime('%s', occurred_at) AS INTEGER) <= CAST(strftime('%s', reconnected_at) AS INTEGER) AND CAST(strftime('%s', submitted_at) AS INTEGER) >= CAST(strftime('%s', reconnected_at) AS INTEGER), 0)),   -- 时间加固：整数秒，不按文本
    CONSTRAINT ck_paper_expired  CHECK (COALESCE((status = 'EXPIRED' AND CAST(strftime('%s', submitted_at) AS INTEGER) > CAST(strftime('%s', backfill_deadline_at) AS INTEGER) AND exception_case_id IS NOT NULL) OR (status <> 'EXPIRED' AND CAST(strftime('%s', submitted_at) AS INTEGER) <= CAST(strftime('%s', backfill_deadline_at) AS INTEGER) AND exception_case_id IS NULL), 0)),
    CONSTRAINT ck_paper_sod      CHECK (approver_id IS NULL OR approver_id <> applicant_id),   -- 申请人不能自批
    CONSTRAINT ck_paper_approve  CHECK ((status IN ('APPROVED','REJECTED') AND approver_id IS NOT NULL AND approved_at IS NOT NULL)
                                        OR (status IN ('PENDING','EXPIRED') AND approver_id IS NULL AND approved_at IS NULL))
);
CREATE INDEX ix_paper_pending ON offline_paper_record(warehouse_id, status, submitted_at);
-- SQLite（边缘节点）没有角色：UPDATE/DELETE 一律拦；到期清理同流水表，由维护脚本导出后 DROP 触发器→删 retain_until 已过的行→重建，全程审计
CREATE TRIGGER trg_upl_no_update BEFORE UPDATE ON upstream_push_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: upstream_push_log'); END;
CREATE TRIGGER trg_upl_no_delete BEFORE DELETE ON upstream_push_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: upstream_push_log'); END;

-- 第 11 篇：推送日志到期清理只经函数（替代原 wms_archiver 直删）。函数本体放本篇文件（两库：SQLite 无函数，边缘按上面维护脚本清理）。
-- 属主 wms_purge_owner、wms_cleaner 的 EXECUTE、wms_purge_owner 对 upstream_push_log 的 SELECT/DELETE 都由 #2 99_grants.sql 按目录检查授予
-- （GRANT 自 4e3a7efb；ALTER FUNCTION … OWNER 自 #2 round 7）。SECURITY DEFINER + search_path = pg_catalog, public（本库对象都在 public）。
CREATE TABLE idempotency_record (
    idem_key     VARCHAR(80)  PRIMARY KEY,
    req_hash     VARCHAR(64)  NOT NULL,
    response     TEXT         NOT NULL,
    status_code  INT          NOT NULL,
    ttl_seconds  INTEGER      NOT NULL DEFAULT 86400,   -- 时间加固：去重 TTL（秒）。PG 非属主插入 expires_at = 服务端 created_at + ttl_seconds（trg_idem_server_time）
    created_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- 一律存 UTC（P1）
    expires_at   TIMESTAMP    NOT NULL,               -- UTC；写入后只许往后改（trg_idem_expiry_fwd，P2）
    CONSTRAINT ck_idem_ttl CHECK (ttl_seconds BETWEEN 1 AND 7776000)   -- 1 秒 ~ 90 天
    -- 小赵 S1：SQLite 不约束时间类型，'garbage'、T 格式、整数都能写进去，按文本比较永远清不掉；限定为 'YYYY-MM-DD HH:MM:SS' 且是真实日期时间
    , CONSTRAINT ck_idem_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) IS NOT NULL AND time(created_at) IS NOT NULL AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8) AND substr(created_at, 12, 2) <= '23') AND (typeof(expires_at) = 'text' AND length(expires_at) = 19 AND expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(expires_at) IS NOT NULL AND time(expires_at) IS NOT NULL AND date(expires_at) = substr(expires_at, 1, 10) AND time(expires_at) = substr(expires_at, 12, 8) AND substr(expires_at, 12, 2) <= '23'))
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
    received_at     TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- 时间加固（00 §6.8）：中心接收时间，UTC 整秒，由库写（trg_11_recv_server_time；SQLite trg_in_msg_received_now）
    client_occurred_at TIMESTAMP,                -- T2（Doro 裁定）：上游/设备给的原始时间（UTC），只供展示、排障；不参与任何 CHECK、清理、比较
    processed_at    TIMESTAMP,
    biz_ref         VARCHAR(64),                 -- 第 11 篇：处理成功后生成的 WMS 单号
    CONSTRAINT uq_in_msg UNIQUE (source, biz_type, external_no),
    CONSTRAINT ck_in_msg_status CHECK (status IN ('RECEIVED','PROCESSING','DONE','FAILED','DEAD','REJECTED'))
    , CONSTRAINT ck_in_msg_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND client_occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(client_occurred_at) IS client_occurred_at AND substr(client_occurred_at, 12, 2) <= '23'))   -- 只验格式，不设容差
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
    next_retry_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- UTC
    last_error      VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- UTC
    sent_at         TIMESTAMP,                          -- UTC；写入后只许往后改（P2）
    -- 第 11 篇：节点内单调序号（00 §9.1 边缘回传按 (node_id, seq) 严格顺序，缺口暂停）
    warehouse_id    BIGINT       NOT NULL DEFAULT 0,
    node_id         INT          NOT NULL DEFAULT 0,
    seq             BIGINT       NOT NULL DEFAULT 0,
    replay_count    SMALLINT     NOT NULL DEFAULT 0,   -- 死信人工重放次数（重放沿用原 id，下游按事件 id 幂等）
    -- 小吴 C2：SENT 必须注明依据：2XX = 下游 2xx；DUP_409 = 下游 409 且被识别为"同一请求重复"（docs/11 §6.3）
    ack_kind        VARCHAR(8),
    -- 小吴 C1：DEAD 人工跳过的审计（谁、何时、原因），同事务另写 audit_log
    skipped_by      BIGINT,
    skipped_at      TIMESTAMP,
    skip_reason     VARCHAR(256),
    CONSTRAINT ck_outbox_status CHECK (status IN ('PENDING','SENDING','SENT','FAILED','DEAD','SKIPPED')),
    CONSTRAINT ck_outbox_seq    CHECK (seq >= 0),
    CONSTRAINT ck_outbox_ack    CHECK ((status = 'SENT' AND ack_kind IS NOT NULL AND ack_kind IN ('2XX','DUP_409')) OR (status <> 'SENT' AND ack_kind IS NULL)),
    CONSTRAINT ck_outbox_skip   CHECK ((status = 'SKIPPED' AND skipped_by IS NOT NULL AND skipped_at IS NOT NULL AND skip_reason IS NOT NULL AND length(trim(skip_reason)) >= 4)
                                    OR (status <> 'SKIPPED' AND skipped_by IS NULL AND skipped_at IS NULL AND skip_reason IS NULL)),
    CONSTRAINT ck_outbox_sent CHECK (status <> 'SENT' OR sent_at IS NOT NULL)   -- P3
    , CONSTRAINT ck_outbox_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) IS NOT NULL AND time(created_at) IS NOT NULL AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8) AND substr(created_at, 12, 2) <= '23') AND (typeof(next_retry_at) = 'text' AND length(next_retry_at) = 19 AND next_retry_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(next_retry_at) IS NOT NULL AND time(next_retry_at) IS NOT NULL AND date(next_retry_at) = substr(next_retry_at, 1, 10) AND time(next_retry_at) = substr(next_retry_at, 12, 8) AND substr(next_retry_at, 12, 2) <= '23') AND (sent_at IS NULL OR (typeof(sent_at) = 'text' AND length(sent_at) = 19 AND sent_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(sent_at) IS NOT NULL AND time(sent_at) IS NOT NULL AND date(sent_at) = substr(sent_at, 1, 10) AND time(sent_at) = substr(sent_at, 12, 8) AND substr(sent_at, 12, 2) <= '23')))   -- 小赵 S1
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
CREATE INDEX ix_outbox_bizkey  ON outbox_event(biz_key, id);   -- 同键串行发送
CREATE UNIQUE INDEX uq_outbox_seq ON outbox_event(node_id, seq) WHERE seq > 0;
-- 小吴 C1：同一 biz_key 同时最多一条 DEAD（它之后的事件都被阻塞在 PENDING/FAILED，不可能再进死信）
CREATE UNIQUE INDEX uq_outbox_dead_bizkey ON outbox_event(biz_key) WHERE status = 'DEAD';
-- 形态 A：relay 扫待补 seq 的事件（seq=0），按 id 顺序补号（小吴 C3）
CREATE INDEX ix_outbox_noseq ON outbox_event(node_id, id) WHERE seq = 0;
-- 小吴 C1/C3：投递顺序与 seq 的库层守卫（两库同义）
--   ① 进 SENDING 时，同 biz_key 更早（id 更小）的事件必须都已 SENT 或 SKIPPED，否则 outbox_bizkey_blocked
--   ② SKIPPED 只能从 DEAD 来，且 SKIPPED / SENT 是终态
--   ③ seq 只能从 0 补成正数一次，之后不可改（relay 补号、边缘事务内取号都满足）
CREATE TRIGGER trg_outbox_bizkey_blocked BEFORE UPDATE OF status ON outbox_event
WHEN NEW.status = 'SENDING' AND OLD.status <> 'SENDING' AND EXISTS (SELECT 1 FROM outbox_event e WHERE e.biz_key = NEW.biz_key AND e.id < NEW.id AND e.status NOT IN ('SENT','SKIPPED'))
BEGIN SELECT RAISE(ABORT, 'outbox_bizkey_blocked'); END;
CREATE TRIGGER trg_outbox_illegal_transition BEFORE UPDATE OF status ON outbox_event
WHEN (NEW.status = 'SKIPPED' AND OLD.status NOT IN ('DEAD','SKIPPED')) OR (OLD.status IN ('SENT','SKIPPED') AND NEW.status <> OLD.status)
BEGIN SELECT RAISE(ABORT, 'outbox_illegal_transition'); END;
CREATE TRIGGER trg_outbox_seq_immutable BEFORE UPDATE OF seq ON outbox_event
WHEN NEW.seq <> OLD.seq AND OLD.seq <> 0
BEGIN SELECT RAISE(ABORT, 'outbox_seq_immutable'); END;

-- 小赵 Q2：去重记录与 outbox 只能清理"已过期 / 已投递且过保留期"的行（两库触发器，条件与 purge_expired() 一致）
-- search_path 固定为 pg_catalog, public。now()、interval、AT TIME ZONE 走 pg_catalog。
CREATE TRIGGER trg_idem_purge_guard BEFORE DELETE ON idempotency_record WHEN NOT COALESCE(OLD.expires_at < datetime('now'), 0)
BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: idempotency_record'); END;
CREATE TRIGGER trg_outbox_purge_guard BEFORE DELETE ON outbox_event WHEN NOT COALESCE(OLD.status = 'SENT' AND OLD.sent_at < datetime('now', '-7 days'), 0)
BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: outbox_event'); END;
-- 九轮 P2：过期/投递时间写入后只许往后改，不许改早；created_at 不可改；SENT 是终态；sent_at 首次写入不得早于 created_at
-- search_path 固定为 pg_catalog, public。now()、extract、interval、AT TIME ZONE 走 pg_catalog，调用方 schema 里的 now() 不生效。
-- 不是 outbox_event 表属主的角色，只能以初始状态 PENDING（不带 sent_at）插入。SENT 只能经 UPDATE 写入（受 sent_at_not_now 约束）。
-- wms_app 是 NOLOGIN，应用用的是继承它的登录角色，current_user 不是 wms_app，所以不能按角色名判断。
-- 非属主插入非 PENDING、或带上 sent_at：直接拒绝（outbox_insert_not_pending），不把 status 改写成 PENDING。
-- 表属主（建表的迁移角色）可以插入其他状态，种子和迁移走这条。
-- search_path 固定为 pg_catalog, public。属主查询全部写在 pg_catalog。
-- SQLite 没有角色：所有插入都按“非属主”处理，只能是 PENDING 且不带 sent_at，FAILED 同样拒绝。
-- 验证脚本造 SENT 种子时临时 DROP 本触发器、写完重建（单独的种子路径）
CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event WHEN NEW.status IS NOT 'PENDING' OR NEW.sent_at IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'outbox_insert_not_pending'); END;
CREATE TRIGGER trg_idem_expiry_fwd BEFORE UPDATE ON idempotency_record WHEN NEW.created_at IS NOT OLD.created_at OR NEW.expires_at < OLD.expires_at
BEGIN SELECT RAISE(ABORT, 'expiry_backdate: idempotency_record'); END;
CREATE TRIGGER trg_outbox_expiry_fwd BEFORE UPDATE ON outbox_event WHEN NEW.created_at IS NOT OLD.created_at OR (OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR NEW.sent_at < OLD.sent_at)) OR (OLD.sent_at IS NULL AND NEW.sent_at < OLD.created_at) OR (OLD.status = 'SENT' AND NEW.status <> 'SENT')
BEGIN SELECT RAISE(ABORT, 'expiry_backdate: outbox_event'); END;
CREATE TRIGGER trg_outbox_sent_now BEFORE UPDATE ON outbox_event WHEN NEW.status = 'SENT' AND OLD.status <> 'SENT' AND abs(julianday(NEW.sent_at) - julianday('now')) * 86400 > 5
BEGIN SELECT RAISE(ABORT, 'sent_at_not_now'); END;
-- SQLite REPLACE 冲突删旧行不触发 DELETE 触发器 → BEFORE INSERT 主键已存在就中止（应用把 idem_duplicate 当作"键已存在"处理，与 PG 23505 同分支）
CREATE TRIGGER trg_idem_no_replace BEFORE INSERT ON idempotency_record WHEN EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key)
BEGIN SELECT RAISE(ABORT, 'idem_duplicate'); END;
-- 00 §6.10 / 小玛丽 pr2-r11 X2：WHEN 覆盖本表全部唯一键，部分索引带同一谓词（不加 IS NULL 之类逃逸）：
--   PK(id)；uq_outbox_seq(node_id, seq) WHERE seq > 0；uq_outbox_dead_bizkey(biz_key) WHERE status = 'DEAD'
CREATE TRIGGER trg_outbox_no_replace BEFORE INSERT ON outbox_event WHEN EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id OR (NEW.seq > 0 AND o.seq > 0 AND o.node_id = NEW.node_id AND o.seq = NEW.seq) OR (NEW.status = 'DEAD' AND o.status = 'DEAD' AND o.biz_key = NEW.biz_key))
BEGIN SELECT RAISE(ABORT, 'outbox_duplicate'); END;

CREATE TABLE audit_log (
    id              BIGINT       PRIMARY KEY,
    actor_id        BIGINT       REFERENCES sys_user(id),   -- Doro 裁定：SQLite 建表不检查父表是否已存在，可前向引用 12_auth 的 sys_user
    actor_name      VARCHAR(64),
    client_type     VARCHAR(16),
    action          VARCHAR(64)  NOT NULL,   -- outbound.cancel_after_pick / lot.expiry_override ...
    target_type     VARCHAR(32),
    target_id       VARCHAR(64),
    before_json     TEXT,
    after_json      TEXT,
    reason          VARCHAR(256),
    warehouse_id    BIGINT       REFERENCES warehouse(id),   -- 第 13 轮配套：声明外键（NULL = 非仓级操作）
    trace_id        VARCHAR(32),
    ip              VARCHAR(45),
    occurred_at     TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- 时间加固（00 §6.8）：UTC 整秒，由库写（trg_11_recv_server_time；SQLite trg_audit_occurred_now）
    client_occurred_at TIMESTAMP   -- T2：设备原始时间（UTC），只供展示、排障；不参与任何 CHECK、清理、比较
    , CONSTRAINT ck_audit_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND client_occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(client_occurred_at) IS client_occurred_at AND substr(client_occurred_at, 12, 2) <= '23'))
);
CREATE INDEX ix_audit_target ON audit_log(target_type, target_id, occurred_at DESC);
CREATE INDEX ix_audit_actor  ON audit_log(actor_id, occurred_at DESC);

CREATE TABLE numbering_segment (
    biz_prefix   VARCHAR(16)  NOT NULL,
    date_key     VARCHAR(8)   NOT NULL,
    next_value   BIGINT       NOT NULL,
    step         INT          NOT NULL DEFAULT 100,
    updated_at   TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- 时间加固（00 §6.8）
    PRIMARY KEY (biz_prefix, date_key)
);
-- 取号（号段预取，两库语义一致）：
--   UPDATE numbering_segment SET next_value = next_value + step WHERE biz_prefix=? AND date_key=?
--   然后 SELECT next_value - step 作为本段起点。多实例安全，不依赖 Redis 持久化。
-- 小玛丽 blocker（号段回退）：numbering_segment 只许前进。next_value 只增不减、键列 (biz_prefix, date_key) 不可改、
-- 不许 DELETE / TRUNCATE（删了重插 = 回退，任何角色都拦，含属主；旧日号段留着，每天每前缀一行，体量可忽略），SQLite 不许 REPLACE。
-- 取号原语 UPDATE … SET next_value = next_value + step 不受影响（step 必须 > 0，否则 next_value 变小同样被拦）。
CREATE TRIGGER trg_numbering_regress BEFORE UPDATE ON numbering_segment WHEN NEW.next_value < OLD.next_value
BEGIN SELECT RAISE(ABORT, 'numbering_regress'); END;
CREATE TRIGGER trg_numbering_key_immutable BEFORE UPDATE OF biz_prefix, date_key ON numbering_segment WHEN NEW.biz_prefix IS NOT OLD.biz_prefix OR NEW.date_key IS NOT OLD.date_key
BEGIN SELECT RAISE(ABORT, 'numbering_key_immutable'); END;
CREATE TRIGGER trg_numbering_no_delete BEFORE DELETE ON numbering_segment
BEGIN SELECT RAISE(ABORT, 'numbering_regress'); END;
CREATE TRIGGER trg_numbering_no_replace BEFORE INSERT ON numbering_segment WHEN EXISTS (SELECT 1 FROM numbering_segment n WHERE n.biz_prefix = NEW.biz_prefix AND n.date_key = NEW.date_key)
BEGIN SELECT RAISE(ABORT, 'numbering_regress'); END;
-- inbound_message 判重键不可改：id、(source, biz_type, external_no)；SQLite no-REPLACE 覆盖 PK 与 uq_in_msg（00 §6.10）
CREATE TRIGGER trg_in_msg_key_immutable BEFORE UPDATE OF id, source, biz_type, external_no ON inbound_message WHEN NEW.id IS NOT OLD.id OR NEW.source IS NOT OLD.source OR NEW.biz_type IS NOT OLD.biz_type OR NEW.external_no IS NOT OLD.external_no
BEGIN SELECT RAISE(ABORT, 'inbound_message_key_immutable'); END;
CREATE TRIGGER trg_in_msg_no_replace BEFORE INSERT ON inbound_message WHEN EXISTS (SELECT 1 FROM inbound_message m WHERE m.id = NEW.id OR (m.source = NEW.source AND m.biz_type = NEW.biz_type AND m.external_no = NEW.external_no))
BEGIN SELECT RAISE(ABORT, 'inbound_message_duplicate'); END;
-- =============================================================================
-- 第 11 篇 时间加固（小玛丽时间专项 11-1…11-6；00 §6.8 时间约定、§6.9 search_path）
-- 服务端时间：PG 用 BEFORE 触发器强制 date_trunc('second', now() AT TIME ZONE 'UTC')，表属主（迁移/种子）豁免（同 trg_outbox_insert_pending 先例）；
-- SQLite 无角色：由服务端写的时间只收标准整秒且与 now 相差 ≤ 300s，格式错的交给各表 CHECK（ck_upl_retain / ck_idem_ts / ck_paper_ts）报。
-- =============================================================================
-- 11-1 阻断：upstream_push_log.received_at 由库写；retain_until 至少 received_at + 90 天（调用方可以往后延，不能往前）
-- 11-2：idempotency_record.created_at 由库写，expires_at = created_at + ttl_seconds；显式给过去的 expires_at 直接拒（idem_expires_in_past）
-- 11-5：纸质单补录。INSERT：submitted_at、created_at 由库写（审批态插入时 approved_at 也由库写）；
-- UPDATE：进入 APPROVED/REJECTED 时 approved_at 由库写；时间列写入后对任何角色都不可改（paper_time_immutable）
-- SQLite 等价：插入时服务端时间 ±300s；纸质单时间列不可改（verify_sqlite 的种子路径临时 DROP 这些 *_now 触发器写历史数据，写完重建）
CREATE TRIGGER trg_upl_received_now BEFORE INSERT ON upstream_push_log
WHEN (typeof(NEW.received_at) = 'text' AND length(NEW.received_at) = 19 AND NEW.received_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.received_at) IS NEW.received_at AND substr(NEW.received_at, 12, 2) <= '23') AND abs(CAST(strftime('%s', NEW.received_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'upl_received_not_now'); END;
CREATE TRIGGER trg_idem_created_now BEFORE INSERT ON idempotency_record
WHEN (typeof(NEW.created_at) = 'text' AND length(NEW.created_at) = 19 AND NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23') AND (typeof(NEW.expires_at) = 'text' AND length(NEW.expires_at) = 19 AND NEW.expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.expires_at) IS NEW.expires_at AND substr(NEW.expires_at, 12, 2) <= '23') AND NOT EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key) AND abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'idem_created_not_now'); END;
CREATE TRIGGER trg_idem_expires_past BEFORE INSERT ON idempotency_record
WHEN (typeof(NEW.created_at) = 'text' AND length(NEW.created_at) = 19 AND NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23') AND (typeof(NEW.expires_at) = 'text' AND length(NEW.expires_at) = 19 AND NEW.expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.expires_at) IS NEW.expires_at AND substr(NEW.expires_at, 12, 2) <= '23') AND NOT EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key) AND abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300 AND CAST(strftime('%s', NEW.expires_at) AS INTEGER) <= CAST(strftime('%s', 'now') AS INTEGER)
BEGIN SELECT RAISE(ABORT, 'idem_expires_in_past'); END;
CREATE TRIGGER trg_idem_expires_ttl BEFORE INSERT ON idempotency_record
WHEN (typeof(NEW.created_at) = 'text' AND length(NEW.created_at) = 19 AND NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23') AND (typeof(NEW.expires_at) = 'text' AND length(NEW.expires_at) = 19 AND NEW.expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.expires_at) IS NEW.expires_at AND substr(NEW.expires_at, 12, 2) <= '23') AND NOT EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key) AND abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300 AND CAST(strftime('%s', NEW.expires_at) AS INTEGER) > CAST(strftime('%s', 'now') AS INTEGER) AND CAST(strftime('%s', NEW.expires_at) AS INTEGER) <> CAST(strftime('%s', NEW.created_at) AS INTEGER) + NEW.ttl_seconds
BEGIN SELECT RAISE(ABORT, 'idem_expires_not_ttl'); END;
CREATE TRIGGER trg_paper_submitted_now BEFORE INSERT ON offline_paper_record
WHEN (typeof(NEW.submitted_at) = 'text' AND length(NEW.submitted_at) = 19 AND NEW.submitted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.submitted_at) IS NEW.submitted_at AND substr(NEW.submitted_at, 12, 2) <= '23') AND (typeof(NEW.created_at) = 'text' AND length(NEW.created_at) = 19 AND NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23') AND (abs(CAST(strftime('%s', NEW.submitted_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300 OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300 OR (NEW.approved_at IS NOT NULL AND (typeof(NEW.approved_at) = 'text' AND length(NEW.approved_at) = 19 AND NEW.approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.approved_at) IS NEW.approved_at AND substr(NEW.approved_at, 12, 2) <= '23') AND abs(CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300))
BEGIN SELECT RAISE(ABORT, 'paper_submitted_not_now'); END;
CREATE TRIGGER trg_paper_approved_now BEFORE UPDATE ON offline_paper_record
WHEN NEW.status IN ('APPROVED','REJECTED') AND OLD.status NOT IN ('APPROVED','REJECTED') AND (typeof(NEW.approved_at) = 'text' AND length(NEW.approved_at) = 19 AND NEW.approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.approved_at) IS NEW.approved_at AND substr(NEW.approved_at, 12, 2) <= '23') AND abs(CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'paper_approved_not_now'); END;
CREATE TRIGGER trg_paper_time_immutable BEFORE UPDATE ON offline_paper_record
WHEN NEW.occurred_at IS NOT OLD.occurred_at OR NEW.offline_since IS NOT OLD.offline_since OR NEW.reconnected_at IS NOT OLD.reconnected_at OR NEW.backfill_deadline_at IS NOT OLD.backfill_deadline_at OR NEW.submitted_at IS NOT OLD.submitted_at OR NEW.created_at IS NOT OLD.created_at OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NOT OLD.approved_at)
BEGIN SELECT RAISE(ABORT, 'paper_time_immutable'); END;
-- T2（Doro 裁定，待 00 §6.8）：audit_log.occurred_at、inbound_message.received_at 由库写；设备原始时间放 client_occurred_at
CREATE TRIGGER trg_audit_occurred_now BEFORE INSERT ON audit_log
WHEN NOT (typeof(NEW.occurred_at) = 'text' AND length(NEW.occurred_at) = 19 AND NEW.occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.occurred_at) IS NEW.occurred_at AND substr(NEW.occurred_at, 12, 2) <= '23') OR abs(CAST(strftime('%s', NEW.occurred_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'audit_occurred_not_now'); END;
CREATE TRIGGER trg_in_msg_received_now BEFORE INSERT ON inbound_message
WHEN NOT (typeof(NEW.received_at) = 'text' AND length(NEW.received_at) = 19 AND NEW.received_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.received_at) IS NEW.received_at AND substr(NEW.received_at, 12, 2) <= '23') OR abs(CAST(strftime('%s', NEW.received_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300
BEGIN SELECT RAISE(ABORT, 'inbound_received_not_now'); END;
-- 00 §6.10 防 REPLACE（SQLite）：upstream_push_log 只追加，REPLACE 撞主键会删旧行且不触发 DELETE 触发器 → 插入前主键已存在即拒，错误名沿用 append_only_violation（同 12 audit_log）
CREATE TRIGGER trg_upl_no_replace BEFORE INSERT ON upstream_push_log WHEN EXISTS (SELECT 1 FROM upstream_push_log u WHERE u.id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'append_only_violation: upstream_push_log'); END;
-- offline_paper_record 有 trg_paper_time_immutable（BEFORE UPDATE RAISE），按 §6.10 第 2 条同时查主键和 uq_paper_bizkey；paper_duplicate → 40910 key_type=OFFLINE_PAPER（PG 撞 uq_paper_bizkey 同口径）
CREATE TRIGGER trg_paper_no_replace BEFORE INSERT ON offline_paper_record WHEN EXISTS (SELECT 1 FROM offline_paper_record o WHERE o.id = NEW.id OR (o.warehouse_id = NEW.warehouse_id AND o.biz_key = NEW.biz_key))
BEGIN SELECT RAISE(ABORT, 'paper_duplicate'); END;
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
-- =============================================================================
-- 12b_auth_audit.sql —— 第 12 篇（权限与审计，PR #9）自有 DDL
-- 加载顺序：紧跟 12_auth.sql 之后、90_available_view.sql 之前。
-- 跨篇加列一律 ALTER（README「跨篇 ALTER 登记表」已登记）。
-- =============================================================================

-- [跨篇 ALTER] audit_log（表主人：11_integration.sql）
ALTER TABLE audit_log ADD COLUMN node_id INT NOT NULL DEFAULT 0;            -- 0 = 未登记节点，应用层必填真实 node_id
ALTER TABLE audit_log ADD COLUMN node_seq BIGINT NOT NULL DEFAULT 0;
ALTER TABLE audit_log ADD COLUMN device_instance_id VARCHAR(64);
ALTER TABLE audit_log ADD COLUMN approval_id BIGINT;
CREATE UNIQUE INDEX uq_audit_node_seq ON audit_log(node_id, node_seq);
CREATE INDEX ix_audit_wh ON audit_log(warehouse_id, occurred_at DESC);
-- Doro 定：DEFAULT 0 只为兼容存量行；新写入 node_id/node_seq 必须 > 0（应用层映射 40001 PARAM_INVALID）
CREATE TRIGGER trg_audit_node_required BEFORE INSERT ON audit_log
WHEN NEW.node_id <= 0 OR NEW.node_seq <= 0
BEGIN SELECT RAISE(ABORT, 'audit_node_required: 40001'); END;
-- audit_log 只追加（docs/12 §6.4）：行级 UPDATE/DELETE 与 TRUNCATE 都拦；归档走按月导出 + 维护窗口内专用角色
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;
CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;
-- 小赵 B1：SQLite REPLACE 删旧行不触发 DELETE 触发器（recursive_triggers=OFF），id 或 (node_id,node_seq) 已存在就直接 ABORT
CREATE TRIGGER trg_audit_no_replace BEFORE INSERT ON audit_log
WHEN EXISTS (SELECT 1 FROM audit_log a WHERE a.id = NEW.id OR (a.node_id = NEW.node_id AND a.node_seq = NEW.node_seq))
BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;

-- [本篇表，12_auth.sql 由 #2 拆分建立] sys_user 加 perm_version
ALTER TABLE sys_user ADD COLUMN perm_version BIGINT NOT NULL DEFAULT 1 CONSTRAINT ck_user_perm_ver CHECK (perm_version > 0);

-- -----------------------------------------------------------------------------
-- docs/12 权限与审计：设备绑定、离线令牌、主管审批
-- -----------------------------------------------------------------------------

-- 设备实例绑定：device_instance_id（App 安装实例）↔ 账号 + 仓。一个实例同时最多一条 PENDING/ACTIVE 绑定
CREATE TABLE user_device_binding (
    id                  BIGINT       PRIMARY KEY,
    device_instance_id  VARCHAR(64)  NOT NULL,
    device_id           BIGINT,                      -- 第 1 篇 device 台账；司机自有手机可为空
    client_type         VARCHAR(16)  NOT NULL,       -- PDA / DRIVER_APP
    user_id             BIGINT       NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',   -- PENDING（待主管确认）/ ACTIVE / REVOKED（终态）
    approval_id         BIGINT,                      -- DEVICE_BIND 审批单
    bound_at            TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- UTC
    activated_at        TIMESTAMP,
    revoked_at          TIMESTAMP,
    revoked_by          BIGINT,
    revoke_reason       VARCHAR(64),
    CONSTRAINT ck_udb_client CHECK (client_type IN ('PDA','DRIVER_APP')),
    CONSTRAINT ck_udb_status CHECK ((status = 'PENDING' AND revoked_at IS NULL AND activated_at IS NULL)
        OR (status = 'ACTIVE' AND revoked_at IS NULL AND activated_at IS NOT NULL AND approval_id IS NOT NULL)
        OR (status = 'REVOKED' AND revoked_at IS NOT NULL))
);
-- 同一设备实例同时最多一条未吊销绑定（PENDING 或 ACTIVE）
CREATE UNIQUE INDEX uq_udb_active ON user_device_binding(device_instance_id) WHERE status IN ('PENDING','ACTIVE');
CREATE INDEX ix_udb_user ON user_device_binding(user_id, status);

-- 离线令牌：断网时边缘节点/终端本地校验用。签名在应用层，库里只存 jti 与吊销状态
CREATE TABLE offline_token (
    id                  BIGINT       PRIMARY KEY,
    jti                 VARCHAR(64)  NOT NULL,
    binding_id          BIGINT       NOT NULL,       -- user_device_binding.id
    user_id             BIGINT       NOT NULL,
    device_instance_id  VARCHAR(64)  NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    perm_version        BIGINT       NOT NULL,       -- 签发时的权限版本，权限变更后旧令牌联网即失效
    issued_at           TIMESTAMP    NOT NULL,
    expires_at          TIMESTAMP    NOT NULL,
    revoked_at          TIMESTAMP,
    CONSTRAINT uq_offline_jti UNIQUE (jti),
    CONSTRAINT ck_offline_ttl CHECK (expires_at > issued_at),
    -- 有效期上限 12 小时（docs/12 §3.3，小赵 I4）
    CONSTRAINT ck_offline_max_ttl CHECK (datetime(expires_at) <= datetime(issued_at, '+12 hours'))
);
CREATE INDEX ix_offline_binding ON offline_token(binding_id) WHERE revoked_at IS NULL;

-- 主管审批（docs/12 §5）
CREATE TABLE approval_request (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,       -- 审批单号 APR-{warehouse_code}-{yyyyMMdd}-{6 位序号}（ck_apr_code）；02 stock_hold.approval_no 存本列
    approval_type       VARCHAR(32)  NOT NULL,       -- POD_CORRECT / CANCEL_AFTER_PICK / UNPLANNED_FAILOVER / DEVICE_BIND / SCRAP_MISREPORT
    warehouse_id        BIGINT       NOT NULL,
    target_type         VARCHAR(32)  NOT NULL,
    target_id           VARCHAR(64)  NOT NULL,
    payload_json        TEXT         NOT NULL,       -- 申请时的完整命令，审批通过后原样执行
    payload_hash        CHAR(64)     NOT NULL,
    reason              VARCHAR(256) NOT NULL,
    requested_by        BIGINT       NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    first_approver_id   BIGINT,
    first_approver_role VARCHAR(32),                 -- 审批时实际使用的角色（服务端写入，FAILOVER 由触发器核对）
    first_approved_at   TIMESTAMP,
    second_approver_id  BIGINT,                      -- 仅 UNPLANNED_FAILOVER
    second_approver_role VARCHAR(32),
    second_approved_at  TIMESTAMP,
    result_ref          VARCHAR(64),                 -- 执行结果引用：如 POD 更正的新 pod_id + correct_seq（服务端执行时分配）
    decided_at          TIMESTAMP,
    reject_reason       VARCHAR(256),
    expires_at          TIMESTAMP    NOT NULL,
    version             INT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),   -- UTC；expires_at 等时间列一律存 UTC（对齐 02 ad8ec1b P1）
    CONSTRAINT uq_apr_code UNIQUE (code),
    CONSTRAINT ck_apr_type CHECK (approval_type IN ('POD_CORRECT','CANCEL_AFTER_PICK','UNPLANNED_FAILOVER','DEVICE_BIND','SCRAP_MISREPORT',
        'PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER','PROCESS_REWORK')),   -- 【ck_apr_type 变更】00 已登记的 4 类 + PROCESS_REWORK（Doro 06:16）
    -- 非计划切换 = 发起人 + 仓库主管 + 中心运维三人（00 §9.1），角色字符串固定；是否真持有该角色由 trg_apr_transition 查 sys_user_role
    CONSTRAINT ck_apr_failover_roles CHECK (approval_type <> 'UNPLANNED_FAILOVER'
        OR ((first_approver_id IS NULL OR first_approver_role = 'WH_SUPERVISOR')
            AND (second_approver_id IS NULL OR second_approver_role = 'CENTER_OPS'))),
    CONSTRAINT ck_apr_status CHECK (status IN ('PENDING','PARTIAL','APPROVED','REJECTED','EXPIRED','WITHDRAWN')),
    CONSTRAINT ck_apr_sod CHECK (first_approver_id IS NULL OR first_approver_id <> requested_by),
    CONSTRAINT ck_apr_dual CHECK (second_approver_id IS NULL
        OR (approval_type = 'UNPLANNED_FAILOVER' AND second_approver_id <> requested_by AND second_approver_id <> first_approver_id)),
    CONSTRAINT ck_apr_done CHECK (status <> 'APPROVED' OR (first_approver_id IS NOT NULL
        AND (approval_type <> 'UNPLANNED_FAILOVER' OR second_approver_id IS NOT NULL))),
    CONSTRAINT ck_apr_hash CHECK (length(payload_hash) = 64),
    -- 小赵 I2：审批人三列成组；PARTIAL 只用于 FAILOVER 且只有第一人；APPROVED/REJECTED 必有 decided_at，未决不能有
    CONSTRAINT ck_apr_pair CHECK (
        ((first_approver_id IS NULL AND first_approver_role IS NULL AND first_approved_at IS NULL)
          OR (first_approver_id IS NOT NULL AND first_approver_role IS NOT NULL AND first_approved_at IS NOT NULL))
        AND ((second_approver_id IS NULL AND second_approver_role IS NULL AND second_approved_at IS NULL)
          OR (second_approver_id IS NOT NULL AND second_approver_role IS NOT NULL AND second_approved_at IS NOT NULL))),
    CONSTRAINT ck_apr_partial CHECK (status <> 'PARTIAL'
        OR (approval_type = 'UNPLANNED_FAILOVER' AND first_approver_id IS NOT NULL AND second_approver_id IS NULL)),
    CONSTRAINT ck_apr_decided CHECK ((status IN ('APPROVED','REJECTED') AND decided_at IS NOT NULL)
        OR (status IN ('PENDING','PARTIAL') AND decided_at IS NULL)
        OR status IN ('EXPIRED','WITHDRAWN')),
    -- 审批单号统一格式 APR-{warehouse_code}-{yyyyMMdd}-{6 位序号}（所有审批类型共用；02 stock_hold.approval_no 存的就是它）。
    -- 小赵 T1：仓库编码段收紧为 [A-Z0-9]{2,16}（与 #8 ck_wh_code 一致），写法对齐 02 ck_hold_approval_no @92e1477：PG 用 ~，SQLite 用 GLOB + 总长 22–36
    CONSTRAINT ck_apr_code CHECK (
        length(code) BETWEEN 22 AND 36 AND substr(code, 1, 4) = 'APR-'
        AND substr(code, 5, length(code) - 20) NOT GLOB '*[^A-Z0-9]*'
        AND substr(code, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
        AND (substr(code, -11, 2) GLOB '0[1-9]' OR substr(code, -11, 2) GLOB '1[0-2]')
        AND (substr(code, -9, 2) GLOB '0[1-9]' OR substr(code, -9, 2) GLOB '[12][0-9]' OR substr(code, -9, 2) GLOB '3[01]')),
    -- SCRAP_MISREPORT 审批人：质检主管或中心运维（是否真持有由 trg_apr_final / trg_apr_role 查 sys_user_role）
    CONSTRAINT ck_apr_scrap_roles CHECK (approval_type <> 'SCRAP_MISREPORT'
        OR first_approver_id IS NULL OR first_approver_role IN ('QC_SUPERVISOR','CENTER_OPS'))
);
CREATE UNIQUE INDEX uq_apr_open ON approval_request(approval_type, target_type, target_id) WHERE status IN ('PENDING','PARTIAL');
CREATE INDEX ix_apr_wh ON approval_request(warehouse_id, status, created_at);
CREATE INDEX ix_apr_requester ON approval_request(requested_by, status, created_at);   -- GET /approvals?mine=true

-- ===== 小赵 I1/I2/I5：审批只能 INSERT 成 PENDING；迁移单向；审批人写入后不可改；过期不能再审；FAILOVER 确认人必须真持有角色 =====
CREATE TRIGGER trg_apr_no_replace BEFORE INSERT ON approval_request
WHEN EXISTS (SELECT 1 FROM approval_request a WHERE a.id = NEW.id OR a.code = NEW.code
  OR (a.status IN ('PENDING','PARTIAL') AND a.approval_type = NEW.approval_type AND a.target_type = NEW.target_type AND a.target_id = NEW.target_id))
BEGIN SELECT RAISE(ABORT, 'approval_duplicate'); END;
CREATE TRIGGER trg_apr_insert BEFORE INSERT ON approval_request
WHEN NEW.status <> 'PENDING' OR NEW.first_approver_id IS NOT NULL OR NEW.second_approver_id IS NOT NULL
  OR NEW.decided_at IS NOT NULL OR NEW.result_ref IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'approval_insert_not_pending'); END;
CREATE TRIGGER trg_apr_code_wh BEFORE INSERT ON approval_request
WHEN length(NEW.code) BETWEEN 22 AND 36 AND substr(NEW.code, 1, 4) = 'APR-'
  AND substr(NEW.code, 5, length(NEW.code) - 20) NOT GLOB '*[^A-Z0-9]*'
  AND substr(NEW.code, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
  AND NOT EXISTS (SELECT 1 FROM warehouse w WHERE w.id = NEW.warehouse_id AND w.code = substr(NEW.code, 5, length(NEW.code) - 20))
BEGIN SELECT RAISE(ABORT, 'approval_code_warehouse_mismatch'); END;
CREATE TRIGGER trg_apr_insert_role BEFORE INSERT ON approval_request
WHEN NEW.approval_type = 'SCRAP_MISREPORT' AND NOT EXISTS (
    SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
     JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id
     WHERE ur.user_id = NEW.requested_by AND r.code = 'WH_SUPERVISOR')
BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;
CREATE TRIGGER trg_apr_final BEFORE UPDATE ON approval_request
WHEN OLD.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')
  OR NEW.payload_hash IS NOT OLD.payload_hash OR NEW.payload_json IS NOT OLD.payload_json
  OR NEW.requested_by IS NOT OLD.requested_by OR NEW.approval_type IS NOT OLD.approval_type
  OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
  OR NEW.target_type IS NOT OLD.target_type OR NEW.target_id IS NOT OLD.target_id
  OR NEW.expires_at IS NOT OLD.expires_at OR NEW.created_at IS NOT OLD.created_at
BEGIN SELECT RAISE(ABORT, 'approval_final'); END;
CREATE TRIGGER trg_apr_transition BEFORE UPDATE ON approval_request
WHEN OLD.status IN ('PENDING','PARTIAL') AND NOT ((OLD.status = NEW.status AND NEW.status IN ('PENDING','PARTIAL'))
  OR (OLD.status = 'PENDING' AND NEW.status IN ('PARTIAL','APPROVED','REJECTED','EXPIRED','WITHDRAWN'))
  OR (OLD.status = 'PARTIAL' AND NEW.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')))
BEGIN SELECT RAISE(ABORT, 'approval_transition_invalid'); END;
CREATE TRIGGER trg_apr_approver_immutable BEFORE UPDATE ON approval_request
WHEN (OLD.first_approver_id IS NOT NULL AND (NEW.first_approver_id IS NOT OLD.first_approver_id
    OR NEW.first_approver_role IS NOT OLD.first_approver_role OR NEW.first_approved_at IS NOT OLD.first_approved_at))
  OR (OLD.second_approver_id IS NOT NULL AND NEW.second_approver_id IS NOT OLD.second_approver_id)
BEGIN SELECT RAISE(ABORT, 'approval_approver_immutable'); END;
CREATE TRIGGER trg_apr_expired BEFORE UPDATE ON approval_request
WHEN NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status AND COALESCE(datetime(OLD.expires_at) <= datetime('now'), 0)
BEGIN SELECT RAISE(ABORT, 'approval_expired'); END;
CREATE TRIGGER trg_apr_role BEFORE UPDATE ON approval_request
WHEN NEW.approval_type = 'UNPLANNED_FAILOVER' AND (
    (NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NOT EXISTS (
       SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
        JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id
        WHERE ur.user_id = NEW.first_approver_id AND r.code = 'WH_SUPERVISOR'))
 OR (NEW.second_approver_id IS NOT NULL AND OLD.second_approver_id IS NULL AND NOT EXISTS (
       SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
        WHERE ur.user_id = NEW.second_approver_id AND r.code = 'CENTER_OPS')))
BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;
CREATE TRIGGER trg_apr_perm BEFORE UPDATE ON approval_request
WHEN NEW.approval_type IN ('DEVICE_BIND','POD_CORRECT','CANCEL_AFTER_PICK','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER','PROCESS_REWORK')
  AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NEW.first_approver_role IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
      JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id
     WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
       AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
            WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))
       AND p.code = CASE NEW.approval_type WHEN 'DEVICE_BIND' THEN 'device.binding.approve'
                                           WHEN 'POD_CORRECT' THEN 'delivery.pod.correct.approve'
                                           WHEN 'PAPER_BACKFILL' THEN 'offline.paper.approve'
                                           WHEN 'BOX_VOID' THEN 'pack.box.void.approve'
                                           WHEN 'PROCESS_YIELD_DEVIATION' THEN 'process.yield.approve'
                                           WHEN 'LIVE_DEATH_OVER' THEN 'live.death.approve'
                                           WHEN 'PROCESS_REWORK' THEN 'process.rework.approve'
                                           ELSE 'outbound.order.cancel_after_pick.approve' END)
BEGIN SELECT RAISE(ABORT, 'approval_perm_not_held'); END;
CREATE TRIGGER trg_apr_scrap_role BEFORE UPDATE ON approval_request
WHEN NEW.approval_type = 'SCRAP_MISREPORT' AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
        WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
          AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
               WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id)))
BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;

-- ===== 小赵 I3 + S1：设备绑定 INSERT 只能 PENDING；REVOKED 终态；身份列不可改；激活必须有本绑定的已通过 DEVICE_BIND 审批，审批人 ≠ 使用人 =====
CREATE TRIGGER trg_udb_no_replace BEFORE INSERT ON user_device_binding
WHEN EXISTS (SELECT 1 FROM user_device_binding b WHERE b.id = NEW.id
  OR (b.device_instance_id = NEW.device_instance_id AND b.status IN ('PENDING','ACTIVE')))
BEGIN SELECT RAISE(ABORT, 'binding_duplicate'); END;
CREATE TRIGGER trg_udb_insert BEFORE INSERT ON user_device_binding WHEN NEW.status <> 'PENDING' OR NEW.approval_id IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'binding_insert_not_pending'); END;
CREATE TRIGGER trg_udb_immutable BEFORE UPDATE ON user_device_binding
WHEN OLD.status = 'REVOKED' OR (OLD.status = 'ACTIVE' AND NEW.status = 'PENDING')
  OR NEW.device_instance_id IS NOT OLD.device_instance_id OR NEW.user_id IS NOT OLD.user_id
  OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.client_type IS NOT OLD.client_type
  OR NEW.device_id IS NOT OLD.device_id OR NEW.bound_at IS NOT OLD.bound_at
  OR (OLD.approval_id IS NOT NULL AND NEW.approval_id IS NOT OLD.approval_id)
BEGIN SELECT RAISE(ABORT, 'binding_immutable'); END;
CREATE TRIGGER trg_udb_activate BEFORE UPDATE ON user_device_binding
WHEN NEW.status = 'ACTIVE' AND OLD.status = 'PENDING' AND NOT EXISTS (
  SELECT 1 FROM approval_request a WHERE a.id = NEW.approval_id AND a.approval_type = 'DEVICE_BIND'
    AND a.status = 'APPROVED' AND a.target_type = 'DEVICE_BINDING' AND a.target_id = CAST(NEW.id AS TEXT)
    AND a.first_approver_id <> NEW.user_id)
BEGIN SELECT RAISE(ABORT, 'binding_approval_invalid'); END;
CREATE TRIGGER trg_udb_no_delete BEFORE DELETE ON user_device_binding BEGIN SELECT RAISE(ABORT, 'append_only_violation: user_device_binding'); END;
CREATE TRIGGER trg_apr_no_delete BEFORE DELETE ON approval_request BEGIN SELECT RAISE(ABORT, 'append_only_violation: approval_request'); END;

-- ===== 小赵 I4：离线令牌只能写一次 revoked_at；其余列不可改；SQLite 防 REPLACE =====
CREATE TRIGGER trg_offline_guard BEFORE UPDATE ON offline_token
WHEN OLD.revoked_at IS NOT NULL OR NEW.jti IS NOT OLD.jti OR NEW.binding_id IS NOT OLD.binding_id
  OR NEW.user_id IS NOT OLD.user_id OR NEW.device_instance_id IS NOT OLD.device_instance_id
  OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.perm_version IS NOT OLD.perm_version
  OR NEW.issued_at IS NOT OLD.issued_at OR NEW.expires_at IS NOT OLD.expires_at
BEGIN SELECT RAISE(ABORT, 'offline_token_immutable'); END;
CREATE TRIGGER trg_offline_no_replace BEFORE INSERT ON offline_token
WHEN EXISTS (SELECT 1 FROM offline_token t WHERE t.id = NEW.id OR t.jti = NEW.jti)
BEGIN SELECT RAISE(ABORT, 'offline_token_duplicate'); END;

-- sys_user.perm_version 只升不降（撤权必须让旧令牌失效）；SQLite 防 REPLACE 把版本打回 1（小赵 I7）。
-- 下发应用 USER_PERM 一律"UPDATE，0 行再 INSERT"，不用 REPLACE / UPSERT（docs/12 §4.3）
CREATE TRIGGER trg_user_perm_ver BEFORE UPDATE ON sys_user WHEN NEW.perm_version < OLD.perm_version
BEGIN SELECT RAISE(ABORT, 'perm_version_rewind'); END;
CREATE TRIGGER trg_user_no_replace BEFORE INSERT ON sys_user
WHEN EXISTS (SELECT 1 FROM sys_user u WHERE u.id = NEW.id OR u.username = NEW.username)
BEGIN SELECT RAISE(ABORT, 'sys_user_duplicate'); END;


-- [跨篇 ALTER] stock_hold.approval_no → approval_request.code（表主人：02_inventory.sql；00 第 278 行）
-- PG 外键引用 uq_apr_code。SQLite 不能 ALTER 加外键，用 AFTER 触发器：CHECK 先于 AFTER，格式错误仍报 ck_hold_approval_no。
CREATE TRIGGER trg_hold_approval_fk AFTER INSERT ON stock_hold
WHEN NEW.approval_no IS NOT NULL AND NOT EXISTS (SELECT 1 FROM approval_request a WHERE a.code = NEW.approval_no)
BEGIN SELECT RAISE(ABORT, 'fk_hold_approval_no'); END;
CREATE TRIGGER trg_hold_approval_fk_upd AFTER UPDATE OF approval_no ON stock_hold
WHEN NEW.approval_no IS NOT NULL AND NOT EXISTS (SELECT 1 FROM approval_request a WHERE a.code = NEW.approval_no)
BEGIN SELECT RAISE(ABORT, 'fk_hold_approval_no'); END;

-- 授权（PG）
-- docs/12 新表 wms_app 最小授权：不给 DELETE/TRUNCATE；离线令牌只能写吊销时间；审批只能改决策相关列
-- =============================================================================
-- 加工中心（docs/17，米雪儿）：BOM / 出成率、加工单、原料领用（含 LIVE_TANK 池位）、报工产出、损耗、批次追溯、冲回
--   数量一律 *_qty_milli（00 §6.3）；出成率、容差一律万分比整数 *_bp（10000 = 100%）。
--   守恒一律按净重：base_uom=KG 的 qty_milli 即克；按件 SKU 领用时按 issue_pcs × unit_net_weight_g 换算（快照自 01 sku.std_net_weight_g，#8 新增）。
--   库存侧只调 02 原语（#2 6008032）：领用 move + place_hold(PROCESSING)；报工 consume_process_hold（成品+副产+损耗）+ post_in(PROCESS_OUTPUT)；
--   领用冲回 release_hold + move；产出冲回 post_out(PROCESS_REVERSE)。本篇不改 02 的任何表和 CHECK（ck_hold_type/ck_hold_reason/ck_hold_process 以 #2 为准）。
--   外键：本篇内部 + 指向 01/02 的现在加；指向 09 scrap_order、18 live_weigh、12 审批的等对应篇合并后再加（Doro P6）。
-- =============================================================================

CREATE TABLE process_bom (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(32)  NOT NULL,           -- BOM 编码，同编码多版本
    bom_version         INTEGER      NOT NULL,
    name                VARCHAR(128) NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',   -- DRAFT/ACTIVE/RETIRED，只能前进（trg_pbom_forward）
    yield_min_bp        INTEGER      NOT NULL,           -- 成品出成率下限（成品净重 / 原料净投入）
    yield_max_bp        INTEGER      NOT NULL,           -- 上限；越界不拦，转 PROCESS_YIELD_DEVIATION 审批
    loss_max_bp         INTEGER      NOT NULL DEFAULT 10000,  -- 损耗率上限（损耗 / 净投入）；超出同样走 PROCESS_YIELD_DEVIATION（与出成率合并一张审批单）
    balance_tol_bp      INTEGER      NOT NULL DEFAULT 50,  -- 只管称重差：完工余料 ≤ 净投入 × tol 转 WEIGH_DIFF；超出必须先领用冲回
    created_by          BIGINT       NOT NULL,
    activated_at        TIMESTAMP,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_pbom UNIQUE (warehouse_id, code, bom_version),
    CONSTRAINT fk_pbom_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT ck_pbom_status CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    CONSTRAINT ck_pbom_ver    CHECK (bom_version >= 1),
    CONSTRAINT ck_pbom_yield  CHECK (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000),
    CONSTRAINT ck_pbom_loss   CHECK (loss_max_bp >= 0 AND loss_max_bp <= 10000),
    CONSTRAINT ck_pbom_tol    CHECK (balance_tol_bp >= 0 AND balance_tol_bp <= 1000),
    CONSTRAINT ck_pbom_act    CHECK (status = 'DRAFT' OR activated_at IS NOT NULL)
);
-- 同仓同编码只能有一个 ACTIVE 版本
CREATE UNIQUE INDEX uq_pbom_active ON process_bom(warehouse_id, code) WHERE status = 'ACTIVE';
-- 状态只前进 DRAFT→ACTIVE→RETIRED（不允许 ACTIVE→DRAFT 再改行绕过 trg_pboml_frozen）；非 DRAFT 时配置列只读
CREATE TRIGGER trg_pbom_forward BEFORE UPDATE ON process_bom
WHEN NOT ((OLD.status = NEW.status) OR (OLD.status = 'DRAFT' AND NEW.status = 'ACTIVE') OR (OLD.status = 'ACTIVE' AND NEW.status = 'RETIRED'))
  OR (OLD.status <> 'DRAFT' AND (NEW.yield_min_bp IS NOT OLD.yield_min_bp OR NEW.yield_max_bp IS NOT OLD.yield_max_bp
       OR NEW.loss_max_bp IS NOT OLD.loss_max_bp OR NEW.balance_tol_bp IS NOT OLD.balance_tol_bp OR NEW.code IS NOT OLD.code
       OR NEW.bom_version IS NOT OLD.bom_version OR NEW.warehouse_id IS NOT OLD.warehouse_id))
BEGIN SELECT RAISE(ABORT, 'bom_forward_only'); END;

CREATE TABLE process_bom_line (
    id                  BIGINT       PRIMARY KEY,
    bom_id              BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    line_role           VARCHAR(16)  NOT NULL,           -- INPUT 原料 / FINISHED 成品 / BYPRODUCT 副产品
    sku_id              BIGINT       NOT NULL,
    std_qty_milli       BIGINT       NOT NULL,           -- 每批标准量（按 base_uom 的 1/1000）
    CONSTRAINT uq_pboml UNIQUE (bom_id, line_no),
    CONSTRAINT uq_pboml_sku UNIQUE (bom_id, line_role, sku_id),
    CONSTRAINT fk_pboml_bom FOREIGN KEY (bom_id) REFERENCES process_bom(id),
    CONSTRAINT fk_pboml_sku FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT ck_pboml_role CHECK (line_role IN ('INPUT','FINISHED','BYPRODUCT')),
    CONSTRAINT ck_pboml_qty  CHECK (std_qty_milli > 0 AND std_qty_milli = CAST(std_qty_milli AS BIGINT) AND line_no >= 1)
);
-- BOM 生效后只读：改配方 = 新版本（加工单下达时另有快照，双保险）
CREATE TRIGGER trg_pboml_frozen_i BEFORE INSERT ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = NEW.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
CREATE TRIGGER trg_pboml_frozen_u BEFORE UPDATE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id IN (OLD.bom_id, NEW.bom_id) AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
CREATE TRIGGER trg_pboml_frozen_d BEFORE DELETE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = OLD.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;

-- 加工单。守恒（Doro 拍板 Q-a/Q-c/C1–C5）：
--   净投入 net_in   = issued − reversed − reworked（返工回台的成品不算新原料）
--   已消耗 consumed = output + byproduct + loss + scrapped + reworked      （ck_prc_consume，任何时刻成立）
--   余料   residual = issued − reversed − consumed ≥ 0                     （ck_prc_cap；= 该单 PROCESSING 冻结余量之和，日终核对）
--   完工/待审批：residual = 0                                               （ck_prc_balance；≤ tol 的余料已转 WEIGH_DIFF 并 consume）
--   出成率 = output × 10000 / net_in（output 已扣除报废冲回）；越界判定用交叉相乘，不用取整值
CREATE TABLE process_order (
    id                      BIGINT       PRIMARY KEY,
    warehouse_id            BIGINT       NOT NULL,
    code                    VARCHAR(48)  NOT NULL,       -- PRC-{仓}-{节点}-{作业日}-{序号}（00 §6.2）
    work_date               DATE         NOT NULL,
    bom_id                  BIGINT       NOT NULL,
    process_location_id     BIGINT       NOT NULL,       -- 加工中心库位（location_type=PROCESS，#8 待加）
    planned_input_qty_milli BIGINT       NOT NULL,
    status                  VARCHAR(20)  NOT NULL DEFAULT 'CREATED',  -- CREATED/RELEASED/IN_PROGRESS/PENDING_APPROVAL/COMPLETED/CANCELLED（trg_prc_flow 白名单）
    bom_code                VARCHAR(32),
    bom_version             INTEGER,
    bom_snapshot            TEXT,                        -- BOM 行 JSON
    yield_min_bp            INTEGER,
    yield_max_bp            INTEGER,
    loss_max_bp             INTEGER,
    balance_tol_bp          INTEGER,
    issued_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 累计领用（含返工回台）
    reversed_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 累计领用冲回
    consumed_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 累计 consume_process_hold 扣减量（只增）
    output_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 成品净额（扣除产出冲回）
    byproduct_qty_milli     BIGINT       NOT NULL DEFAULT 0,  -- 副产品净额（扣除产出冲回）
    loss_qty_milli          BIGINT       NOT NULL DEFAULT 0,  -- 损耗（含 WEIGH_DIFF）；损耗冲回只改原因/拆分，合计不变
    scrapped_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 产出冲回报废（post_out PROCESS_REVERSE）累计，只增
    reworked_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 产出冲回返工回台（需主管 approval_no）累计，只增
    yield_bp                INTEGER,                      -- 完工时 = output * 10000 / net_in，整除（仅展示；判定用交叉相乘）
    approval_no             VARCHAR(40),                  -- PROCESS_YIELD_DEVIATION 审批单号（出成率 + 损耗合并一张）
    approval_expires_at     TIMESTAMP,                    -- 待审批过期时刻（≤ 进入 PENDING_APPROVAL + 12h，第 12 篇过期回调 → 第 10 篇异常，不自动通过）
    created_by              BIGINT       NOT NULL,
    released_at             TIMESTAMP,
    completed_at            TIMESTAMP,
    cancel_reason           VARCHAR(128),
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    updated_at              TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_prc_code UNIQUE (code),
    CONSTRAINT fk_prc_bom FOREIGN KEY (bom_id) REFERENCES process_bom(id),
    CONSTRAINT fk_prc_wh  FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT fk_prc_loc FOREIGN KEY (process_location_id) REFERENCES location(id),
    CONSTRAINT ck_prc_status CHECK (status IN ('CREATED','RELEASED','IN_PROGRESS','PENDING_APPROVAL','COMPLETED','CANCELLED')),
    CONSTRAINT ck_prc_int CHECK (
        planned_input_qty_milli = CAST(planned_input_qty_milli AS BIGINT)
        AND issued_qty_milli = CAST(issued_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
        AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)
        AND output_qty_milli = CAST(output_qty_milli AS BIGINT) AND byproduct_qty_milli = CAST(byproduct_qty_milli AS BIGINT)
        AND loss_qty_milli = CAST(loss_qty_milli AS BIGINT) AND scrapped_qty_milli = CAST(scrapped_qty_milli AS BIGINT)
        AND reworked_qty_milli = CAST(reworked_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_prc_nonneg CHECK (
        planned_input_qty_milli > 0 AND issued_qty_milli >= 0 AND reversed_qty_milli >= 0 AND consumed_qty_milli >= 0
        AND output_qty_milli >= 0 AND byproduct_qty_milli >= 0 AND loss_qty_milli >= 0
        AND scrapped_qty_milli >= 0 AND reworked_qty_milli >= 0
    ),
    CONSTRAINT ck_prc_reverse CHECK (reversed_qty_milli <= issued_qty_milli),
    -- 已消耗 = 各去向之和（C2）
    CONSTRAINT ck_prc_consume CHECK (
        consumed_qty_milli = output_qty_milli + byproduct_qty_milli + loss_qty_milli + scrapped_qty_milli + reworked_qty_milli
    ),
    -- 余料 ≥ 0：消耗不能超过净领用（超冲回交给 ck_prc_reverse 报）
    CONSTRAINT ck_prc_cap CHECK (reversed_qty_milli > issued_qty_milli
        OR consumed_qty_milli <= issued_qty_milli - reversed_qty_milli),
    CONSTRAINT ck_prc_snapshot CHECK (
        status = 'CREATED'
        OR (status = 'CANCELLED' AND released_at IS NULL)
        OR (released_at IS NOT NULL AND bom_code IS NOT NULL AND bom_version IS NOT NULL AND bom_snapshot IS NOT NULL
            AND yield_min_bp IS NOT NULL AND yield_max_bp IS NOT NULL AND loss_max_bp IS NOT NULL AND balance_tol_bp IS NOT NULL)
    ),
    CONSTRAINT ck_prc_yrange CHECK (yield_min_bp IS NULL OR (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000)),
    -- 完工（含待审批）：余料为 0，且净投入 > 0
    CONSTRAINT ck_prc_balance CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (issued_qty_milli - reversed_qty_milli - reworked_qty_milli > 0
            AND consumed_qty_milli = issued_qty_milli - reversed_qty_milli)
    ),
    CONSTRAINT ck_prc_yield CHECK (
        (status NOT IN ('PENDING_APPROVAL','COMPLETED') AND yield_bp IS NULL)
        OR (status IN ('PENDING_APPROVAL','COMPLETED') AND issued_qty_milli - reversed_qty_milli - reworked_qty_milli > 0
            AND yield_bp = output_qty_milli * 10000 / (issued_qty_milli - reversed_qty_milli - reworked_qty_milli))
    ),
    -- 偏差（出成率越界 或 损耗率超上限）⇔ 必须挂 PROCESS_YIELD_DEVIATION；交叉相乘判定，避免整除截断误判（F4）
    CONSTRAINT ck_prc_dev CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (output_qty_milli * 10000 >= yield_min_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND output_qty_milli * 10000 <= yield_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND loss_qty_milli * 10000 <= loss_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND approval_no IS NULL AND status = 'COMPLETED')
        OR ((output_qty_milli * 10000 < yield_min_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
             OR output_qty_milli * 10000 > yield_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
             OR loss_qty_milli * 10000 > loss_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli))
            AND approval_no IS NOT NULL)
    ),
    -- 待审批必须带过期时刻（Q-f：最长 12h，由第 12 篇审批过期回调触发，过期转第 10 篇异常，绝不自动通过）
    CONSTRAINT ck_prc_apr_exp CHECK (status <> 'PENDING_APPROVAL' OR approval_expires_at IS NOT NULL),
    CONSTRAINT ck_prc_done CHECK ((status = 'COMPLETED') = (completed_at IS NOT NULL)),
    -- 撤销：领用全部冲回，没有任何消耗
    CONSTRAINT ck_prc_cancel CHECK (
        status <> 'CANCELLED'
        OR (issued_qty_milli = reversed_qty_milli AND consumed_qty_milli = 0
            AND cancel_reason IS NOT NULL AND length(cancel_reason) > 0)
    ),
    -- 审批单号格式同 02 ck_hold_approval_no（APR-{仓库编码}-{yyyyMMdd}-{6 位}，真实日历日）
    CONSTRAINT ck_prc_apr CHECK (approval_no IS NULL OR (
        length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
        AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
        AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
        AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
        AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]')
        AND substr(approval_no, -15, 4) <> '0000'
        AND date(substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)) = substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)))
);
CREATE INDEX ix_prc_status ON process_order(warehouse_id, status, work_date, bom_code);
CREATE UNIQUE INDEX uq_prc_apr ON process_order(approval_no) WHERE approval_no IS NOT NULL;
-- 快照只读、终态只读、累计列只增（领用/冲回/消耗/报废/返工）
CREATE TRIGGER trg_prc_snapshot BEFORE UPDATE ON process_order
WHEN (OLD.status <> 'CREATED' AND (NEW.bom_id IS NOT OLD.bom_id OR NEW.bom_code IS NOT OLD.bom_code
       OR NEW.bom_version IS NOT OLD.bom_version OR NEW.bom_snapshot IS NOT OLD.bom_snapshot
       OR NEW.yield_min_bp IS NOT OLD.yield_min_bp OR NEW.yield_max_bp IS NOT OLD.yield_max_bp OR NEW.loss_max_bp IS NOT OLD.loss_max_bp
       OR NEW.balance_tol_bp IS NOT OLD.balance_tol_bp OR NEW.released_at IS NOT OLD.released_at))
  OR OLD.status IN ('COMPLETED','CANCELLED')
  OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
  OR NEW.issued_qty_milli < OLD.issued_qty_milli OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
  OR NEW.consumed_qty_milli < OLD.consumed_qty_milli OR NEW.scrapped_qty_milli < OLD.scrapped_qty_milli
  OR NEW.reworked_qty_milli < OLD.reworked_qty_milli
BEGIN SELECT RAISE(ABORT, 'process_order_frozen'); END;
CREATE TRIGGER trg_prc_flow BEFORE UPDATE OF status ON process_order
WHEN NOT (OLD.status = NEW.status
  OR (OLD.status = 'CREATED' AND NEW.status IN ('RELEASED','CANCELLED'))
  OR (OLD.status = 'RELEASED' AND NEW.status IN ('IN_PROGRESS','CANCELLED'))
  OR (OLD.status = 'IN_PROGRESS' AND NEW.status IN ('PENDING_APPROVAL','COMPLETED','CANCELLED'))
  OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('COMPLETED','IN_PROGRESS')))
BEGIN SELECT RAISE(ABORT, 'process_order_bad_transition'); END;
CREATE TRIGGER trg_prc_insert BEFORE INSERT ON process_order WHEN NEW.status <> 'CREATED'
BEGIN SELECT RAISE(ABORT, 'process_order_bad_transition'); END;
CREATE TRIGGER trg_prc_dup BEFORE INSERT ON process_order
WHEN EXISTS (SELECT 1 FROM process_order o WHERE o.id = NEW.id OR o.code = NEW.code)
BEGIN SELECT RAISE(ABORT, 'process_order_duplicate'); END;

-- 原料领用：一行 = 从一个来源 stock 行领一个批次。库存侧同一事务：move(src → pc) + place_hold(pc_stock, PROCESSING, PROCESS_ORDER, op_key)
-- 报工：consume_process_hold(hold_id, qty, biz=(PROCESS_CONSUME, 加工单号, 领用行号, 报工序号), op_key=PRCC:{order}:{report_seq}:{line_no}) 累加 consumed_qty_milli
CREATE TABLE process_issue (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,           -- PRCI:{process_order_id}:{issue_client_id}（PDA UUID），= stock_hold.op_key（#2 ck_hold_process）
    src_location_id     BIGINT       NOT NULL,
    src_location_type   VARCHAR(16)  NOT NULL,           -- 冗余来源库位类型；LIVE_TANK = 活鲜池（第 18 篇）；REWORK = 产出冲回返工回台
    src_stock_id        BIGINT       NOT NULL,
    pc_stock_id         BIGINT       NOT NULL,           -- 加工中心库位上的 stock 行
    hold_id             BIGINT       NOT NULL,           -- stock_hold(PROCESSING).id
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    lot_expiry_date     DATE         NOT NULL,
    issue_qty_milli     BIGINT       NOT NULL,           -- 净重（milli-KG = 克）
    issue_pcs           INTEGER,                         -- 按件 SKU：件数（S2/F3）
    unit_net_weight_g   INTEGER,                         -- 按件 SKU：领用时快照 01 sku.std_net_weight_g（为空 → 40001 拒绝领用）
    issue_count         INTEGER,                         -- 尾数：LIVE_TANK 必填（第 18 篇双计量）
    live_weigh_id       BIGINT,                          -- LIVE_TANK：18 出池称重 live_weigh(task_kind=PROCESS_ISSUE, ACCEPTED).id；FK 待 #12 合并
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- 领用冲回（release_hold + move 回来源库位；LIVE_TANK 不回池，退加工暂存位）
    consumed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- consume_process_hold 累计
    issued_by           BIGINT       NOT NULL,
    issued_at           TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_prci UNIQUE (process_order_id, line_no),
    CONSTRAINT uq_prci_op UNIQUE (op_key),
    CONSTRAINT uq_prci_hold UNIQUE (hold_id),
    CONSTRAINT fk_prci_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prci_hold  FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_prci_src   FOREIGN KEY (src_stock_id) REFERENCES stock(id),
    CONSTRAINT fk_prci_pc    FOREIGN KEY (pc_stock_id) REFERENCES stock(id),
    CONSTRAINT fk_prci_lot   FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_prci_sku   FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT ck_prci_int CHECK (issue_qty_milli = CAST(issue_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
                                  AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prci_qty CHECK (issue_qty_milli > 0 AND reversed_qty_milli >= 0 AND consumed_qty_milli >= 0 AND line_no >= 1),
    -- 冲回 + 消耗 ≤ 领用（= PROCESSING 冻结 released ≤ hold）；冲回超量 42214 detail.reason=OVER_REVERSE + {process_order_id, line_id, max_reversible_qty_milli}（00 §6.4，#2 1d907031）
    CONSTRAINT ck_prci_reverse CHECK (reversed_qty_milli + consumed_qty_milli <= issue_qty_milli),
    CONSTRAINT ck_prci_op CHECK (op_key GLOB 'PRCI:*'),
    CONSTRAINT ck_prci_live CHECK (
        (src_location_type = 'LIVE_TANK' AND issue_count IS NOT NULL AND issue_count > 0 AND live_weigh_id IS NOT NULL)
        OR (src_location_type <> 'LIVE_TANK' AND issue_count IS NULL AND live_weigh_id IS NULL)
    ),
    -- 按件换算：件数与单件净重成对出现，净重 = 件数 × 单件净重（g = milli-KG）
    CONSTRAINT ck_prci_pcs CHECK (
        (issue_pcs IS NULL AND unit_net_weight_g IS NULL)
        OR (issue_pcs IS NOT NULL AND unit_net_weight_g IS NOT NULL AND issue_pcs > 0 AND unit_net_weight_g > 0
            AND issue_qty_milli = issue_pcs * unit_net_weight_g
            AND reversed_qty_milli % unit_net_weight_g = 0 AND consumed_qty_milli % unit_net_weight_g = 0)   -- 按件只能整件冲回/消耗
    )
);
CREATE INDEX ix_prci_lot ON process_issue(lot_id);
-- 领用行关键列只读、累计列只增、不可删（S1-2）
CREATE TRIGGER trg_prci_immutable BEFORE UPDATE ON process_issue
WHEN NEW.issue_qty_milli IS NOT OLD.issue_qty_milli OR NEW.hold_id IS NOT OLD.hold_id OR NEW.lot_id IS NOT OLD.lot_id
  OR NEW.src_stock_id IS NOT OLD.src_stock_id OR NEW.pc_stock_id IS NOT OLD.pc_stock_id OR NEW.sku_id IS NOT OLD.sku_id
  OR NEW.process_order_id IS NOT OLD.process_order_id OR NEW.op_key IS NOT OLD.op_key
  OR NEW.reversed_qty_milli < OLD.reversed_qty_milli OR NEW.consumed_qty_milli < OLD.consumed_qty_milli
BEGIN SELECT RAISE(ABORT, 'process_issue_immutable'); END;
CREATE TRIGGER trg_prci_no_delete BEFORE DELETE ON process_issue BEGIN SELECT RAISE(ABORT, 'process_issue_immutable'); END;
CREATE TRIGGER trg_prci_dup BEFORE INSERT ON process_issue
WHEN EXISTS (SELECT 1 FROM process_issue i WHERE i.id = NEW.id OR i.op_key = NEW.op_key OR i.hold_id = NEW.hold_id
             OR (i.process_order_id = NEW.process_order_id AND i.line_no = NEW.line_no))
BEGIN SELECT RAISE(ABORT, 'process_issue_duplicate'); END;

-- 报工（一次提交 = 一行）：业务键 (process_order_id, report_client_id)，长期保留；只缓存成功结果（200/202）
-- key_type=PROCESS_REPORT（00 §6.4 待 Doro 登记）；被拒（4xx）不占键
CREATE TABLE process_report (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_client_id    VARCHAR(36)  NOT NULL,           -- 客户端 UUID
    request_hash        VARCHAR(64)  NOT NULL,           -- 规范化请求体 SHA-256；同键不同 hash → 40910 key_type=PROCESS_REPORT
    report_seq          INTEGER      NOT NULL,           -- 服务端分配：SELECT … FOR UPDATE process_order 后 max+1
    is_final            BOOLEAN      NOT NULL DEFAULT false,
    response_http       INTEGER      NOT NULL,
    response            TEXT         NOT NULL,
    reported_by         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_prcr_client UNIQUE (process_order_id, report_client_id),
    CONSTRAINT uq_prcr_seq UNIQUE (process_order_id, report_seq),
    CONSTRAINT fk_prcr_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT ck_prcr_client CHECK (length(report_client_id) = 36 AND substr(report_client_id, 9, 1) = '-' AND substr(report_client_id, 14, 1) = '-'
                                     AND substr(report_client_id, 19, 1) = '-' AND substr(report_client_id, 24, 1) = '-'),
    CONSTRAINT ck_prcr_hash CHECK (length(request_hash) = 64),
    CONSTRAINT ck_prcr_seq  CHECK (report_seq >= 1),
    CONSTRAINT ck_prcr_http CHECK (response_http IN (200, 202))
);

-- 产出明细：成品 / 副产品（post_in PROCESS_OUTPUT 新批次入库）/ 损耗（09 报损单 PROCESS_LOSS，只记账不扣库存——原料已随报工 consume）
CREATE TABLE process_output (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_id           BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    output_role         VARCHAR(16)  NOT NULL,           -- FINISHED/BYPRODUCT/LOSS
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT,
    to_location_id      BIGINT,
    gross_qty_milli     BIGINT       NOT NULL,
    tare_qty_milli      BIGINT       NOT NULL DEFAULT 0,
    qty_milli           BIGINT       NOT NULL,           -- 净重 = 毛重 − 皮重
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- FINISHED/BYPRODUCT：产出冲回量（报废或返工）；LOSS：改数量/改原因转出的量
    processed_at        TIMESTAMP    NOT NULL,
    expiry_date         DATE,
    sell_deadline       DATE,
    earliest_raw_expiry DATE,
    scrap_order_id      BIGINT,                          -- LOSS：09 报损单（PROCESS_LOSS）；FK 待 #4 合并
    loss_reason         VARCHAR(24),                     -- LOSS：TRIM/DRIP/WEIGH_DIFF/DEFECT
    from_output_id      BIGINT,                          -- LOSS 改原因/改数量：新行指向被转出的旧 LOSS 行（只在同单内）
    -- 损耗定案（Doro 定）：完工时越界损耗行为 PENDING_APPROVAL，其余 SETTLED。审批回调 / 12h 过期任务的**主守卫**是本行条件更新：
    --   UPDATE process_output SET loss_status = :result, … WHERE id = :loss_line_id AND loss_status = 'PENDING_APPROVAL'
    --   影响 1 行 → 同事务（REJECTED / EXPIRED 时）建第 10 篇异常单（PROCESS_LOSS，PRCL:{id}）、写 outbox wms.process.loss_settled；
    --   影响 0 行 → 已被另一方定案：读回本行 loss_status / loss_exception_no 原样返回，不建异常、不发事件。不动库存（consume_process_hold 已扣）。
    --   第 10 篇 uq_exc_pl_key 是第二道保险。
    loss_status         VARCHAR(24)  NOT NULL DEFAULT 'SETTLED',
    loss_approved_qty_milli BIGINT,                      -- 定案后获批量：APPROVED = qty；REJECTED 通常 0；EXPIRED = 0
    loss_exception_no   VARCHAR(64),                     -- REJECTED / EXPIRED_TO_EXCEPTION：第 10 篇异常单号（差额以 10 为准）
    CONSTRAINT uq_prco UNIQUE (report_id, line_no),
    CONSTRAINT fk_prco_order  FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prco_report FOREIGN KEY (report_id) REFERENCES process_report(id),
    CONSTRAINT fk_prco_sku    FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT fk_prco_lot    FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_prco_loc    FOREIGN KEY (to_location_id) REFERENCES location(id),
    CONSTRAINT fk_prco_from   FOREIGN KEY (from_output_id) REFERENCES process_output(id),
    CONSTRAINT ck_prco_role CHECK (output_role IN ('FINISHED','BYPRODUCT','LOSS')),
    CONSTRAINT ck_prco_int CHECK (gross_qty_milli = CAST(gross_qty_milli AS BIGINT) AND tare_qty_milli = CAST(tare_qty_milli AS BIGINT)
                                  AND qty_milli = CAST(qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prco_net CHECK (qty_milli > 0 AND tare_qty_milli >= 0 AND qty_milli = gross_qty_milli - tare_qty_milli),
    CONSTRAINT ck_prco_reverse CHECK (reversed_qty_milli >= 0 AND reversed_qty_milli <= qty_milli),
    CONSTRAINT ck_prco_kind CHECK (
        (output_role IN ('FINISHED','BYPRODUCT') AND lot_id IS NOT NULL AND to_location_id IS NOT NULL
             AND expiry_date IS NOT NULL AND earliest_raw_expiry IS NOT NULL AND scrap_order_id IS NULL AND loss_reason IS NULL
             AND from_output_id IS NULL)
        OR (output_role = 'LOSS' AND lot_id IS NULL AND to_location_id IS NULL AND expiry_date IS NULL AND sell_deadline IS NULL
             AND scrap_order_id IS NOT NULL AND loss_reason IN ('TRIM','DRIP','WEIGH_DIFF','DEFECT'))
    ),
    -- 损耗冲回整行转出（对应 09 报损单整张 VOIDED + 新行新单），不做部分冲回
    CONSTRAINT ck_prco_loss_status CHECK (loss_status IN ('SETTLED','PENDING_APPROVAL','APPROVED','REJECTED','EXPIRED_TO_EXCEPTION')
                                          AND (output_role = 'LOSS' OR loss_status = 'SETTLED')),
    CONSTRAINT ck_prco_loss_settle CHECK (
        (loss_status IN ('SETTLED','PENDING_APPROVAL') AND loss_approved_qty_milli IS NULL AND loss_exception_no IS NULL)
        OR (loss_status = 'APPROVED' AND loss_approved_qty_milli = qty_milli AND loss_exception_no IS NULL)
        OR (loss_status = 'REJECTED' AND loss_approved_qty_milli >= 0 AND loss_approved_qty_milli < qty_milli AND loss_exception_no IS NOT NULL)
        OR (loss_status = 'EXPIRED_TO_EXCEPTION' AND loss_approved_qty_milli = 0 AND loss_exception_no IS NOT NULL)),
    CONSTRAINT ck_prco_loss_whole CHECK (output_role <> 'LOSS' OR reversed_qty_milli IN (0, qty_milli)),
    CONSTRAINT ck_prco_expiry CHECK (expiry_date IS NULL OR expiry_date <= earliest_raw_expiry),
    CONSTRAINT ck_prco_sell   CHECK (sell_deadline IS NULL OR (expiry_date IS NOT NULL AND sell_deadline <= expiry_date))
);
CREATE INDEX ix_prco_order ON process_output(process_order_id, output_role);
CREATE UNIQUE INDEX uq_prco_lot ON process_output(lot_id) WHERE lot_id IS NOT NULL;

-- 批次追溯：成品/副产批次 ↔ 原料批次，多对多（§6.6）
CREATE TABLE process_lot_trace (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    output_id           BIGINT       NOT NULL,
    output_lot_id       BIGINT       NOT NULL,
    issue_id            BIGINT       NOT NULL,
    raw_lot_id          BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_plt UNIQUE (output_id, issue_id),
    CONSTRAINT fk_plt_order  FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_plt_output FOREIGN KEY (output_id) REFERENCES process_output(id),
    CONSTRAINT fk_plt_issue  FOREIGN KEY (issue_id) REFERENCES process_issue(id),
    CONSTRAINT fk_plt_olot   FOREIGN KEY (output_lot_id) REFERENCES lot(id),
    CONSTRAINT fk_plt_rlot   FOREIGN KEY (raw_lot_id) REFERENCES lot(id),
    CONSTRAINT ck_plt_self CHECK (output_lot_id <> raw_lot_id)
);
CREATE INDEX ix_plt_out ON process_lot_trace(output_lot_id, raw_lot_id);
CREATE INDEX ix_plt_raw ON process_lot_trace(raw_lot_id, output_lot_id);

-- 冲回记录，只追加。key_type=PROCESS_REVERSAL（00 §6.4 40910 ⑪，#2 1d907031）；op_key = PRCR:{process_order_id}:{reversal_client_id}
--   ISSUE  ：release_hold(hold_id, q, op_key) + move(pc → 来源库位 / LIVE_TANK 来源退加工暂存位)；hold_release_id + movement_ref 必填
--   OUTPUT ：disposition=SCRAP → post_out(lot_stock, q, PROCESS_REVERSE)；REWORK（approval_no = 第 12 篇审批单，类型 PROCESS_REWORK，审批人须持 process.rework.approve；Doro 已定，类型与权限由爱弥斯在 12b_auth_audit.sql 登记）→ move(lot_stock → 加工中心) + place_hold(PROCESSING) 记一条 REWORK 领用行
--   LOSS   ：只改原因/拆数量（新 LOSS 行 from_output_id 指回），不回在制、不动库存；movement_ref/hold_release_id 必为空
CREATE TABLE process_reversal (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,
    reversal_type       VARCHAR(16)  NOT NULL,           -- ISSUE/OUTPUT/LOSS
    disposition         VARCHAR(16),                     -- OUTPUT：SCRAP（默认）/ REWORK
    approval_no         VARCHAR(40),                     -- REWORK 必填：审批单号（审批类型 PROCESS_REWORK / 权限 process.rework.approve，12b 合并后补 FK）
    issue_id            BIGINT,
    output_id           BIGINT,
    qty_milli           BIGINT       NOT NULL,
    movement_ref        VARCHAR(160),                    -- 库存流水 idempotency_key（stock_movement_key.idempotency_key），对账用
    hold_release_id     BIGINT,                          -- ISSUE：stock_hold_release.id（不建 FK：02 verify 断言 TRUNCATE stock_hold_release 由触发器拦，FK 会抢先报错；改由日终对账 §9 核对）
    reason              VARCHAR(128) NOT NULL,
    operator_id         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_prcv_op UNIQUE (op_key),
    CONSTRAINT fk_prcv_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prcv_issue FOREIGN KEY (issue_id) REFERENCES process_issue(id),
    CONSTRAINT fk_prcv_out   FOREIGN KEY (output_id) REFERENCES process_output(id),
    CONSTRAINT fk_prcv_mv    FOREIGN KEY (movement_ref) REFERENCES stock_movement_key(idempotency_key),
    CONSTRAINT ck_prcv_type CHECK (
        (reversal_type = 'ISSUE' AND issue_id IS NOT NULL AND output_id IS NULL AND disposition IS NULL
             AND hold_release_id IS NOT NULL AND movement_ref IS NOT NULL)
        OR (reversal_type = 'OUTPUT' AND output_id IS NOT NULL AND issue_id IS NULL AND hold_release_id IS NULL
             AND movement_ref IS NOT NULL
             AND ((disposition = 'SCRAP' AND approval_no IS NULL) OR (disposition = 'REWORK' AND approval_no IS NOT NULL)))
        OR (reversal_type = 'LOSS' AND output_id IS NOT NULL AND issue_id IS NULL AND disposition IS NULL
             AND hold_release_id IS NULL AND movement_ref IS NULL)
    ),
    CONSTRAINT ck_prcv_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT) AND length(reason) > 0),
    CONSTRAINT ck_prcv_op CHECK (op_key GLOB 'PRCR:[0-9]*:????????-????-????-????-????????????'),
    CONSTRAINT ck_prcv_apr CHECK (approval_no IS NULL OR length(approval_no) BETWEEN 22 AND 40)
);
CREATE INDEX ix_prcv_order ON process_reversal(process_order_id, created_at);

-- 报工、追溯、冲回只追加
CREATE TRIGGER trg_prcr_no_update BEFORE UPDATE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
CREATE TRIGGER trg_prcr_no_delete BEFORE DELETE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
CREATE TRIGGER trg_plt_no_update  BEFORE UPDATE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
CREATE TRIGGER trg_plt_no_delete  BEFORE DELETE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
CREATE TRIGGER trg_prcv_no_update BEFORE UPDATE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
CREATE TRIGGER trg_prcv_no_delete BEFORE DELETE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
-- B6：SQLite 拦 INSERT OR REPLACE（隐式 DELETE+INSERT 不触发 DELETE 触发器），命中主键或业务键即 ABORT
CREATE TRIGGER trg_prcr_dup BEFORE INSERT ON process_report
WHEN EXISTS (SELECT 1 FROM process_report r WHERE r.id = NEW.id OR (r.process_order_id = NEW.process_order_id AND (r.report_client_id = NEW.report_client_id OR r.report_seq = NEW.report_seq)))
BEGIN SELECT RAISE(ABORT, 'process_report_duplicate'); END;
CREATE TRIGGER trg_prco_dup BEFORE INSERT ON process_output
WHEN EXISTS (SELECT 1 FROM process_output o WHERE o.id = NEW.id OR (o.report_id = NEW.report_id AND o.line_no = NEW.line_no) OR (NEW.lot_id IS NOT NULL AND o.lot_id = NEW.lot_id))
BEGIN SELECT RAISE(ABORT, 'process_output_duplicate'); END;
CREATE TRIGGER trg_plt_dup BEFORE INSERT ON process_lot_trace
WHEN EXISTS (SELECT 1 FROM process_lot_trace t WHERE t.id = NEW.id OR (t.output_id = NEW.output_id AND t.issue_id = NEW.issue_id))
BEGIN SELECT RAISE(ABORT, 'process_lot_trace_duplicate'); END;
CREATE TRIGGER trg_prcv_dup BEFORE INSERT ON process_reversal
WHEN EXISTS (SELECT 1 FROM process_reversal v WHERE v.id = NEW.id OR v.op_key = NEW.op_key)
BEGIN SELECT RAISE(ABORT, 'process_reversal_duplicate'); END;
-- 产出行：关键列只读，reversed_qty_milli 只增
CREATE TRIGGER trg_prco_immutable BEFORE UPDATE ON process_output
WHEN NEW.qty_milli IS NOT OLD.qty_milli OR NEW.gross_qty_milli IS NOT OLD.gross_qty_milli OR NEW.tare_qty_milli IS NOT OLD.tare_qty_milli
  OR NEW.lot_id IS NOT OLD.lot_id OR NEW.output_role IS NOT OLD.output_role OR NEW.expiry_date IS NOT OLD.expiry_date
  OR NEW.sell_deadline IS NOT OLD.sell_deadline OR NEW.sku_id IS NOT OLD.sku_id
  OR NEW.loss_reason IS NOT OLD.loss_reason OR NEW.scrap_order_id IS NOT OLD.scrap_order_id OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;
CREATE TRIGGER trg_prco_loss_settle_once BEFORE UPDATE ON process_output
WHEN (NEW.loss_status IS NOT OLD.loss_status AND NOT (OLD.loss_status = 'PENDING_APPROVAL' AND NEW.loss_status IN ('APPROVED','REJECTED','EXPIRED_TO_EXCEPTION')))
  OR (NEW.loss_status = OLD.loss_status AND (NEW.loss_approved_qty_milli IS NOT OLD.loss_approved_qty_milli OR NEW.loss_exception_no IS NOT OLD.loss_exception_no))
BEGIN SELECT RAISE(ABORT, 'process_loss_settle_once'); END;
CREATE TRIGGER trg_prco_no_delete BEFORE DELETE ON process_output BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;

-- =============================================================================
-- 18_live.sql —— docs/18 活鲜暂存（双数量：重量 *_qty_milli 走第 2 篇账；尾数 *_count 走本篇 live_count_ledger）
-- 温度一律 *_c10（0.1 ℃ 整数，与 PR #8 温区口径一致）；时间存 UTC
-- 库存只经 02 原语：锁池 place_hold(LIVE_HOLD)，复检合格 release_live_hold，锁池中死亡/失重 consume_live_hold。
-- 本篇不改 02 的 ck_hold_* / ck_recon_code（#2 已收进码表）。
-- 外键：同篇表之间、指向 01/02（warehouse/location/sku/lot/stock/stock_hold/stock_movement_key）现在加；
--       指向 05 pick_task、08 count_order、09 scrap_order、12 approval_request 的等对应篇合并后补（docs/18 §4.11）。
-- =============================================================================
-- SKU 活鲜参数（按 SKU）：称重容差、日死亡率阈值、日失重容差，单位 bp（万分之一）
CREATE TABLE sku_live_param (
    sku_id                  BIGINT   PRIMARY KEY REFERENCES sku(id),
    weigh_tolerance_bp      INT      NOT NULL DEFAULT 300,   -- PM 2：默认 3%
    death_rate_threshold_bp INT      NOT NULL DEFAULT 500,   -- PM 3：默认 5%（池日死亡率）
    shrink_tolerance_bp     INT      NOT NULL DEFAULT 100,   -- PM 7：每日失重容差；默认值待定（§13 Q3）
    version                 INT      NOT NULL DEFAULT 0,
    updated_by              BIGINT,
    updated_at              TIMESTAMP NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_slp_bp CHECK (weigh_tolerance_bp BETWEEN 0 AND 10000 AND death_rate_threshold_bp BETWEEN 0 AND 10000 AND shrink_tolerance_bp BETWEEN 0 AND 10000)
    , CONSTRAINT ck_slp_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_slp_upd BEFORE UPDATE ON sku_live_param WHEN NEW.sku_id <> OLD.sku_id BEGIN SELECT RAISE(ABORT, 'slp_immutable'); END;
CREATE TRIGGER trg_slp_del BEFORE DELETE ON sku_live_param BEGIN SELECT RAISE(ABORT, 'slp_immutable'); END;
CREATE TRIGGER trg_slp_dup BEFORE INSERT ON sku_live_param
WHEN EXISTS (SELECT 1 FROM sku_live_param x WHERE x.sku_id = NEW.sku_id)
BEGIN SELECT RAISE(ABORT, 'slp_duplicate'); END;

-- 暂养池扩展（PM 5）：库位 location_type='LIVE_TANK' 的 1:1 扩展；一池一 SKU，可多批次
CREATE TABLE live_tank (
    location_id             BIGINT   PRIMARY KEY,           -- = location.id，location_type 必须是 LIVE_TANK（trg_lt_type）
    warehouse_id            BIGINT   NOT NULL,
    sku_id                  BIGINT   NOT NULL,              -- 一池一 SKU
    water_volume_l          BIGINT   NOT NULL,              -- 水体积（升）
    temp_controlled         BOOLEAN  NOT NULL DEFAULT true,
    temp_min_c10            INT      NOT NULL,              -- 告警下限（0.1 ℃）
    temp_max_c10            INT      NOT NULL,              -- 告警上限
    temp_severe_min_c10     INT      NOT NULL,              -- 严重下限：一次即锁池
    temp_severe_max_c10     INT      NOT NULL,              -- 严重上限
    do_min_x100             INT      NOT NULL,              -- 溶解氧告警下限（mg/L ×100）
    do_severe_min_x100      INT      NOT NULL,
    ph_min_x100             INT      NOT NULL,
    ph_max_x100             INT      NOT NULL,
    inspect_interval_min    INT      NOT NULL DEFAULT 120,  -- 巡检频率（分钟）
    status                  VARCHAR(16) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE/DISABLED（锁池走 live_tank_hold，不在这里）
    version                 INT      NOT NULL DEFAULT 0,
    updated_at              TIMESTAMP NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_lt_status CHECK (status IN ('ACTIVE','DISABLED')),
    CONSTRAINT ck_lt_volume CHECK (water_volume_l > 0),
    CONSTRAINT ck_lt_temp CHECK (temp_severe_min_c10 <= temp_min_c10 AND temp_min_c10 < temp_max_c10 AND temp_max_c10 <= temp_severe_max_c10),
    CONSTRAINT ck_lt_do CHECK (do_severe_min_x100 >= 0 AND do_severe_min_x100 <= do_min_x100),
    CONSTRAINT ck_lt_ph CHECK (ph_min_x100 >= 0 AND ph_min_x100 < ph_max_x100 AND ph_max_x100 <= 1400),
    CONSTRAINT ck_lt_interval CHECK (inspect_interval_min BETWEEN 10 AND 1440),
    CONSTRAINT fk_lt_location FOREIGN KEY (location_id) REFERENCES location(id),
    CONSTRAINT fk_lt_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT fk_lt_sku FOREIGN KEY (sku_id) REFERENCES sku(id)
    , CONSTRAINT ck_lt_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lt_upd BEFORE UPDATE ON live_tank WHEN NEW.location_id <> OLD.location_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.sku_id <> OLD.sku_id BEGIN SELECT RAISE(ABORT, 'lt_immutable'); END;
CREATE TRIGGER trg_lt_del BEFORE DELETE ON live_tank BEGIN SELECT RAISE(ABORT, 'lt_immutable'); END;
CREATE TRIGGER trg_lt_type BEFORE INSERT ON live_tank WHEN NOT EXISTS (SELECT 1 FROM location l WHERE l.id = NEW.location_id AND l.location_type = 'LIVE_TANK' AND l.warehouse_id = NEW.warehouse_id) BEGIN SELECT RAISE(ABORT, 'lt_not_live_tank'); END;
CREATE TRIGGER trg_lt_dup BEFORE INSERT ON live_tank
WHEN EXISTS (SELECT 1 FROM live_tank x WHERE x.location_id = NEW.location_id)
BEGIN SELECT RAISE(ABORT, 'lt_duplicate'); END;

-- 尾数余额（PM 1）：与 stock 行 1:1；重量仍在 stock.on_hand_qty_milli（第 2 篇），这里只存只数
-- count > 0 ⇒ 对应 stock 重量 > 0（触发器；第 2 篇改重量时由巡检 LIVE_COUNT_WEIGHT 兜底）
CREATE TABLE live_stock_count (
    stock_id        BIGINT   PRIMARY KEY,
    location_id     BIGINT   NOT NULL,
    lot_id          BIGINT   NOT NULL,
    on_hand_count   BIGINT   NOT NULL DEFAULT 0,
    version         INT      NOT NULL DEFAULT 0,
    updated_at      TIMESTAMP NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_lsc_count CHECK (on_hand_count >= 0),
    CONSTRAINT fk_lsc_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_lsc_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lsc_lot FOREIGN KEY (lot_id) REFERENCES lot(id)
    , CONSTRAINT ck_lsc_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lsc_upd BEFORE UPDATE ON live_stock_count WHEN NEW.stock_id <> OLD.stock_id OR NEW.location_id <> OLD.location_id OR NEW.lot_id <> OLD.lot_id BEGIN SELECT RAISE(ABORT, 'lsc_immutable'); END;
CREATE TRIGGER trg_lsc_del BEFORE DELETE ON live_stock_count BEGIN SELECT RAISE(ABORT, 'lsc_immutable'); END;
CREATE TRIGGER trg_lsc_dup BEFORE INSERT ON live_stock_count WHEN EXISTS (SELECT 1 FROM live_stock_count x WHERE x.stock_id = NEW.stock_id) BEGIN SELECT RAISE(ABORT, 'lsc_duplicate'); END;
CREATE TRIGGER trg_lsc_w_ins BEFORE INSERT ON live_stock_count WHEN NEW.on_hand_count > 0 AND COALESCE((SELECT on_hand_qty_milli FROM stock WHERE id = NEW.stock_id), 0) <= 0 BEGIN SELECT RAISE(ABORT, 'live_count_without_weight'); END;
CREATE TRIGGER trg_lsc_w_upd BEFORE UPDATE ON live_stock_count WHEN NEW.on_hand_count > 0 AND COALESCE((SELECT on_hand_qty_milli FROM stock WHERE id = NEW.stock_id), 0) <= 0 BEGIN SELECT RAISE(ABORT, 'live_count_without_weight'); END;

-- 尾数流水（只追加）：每笔只数变动一行，与第 2 篇重量流水 stock_movement 同事务、同 biz 键
CREATE TABLE live_count_ledger (
    id              BIGINT       PRIMARY KEY,
    stock_id        BIGINT       NOT NULL,
    biz_type        VARCHAR(16)  NOT NULL,   -- RECEIVE/WEIGH_OUT/DEATH/COUNT_ADJ/MOVE_IN/MOVE_OUT/PROCESS_OUT
    biz_no          VARCHAR(64)  NOT NULL,
    line_no         INT          NOT NULL DEFAULT 1,
    delta_count     BIGINT       NOT NULL,
    count_before    BIGINT       NOT NULL,
    count_after     BIGINT       NOT NULL,
    movement_id     BIGINT,                  -- 对应重量流水（第 2 篇 stock_movement_key.movement_id）；纯只数盘点调整可空
    created_at      TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_lcl_biz UNIQUE (biz_type, biz_no, line_no, stock_id),
    CONSTRAINT ck_lcl_type CHECK (biz_type IN ('RECEIVE','WEIGH_OUT','DEATH','COUNT_ADJ','MOVE_IN','MOVE_OUT','PROCESS_OUT')),
    CONSTRAINT ck_lcl_math CHECK (delta_count <> 0 AND count_before >= 0 AND count_after >= 0 AND count_after = count_before + delta_count),
    CONSTRAINT fk_lcl_count FOREIGN KEY (stock_id) REFERENCES live_stock_count(stock_id),
    CONSTRAINT fk_lcl_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id)   -- stock_movement 是分区表，主键含 occurred_at，挂在 1:1 的 key 表上
    , CONSTRAINT ck_lcl_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lcl_upd BEFORE UPDATE ON live_count_ledger BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lcl_del BEFORE DELETE ON live_count_ledger BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lcl_dup BEFORE INSERT ON live_count_ledger
WHEN EXISTS (SELECT 1 FROM live_count_ledger x WHERE x.id = NEW.id OR (x.biz_type = NEW.biz_type AND x.biz_no = NEW.biz_no AND x.line_no = NEW.line_no AND x.stock_id = NEW.stock_id))
BEGIN SELECT RAISE(ABORT, 'lcl_duplicate'); END;

-- 巡检记录（PM 4，只追加）：PDA 离线可录，键 (device_instance_id, client_op_id)
CREATE TABLE live_inspection (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    location_id         BIGINT       NOT NULL,
    device_instance_id  VARCHAR(64)  NOT NULL,
    client_op_id        VARCHAR(64)  NOT NULL,
    inspector_id        BIGINT       NOT NULL,
    inspected_at        TIMESTAMP    NOT NULL,    -- 现场时间（UTC）
    client_occurred_at  TIMESTAMP,   -- 00 §6.8 第 7 条：设备上报的原始时间（UTC），只用于展示，任何逻辑不得使用；inspected_at 由库写
    temp_c10            INT          NOT NULL,
    do_x100             INT          NOT NULL,
    ph_x100             INT          NOT NULL,
    result              VARCHAR(8)   NOT NULL,    -- NORMAL/ALARM/SEVERE（服务端按 live_tank 阈值判定，不信客户端）
    consecutive_breach  INT          NOT NULL DEFAULT 0,  -- 含本次的连续超标次数（NORMAL 为 0）
    is_recheck          BOOLEAN      NOT NULL DEFAULT false,  -- 锁池后的复检
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_li_op UNIQUE (device_instance_id, client_op_id),
    CONSTRAINT ck_li_result CHECK (result IN ('NORMAL','ALARM','SEVERE')),
    CONSTRAINT ck_li_breach CHECK ((result = 'NORMAL' AND consecutive_breach = 0) OR (result <> 'NORMAL' AND consecutive_breach >= 1)),
    CONSTRAINT ck_li_range CHECK (do_x100 >= 0 AND ph_x100 BETWEEN 0 AND 1400),
    CONSTRAINT fk_li_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_li_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse(id)
    , CONSTRAINT ck_li_ts CHECK ((typeof(inspected_at) = 'text' AND length(inspected_at) = 19 AND inspected_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(inspected_at) = substr(inspected_at, 1, 10) AND time(inspected_at) = substr(inspected_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
    , CONSTRAINT ck_li_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE INDEX ix_li_tank ON live_inspection(location_id, inspected_at);
CREATE TRIGGER trg_li_upd BEFORE UPDATE ON live_inspection BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_li_del BEFORE DELETE ON live_inspection BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_li_dup BEFORE INSERT ON live_inspection
WHEN EXISTS (SELECT 1 FROM live_inspection x WHERE x.id = NEW.id OR (x.device_instance_id = NEW.device_instance_id AND x.client_op_id = NEW.client_op_id))
BEGIN SELECT RAISE(ABORT, 'li_duplicate'); END;

-- 池级锁（PM 4）：2 次连续超标或 1 次严重 → ACTIVE；复检合格 → RELEASED（系统释放）。
-- 同一池同时至多一条 ACTIVE；状态单向；锁池时对池内每个 stock 行 place_hold 一条第 2 篇
-- stock_hold(hold_type=LIVE_HOLD, source_type=LIVE_TANK_HOLD, source_id=本表 id)；释放走 release_live_hold(本表 id, release_inspection_id, op_key, release_ids[])（02 §7.1.7）
CREATE TABLE live_tank_hold (
    id                      BIGINT       PRIMARY KEY,
    warehouse_id            BIGINT       NOT NULL,
    location_id             BIGINT       NOT NULL,
    reason                  VARCHAR(24)  NOT NULL,    -- CONSECUTIVE_BREACH/SEVERE
    trigger_inspection_id   BIGINT       NOT NULL,
    status                  VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE/RELEASED
    release_inspection_id   BIGINT,
    released_at             TIMESTAMP,
    created_at              TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_lth_reason CHECK (reason IN ('CONSECUTIVE_BREACH','SEVERE')),
    CONSTRAINT ck_lth_status CHECK (status IN ('ACTIVE','RELEASED')),
    CONSTRAINT ck_lth_release CHECK ((status = 'ACTIVE' AND release_inspection_id IS NULL AND released_at IS NULL)
                                  OR (status = 'RELEASED' AND release_inspection_id IS NOT NULL AND released_at IS NOT NULL)),
    CONSTRAINT fk_lth_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lth_trigger FOREIGN KEY (trigger_inspection_id) REFERENCES live_inspection(id),
    CONSTRAINT fk_lth_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- 03 R3：补外键（小玛丽 r12）
    CONSTRAINT fk_lth_release FOREIGN KEY (release_inspection_id) REFERENCES live_inspection(id)
    , CONSTRAINT ck_lth_ts CHECK ((released_at IS NULL OR (typeof(released_at) = 'text' AND length(released_at) = 19 AND released_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(released_at) = substr(released_at, 1, 10) AND time(released_at) = substr(released_at, 12, 8))) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE UNIQUE INDEX uq_lth_active ON live_tank_hold(location_id) WHERE status = 'ACTIVE';
CREATE TRIGGER trg_lth_ins BEFORE INSERT ON live_tank_hold WHEN NEW.status <> 'ACTIVE' BEGIN SELECT RAISE(ABORT, 'lth_state'); END;
CREATE TRIGGER trg_lth_closed BEFORE UPDATE ON live_tank_hold WHEN OLD.status <> 'ACTIVE' BEGIN SELECT RAISE(ABORT, 'lth_closed'); END;
CREATE TRIGGER trg_lth_upd BEFORE UPDATE ON live_tank_hold WHEN OLD.status = 'ACTIVE' AND (NEW.location_id <> OLD.location_id OR NEW.reason <> OLD.reason OR NEW.trigger_inspection_id <> OLD.trigger_inspection_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.created_at <> OLD.created_at) BEGIN SELECT RAISE(ABORT, 'lth_immutable'); END;
CREATE TRIGGER trg_lth_rel BEFORE UPDATE OF status ON live_tank_hold WHEN OLD.status = 'ACTIVE' AND NEW.status = 'RELEASED' AND NOT EXISTS (SELECT 1 FROM live_inspection i WHERE i.id = NEW.release_inspection_id AND i.location_id = NEW.location_id AND i.is_recheck AND i.result = 'NORMAL') BEGIN SELECT RAISE(ABORT, 'lth_recheck_required'); END;
CREATE TRIGGER trg_lth_del BEFORE DELETE ON live_tank_hold BEGIN SELECT RAISE(ABORT, 'lth_immutable'); END;
CREATE TRIGGER trg_lth_dup BEFORE INSERT ON live_tank_hold WHEN EXISTS (SELECT 1 FROM live_tank_hold x WHERE x.id = NEW.id OR (x.location_id = NEW.location_id AND x.status = 'ACTIVE')) BEGIN SELECT RAISE(ABORT, 'lth_duplicate'); END;

-- 出池称重（PM 1/2，只追加）。task_kind 区分拣货任务（05 pick_task）与加工领用（17 领料行），B3/P4。
-- 幂等键 (task_kind, task_id, weigh_client_id) 只约束 ACCEPTED（部分唯一索引，B5/P3）：
-- REJECTED（42217）照样留痕，但不占键，同一键重试会重新执行（00 §6.5：422 不缓存）。
-- 超容差 → result=REJECTED, result_code='42217'，不入账；ACCEPTED 才扣重量（实际净重）和只数（实际只数）
CREATE TABLE live_weigh (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    task_kind           VARCHAR(16)  NOT NULL,       -- PICK（05 pick_task.id）/ PROCESS_ISSUE（17 领料行 id）
    task_id             BIGINT       NOT NULL,       -- 多态引用，FK 等 05/17 合并后按 task_kind 用触发器补（§4.11）
    line_no             INT          NOT NULL,
    weigh_client_id     VARCHAR(64)  NOT NULL,       -- 客户端每次称重生成（UUID）
    device_instance_id  VARCHAR(64)  NOT NULL,
    scale_id            VARCHAR(64),                 -- 蓝牙秤/台秤编号；手输为空
    reading_source      VARCHAR(8)   NOT NULL,       -- SCALE/MANUAL
    location_id         BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    gross_qty_milli     BIGINT       NOT NULL,
    tare_qty_milli      BIGINT       NOT NULL,
    net_qty_milli       BIGINT       NOT NULL,
    qty_count           BIGINT       NOT NULL,
    planned_qty_milli   BIGINT       NOT NULL,
    deviation_bp        INT          NOT NULL,       -- |net − planned| / planned × 10000（向上取整）
    result              VARCHAR(8)   NOT NULL,       -- ACCEPTED/REJECTED
    result_code         CHAR(5),
    movement_id         BIGINT,                      -- ACCEPTED 的重量流水
    weighed_by          BIGINT       NOT NULL,
    weighed_at          TIMESTAMP    NOT NULL,       -- UTC
    client_occurred_at  TIMESTAMP,   -- 00 §6.8 第 7 条：设备上报的原始时间（UTC），只用于展示，任何逻辑不得使用；weighed_at 由库写
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT ck_lw_kind CHECK (task_kind IN ('PICK','PROCESS_ISSUE')),
    CONSTRAINT ck_lw_src CHECK (reading_source IN ('SCALE','MANUAL') AND (reading_source = 'MANUAL' OR scale_id IS NOT NULL)),
    CONSTRAINT ck_lw_qty CHECK (gross_qty_milli >= 0 AND tare_qty_milli >= 0 AND net_qty_milli >= 0 AND qty_count >= 0
                                AND net_qty_milli = gross_qty_milli - tare_qty_milli AND planned_qty_milli > 0 AND deviation_bp >= 0),
    CONSTRAINT ck_lw_dual CHECK (qty_count = 0 OR net_qty_milli > 0),
    CONSTRAINT ck_lw_result CHECK ((result = 'ACCEPTED' AND result_code IS NULL AND movement_id IS NOT NULL)
                                OR (result = 'REJECTED' AND result_code = '42217' AND movement_id IS NULL)),
    CONSTRAINT fk_lw_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lw_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_lw_sku FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT fk_lw_lot FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_lw_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- 03 R3：补外键（小玛丽 r12）
    CONSTRAINT fk_lw_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id)
    , CONSTRAINT ck_lw_ts CHECK ((typeof(weighed_at) = 'text' AND length(weighed_at) = 19 AND weighed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(weighed_at) = substr(weighed_at, 1, 10) AND time(weighed_at) = substr(weighed_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
    , CONSTRAINT ck_lw_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE UNIQUE INDEX uq_lw_key ON live_weigh(task_kind, task_id, weigh_client_id) WHERE result = 'ACCEPTED';
CREATE TRIGGER trg_lw_upd BEFORE UPDATE ON live_weigh BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lw_del BEFORE DELETE ON live_weigh BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lw_dup BEFORE INSERT ON live_weigh
WHEN EXISTS (SELECT 1 FROM live_weigh x WHERE x.id = NEW.id OR (NEW.result = 'ACCEPTED' AND x.result = 'ACCEPTED' AND x.task_kind = NEW.task_kind AND x.task_id = NEW.task_id AND x.weigh_client_id = NEW.weigh_client_id))
BEGIN SELECT RAISE(ABORT, 'lw_duplicate'); END;

-- 死亡登记（PM 3，只追加）：库存在本篇直接扣（B2/P1），第 9 篇报损单只记账（不再 post_out）。
-- 未锁池：post_out(SCRAP)，流水 hold_id 为空；锁池中：consume_live_hold(hold_id, qty, 'LIVE_DEATH', live_death.id, op_key)，扣的那条 LIVE_HOLD 记在 02 stock_movement.hold_id（#2 四轮），本表不再存 hold_id。
-- movement_id = 本次唯一一条 −1 流水；uq_ld_mv 保证一条流水只挂一次死亡，防重复扣减。
-- 当日该池死亡率超 SKU 阈值时必须带 LIVE_DEATH_OVER 审批单号，否则接口返回 40938（应用层判定，库层只校验格式）
CREATE TABLE live_death (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    location_id         BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    work_date           DATE         NOT NULL,
    device_instance_id  VARCHAR(64)  NOT NULL,
    client_op_id        VARCHAR(64)  NOT NULL,
    death_count         BIGINT       NOT NULL,
    death_qty_milli     BIGINT       NOT NULL,
    day_rate_bp         INT          NOT NULL,       -- 含本次的池当日死亡率（只数口径）
    approval_no         VARCHAR(64),                 -- 超阈值时必填，APR-{仓库编码}-{yyyyMMdd}-{6 位}；FK 到 12 approval_request.code 等 #9 合并
    movement_id         BIGINT,                      -- 本篇扣重量写的那条 SCRAP −1 流水；PENDING 为空，补扣后回填；EXCEPTION 部分扣时回填、零扣为空
    deduct_status       VARCHAR(16)  NOT NULL DEFAULT 'DEDUCTED',  -- PENDING（先落、扣减延后）/ DEDUCTED / EXCEPTION（补扣时在库不足，差额转 10 异常单）
    deducted_qty_milli  BIGINT       NOT NULL DEFAULT 0,  -- 已扣重量（milli）；= 挂的那条 −1 流水量
    exception_key       VARCHAR(64),                 -- EXCEPTION 时 10 异常单来源键（source_type=LIVE_DEATH），格式 LDTH:{live_death.id}（正整数、无前导零），异常单须带 SKU
    scrap_order_id      BIGINT,                      -- 09 报损单（只记账）；FK 等 #4 合并
    reported_by         BIGINT       NOT NULL,
    reported_at         TIMESTAMP    NOT NULL,
    client_occurred_at  TIMESTAMP,   -- 00 §6.8 第 7 条：设备上报的原始时间（UTC），只用于展示，任何逻辑不得使用；reported_at 由库写
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_ld_op UNIQUE (device_instance_id, client_op_id),
    CONSTRAINT ck_ld_date CHECK (typeof(work_date) = 'text' AND length(work_date) = 10 AND date(work_date) IS work_date),
    CONSTRAINT uq_ld_mv UNIQUE (movement_id),
    CONSTRAINT ck_ld_deduct CHECK (deducted_qty_milli >= 0 AND deducted_qty_milli <= death_qty_milli AND (
           (deduct_status = 'PENDING'   AND deducted_qty_milli = 0 AND movement_id IS NULL AND exception_key IS NULL)
        OR (deduct_status = 'DEDUCTED'  AND deducted_qty_milli = death_qty_milli AND movement_id IS NOT NULL AND exception_key IS NULL)
        OR (deduct_status = 'EXCEPTION' AND deducted_qty_milli < death_qty_milli
            AND ((deducted_qty_milli > 0 AND movement_id IS NOT NULL) OR (deducted_qty_milli = 0 AND movement_id IS NULL))
            AND exception_key IS NOT NULL AND exception_key = 'LDTH:' || CAST(id AS VARCHAR(20))))),
    CONSTRAINT ck_ld_qty CHECK (death_count > 0 AND death_qty_milli > 0 AND day_rate_bp BETWEEN 0 AND 10000),
    CONSTRAINT ck_ld_apr CHECK (approval_no IS NULL OR (approval_no LIKE 'APR-%' AND length(approval_no) BETWEEN 22 AND 36)),
    CONSTRAINT fk_ld_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_ld_stock FOREIGN KEY (stock_id) REFERENCES live_stock_count(stock_id),
    CONSTRAINT fk_ld_lot FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_ld_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- 03 R3：补外键（小玛丽 r12）
    CONSTRAINT fk_ld_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id)
    , CONSTRAINT ck_ld_ts CHECK ((typeof(reported_at) = 'text' AND length(reported_at) = 19 AND reported_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(reported_at) = substr(reported_at, 1, 10) AND time(reported_at) = substr(reported_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
    , CONSTRAINT ck_ld_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE INDEX ix_ld_tank_day ON live_death(location_id, work_date);   -- 日死亡率
CREATE INDEX ix_ld_pending ON live_death(deduct_status) WHERE deduct_status <> 'DEDUCTED';   -- 补扣作业 / 在途对账
-- 只追加，唯一例外：写节点恢复后补扣，PENDING → DEDUCTED / EXCEPTION，只改 deduct_status、movement_id、deducted_qty_milli、exception_key
CREATE TRIGGER trg_ld_upd BEFORE UPDATE ON live_death WHEN NOT (OLD.deduct_status = 'PENDING' AND NEW.deduct_status IN ('DEDUCTED', 'EXCEPTION') AND NEW.id IS OLD.id AND NEW.warehouse_id IS OLD.warehouse_id AND NEW.location_id IS OLD.location_id AND NEW.stock_id IS OLD.stock_id AND NEW.lot_id IS OLD.lot_id AND NEW.work_date IS OLD.work_date AND NEW.device_instance_id IS OLD.device_instance_id AND NEW.client_op_id IS OLD.client_op_id AND NEW.death_count IS OLD.death_count AND NEW.death_qty_milli IS OLD.death_qty_milli AND NEW.day_rate_bp IS OLD.day_rate_bp AND NEW.approval_no IS OLD.approval_no AND NEW.scrap_order_id IS OLD.scrap_order_id AND NEW.reported_by IS OLD.reported_by AND NEW.reported_at IS OLD.reported_at AND NEW.created_at IS OLD.created_at) BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_ld_del BEFORE DELETE ON live_death BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_ld_dup BEFORE INSERT ON live_death
WHEN EXISTS (SELECT 1 FROM live_death x WHERE x.id = NEW.id OR (x.device_instance_id = NEW.device_instance_id AND x.client_op_id = NEW.client_op_id) OR x.movement_id = NEW.movement_id)
BEGIN SELECT RAISE(ABORT, 'ld_duplicate'); END;

-- 日失重结算（PM 7，只追加，权威库日终作业）：键 (location_id, lot_id, work_date)，重跑撞键 → 40910 key_type=LIVE_SHRINK
-- LOSS：本篇扣重量（未锁池 post_out(SCRAP)，锁池中 consume_live_hold(hold_id, …, 'LIVE_SHRINK', 本表 id, op_key)），
--       09 LIVE_SHRINK 损耗单只记账；VARIANCE：不扣，挂 08 盘点单；NONE：不扣
CREATE TABLE live_shrink_settlement (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    location_id         BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,
    work_date           DATE         NOT NULL,
    book_qty_milli      BIGINT       NOT NULL,       -- 结算前账面重量
    measured_qty_milli  BIGINT       NOT NULL,       -- 抽称推算重量
    shrink_qty_milli    BIGINT       NOT NULL,       -- = book − measured（只计重量，不动只数）
    shrink_bp           INT          NOT NULL,
    tolerance_bp        INT          NOT NULL,       -- 结算时的 SKU shrink_tolerance_bp 快照
    outcome             VARCHAR(16)  NOT NULL,       -- LOSS/VARIANCE/NONE
    movement_id         BIGINT,                      -- LOSS：本篇写的 SCRAP −1 流水
    scrap_order_id      BIGINT,                      -- 09（只记账），FK 等 #4
    count_order_id      BIGINT,                      -- 08，FK 等 08 新稿
    created_at          TIMESTAMP    NOT NULL DEFAULT (datetime('now')),
    CONSTRAINT uq_lss_day UNIQUE (location_id, lot_id, work_date),
    CONSTRAINT uq_lss_mv UNIQUE (movement_id),
    CONSTRAINT ck_lss_qty CHECK (book_qty_milli >= 0 AND measured_qty_milli >= 0 AND shrink_qty_milli = book_qty_milli - measured_qty_milli AND shrink_bp >= 0 AND tolerance_bp BETWEEN 0 AND 10000),
    CONSTRAINT ck_lss_outcome CHECK ((outcome = 'NONE' AND shrink_qty_milli <= 0 AND scrap_order_id IS NULL AND count_order_id IS NULL AND movement_id IS NULL)
                                  OR (outcome = 'LOSS' AND shrink_qty_milli > 0 AND shrink_bp <= tolerance_bp AND scrap_order_id IS NOT NULL AND count_order_id IS NULL AND movement_id IS NOT NULL)
                                  OR (outcome = 'VARIANCE' AND shrink_qty_milli > 0 AND shrink_bp > tolerance_bp AND count_order_id IS NOT NULL AND scrap_order_id IS NULL AND movement_id IS NULL)),
    CONSTRAINT fk_lss_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lss_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_lss_lot FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_lss_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- 03 R3：补外键（小玛丽 r12）
    CONSTRAINT fk_lss_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id)
    , CONSTRAINT ck_lss_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lss_upd BEFORE UPDATE ON live_shrink_settlement BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lss_del BEFORE DELETE ON live_shrink_settlement BEGIN SELECT RAISE(ABORT, 'append_only'); END;
CREATE TRIGGER trg_lss_dup BEFORE INSERT ON live_shrink_settlement
WHEN EXISTS (SELECT 1 FROM live_shrink_settlement x WHERE x.id = NEW.id OR (x.location_id = NEW.location_id AND x.lot_id = NEW.lot_id AND x.work_date = NEW.work_date) OR x.movement_id = NEW.movement_id)
BEGIN SELECT RAISE(ABORT, 'lss_duplicate'); END;

-- 时间约定（00 §6.8，小玛丽 time-scan 18-1）：巡检 / 称重 / 死亡上报 / 释放时间是服务端时间。PG 非属主写入一律改成库时钟 UTC 整秒（属主豁免：种子 / 迁移）；
-- SQLite 不能改 NEW，只收 now ±300s（strftime 为 NULL 也算 live_clock_skew）。触发器名带 z：排在本篇业务守卫之后
CREATE TRIGGER trg_li_zclock BEFORE INSERT ON live_inspection WHEN (strftime('%s', NEW.inspected_at) IS NULL OR substr(NEW.inspected_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.inspected_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID inspected_at'); END;
CREATE TRIGGER trg_lw_zclock BEFORE INSERT ON live_weigh WHEN (strftime('%s', NEW.weighed_at) IS NULL OR substr(NEW.weighed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.weighed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID weighed_at'); END;
CREATE TRIGGER trg_ld_zclock BEFORE INSERT ON live_death WHEN (strftime('%s', NEW.reported_at) IS NULL OR substr(NEW.reported_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.reported_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID reported_at'); END;
CREATE TRIGGER trg_lth_zclock BEFORE UPDATE ON live_tank_hold WHEN NEW.released_at IS NOT NULL AND OLD.released_at IS NULL AND (strftime('%s', NEW.released_at) IS NULL OR substr(NEW.released_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.released_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID released_at'); END;
CREATE TRIGGER trg_lth_zclock_ins BEFORE INSERT ON live_tank_hold WHEN NEW.released_at IS NOT NULL AND (strftime('%s', NEW.released_at) IS NULL OR substr(NEW.released_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.released_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID released_at'); END;
-- 对账在途差异（Doro 定）：PENDING = 未扣，全量在途；EXCEPTION = 部分/零扣，差额挂 10 异常单，异常单关单前都算差异，不算对平
CREATE VIEW v_live_death_in_transit AS
SELECT d.id AS live_death_id, d.warehouse_id, d.location_id, d.stock_id, d.lot_id, d.work_date, d.deduct_status,
       d.death_qty_milli, d.deducted_qty_milli,
       d.death_qty_milli - d.deducted_qty_milli AS diff_qty_milli,          -- PENDING：在途；EXCEPTION：= 异常单数量（关单前不算对平）
       d.exception_key,
       (SELECT m.hold_id FROM stock_movement m WHERE m.id = d.movement_id) AS hold_id,   -- 锁池中扣的 LIVE_HOLD，经流水取（02 四轮 stock_movement.hold_id）
       COALESCE((SELECT m.move_qty_milli FROM stock_movement m WHERE m.id = d.movement_id), 0) AS movement_qty_milli  -- 对账：必须 = deducted_qty_milli
FROM live_death d
WHERE d.deduct_status IN ('PENDING', 'EXCEPTION');
-- 补扣参考实现（§7.2 / §8，PG）：写节点恢复后每条 PENDING 一个事务调一次。
-- 锁序 live_death 行 → stock 行 → stock_hold 明细；锁到 live_death 后先复查 PENDING，不是就返回 EXISTING:{状态}，不碰库存、不开异常单。
-- 锁池中（有 HELD 的 LIVE_HOLD）走 consume_live_hold 写法，流水挂 hold_id；未锁池走 post_out(SCRAP) 写法，流水 hold_id 为空。
-- 02 五轮口径：同一 idempotency_key（LD-{id}:1:D1:1）已有流水就直接返回 EXISTING_MOVEMENT:{状态}，不再进库存。
-- 返回 WON:{已扣}:{差额}:{sku_id}；差额 > 0 时调用方在同事务按 10 篇开异常单（source_type=LIVE_DEATH，键 LDTH:{id}，sku_id = 返回的 sku）。
-- 最后的条件 UPDATE 是第二道保险：0 行即 RAISE，整笔回滚。SQLite 单写者，应用层同序执行，不建本函数。
-- X1/X2：no-replace 触发器（WHEN 覆盖本表全部 PK / UNIQUE，部分索引带谓词；由 genreplace 生成）

-- 去重键不可改、计数器只增（由 genlock 生成；PG 触发器名 trg_0keylock_* 让它按字母序最先执行）
CREATE TRIGGER trg_sku_live_param_keylock BEFORE UPDATE ON sku_live_param WHEN NEW.sku_id IS NOT OLD.sku_id BEGIN SELECT RAISE(ABORT, 'sku_live_param_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_sku_live_param_monotonic BEFORE UPDATE ON sku_live_param WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'sku_live_param_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_live_tank_keylock BEFORE UPDATE ON live_tank WHEN NEW.location_id IS NOT OLD.location_id BEGIN SELECT RAISE(ABORT, 'live_tank_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_live_tank_monotonic BEFORE UPDATE ON live_tank WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'live_tank_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_live_stock_count_keylock BEFORE UPDATE ON live_stock_count WHEN NEW.stock_id IS NOT OLD.stock_id BEGIN SELECT RAISE(ABORT, 'live_stock_count_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_live_stock_count_monotonic BEFORE UPDATE ON live_stock_count WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'live_stock_count_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_live_tank_hold_keylock BEFORE UPDATE ON live_tank_hold WHEN NEW.id IS NOT OLD.id OR NEW.location_id IS NOT OLD.location_id BEGIN SELECT RAISE(ABORT, 'live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_live_death_keylock BEFORE UPDATE ON live_death WHEN NEW.id IS NOT OLD.id OR (OLD.movement_id IS NOT NULL AND NEW.movement_id IS NOT OLD.movement_id) OR NEW.device_instance_id IS NOT OLD.device_instance_id OR NEW.client_op_id IS NOT OLD.client_op_id BEGIN SELECT RAISE(ABORT, 'live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_live_death_monotonic BEFORE UPDATE ON live_death WHEN NEW.deducted_qty_milli < OLD.deducted_qty_milli BEGIN SELECT RAISE(ABORT, 'live_death_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
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
-- 清理角色与 purge_expired()。各表的 wms_app GRANT 写在该表所在的篇文件末尾，
-- 后续篇章只加自己的 sql/schema/NN_*.sql，不要再改一份总 GRANT。
-- ============================================================
-- 清理只能经 purge_expired()：属主 wms_purge_owner（非超级用户、NOLOGIN，只有这两张表的 SELECT/DELETE），
-- 调用方 wms_cleaner 只有 EXECUTE，对表没有任何权限；删除条件写死在函数里，不接受参数
