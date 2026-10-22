-- -----------------------------------------------------------------------------
-- 06 复核、装箱、发货（范围到发货出库为止，配送与签收归第 16 篇）
--   文档：docs/06-复核装箱发货.md。表与约束以本文件为准。
--   本轮（长流）：补类型 / 重量 / 封箱一致性 CHECK、状态值域 CHECK、本篇外键、
--   shipment 时间列改库时钟整秒 UTC（00 §6.8 第 3 条）。
--   表顺序：pack_box.shipment_id 外键指向 shipment，所以 shipment / shipment_order
--   建在 pack_box 之前（SQLite 不能 ALTER 加外键，必须内联）。
--   待落库 / 待裁决：check_record / check_line / check_op / check_picker（复核逐扫与 SoD
--   留痕）、box_void_request（00 §6.6.1 已登记的表）、pack_box 的状态列与装箱状态机、
--   shipment 上司机 / 车辆 / 发车 / 签收列与 status 取值跟第 16 篇的分工（00 §8 说
--   本篇到发货出库为止）、四张表的 no-REPLACE 守卫（00 §6.10 REPLACE_TODO）。详见 docs/06 §4.5 / §12。
-- -----------------------------------------------------------------------------

CREATE TABLE shipment (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    carrier_code    VARCHAR(32),
    vehicle_no      VARCHAR(24),
    driver_id       BIGINT,
    driver_name     VARCHAR(64),
    driver_phone    VARCHAR(32),
    status          VARCHAR(16)  NOT NULL DEFAULT 'CREATED', -- CREATED/HANDED_OVER/CANCELLED（本轮按 00 §8 范围收窄；司机/车辆/发车/签收列的去留待 16 篇拍板，docs/06 §12 Q1）
    planned_depart_at TIMESTAMP,
    departed_at     TIMESTAMP,
    signed_at       TIMESTAMP,
    temp_log_ref    VARCHAR(128),                   -- 温控记录对象存储 key
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_shp_code UNIQUE (code),
    CONSTRAINT ck_shp_status CHECK (status IN ('CREATED','HANDED_OVER','CANCELLED')),   -- 06 范围到发货出库为止；发车/在途/签收在 16 篇的运单表（docs/06 §12 Q1）
    CONSTRAINT fk_shp_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id)
);
CREATE INDEX ix_shp_driver ON shipment(driver_id, status, planned_depart_at);

CREATE TABLE shipment_order (
    shipment_id BIGINT NOT NULL,
    outbound_id BIGINT NOT NULL,
    PRIMARY KEY (shipment_id, outbound_id),
    -- 「一张出库单只能挂一个车次」是应用层不变量（旧稿的 uq_sho_outbound 部分唯一未落库，见 docs/06 §12）
    CONSTRAINT fk_sho_shipment FOREIGN KEY (shipment_id) REFERENCES shipment(id),
    CONSTRAINT fk_sho_outbound FOREIGN KEY (outbound_id) REFERENCES outbound_order(id)
);

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
    CONSTRAINT uq_box_code UNIQUE (code),
    CONSTRAINT ck_box_type   CHECK (box_type IN ('CARTON','TURNBOX')),
    CONSTRAINT ck_box_weight CHECK (weight_g IS NULL OR weight_g >= 0),
    CONSTRAINT ck_box_sealed CHECK (sealed = false OR (packed_at IS NOT NULL AND checker_id IS NOT NULL)),  -- 封箱必须留下复核人与封箱时刻
    CONSTRAINT fk_box_wh       FOREIGN KEY (warehouse_id)      REFERENCES warehouse(id),
    CONSTRAINT fk_box_outbound FOREIGN KEY (outbound_id)       REFERENCES outbound_order(id),
    CONSTRAINT fk_box_shipment FOREIGN KEY (shipment_id)       REFERENCES shipment(id),
    CONSTRAINT fk_box_stage    FOREIGN KEY (stage_location_id) REFERENCES location(id)
);

CREATE TABLE pack_box_line (
    id          BIGINT          PRIMARY KEY,
    box_id      BIGINT          NOT NULL,
    sku_id      BIGINT          NOT NULL,
    lot_id      BIGINT          NOT NULL DEFAULT 0,   -- 0 = 未记批次；同 stock.container_id，不可空（uq 含 NULL 会失效）
    qty_milli   BIGINT          NOT NULL,   -- 基本单位 milli
    uom         VARCHAR(16)     NOT NULL,
    CONSTRAINT ck_box_line_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT uq_box_line UNIQUE (box_id, sku_id, lot_id),
    CONSTRAINT fk_bxl_box FOREIGN KEY (box_id) REFERENCES pack_box(id),
    CONSTRAINT fk_bxl_sku FOREIGN KEY (sku_id) REFERENCES sku(id)
    -- lot_id 不加外键：0 是"未记批次"哨兵值（R11），不是 lot 行
);
GRANT SELECT, INSERT, UPDATE ON pack_box, pack_box_line, shipment, shipment_order TO wms_app;  -- @pg-only
