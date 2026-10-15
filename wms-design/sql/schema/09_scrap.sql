-- =============================================================================
-- 09_scrap.sql —— 第 9 篇 效期与损耗（PR #4，米雪儿接手）自有 DDL
-- 加载顺序：08_count.sql 之后、11_integration.sql 之前。不改别篇文件；本篇没有跨篇 ALTER。
-- 基线 #2 6008032：convert_hold(hold_id, qty, to_hold_type, to_source, op_key) 支持部分转换；可售期到期（SELL_EXPIRED）按 02（6008032）§表 SCRAP_PENDING 行：直接 hold(SCRAP_PENDING)（op_key=SELLEXP:{lot_id}:{date}，operator_id=0），不走 convert_hold，也不走 place_hold（place_hold 只收 PROCESSING / LIVE_HOLD）。
-- 记账型来源（record_only）：PROCESS_LOSS（第 17 篇，原料已随报工 consume_process_hold 扣过）、LIVE_DEATH / LIVE_SHRINK（第 18 篇 consume_live_hold 直接扣，Doro P1）
--   —— 报损单只记账：不冻结（hold_id=0）、行 ledger_mode=NONE、过账不调 post_out。
-- =============================================================================
-- 第 9 篇 效期与损耗：报损单（SCR）。审批通过后由服务端按行调 02 原语 post_out(SCRAP)；
-- SCRAP_PENDING 冻结 source_type='SCRAP'、source_id=本表 id（04 N2）（op_key = SCRH:{scrap_line_id}），审批出账与解冻同事务。
CREATE TABLE scrap_order (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,   -- SCR-{仓}-{节点}-{作业日}-{序号}
    warehouse_id    BIGINT          NOT NULL,
    source_type     VARCHAR(24)     NOT NULL,   -- 取值见 ck_scr_src_type；SELL_EXPIRED：可售天数到期扫描（source_id=lot_id，来源键 SELL_EXPIRED:{lot_id}:{date}，落库 source_id=lot_id + source_date=作业日，见 uq_scr_source；冻结 op_key SELLEXP:{lot_id}:{date}）；RETURN_HANDOVER：04 交接，source_id=待回库记录 id；RETURN_QC：10 质检不合格，source_id=inbound_line.id
    source_id       BIGINT          NOT NULL DEFAULT 0,
    source_date     DATE            NOT NULL DEFAULT '1970-01-01',   -- 00 §6.4 D3：按日去重白名单（SELL_EXPIRED / LIVE_SHRINK）写仓库作业日；其余来源固定 '1970-01-01'
    reason_code     VARCHAR(24)     NOT NULL,   -- 取值见 ck_scr_reason
    status          VARCHAR(16)     NOT NULL DEFAULT 'DRAFT',
    work_date       DATE            NOT NULL,   -- 仓库时区作业日
    amount_impact   BIGINT          NOT NULL DEFAULT 0,   -- 分
    applicant_id    BIGINT          NOT NULL,
    approver_id     BIGINT,
    approved_at     TIMESTAMP,
    posted_at       TIMESTAMP,
    void_approval_no VARCHAR(64),
    void_ref        VARCHAR(80),                -- PROCESS_LOSS 作废：17 process_reversal.op_key（PRCR:{order}:{uuid}）
    record_only     BOOLEAN         GENERATED ALWAYS AS (source_type IN ('PROCESS_LOSS','LIVE_DEATH','LIVE_SHRINK')) STORED,   -- 记账型（不冻结、不出账）；由来源推出，应用写不进               -- 交接误报作废（SCRAP_MISREPORT 审批单号，第 12 篇）；只有 VOIDED 才有
    version         BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_scr_code   UNIQUE (code),
    CONSTRAINT ck_scr_status CHECK (status IN ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED','REJECTED','CANCELLED','VOIDED')),
    CONSTRAINT ck_scr_void   CHECK ((status = 'VOIDED') = ((void_approval_no IS NOT NULL AND length(void_approval_no) > 0) OR void_ref IS NOT NULL)),
    -- 审批单号全局格式 APR-{仓库编码 [A-Z0-9]{2,16}}-{yyyyMMdd}-{6位序号}（Q17，与 02 ck_hold_approval_no 一致）
    CONSTRAINT ck_scr_apr_fmt CHECK (void_approval_no IS NULL OR void_approval_no ~ '^APR-[A-Z0-9]{2,16}-[0-9]{8}-[0-9]{6}$'),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_scr_apr_fmt CHECK (void_approval_no IS NULL OR (length(void_approval_no) BETWEEN 22 AND 36 AND void_approval_no GLOB 'APR-?*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' AND substr(void_approval_no, 5, length(void_approval_no) - 20) NOT GLOB '*[^A-Z0-9]*')),
    CONSTRAINT ck_scr_sod    CHECK (approver_id IS NULL OR approver_id <> applicant_id),
    -- 小赵复评 S1：审批 / 过账后的人员与时间必须齐
    -- 记账型在容差内可 DRAFT → POSTED 直接过账（无人审）；超容差走 PENDING_APPROVAL（PROCESS_LOSS 的审批即 17 的 PROCESS_YIELD_DEVIATION 合并单）
    CONSTRAINT ck_scr_appr   CHECK (status NOT IN ('APPROVED','POSTED') OR (approver_id IS NOT NULL AND approved_at IS NOT NULL)
                                    OR (record_only AND status = 'POSTED' AND approver_id IS NULL AND approved_at IS NULL)),
    CONSTRAINT ck_scr_posted CHECK (status <> 'POSTED' OR posted_at IS NOT NULL),
    CONSTRAINT ck_scr_src_type CHECK (source_type IN ('EXPIRY_SCAN','SELL_EXPIRED','MANUAL','RETURN_QC','RETURN_HANDOVER','COUNT','EXCEPTION','LIVE_DEATH','LIVE_SHRINK','PROCESS_LOSS')),
    -- 00 §6.4 D3（大肥鱼定）：按日去重白名单 SELL_EXPIRED / LIVE_SHRINK 的 source_date = work_date；其余来源（含 LIVE_DEATH）固定 '1970-01-01'
    CONSTRAINT ck_scr_src_date CHECK (CASE WHEN source_type IN ('SELL_EXPIRED','LIVE_SHRINK') THEN source_date = work_date ELSE source_date = '1970-01-01' END),
    CONSTRAINT ck_scr_reason CHECK (reason_code IN ('EXPIRED','NEAR_EXPIRY','SELL_EXPIRED','DAMAGED','QC_REJECT','NATURAL_LOSS','OTHER',
                                                  'TRIM','DRIP','WEIGH_DIFF','DEFECT','LIVE_DEATH')),
    -- 加工损耗原因只给 PROCESS_LOSS 用；PROCESS_LOSS 只收这 4 个（17 process_output.loss_reason 一一对应，不再映射成 NATURAL_LOSS）
    CONSTRAINT ck_scr_reason_src CHECK (
        (source_type = 'PROCESS_LOSS') = (reason_code IN ('TRIM','DRIP','WEIGH_DIFF','DEFECT'))
        AND (reason_code <> 'LIVE_DEATH' OR source_type = 'LIVE_DEATH')
    ),
    -- PROCESS_LOSS 作废（17 损耗改原因/改数量）挂 17 冲回键 void_ref=PRCR:…，不走 SCRAP_MISREPORT
    CONSTRAINT ck_scr_void_ref CHECK (void_ref IS NULL OR (source_type = 'PROCESS_LOSS' AND status = 'VOIDED' AND void_ref LIKE 'PRCR:%'))
);
CREATE INDEX ix_scr_wh_status ON scrap_order(warehouse_id, status, work_date);
-- 00 §6.4 D3：三列唯一，对所有来源生效；SELL_EXPIRED 靠 source_date 实现「同一批次同一天一张」
CREATE UNIQUE INDEX uq_scr_source ON scrap_order(source_type, source_id, source_date) WHERE source_id <> 0 AND status NOT IN ('REJECTED','CANCELLED');
-- ↑ 同一来源（效期扫描任务、待回库记录等）最多一张有效报损单

CREATE TABLE scrap_line (
    id              BIGINT          PRIMARY KEY,
    scrap_id        BIGINT          NOT NULL REFERENCES scrap_order(id),
    line_no         INT             NOT NULL,
    stock_id        BIGINT          NOT NULL,
    sku_id          BIGINT          NOT NULL,
    lot_id          BIGINT          NOT NULL,
    scrap_qty_milli BIGINT          NOT NULL,
    hold_id         BIGINT          NOT NULL DEFAULT 0,   -- SCRAP_PENDING 冻结；0 = 已出库待报损（不冻结）
    ledger_mode     VARCHAR(16)     NOT NULL DEFAULT 'POST_OUT',   -- POST_OUT 出账 / NONE 已扣账只记损耗
    cost_amount     BIGINT          NOT NULL DEFAULT 0,
    CONSTRAINT uq_scr_line   UNIQUE (scrap_id, line_no),
    CONSTRAINT ck_scrl_int   CHECK (scrap_qty_milli = CAST(scrap_qty_milli AS BIGINT)),   -- CAST 只在 SQLite 起作用，PG 恒真
    CONSTRAINT ck_scrl_qty   CHECK (scrap_qty_milli > 0),
    CONSTRAINT ck_scrl_mode  CHECK (ledger_mode IN ('POST_OUT','NONE'))
);
CREATE INDEX ix_scrl_stock ON scrap_line(stock_id);
-- 报损单库层守卫（小赵 I3 / 复评 K1–K4、S1；大肥鱼定案）
-- 状态白名单：DRAFT→PENDING_APPROVAL/CANCELLED，PENDING_APPROVAL→APPROVED/REJECTED/DRAFT，APPROVED→POSTED；POSTED/REJECTED/CANCELLED/VOIDED 是终态。
-- K1：锁定来源 = RETURN_HANDOVER（待回库交接）和 RETURN_QC（质检不合格）：不许撤回 / 取消 / 驳回（scrap_handover_no_revoke → 40930），
--     release_scrap_hold(REVOKED) 也拒绝（02 f802a41）；质检或交接判错只走 SCRAP_MISREPORT 审批 → VOIDED（与 convert_hold SCRAP_PENDING→RETURN_QC 同事务）。
-- K3：code / warehouse_id / source_* / applicant_id 建单后不可改；approver_id / approved_at / posted_at 只能从 NULL 写一次；终态整行只读。
-- S1：INSERT 只能是 DRAFT。K2：不许 DELETE / TRUNCATE（PG 兜超级用户和迁移脚本），SQLite 另拦 REPLACE。
CREATE FUNCTION trg_scr_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF NEW.status <> OLD.status AND OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC')   -- @pg-only
       AND NEW.status IN ('DRAFT','CANCELLED','REJECTED') THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_handover_no_revoke' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.status <> OLD.status AND NOT (   -- @pg-only
          (OLD.status = 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','CANCELLED'))   -- @pg-only
       OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('APPROVED','REJECTED','DRAFT'))   -- @pg-only
       OR (OLD.status = 'APPROVED' AND NEW.status = 'POSTED')   -- @pg-only
       OR (OLD.record_only AND OLD.status = 'DRAFT' AND NEW.status = 'POSTED')   -- 记账型容差内直接过账 -- @pg-only
       OR (OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC') AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED')   -- @pg-only
           AND NEW.status = 'VOIDED')   -- @pg-only
       OR (OLD.source_type = 'PROCESS_LOSS' AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED')   -- 17 损耗改原因/改数量 -- @pg-only
           AND NEW.status = 'VOIDED')) THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_state_forward_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.source_type IS DISTINCT FROM OLD.source_type OR NEW.source_id IS DISTINCT FROM OLD.source_id OR NEW.source_date IS DISTINCT FROM OLD.source_date THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_state_forward_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id   -- @pg-only
       OR NEW.applicant_id IS DISTINCT FROM OLD.applicant_id   -- @pg-only
       OR (OLD.approver_id IS NOT NULL AND NEW.approver_id IS DISTINCT FROM OLD.approver_id)   -- @pg-only
       OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS DISTINCT FROM OLD.approved_at)   -- @pg-only
       OR (OLD.posted_at   IS NOT NULL AND NEW.posted_at   IS DISTINCT FROM OLD.posted_at)   -- @pg-only
       OR (OLD.status IN ('POSTED','REJECTED','CANCELLED','VOIDED')   -- @pg-only
           AND (NEW.reason_code IS DISTINCT FROM OLD.reason_code OR NEW.amount_impact IS DISTINCT FROM OLD.amount_impact   -- @pg-only
                OR NEW.void_approval_no IS DISTINCT FROM OLD.void_approval_no OR NEW.work_date IS DISTINCT FROM OLD.work_date)) THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_immutable' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_scr_forward BEFORE UPDATE ON scrap_order FOR EACH ROW EXECUTE FUNCTION trg_scr_forward();   -- @pg-only
