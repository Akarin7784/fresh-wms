-- -----------------------------------------------------------------------------
-- 第 7 篇 补货与移库
-- 依赖：01（location / zone / sku / lot）、02（move 原语、stock / stock_movement）、
--       04（outbound_line.alloc_round / Shortage(cause=NEED_REPLENISH)）
-- 本篇不绕过第 2 篇库存原语：补货与移库的库存效果一律由 `move()` 产生两腿流水。
-- 补货任务**不复用** 05 的 `pick_task`：补货任务没有波次（pick_task.wave_id NOT NULL），
-- 且任务行需要「源存储位 + 目标拣货位」两个库位（pick_task_line 只有一个 location_id）。
-- 因此本篇自建 replenish_task / replenish_task_line；05 的 task_type='REPLENISH' 注释作废，
-- 见 docs/07-补货与移库.md §12 Q1（已报 Chief）。
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 1) 补货任务（replenish_task / replenish_task_line）
--    一个任务 = 同一库区（zone_id）里的一组补货行，PDA 按库区 / 动线领取。
-- -----------------------------------------------------------------------------
CREATE TABLE replenish_task (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL REFERENCES warehouse(id),
    zone_id         BIGINT       NOT NULL REFERENCES zone(id),
    work_date       DATE         NOT NULL,
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING',  -- PENDING/EXECUTING/DONE/ABNORMAL/CANCELLED
    priority        SMALLINT     NOT NULL DEFAULT 5,
    assigned_to     BIGINT,
    claimed_at      TIMESTAMP,
    started_at      TIMESTAMP,
    finished_at     TIMESTAMP,
    line_count      INT          NOT NULL DEFAULT 0,
    done_count      INT          NOT NULL DEFAULT 0,
    cancelled_reason VARCHAR(128),
    version         BIGINT       NOT NULL DEFAULT 0,
    created_by      BIGINT,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_rt_code UNIQUE (code),
    CONSTRAINT ck_rt_status CHECK (status IN ('PENDING','EXECUTING','DONE','ABNORMAL','CANCELLED')),
    CONSTRAINT ck_rt_count CHECK (line_count >= 0 AND done_count >= 0 AND done_count <= line_count),
    CONSTRAINT ck_rt_claim CHECK ((assigned_to IS NULL) = (claimed_at IS NULL))
);
CREATE INDEX ix_rt_claim ON replenish_task(warehouse_id, status, zone_id) WHERE status = 'PENDING';
CREATE INDEX ix_rt_mine  ON replenish_task(assigned_to, status);

CREATE TABLE replenish_task_line (
    id                  BIGINT       PRIMARY KEY,
    task_id             BIGINT       NOT NULL REFERENCES replenish_task(id),
    seq                 SMALLINT     NOT NULL,                 -- 动线顺序
    from_location_id    BIGINT       NOT NULL REFERENCES location(id),   -- 源：存储位
    to_location_id      BIGINT       NOT NULL REFERENCES location(id),   -- 目标：拣货位
    sku_id              BIGINT       NOT NULL REFERENCES sku(id),
    lot_id              BIGINT       NOT NULL REFERENCES lot(id),
    from_stock_id       BIGINT       NOT NULL REFERENCES stock(id),      -- 源库存行
    planned_qty_milli   BIGINT       NOT NULL,
    confirmed_qty_milli BIGINT       NOT NULL DEFAULT 0,
    uom                 VARCHAR(16)  NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',         -- PENDING/DONE/ABNORMAL/CANCELLED
    abnormal_reason     VARCHAR(32),                          -- SOURCE_SHORT / LOCATION_LOCKED / TARGET_FULL
    movement_biz_no     VARCHAR(64),                          -- 第 2 篇流水 biz_no（MOVE 两腿，op_no = 1）
    moved_at            TIMESTAMP,
    moved_by            BIGINT,
    barcode_expected    VARCHAR(64),
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_rtl UNIQUE (task_id, seq),
    CONSTRAINT ck_rtl_status CHECK (status IN ('PENDING','DONE','ABNORMAL','CANCELLED')),
    CONSTRAINT ck_rtl_route CHECK (from_location_id <> to_location_id),
    CONSTRAINT ck_rtl_qty CHECK (planned_qty_milli > 0 AND confirmed_qty_milli >= 0
        AND confirmed_qty_milli <= planned_qty_milli
        AND planned_qty_milli = CAST(planned_qty_milli AS BIGINT) AND confirmed_qty_milli = CAST(confirmed_qty_milli AS BIGINT)),
    -- 记账完成 ⇔ 已有流水号与时间；异常行必须给原因
    CONSTRAINT ck_rtl_done CHECK ((status = 'DONE') = (movement_biz_no IS NOT NULL AND moved_at IS NOT NULL)),
    CONSTRAINT ck_rtl_abnormal CHECK ((status = 'ABNORMAL') = (abnormal_reason IS NOT NULL))
);
CREATE INDEX ix_rtl_task ON replenish_task_line(task_id, status);
CREATE INDEX ix_rtl_stock ON replenish_task_line(from_stock_id);

