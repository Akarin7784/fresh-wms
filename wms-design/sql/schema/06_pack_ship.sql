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
    check_id        BIGINT       REFERENCES check_record(id),  -- 封箱时必须指向同单 PASSED 复核单（H3，触发器）
    shipment_id     BIGINT       REFERENCES shipment(id),
    stage_location_id BIGINT,                       -- 集货位
    box_type        VARCHAR(24)  NOT NULL DEFAULT 'CARTON',  -- CARTON/TURNBOX（周转筐）
    weight_g        BIGINT,                         -- docs/06 Q6 已定：整数克
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN',    -- docs/06 §5.2：OPEN/SEALED/STAGED/SHIPPED/CANCELLED/VOIDED
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
CREATE INDEX ix_box_outbound ON pack_box(outbound_id, status);
CREATE INDEX ix_box_shipment ON pack_box(shipment_id);
CREATE INDEX ix_box_check ON pack_box(check_id);
-- docs/06 §5.2 箱守卫（H3/H4/H6）：
--  INSERT 只能 OPEN；不可删；身份列不可改；SHIPPED/CANCELLED/VOIDED 整行只读（box_closed）
--  状态边：OPEN→SEALED/CANCELLED；SEALED→STAGED/OPEN/VOIDED；STAGED→SHIPPED/SEALED
--  封箱后（新旧都非 OPEN）check_id/checker_id/packed_at/weight_g 不可改（box_sealed → 40937）
--  OPEN→SEALED：check_id 指向同单 PASSED 复核单（box_check_invalid）；checker_id = 复核人（sealer_not_checker）；
--               该复核单下所有有效箱按 SKU 合计 ≤ 复核量（box_over_check）
--  shipment_id 只能在 STAGED 期间、新旧车次都是 CREATED 时挂/摘（box_shipment）；STAGED→SEALED 前须先摘车
--  STAGED→SHIPPED：shipment_id 不变且车次已 HANDED_OVER（box_shipment）
--  SEALED→VOIDED：须有 APPROVED 作废申请（box_void_unapproved）
CREATE FUNCTION trg_box_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                    -- @pg-only
DECLARE c check_record%ROWTYPE;                                                                            -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                               -- @pg-only
        IF NEW.status <> 'OPEN' THEN RAISE EXCEPTION 'box_state'; END IF;                                  -- @pg-only
        RETURN NEW;                                                                                        -- @pg-only
    END IF;                                                                                                -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'box_immutable'; END IF;                                      -- @pg-only
    IF NEW.code <> OLD.code OR NEW.outbound_id <> OLD.outbound_id OR NEW.warehouse_id <> OLD.warehouse_id  -- @pg-only
    THEN RAISE EXCEPTION 'box_immutable'; END IF;                                                          -- @pg-only
    IF OLD.status IN ('SHIPPED','CANCELLED','VOIDED') THEN RAISE EXCEPTION 'box_closed'; END IF;           -- @pg-only
    IF NEW.status <> OLD.status AND NOT (                                                                  -- @pg-only
        (OLD.status = 'OPEN'   AND NEW.status IN ('SEALED','CANCELLED')) OR                                -- @pg-only
        (OLD.status = 'SEALED' AND NEW.status IN ('STAGED','OPEN','VOIDED')) OR                            -- @pg-only
        (OLD.status = 'STAGED' AND NEW.status IN ('SHIPPED','SEALED')))                                    -- @pg-only
    THEN RAISE EXCEPTION 'box_state'; END IF;                                                              -- @pg-only
    IF OLD.status <> 'OPEN' AND NEW.status <> 'OPEN' AND (NEW.check_id IS DISTINCT FROM OLD.check_id       -- @pg-only
       OR NEW.checker_id IS DISTINCT FROM OLD.checker_id OR NEW.packed_at IS DISTINCT FROM OLD.packed_at   -- @pg-only
       OR NEW.weight_g IS DISTINCT FROM OLD.weight_g) THEN RAISE EXCEPTION 'box_sealed'; END IF;           -- @pg-only
    IF OLD.status = 'OPEN' AND NEW.status = 'SEALED' THEN                                                  -- @pg-only
        SELECT * INTO c FROM check_record WHERE id = NEW.check_id;                                         -- @pg-only
        IF c.id IS NULL OR c.outbound_id <> NEW.outbound_id OR c.status <> 'PASSED'                        -- @pg-only
        THEN RAISE EXCEPTION 'box_check_invalid'; END IF;                                                  -- @pg-only
        IF NEW.checker_id IS DISTINCT FROM c.checker_id THEN RAISE EXCEPTION 'sealer_not_checker'; END IF; -- @pg-only
        IF EXISTS (SELECT 1 FROM (SELECT l.sku_id, SUM(l.qty_milli) AS q FROM pack_box_line l JOIN pack_box b ON b.id = l.box_id  -- @pg-only
                   WHERE (b.check_id = NEW.check_id OR b.id = NEW.id) AND b.status NOT IN ('CANCELLED','VOIDED') GROUP BY l.sku_id) x  -- @pg-only
                   WHERE x.q > COALESCE((SELECT SUM(cl.checked_qty_milli) FROM check_line cl WHERE cl.check_id = NEW.check_id AND cl.sku_id = x.sku_id), 0))  -- @pg-only
        THEN RAISE EXCEPTION 'box_over_check'; END IF;                                                     -- @pg-only
    END IF;                                                                                                -- @pg-only
    IF NEW.shipment_id IS DISTINCT FROM OLD.shipment_id AND NOT (                                          -- @pg-only
         OLD.status = 'STAGED' AND NEW.status = 'STAGED'                                                   -- @pg-only
         AND (OLD.shipment_id IS NULL OR (SELECT status FROM shipment WHERE id = OLD.shipment_id) = 'CREATED')  -- @pg-only
         AND (NEW.shipment_id IS NULL OR (SELECT status FROM shipment WHERE id = NEW.shipment_id) = 'CREATED'))  -- @pg-only
    THEN RAISE EXCEPTION 'box_shipment'; END IF;                                                           -- @pg-only
    IF OLD.status = 'STAGED' AND NEW.status = 'SEALED' AND NEW.shipment_id IS NOT NULL THEN RAISE EXCEPTION 'box_shipment'; END IF;  -- @pg-only
    IF NEW.status = 'SHIPPED' AND (SELECT status FROM shipment WHERE id = NEW.shipment_id) IS DISTINCT FROM 'HANDED_OVER'  -- @pg-only
    THEN RAISE EXCEPTION 'box_shipment'; END IF;                                                           -- @pg-only
    IF NEW.status = 'VOIDED' AND NOT EXISTS (SELECT 1 FROM box_void_request r WHERE r.box_id = NEW.id AND r.status = 'APPROVED')  -- @pg-only
    THEN RAISE EXCEPTION 'box_void_unapproved'; END IF;                                                    -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_box_guard BEFORE INSERT OR UPDATE OR DELETE ON pack_box FOR EACH ROW EXECUTE FUNCTION trg_box_guard();  -- @pg-only
