-- =============================================================================
-- 加工中心（docs/17，米雪儿）：BOM / 出成率、加工单、原料领用（含 LIVE_TANK 池位）、报工产出、损耗、批次追溯、冲回
--   数量一律 *_qty_milli（00 §6.3）；出成率、容差一律万分比整数 *_bp（10000 = 100%）。
--   守恒一律按净重：base_uom=KG 的 qty_milli 即克；按件 SKU 领用时按 issue_pcs × unit_net_weight_g 换算（快照自 01 sku.std_net_weight_g，#8 新增）。
--   库存侧只调 02 原语（#2 6008032）：领用 move + place_hold(PROCESSING)；报工 consume_process_hold（成品+副产+损耗）+ post_in(PROCESS_OUTPUT)；
--   领用冲回 release_hold + move；产出冲回 post_out(PROCESS_REVERSE)。本篇不改 02 的任何表和 CHECK（ck_hold_type/ck_hold_reason/ck_hold_process 以 #2 为准）。
--   外键：本篇内部 + 指向 01/02 的现在加；指向 09 scrap_order、18 live_weigh、12 审批的等对应篇合并后再加（Doro P6）。
-- =============================================================================

CREATE TABLE process_bom (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(32)  NOT NULL,           -- BOM 编码，同编码多版本
    bom_version         INTEGER      NOT NULL,
    name                VARCHAR(128) NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'DRAFT',   -- DRAFT/ACTIVE/RETIRED，只能前进（trg_pbom_forward）
    yield_min_bp        INTEGER      NOT NULL,           -- 成品出成率下限（成品净重 / 原料净投入）
    yield_max_bp        INTEGER      NOT NULL,           -- 上限；越界不拦，转 PROCESS_YIELD_DEVIATION 审批
    loss_max_bp         INTEGER      NOT NULL DEFAULT 10000,  -- 损耗率上限（损耗 / 净投入）；超出同样走 PROCESS_YIELD_DEVIATION（与出成率合并一张审批单）
    balance_tol_bp      INTEGER      NOT NULL DEFAULT 50,  -- 只管称重差：完工余料 ≤ 净投入 × tol 转 WEIGH_DIFF；超出必须先领用冲回
    created_by          BIGINT       NOT NULL,
    activated_at        TIMESTAMP,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_pbom UNIQUE (warehouse_id, code, bom_version),
    CONSTRAINT fk_pbom_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT ck_pbom_status CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    CONSTRAINT ck_pbom_ver    CHECK (bom_version >= 1),
    CONSTRAINT ck_pbom_yield  CHECK (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000),
    CONSTRAINT ck_pbom_loss   CHECK (loss_max_bp >= 0 AND loss_max_bp <= 10000),
    CONSTRAINT ck_pbom_tol    CHECK (balance_tol_bp >= 0 AND balance_tol_bp <= 1000),
    CONSTRAINT ck_pbom_act    CHECK (status = 'DRAFT' OR activated_at IS NOT NULL)
);
-- 同仓同编码只能有一个 ACTIVE 版本
CREATE UNIQUE INDEX uq_pbom_active ON process_bom(warehouse_id, code) WHERE status = 'ACTIVE';
-- 状态只前进 DRAFT→ACTIVE→RETIRED（不允许 ACTIVE→DRAFT 再改行绕过 trg_pboml_frozen）；非 DRAFT 时配置列只读
CREATE FUNCTION trg_pbom_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NOT ((OLD.status = NEW.status) OR (OLD.status = 'DRAFT' AND NEW.status = 'ACTIVE')                     -- @pg-only
            OR (OLD.status = 'ACTIVE' AND NEW.status = 'RETIRED'))                                            -- @pg-only
       OR (OLD.status <> 'DRAFT' AND (NEW.yield_min_bp IS DISTINCT FROM OLD.yield_min_bp                      -- @pg-only
            OR NEW.yield_max_bp IS DISTINCT FROM OLD.yield_max_bp OR NEW.loss_max_bp IS DISTINCT FROM OLD.loss_max_bp  -- @pg-only
            OR NEW.balance_tol_bp IS DISTINCT FROM OLD.balance_tol_bp OR NEW.code IS DISTINCT FROM OLD.code   -- @pg-only
            OR NEW.bom_version IS DISTINCT FROM OLD.bom_version OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id)) THEN  -- @pg-only
        RAISE EXCEPTION 'bom_forward_only' USING ERRCODE = '23514';                                          -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_pbom_forward BEFORE UPDATE ON process_bom FOR EACH ROW EXECUTE FUNCTION trg_pbom_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_pbom_forward BEFORE UPDATE ON process_bom
-- @sqlite-only WHEN NOT ((OLD.status = NEW.status) OR (OLD.status = 'DRAFT' AND NEW.status = 'ACTIVE') OR (OLD.status = 'ACTIVE' AND NEW.status = 'RETIRED'))
-- @sqlite-only   OR (OLD.status <> 'DRAFT' AND (NEW.yield_min_bp IS NOT OLD.yield_min_bp OR NEW.yield_max_bp IS NOT OLD.yield_max_bp
-- @sqlite-only        OR NEW.loss_max_bp IS NOT OLD.loss_max_bp OR NEW.balance_tol_bp IS NOT OLD.balance_tol_bp OR NEW.code IS NOT OLD.code
-- @sqlite-only        OR NEW.bom_version IS NOT OLD.bom_version OR NEW.warehouse_id IS NOT OLD.warehouse_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'bom_forward_only'); END;

CREATE TABLE process_bom_line (
    id                  BIGINT       PRIMARY KEY,
    bom_id              BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    line_role           VARCHAR(16)  NOT NULL,           -- INPUT 原料 / FINISHED 成品 / BYPRODUCT 副产品
    sku_id              BIGINT       NOT NULL,
    std_qty_milli       BIGINT       NOT NULL,           -- 每批标准量（按 base_uom 的 1/1000）
    CONSTRAINT uq_pboml UNIQUE (bom_id, line_no),
    CONSTRAINT uq_pboml_sku UNIQUE (bom_id, line_role, sku_id),
    CONSTRAINT fk_pboml_bom FOREIGN KEY (bom_id) REFERENCES process_bom(id),
    CONSTRAINT fk_pboml_sku FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT ck_pboml_role CHECK (line_role IN ('INPUT','FINISHED','BYPRODUCT')),
    CONSTRAINT ck_pboml_qty  CHECK (std_qty_milli > 0 AND std_qty_milli = CAST(std_qty_milli AS BIGINT) AND line_no >= 1)
);
-- BOM 生效后只读：改配方 = 新版本（加工单下达时另有快照，双保险）
CREATE FUNCTION trg_pboml_frozen() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF EXISTS (SELECT 1 FROM process_bom b WHERE b.id = COALESCE(NEW.bom_id, OLD.bom_id) AND b.status <> 'DRAFT')   -- @pg-only
       OR (TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM process_bom b WHERE b.id = OLD.bom_id AND b.status <> 'DRAFT')) THEN  -- @pg-only
        RAISE EXCEPTION 'bom_frozen' USING ERRCODE = '23514';                                                -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN COALESCE(NEW, OLD);                                                                                -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_pboml_frozen BEFORE INSERT OR UPDATE OR DELETE ON process_bom_line FOR EACH ROW EXECUTE FUNCTION trg_pboml_frozen();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_i BEFORE INSERT ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = NEW.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_u BEFORE UPDATE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id IN (OLD.bom_id, NEW.bom_id) AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;