-- 任务：PENDING → EXECUTING → DONE / ABNORMAL，或 PENDING → CANCELLED；终态不可回退
CREATE FUNCTION trg_rt_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                                -- @pg-only
    IF OLD.status IN ('DONE','ABNORMAL','CANCELLED') AND NEW.status IS DISTINCT FROM OLD.status THEN                -- @pg-only
        RAISE EXCEPTION 'replenish_task_forward_only' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                          -- @pg-only
    IF OLD.status = 'PENDING' AND NEW.status NOT IN ('PENDING','EXECUTING','DONE','ABNORMAL','CANCELLED') THEN      -- @pg-only
        RAISE EXCEPTION 'replenish_task_forward_only' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                          -- @pg-only
    IF OLD.status = 'EXECUTING' AND NEW.status NOT IN ('EXECUTING','DONE','ABNORMAL','CANCELLED') THEN              -- @pg-only
        RAISE EXCEPTION 'replenish_task_forward_only' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                          -- @pg-only
    RETURN NEW;                                                                                                      -- @pg-only
END $$;                                                                                                              -- @pg-only
CREATE TRIGGER trg_rt_forward BEFORE UPDATE ON replenish_task FOR EACH ROW EXECUTE FUNCTION trg_rt_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_rt_forward BEFORE UPDATE ON replenish_task
-- @sqlite-only WHEN (OLD.status IN ('DONE','ABNORMAL','CANCELLED') AND NEW.status IS NOT OLD.status)
-- @sqlite-only   OR (OLD.status = 'PENDING' AND NEW.status NOT IN ('PENDING','EXECUTING','DONE','ABNORMAL','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'EXECUTING' AND NEW.status NOT IN ('EXECUTING','DONE','ABNORMAL','CANCELLED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'replenish_task_forward_only'); END;

-- 任务行：DONE / ABNORMAL / CANCELLED 终态；已 DONE 的行锁死路由、数量、批次与源库存行
CREATE FUNCTION trg_rtl_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                                   -- @pg-only
    IF OLD.status IN ('DONE','ABNORMAL','CANCELLED') AND NEW.status IS DISTINCT FROM OLD.status THEN                   -- @pg-only
        RAISE EXCEPTION 'replenish_line_forward_only' USING ERRCODE = '23514';                                          -- @pg-only
    END IF;                                                                                                             -- @pg-only
    IF OLD.status = 'DONE' AND (NEW.from_location_id IS DISTINCT FROM OLD.from_location_id                              -- @pg-only
        OR NEW.to_location_id IS DISTINCT FROM OLD.to_location_id                                                       -- @pg-only
        OR NEW.from_stock_id IS DISTINCT FROM OLD.from_stock_id                                                         -- @pg-only
        OR NEW.planned_qty_milli IS DISTINCT FROM OLD.planned_qty_milli                                                 -- @pg-only
        OR NEW.lot_id IS DISTINCT FROM OLD.lot_id) THEN                                                                 -- @pg-only
        RAISE EXCEPTION 'replenish_line_done_locked' USING ERRCODE = '23514';                                           -- @pg-only
    END IF;                                                                                                             -- @pg-only
    RETURN NEW;                                                                                                         -- @pg-only
END $$;                                                                                                                 -- @pg-only
CREATE TRIGGER trg_rtl_forward BEFORE UPDATE ON replenish_task_line FOR EACH ROW EXECUTE FUNCTION trg_rtl_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_rtl_forward BEFORE UPDATE ON replenish_task_line
-- @sqlite-only WHEN OLD.status IN ('DONE','ABNORMAL','CANCELLED') AND NEW.status IS NOT OLD.status
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'replenish_line_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_rtl_done_lock BEFORE UPDATE ON replenish_task_line
-- @sqlite-only WHEN OLD.status = 'DONE' AND (NEW.from_location_id IS NOT OLD.from_location_id
-- @sqlite-only        OR NEW.to_location_id IS NOT OLD.to_location_id OR NEW.from_stock_id IS NOT OLD.from_stock_id
-- @sqlite-only        OR NEW.planned_qty_milli IS NOT OLD.planned_qty_milli OR NEW.lot_id IS NOT OLD.lot_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'replenish_line_done_locked'); END;

-- -----------------------------------------------------------------------------
-- 2) 补货需求（replenish_demand）
--    来源：① 第 4 篇分配产生的 Shortage(cause=NEED_REPLENISH)（记 source_outbound_* + 轮次）
--          ② 低水位扫描（拣货位 available < location.min_level_milli 且存储位有同 SKU 货）
--          ③ 人工补单
--    一个出库行在同一 alloc_round 上只能有一条「未完结」需求 → uq_rpd_open（部分唯一索引）。
-- -----------------------------------------------------------------------------
CREATE TABLE replenish_demand (
    id                      BIGINT       PRIMARY KEY,
    code                    VARCHAR(64)  NOT NULL,
    warehouse_id            BIGINT       NOT NULL REFERENCES warehouse(id),
    work_date               DATE         NOT NULL,
    cause                   VARCHAR(24)  NOT NULL,   -- OUTBOUND_SHORTAGE / LOW_LEVEL / MANUAL
    target_location_id      BIGINT       NOT NULL REFERENCES location(id),   -- 拣货位
    sku_id                  BIGINT       NOT NULL REFERENCES sku(id),
    lot_id                  BIGINT       REFERENCES lot(id),                 -- 计划阶段未定批次时为空
    demand_qty_milli        BIGINT       NOT NULL,
    planned_qty_milli       BIGINT       NOT NULL DEFAULT 0,
    fulfilled_qty_milli     BIGINT       NOT NULL DEFAULT 0,
    status                  VARCHAR(16)  NOT NULL DEFAULT 'OPEN',            -- OPEN / PLANNED / DONE / CANCELLED
    priority                SMALLINT     NOT NULL DEFAULT 5,
    source_outbound_id      BIGINT,
    source_outbound_line_id BIGINT,
    source_alloc_round      INT,
    source_doc_no           VARCHAR(64),
    task_id                 BIGINT       REFERENCES replenish_task(id),
    task_line_id            BIGINT       REFERENCES replenish_task_line(id),
    cancelled_reason        VARCHAR(128),
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_by              BIGINT,
    created_at              TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at              TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_rpd_code UNIQUE (code),
    CONSTRAINT ck_rpd_cause CHECK (cause IN ('OUTBOUND_SHORTAGE','LOW_LEVEL','MANUAL')),
    CONSTRAINT ck_rpd_status CHECK (status IN ('OPEN','PLANNED','DONE','CANCELLED')),
    CONSTRAINT ck_rpd_qty CHECK (demand_qty_milli > 0 AND planned_qty_milli >= 0 AND fulfilled_qty_milli >= 0
        AND planned_qty_milli <= demand_qty_milli AND fulfilled_qty_milli <= demand_qty_milli
        AND demand_qty_milli = CAST(demand_qty_milli AS BIGINT) AND planned_qty_milli = CAST(planned_qty_milli AS BIGINT)
        AND fulfilled_qty_milli = CAST(fulfilled_qty_milli AS BIGINT)),
    -- 缺货来源必须带齐出库单 / 行 / 轮次；其它来源不许带
    CONSTRAINT ck_rpd_short CHECK ((cause = 'OUTBOUND_SHORTAGE')
        = (source_outbound_id IS NOT NULL AND source_outbound_line_id IS NOT NULL AND source_alloc_round IS NOT NULL)),
    -- DONE ⇔ 已满足量 ≥ 需求量（半途取消允许 fulfilled 残留）
    CONSTRAINT ck_rpd_done CHECK ((status = 'DONE') = (fulfilled_qty_milli >= demand_qty_milli)),
    -- 被任务带走的行必须记下发到哪条任务行；未带走时两列都为空
    CONSTRAINT ck_rpd_task CHECK ((task_id IS NULL) = (task_line_id IS NULL))
);
CREATE UNIQUE INDEX uq_rpd_open ON replenish_demand(source_outbound_line_id, source_alloc_round)
    WHERE cause = 'OUTBOUND_SHORTAGE' AND status IN ('OPEN','PLANNED');
