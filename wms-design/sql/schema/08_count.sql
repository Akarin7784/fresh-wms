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
GRANT SELECT, INSERT, UPDATE ON count_order, count_line, adjust_order, adjust_line TO wms_app;  -- @pg-only