CREATE TRIGGER trg_box_no_truncate BEFORE TRUNCATE ON pack_box FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_box_ins BEFORE INSERT ON pack_box WHEN NEW.status <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_state'); END;
-- @sqlite-only CREATE TRIGGER trg_box_upd BEFORE UPDATE ON pack_box
-- @sqlite-only WHEN NEW.code <> OLD.code OR NEW.outbound_id <> OLD.outbound_id OR NEW.warehouse_id <> OLD.warehouse_id
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_box_closed BEFORE UPDATE ON pack_box WHEN OLD.status IN ('SHIPPED','CANCELLED','VOIDED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_box_state BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN OLD.status NOT IN ('SHIPPED','CANCELLED','VOIDED') AND NEW.status <> OLD.status AND NOT ((OLD.status = 'OPEN' AND NEW.status IN ('SEALED','CANCELLED')) OR (OLD.status = 'SEALED' AND NEW.status IN ('STAGED','OPEN','VOIDED')) OR (OLD.status = 'STAGED' AND NEW.status IN ('SHIPPED','SEALED')))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_state'); END;
-- @sqlite-only CREATE TRIGGER trg_box_frozen BEFORE UPDATE ON pack_box
-- @sqlite-only WHEN OLD.status NOT IN ('OPEN','SHIPPED','CANCELLED','VOIDED') AND NEW.status <> 'OPEN' AND (NEW.check_id IS NOT OLD.check_id OR NEW.checker_id IS NOT OLD.checker_id OR NEW.packed_at IS NOT OLD.packed_at OR NEW.weight_g IS NOT OLD.weight_g)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_sealed'); END;
-- @sqlite-only CREATE TRIGGER trg_box_seal_check BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN OLD.status = 'OPEN' AND NEW.status = 'SEALED' AND NOT EXISTS (SELECT 1 FROM check_record c WHERE c.id = NEW.check_id AND c.outbound_id = NEW.outbound_id AND c.status = 'PASSED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_check_invalid'); END;
-- @sqlite-only CREATE TRIGGER trg_box_seal_sod BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN OLD.status = 'OPEN' AND NEW.status = 'SEALED' AND EXISTS (SELECT 1 FROM check_record c WHERE c.id = NEW.check_id AND c.outbound_id = NEW.outbound_id AND c.status = 'PASSED') AND NEW.checker_id IS NOT (SELECT checker_id FROM check_record WHERE id = NEW.check_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sealer_not_checker'); END;
-- @sqlite-only CREATE TRIGGER trg_box_seal_qty BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN OLD.status = 'OPEN' AND NEW.status = 'SEALED' AND NEW.checker_id IS (SELECT checker_id FROM check_record WHERE id = NEW.check_id AND outbound_id = NEW.outbound_id AND status = 'PASSED') AND EXISTS (SELECT 1 FROM (SELECT l.sku_id AS sku_id, SUM(l.qty_milli) AS q FROM pack_box_line l JOIN pack_box b ON b.id = l.box_id WHERE (b.check_id = NEW.check_id OR b.id = NEW.id) AND b.status NOT IN ('CANCELLED','VOIDED') GROUP BY l.sku_id) x WHERE x.q > COALESCE((SELECT SUM(cl.checked_qty_milli) FROM check_line cl WHERE cl.check_id = NEW.check_id AND cl.sku_id = x.sku_id), 0))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_over_check'); END;
-- @sqlite-only CREATE TRIGGER trg_box_ship_attach BEFORE UPDATE OF shipment_id ON pack_box
-- @sqlite-only WHEN OLD.status NOT IN ('SHIPPED','CANCELLED','VOIDED') AND NEW.shipment_id IS NOT OLD.shipment_id AND NOT (OLD.status = 'STAGED' AND NEW.status = 'STAGED' AND (OLD.shipment_id IS NULL OR (SELECT status FROM shipment WHERE id = OLD.shipment_id) = 'CREATED') AND (NEW.shipment_id IS NULL OR (SELECT status FROM shipment WHERE id = NEW.shipment_id) = 'CREATED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_shipment'); END;
-- @sqlite-only CREATE TRIGGER trg_box_ship_go BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN (OLD.status = 'STAGED' AND NEW.status = 'SHIPPED' AND (SELECT status FROM shipment WHERE id = NEW.shipment_id) IS NOT 'HANDED_OVER') OR (OLD.status = 'STAGED' AND NEW.status = 'SEALED' AND NEW.shipment_id IS NOT NULL)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_shipment'); END;
-- @sqlite-only CREATE TRIGGER trg_box_void BEFORE UPDATE OF status ON pack_box
-- @sqlite-only WHEN OLD.status = 'SEALED' AND NEW.status = 'VOIDED' AND NOT EXISTS (SELECT 1 FROM box_void_request r WHERE r.box_id = NEW.id AND r.status = 'APPROVED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_void_unapproved'); END;
-- @sqlite-only CREATE TRIGGER trg_box_del BEFORE DELETE ON pack_box BEGIN SELECT RAISE(ABORT, 'box_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_box_dup BEFORE INSERT ON pack_box
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM pack_box b WHERE b.id = NEW.id OR b.code = NEW.code)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_duplicate'); END;

-- 箱作废申请（Q8）：只对 SEALED 箱；申请人 ≠ 审批人；一箱同时至多一张 PENDING；只能 PENDING→APPROVED/REJECTED 一次
CREATE TABLE box_void_request (
    id              BIGINT       PRIMARY KEY,
    box_id          BIGINT       NOT NULL REFERENCES pack_box(id),
    reason_code     VARCHAR(16)  NOT NULL,          -- LOST / DAMAGED
    remark          VARCHAR(500),
    photo_ids       TEXT,                           -- JSON 数组（对象存储 key）
    requested_by    BIGINT       NOT NULL,
    requested_at    TIMESTAMP    NOT NULL DEFAULT now(),
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING',  -- PENDING/APPROVED/REJECTED
    decided_by      BIGINT,
    decided_at      TIMESTAMP,
    decision_remark VARCHAR(500),                   -- 审批意见（接口同名字段）
    version         INT          NOT NULL DEFAULT 0,
    CONSTRAINT ck_bvr_reason CHECK (reason_code IN ('LOST','DAMAGED')),
    CONSTRAINT ck_bvr_status CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    CONSTRAINT ck_bvr_decided CHECK ((status = 'PENDING' AND decided_by IS NULL AND decided_at IS NULL)
                                  OR (status <> 'PENDING' AND decided_by IS NOT NULL AND decided_at IS NOT NULL)),
    CONSTRAINT ck_bvr_dremark CHECK (status <> 'PENDING' OR decision_remark IS NULL),
    CONSTRAINT ck_bvr_self CHECK (decided_by IS NULL OR decided_by <> requested_by)
);
CREATE UNIQUE INDEX uq_bvr_pending ON box_void_request(box_id) WHERE status = 'PENDING';
CREATE FUNCTION trg_bvr_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                    -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                               -- @pg-only
        IF NEW.status <> 'PENDING' OR (SELECT status FROM pack_box WHERE id = NEW.box_id) IS DISTINCT FROM 'SEALED'  -- @pg-only
        THEN RAISE EXCEPTION 'box_void_state'; END IF;                                                     -- @pg-only
        RETURN NEW;                                                                                        -- @pg-only
    END IF;                                                                                                -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'bvr_immutable'; END IF;                                      -- @pg-only
    IF OLD.status <> 'PENDING' THEN RAISE EXCEPTION 'bvr_closed'; END IF;                                  -- @pg-only
    IF NEW.box_id <> OLD.box_id OR NEW.reason_code <> OLD.reason_code OR NEW.requested_by <> OLD.requested_by  -- @pg-only
       OR NEW.remark IS DISTINCT FROM OLD.remark OR NEW.photo_ids IS DISTINCT FROM OLD.photo_ids          -- @pg-only
       OR NEW.requested_at <> OLD.requested_at THEN RAISE EXCEPTION 'bvr_immutable'; END IF;               -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_bvr_guard BEFORE INSERT OR UPDATE OR DELETE ON box_void_request FOR EACH ROW EXECUTE FUNCTION trg_bvr_guard();  -- @pg-only
CREATE TRIGGER trg_bvr_no_truncate BEFORE TRUNCATE ON box_void_request FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_bvr_ins BEFORE INSERT ON box_void_request
-- @sqlite-only WHEN NEW.status <> 'PENDING' OR COALESCE((SELECT status FROM pack_box WHERE id = NEW.box_id), '') <> 'SEALED'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_void_state'); END;
-- @sqlite-only CREATE TRIGGER trg_bvr_closed BEFORE UPDATE ON box_void_request WHEN OLD.status <> 'PENDING'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'bvr_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_bvr_upd BEFORE UPDATE ON box_void_request
-- @sqlite-only WHEN OLD.status = 'PENDING' AND (NEW.box_id <> OLD.box_id OR NEW.reason_code <> OLD.reason_code OR NEW.requested_by <> OLD.requested_by OR NEW.remark IS NOT OLD.remark OR NEW.photo_ids IS NOT OLD.photo_ids OR NEW.requested_at <> OLD.requested_at)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'bvr_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_bvr_del BEFORE DELETE ON box_void_request BEGIN SELECT RAISE(ABORT, 'bvr_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_bvr_dup BEFORE INSERT ON box_void_request
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM box_void_request r WHERE r.id = NEW.id OR (r.box_id = NEW.box_id AND r.status = 'PENDING'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'bvr_duplicate'); END;

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