CREATE INDEX ix_rpd_open ON replenish_demand(warehouse_id, status, priority, work_date);
CREATE INDEX ix_rpd_task ON replenish_demand(task_id) WHERE task_id IS NOT NULL;
CREATE INDEX ix_rpd_loc  ON replenish_demand(target_location_id, status);

-- 需求只前进：OPEN → PLANNED → DONE，或 → CANCELLED；DONE / CANCELLED 终态；已满足量单调不减
CREATE FUNCTION trg_rpd_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                                   -- @pg-only
    IF OLD.status IN ('DONE','CANCELLED') AND NEW.status IS DISTINCT FROM OLD.status THEN                               -- @pg-only
        RAISE EXCEPTION 'replenish_demand_forward_only' USING ERRCODE = '23514';                                        -- @pg-only
    END IF;                                                                                                             -- @pg-only
    IF OLD.status = 'OPEN' AND NEW.status NOT IN ('OPEN','PLANNED','DONE','CANCELLED') THEN                             -- @pg-only
        RAISE EXCEPTION 'replenish_demand_forward_only' USING ERRCODE = '23514';                                        -- @pg-only
    END IF;                                                                                                             -- @pg-only
    IF OLD.status = 'PLANNED' AND NEW.status NOT IN ('PLANNED','DONE','CANCELLED') THEN                                 -- @pg-only
        RAISE EXCEPTION 'replenish_demand_forward_only' USING ERRCODE = '23514';                                        -- @pg-only
    END IF;                                                                                                             -- @pg-only
    IF NEW.fulfilled_qty_milli < OLD.fulfilled_qty_milli THEN                                                           -- @pg-only
        RAISE EXCEPTION 'replenish_demand_forward_only' USING ERRCODE = '23514';                                        -- @pg-only
    END IF;                                                                                                             -- @pg-only
    RETURN NEW;                                                                                                         -- @pg-only
