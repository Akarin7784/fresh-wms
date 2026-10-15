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

-- 环守卫（镜鉴 r5 重要项②）：ck_wave_parent 只防自指，两点成环（A→B、B→A）能落库。
-- 00 §6.1 明说 ID 不保证跨节点单调、业务逻辑不得依赖 ID 大小，所以不能用 parent_wave_id < id 当拓扑序，只能真沿链上溯。
-- 用 AFTER 而不是 BEFORE：守卫必须在 REPLACE / UPSERT 插入的新行上也生效（AFTER INSERT 照常触发），
--   同时不把 wave / pick_task 变成 00 §6.10 的「受锁表」（那会强制补 no-REPLACE 守卫，是另一个增量）。
-- 事务内可观测的环（含任意长度、INSERT 与 UPDATE 两条路径）必被拦；写偏斜（两个事务各写一半、都看不到对方）由应用层
--   在同一事务内对父波次行加锁串行化，见 docs/05 §8「环写的并发口径」。
CREATE FUNCTION trg_wave_parent_cycle() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE                                                                                                                       -- @pg-only
    cur BIGINT := NEW.parent_wave_id;                                                                                         -- @pg-only
    lvl INT := 0;                                                                                                             -- @pg-only
BEGIN                                                                                                                         -- @pg-only
    IF cur IS NULL THEN RETURN NULL; END IF;                                                                                  -- @pg-only
    WHILE cur IS NOT NULL LOOP                                                                                                -- @pg-only
        IF cur = NEW.id THEN RAISE EXCEPTION 'wave_parent_cycle' USING ERRCODE = '23514'; END IF;                             -- @pg-only
        lvl := lvl + 1;                                                                                                       -- @pg-only
        IF lvl > 64 THEN RAISE EXCEPTION 'wave_parent_cycle_depth' USING ERRCODE = '23514'; END IF;                           -- @pg-only
        SELECT parent_wave_id INTO cur FROM wave WHERE id = cur;                                                              -- @pg-only
    END LOOP;                                                                                                                 -- @pg-only
    RETURN NULL;                                                                                                              -- @pg-only
END $$;                                                                                                                       -- @pg-only
CREATE TRIGGER trg_wave_parent_cycle AFTER INSERT OR UPDATE OF parent_wave_id ON wave FOR EACH ROW EXECUTE FUNCTION trg_wave_parent_cycle();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_wave_parent_cycle AFTER INSERT ON wave WHEN NEW.parent_wave_id IS NOT NULL
-- @sqlite-only BEGIN
-- @sqlite-only   SELECT RAISE(ABORT, 'wave_parent_cycle') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, parent_wave_id, lvl) AS (
-- @sqlite-only       SELECT w.id, w.parent_wave_id, 1 FROM wave w WHERE w.id = NEW.parent_wave_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT w.id, w.parent_wave_id, a.lvl + 1 FROM wave w JOIN anc a ON w.id = a.parent_wave_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE id = NEW.id);
-- @sqlite-only   SELECT RAISE(ABORT, 'wave_parent_cycle_depth') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, parent_wave_id, lvl) AS (
-- @sqlite-only       SELECT w.id, w.parent_wave_id, 1 FROM wave w WHERE w.id = NEW.parent_wave_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT w.id, w.parent_wave_id, a.lvl + 1 FROM wave w JOIN anc a ON w.id = a.parent_wave_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE lvl > 64);
-- @sqlite-only END;
-- @sqlite-only CREATE TRIGGER trg_wave_parent_cycle_u AFTER UPDATE OF parent_wave_id ON wave WHEN NEW.parent_wave_id IS NOT NULL
-- @sqlite-only BEGIN
-- @sqlite-only   SELECT RAISE(ABORT, 'wave_parent_cycle') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, parent_wave_id, lvl) AS (
-- @sqlite-only       SELECT w.id, w.parent_wave_id, 1 FROM wave w WHERE w.id = NEW.parent_wave_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT w.id, w.parent_wave_id, a.lvl + 1 FROM wave w JOIN anc a ON w.id = a.parent_wave_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE id = NEW.id);
-- @sqlite-only   SELECT RAISE(ABORT, 'wave_parent_cycle_depth') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, parent_wave_id, lvl) AS (
-- @sqlite-only       SELECT w.id, w.parent_wave_id, 1 FROM wave w WHERE w.id = NEW.parent_wave_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT w.id, w.parent_wave_id, a.lvl + 1 FROM wave w JOIN anc a ON w.id = a.parent_wave_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE lvl > 64);
-- @sqlite-only END;

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
    -- 空白串不算设备号（镜鉴 r5 重要项① + r6 加固）：'' / '   ' / '\t' 都能绕过 ck_pt_exec，
    -- 两台没写设备号的 PDA 生成同一个幂等键 P{设备}.{op_seq}（00 §6.5 四元组），把并发上报当成重放。
    -- 与状态无关，一律拒；PG 用 btrim（默认只去空格，必须显式给 ASCII 空白集），SQLite 用 trim(X,Y)。
    CONSTRAINT ck_pt_device CHECK (device_instance_id IS NULL OR btrim(device_instance_id, E' \t\r\n\v\f') <> ''),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_pt_device CHECK (device_instance_id IS NULL OR trim(device_instance_id, ' ' || char(9) || char(10) || char(11) || char(12) || char(13)) <> ''),
    CONSTRAINT ck_pt_count  CHECK (line_count >= 0 AND done_count >= 0 AND done_count <= line_count),
    CONSTRAINT ck_pt_handover CHECK (handover_from_task_id IS NULL OR handover_from_task_id <> id),
    CONSTRAINT fk_pt_wave   FOREIGN KEY (wave_id)  REFERENCES wave(id),
    CONSTRAINT fk_pt_zone   FOREIGN KEY (zone_id)  REFERENCES zone(id)
);
-- 领取队列：待领取 + 按动线优先级
CREATE INDEX ix_pt_claim ON pick_task(wave_id, status, zone_id) WHERE status = 'PENDING';
CREATE INDEX ix_pt_mine  ON pick_task(assigned_to, status);
CREATE INDEX ix_pt_handover ON pick_task(handover_from_task_id) WHERE handover_from_task_id IS NOT NULL;

