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
GRANT SELECT, INSERT, UPDATE ON pack_box, pack_box_line, shipment, shipment_order TO wms_app;  -- @pg-only