END $$;                                                                                                                 -- @pg-only
CREATE TRIGGER trg_rpd_forward BEFORE UPDATE ON replenish_demand FOR EACH ROW EXECUTE FUNCTION trg_rpd_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_rpd_forward BEFORE UPDATE ON replenish_demand
-- @sqlite-only WHEN (OLD.status IN ('DONE','CANCELLED') AND NEW.status IS NOT OLD.status)
-- @sqlite-only   OR (OLD.status = 'OPEN' AND NEW.status NOT IN ('OPEN','PLANNED','DONE','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'PLANNED' AND NEW.status NOT IN ('PLANNED','DONE','CANCELLED'))
-- @sqlite-only   OR (NEW.fulfilled_qty_milli < OLD.fulfilled_qty_milli)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'replenish_demand_forward_only'); END;

-- -----------------------------------------------------------------------------
-- 3) 独立移库单（move_order / move_order_line）
--    一次移库 = 一条移库行 = 一次 move() 两腿；不做分次执行（要分次就拆行）。
-- -----------------------------------------------------------------------------
CREATE TABLE move_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL REFERENCES warehouse(id),
    move_type       VARCHAR(24)  NOT NULL,   -- LOCATION_TRANSFER / ZONE_TRANSFER / PICK_FACE_SWAP / CONSOLIDATE
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',   -- DRAFT / CONFIRMED / CANCELLED
    reason_code     VARCHAR(24)  NOT NULL,
    remark          VARCHAR(256),
    line_count      INT          NOT NULL DEFAULT 0,
    done_count      INT          NOT NULL DEFAULT 0,
    created_by      BIGINT,
    confirmed_by    BIGINT,
    confirmed_at    TIMESTAMP,
    cancelled_reason VARCHAR(128),
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_mo_code UNIQUE (code),
    CONSTRAINT ck_mo_type CHECK (move_type IN ('LOCATION_TRANSFER','ZONE_TRANSFER','PICK_FACE_SWAP','CONSOLIDATE')),
    CONSTRAINT ck_mo_status CHECK (status IN ('DRAFT','CONFIRMED','CANCELLED')),
    CONSTRAINT ck_mo_confirm CHECK ((status = 'CONFIRMED') = (confirmed_at IS NOT NULL)),
    CONSTRAINT ck_mo_count CHECK (line_count >= 0 AND done_count >= 0 AND done_count <= line_count)
);
CREATE INDEX ix_mo_wh ON move_order(warehouse_id, status, created_at DESC);

