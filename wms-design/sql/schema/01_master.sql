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
    warehouse_id    BIGINT       NOT NULL REFERENCES warehouse(id),
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
    sku_id      BIGINT      NOT NULL REFERENCES sku(id),
    barcode     VARCHAR(64) NOT NULL,
    uom         VARCHAR(16) NOT NULL DEFAULT 'EA',   -- 该条码对应的包装层级
    is_primary  BOOLEAN     NOT NULL DEFAULT false,
    CONSTRAINT uq_barcode UNIQUE (barcode)
);
-- PDA 扫码解析：条码 → SKU，必须走唯一索引，一次命中
-- #2 第十二轮（00 §6.10 扩到全部带唯一键的表）：REPLACE 同条码会静默删掉别的 SKU 的条码行（条码被"抢"走）→ 两个唯一键都先拦
-- @sqlite-only CREATE TRIGGER trg_bc_no_replace BEFORE INSERT ON sku_barcode WHEN EXISTS (SELECT 1 FROM sku_barcode b WHERE b.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'barcode_duplicate: sku_barcode.id'); END;
-- @sqlite-only CREATE TRIGGER trg_bc_no_replace_code BEFORE INSERT ON sku_barcode WHEN EXISTS (SELECT 1 FROM sku_barcode b WHERE b.barcode = NEW.barcode) BEGIN SELECT RAISE(ABORT, 'barcode_duplicate: sku_barcode.barcode'); END;

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
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
-- @sqlite-only     CONSTRAINT ck_lot_date CHECK (
-- @sqlite-only         (production_date IS NULL OR (production_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(production_date) IS production_date))
-- @sqlite-only         AND expiry_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(expiry_date) IS expiry_date
-- @sqlite-only         AND (sell_deadline IS NULL OR (sell_deadline GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(sell_deadline) IS sell_deadline))),
-- @sqlite-only     CONSTRAINT ck_lot_recv_ts CHECK (receive_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(receive_date) IS receive_date),   -- #2 第十一轮：只收 YYYY-MM-DD，拒时间/24:00/偏移/斜杠/紧凑写法/非法日期
    CONSTRAINT uq_lot UNIQUE (sku_id, lot_code, expiry_date)
);
CREATE INDEX ix_lot_expiry ON lot(sku_id, expiry_date) WHERE quality_status = 'QUALIFIED';
CREATE INDEX ix_lot_aging  ON lot(remaining_life_days, sku_id);
-- [SQLite] 两个部分索引均支持；ix_lot_aging 支撑效期预警列表
-- sell_deadline 建档固定、不回溯：其余列仍可更新，只有这一列（含 NULL）写入后不可改
-- search_path 固定为 pg_catalog, public。IS DISTINCT FROM 用的 =(date,date) 来自 pg_catalog，调用方 schema 里的同名运算符不生效。
CREATE FUNCTION trg_lot_sell_deadline() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                     -- @pg-only
    IF NEW.sell_deadline IS DISTINCT FROM OLD.sell_deadline THEN                                          -- @pg-only
        RAISE EXCEPTION 'sell_deadline_immutable' USING ERRCODE = '23514';                               -- @pg-only
    END IF;                                                                                               -- @pg-only
    RETURN NEW;                                                                                           -- @pg-only
END $$;                                                                                                   -- @pg-only
CREATE TRIGGER trg_lot_sell_deadline BEFORE UPDATE ON lot FOR EACH ROW EXECUTE FUNCTION trg_lot_sell_deadline();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lot_sell_deadline BEFORE UPDATE ON lot
-- @sqlite-only WHEN NEW.sell_deadline IS NOT OLD.sell_deadline
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sell_deadline_immutable'); END;
-- #2 第十二轮：REPLACE 撞 id 或 uq_lot 会删旧批次再插新行，绕过 trg_lot_sell_deadline（00 §6.10）→ 两个唯一键都先拦
-- @sqlite-only CREATE TRIGGER trg_lot_no_replace BEFORE INSERT ON lot WHEN EXISTS (SELECT 1 FROM lot l WHERE l.id = NEW.id
-- @sqlite-only   OR (l.sku_id = NEW.sku_id AND l.lot_code = NEW.lot_code AND l.expiry_date = NEW.expiry_date))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'lot_duplicate'); END;
-- #2 第十二轮（小玛丽 r12 B2）：主数据按业务键换 id REPLACE 会静默删掉父行；子表 sku_id / location_id / zone_id 很多没声明外键（见 #14），删掉就是孤儿 → 每个唯一键都拦
-- @sqlite-only CREATE TRIGGER trg_warehouse_no_replace BEFORE INSERT ON warehouse WHEN EXISTS (SELECT 1 FROM warehouse x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: warehouse.id'); END;
-- @sqlite-only CREATE TRIGGER trg_warehouse_no_replace_code BEFORE INSERT ON warehouse WHEN EXISTS (SELECT 1 FROM warehouse x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: warehouse.code'); END;
-- @sqlite-only CREATE TRIGGER trg_zone_no_replace BEFORE INSERT ON zone WHEN EXISTS (SELECT 1 FROM zone x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: zone.id'); END;
-- @sqlite-only CREATE TRIGGER trg_zone_no_replace_code BEFORE INSERT ON zone WHEN EXISTS (SELECT 1 FROM zone x WHERE x.warehouse_id = NEW.warehouse_id AND x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: zone.warehouse_id, zone.code'); END;
-- @sqlite-only CREATE TRIGGER trg_location_no_replace BEFORE INSERT ON location WHEN EXISTS (SELECT 1 FROM location x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: location.id'); END;
-- @sqlite-only CREATE TRIGGER trg_location_no_replace_code BEFORE INSERT ON location WHEN EXISTS (SELECT 1 FROM location x WHERE x.warehouse_id = NEW.warehouse_id AND x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: location.warehouse_id, location.code'); END;
-- @sqlite-only CREATE TRIGGER trg_sku_no_replace BEFORE INSERT ON sku WHEN EXISTS (SELECT 1 FROM sku x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'master_duplicate: sku.id'); END;
-- @sqlite-only CREATE TRIGGER trg_sku_no_replace_code BEFORE INSERT ON sku WHEN EXISTS (SELECT 1 FROM sku x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'master_duplicate: sku.code'); END;
GRANT SELECT, INSERT, UPDATE ON warehouse, zone, location, sku, sku_barcode, sku_unit, lot TO wms_app;  -- @pg-only
