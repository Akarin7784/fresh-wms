-- docs/06 复核、装箱、发货（复核表放在 pack_box 之前，供外键引用）
-- ============================================================
-- 复核单：一张出库单同一时刻至多一张 OPEN 复核。INSERT 只能是 OPEN（H2）。
-- SoD（H1）：复核人不得是该单任一拣货人；拣货人全集写在 check_picker（开单同事务），picker_id 只作展示
CREATE TABLE check_record (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    outbound_id         BIGINT       NOT NULL,
    picker_id           BIGINT,                      -- 展示用（主拣货人）；SoD 以 check_picker 为准
    checker_id          BIGINT       NOT NULL,
    device_instance_id  VARCHAR(64),
    status              VARCHAR(16)  NOT NULL DEFAULT 'OPEN',  -- OPEN/PASSED/FAILED/CANCELLED
    mismatch_count      INT          NOT NULL DEFAULT 0,
    closed_by           BIGINT,
    closed_at           TIMESTAMP,
    version             INT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_chk_code UNIQUE (code),
    CONSTRAINT ck_chk_status CHECK (status IN ('OPEN','PASSED','FAILED','CANCELLED')),
    CONSTRAINT ck_chk_sod CHECK (picker_id IS NULL OR picker_id <> checker_id),
    CONSTRAINT ck_chk_closed CHECK ((status = 'OPEN' AND closed_at IS NULL AND closed_by IS NULL)
                                 OR (status <> 'OPEN' AND closed_at IS NOT NULL AND closed_by IS NOT NULL)),
    CONSTRAINT ck_chk_pass CHECK (status <> 'PASSED' OR mismatch_count = 0),
    CONSTRAINT ck_chk_mismatch CHECK (mismatch_count >= 0)
);
CREATE UNIQUE INDEX uq_chk_open ON check_record(outbound_id) WHERE status = 'OPEN';

-- 拣货人全集（H1）：开单时把该单所有 pick_task.assigned_to 与 pick_op 操作人写入；只追加
CREATE TABLE check_picker (
    check_id    BIGINT  NOT NULL REFERENCES check_record(id),
    user_id     BIGINT  NOT NULL,
    PRIMARY KEY (check_id, user_id)
);
CREATE FUNCTION trg_chk_picker_guard() RETURNS trigger LANGUAGE plpgsql AS $$                             -- @pg-only
DECLARE c check_record%ROWTYPE;                                                                            -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'check_immutable'; END IF;                                   -- @pg-only
    SELECT * INTO c FROM check_record WHERE id = NEW.check_id;                                             -- @pg-only
    IF c.status IS DISTINCT FROM 'OPEN' THEN RAISE EXCEPTION 'check_closed'; END IF;                       -- @pg-only
    IF c.checker_id = NEW.user_id THEN RAISE EXCEPTION 'check_sod'; END IF;                                -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_chk_picker_guard BEFORE INSERT OR UPDATE OR DELETE ON check_picker FOR EACH ROW EXECUTE FUNCTION trg_chk_picker_guard();  -- @pg-only
