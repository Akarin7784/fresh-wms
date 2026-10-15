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
    updated_at              TIMESTAMP NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT ck_slp_bp CHECK (weigh_tolerance_bp BETWEEN 0 AND 10000 AND death_rate_threshold_bp BETWEEN 0 AND 10000 AND shrink_tolerance_bp BETWEEN 0 AND 10000)
-- @sqlite-only     , CONSTRAINT ck_slp_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE FUNCTION trg_slp_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                     -- @pg-only
    IF TG_OP = 'DELETE' OR (NEW.sku_id <> OLD.sku_id) THEN RAISE EXCEPTION 'slp_immutable'; END IF;  -- @pg-only
    RETURN NEW;                                                                           -- @pg-only
END $$;                                                                                   -- @pg-only
CREATE TRIGGER trg_slp_guard BEFORE UPDATE OR DELETE ON sku_live_param FOR EACH ROW EXECUTE FUNCTION trg_slp_guard();  -- @pg-only
CREATE TRIGGER trg_slp_no_truncate BEFORE TRUNCATE ON sku_live_param FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_slp_upd BEFORE UPDATE ON sku_live_param WHEN NEW.sku_id <> OLD.sku_id BEGIN SELECT RAISE(ABORT, 'slp_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_slp_del BEFORE DELETE ON sku_live_param BEGIN SELECT RAISE(ABORT, 'slp_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_slp_dup BEFORE INSERT ON sku_live_param
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sku_live_param x WHERE x.sku_id = NEW.sku_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'slp_duplicate'); END;

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
    updated_at              TIMESTAMP NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT ck_lt_status CHECK (status IN ('ACTIVE','DISABLED')),
    CONSTRAINT ck_lt_volume CHECK (water_volume_l > 0),
    CONSTRAINT ck_lt_temp CHECK (temp_severe_min_c10 <= temp_min_c10 AND temp_min_c10 < temp_max_c10 AND temp_max_c10 <= temp_severe_max_c10),
    CONSTRAINT ck_lt_do CHECK (do_severe_min_x100 >= 0 AND do_severe_min_x100 <= do_min_x100),
    CONSTRAINT ck_lt_ph CHECK (ph_min_x100 >= 0 AND ph_min_x100 < ph_max_x100 AND ph_max_x100 <= 1400),
    CONSTRAINT ck_lt_interval CHECK (inspect_interval_min BETWEEN 10 AND 1440),
    CONSTRAINT fk_lt_location FOREIGN KEY (location_id) REFERENCES location(id),
    CONSTRAINT fk_lt_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT fk_lt_sku FOREIGN KEY (sku_id) REFERENCES sku(id)
-- @sqlite-only     , CONSTRAINT ck_lt_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE FUNCTION trg_lt_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                     -- @pg-only
    IF TG_OP = 'DELETE' OR (NEW.location_id <> OLD.location_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.sku_id <> OLD.sku_id) THEN RAISE EXCEPTION 'lt_immutable'; END IF;  -- @pg-only
    RETURN NEW;                                                                           -- @pg-only
END $$;                                                                                   -- @pg-only
CREATE TRIGGER trg_lt_guard BEFORE UPDATE OR DELETE ON live_tank FOR EACH ROW EXECUTE FUNCTION trg_lt_guard();  -- @pg-only
CREATE TRIGGER trg_lt_no_truncate BEFORE TRUNCATE ON live_tank FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lt_upd BEFORE UPDATE ON live_tank WHEN NEW.location_id <> OLD.location_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.sku_id <> OLD.sku_id BEGIN SELECT RAISE(ABORT, 'lt_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_lt_del BEFORE DELETE ON live_tank BEGIN SELECT RAISE(ABORT, 'lt_immutable'); END;
CREATE FUNCTION trg_lt_type() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                       -- @pg-only
BEGIN                                                                                       -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM location l WHERE l.id = NEW.location_id AND l.location_type = 'LIVE_TANK' AND l.warehouse_id = NEW.warehouse_id)  -- @pg-only
    THEN RAISE EXCEPTION 'lt_not_live_tank'; END IF;                                        -- @pg-only
    RETURN NEW;                                                                             -- @pg-only
END $$;                                                                                     -- @pg-only
CREATE TRIGGER trg_lt_type BEFORE INSERT ON live_tank FOR EACH ROW EXECUTE FUNCTION trg_lt_type();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lt_type BEFORE INSERT ON live_tank WHEN NOT EXISTS (SELECT 1 FROM location l WHERE l.id = NEW.location_id AND l.location_type = 'LIVE_TANK' AND l.warehouse_id = NEW.warehouse_id) BEGIN SELECT RAISE(ABORT, 'lt_not_live_tank'); END;
-- @sqlite-only CREATE TRIGGER trg_lt_dup BEFORE INSERT ON live_tank
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_tank x WHERE x.location_id = NEW.location_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'lt_duplicate'); END;