-- @sqlite-only CREATE TRIGGER trg_pboml_frozen_d BEFORE DELETE ON process_bom_line WHEN EXISTS (SELECT 1 FROM process_bom b WHERE b.id = OLD.bom_id AND b.status <> 'DRAFT') BEGIN SELECT RAISE(ABORT, 'bom_frozen'); END;

-- 加工单。守恒（Doro 拍板 Q-a/Q-c/C1–C5）：
--   净投入 net_in   = issued − reversed − reworked（返工回台的成品不算新原料）
--   已消耗 consumed = output + byproduct + loss + scrapped + reworked      （ck_prc_consume，任何时刻成立）
--   余料   residual = issued − reversed − consumed ≥ 0                     （ck_prc_cap；= 该单 PROCESSING 冻结余量之和，日终核对）
--   完工/待审批：residual = 0                                               （ck_prc_balance；≤ tol 的余料已转 WEIGH_DIFF 并 consume）
--   出成率 = output × 10000 / net_in（output 已扣除报废冲回）；越界判定用交叉相乘，不用取整值
CREATE TABLE process_order (
    id                      BIGINT       PRIMARY KEY,
    warehouse_id            BIGINT       NOT NULL,
    code                    VARCHAR(48)  NOT NULL,       -- PRC-{仓}-{节点}-{作业日}-{序号}（00 §6.2）
    work_date               DATE         NOT NULL,
    bom_id                  BIGINT       NOT NULL,
    process_location_id     BIGINT       NOT NULL,       -- 加工中心库位（location_type=PROCESS，#8 待加）
    planned_input_qty_milli BIGINT       NOT NULL,
    status                  VARCHAR(20)  NOT NULL DEFAULT 'CREATED',  -- CREATED/RELEASED/IN_PROGRESS/PENDING_APPROVAL/COMPLETED/CANCELLED（trg_prc_flow 白名单）
    bom_code                VARCHAR(32),
    bom_version             INTEGER,
    bom_snapshot            TEXT,                        -- BOM 行 JSON
    yield_min_bp            INTEGER,
    yield_max_bp            INTEGER,
    loss_max_bp             INTEGER,
    balance_tol_bp          INTEGER,
    issued_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 累计领用（含返工回台）
    reversed_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 累计领用冲回
    consumed_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 累计 consume_process_hold 扣减量（只增）
    output_qty_milli        BIGINT       NOT NULL DEFAULT 0,  -- 成品净额（扣除产出冲回）
    byproduct_qty_milli     BIGINT       NOT NULL DEFAULT 0,  -- 副产品净额（扣除产出冲回）
    loss_qty_milli          BIGINT       NOT NULL DEFAULT 0,  -- 损耗（含 WEIGH_DIFF）；损耗冲回只改原因/拆分，合计不变
    scrapped_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 产出冲回报废（post_out PROCESS_REVERSE）累计，只增
    reworked_qty_milli      BIGINT       NOT NULL DEFAULT 0,  -- 产出冲回返工回台（需主管 approval_no）累计，只增
    yield_bp                INTEGER,                      -- 完工时 = output * 10000 / net_in，整除（仅展示；判定用交叉相乘）
    approval_no             VARCHAR(40),                  -- PROCESS_YIELD_DEVIATION 审批单号（出成率 + 损耗合并一张）
    approval_expires_at     TIMESTAMP,                    -- 待审批过期时刻（≤ 进入 PENDING_APPROVAL + 12h，第 12 篇过期回调 → 第 10 篇异常，不自动通过）
    created_by              BIGINT       NOT NULL,
    released_at             TIMESTAMP,
    completed_at            TIMESTAMP,
    cancel_reason           VARCHAR(128),
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prc_code UNIQUE (code),
    CONSTRAINT fk_prc_bom FOREIGN KEY (bom_id) REFERENCES process_bom(id),
    CONSTRAINT fk_prc_wh  FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT fk_prc_loc FOREIGN KEY (process_location_id) REFERENCES location(id),
    CONSTRAINT ck_prc_status CHECK (status IN ('CREATED','RELEASED','IN_PROGRESS','PENDING_APPROVAL','COMPLETED','CANCELLED')),
    CONSTRAINT ck_prc_int CHECK (
        planned_input_qty_milli = CAST(planned_input_qty_milli AS BIGINT)
        AND issued_qty_milli = CAST(issued_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
        AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)
        AND output_qty_milli = CAST(output_qty_milli AS BIGINT) AND byproduct_qty_milli = CAST(byproduct_qty_milli AS BIGINT)
        AND loss_qty_milli = CAST(loss_qty_milli AS BIGINT) AND scrapped_qty_milli = CAST(scrapped_qty_milli AS BIGINT)
        AND reworked_qty_milli = CAST(reworked_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_prc_nonneg CHECK (
        planned_input_qty_milli > 0 AND issued_qty_milli >= 0 AND reversed_qty_milli >= 0 AND consumed_qty_milli >= 0
        AND output_qty_milli >= 0 AND byproduct_qty_milli >= 0 AND loss_qty_milli >= 0
        AND scrapped_qty_milli >= 0 AND reworked_qty_milli >= 0
    ),
    CONSTRAINT ck_prc_reverse CHECK (reversed_qty_milli <= issued_qty_milli),
    -- 已消耗 = 各去向之和（C2）
    CONSTRAINT ck_prc_consume CHECK (
        consumed_qty_milli = output_qty_milli + byproduct_qty_milli + loss_qty_milli + scrapped_qty_milli + reworked_qty_milli
    ),
    -- 余料 ≥ 0：消耗不能超过净领用（超冲回交给 ck_prc_reverse 报）
    CONSTRAINT ck_prc_cap CHECK (reversed_qty_milli > issued_qty_milli
        OR consumed_qty_milli <= issued_qty_milli - reversed_qty_milli),
    CONSTRAINT ck_prc_snapshot CHECK (
        status = 'CREATED'
        OR (status = 'CANCELLED' AND released_at IS NULL)
        OR (released_at IS NOT NULL AND bom_code IS NOT NULL AND bom_version IS NOT NULL AND bom_snapshot IS NOT NULL
            AND yield_min_bp IS NOT NULL AND yield_max_bp IS NOT NULL AND loss_max_bp IS NOT NULL AND balance_tol_bp IS NOT NULL)
    ),
    CONSTRAINT ck_prc_yrange CHECK (yield_min_bp IS NULL OR (yield_min_bp > 0 AND yield_min_bp <= yield_max_bp AND yield_max_bp <= 20000)),
    -- 完工（含待审批）：余料为 0，且净投入 > 0
    CONSTRAINT ck_prc_balance CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (issued_qty_milli - reversed_qty_milli - reworked_qty_milli > 0
            AND consumed_qty_milli = issued_qty_milli - reversed_qty_milli)
    ),
    CONSTRAINT ck_prc_yield CHECK (
        (status NOT IN ('PENDING_APPROVAL','COMPLETED') AND yield_bp IS NULL)
        OR (status IN ('PENDING_APPROVAL','COMPLETED') AND issued_qty_milli - reversed_qty_milli - reworked_qty_milli > 0
            AND yield_bp = output_qty_milli * 10000 / (issued_qty_milli - reversed_qty_milli - reworked_qty_milli))
    ),
    -- 偏差（出成率越界 或 损耗率超上限）⇔ 必须挂 PROCESS_YIELD_DEVIATION；交叉相乘判定，避免整除截断误判（F4）
    CONSTRAINT ck_prc_dev CHECK (
        status NOT IN ('PENDING_APPROVAL','COMPLETED')
        OR (output_qty_milli * 10000 >= yield_min_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND output_qty_milli * 10000 <= yield_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND loss_qty_milli * 10000 <= loss_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
            AND approval_no IS NULL AND status = 'COMPLETED')
        OR ((output_qty_milli * 10000 < yield_min_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
             OR output_qty_milli * 10000 > yield_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli)
             OR loss_qty_milli * 10000 > loss_max_bp * (issued_qty_milli - reversed_qty_milli - reworked_qty_milli))
            AND approval_no IS NOT NULL)
    ),
    -- 待审批必须带过期时刻（Q-f：最长 12h，由第 12 篇审批过期回调触发，过期转第 10 篇异常，绝不自动通过）
    CONSTRAINT ck_prc_apr_exp CHECK (status <> 'PENDING_APPROVAL' OR approval_expires_at IS NOT NULL),
    CONSTRAINT ck_prc_done CHECK ((status = 'COMPLETED') = (completed_at IS NOT NULL)),
    -- 撤销：领用全部冲回，没有任何消耗
    CONSTRAINT ck_prc_cancel CHECK (
        status <> 'CANCELLED'
        OR (issued_qty_milli = reversed_qty_milli AND consumed_qty_milli = 0
            AND cancel_reason IS NOT NULL AND length(cancel_reason) > 0)
    ),
    -- 审批单号格式同 02 ck_hold_approval_no（APR-{仓库编码}-{yyyyMMdd}-{6 位}，真实日历日）
    CONSTRAINT ck_prc_apr CHECK (approval_no IS NULL OR CASE  -- @pg-only
        WHEN approval_no !~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$' THEN false  -- @pg-only
        WHEN substr(substr(right(approval_no, 15), 1, 8), 1, 4) = '0000' THEN false  -- @pg-only
        ELSE substr(substr(right(approval_no, 15), 1, 8), 7, 2)::int <= extract(day FROM make_date(substr(substr(right(approval_no, 15), 1, 8), 1, 4)::int, substr(substr(right(approval_no, 15), 1, 8), 5, 2)::int, 1) + interval '1 month' - interval '1 day')  -- @pg-only
    END)  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_prc_apr CHECK (approval_no IS NULL OR (
-- @sqlite-only         length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
-- @sqlite-only         AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only         AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only         AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
-- @sqlite-only         AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]')
-- @sqlite-only         AND substr(approval_no, -15, 4) <> '0000'
-- @sqlite-only         AND date(substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)) = substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)))
);
CREATE INDEX ix_prc_status ON process_order(warehouse_id, status, work_date, bom_code);
CREATE UNIQUE INDEX uq_prc_apr ON process_order(approval_no) WHERE approval_no IS NOT NULL;
-- 快照只读、终态只读、累计列只增（领用/冲回/消耗/报废/返工）
CREATE FUNCTION trg_prc_snapshot() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF (OLD.status <> 'CREATED' AND (NEW.bom_id IS DISTINCT FROM OLD.bom_id OR NEW.bom_code IS DISTINCT FROM OLD.bom_code  -- @pg-only
         OR NEW.bom_version IS DISTINCT FROM OLD.bom_version OR NEW.bom_snapshot IS DISTINCT FROM OLD.bom_snapshot      -- @pg-only
         OR NEW.yield_min_bp IS DISTINCT FROM OLD.yield_min_bp OR NEW.yield_max_bp IS DISTINCT FROM OLD.yield_max_bp    -- @pg-only
         OR NEW.loss_max_bp IS DISTINCT FROM OLD.loss_max_bp                                                  -- @pg-only
         OR NEW.balance_tol_bp IS DISTINCT FROM OLD.balance_tol_bp OR NEW.released_at IS DISTINCT FROM OLD.released_at))  -- @pg-only
       OR OLD.status IN ('COMPLETED','CANCELLED')                                                             -- @pg-only
       OR NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id            -- @pg-only
       OR NEW.issued_qty_milli < OLD.issued_qty_milli OR NEW.reversed_qty_milli < OLD.reversed_qty_milli     -- @pg-only
       OR NEW.consumed_qty_milli < OLD.consumed_qty_milli OR NEW.scrapped_qty_milli < OLD.scrapped_qty_milli -- @pg-only
       OR NEW.reworked_qty_milli < OLD.reworked_qty_milli THEN                                               -- @pg-only
        RAISE EXCEPTION 'process_order_frozen' USING ERRCODE = '23514';                                      -- @pg-only
    END IF;                                                                                                   -- @pg-only
    -- 状态迁移白名单（§5.1，S1-4）                                                                           -- @pg-only
    IF NOT (OLD.status = NEW.status                                                                           -- @pg-only
            OR (OLD.status = 'CREATED' AND NEW.status IN ('RELEASED','CANCELLED'))                            -- @pg-only
            OR (OLD.status = 'RELEASED' AND NEW.status IN ('IN_PROGRESS','CANCELLED'))                        -- @pg-only
            OR (OLD.status = 'IN_PROGRESS' AND NEW.status IN ('PENDING_APPROVAL','COMPLETED','CANCELLED'))    -- @pg-only
            OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('COMPLETED','IN_PROGRESS'))) THEN          -- @pg-only
        RAISE EXCEPTION 'process_order_bad_transition' USING ERRCODE = '23514';                              -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prc_snapshot BEFORE UPDATE ON process_order FOR EACH ROW EXECUTE FUNCTION trg_prc_snapshot();  -- @pg-only