CREATE TRIGGER trg_chk_picker_no_truncate BEFORE TRUNCATE ON check_picker FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_chkp_upd BEFORE UPDATE ON check_picker BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chkp_del BEFORE DELETE ON check_picker BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chkp_dup BEFORE INSERT ON check_picker
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM check_picker p WHERE p.check_id = NEW.check_id AND p.user_id = NEW.user_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_chkp_closed BEFORE INSERT ON check_picker
-- @sqlite-only WHEN COALESCE((SELECT status FROM check_record WHERE id = NEW.check_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_chkp_sod BEFORE INSERT ON check_picker
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM check_record c WHERE c.id = NEW.check_id AND c.checker_id = NEW.user_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_sod'); END;

-- 复核单守卫：INSERT 只能 OPEN；关单后终态；身份列不可改；不可删；
-- 转 PASSED（H2）：至少一行、无 checked<>expected 的行、至少登记了一个拣货人
CREATE FUNCTION trg_chk_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                    -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                               -- @pg-only
        IF NEW.status <> 'OPEN' THEN RAISE EXCEPTION 'check_state'; END IF;                                -- @pg-only
        RETURN NEW;                                                                                        -- @pg-only
    END IF;                                                                                                -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'check_immutable'; END IF;                                    -- @pg-only
    IF NEW.outbound_id <> OLD.outbound_id OR NEW.checker_id <> OLD.checker_id                              -- @pg-only
       OR NEW.picker_id IS DISTINCT FROM OLD.picker_id OR NEW.code <> OLD.code                             -- @pg-only
    THEN RAISE EXCEPTION 'check_immutable'; END IF;                                                        -- @pg-only
    IF OLD.status <> 'OPEN' THEN RAISE EXCEPTION 'check_closed'; END IF;                                   -- @pg-only
    IF NEW.status = 'PASSED' AND (                                                                         -- @pg-only
         NOT EXISTS (SELECT 1 FROM check_line l WHERE l.check_id = NEW.id)                                 -- @pg-only
      OR EXISTS (SELECT 1 FROM check_line l WHERE l.check_id = NEW.id AND l.checked_qty_milli <> l.expected_qty_milli)  -- @pg-only
      OR NOT EXISTS (SELECT 1 FROM check_picker p WHERE p.check_id = NEW.id))                              -- @pg-only
    THEN RAISE EXCEPTION 'check_not_complete'; END IF;                                                     -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_chk_guard BEFORE INSERT OR UPDATE OR DELETE ON check_record FOR EACH ROW EXECUTE FUNCTION trg_chk_guard();  -- @pg-only
CREATE TRIGGER trg_chk_no_truncate BEFORE TRUNCATE ON check_record FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_chk_ins BEFORE INSERT ON check_record WHEN NEW.status <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_state'); END;
-- @sqlite-only CREATE TRIGGER trg_chk_upd BEFORE UPDATE ON check_record
-- @sqlite-only WHEN NEW.outbound_id <> OLD.outbound_id OR NEW.checker_id <> OLD.checker_id OR NEW.picker_id IS NOT OLD.picker_id OR NEW.code <> OLD.code
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chk_closed BEFORE UPDATE ON check_record WHEN OLD.status <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_chk_pass BEFORE UPDATE OF status ON check_record
-- @sqlite-only WHEN OLD.status = 'OPEN' AND NEW.status = 'PASSED' AND (NOT EXISTS (SELECT 1 FROM check_line l WHERE l.check_id = NEW.id) OR EXISTS (SELECT 1 FROM check_line l WHERE l.check_id = NEW.id AND l.checked_qty_milli <> l.expected_qty_milli) OR NOT EXISTS (SELECT 1 FROM check_picker p WHERE p.check_id = NEW.id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_not_complete'); END;
-- @sqlite-only CREATE TRIGGER trg_chk_del BEFORE DELETE ON check_record BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chk_dup BEFORE INSERT ON check_record
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM check_record c WHERE c.id = NEW.id OR c.code = NEW.code OR (c.outbound_id = NEW.outbound_id AND c.status = 'OPEN' AND NEW.status = 'OPEN'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_duplicate'); END;

-- 复核行：按出库行汇总；checked ≤ expected（多扫 → 42214 OVER_QTY，detail.reason=OVER_CHECK）
CREATE TABLE check_line (
    id                  BIGINT       PRIMARY KEY,
    check_id            BIGINT       NOT NULL REFERENCES check_record(id),
    line_no             INT          NOT NULL,       -- = outbound_line.line_no
    outbound_line_id    BIGINT       NOT NULL,
    sku_id              BIGINT       NOT NULL,
    expected_qty_milli  BIGINT       NOT NULL,       -- = 该出库行已拣 picked_qty_milli（开单冻结）
    checked_qty_milli   BIGINT       NOT NULL DEFAULT 0,
    version             INT          NOT NULL DEFAULT 0,
    CONSTRAINT uq_chkl_line UNIQUE (check_id, line_no),
    CONSTRAINT uq_chkl_obl UNIQUE (check_id, outbound_line_id),
    CONSTRAINT ck_chkl_qty CHECK (expected_qty_milli >= 0 AND checked_qty_milli >= 0 AND checked_qty_milli <= expected_qty_milli
                                  AND expected_qty_milli = CAST(expected_qty_milli AS BIGINT) AND checked_qty_milli = CAST(checked_qty_milli AS BIGINT))
);
-- 复核行只在复核单 OPEN 时可写；不可删；身份列不可改
CREATE FUNCTION trg_chkl_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'check_immutable'; END IF;                                    -- @pg-only
    IF TG_OP = 'UPDATE' AND (NEW.check_id <> OLD.check_id OR NEW.line_no <> OLD.line_no                    -- @pg-only
       OR NEW.outbound_line_id <> OLD.outbound_line_id OR NEW.sku_id <> OLD.sku_id                         -- @pg-only
       OR NEW.expected_qty_milli <> OLD.expected_qty_milli) THEN RAISE EXCEPTION 'check_immutable'; END IF; -- @pg-only
    IF (SELECT status FROM check_record WHERE id = NEW.check_id) IS DISTINCT FROM 'OPEN'                   -- @pg-only
    THEN RAISE EXCEPTION 'check_closed'; END IF;                                                           -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_chkl_guard BEFORE INSERT OR UPDATE OR DELETE ON check_line FOR EACH ROW EXECUTE FUNCTION trg_chkl_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_chkl_upd BEFORE UPDATE ON check_line
-- @sqlite-only WHEN NEW.check_id <> OLD.check_id OR NEW.line_no <> OLD.line_no OR NEW.outbound_line_id <> OLD.outbound_line_id OR NEW.sku_id <> OLD.sku_id OR NEW.expected_qty_milli <> OLD.expected_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chkl_closed_u BEFORE UPDATE ON check_line
-- @sqlite-only WHEN COALESCE((SELECT status FROM check_record WHERE id = OLD.check_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_chkl_closed_i BEFORE INSERT ON check_line
-- @sqlite-only WHEN COALESCE((SELECT status FROM check_record WHERE id = NEW.check_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_chkl_del BEFORE DELETE ON check_line BEGIN SELECT RAISE(ABORT, 'check_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_chkl_dup BEFORE INSERT ON check_line
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM check_line l WHERE l.id = NEW.id OR (l.check_id = NEW.check_id AND (l.line_no = NEW.line_no OR l.outbound_line_id = NEW.outbound_line_id)))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_duplicate'); END;

-- 复核扫描操作：PDA 四元键 (check_id, line_no, device_instance_id, op_seq) 去重，与 docs/05 pick_op 同构
-- 同键不同 (op_type, qty_milli, barcode) → 40910 key_type=PDA_OP；不入账（复核不动库存）
CREATE TABLE check_op (
    id                  BIGINT       PRIMARY KEY,
    check_id            BIGINT       NOT NULL,
    line_no             INT          NOT NULL,
    device_instance_id  VARCHAR(64)  NOT NULL,
    op_seq              BIGINT       NOT NULL,
    op_type             VARCHAR(16)  NOT NULL,       -- SCAN/UNDO
    barcode             VARCHAR(64)  NOT NULL,
    qty_milli           BIGINT       NOT NULL,
    scan_event_id       VARCHAR(64),                 -- 逐件模式
    result_code         CHAR(5),                     -- NULL=成功；失败为 5 位错误码（42210/42214/…）
    finished_at         TIMESTAMP,                   -- UTC；与 result_code 一起只写一次
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_check_op UNIQUE (check_id, line_no, device_instance_id, op_seq),
    CONSTRAINT ck_check_op_type CHECK (op_type IN ('SCAN','UNDO')),
    CONSTRAINT ck_check_op_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_check_op_result CHECK (result_code IS NULL OR (length(result_code) = 5 AND result_code BETWEEN '10000' AND '59999')),
    CONSTRAINT ck_check_op_finish CHECK (finished_at IS NOT NULL OR result_code IS NULL)
);
CREATE UNIQUE INDEX uq_check_op_scan ON check_op(check_id, scan_event_id) WHERE scan_event_id IS NOT NULL;
CREATE FUNCTION trg_check_op_guard() RETURNS trigger LANGUAGE plpgsql AS $$                               -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'check_op_immutable'; END IF;                                 -- @pg-only
    IF OLD.finished_at IS NOT NULL                                                                         -- @pg-only
       OR NEW.check_id <> OLD.check_id OR NEW.line_no <> OLD.line_no OR NEW.device_instance_id <> OLD.device_instance_id  -- @pg-only
       OR NEW.op_seq <> OLD.op_seq OR NEW.op_type <> OLD.op_type OR NEW.barcode <> OLD.barcode            -- @pg-only
       OR NEW.qty_milli <> OLD.qty_milli OR NEW.scan_event_id IS DISTINCT FROM OLD.scan_event_id           -- @pg-only
       OR NEW.created_at <> OLD.created_at                                                                 -- @pg-only
    THEN RAISE EXCEPTION 'check_op_immutable'; END IF;                                                     -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_check_op_guard BEFORE UPDATE OR DELETE ON check_op FOR EACH ROW EXECUTE FUNCTION trg_check_op_guard();  -- @pg-only
CREATE TRIGGER trg_check_op_no_truncate BEFORE TRUNCATE ON check_op FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_check_op_upd BEFORE UPDATE ON check_op
-- @sqlite-only WHEN OLD.finished_at IS NOT NULL OR NEW.check_id <> OLD.check_id OR NEW.line_no <> OLD.line_no OR NEW.device_instance_id <> OLD.device_instance_id OR NEW.op_seq <> OLD.op_seq OR NEW.op_type <> OLD.op_type OR NEW.barcode <> OLD.barcode OR NEW.qty_milli <> OLD.qty_milli OR NEW.scan_event_id IS NOT OLD.scan_event_id OR NEW.created_at <> OLD.created_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_op_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_check_op_del BEFORE DELETE ON check_op BEGIN SELECT RAISE(ABORT, 'check_op_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_check_op_dup BEFORE INSERT ON check_op
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM check_op o WHERE o.id = NEW.id OR (o.check_id = NEW.check_id AND o.line_no = NEW.line_no AND o.device_instance_id = NEW.device_instance_id AND o.op_seq = NEW.op_seq) OR (NEW.scan_event_id IS NOT NULL AND o.check_id = NEW.check_id AND o.scan_event_id = NEW.scan_event_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'check_op_duplicate'); END;

-- 发运单（docs/06 §5.3）：CREATED/HANDED_OVER/CANCELLED；司机、车辆、发车、签收在 docs/16 waybill
CREATE TABLE shipment (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL,
    carrier_code    VARCHAR(32),
    status          VARCHAR(16)  NOT NULL DEFAULT 'CREATED',
    temp_log_ref    VARCHAR(128),                   -- 温控记录对象存储 key
    dock_location_id BIGINT,                        -- 月台
    waybill_id      BIGINT,                         -- docs/16 waybill.id（1:1，交接同事务由 create_from_shipment 生成后回填）
    box_count       INT          NOT NULL DEFAULT 0,       -- 交接时冻结：= 本车次 STAGED 箱数（触发器核对，H4）
    handed_over_at  TIMESTAMP,                      -- 发货出库交接时间（UTC）
    handed_over_by  BIGINT,
    version         INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_shp_code UNIQUE (code),
    CONSTRAINT ck_shp_status CHECK (status IN ('CREATED','HANDED_OVER','CANCELLED')),
    CONSTRAINT ck_shp_handover CHECK (status <> 'HANDED_OVER' OR (handed_over_at IS NOT NULL AND handed_over_by IS NOT NULL AND waybill_id IS NOT NULL AND box_count > 0)),
    CONSTRAINT ck_shp_box_count CHECK (box_count >= 0)
);
-- H4：INSERT 只能 CREATED；终态冻结；CANCELLED 要求车次下无箱、无出库单；HANDED_OVER 要求 box_count = 本车次 STAGED 箱数
CREATE FUNCTION trg_shp_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                    -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                               -- @pg-only
        IF NEW.status <> 'CREATED' THEN RAISE EXCEPTION 'shipment_state'; END IF;                          -- @pg-only
        RETURN NEW;                                                                                        -- @pg-only
    END IF;                                                                                                -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'shipment_immutable'; END IF;                                 -- @pg-only
    IF OLD.status IN ('HANDED_OVER','CANCELLED') AND (NEW.status <> OLD.status OR NEW.box_count <> OLD.box_count  -- @pg-only
       OR NEW.waybill_id IS DISTINCT FROM OLD.waybill_id OR NEW.handed_over_at IS DISTINCT FROM OLD.handed_over_at)  -- @pg-only
    THEN RAISE EXCEPTION 'shipment_closed'; END IF;                                                        -- @pg-only
    IF NEW.status <> OLD.status AND NOT (OLD.status = 'CREATED' AND NEW.status IN ('HANDED_OVER','CANCELLED'))  -- @pg-only
    THEN RAISE EXCEPTION 'shipment_state'; END IF;                                                         -- @pg-only
    IF OLD.status = 'CREATED' AND NEW.status = 'CANCELLED' AND (EXISTS (SELECT 1 FROM pack_box b WHERE b.shipment_id = NEW.id)  -- @pg-only
       OR EXISTS (SELECT 1 FROM shipment_order o WHERE o.shipment_id = NEW.id)) THEN RAISE EXCEPTION 'shipment_not_empty'; END IF;  -- @pg-only
    IF OLD.status = 'CREATED' AND NEW.status = 'HANDED_OVER'                                               -- @pg-only
       AND NEW.box_count <> (SELECT count(*) FROM pack_box b WHERE b.shipment_id = NEW.id AND b.status = 'STAGED')  -- @pg-only
    THEN RAISE EXCEPTION 'shipment_box_count'; END IF;                                                     -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_shp_guard BEFORE INSERT OR UPDATE OR DELETE ON shipment FOR EACH ROW EXECUTE FUNCTION trg_shp_guard();  -- @pg-only
CREATE TRIGGER trg_shp_no_truncate BEFORE TRUNCATE ON shipment FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_shp_ins BEFORE INSERT ON shipment WHEN NEW.status <> 'CREATED'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_state'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_closed BEFORE UPDATE ON shipment
-- @sqlite-only WHEN OLD.status IN ('HANDED_OVER','CANCELLED') AND (NEW.status <> OLD.status OR NEW.box_count <> OLD.box_count OR NEW.waybill_id IS NOT OLD.waybill_id OR NEW.handed_over_at IS NOT OLD.handed_over_at)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_state BEFORE UPDATE OF status ON shipment
-- @sqlite-only WHEN OLD.status NOT IN ('HANDED_OVER','CANCELLED') AND NEW.status <> OLD.status AND NOT (OLD.status = 'CREATED' AND NEW.status IN ('HANDED_OVER','CANCELLED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_state'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_cancel BEFORE UPDATE OF status ON shipment
-- @sqlite-only WHEN OLD.status = 'CREATED' AND NEW.status = 'CANCELLED' AND (EXISTS (SELECT 1 FROM pack_box b WHERE b.shipment_id = NEW.id) OR EXISTS (SELECT 1 FROM shipment_order o WHERE o.shipment_id = NEW.id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_not_empty'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_count BEFORE UPDATE OF status ON shipment
-- @sqlite-only WHEN OLD.status = 'CREATED' AND NEW.status = 'HANDED_OVER' AND NEW.box_count <> (SELECT count(*) FROM pack_box b WHERE b.shipment_id = NEW.id AND b.status = 'STAGED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_box_count'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_del BEFORE DELETE ON shipment BEGIN SELECT RAISE(ABORT, 'shipment_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_shp_dup BEFORE INSERT ON shipment
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM shipment x WHERE x.id = NEW.id OR x.code = NEW.code)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_duplicate'); END;

-- H5：一张出库单只能挂一个车次（uq_sho_outbound）；车次非 CREATED 时不可增删；任何时候不可改（摘挂 = 删 + 插）
CREATE TABLE shipment_order (
    shipment_id BIGINT NOT NULL REFERENCES shipment(id),
    outbound_id BIGINT NOT NULL,
    PRIMARY KEY (shipment_id, outbound_id),
    CONSTRAINT uq_sho_outbound UNIQUE (outbound_id)
);
CREATE FUNCTION trg_sho_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                    -- @pg-only
BEGIN                                                                                                      -- @pg-only
    IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'shipment_order_immutable'; END IF;                           -- @pg-only
    IF (SELECT status FROM shipment WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.shipment_id ELSE NEW.shipment_id END) IS DISTINCT FROM 'CREATED'  -- @pg-only
    THEN RAISE EXCEPTION 'shipment_closed'; END IF;                                                        -- @pg-only
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;                                                           -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_sho_guard BEFORE INSERT OR UPDATE OR DELETE ON shipment_order FOR EACH ROW EXECUTE FUNCTION trg_sho_guard();  -- @pg-only
CREATE TRIGGER trg_sho_no_truncate BEFORE TRUNCATE ON shipment_order FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sho_upd BEFORE UPDATE ON shipment_order BEGIN SELECT RAISE(ABORT, 'shipment_order_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_sho_del BEFORE DELETE ON shipment_order
-- @sqlite-only WHEN COALESCE((SELECT status FROM shipment WHERE id = OLD.shipment_id), '') <> 'CREATED'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_sho_ins BEFORE INSERT ON shipment_order
-- @sqlite-only WHEN COALESCE((SELECT status FROM shipment WHERE id = NEW.shipment_id), '') <> 'CREATED'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'shipment_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_sho_dup BEFORE INSERT ON shipment_order
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM shipment_order o WHERE o.outbound_id = NEW.outbound_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sho_duplicate'); END;

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
    checker_id      BIGINT,                         -- 封箱人，必须 = 复核单 checker_id（40930 SEALER_NOT_CHECKER）
    packed_at       TIMESTAMP,                      -- 封箱时间（UTC）
    shipped_at      TIMESTAMP,                      -- 发货出库时间（UTC）
    voided_at       TIMESTAMP,                      -- 作废时间（UTC，Q8）
    version         INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_box_code UNIQUE (code),
    CONSTRAINT ck_box_weight CHECK (weight_g IS NULL OR (weight_g >= 0 AND weight_g = CAST(weight_g AS BIGINT))),
    CONSTRAINT ck_box_status CHECK (status IN ('OPEN','SEALED','STAGED','SHIPPED','CANCELLED','VOIDED')),
    CONSTRAINT ck_box_sealed CHECK ((status IN ('OPEN','CANCELLED') AND sealed = false)
                                 OR (status IN ('SEALED','STAGED','SHIPPED','VOIDED') AND sealed = true AND packed_at IS NOT NULL AND checker_id IS NOT NULL AND check_id IS NOT NULL)),
    CONSTRAINT ck_box_staged CHECK (status NOT IN ('STAGED','SHIPPED') OR stage_location_id IS NOT NULL),
    CONSTRAINT ck_box_shipped CHECK (status <> 'SHIPPED' OR (shipment_id IS NOT NULL AND shipped_at IS NOT NULL)),
    CONSTRAINT ck_box_voided CHECK ((status = 'VOIDED' AND voided_at IS NOT NULL) OR (status <> 'VOIDED' AND voided_at IS NULL))
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
    CONSTRAINT uq_box_line UNIQUE (box_id, sku_id, lot_id)
);
-- docs/06 §5.2：箱明细只在箱 OPEN 时可增改删；封箱后冻结（解封回 OPEN 才能改，需 pack.unseal 权限 + audit_log）
CREATE FUNCTION trg_box_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$                               -- @pg-only
DECLARE st VARCHAR(16);                                                                                    -- @pg-only
BEGIN                                                                                                      -- @pg-only
    SELECT status INTO st FROM pack_box WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.box_id ELSE NEW.box_id END;  -- @pg-only
    IF st IS DISTINCT FROM 'OPEN' THEN RAISE EXCEPTION 'box_sealed'; END IF;                               -- @pg-only
    IF TG_OP = 'UPDATE' AND NEW.box_id <> OLD.box_id THEN RAISE EXCEPTION 'box_sealed'; END IF;            -- @pg-only
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;                                                           -- @pg-only
    RETURN NEW;                                                                                            -- @pg-only
END $$;                                                                                                    -- @pg-only
CREATE TRIGGER trg_box_line_guard BEFORE INSERT OR UPDATE OR DELETE ON pack_box_line FOR EACH ROW EXECUTE FUNCTION trg_box_line_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_box_line_ins BEFORE INSERT ON pack_box_line
-- @sqlite-only WHEN COALESCE((SELECT status FROM pack_box WHERE id = NEW.box_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_sealed'); END;
-- @sqlite-only CREATE TRIGGER trg_box_line_upd BEFORE UPDATE ON pack_box_line
-- @sqlite-only WHEN NEW.box_id <> OLD.box_id OR COALESCE((SELECT status FROM pack_box WHERE id = OLD.box_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_sealed'); END;
-- @sqlite-only CREATE TRIGGER trg_box_line_del BEFORE DELETE ON pack_box_line
-- @sqlite-only WHEN COALESCE((SELECT status FROM pack_box WHERE id = OLD.box_id), '') <> 'OPEN'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'box_sealed'); END;

GRANT SELECT, INSERT, UPDATE ON check_record, check_line, box_void_request TO wms_app;   -- @pg-only
GRANT SELECT, INSERT ON check_op, check_picker TO wms_app;                               -- @pg-only
GRANT UPDATE (result_code, finished_at) ON check_op TO wms_app;                          -- @pg-only
GRANT DELETE ON pack_box_line, shipment_order TO wms_app;  -- 只在箱 OPEN / 车次 CREATED 时可删（触发器限定）-- @pg-only
GRANT SELECT, INSERT, UPDATE ON pack_box, pack_box_line, shipment, shipment_order TO wms_app;  -- @pg-only