-- 环守卫（镜鉴 r5 重要项②）：改派链同样只防自指，A→B→A 能落库。口径与 trg_wave_parent_cycle 一致（AFTER 触发 + 真沿链上溯 + 应用层加锁）。
CREATE FUNCTION trg_pt_handover_cycle() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE                                                                                                                      -- @pg-only
    cur BIGINT := NEW.handover_from_task_id;                                                                                 -- @pg-only
    lvl INT := 0;                                                                                                            -- @pg-only
BEGIN                                                                                                                        -- @pg-only
    IF cur IS NULL THEN RETURN NULL; END IF;                                                                                 -- @pg-only
    WHILE cur IS NOT NULL LOOP                                                                                               -- @pg-only
        IF cur = NEW.id THEN RAISE EXCEPTION 'pick_task_handover_cycle' USING ERRCODE = '23514'; END IF;                     -- @pg-only
        lvl := lvl + 1;                                                                                                      -- @pg-only
        IF lvl > 64 THEN RAISE EXCEPTION 'pick_task_handover_cycle_depth' USING ERRCODE = '23514'; END IF;                   -- @pg-only
        SELECT handover_from_task_id INTO cur FROM pick_task WHERE id = cur;                                                 -- @pg-only
    END LOOP;                                                                                                                -- @pg-only
    RETURN NULL;                                                                                                             -- @pg-only
END $$;                                                                                                                      -- @pg-only
CREATE TRIGGER trg_pt_handover_cycle AFTER INSERT OR UPDATE OF handover_from_task_id ON pick_task FOR EACH ROW EXECUTE FUNCTION trg_pt_handover_cycle();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_pt_handover_cycle AFTER INSERT ON pick_task WHEN NEW.handover_from_task_id IS NOT NULL
-- @sqlite-only BEGIN
-- @sqlite-only   SELECT RAISE(ABORT, 'pick_task_handover_cycle') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, handover_from_task_id, lvl) AS (
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, 1 FROM pick_task t WHERE t.id = NEW.handover_from_task_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, a.lvl + 1 FROM pick_task t JOIN anc a ON t.id = a.handover_from_task_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE id = NEW.id);
-- @sqlite-only   SELECT RAISE(ABORT, 'pick_task_handover_cycle_depth') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, handover_from_task_id, lvl) AS (
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, 1 FROM pick_task t WHERE t.id = NEW.handover_from_task_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, a.lvl + 1 FROM pick_task t JOIN anc a ON t.id = a.handover_from_task_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE lvl > 64);
-- @sqlite-only END;
-- @sqlite-only CREATE TRIGGER trg_pt_handover_cycle_u AFTER UPDATE OF handover_from_task_id ON pick_task WHEN NEW.handover_from_task_id IS NOT NULL
-- @sqlite-only BEGIN
-- @sqlite-only   SELECT RAISE(ABORT, 'pick_task_handover_cycle') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, handover_from_task_id, lvl) AS (
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, 1 FROM pick_task t WHERE t.id = NEW.handover_from_task_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, a.lvl + 1 FROM pick_task t JOIN anc a ON t.id = a.handover_from_task_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE id = NEW.id);
-- @sqlite-only   SELECT RAISE(ABORT, 'pick_task_handover_cycle_depth') WHERE EXISTS (
-- @sqlite-only     WITH RECURSIVE anc(id, handover_from_task_id, lvl) AS (
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, 1 FROM pick_task t WHERE t.id = NEW.handover_from_task_id
-- @sqlite-only       UNION ALL
-- @sqlite-only       SELECT t.id, t.handover_from_task_id, a.lvl + 1 FROM pick_task t JOIN anc a ON t.id = a.handover_from_task_id WHERE a.lvl < 65)
-- @sqlite-only     SELECT 1 FROM anc WHERE lvl > 64);
-- @sqlite-only END;

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
