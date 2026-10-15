-- -----------------------------------------------------------------------------
-- 05 波次与拣货
--   文档：docs/05-波次与拣货.md。表与约束以本文件为准。
--   本篇落库范围：波次、拣货任务、任务行。待回库记录 return_record（04 §4.4 定约束）
--   与 PDA 去重表 pick_op、波次容量配置 wave_capacity_config 见 docs/05 §4.5 / §12，
--   尚未落库：它们需要连带 no-REPLACE 守卫、冻结基线登记与两库用例，按 00 §6.10
--   "名单只能缩小"的口径单独一个增量提。
-- -----------------------------------------------------------------------------

CREATE TABLE wave (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    work_date           DATE         NOT NULL,
    temperature_zone    VARCHAR(16)  NOT NULL,
    route_code          VARCHAR(32)  NOT NULL,
    carrier_code        VARCHAR(32),
    pick_strategy       VARCHAR(24)  NOT NULL DEFAULT 'BATCH',   -- DISCRETE/BATCH/ZONE/WAVE_AND_SPLIT，只决定拣货方式
    status              VARCHAR(16)  NOT NULL DEFAULT 'PLANNED', -- PLANNED/RELEASED/PICKING/COMPLETED/HOLD/CANCELLED
    order_count         INT          NOT NULL DEFAULT 0,
    pick_line_count     INT          NOT NULL DEFAULT 0,
    parent_wave_id      BIGINT,
    released_at         TIMESTAMP,
    completed_at        TIMESTAMP,
    created_by          BIGINT,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    version             BIGINT       NOT NULL DEFAULT 0,         -- 状态条件更新时 +1（00 §6.7）
    CONSTRAINT uq_wave_code UNIQUE (code),
    CONSTRAINT ck_wave_status   CHECK (status IN ('PLANNED','RELEASED','PICKING','COMPLETED','HOLD','CANCELLED')),
    CONSTRAINT ck_wave_strategy CHECK (pick_strategy IN ('DISCRETE','BATCH','ZONE','WAVE_AND_SPLIT')),
    CONSTRAINT ck_wave_parent   CHECK (parent_wave_id IS NULL OR parent_wave_id <> id),
    CONSTRAINT ck_wave_count    CHECK (order_count >= 0 AND pick_line_count >= 0)
);
CREATE INDEX ix_wave_wh ON wave(warehouse_id, status, work_date DESC);

CREATE TABLE pick_task (
    id                      BIGINT       PRIMARY KEY,
    code                    VARCHAR(64)  NOT NULL,
    wave_id                 BIGINT       NOT NULL,
    warehouse_id            BIGINT       NOT NULL,
    task_type               VARCHAR(24)  NOT NULL DEFAULT 'PICK',   -- PICK/REPLENISH（补货复用本表，流程在 07）
    zone_id                 BIGINT,
    status                  VARCHAR(16)  NOT NULL DEFAULT 'PENDING',-- PENDING/EXECUTING/DONE/ABNORMAL/CANCELLED/CLOSED
    assigned_to             BIGINT,
    device_instance_id      VARCHAR(64),                            -- 当前持有设备；记账归属的权威仍是 stock_ledger_line.owner_device_instance_id
    claimed_at              TIMESTAMP,
    started_at              TIMESTAMP,
    finished_at             TIMESTAMP,
    line_count              INT          NOT NULL DEFAULT 0,
    done_count              INT          NOT NULL DEFAULT 0,
    version                 BIGINT       NOT NULL DEFAULT 0,
    handover_from_task_id   BIGINT,                                 -- 交接任务来源（改派产生），只做追溯
    created_at              TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at              TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_pt_code UNIQUE (code),
    CONSTRAINT ck_pt_type   CHECK (task_type IN ('PICK','REPLENISH')),
    CONSTRAINT ck_pt_status CHECK (status IN ('PENDING','EXECUTING','DONE','ABNORMAL','CANCELLED','CLOSED')),
    CONSTRAINT ck_pt_exec   CHECK (status <> 'EXECUTING' OR (assigned_to IS NOT NULL AND device_instance_id IS NOT NULL)),
    CONSTRAINT ck_pt_count  CHECK (line_count >= 0 AND done_count >= 0 AND done_count <= line_count),
    CONSTRAINT ck_pt_handover CHECK (handover_from_task_id IS NULL OR handover_from_task_id <> id),
    CONSTRAINT fk_pt_wave   FOREIGN KEY (wave_id)  REFERENCES wave(id),
    CONSTRAINT fk_pt_zone   FOREIGN KEY (zone_id)  REFERENCES zone(id)
);
-- 领取队列：待领取 + 按动线优先级
CREATE INDEX ix_pt_claim ON pick_task(wave_id, status, zone_id) WHERE status = 'PENDING';
CREATE INDEX ix_pt_mine  ON pick_task(assigned_to, status);
CREATE INDEX ix_pt_handover ON pick_task(handover_from_task_id) WHERE handover_from_task_id IS NOT NULL;