CREATE TABLE move_order_line (
    id                BIGINT       PRIMARY KEY,
    move_order_id     BIGINT       NOT NULL REFERENCES move_order(id),
    line_no           SMALLINT     NOT NULL,
    from_location_id  BIGINT       NOT NULL REFERENCES location(id),
    to_location_id    BIGINT       NOT NULL REFERENCES location(id),
    sku_id            BIGINT       NOT NULL REFERENCES sku(id),
    lot_id            BIGINT       NOT NULL REFERENCES lot(id),
    from_stock_id     BIGINT       NOT NULL REFERENCES stock(id),
    qty_milli         BIGINT       NOT NULL,
    uom               VARCHAR(16)  NOT NULL,
    status            VARCHAR(16)  NOT NULL DEFAULT 'PENDING',   -- PENDING / DONE / CANCELLED
    movement_biz_no   VARCHAR(64),
    moved_at          TIMESTAMP,
    moved_by          BIGINT,
    version           BIGINT       NOT NULL DEFAULT 0,
    created_at        TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at        TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_mol UNIQUE (move_order_id, line_no),
    CONSTRAINT ck_mol_status CHECK (status IN ('PENDING','DONE','CANCELLED')),
    CONSTRAINT ck_mol_route CHECK (from_location_id <> to_location_id),
    CONSTRAINT ck_mol_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_mol_done CHECK ((status = 'DONE') = (moved_at IS NOT NULL AND movement_biz_no IS NOT NULL))
);
CREATE INDEX ix_mol_order ON move_order_line(move_order_id, status);
CREATE INDEX ix_mol_stock ON move_order_line(from_stock_id);

-- 移库单只前进：DRAFT → CONFIRMED（终态）/ CANCELLED（终态）
CREATE FUNCTION trg_mo_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                                 -- @pg-only
    IF OLD.status <> 'DRAFT' AND NEW.status IS DISTINCT FROM OLD.status THEN                                          -- @pg-only
        RAISE EXCEPTION 'move_order_forward_only' USING ERRCODE = '23514';                                            -- @pg-only
    END IF;                                                                                                           -- @pg-only
    RETURN NEW;                                                                                                       -- @pg-only
END $$;                                                                                                               -- @pg-only
CREATE TRIGGER trg_mo_forward BEFORE UPDATE ON move_order FOR EACH ROW EXECUTE FUNCTION trg_mo_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mo_forward BEFORE UPDATE ON move_order
-- @sqlite-only WHEN OLD.status <> 'DRAFT' AND NEW.status IS NOT OLD.status
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'move_order_forward_only'); END;

