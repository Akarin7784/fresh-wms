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
GRANT SELECT, INSERT, UPDATE ON inbound_order, inbound_line TO wms_app;  -- @pg-only