CREATE TABLE pick_task_line (
    id                  BIGINT          PRIMARY KEY,
    pick_task_id        BIGINT          NOT NULL,
    seq                 SMALLINT        NOT NULL,   -- 动线顺序，前端按它渲染；即四元组里的 line_no
    location_id         BIGINT          NOT NULL,
    sku_id              BIGINT          NOT NULL,
    lot_id              BIGINT          NOT NULL,
    stock_id            BIGINT          NOT NULL,
    outbound_line_id    BIGINT,                     -- PICK 行必填（口径见 docs/05 §3.2）；REPLENISH 行为空
    planned_qty_milli   BIGINT          NOT NULL,   -- 应拣量，基本单位 milli（原 plan_qty_base）
    confirmed_qty_milli BIGINT          NOT NULL DEFAULT 0,  -- 已确认量；条件更新 confirmed + qty <= planned，否则 42214（00 §6.5）
    uom                 VARCHAR(16)     NOT NULL,   -- 作业单位，仅展示
    barcode_expected    VARCHAR(64),
    status              VARCHAR(16)     NOT NULL DEFAULT 'PENDING', -- PENDING/DONE/SHORT/SKIP/ABNORMAL
    short_reason_code   VARCHAR(24),                -- STOCK_OUT/DAMAGED/EXPIRED/WRONG_LOC/OTHER
    scanned_at          TIMESTAMP,
    override_reason     VARCHAR(128),               -- FEFO 越权原因（RK4）
    override_by         BIGINT,
    CONSTRAINT ck_ptl_qty CHECK (
        planned_qty_milli > 0 AND confirmed_qty_milli >= 0 AND confirmed_qty_milli <= planned_qty_milli
        AND planned_qty_milli = CAST(planned_qty_milli AS BIGINT) AND confirmed_qty_milli = CAST(confirmed_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_ptl_status CHECK (status IN ('PENDING','DONE','SHORT','SKIP','ABNORMAL')),
    CONSTRAINT ck_ptl_short  CHECK (
        (short_reason_code IS NULL OR short_reason_code IN ('STOCK_OUT','DAMAGED','EXPIRED','WRONG_LOC','OTHER'))
        AND (status <> 'SHORT' OR short_reason_code IS NOT NULL)
    ),
    CONSTRAINT ck_ptl_override CHECK (
        (override_reason IS NULL AND override_by IS NULL) OR (override_reason IS NOT NULL AND override_by IS NOT NULL)
    ),
    CONSTRAINT uq_ptl UNIQUE (pick_task_id, seq),
    CONSTRAINT fk_ptl_task     FOREIGN KEY (pick_task_id)     REFERENCES pick_task(id),
    CONSTRAINT fk_ptl_stock    FOREIGN KEY (stock_id)         REFERENCES stock(id),
    CONSTRAINT fk_ptl_location FOREIGN KEY (location_id)      REFERENCES location(id),
    CONSTRAINT fk_ptl_sku      FOREIGN KEY (sku_id)           REFERENCES sku(id),
    CONSTRAINT fk_ptl_lot      FOREIGN KEY (lot_id)           REFERENCES lot(id),
    CONSTRAINT fk_ptl_obl      FOREIGN KEY (outbound_line_id) REFERENCES outbound_line(id)
);
CREATE INDEX ix_ptl_loc ON pick_task_line(location_id, status);
GRANT SELECT, INSERT, UPDATE ON wave, pick_task, pick_task_line TO wms_app;  -- @pg-only