-- 移库行：DONE / CANCELLED 终态；已 DONE 的行锁死路由与数量
CREATE FUNCTION trg_mol_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                                   -- @pg-only
    IF OLD.status IN ('DONE','CANCELLED') AND NEW.status IS DISTINCT FROM OLD.status THEN                               -- @pg-only
        RAISE EXCEPTION 'move_line_forward_only' USING ERRCODE = '23514';                                               -- @pg-only
    END IF;                                                                                                             -- @pg-only
    IF OLD.status = 'DONE' AND (NEW.from_location_id IS DISTINCT FROM OLD.from_location_id                             -- @pg-only
        OR NEW.to_location_id IS DISTINCT FROM OLD.to_location_id                                                       -- @pg-only
        OR NEW.qty_milli IS DISTINCT FROM OLD.qty_milli                                                                 -- @pg-only
        OR NEW.from_stock_id IS DISTINCT FROM OLD.from_stock_id) THEN                                                   -- @pg-only
        RAISE EXCEPTION 'move_line_done_locked' USING ERRCODE = '23514';                                                -- @pg-only
    END IF;                                                                                                             -- @pg-only
    RETURN NEW;                                                                                                         -- @pg-only
END $$;                                                                                                                 -- @pg-only
CREATE TRIGGER trg_mol_forward BEFORE UPDATE ON move_order_line FOR EACH ROW EXECUTE FUNCTION trg_mol_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mol_forward BEFORE UPDATE ON move_order_line
-- @sqlite-only WHEN OLD.status IN ('DONE','CANCELLED') AND NEW.status IS NOT OLD.status
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'move_line_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_mol_done_lock BEFORE UPDATE ON move_order_line
-- @sqlite-only WHEN OLD.status = 'DONE' AND (NEW.from_location_id IS NOT OLD.from_location_id
-- @sqlite-only        OR NEW.to_location_id IS NOT OLD.to_location_id OR NEW.qty_milli IS NOT OLD.qty_milli
-- @sqlite-only        OR NEW.from_stock_id IS NOT OLD.from_stock_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'move_line_done_locked'); END;

-- -----------------------------------------------------------------------------
-- 4) 上架 / 补货共用的库位候选视图（03 篇只留三条约束，算法在第 7 篇）
--    硬约束（都在这个视图里）：温区一致、库位未锁定（status='AVAILABLE'）、未软删、SKU 在售、
--    mix_sku=false 时库位里不能有别的 SKU。max_lots 用 has_lot_slot 交给调用方按「本次批次」判定。
-- -----------------------------------------------------------------------------
CREATE VIEW v_location_sku_candidate AS
SELECT
    l.warehouse_id,
    l.id            AS location_id,
    l.code          AS location_code,
    l.zone_id,
    z.temp_zone,
    z.zone_type,
    l.location_type,
    l.pickable,
    l.max_lots,
    l.mix_sku,
    l.pick_sequence,
    k.id            AS sku_id,
    k.temperature_required,
    COALESCE(o.lot_cnt, 0)            AS lot_cnt,
    COALESCE(o.sku_cnt, 0)            AS sku_cnt,
    COALESCE(o.on_hand_qty_milli, 0)  AS on_hand_qty_milli,
    CASE WHEN EXISTS (SELECT 1 FROM stock s2 WHERE s2.location_id = l.id AND s2.sku_id = k.id AND s2.on_hand_qty_milli > 0)
         THEN 1 ELSE 0 END            AS has_same_sku,
    CASE WHEN COALESCE(o.lot_cnt, 0) < l.max_lots THEN 1 ELSE 0 END  AS has_lot_slot
FROM location l
JOIN zone z ON z.id = l.zone_id
JOIN sku  k ON k.temperature_required = z.temp_zone AND k.status = 'ACTIVE'
LEFT JOIN (
    SELECT location_id,
           COUNT(DISTINCT lot_id) AS lot_cnt,
           COUNT(DISTINCT sku_id) AS sku_cnt,
           SUM(on_hand_qty_milli) AS on_hand_qty_milli
    FROM stock WHERE on_hand_qty_milli > 0 GROUP BY location_id
) o ON o.location_id = l.id
WHERE l.status = 'AVAILABLE' AND l.deleted_at IS NULL
  AND (l.mix_sku = true OR COALESCE(o.sku_cnt, 0) = 0
       OR EXISTS (SELECT 1 FROM stock s3 WHERE s3.location_id = l.id AND s3.sku_id = k.id AND s3.on_hand_qty_milli > 0));