-- 尾数余额（PM 1）：与 stock 行 1:1；重量仍在 stock.on_hand_qty_milli（第 2 篇），这里只存只数
-- count > 0 ⇒ 对应 stock 重量 > 0（触发器；第 2 篇改重量时由巡检 LIVE_COUNT_WEIGHT 兜底）
CREATE TABLE live_stock_count (
    stock_id        BIGINT   PRIMARY KEY,
    location_id     BIGINT   NOT NULL,
    lot_id          BIGINT   NOT NULL,
    on_hand_count   BIGINT   NOT NULL DEFAULT 0,
    version         INT      NOT NULL DEFAULT 0,
    updated_at      TIMESTAMP NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT ck_lsc_count CHECK (on_hand_count >= 0),
    CONSTRAINT fk_lsc_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_lsc_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lsc_lot FOREIGN KEY (lot_id) REFERENCES lot(id)
-- @sqlite-only     , CONSTRAINT ck_lsc_ts CHECK ((typeof(updated_at) = 'text' AND length(updated_at) = 19 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(updated_at) = substr(updated_at, 1, 10) AND time(updated_at) = substr(updated_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE FUNCTION trg_lsc_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                     -- @pg-only
BEGIN                                                                                       -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'lsc_immutable'; END IF;                       -- @pg-only
    IF TG_OP = 'UPDATE' AND (NEW.stock_id <> OLD.stock_id OR NEW.location_id <> OLD.location_id OR NEW.lot_id <> OLD.lot_id)  -- @pg-only
    THEN RAISE EXCEPTION 'lsc_immutable'; END IF;                                           -- @pg-only
    IF NEW.on_hand_count > 0 AND COALESCE((SELECT on_hand_qty_milli FROM stock WHERE id = NEW.stock_id), 0) <= 0  -- @pg-only
    THEN RAISE EXCEPTION 'live_count_without_weight'; END IF;                               -- @pg-only
    RETURN NEW;                                                                             -- @pg-only
END $$;                                                                                     -- @pg-only
CREATE TRIGGER trg_lsc_guard BEFORE INSERT OR UPDATE OR DELETE ON live_stock_count FOR EACH ROW EXECUTE FUNCTION trg_lsc_guard();  -- @pg-only
CREATE TRIGGER trg_lsc_no_truncate BEFORE TRUNCATE ON live_stock_count FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lsc_upd BEFORE UPDATE ON live_stock_count WHEN NEW.stock_id <> OLD.stock_id OR NEW.location_id <> OLD.location_id OR NEW.lot_id <> OLD.lot_id BEGIN SELECT RAISE(ABORT, 'lsc_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_lsc_del BEFORE DELETE ON live_stock_count BEGIN SELECT RAISE(ABORT, 'lsc_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_lsc_dup BEFORE INSERT ON live_stock_count WHEN EXISTS (SELECT 1 FROM live_stock_count x WHERE x.stock_id = NEW.stock_id) BEGIN SELECT RAISE(ABORT, 'lsc_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_lsc_w_ins BEFORE INSERT ON live_stock_count WHEN NEW.on_hand_count > 0 AND COALESCE((SELECT on_hand_qty_milli FROM stock WHERE id = NEW.stock_id), 0) <= 0 BEGIN SELECT RAISE(ABORT, 'live_count_without_weight'); END;
-- @sqlite-only CREATE TRIGGER trg_lsc_w_upd BEFORE UPDATE ON live_stock_count WHEN NEW.on_hand_count > 0 AND COALESCE((SELECT on_hand_qty_milli FROM stock WHERE id = NEW.stock_id), 0) <= 0 BEGIN SELECT RAISE(ABORT, 'live_count_without_weight'); END;

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
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_lcl_biz UNIQUE (biz_type, biz_no, line_no, stock_id),
    CONSTRAINT ck_lcl_type CHECK (biz_type IN ('RECEIVE','WEIGH_OUT','DEATH','COUNT_ADJ','MOVE_IN','MOVE_OUT','PROCESS_OUT')),
    CONSTRAINT ck_lcl_math CHECK (delta_count <> 0 AND count_before >= 0 AND count_after >= 0 AND count_after = count_before + delta_count),
    CONSTRAINT fk_lcl_count FOREIGN KEY (stock_id) REFERENCES live_stock_count(stock_id),
    CONSTRAINT fk_lcl_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id)   -- stock_movement 是分区表，主键含 occurred_at，挂在 1:1 的 key 表上
-- @sqlite-only     , CONSTRAINT ck_lcl_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lcl_append_only BEFORE UPDATE OR DELETE ON live_count_ledger FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_lcl_no_truncate BEFORE TRUNCATE ON live_count_ledger FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lcl_upd BEFORE UPDATE ON live_count_ledger BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lcl_del BEFORE DELETE ON live_count_ledger BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lcl_dup BEFORE INSERT ON live_count_ledger
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_count_ledger x WHERE x.id = NEW.id OR (x.biz_type = NEW.biz_type AND x.biz_no = NEW.biz_no AND x.line_no = NEW.line_no AND x.stock_id = NEW.stock_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'lcl_duplicate'); END;

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
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_li_op UNIQUE (device_instance_id, client_op_id),
    CONSTRAINT ck_li_result CHECK (result IN ('NORMAL','ALARM','SEVERE')),
    CONSTRAINT ck_li_breach CHECK ((result = 'NORMAL' AND consecutive_breach = 0) OR (result <> 'NORMAL' AND consecutive_breach >= 1)),
    CONSTRAINT ck_li_range CHECK (do_x100 >= 0 AND ph_x100 BETWEEN 0 AND 1400),
    CONSTRAINT fk_li_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_li_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouse(id)
-- @sqlite-only     , CONSTRAINT ck_li_ts CHECK ((typeof(inspected_at) = 'text' AND length(inspected_at) = 19 AND inspected_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(inspected_at) = substr(inspected_at, 1, 10) AND time(inspected_at) = substr(inspected_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
-- @sqlite-only     , CONSTRAINT ck_li_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE INDEX ix_li_tank ON live_inspection(location_id, inspected_at);
CREATE TRIGGER trg_li_append_only BEFORE UPDATE OR DELETE ON live_inspection FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_li_no_truncate BEFORE TRUNCATE ON live_inspection FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_li_upd BEFORE UPDATE ON live_inspection BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_li_del BEFORE DELETE ON live_inspection BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_li_dup BEFORE INSERT ON live_inspection
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_inspection x WHERE x.id = NEW.id OR (x.device_instance_id = NEW.device_instance_id AND x.client_op_id = NEW.client_op_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'li_duplicate'); END;

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
    created_at              TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT ck_lth_reason CHECK (reason IN ('CONSECUTIVE_BREACH','SEVERE')),
    CONSTRAINT ck_lth_status CHECK (status IN ('ACTIVE','RELEASED')),
    CONSTRAINT ck_lth_release CHECK ((status = 'ACTIVE' AND release_inspection_id IS NULL AND released_at IS NULL)
                                  OR (status = 'RELEASED' AND release_inspection_id IS NOT NULL AND released_at IS NOT NULL)),
    CONSTRAINT fk_lth_tank FOREIGN KEY (location_id) REFERENCES live_tank(location_id),
    CONSTRAINT fk_lth_trigger FOREIGN KEY (trigger_inspection_id) REFERENCES live_inspection(id),
    CONSTRAINT fk_lth_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- 03 R3：补外键（小玛丽 r12）
    CONSTRAINT fk_lth_release FOREIGN KEY (release_inspection_id) REFERENCES live_inspection(id)
-- @sqlite-only     , CONSTRAINT ck_lth_ts CHECK ((released_at IS NULL OR (typeof(released_at) = 'text' AND length(released_at) = 19 AND released_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(released_at) = substr(released_at, 1, 10) AND time(released_at) = substr(released_at, 12, 8))) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE UNIQUE INDEX uq_lth_active ON live_tank_hold(location_id) WHERE status = 'ACTIVE';
CREATE FUNCTION trg_lth_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                     -- @pg-only
BEGIN                                                                                       -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                -- @pg-only
        IF NEW.status <> 'ACTIVE' THEN RAISE EXCEPTION 'lth_state'; END IF; RETURN NEW;    -- @pg-only
    END IF;                                                                                 -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'lth_immutable'; END IF;                       -- @pg-only
    IF OLD.status <> 'ACTIVE' THEN RAISE EXCEPTION 'lth_closed'; END IF;                    -- @pg-only
    IF NEW.location_id <> OLD.location_id OR NEW.reason <> OLD.reason OR NEW.trigger_inspection_id <> OLD.trigger_inspection_id  -- @pg-only
       OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.created_at <> OLD.created_at THEN RAISE EXCEPTION 'lth_immutable'; END IF;  -- @pg-only
    IF NEW.status = 'RELEASED' AND NOT EXISTS (SELECT 1 FROM live_inspection i WHERE i.id = NEW.release_inspection_id  -- @pg-only
       AND i.location_id = NEW.location_id AND i.is_recheck AND i.result = 'NORMAL') THEN RAISE EXCEPTION 'lth_recheck_required'; END IF;  -- @pg-only
    RETURN NEW;                                                                             -- @pg-only
END $$;                                                                                     -- @pg-only
CREATE TRIGGER trg_lth_guard BEFORE INSERT OR UPDATE OR DELETE ON live_tank_hold FOR EACH ROW EXECUTE FUNCTION trg_lth_guard();  -- @pg-only
CREATE TRIGGER trg_lth_no_truncate BEFORE TRUNCATE ON live_tank_hold FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lth_ins BEFORE INSERT ON live_tank_hold WHEN NEW.status <> 'ACTIVE' BEGIN SELECT RAISE(ABORT, 'lth_state'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_closed BEFORE UPDATE ON live_tank_hold WHEN OLD.status <> 'ACTIVE' BEGIN SELECT RAISE(ABORT, 'lth_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_upd BEFORE UPDATE ON live_tank_hold WHEN OLD.status = 'ACTIVE' AND (NEW.location_id <> OLD.location_id OR NEW.reason <> OLD.reason OR NEW.trigger_inspection_id <> OLD.trigger_inspection_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.created_at <> OLD.created_at) BEGIN SELECT RAISE(ABORT, 'lth_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_rel BEFORE UPDATE OF status ON live_tank_hold WHEN OLD.status = 'ACTIVE' AND NEW.status = 'RELEASED' AND NOT EXISTS (SELECT 1 FROM live_inspection i WHERE i.id = NEW.release_inspection_id AND i.location_id = NEW.location_id AND i.is_recheck AND i.result = 'NORMAL') BEGIN SELECT RAISE(ABORT, 'lth_recheck_required'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_del BEFORE DELETE ON live_tank_hold BEGIN SELECT RAISE(ABORT, 'lth_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_dup BEFORE INSERT ON live_tank_hold WHEN EXISTS (SELECT 1 FROM live_tank_hold x WHERE x.id = NEW.id OR (x.location_id = NEW.location_id AND x.status = 'ACTIVE')) BEGIN SELECT RAISE(ABORT, 'lth_duplicate'); END;

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
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
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
-- @sqlite-only     , CONSTRAINT ck_lw_ts CHECK ((typeof(weighed_at) = 'text' AND length(weighed_at) = 19 AND weighed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(weighed_at) = substr(weighed_at, 1, 10) AND time(weighed_at) = substr(weighed_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
-- @sqlite-only     , CONSTRAINT ck_lw_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE UNIQUE INDEX uq_lw_key ON live_weigh(task_kind, task_id, weigh_client_id) WHERE result = 'ACCEPTED';
CREATE TRIGGER trg_lw_append_only BEFORE UPDATE OR DELETE ON live_weigh FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_lw_no_truncate BEFORE TRUNCATE ON live_weigh FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lw_upd BEFORE UPDATE ON live_weigh BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lw_del BEFORE DELETE ON live_weigh BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lw_dup BEFORE INSERT ON live_weigh
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_weigh x WHERE x.id = NEW.id OR (NEW.result = 'ACCEPTED' AND x.result = 'ACCEPTED' AND x.task_kind = NEW.task_kind AND x.task_id = NEW.task_id AND x.weigh_client_id = NEW.weigh_client_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'lw_duplicate'); END;

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
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_ld_op UNIQUE (device_instance_id, client_op_id),
-- @sqlite-only     CONSTRAINT ck_ld_date CHECK (typeof(work_date) = 'text' AND length(work_date) = 10 AND date(work_date) IS work_date),
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
-- @sqlite-only     , CONSTRAINT ck_ld_ts CHECK ((typeof(reported_at) = 'text' AND length(reported_at) = 19 AND reported_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(reported_at) = substr(reported_at, 1, 10) AND time(reported_at) = substr(reported_at, 12, 8)) AND (typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
-- @sqlite-only     , CONSTRAINT ck_ld_cts CHECK (client_occurred_at IS NULL OR (typeof(client_occurred_at) = 'text' AND length(client_occurred_at) = 19 AND datetime(client_occurred_at) IS client_occurred_at))
);
CREATE INDEX ix_ld_tank_day ON live_death(location_id, work_date);   -- 日死亡率
CREATE INDEX ix_ld_pending ON live_death(deduct_status) WHERE deduct_status <> 'DEDUCTED';   -- 补扣作业 / 在途对账
-- 只追加，唯一例外：写节点恢复后补扣，PENDING → DEDUCTED / EXCEPTION，只改 deduct_status、movement_id、deducted_qty_milli、exception_key
CREATE FUNCTION trg_ld_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                     -- @pg-only
BEGIN                                                                                                       -- @pg-only
    IF TG_OP = 'UPDATE' AND OLD.deduct_status = 'PENDING' AND NEW.deduct_status IN ('DEDUCTED', 'EXCEPTION')   -- @pg-only
       AND (to_jsonb(NEW) - 'deduct_status' - 'movement_id' - 'exception_key' - 'deducted_qty_milli')                  -- @pg-only
         = (to_jsonb(OLD) - 'deduct_status' - 'movement_id' - 'exception_key' - 'deducted_qty_milli') THEN             -- @pg-only
        RETURN NEW;                                                                                         -- @pg-only
    END IF;                                                                                                 -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                      -- @pg-only
END $$;                                                                                                     -- @pg-only
CREATE TRIGGER trg_ld_append_only BEFORE UPDATE OR DELETE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_ld_guard();  -- @pg-only
CREATE TRIGGER trg_ld_no_truncate BEFORE TRUNCATE ON live_death FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_ld_upd BEFORE UPDATE ON live_death WHEN NOT (OLD.deduct_status = 'PENDING' AND NEW.deduct_status IN ('DEDUCTED', 'EXCEPTION') AND NEW.id IS OLD.id AND NEW.warehouse_id IS OLD.warehouse_id AND NEW.location_id IS OLD.location_id AND NEW.stock_id IS OLD.stock_id AND NEW.lot_id IS OLD.lot_id AND NEW.work_date IS OLD.work_date AND NEW.device_instance_id IS OLD.device_instance_id AND NEW.client_op_id IS OLD.client_op_id AND NEW.death_count IS OLD.death_count AND NEW.death_qty_milli IS OLD.death_qty_milli AND NEW.day_rate_bp IS OLD.day_rate_bp AND NEW.approval_no IS OLD.approval_no AND NEW.scrap_order_id IS OLD.scrap_order_id AND NEW.reported_by IS OLD.reported_by AND NEW.reported_at IS OLD.reported_at AND NEW.created_at IS OLD.created_at) BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_ld_del BEFORE DELETE ON live_death BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_ld_dup BEFORE INSERT ON live_death
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_death x WHERE x.id = NEW.id OR (x.device_instance_id = NEW.device_instance_id AND x.client_op_id = NEW.client_op_id) OR x.movement_id = NEW.movement_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ld_duplicate'); END;

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
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
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
-- @sqlite-only     , CONSTRAINT ck_lss_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8)))   -- 时间列格式（小赵 S1 口径）
);
CREATE TRIGGER trg_lss_append_only BEFORE UPDATE OR DELETE ON live_shrink_settlement FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_lss_no_truncate BEFORE TRUNCATE ON live_shrink_settlement FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_lss_upd BEFORE UPDATE ON live_shrink_settlement BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lss_del BEFORE DELETE ON live_shrink_settlement BEGIN SELECT RAISE(ABORT, 'append_only'); END;
-- @sqlite-only CREATE TRIGGER trg_lss_dup BEFORE INSERT ON live_shrink_settlement
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM live_shrink_settlement x WHERE x.id = NEW.id OR (x.location_id = NEW.location_id AND x.lot_id = NEW.lot_id AND x.work_date = NEW.work_date) OR x.movement_id = NEW.movement_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'lss_duplicate'); END;

-- 时间约定（00 §6.8，小玛丽 time-scan 18-1）：巡检 / 称重 / 死亡上报 / 释放时间是服务端时间。PG 非属主写入一律改成库时钟 UTC 整秒（属主豁免：种子 / 迁移）；
-- SQLite 不能改 NEW，只收 now ±300s（strftime 为 NULL 也算 live_clock_skew）。触发器名带 z：排在本篇业务守卫之后
CREATE FUNCTION trg_live_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');  -- @pg-only
BEGIN  -- @pg-only
    IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'live_inspection' THEN IF NEW.inspected_at IS NULL THEN RAISE EXCEPTION 'live_clock_skew: 40003 CLIENT_TIME_INVALID explicit NULL' USING ERRCODE = '23514'; END IF;  -- 显式 NULL 拒绝，不传列走 DEFAULT  -- @pg-only
    ELSIF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'live_weigh' THEN IF NEW.weighed_at IS NULL THEN RAISE EXCEPTION 'live_clock_skew: 40003 CLIENT_TIME_INVALID explicit NULL' USING ERRCODE = '23514'; END IF;  -- @pg-only
    ELSIF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'live_death' THEN IF NEW.reported_at IS NULL THEN RAISE EXCEPTION 'live_clock_skew: 40003 CLIENT_TIME_INVALID explicit NULL' USING ERRCODE = '23514'; END IF;  -- @pg-only
    END IF;  -- @pg-only
    IF current_user IS NOT DISTINCT FROM (SELECT r.rolname FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid WHERE c.oid = TG_RELID) THEN  -- @pg-only
        RETURN NEW;  -- @pg-only
    END IF;  -- @pg-only
    IF TG_TABLE_NAME = 'live_inspection' THEN NEW.inspected_at := t;  -- @pg-only
    ELSIF TG_TABLE_NAME = 'live_weigh' THEN NEW.weighed_at := t;  -- @pg-only
    ELSIF TG_TABLE_NAME = 'live_death' THEN NEW.reported_at := t;  -- @pg-only
    ELSIF TG_TABLE_NAME = 'live_tank_hold' AND NEW.released_at IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.released_at IS NULL) THEN NEW.released_at := t;  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_li_zclock BEFORE INSERT ON live_inspection FOR EACH ROW EXECUTE FUNCTION trg_live_zclock();  -- @pg-only
CREATE TRIGGER trg_lw_zclock BEFORE INSERT ON live_weigh FOR EACH ROW EXECUTE FUNCTION trg_live_zclock();  -- @pg-only
CREATE TRIGGER trg_ld_zclock BEFORE INSERT ON live_death FOR EACH ROW EXECUTE FUNCTION trg_live_zclock();  -- @pg-only
CREATE TRIGGER trg_lth_zclock BEFORE INSERT OR UPDATE ON live_tank_hold FOR EACH ROW EXECUTE FUNCTION trg_live_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_li_zclock BEFORE INSERT ON live_inspection WHEN (strftime('%s', NEW.inspected_at) IS NULL OR substr(NEW.inspected_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.inspected_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID inspected_at'); END;
-- @sqlite-only CREATE TRIGGER trg_lw_zclock BEFORE INSERT ON live_weigh WHEN (strftime('%s', NEW.weighed_at) IS NULL OR substr(NEW.weighed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.weighed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID weighed_at'); END;
-- @sqlite-only CREATE TRIGGER trg_ld_zclock BEFORE INSERT ON live_death WHEN (strftime('%s', NEW.reported_at) IS NULL OR substr(NEW.reported_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.reported_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID reported_at'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_zclock BEFORE UPDATE ON live_tank_hold WHEN NEW.released_at IS NOT NULL AND OLD.released_at IS NULL AND (strftime('%s', NEW.released_at) IS NULL OR substr(NEW.released_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.released_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID released_at'); END;
-- @sqlite-only CREATE TRIGGER trg_lth_zclock_ins BEFORE INSERT ON live_tank_hold WHEN NEW.released_at IS NOT NULL AND (strftime('%s', NEW.released_at) IS NULL OR substr(NEW.released_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.released_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'live_clock_skew: 40003 CLIENT_TIME_INVALID released_at'); END;
GRANT SELECT, INSERT, UPDATE ON sku_live_param, live_tank, live_stock_count TO wms_app;             -- @pg-only
GRANT SELECT, INSERT ON live_count_ledger, live_inspection, live_weigh, live_death, live_shrink_settlement TO wms_app;  -- 只追加 -- @pg-only
GRANT UPDATE (deduct_status, movement_id, deducted_qty_milli, exception_key) ON live_death TO wms_app;   -- 只用于补扣，触发器再限转移 -- @pg-only
GRANT SELECT, INSERT ON live_tank_hold TO wms_app;                                                  -- @pg-only
GRANT UPDATE (status, release_inspection_id, released_at) ON live_tank_hold TO wms_app;            -- 只允许系统释放 -- @pg-only

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
GRANT SELECT ON v_live_death_in_transit TO wms_app;  -- @pg-only

-- 补扣参考实现（§7.2 / §8，PG）：写节点恢复后每条 PENDING 一个事务调一次。
-- 锁序 live_death 行 → stock 行 → stock_hold 明细；锁到 live_death 后先复查 PENDING，不是就返回 EXISTING:{状态}，不碰库存、不开异常单。
-- 锁池中（有 HELD 的 LIVE_HOLD）走 consume_live_hold 写法，流水挂 hold_id；未锁池走 post_out(SCRAP) 写法，流水 hold_id 为空。
-- 02 五轮口径：同一 idempotency_key（LD-{id}:1:D1:1）已有流水就直接返回 EXISTING_MOVEMENT:{状态}，不再进库存。
-- 返回 WON:{已扣}:{差额}:{sku_id}；差额 > 0 时调用方在同事务按 10 篇开异常单（source_type=LIVE_DEATH，键 LDTH:{id}，sku_id = 返回的 sku）。
-- 最后的条件 UPDATE 是第二道保险：0 行即 RAISE，整笔回滚。SQLite 单写者，应用层同序执行，不建本函数。
CREATE FUNCTION live_death_makeup(p_ld BIGINT, p_mid BIGINT) RETURNS TEXT LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE st TEXT; v_sid BIGINT; v_lot BIGINT; v_loc BIGINT; v_wh BIGINT; v_day DATE; v_death BIGINT; v_sku BIGINT;  -- @pg-only
        v_hid BIGINT; v_avail BIGINT; v_q BIGINT; v_after BIGINT; v_seq BIGINT; v_biz TEXT; v_opk TEXT; n INT;  -- @pg-only
BEGIN  -- @pg-only
    SELECT deduct_status INTO st FROM live_death WHERE id = p_ld FOR UPDATE;  -- @pg-only
    IF st IS NULL THEN RAISE EXCEPTION 'live_death_not_found: %', p_ld; END IF;  -- @pg-only
    IF st <> 'PENDING' THEN RETURN 'EXISTING:' || st; END IF;  -- @pg-only
    IF EXISTS (SELECT 1 FROM stock_movement_key WHERE idempotency_key = 'LD-' || p_ld || ':1:D1:1') THEN RETURN 'EXISTING_MOVEMENT:' || st; END IF;  -- @pg-only
    SELECT stock_id, lot_id, location_id, warehouse_id, work_date, death_qty_milli  -- @pg-only
      INTO v_sid, v_lot, v_loc, v_wh, v_day, v_death FROM live_death WHERE id = p_ld;  -- @pg-only
    v_biz := 'LD-' || p_ld; v_opk := v_biz || ':1:D1:1';  -- @pg-only
    SELECT sku_id INTO v_sku FROM stock WHERE id = v_sid ORDER BY id FOR UPDATE;  -- @pg-only
    SELECT id, hold_qty_milli - released_qty_milli INTO v_hid, v_avail FROM stock_hold  -- @pg-only
     WHERE stock_id = v_sid AND hold_type = 'LIVE_HOLD' AND status = 'HELD' ORDER BY id LIMIT 1 FOR UPDATE;  -- @pg-only
    IF v_hid IS NULL THEN  -- @pg-only
        SELECT on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli  -- @pg-only
          INTO v_avail FROM stock WHERE id = v_sid;  -- @pg-only
    END IF;  -- @pg-only
    v_q := LEAST(v_death, GREATEST(COALESCE(v_avail, 0), 0));  -- @pg-only
    IF v_q > 0 THEN  -- @pg-only
        IF v_hid IS NOT NULL THEN  -- @pg-only
            UPDATE stock SET hold_qty_milli = hold_qty_milli - v_q, on_hand_qty_milli = on_hand_qty_milli - v_q, ledger_seq = ledger_seq + 1, version = version + 1  -- @pg-only
             WHERE id = v_sid AND hold_qty_milli >= v_q AND on_hand_qty_milli >= v_q RETURNING on_hand_qty_milli, ledger_seq INTO v_after, v_seq;  -- @pg-only
            UPDATE stock_hold SET released_qty_milli = released_qty_milli + v_q,  -- @pg-only
                   status = CASE WHEN released_qty_milli + v_q = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1  -- @pg-only
             WHERE id = v_hid AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= v_q;  -- @pg-only
        ELSE  -- @pg-only
            UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - v_q, ledger_seq = ledger_seq + 1, version = version + 1  -- @pg-only
             WHERE id = v_sid AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= v_q  -- @pg-only
            RETURNING on_hand_qty_milli, ledger_seq INTO v_after, v_seq;  -- @pg-only
        END IF;  -- @pg-only
        IF v_seq IS NULL THEN RAISE EXCEPTION 'makeup_stock_rowcount_0: %', p_ld; END IF;  -- @pg-only
        INSERT INTO stock_ledger_line (biz_no, line_no, src_kind, owner_device_instance_id) SELECT v_biz,1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = v_biz AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING;  -- @pg-only
        INSERT INTO stock_movement (id, biz_no, line_no, op_no, leg, src_kind, biz_type, direction, stock_id, stock_seq, warehouse_id, location_id, sku_id, lot_id,  -- @pg-only
                                    move_qty_milli, on_hand_before_qty_milli, on_hand_after_qty_milli, occurred_at, idempotency_key, hold_id)  -- @pg-only
             VALUES (p_mid, v_biz, 1, 1, 1, 'DOC', 'SCRAP', -1, v_sid, v_seq, v_wh, v_loc, v_sku, v_lot, v_q, v_after + v_q, v_after, v_day, v_opk, v_hid);  -- @pg-only
        INSERT INTO stock_movement_key (movement_id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)  -- @pg-only
             VALUES (p_mid, v_opk, v_biz, 1, 1, 1, 'DOC', v_sid, v_seq, -1, v_day);  -- @pg-only
    END IF;  -- @pg-only
    UPDATE live_death SET deduct_status = CASE WHEN v_q = v_death THEN 'DEDUCTED' ELSE 'EXCEPTION' END,  -- @pg-only
           movement_id = CASE WHEN v_q > 0 THEN p_mid END, deducted_qty_milli = v_q,  -- @pg-only
           exception_key = CASE WHEN v_q < v_death THEN 'LDTH:' || p_ld END  -- @pg-only
     WHERE id = p_ld AND deduct_status = 'PENDING';  -- @pg-only
    GET DIAGNOSTICS n = ROW_COUNT;  -- @pg-only
    IF n = 0 THEN RAISE EXCEPTION 'makeup_lost_at_cond_update: %', p_ld; END IF;  -- @pg-only
    RETURN 'WON:' || v_q || ':' || (v_death - v_q) || ':' || v_sku;  -- @pg-only
END $$;  -- @pg-only

-- X1/X2：no-replace 触发器（WHEN 覆盖本表全部 PK / UNIQUE，部分索引带谓词；由 genreplace 生成）

-- 去重键不可改、计数器只增（由 genlock 生成；PG 触发器名 trg_0keylock_* 让它按字母序最先执行）
CREATE TRIGGER trg_0keylock_sku_live_param BEFORE UPDATE ON sku_live_param FOR EACH ROW EXECUTE FUNCTION trg_keylock('sku_id', '', 'version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sku_live_param_keylock BEFORE UPDATE ON sku_live_param WHEN NEW.sku_id IS NOT OLD.sku_id BEGIN SELECT RAISE(ABORT, 'sku_live_param_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_sku_live_param_monotonic BEFORE UPDATE ON sku_live_param WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'sku_live_param_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_0keylock_live_tank BEFORE UPDATE ON live_tank FOR EACH ROW EXECUTE FUNCTION trg_keylock('location_id', '', 'version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_live_tank_keylock BEFORE UPDATE ON live_tank WHEN NEW.location_id IS NOT OLD.location_id BEGIN SELECT RAISE(ABORT, 'live_tank_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_live_tank_monotonic BEFORE UPDATE ON live_tank WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'live_tank_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_0keylock_live_stock_count BEFORE UPDATE ON live_stock_count FOR EACH ROW EXECUTE FUNCTION trg_keylock('stock_id', '', 'version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_live_stock_count_keylock BEFORE UPDATE ON live_stock_count WHEN NEW.stock_id IS NOT OLD.stock_id BEGIN SELECT RAISE(ABORT, 'live_stock_count_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_live_stock_count_monotonic BEFORE UPDATE ON live_stock_count WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'live_stock_count_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_0keylock_live_tank_hold BEFORE UPDATE ON live_tank_hold FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,location_id', '', '');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_live_tank_hold_keylock BEFORE UPDATE ON live_tank_hold WHEN NEW.id IS NOT OLD.id OR NEW.location_id IS NOT OLD.location_id BEGIN SELECT RAISE(ABORT, 'live_tank_hold_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
CREATE TRIGGER trg_0keylock_live_death BEFORE UPDATE ON live_death FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,movement_id,device_instance_id,client_op_id', 'movement_id', 'deducted_qty_milli');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_live_death_keylock BEFORE UPDATE ON live_death WHEN NEW.id IS NOT OLD.id OR (OLD.movement_id IS NOT NULL AND NEW.movement_id IS NOT OLD.movement_id) OR NEW.device_instance_id IS NOT OLD.device_instance_id OR NEW.client_op_id IS NOT OLD.client_op_id BEGIN SELECT RAISE(ABORT, 'live_death_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_live_death_monotonic BEFORE UPDATE ON live_death WHEN NEW.deducted_qty_milli < OLD.deducted_qty_milli BEGIN SELECT RAISE(ABORT, 'live_death_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
