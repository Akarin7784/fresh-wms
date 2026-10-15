-- -----------------------------------------------------------------------------
-- 盘点 / 调整
--   文档：docs/08-盘点.md。表与约束以本文件为准。
--   本轮（长流）：补状态 / 类型 CHECK、本篇外键与二级索引、count_order / adjust_order
--   的 version + updated_at、created_at 改库时钟整秒 UTC（00 §6.8 第 3 条）；
--   adjust_line 按 00 §5 R2 把 delta_qty NUMERIC(14,3) 改成 delta_qty_milli BIGINT，
--   并补 line_no（02 记账幂等键 {biz_no}:{line_no}:D{op_no}:{leg} 需要）。
--   表顺序：count_line.adjust_id 外键指向 adjust_order，所以 adjust_* 建在 count_line 之前。
--   待落库：四张表的 no-REPLACE 守卫（00 §6.10 REPLACE_TODO 现状）、盘点冻结在 02 侧
--   的加固、离线实盘去重表，见 docs/08 §4.6 / §12。
-- -----------------------------------------------------------------------------

CREATE TABLE count_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    count_type      VARCHAR(24)  NOT NULL,   -- FULL/CYCLE/DYNAMIC/SAMPLE
    scope_json      TEXT         NOT NULL,   -- 盘点范围（不用 JSONB，R4）
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',  -- DRAFT/COUNTING/SUSPENDED/CONFIRMED/CLOSED/CANCELLED
    frozen_at       TIMESTAMP,
    book_at         TIMESTAMP    NOT NULL,   -- 账面基准时点（差异要加回期间流水）
    started_at      TIMESTAMP,
    finished_at     TIMESTAMP,
    approved_by     BIGINT,
    approved_at     TIMESTAMP,
    created_by      BIGINT,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    version         BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_cnt_code UNIQUE (code),
    CONSTRAINT ck_cnt_type     CHECK (count_type IN ('FULL','CYCLE','DYNAMIC','SAMPLE')),
    CONSTRAINT ck_cnt_status   CHECK (status IN ('DRAFT','COUNTING','SUSPENDED','CONFIRMED','CLOSED','CANCELLED')),
    CONSTRAINT ck_cnt_approved CHECK (approved_by IS NULL OR created_by IS NULL OR approved_by <> created_by),
    CONSTRAINT fk_cnt_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id)
);
CREATE INDEX ix_cnt_wh ON count_order(warehouse_id, status, created_at);

CREATE TABLE adjust_order (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,
    warehouse_id    BIGINT          NOT NULL,
    adjust_type     VARCHAR(24)     NOT NULL,   -- COUNT_GAIN/COUNT_LOSS/SCRAP/MANUAL/REVERSE_PICK
    reason_code     VARCHAR(24)     NOT NULL,
    source_type     VARCHAR(24),
    source_id       BIGINT,
    status          VARCHAR(16)     NOT NULL DEFAULT 'PENDING',  -- PENDING/APPROVED/REJECTED/CANCELLED/APPLIED
    amount_impact   BIGINT          NOT NULL DEFAULT 0,
    applicant_id    BIGINT          NOT NULL,
    approver_id     BIGINT,
    approved_at     TIMESTAMP,
    applied_at      TIMESTAMP,
    created_at      TIMESTAMP       NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP       NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    version         BIGINT          NOT NULL DEFAULT 0,
    CONSTRAINT uq_adj_code UNIQUE (code),
    CONSTRAINT ck_adj_type   CHECK (adjust_type IN ('COUNT_GAIN','COUNT_LOSS','SCRAP','MANUAL','REVERSE_PICK')),
    CONSTRAINT ck_adj_status CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED','APPLIED')),
    CONSTRAINT ck_adj_sod    CHECK (approver_id IS NULL OR approver_id <> applicant_id),
    CONSTRAINT fk_adj_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id)
);
CREATE INDEX ix_adj_wh  ON adjust_order(warehouse_id, status, created_at);
CREATE INDEX ix_adj_src ON adjust_order(source_type, source_id);

CREATE TABLE adjust_line (
    id              BIGINT          PRIMARY KEY,
    adjust_id       BIGINT          NOT NULL,
    line_no         SMALLINT        NOT NULL,   -- 过账流水行号：{biz_no}:{line_no}:D{op_no}:{leg}
    stock_id        BIGINT          NOT NULL,
    delta_qty_milli BIGINT          NOT NULL,   -- 正入负出，基本单位 milli（00 §5 R2）
    CONSTRAINT ck_adj_delta CHECK (delta_qty_milli <> 0),
    CONSTRAINT ck_adj_int   CHECK (delta_qty_milli = CAST(delta_qty_milli AS BIGINT)),
    CONSTRAINT uq_adjl UNIQUE (adjust_id, line_no),
    CONSTRAINT fk_adjl_order FOREIGN KEY (adjust_id) REFERENCES adjust_order(id)
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
    status          VARCHAR(16)     NOT NULL DEFAULT 'PENDING', -- PENDING/COUNTED/RECOUNTED/CONFIRMED/CANCELLED
    counted_by      BIGINT,
    counted_at      TIMESTAMP,
    adjust_id       BIGINT,
    CONSTRAINT ck_cnt_int CHECK (
        book_qty_milli = CAST(book_qty_milli AS BIGINT)
        AND movement_qty_milli = CAST(movement_qty_milli AS BIGINT)
        AND (actual_qty_milli IS NULL OR actual_qty_milli = CAST(actual_qty_milli AS BIGINT))
        AND (recount_qty_milli IS NULL OR recount_qty_milli = CAST(recount_qty_milli AS BIGINT))
    ),
    CONSTRAINT ck_cntl_status  CHECK (status IN ('PENDING','COUNTED','RECOUNTED','CONFIRMED','CANCELLED')),
    CONSTRAINT ck_cntl_counted CHECK (status = 'PENDING' OR (actual_qty_milli IS NOT NULL AND counted_at IS NOT NULL)),
    CONSTRAINT ck_cntl_recount CHECK (recount_qty_milli IS NULL OR actual_qty_milli IS NOT NULL),
    CONSTRAINT uq_cnt_line UNIQUE (count_id, location_id, sku_id, lot_id),
    CONSTRAINT fk_cntl_count  FOREIGN KEY (count_id)    REFERENCES count_order(id),
    CONSTRAINT fk_cntl_adjust FOREIGN KEY (adjust_id)   REFERENCES adjust_order(id),
    CONSTRAINT fk_cntl_loc    FOREIGN KEY (location_id) REFERENCES location(id),
    CONSTRAINT fk_cntl_sku    FOREIGN KEY (sku_id)      REFERENCES sku(id),
    CONSTRAINT fk_cntl_lot    FOREIGN KEY (lot_id)      REFERENCES lot(id)
);
-- [SQLite] GENERATED 列 SQLite 3.31+ 支持 STORED；若低于该版本改为应用层计算 + 普通列
CREATE INDEX ix_cnt_line_count ON count_line(count_id, status);
CREATE INDEX ix_cnt_line_loc   ON count_line(location_id);
GRANT SELECT, INSERT, UPDATE ON count_order, count_line, adjust_order, adjust_line TO wms_app;  -- @pg-only