-- FEFO / 动线排序在应用层（domain/location_pick.py），视图只负责硬约束与统计
GRANT SELECT ON v_location_sku_candidate TO wms_app;  -- @pg-only

-- -----------------------------------------------------------------------------
-- 5) SQLite 防 REPLACE（00 §6.10）：本篇五张表的每一个唯一键都要有守卫
-- -----------------------------------------------------------------------------
-- @sqlite-only CREATE TRIGGER trg_rt_no_replace_id BEFORE INSERT ON replenish_task WHEN EXISTS (SELECT 1 FROM replenish_task x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'replenish_task_duplicate: replenish_task.id'); END;
-- @sqlite-only CREATE TRIGGER trg_rt_no_replace_code BEFORE INSERT ON replenish_task WHEN EXISTS (SELECT 1 FROM replenish_task x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'replenish_task_duplicate: replenish_task.code'); END;
-- @sqlite-only CREATE TRIGGER trg_rtl_no_replace_id BEFORE INSERT ON replenish_task_line WHEN EXISTS (SELECT 1 FROM replenish_task_line x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'replenish_task_line_duplicate: replenish_task_line.id'); END;
-- @sqlite-only CREATE TRIGGER trg_rtl_no_replace_seq BEFORE INSERT ON replenish_task_line WHEN EXISTS (SELECT 1 FROM replenish_task_line x WHERE x.task_id = NEW.task_id AND x.seq = NEW.seq) BEGIN SELECT RAISE(ABORT, 'replenish_task_line_duplicate: replenish_task_line.task_id, replenish_task_line.seq'); END;
-- @sqlite-only CREATE TRIGGER trg_rpd_no_replace_id BEFORE INSERT ON replenish_demand WHEN EXISTS (SELECT 1 FROM replenish_demand x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'replenish_demand_duplicate: replenish_demand.id'); END;
-- @sqlite-only CREATE TRIGGER trg_rpd_no_replace_code BEFORE INSERT ON replenish_demand WHEN EXISTS (SELECT 1 FROM replenish_demand x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'replenish_demand_duplicate: replenish_demand.code'); END;
-- @sqlite-only CREATE TRIGGER trg_rpd_no_replace_open BEFORE INSERT ON replenish_demand WHEN EXISTS (SELECT 1 FROM replenish_demand x WHERE x.source_outbound_line_id = NEW.source_outbound_line_id AND x.source_alloc_round = NEW.source_alloc_round AND (x.cause = 'OUTBOUND_SHORTAGE' AND x.status IN ('OPEN','PLANNED')) AND (NEW.cause = 'OUTBOUND_SHORTAGE' AND NEW.status IN ('OPEN','PLANNED'))) BEGIN SELECT RAISE(ABORT, 'replenish_demand_duplicate: replenish_demand.source_outbound_line_id, replenish_demand.source_alloc_round'); END;
-- @sqlite-only CREATE TRIGGER trg_mo_no_replace_id BEFORE INSERT ON move_order WHEN EXISTS (SELECT 1 FROM move_order x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'move_order_duplicate: move_order.id'); END;
-- @sqlite-only CREATE TRIGGER trg_mo_no_replace_code BEFORE INSERT ON move_order WHEN EXISTS (SELECT 1 FROM move_order x WHERE x.code = NEW.code) BEGIN SELECT RAISE(ABORT, 'move_order_duplicate: move_order.code'); END;
-- @sqlite-only CREATE TRIGGER trg_mol_no_replace_id BEFORE INSERT ON move_order_line WHEN EXISTS (SELECT 1 FROM move_order_line x WHERE x.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'move_order_line_duplicate: move_order_line.id'); END;
-- @sqlite-only CREATE TRIGGER trg_mol_no_replace_line BEFORE INSERT ON move_order_line WHEN EXISTS (SELECT 1 FROM move_order_line x WHERE x.move_order_id = NEW.move_order_id AND x.line_no = NEW.line_no) BEGIN SELECT RAISE(ABORT, 'move_order_line_duplicate: move_order_line.move_order_id, move_order_line.line_no'); END;

GRANT SELECT, INSERT, UPDATE ON replenish_task, replenish_task_line, replenish_demand, move_order, move_order_line TO wms_app;  -- @pg-only