CREATE FUNCTION trg_scr_ins_draft() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF NEW.status <> 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','APPROVED','POSTED','REJECTED','CANCELLED','VOIDED') THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_insert_draft_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_scr_ins_draft BEFORE INSERT ON scrap_order FOR EACH ROW EXECUTE FUNCTION trg_scr_ins_draft();   -- @pg-only
-- 报损行（K3/K4）：只能在 DRAFT 单下新增或修改；单据离开 DRAFT 后整行只读；
-- 带冻结的行（hold_id≠0）数量必须等于冻结余量、库存一致；锁定来源（交接 / 质检）的行冻结写定后数量、库存、hold_id 都不能改
CREATE FUNCTION trg_scrl_draft_only() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        IF NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.status = 'DRAFT') THEN   -- @pg-only
            RAISE EXCEPTION 'scrap_line_locked' USING ERRCODE = '23514';   -- @pg-only
        END IF;   -- @pg-only
    ELSE   -- @pg-only
        IF ROW(NEW.*) IS DISTINCT FROM ROW(OLD.*)   -- @pg-only
           AND NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.status = 'DRAFT') THEN   -- @pg-only
            RAISE EXCEPTION 'scrap_line_locked' USING ERRCODE = '23514';   -- @pg-only
        END IF;   -- @pg-only
        IF OLD.hold_id <> 0   -- @pg-only
           AND (NEW.scrap_qty_milli <> OLD.scrap_qty_milli OR NEW.stock_id <> OLD.stock_id OR NEW.hold_id <> OLD.hold_id)   -- @pg-only
           AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.source_type IN ('RETURN_HANDOVER','RETURN_QC')) THEN   -- @pg-only
            RAISE EXCEPTION 'scrap_line_hold_locked' USING ERRCODE = '23514';   -- @pg-only
        END IF;   -- @pg-only
    END IF;   -- @pg-only
    IF (NEW.hold_id <> 0 OR NEW.ledger_mode <> 'NONE')   -- 记账型单的行：不冻结、不出账 -- @pg-only
       AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.record_only) THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_line_record_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.hold_id <> 0 AND (TG_OP = 'INSERT' OR OLD.hold_id = 0)   -- S1 首次写定 hold_id 时校验；之后由 hold_locked / line_locked 管   -- @pg-only
       AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.hold_id AND h.stock_id = NEW.stock_id AND h.status = 'HELD'   -- @pg-only
                       AND h.hold_qty_milli - h.released_qty_milli = NEW.scrap_qty_milli) THEN   -- @pg-only
        RAISE EXCEPTION 'scrap_line_hold_mismatch' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_scrl_draft_only BEFORE INSERT OR UPDATE ON scrap_line FOR EACH ROW EXECUTE FUNCTION trg_scrl_draft_only();   -- @pg-only