CREATE FUNCTION trg_prc_insert() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.status <> 'CREATED' THEN RAISE EXCEPTION 'process_order_bad_transition' USING ERRCODE = '23514'; END IF;  -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prc_insert BEFORE INSERT ON process_order FOR EACH ROW EXECUTE FUNCTION trg_prc_insert();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prc_snapshot BEFORE UPDATE ON process_order
-- @sqlite-only WHEN (OLD.status <> 'CREATED' AND (NEW.bom_id IS NOT OLD.bom_id OR NEW.bom_code IS NOT OLD.bom_code
-- @sqlite-only        OR NEW.bom_version IS NOT OLD.bom_version OR NEW.bom_snapshot IS NOT OLD.bom_snapshot
-- @sqlite-only        OR NEW.yield_min_bp IS NOT OLD.yield_min_bp OR NEW.yield_max_bp IS NOT OLD.yield_max_bp OR NEW.loss_max_bp IS NOT OLD.loss_max_bp
-- @sqlite-only        OR NEW.balance_tol_bp IS NOT OLD.balance_tol_bp OR NEW.released_at IS NOT OLD.released_at))
-- @sqlite-only   OR OLD.status IN ('COMPLETED','CANCELLED')
-- @sqlite-only   OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
-- @sqlite-only   OR NEW.issued_qty_milli < OLD.issued_qty_milli OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
-- @sqlite-only   OR NEW.consumed_qty_milli < OLD.consumed_qty_milli OR NEW.scrapped_qty_milli < OLD.scrapped_qty_milli
-- @sqlite-only   OR NEW.reworked_qty_milli < OLD.reworked_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_order_frozen'); END;
-- @sqlite-only CREATE TRIGGER trg_prc_flow BEFORE UPDATE OF status ON process_order
-- @sqlite-only WHEN NOT (OLD.status = NEW.status
-- @sqlite-only   OR (OLD.status = 'CREATED' AND NEW.status IN ('RELEASED','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'RELEASED' AND NEW.status IN ('IN_PROGRESS','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'IN_PROGRESS' AND NEW.status IN ('PENDING_APPROVAL','COMPLETED','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('COMPLETED','IN_PROGRESS')))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_order_bad_transition'); END;
-- @sqlite-only CREATE TRIGGER trg_prc_insert BEFORE INSERT ON process_order WHEN NEW.status <> 'CREATED'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_order_bad_transition'); END;
-- @sqlite-only CREATE TRIGGER trg_prc_dup BEFORE INSERT ON process_order
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_order o WHERE o.id = NEW.id OR o.code = NEW.code)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_order_duplicate'); END;

-- 原料领用：一行 = 从一个来源 stock 行领一个批次。库存侧同一事务：move(src → pc) + place_hold(pc_stock, PROCESSING, PROCESS_ORDER, op_key)
-- 报工：consume_process_hold(hold_id, qty, biz=(PROCESS_CONSUME, 加工单号, 领用行号, 报工序号), op_key=PRCC:{order}:{report_seq}:{line_no}) 累加 consumed_qty_milli
CREATE TABLE process_issue (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,           -- PRCI:{process_order_id}:{issue_client_id}（PDA UUID），= stock_hold.op_key（#2 ck_hold_process）
    src_location_id     BIGINT       NOT NULL,
    src_location_type   VARCHAR(16)  NOT NULL,           -- 冗余来源库位类型；LIVE_TANK = 活鲜池（第 18 篇）；REWORK = 产出冲回返工回台
    src_stock_id        BIGINT       NOT NULL,
    pc_stock_id         BIGINT       NOT NULL,           -- 加工中心库位上的 stock 行
    hold_id             BIGINT       NOT NULL,           -- stock_hold(PROCESSING).id
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,
    lot_expiry_date     DATE         NOT NULL,
    issue_qty_milli     BIGINT       NOT NULL,           -- 净重（milli-KG = 克）
    issue_pcs           INTEGER,                         -- 按件 SKU：件数（S2/F3）
    unit_net_weight_g   INTEGER,                         -- 按件 SKU：领用时快照 01 sku.std_net_weight_g（为空 → 40001 拒绝领用）
    issue_count         INTEGER,                         -- 尾数：LIVE_TANK 必填（第 18 篇双计量）
    live_weigh_id       BIGINT,                          -- LIVE_TANK：18 出池称重 live_weigh(task_kind=PROCESS_ISSUE, ACCEPTED).id；FK 待 #12 合并
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- 领用冲回（release_hold + move 回来源库位；LIVE_TANK 不回池，退加工暂存位）
    consumed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- consume_process_hold 累计
    issued_by           BIGINT       NOT NULL,
    issued_at           TIMESTAMP    NOT NULL DEFAULT now(),
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_prci UNIQUE (process_order_id, line_no),
    CONSTRAINT uq_prci_op UNIQUE (op_key),
    CONSTRAINT uq_prci_hold UNIQUE (hold_id),
    CONSTRAINT fk_prci_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prci_hold  FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_prci_src   FOREIGN KEY (src_stock_id) REFERENCES stock(id),
    CONSTRAINT fk_prci_pc    FOREIGN KEY (pc_stock_id) REFERENCES stock(id),
    CONSTRAINT fk_prci_lot   FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_prci_sku   FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT ck_prci_int CHECK (issue_qty_milli = CAST(issue_qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
                                  AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prci_qty CHECK (issue_qty_milli > 0 AND reversed_qty_milli >= 0 AND consumed_qty_milli >= 0 AND line_no >= 1),
    -- 冲回 + 消耗 ≤ 领用（= PROCESSING 冻结 released ≤ hold）；冲回超量 42214 detail.reason=OVER_REVERSE + {process_order_id, line_id, max_reversible_qty_milli}（00 §6.4，#2 1d907031）
    CONSTRAINT ck_prci_reverse CHECK (reversed_qty_milli + consumed_qty_milli <= issue_qty_milli),
    CONSTRAINT ck_prci_op CHECK (op_key LIKE 'PRCI:%'),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_prci_op CHECK (op_key GLOB 'PRCI:*'),
    CONSTRAINT ck_prci_live CHECK (
        (src_location_type = 'LIVE_TANK' AND issue_count IS NOT NULL AND issue_count > 0 AND live_weigh_id IS NOT NULL)
        OR (src_location_type <> 'LIVE_TANK' AND issue_count IS NULL AND live_weigh_id IS NULL)
    ),
    -- 按件换算：件数与单件净重成对出现，净重 = 件数 × 单件净重（g = milli-KG）
    CONSTRAINT ck_prci_pcs CHECK (
        (issue_pcs IS NULL AND unit_net_weight_g IS NULL)
        OR (issue_pcs IS NOT NULL AND unit_net_weight_g IS NOT NULL AND issue_pcs > 0 AND unit_net_weight_g > 0
            AND issue_qty_milli = issue_pcs * unit_net_weight_g
            AND reversed_qty_milli % unit_net_weight_g = 0 AND consumed_qty_milli % unit_net_weight_g = 0)   -- 按件只能整件冲回/消耗
    )
);
CREATE INDEX ix_prci_lot ON process_issue(lot_id);
-- 领用行关键列只读、累计列只增、不可删（S1-2）
CREATE FUNCTION trg_prci_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'DELETE' OR NEW.issue_qty_milli IS DISTINCT FROM OLD.issue_qty_milli OR NEW.hold_id IS DISTINCT FROM OLD.hold_id  -- @pg-only
       OR NEW.lot_id IS DISTINCT FROM OLD.lot_id OR NEW.src_stock_id IS DISTINCT FROM OLD.src_stock_id        -- @pg-only
       OR NEW.pc_stock_id IS DISTINCT FROM OLD.pc_stock_id OR NEW.sku_id IS DISTINCT FROM OLD.sku_id          -- @pg-only
       OR NEW.process_order_id IS DISTINCT FROM OLD.process_order_id OR NEW.op_key IS DISTINCT FROM OLD.op_key  -- @pg-only
       OR NEW.reversed_qty_milli < OLD.reversed_qty_milli OR NEW.consumed_qty_milli < OLD.consumed_qty_milli THEN  -- @pg-only
        RAISE EXCEPTION 'process_issue_immutable' USING ERRCODE = '23514';                                   -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prci_immutable BEFORE UPDATE OR DELETE ON process_issue FOR EACH ROW EXECUTE FUNCTION trg_prci_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prci_immutable BEFORE UPDATE ON process_issue
-- @sqlite-only WHEN NEW.issue_qty_milli IS NOT OLD.issue_qty_milli OR NEW.hold_id IS NOT OLD.hold_id OR NEW.lot_id IS NOT OLD.lot_id
-- @sqlite-only   OR NEW.src_stock_id IS NOT OLD.src_stock_id OR NEW.pc_stock_id IS NOT OLD.pc_stock_id OR NEW.sku_id IS NOT OLD.sku_id
-- @sqlite-only   OR NEW.process_order_id IS NOT OLD.process_order_id OR NEW.op_key IS NOT OLD.op_key
-- @sqlite-only   OR NEW.reversed_qty_milli < OLD.reversed_qty_milli OR NEW.consumed_qty_milli < OLD.consumed_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_issue_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_prci_no_delete BEFORE DELETE ON process_issue BEGIN SELECT RAISE(ABORT, 'process_issue_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_prci_dup BEFORE INSERT ON process_issue
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_issue i WHERE i.id = NEW.id OR i.op_key = NEW.op_key OR i.hold_id = NEW.hold_id
-- @sqlite-only              OR (i.process_order_id = NEW.process_order_id AND i.line_no = NEW.line_no))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_issue_duplicate'); END;

-- 报工（一次提交 = 一行）：业务键 (process_order_id, report_client_id)，长期保留；只缓存成功结果（200/202）
-- key_type=PROCESS_REPORT（00 §6.4 待 Doro 登记）；被拒（4xx）不占键
CREATE TABLE process_report (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_client_id    VARCHAR(36)  NOT NULL,           -- 客户端 UUID
    request_hash        VARCHAR(64)  NOT NULL,           -- 规范化请求体 SHA-256；同键不同 hash → 40910 key_type=PROCESS_REPORT
    report_seq          INTEGER      NOT NULL,           -- 服务端分配：SELECT … FOR UPDATE process_order 后 max+1
    is_final            BOOLEAN      NOT NULL DEFAULT false,
    response_http       INTEGER      NOT NULL,
    response            TEXT         NOT NULL,
    reported_by         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prcr_client UNIQUE (process_order_id, report_client_id),
    CONSTRAINT uq_prcr_seq UNIQUE (process_order_id, report_seq),
    CONSTRAINT fk_prcr_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT ck_prcr_client CHECK (length(report_client_id) = 36 AND substr(report_client_id, 9, 1) = '-' AND substr(report_client_id, 14, 1) = '-'
                                     AND substr(report_client_id, 19, 1) = '-' AND substr(report_client_id, 24, 1) = '-'),
    CONSTRAINT ck_prcr_hash CHECK (length(request_hash) = 64),
    CONSTRAINT ck_prcr_seq  CHECK (report_seq >= 1),
    CONSTRAINT ck_prcr_http CHECK (response_http IN (200, 202))
);

-- 产出明细：成品 / 副产品（post_in PROCESS_OUTPUT 新批次入库）/ 损耗（09 报损单 PROCESS_LOSS，只记账不扣库存——原料已随报工 consume）
CREATE TABLE process_output (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    report_id           BIGINT       NOT NULL,
    line_no             INTEGER      NOT NULL,
    output_role         VARCHAR(16)  NOT NULL,           -- FINISHED/BYPRODUCT/LOSS
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT,
    to_location_id      BIGINT,
    gross_qty_milli     BIGINT       NOT NULL,
    tare_qty_milli      BIGINT       NOT NULL DEFAULT 0,
    qty_milli           BIGINT       NOT NULL,           -- 净重 = 毛重 − 皮重
    reversed_qty_milli  BIGINT       NOT NULL DEFAULT 0, -- FINISHED/BYPRODUCT：产出冲回量（报废或返工）；LOSS：改数量/改原因转出的量
    processed_at        TIMESTAMP    NOT NULL,
    expiry_date         DATE,
    sell_deadline       DATE,
    earliest_raw_expiry DATE,
    scrap_order_id      BIGINT,                          -- LOSS：09 报损单（PROCESS_LOSS）；FK 待 #4 合并
    loss_reason         VARCHAR(24),                     -- LOSS：TRIM/DRIP/WEIGH_DIFF/DEFECT
    from_output_id      BIGINT,                          -- LOSS 改原因/改数量：新行指向被转出的旧 LOSS 行（只在同单内）
    -- 损耗定案（Doro 定）：完工时越界损耗行为 PENDING_APPROVAL，其余 SETTLED。审批回调 / 12h 过期任务的**主守卫**是本行条件更新：
    --   UPDATE process_output SET loss_status = :result, … WHERE id = :loss_line_id AND loss_status = 'PENDING_APPROVAL'
    --   影响 1 行 → 同事务（REJECTED / EXPIRED 时）建第 10 篇异常单（PROCESS_LOSS，PRCL:{id}）、写 outbox wms.process.loss_settled；
    --   影响 0 行 → 已被另一方定案：读回本行 loss_status / loss_exception_no 原样返回，不建异常、不发事件。不动库存（consume_process_hold 已扣）。
    --   第 10 篇 uq_exc_pl_key 是第二道保险。
    loss_status         VARCHAR(24)  NOT NULL DEFAULT 'SETTLED',
    loss_approved_qty_milli BIGINT,                      -- 定案后获批量：APPROVED = qty；REJECTED 通常 0；EXPIRED = 0
    loss_exception_no   VARCHAR(64),                     -- REJECTED / EXPIRED_TO_EXCEPTION：第 10 篇异常单号（差额以 10 为准）
    CONSTRAINT uq_prco UNIQUE (report_id, line_no),
    CONSTRAINT fk_prco_order  FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prco_report FOREIGN KEY (report_id) REFERENCES process_report(id),
    CONSTRAINT fk_prco_sku    FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT fk_prco_lot    FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_prco_loc    FOREIGN KEY (to_location_id) REFERENCES location(id),
    CONSTRAINT fk_prco_from   FOREIGN KEY (from_output_id) REFERENCES process_output(id),
    CONSTRAINT ck_prco_role CHECK (output_role IN ('FINISHED','BYPRODUCT','LOSS')),
    CONSTRAINT ck_prco_int CHECK (gross_qty_milli = CAST(gross_qty_milli AS BIGINT) AND tare_qty_milli = CAST(tare_qty_milli AS BIGINT)
                                  AND qty_milli = CAST(qty_milli AS BIGINT) AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)),
    CONSTRAINT ck_prco_net CHECK (qty_milli > 0 AND tare_qty_milli >= 0 AND qty_milli = gross_qty_milli - tare_qty_milli),
    CONSTRAINT ck_prco_reverse CHECK (reversed_qty_milli >= 0 AND reversed_qty_milli <= qty_milli),
    CONSTRAINT ck_prco_kind CHECK (
        (output_role IN ('FINISHED','BYPRODUCT') AND lot_id IS NOT NULL AND to_location_id IS NOT NULL
             AND expiry_date IS NOT NULL AND earliest_raw_expiry IS NOT NULL AND scrap_order_id IS NULL AND loss_reason IS NULL
             AND from_output_id IS NULL)
        OR (output_role = 'LOSS' AND lot_id IS NULL AND to_location_id IS NULL AND expiry_date IS NULL AND sell_deadline IS NULL
             AND scrap_order_id IS NOT NULL AND loss_reason IN ('TRIM','DRIP','WEIGH_DIFF','DEFECT'))
    ),
    -- 损耗冲回整行转出（对应 09 报损单整张 VOIDED + 新行新单），不做部分冲回
    CONSTRAINT ck_prco_loss_status CHECK (loss_status IN ('SETTLED','PENDING_APPROVAL','APPROVED','REJECTED','EXPIRED_TO_EXCEPTION')
                                          AND (output_role = 'LOSS' OR loss_status = 'SETTLED')),
    CONSTRAINT ck_prco_loss_settle CHECK (
        (loss_status IN ('SETTLED','PENDING_APPROVAL') AND loss_approved_qty_milli IS NULL AND loss_exception_no IS NULL)
        OR (loss_status = 'APPROVED' AND loss_approved_qty_milli = qty_milli AND loss_exception_no IS NULL)
        OR (loss_status = 'REJECTED' AND loss_approved_qty_milli >= 0 AND loss_approved_qty_milli < qty_milli AND loss_exception_no IS NOT NULL)
        OR (loss_status = 'EXPIRED_TO_EXCEPTION' AND loss_approved_qty_milli = 0 AND loss_exception_no IS NOT NULL)),
    CONSTRAINT ck_prco_loss_whole CHECK (output_role <> 'LOSS' OR reversed_qty_milli IN (0, qty_milli)),
    CONSTRAINT ck_prco_expiry CHECK (expiry_date IS NULL OR expiry_date <= earliest_raw_expiry),
    CONSTRAINT ck_prco_sell   CHECK (sell_deadline IS NULL OR (expiry_date IS NOT NULL AND sell_deadline <= expiry_date))
);
CREATE INDEX ix_prco_order ON process_output(process_order_id, output_role);
CREATE UNIQUE INDEX uq_prco_lot ON process_output(lot_id) WHERE lot_id IS NOT NULL;

-- 批次追溯：成品/副产批次 ↔ 原料批次，多对多（§6.6）
CREATE TABLE process_lot_trace (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    output_id           BIGINT       NOT NULL,
    output_lot_id       BIGINT       NOT NULL,
    issue_id            BIGINT       NOT NULL,
    raw_lot_id          BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_plt UNIQUE (output_id, issue_id),
    CONSTRAINT fk_plt_order  FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_plt_output FOREIGN KEY (output_id) REFERENCES process_output(id),
    CONSTRAINT fk_plt_issue  FOREIGN KEY (issue_id) REFERENCES process_issue(id),
    CONSTRAINT fk_plt_olot   FOREIGN KEY (output_lot_id) REFERENCES lot(id),
    CONSTRAINT fk_plt_rlot   FOREIGN KEY (raw_lot_id) REFERENCES lot(id),
    CONSTRAINT ck_plt_self CHECK (output_lot_id <> raw_lot_id)
);
CREATE INDEX ix_plt_out ON process_lot_trace(output_lot_id, raw_lot_id);
CREATE INDEX ix_plt_raw ON process_lot_trace(raw_lot_id, output_lot_id);

-- 冲回记录，只追加。key_type=PROCESS_REVERSAL（00 §6.4 40910 ⑪，#2 1d907031）；op_key = PRCR:{process_order_id}:{reversal_client_id}
--   ISSUE  ：release_hold(hold_id, q, op_key) + move(pc → 来源库位 / LIVE_TANK 来源退加工暂存位)；hold_release_id + movement_ref 必填
--   OUTPUT ：disposition=SCRAP → post_out(lot_stock, q, PROCESS_REVERSE)；REWORK（approval_no = 第 12 篇审批单，类型 PROCESS_REWORK，审批人须持 process.rework.approve；Doro 已定，类型与权限由爱弥斯在 12b_auth_audit.sql 登记）→ move(lot_stock → 加工中心) + place_hold(PROCESSING) 记一条 REWORK 领用行
--   LOSS   ：只改原因/拆数量（新 LOSS 行 from_output_id 指回），不回在制、不动库存；movement_ref/hold_release_id 必为空
CREATE TABLE process_reversal (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    process_order_id    BIGINT       NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,
    reversal_type       VARCHAR(16)  NOT NULL,           -- ISSUE/OUTPUT/LOSS
    disposition         VARCHAR(16),                     -- OUTPUT：SCRAP（默认）/ REWORK
    approval_no         VARCHAR(40),                     -- REWORK 必填：审批单号（审批类型 PROCESS_REWORK / 权限 process.rework.approve，12b 合并后补 FK）
    issue_id            BIGINT,
    output_id           BIGINT,
    qty_milli           BIGINT       NOT NULL,
    movement_ref        VARCHAR(160),                    -- 库存流水 idempotency_key（stock_movement_key.idempotency_key），对账用
    hold_release_id     BIGINT,                          -- ISSUE：stock_hold_release.id（不建 FK：02 verify 断言 TRUNCATE stock_hold_release 由触发器拦，FK 会抢先报错；改由日终对账 §9 核对）
    reason              VARCHAR(128) NOT NULL,
    operator_id         BIGINT       NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT uq_prcv_op UNIQUE (op_key),
    CONSTRAINT fk_prcv_order FOREIGN KEY (process_order_id) REFERENCES process_order(id),
    CONSTRAINT fk_prcv_issue FOREIGN KEY (issue_id) REFERENCES process_issue(id),
    CONSTRAINT fk_prcv_out   FOREIGN KEY (output_id) REFERENCES process_output(id),
    CONSTRAINT fk_prcv_mv    FOREIGN KEY (movement_ref) REFERENCES stock_movement_key(idempotency_key),
    CONSTRAINT ck_prcv_type CHECK (
        (reversal_type = 'ISSUE' AND issue_id IS NOT NULL AND output_id IS NULL AND disposition IS NULL
             AND hold_release_id IS NOT NULL AND movement_ref IS NOT NULL)
        OR (reversal_type = 'OUTPUT' AND output_id IS NOT NULL AND issue_id IS NULL AND hold_release_id IS NULL
             AND movement_ref IS NOT NULL
             AND ((disposition = 'SCRAP' AND approval_no IS NULL) OR (disposition = 'REWORK' AND approval_no IS NOT NULL)))
        OR (reversal_type = 'LOSS' AND output_id IS NOT NULL AND issue_id IS NULL AND disposition IS NULL
             AND hold_release_id IS NULL AND movement_ref IS NULL)
    ),
    CONSTRAINT ck_prcv_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT) AND length(reason) > 0),
    CONSTRAINT ck_prcv_op CHECK (op_key LIKE 'PRCR:%:________-____-____-____-____________'),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_prcv_op CHECK (op_key GLOB 'PRCR:[0-9]*:????????-????-????-????-????????????'),
    CONSTRAINT ck_prcv_apr CHECK (approval_no IS NULL OR length(approval_no) BETWEEN 22 AND 40)
);
CREATE INDEX ix_prcv_order ON process_reversal(process_order_id, created_at);

-- 报工、追溯、冲回只追加
CREATE TRIGGER trg_prcr_append_only BEFORE UPDATE OR DELETE ON process_report    FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_plt_append_only  BEFORE UPDATE OR DELETE ON process_lot_trace FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_prcv_append_only BEFORE UPDATE OR DELETE ON process_reversal  FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prcr_no_update BEFORE UPDATE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
-- @sqlite-only CREATE TRIGGER trg_prcr_no_delete BEFORE DELETE ON process_report    BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_report'); END;
-- @sqlite-only CREATE TRIGGER trg_plt_no_update  BEFORE UPDATE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
-- @sqlite-only CREATE TRIGGER trg_plt_no_delete  BEFORE DELETE ON process_lot_trace BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_lot_trace'); END;
-- @sqlite-only CREATE TRIGGER trg_prcv_no_update BEFORE UPDATE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
-- @sqlite-only CREATE TRIGGER trg_prcv_no_delete BEFORE DELETE ON process_reversal  BEGIN SELECT RAISE(ABORT, 'append_only_violation: process_reversal'); END;
-- B6：SQLite 拦 INSERT OR REPLACE（隐式 DELETE+INSERT 不触发 DELETE 触发器），命中主键或业务键即 ABORT
-- @sqlite-only CREATE TRIGGER trg_prcr_dup BEFORE INSERT ON process_report
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_report r WHERE r.id = NEW.id OR (r.process_order_id = NEW.process_order_id AND (r.report_client_id = NEW.report_client_id OR r.report_seq = NEW.report_seq)))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_report_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_prco_dup BEFORE INSERT ON process_output
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_output o WHERE o.id = NEW.id OR (o.report_id = NEW.report_id AND o.line_no = NEW.line_no) OR (NEW.lot_id IS NOT NULL AND o.lot_id = NEW.lot_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_output_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_plt_dup BEFORE INSERT ON process_lot_trace
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_lot_trace t WHERE t.id = NEW.id OR (t.output_id = NEW.output_id AND t.issue_id = NEW.issue_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_lot_trace_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_prcv_dup BEFORE INSERT ON process_reversal
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM process_reversal v WHERE v.id = NEW.id OR v.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_reversal_duplicate'); END;
-- 产出行：关键列只读，reversed_qty_milli 只增
CREATE FUNCTION trg_prco_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'DELETE' OR NEW.qty_milli IS DISTINCT FROM OLD.qty_milli OR NEW.gross_qty_milli IS DISTINCT FROM OLD.gross_qty_milli  -- @pg-only
       OR NEW.tare_qty_milli IS DISTINCT FROM OLD.tare_qty_milli OR NEW.lot_id IS DISTINCT FROM OLD.lot_id     -- @pg-only
       OR NEW.output_role IS DISTINCT FROM OLD.output_role OR NEW.expiry_date IS DISTINCT FROM OLD.expiry_date  -- @pg-only
       OR NEW.sell_deadline IS DISTINCT FROM OLD.sell_deadline OR NEW.sku_id IS DISTINCT FROM OLD.sku_id        -- @pg-only
       OR NEW.loss_reason IS DISTINCT FROM OLD.loss_reason OR NEW.scrap_order_id IS DISTINCT FROM OLD.scrap_order_id  -- @pg-only
       OR NEW.reversed_qty_milli < OLD.reversed_qty_milli THEN                                                -- @pg-only
        RAISE EXCEPTION 'process_output_immutable' USING ERRCODE = '23514';                                  -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF (NEW.loss_status IS DISTINCT FROM OLD.loss_status AND NOT (OLD.loss_status = 'PENDING_APPROVAL'        -- @pg-only
            AND NEW.loss_status IN ('APPROVED','REJECTED','EXPIRED_TO_EXCEPTION')))                          -- @pg-only
       OR (NEW.loss_status = OLD.loss_status AND (NEW.loss_approved_qty_milli IS DISTINCT FROM OLD.loss_approved_qty_milli  -- @pg-only
            OR NEW.loss_exception_no IS DISTINCT FROM OLD.loss_exception_no)) THEN                            -- @pg-only
        RAISE EXCEPTION 'process_loss_settle_once' USING ERRCODE = '23514';                                  -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_prco_immutable BEFORE UPDATE OR DELETE ON process_output FOR EACH ROW EXECUTE FUNCTION trg_prco_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_prco_immutable BEFORE UPDATE ON process_output
-- @sqlite-only WHEN NEW.qty_milli IS NOT OLD.qty_milli OR NEW.gross_qty_milli IS NOT OLD.gross_qty_milli OR NEW.tare_qty_milli IS NOT OLD.tare_qty_milli
-- @sqlite-only   OR NEW.lot_id IS NOT OLD.lot_id OR NEW.output_role IS NOT OLD.output_role OR NEW.expiry_date IS NOT OLD.expiry_date
-- @sqlite-only   OR NEW.sell_deadline IS NOT OLD.sell_deadline OR NEW.sku_id IS NOT OLD.sku_id
-- @sqlite-only   OR NEW.loss_reason IS NOT OLD.loss_reason OR NEW.scrap_order_id IS NOT OLD.scrap_order_id OR NEW.reversed_qty_milli < OLD.reversed_qty_milli
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_prco_loss_settle_once BEFORE UPDATE ON process_output
-- @sqlite-only WHEN (NEW.loss_status IS NOT OLD.loss_status AND NOT (OLD.loss_status = 'PENDING_APPROVAL' AND NEW.loss_status IN ('APPROVED','REJECTED','EXPIRED_TO_EXCEPTION')))
-- @sqlite-only   OR (NEW.loss_status = OLD.loss_status AND (NEW.loss_approved_qty_milli IS NOT OLD.loss_approved_qty_milli OR NEW.loss_exception_no IS NOT OLD.loss_exception_no))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'process_loss_settle_once'); END;
-- @sqlite-only CREATE TRIGGER trg_prco_no_delete BEFORE DELETE ON process_output BEGIN SELECT RAISE(ABORT, 'process_output_immutable'); END;

GRANT SELECT, INSERT, UPDATE ON process_bom, process_bom_line, process_order, process_issue, process_output TO wms_app;   -- @pg-only
GRANT SELECT, INSERT ON process_report, process_lot_trace, process_reversal TO wms_app;                                    -- 只追加 -- @pg-only