CREATE FUNCTION trg_scr_no_delete() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    RAISE EXCEPTION 'scrap_no_delete' USING ERRCODE = '23514';   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_scr_no_delete  BEFORE DELETE ON scrap_order FOR EACH ROW EXECUTE FUNCTION trg_scr_no_delete();   -- @pg-only
CREATE TRIGGER trg_scrl_no_delete BEFORE DELETE ON scrap_line  FOR EACH ROW EXECUTE FUNCTION trg_scr_no_delete();   -- @pg-only
CREATE TRIGGER trg_scr_no_trunc   BEFORE TRUNCATE ON scrap_order FOR EACH STATEMENT EXECUTE FUNCTION trg_scr_no_delete();   -- @pg-only
CREATE TRIGGER trg_scrl_no_trunc  BEFORE TRUNCATE ON scrap_line  FOR EACH STATEMENT EXECUTE FUNCTION trg_scr_no_delete();   -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_scr_handover BEFORE UPDATE ON scrap_order
-- @sqlite-only WHEN OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC') AND NEW.status <> OLD.status AND NEW.status IN ('DRAFT','CANCELLED','REJECTED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_handover_no_revoke'); END;
-- @sqlite-only CREATE TRIGGER trg_scr_forward BEFORE UPDATE ON scrap_order
-- @sqlite-only WHEN (NEW.status <> OLD.status AND NOT ((OLD.status = 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','CANCELLED'))
-- @sqlite-only        OR (OLD.status = 'PENDING_APPROVAL' AND NEW.status IN ('APPROVED','REJECTED','DRAFT'))
-- @sqlite-only        OR (OLD.status = 'APPROVED' AND NEW.status = 'POSTED')
-- @sqlite-only        OR (OLD.record_only AND OLD.status = 'DRAFT' AND NEW.status = 'POSTED')
-- @sqlite-only        OR (OLD.source_type IN ('RETURN_HANDOVER','RETURN_QC') AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED') AND NEW.status = 'VOIDED')
-- @sqlite-only        OR (OLD.source_type = 'PROCESS_LOSS' AND OLD.status IN ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED') AND NEW.status = 'VOIDED')))
-- @sqlite-only   OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.source_date IS NOT OLD.source_date
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_state_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_scr_immutable BEFORE UPDATE ON scrap_order
-- @sqlite-only WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.applicant_id IS NOT OLD.applicant_id
-- @sqlite-only   OR (OLD.approver_id IS NOT NULL AND NEW.approver_id IS NOT OLD.approver_id)
-- @sqlite-only   OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NOT OLD.approved_at)
-- @sqlite-only   OR (OLD.posted_at IS NOT NULL AND NEW.posted_at IS NOT OLD.posted_at)
-- @sqlite-only   OR (OLD.status IN ('POSTED','REJECTED','CANCELLED','VOIDED') AND (NEW.reason_code IS NOT OLD.reason_code
-- @sqlite-only       OR NEW.amount_impact IS NOT OLD.amount_impact OR NEW.void_approval_no IS NOT OLD.void_approval_no OR NEW.work_date IS NOT OLD.work_date))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_scr_ins_draft BEFORE INSERT ON scrap_order
-- @sqlite-only WHEN NEW.status <> 'DRAFT' AND NEW.status IN ('PENDING_APPROVAL','APPROVED','POSTED','REJECTED','CANCELLED','VOIDED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_insert_draft_only'); END;
-- @sqlite-only CREATE TRIGGER trg_scr_no_replace BEFORE INSERT ON scrap_order
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_scr_no_delete BEFORE DELETE ON scrap_order BEGIN SELECT RAISE(ABORT, 'scrap_no_delete'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_no_replace BEFORE INSERT ON scrap_line
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM scrap_line l WHERE l.id = NEW.id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_no_delete BEFORE DELETE ON scrap_line BEGIN SELECT RAISE(ABORT, 'scrap_no_delete'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_draft_ins BEFORE INSERT ON scrap_line
-- @sqlite-only WHEN NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.status = 'DRAFT')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_locked'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_draft_upd BEFORE UPDATE ON scrap_line
-- @sqlite-only WHEN (NEW.scrap_id IS NOT OLD.scrap_id OR NEW.line_no IS NOT OLD.line_no OR NEW.stock_id IS NOT OLD.stock_id OR NEW.sku_id IS NOT OLD.sku_id
-- @sqlite-only       OR NEW.lot_id IS NOT OLD.lot_id OR NEW.scrap_qty_milli IS NOT OLD.scrap_qty_milli OR NEW.hold_id IS NOT OLD.hold_id
-- @sqlite-only       OR NEW.ledger_mode IS NOT OLD.ledger_mode OR NEW.cost_amount IS NOT OLD.cost_amount)
-- @sqlite-only   AND NOT EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.status = 'DRAFT')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_locked'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_hold_lock BEFORE UPDATE ON scrap_line
-- @sqlite-only WHEN OLD.hold_id <> 0 AND (NEW.scrap_qty_milli <> OLD.scrap_qty_milli OR NEW.stock_id <> OLD.stock_id OR NEW.hold_id <> OLD.hold_id)
-- @sqlite-only   AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = OLD.scrap_id AND o.source_type IN ('RETURN_HANDOVER','RETURN_QC'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_locked'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_record_only BEFORE INSERT ON scrap_line
-- @sqlite-only WHEN (NEW.hold_id <> 0 OR NEW.ledger_mode <> 'NONE') AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.record_only)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_record_only'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_record_only_u BEFORE UPDATE ON scrap_line
-- @sqlite-only WHEN (NEW.hold_id <> 0 OR NEW.ledger_mode <> 'NONE') AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = NEW.scrap_id AND o.record_only)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_record_only'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_hold_ins BEFORE INSERT ON scrap_line
-- @sqlite-only WHEN NEW.hold_id <> 0 AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.hold_id AND h.stock_id = NEW.stock_id
-- @sqlite-only       AND h.status = 'HELD' AND h.hold_qty_milli - h.released_qty_milli = NEW.scrap_qty_milli)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_mismatch'); END;
-- @sqlite-only CREATE TRIGGER trg_scrl_hold_upd BEFORE UPDATE ON scrap_line
-- @sqlite-only WHEN NEW.hold_id <> 0 AND OLD.hold_id = 0
-- @sqlite-only   AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.hold_id AND h.stock_id = NEW.stock_id
-- @sqlite-only       AND h.status = 'HELD' AND h.hold_qty_milli - h.released_qty_milli = NEW.scrap_qty_milli)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'scrap_line_hold_mismatch'); END;
-- 授权（I4）：不给 DELETE/TRUNCATE，作废走状态
GRANT SELECT, INSERT, UPDATE ON scrap_order, scrap_line TO wms_app;                                           -- @pg-only

