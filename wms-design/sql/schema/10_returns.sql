-- 第 10 篇 退货与异常（#5）。本文件只建第 10 篇自己的表；对第 3 篇 inbound_order / inbound_line 的改动一律用 ALTER 写在这里，
-- 并登记在 README「跨篇 ALTER 登记表」（不改 03_inbound.sql 的 CREATE TABLE）。
-- ① inbound_order：退货入库单（RTN）来源白名单。WMS_DELIVERY=第 16 篇拒收回仓；STORE_RETURN=门店退货回仓；STORE_BLIND=盲收；
--    SCRAP_MISREPORT=第 9 篇交接误报回转的质检单（不 post_in）；MALL/ERP=客户退货经第 11 篇
ALTER TABLE inbound_order ADD CONSTRAINT ck_inb_rtn_src CHECK (order_type <> 'RETURN' OR source_system IN ('WMS_DELIVERY','STORE_RETURN','STORE_BLIND','SCRAP_MISREPORT','MALL','ERP'));   -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inb_rtn_src_ins BEFORE INSERT ON inbound_order
-- @sqlite-only WHEN NEW.order_type = 'RETURN' AND NEW.source_system NOT IN ('WMS_DELIVERY','STORE_RETURN','STORE_BLIND','SCRAP_MISREPORT','MALL','ERP')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ck_inb_rtn_src'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_rtn_src_upd BEFORE UPDATE ON inbound_order
-- @sqlite-only WHEN NEW.order_type = 'RETURN' AND NEW.source_system NOT IN ('WMS_DELIVERY','STORE_RETURN','STORE_BLIND','SCRAP_MISREPORT','MALL','ERP')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ck_inb_rtn_src'); END;
-- ② inbound_line：03 里只有 NUMERIC 的 received_qty，没有任何 *_qty_milli 列。这里只补 02 §7.1.3 release_qc_hold 用到的三列
--    received / qc_passed / qc_failed（与 README 跨篇 ALTER 登记表一致）。对方声称数不放在 inbound_line：门店退货在
--    return_reservation_line.qty_milli，拒收差异在 exception_case.claimed_qty_milli。
--    退货入库（docs/10 I3）数量一律 *_qty_milli（00 R2）。第 3 篇的 NUMERIC 列按 00 §9.2「加列 → 双写 → 删旧」迁移；
--    退货（order_type='RETURN'）只读写这三列，入账 post_in 只用 received_qty_milli；质检通过 release_qc_hold 与 qc_passed 累加同事务。
--    SQLite 的 ALTER 不能加表级约束，两条 CHECK 挂在最后一列上（SQLite 允许列级 CHECK 引用同表其他列），约束名两库一致。
ALTER TABLE inbound_line ADD COLUMN received_qty_milli  BIGINT NOT NULL DEFAULT 0;   -- 仓管实点（入账以此为准）
ALTER TABLE inbound_line ADD COLUMN qc_passed_qty_milli BIGINT NOT NULL DEFAULT 0;
ALTER TABLE inbound_line ADD COLUMN qc_failed_qty_milli BIGINT NOT NULL DEFAULT 0;   -- @pg-only
-- @sqlite-only ALTER TABLE inbound_line ADD COLUMN qc_failed_qty_milli BIGINT NOT NULL DEFAULT 0
-- @sqlite-only     CONSTRAINT ck_inbl_int CHECK (received_qty_milli = CAST(received_qty_milli AS BIGINT) AND qc_passed_qty_milli = CAST(qc_passed_qty_milli AS BIGINT) AND qc_failed_qty_milli = CAST(qc_failed_qty_milli AS BIGINT))
-- @sqlite-only     CONSTRAINT ck_inbl_qc CHECK (received_qty_milli >= 0 AND qc_passed_qty_milli >= 0 AND qc_failed_qty_milli >= 0 AND qc_passed_qty_milli + qc_failed_qty_milli <= received_qty_milli);
-- CAST 对 BIGINT 在 PG 上恒为真，只在 SQLite（REAL/TEXT 亲和）起作用，写法与 02 相同
ALTER TABLE inbound_line ADD CONSTRAINT ck_inbl_int CHECK (received_qty_milli = CAST(received_qty_milli AS BIGINT)   -- @pg-only
    AND qc_passed_qty_milli = CAST(qc_passed_qty_milli AS BIGINT) AND qc_failed_qty_milli = CAST(qc_failed_qty_milli AS BIGINT));   -- @pg-only
ALTER TABLE inbound_line ADD CONSTRAINT ck_inbl_qc CHECK (received_qty_milli >= 0 AND qc_passed_qty_milli >= 0 AND qc_failed_qty_milli >= 0   -- @pg-only
    AND qc_passed_qty_milli + qc_failed_qty_milli <= received_qty_milli);   -- @pg-only
-- ③ 质检通过走第 2 篇 release_qc_hold(hold_id, inbound_order_id, inbound_line_id, qty, op_key)：RETURN_QC 冻结 source_type='QC'、
--    source_id = inbound_order.id（RTN 单头 id，不是行 id，也没有 qc_line 表）；op_key = QCR:{inbound_line_id}:{op_seq}。

-- 第 10 篇 退货与异常：异常码字典 + 异常单（EXC）。退货入库单复用 inbound_order(order_type='RETURN')。
CREATE TABLE exception_code (
    code            VARCHAR(32)     PRIMARY KEY,   -- SHORT_STOCK/DAMAGED/EXPIRED/WRONG_LOC/WRONG_SKU/CUSTOMER_REJECT/RETURN_COUNT_DIFF/TEMP_BREACH ...
    name            VARCHAR(64)     NOT NULL,
    action          VARCHAR(32)     NOT NULL,      -- NONE/ADJUST/SCRAP/REPLENISH/NOTIFY_PURCHASE
    liability       VARCHAR(16)     NOT NULL,      -- WAREHOUSE/SUPPLIER/CARRIER/CUSTOMER/UNKNOWN
    escalate_minutes INT            NOT NULL DEFAULT 240,
    is_active       SMALLINT        NOT NULL DEFAULT 1,
    CONSTRAINT ck_exc_liab CHECK (liability IN ('WAREHOUSE','SUPPLIER','CARRIER','CUSTOMER','UNKNOWN'))
);

CREATE TABLE exception_case (
    id              BIGINT          PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL,      -- EXC-{仓}-{节点}-{作业日}-{序号}
    warehouse_id    BIGINT          NOT NULL,
    exception_code  VARCHAR(32)     NOT NULL REFERENCES exception_code(code),   -- I1：外键到字典
    source_type     VARCHAR(24)     NOT NULL,      -- 取值见 ck_exc_src_type
    source_key      VARCHAR(96)     NOT NULL,      -- DELIVERY_RETURN：POD:{pod_id}:{correct_seq}（16，首签 0）；FAILOVER_GAP：FG:{failover_id}:{source_system}:{source_order_no}
    source_hash     VARCHAR(64)     NOT NULL,      -- 规范化内容 SHA-256：同键不同内容 → 40910 SOURCE_ORDER
    sku_id          BIGINT          NOT NULL DEFAULT 0,
    lot_id          BIGINT          NOT NULL DEFAULT 0,
    claimed_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 对方声称（如司机拒收登记数）
    counted_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 仓库实点数（以此为准）
    diff_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- counted − claimed，应用层写入
    liable_party    VARCHAR(16)     NOT NULL DEFAULT 'UNKNOWN',   -- 责任方：WAREHOUSE/CARRIER/STORE/UNKNOWN（字典 exception_code.liability 只是建议值，落单时映射）
    link_deadline_at TIMESTAMP,                    -- UTC；关联单据截止：盲收 = created_at + 48h，超时升级主管（escalated=1）；只能往后改
    status          VARCHAR(16)     NOT NULL DEFAULT 'OPEN',
    escalated       SMALLINT        NOT NULL DEFAULT 0,
    due_at          TIMESTAMP       NOT NULL,
    assignee_id     BIGINT,
    resolution      VARCHAR(32),                   -- ACCEPT_COUNT/ADJUST/SCRAP/CLAIM_CARRIER/CLAIM_CUSTOMER/NO_ACTION
    resolution_doc  VARCHAR(64),                   -- 生成的调整单/报损单号
    reporter_id     BIGINT          NOT NULL,
    closed_by       BIGINT,
    closed_at       TIMESTAMP,
    version         BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_exc_code   UNIQUE (code),
    CONSTRAINT uq_exc_src    UNIQUE (source_type, source_key),
    CONSTRAINT ck_exc_status CHECK (status IN ('OPEN','PROCESSING','RESOLVED','CLOSED','CANCELLED')),
    CONSTRAINT ck_exc_int    CHECK (counted_qty_milli = CAST(counted_qty_milli AS BIGINT) AND diff_qty_milli = CAST(diff_qty_milli AS BIGINT)),
    CONSTRAINT ck_exc_diff   CHECK (diff_qty_milli = counted_qty_milli - claimed_qty_milli),
    CONSTRAINT ck_exc_close  CHECK (status NOT IN ('RESOLVED','CLOSED') OR (resolution IS NOT NULL AND closed_by IS NOT NULL)),
    -- 小赵复评建议 1：处置结论取值；调整 / 报损必须带生成的单号
    CONSTRAINT ck_exc_resol  CHECK (resolution IS NULL OR resolution IN ('ACCEPT_COUNT','ADJUST','SCRAP','CLAIM_CARRIER','CLAIM_CUSTOMER','NO_ACTION')),
    CONSTRAINT ck_exc_resdoc CHECK (resolution IS NULL OR resolution NOT IN ('ADJUST','SCRAP') OR (resolution_doc IS NOT NULL AND length(resolution_doc) > 0)),
    CONSTRAINT ck_exc_liable CHECK (liable_party IN ('WAREHOUSE','CARRIER','STORE','UNKNOWN')),
    CONSTRAINT ck_exc_blind  CHECK (source_type <> 'BLIND_RETURN' OR link_deadline_at IS NOT NULL),
    CONSTRAINT ck_exc_src_type CHECK (source_type IN ('DELIVERY_RETURN','STORE_RETURN','BLIND_RETURN','SCRAP_MISREPORT','RETURN_INBOUND','RR_HOLD_FAILED','FAILOVER_GAP','PICK','COUNT','MANUAL','PROCESS_LOSS','LIVE_DEATH')),
    -- 第 17 篇加工损耗未获批部分（审批 REJECTED / 12h 过期 EXPIRED_TO_EXCEPTION）转本篇异常：source_type 与 00 报损来源同名 PROCESS_LOSS，
    -- source_key = PRCL:{process_output.id}（损耗行 id，一行只转一次，uq_exc_src 去重）；转异常后损耗结论以本篇为准（ERP 等 wms.exception.closed）
    -- 第 18 篇活鲜死亡延迟扣减任务（deduct_status = EXCEPTION）转本篇异常：source_type 与 00 报损来源同名 LIVE_DEATH，
    -- source_key = LDTH:{live_death.id}（死亡登记 id，一条只转一次，uq_exc_ldth_key 去重；幂等返回规则同 PROCESS_LOSS）
    -- 键格式：前缀后必须是不带前导零的正整数 [1-9][0-9]*（PG 正则；SQLite 用 substr + GLOB 等价判断）
    CONSTRAINT ck_exc_ldth_key CHECK (source_type <> 'LIVE_DEATH' OR (source_key ~ '^LDTH:[1-9][0-9]*$' AND sku_id > 0)),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_exc_ldth_key CHECK (source_type <> 'LIVE_DEATH' OR (substr(source_key, 1, 5) = 'LDTH:' AND length(source_key) >= 6 AND substr(source_key, 6, 1) BETWEEN '1' AND '9' AND substr(source_key, 6) NOT GLOB '*[^0-9]*' AND sku_id > 0)),
    CONSTRAINT ck_exc_pl_key CHECK (source_type <> 'PROCESS_LOSS' OR (source_key ~ '^PRCL:[1-9][0-9]*$' AND sku_id > 0)),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_exc_pl_key CHECK (source_type <> 'PROCESS_LOSS' OR (substr(source_key, 1, 5) = 'PRCL:' AND length(source_key) >= 6 AND substr(source_key, 6, 1) BETWEEN '1' AND '9' AND substr(source_key, 6) NOT GLOB '*[^0-9]*' AND sku_id > 0)),
    CONSTRAINT ck_exc_hash   CHECK (length(source_hash) = 64 AND lower(source_hash) = source_hash AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(source_hash,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = '')
);
CREATE INDEX ix_exc_wh_status ON exception_case(warehouse_id, status, due_at);
-- 第 17 篇加工损耗转异常的幂等键（Doro 定）：一条损耗行 PRCL:{process_output.id} 只有一张异常单（两库同一部分唯一索引）。
-- 审批驳回回调（含重放）与 12h 过期任务可能并发处理同一损耗行：后到者不报错，返回已存在的 exception_no，且不再写 outbox。
--   PG：INSERT … ON CONFLICT (source_key) WHERE source_type = 'PROCESS_LOSS' DO NOTHING RETURNING code → 0 行则 SELECT code；
--   SQLite（单写者，BEGIN IMMEDIATE 串行）：INSERT … SELECT … WHERE NOT EXISTS (…) → changes() = 0 则 SELECT code。
--   （SQLite 的 trg_exc_no_replace 会让 INSERT OR IGNORE / ON CONFLICT DO NOTHING 直接 ABORT，所以 SQLite 侧不用 DO NOTHING。）
--   wms.process.loss_settled 只由真正插入异常单的一方在同事务写出 → 每条损耗行只发一次。
CREATE UNIQUE INDEX uq_exc_pl_key ON exception_case(source_key) WHERE source_type = 'PROCESS_LOSS';
-- 第 18 篇活鲜死亡（LDTH:{live_death.id}）同一套：部分唯一索引兜底，后到者返回已有 exception_no、不报错
CREATE UNIQUE INDEX uq_exc_ldth_key ON exception_case(source_key) WHERE source_type = 'LIVE_DEATH';
-- 异常单库层守卫（小赵 I2 / 复评 L1–L3，大肥鱼定案）
-- L1 状态白名单：OPEN→PROCESSING/RESOLVED/CANCELLED，PROCESSING→RESOLVED/CANCELLED，RESOLVED→CLOSED；其余一律拒（含 RESOLVED→PROCESSING、
--    OPEN/PROCESSING→CLOSED）。下游单据被驳回（原 X4）不再退回处理中，而是新开一张异常单（source_type=MANUAL，payload 引用原单号）。
-- L2 建单后 code / warehouse_id / exception_code / source_type / source_key / source_hash / reporter_id 不可改；
--    进入 RESOLVED 后声称、实点、差异、处置结论、处置单号、责任方、关闭人不可改，closed_at 只能从 NULL 写一次；CLOSED / CANCELLED 整行只读（含 version）。
-- L3 不许 DELETE / TRUNCATE；SQLite 另拦 REPLACE（id 或 (source_type, source_key) 已存在即拒），去重键永不释放。
-- 建议 2：SQLite 外键依赖 PRAGMA foreign_keys=ON，边缘连接漏开也要拦：exception_code 存在性用触发器再校验一次。
CREATE FUNCTION trg_exc_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF NEW.status <> OLD.status AND NEW.status IN ('OPEN','PROCESSING','RESOLVED','CLOSED','CANCELLED') AND NOT (   -- @pg-only
          (OLD.status = 'OPEN' AND NEW.status IN ('PROCESSING','RESOLVED','CANCELLED'))   -- @pg-only
       OR (OLD.status = 'PROCESSING' AND NEW.status IN ('RESOLVED','CANCELLED'))   -- @pg-only
       OR (OLD.status = 'RESOLVED' AND NEW.status = 'CLOSED')) THEN   -- @pg-only
        RAISE EXCEPTION 'exc_state_forward_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id   -- @pg-only
       OR NEW.exception_code IS DISTINCT FROM OLD.exception_code OR NEW.source_type IS DISTINCT FROM OLD.source_type   -- @pg-only
       OR NEW.source_key IS DISTINCT FROM OLD.source_key OR NEW.source_hash IS DISTINCT FROM OLD.source_hash   -- @pg-only
       OR NEW.reporter_id IS DISTINCT FROM OLD.reporter_id   -- @pg-only
       OR (OLD.status IN ('CLOSED','CANCELLED') AND NEW.status = OLD.status AND ROW(NEW.*) IS DISTINCT FROM ROW(OLD.*))   -- @pg-only
       OR (OLD.status = 'RESOLVED' AND (NEW.claimed_qty_milli IS DISTINCT FROM OLD.claimed_qty_milli   -- @pg-only
           OR NEW.counted_qty_milli IS DISTINCT FROM OLD.counted_qty_milli OR NEW.diff_qty_milli IS DISTINCT FROM OLD.diff_qty_milli   -- @pg-only
           OR NEW.resolution IS DISTINCT FROM OLD.resolution OR NEW.resolution_doc IS DISTINCT FROM OLD.resolution_doc   -- @pg-only
           OR NEW.liable_party IS DISTINCT FROM OLD.liable_party OR NEW.closed_by IS DISTINCT FROM OLD.closed_by   -- @pg-only
           OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS DISTINCT FROM OLD.closed_at))) THEN   -- @pg-only
        RAISE EXCEPTION 'exc_immutable' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF OLD.link_deadline_at IS NOT NULL AND (NEW.link_deadline_at IS NULL OR NEW.link_deadline_at < OLD.link_deadline_at) THEN   -- @pg-only
        RAISE EXCEPTION 'exc_deadline_backward' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_exc_forward BEFORE UPDATE ON exception_case FOR EACH ROW EXECUTE FUNCTION trg_exc_forward();   -- @pg-only
CREATE FUNCTION trg_exc_no_delete() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    RAISE EXCEPTION 'exc_no_delete' USING ERRCODE = '23514';   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_exc_no_delete BEFORE DELETE ON exception_case FOR EACH ROW EXECUTE FUNCTION trg_exc_no_delete();   -- @pg-only
CREATE TRIGGER trg_exc_no_trunc  BEFORE TRUNCATE ON exception_case FOR EACH STATEMENT EXECUTE FUNCTION trg_exc_no_delete();   -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_exc_forward BEFORE UPDATE ON exception_case
-- @sqlite-only WHEN NEW.status <> OLD.status AND NEW.status IN ('OPEN','PROCESSING','RESOLVED','CLOSED','CANCELLED') AND NOT ((OLD.status = 'OPEN' AND NEW.status IN ('PROCESSING','RESOLVED','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'PROCESSING' AND NEW.status IN ('RESOLVED','CANCELLED'))
-- @sqlite-only   OR (OLD.status = 'RESOLVED' AND NEW.status = 'CLOSED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_state_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_exc_immutable BEFORE UPDATE ON exception_case
-- @sqlite-only WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.exception_code IS NOT OLD.exception_code
-- @sqlite-only   OR NEW.source_type IS NOT OLD.source_type OR NEW.source_key IS NOT OLD.source_key OR NEW.source_hash IS NOT OLD.source_hash
-- @sqlite-only   OR NEW.reporter_id IS NOT OLD.reporter_id
-- @sqlite-only   OR (OLD.status IN ('CLOSED','CANCELLED') AND (NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
-- @sqlite-only   OR NEW.exception_code IS NOT OLD.exception_code OR NEW.source_type IS NOT OLD.source_type
-- @sqlite-only   OR NEW.source_key IS NOT OLD.source_key OR NEW.source_hash IS NOT OLD.source_hash OR NEW.sku_id IS NOT OLD.sku_id
-- @sqlite-only   OR NEW.lot_id IS NOT OLD.lot_id OR NEW.claimed_qty_milli IS NOT OLD.claimed_qty_milli
-- @sqlite-only   OR NEW.counted_qty_milli IS NOT OLD.counted_qty_milli OR NEW.diff_qty_milli IS NOT OLD.diff_qty_milli
-- @sqlite-only   OR NEW.liable_party IS NOT OLD.liable_party OR NEW.escalated IS NOT OLD.escalated
-- @sqlite-only   OR NEW.due_at IS NOT OLD.due_at OR NEW.assignee_id IS NOT OLD.assignee_id OR NEW.resolution IS NOT OLD.resolution
-- @sqlite-only   OR NEW.resolution_doc IS NOT OLD.resolution_doc OR NEW.reporter_id IS NOT OLD.reporter_id
-- @sqlite-only   OR NEW.closed_by IS NOT OLD.closed_by OR NEW.closed_at IS NOT OLD.closed_at OR NEW.version IS NOT OLD.version
-- @sqlite-only   OR NEW.link_deadline_at IS NOT OLD.link_deadline_at OR NEW.created_at IS NOT OLD.created_at))
-- @sqlite-only   OR (OLD.status = 'RESOLVED' AND (NEW.claimed_qty_milli IS NOT OLD.claimed_qty_milli OR NEW.counted_qty_milli IS NOT OLD.counted_qty_milli
-- @sqlite-only       OR NEW.diff_qty_milli IS NOT OLD.diff_qty_milli OR NEW.resolution IS NOT OLD.resolution OR NEW.resolution_doc IS NOT OLD.resolution_doc
-- @sqlite-only       OR NEW.liable_party IS NOT OLD.liable_party OR NEW.closed_by IS NOT OLD.closed_by
-- @sqlite-only       OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at)))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_exc_no_delete BEFORE DELETE ON exception_case BEGIN SELECT RAISE(ABORT, 'exc_no_delete'); END;
-- @sqlite-only CREATE TRIGGER trg_exc_no_replace BEFORE INSERT ON exception_case
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM exception_case e WHERE e.id = NEW.id OR (e.source_type = NEW.source_type AND e.source_key = NEW.source_key))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_exc_code_ins BEFORE INSERT ON exception_case
-- @sqlite-only WHEN NOT EXISTS (SELECT 1 FROM exception_code c WHERE c.code = NEW.exception_code)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_code_unknown'); END;
-- 盲收异常单：link_deadline_at 建单时必须 = created_at + 48h（截止只能往后改，见 trg_exc_forward / trg_exc_deadline）
CREATE FUNCTION trg_exc_blind_ins() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF NEW.source_type = 'BLIND_RETURN' AND NEW.link_deadline_at IS NOT NULL AND NEW.link_deadline_at IS DISTINCT FROM NEW.created_at + INTERVAL '48 hours' THEN   -- @pg-only
        RAISE EXCEPTION 'exc_blind_deadline' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_exc_blind_ins BEFORE INSERT ON exception_case FOR EACH ROW EXECUTE FUNCTION trg_exc_blind_ins();   -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_exc_blind_ins BEFORE INSERT ON exception_case
-- @sqlite-only WHEN NEW.source_type = 'BLIND_RETURN' AND NEW.link_deadline_at IS NOT NULL AND NEW.link_deadline_at IS NOT datetime(NEW.created_at, '+48 hours')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_blind_deadline'); END;
-- @sqlite-only CREATE TRIGGER trg_exc_deadline BEFORE UPDATE ON exception_case
-- @sqlite-only WHEN OLD.link_deadline_at IS NOT NULL AND (NEW.link_deadline_at IS NULL OR NEW.link_deadline_at < OLD.link_deadline_at)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'exc_deadline_backward'); END;
-- I4：授权。字典只读写不删；异常单不删（取消走状态）
GRANT SELECT, INSERT, UPDATE ON exception_code, exception_case TO wms_app;                                   -- @pg-only

-- -----------------------------------------------------------------------------
-- 第 10 篇：门店退货「退货预约 + 盲收」（大肥鱼定案，对标盒马）
--   原因码与容器码必填；没有容器码的货现场补贴新标签再收。
-- -----------------------------------------------------------------------------
-- 退货预约：门店建（returns.reservation.create），仓库收货员收（returns.reservation.receive），收货后库存挂 RETURN_QC。
-- 状态：CREATED → RECEIVED / CANCELLED，只进不退；建单键不可改；终态整行只读；不许 DELETE / TRUNCATE；SQLite 另拦 REPLACE。
CREATE TABLE return_reservation (
    id                  BIGINT          PRIMARY KEY,
    code                VARCHAR(32)     NOT NULL,      -- RSV-{yyyyMMdd}-{seq}
    warehouse_id        BIGINT          NOT NULL,
    store_code          VARCHAR(32)     NOT NULL,
    outbound_order_id   BIGINT          NOT NULL,      -- 原出库单（门店只能退本店收过的单，服务端校验）
    status              VARCHAR(16)     NOT NULL DEFAULT 'CREATED',
    rtn_inbound_id      BIGINT,                        -- 收货生成的 RTN（inbound_order，source_system=STORE_RETURN）
    created_by          BIGINT          NOT NULL,
    received_by         BIGINT,
    received_at         TIMESTAMP,
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_rrsv_code   UNIQUE (code),
    CONSTRAINT ck_rrsv_status CHECK (status IN ('CREATED','RECEIVED','CANCELLED')),
    CONSTRAINT ck_rrsv_store  CHECK (length(store_code) > 0),
    CONSTRAINT ck_rrsv_recv   CHECK ((status = 'RECEIVED') = (rtn_inbound_id IS NOT NULL AND received_by IS NOT NULL AND received_at IS NOT NULL))
);
CREATE INDEX ix_rrsv_store ON return_reservation(warehouse_id, store_code, status);
CREATE TABLE return_reservation_line (
    id                  BIGINT          PRIMARY KEY,
    reservation_id      BIGINT          NOT NULL REFERENCES return_reservation(id),
    line_no             INTEGER         NOT NULL,
    sku_id              BIGINT          NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    reason_code         VARCHAR(24)     NOT NULL,
    container_code      VARCHAR(64)     NOT NULL,
    received_qty_milli  BIGINT,                        -- 收货时写一次（实点）
    CONSTRAINT uq_rrsl_line   UNIQUE (reservation_id, line_no),
    CONSTRAINT ck_rrsl_qty    CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)
                                     AND (received_qty_milli IS NULL OR (received_qty_milli >= 0 AND received_qty_milli = CAST(received_qty_milli AS BIGINT)))),
    CONSTRAINT ck_rrsl_ctn    CHECK (length(container_code) > 0),
    CONSTRAINT ck_rrsl_reason CHECK (reason_code IN ('QUALITY','DAMAGED','EXPIRED','NEAR_EXPIRY','WRONG_ITEM','OVERSTOCK','TEMP_ABNORMAL','PACKAGING','OTHER'))
);
-- 盲收记录：不预约直接收（inbound.return.blind），只追加：整行不可改、不可删；同事务生成 RTN（source_system=STORE_BLIND）与异常单（source_type=BLIND_RETURN）。
CREATE TABLE return_blind_receipt (
    id                  BIGINT          PRIMARY KEY,
    code                VARCHAR(32)     NOT NULL,      -- BRC-{yyyyMMdd}-{seq}，接口返回的收货记录号
    warehouse_id        BIGINT          NOT NULL,
    sku_id              BIGINT          NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    store_code          VARCHAR(32),                   -- 可空：不知道哪家门店
    container_code      VARCHAR(64)     NOT NULL,
    reason_code         VARCHAR(24)     NOT NULL,
    photo_ids           TEXT            NOT NULL DEFAULT '[]',   -- JSON 数组，第 12 篇文件服务 id
    rtn_inbound_id      BIGINT          NOT NULL,
    exception_case_id   BIGINT          NOT NULL,
    op_key              VARCHAR(80)     NOT NULL,      -- Idempotency-Key
    received_by         BIGINT          NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_rbr_code    UNIQUE (code),
    CONSTRAINT uq_rbr_op      UNIQUE (op_key),
    CONSTRAINT ck_rbr_qty     CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_rbr_ctn     CHECK (length(container_code) > 0 AND (store_code IS NULL OR length(store_code) > 0)),
    CONSTRAINT ck_rbr_reason  CHECK (reason_code IN ('QUALITY','DAMAGED','EXPIRED','NEAR_EXPIRY','WRONG_ITEM','OVERSTOCK','TEMP_ABNORMAL','PACKAGING','OTHER'))
);
CREATE FUNCTION trg_rrsv_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF NEW.status <> OLD.status AND NOT (OLD.status = 'CREATED' AND NEW.status IN ('RECEIVED','CANCELLED')) THEN   -- @pg-only
        RAISE EXCEPTION 'rrsv_state_forward_only' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id   -- @pg-only
       OR NEW.store_code IS DISTINCT FROM OLD.store_code OR NEW.outbound_order_id IS DISTINCT FROM OLD.outbound_order_id   -- @pg-only
       OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at   -- @pg-only
       OR (OLD.status <> 'CREATED' AND NEW.status = OLD.status AND ROW(NEW.*) IS DISTINCT FROM ROW(OLD.*)) THEN   -- @pg-only
        RAISE EXCEPTION 'rrsv_immutable' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_rrsv_guard BEFORE UPDATE ON return_reservation FOR EACH ROW EXECUTE FUNCTION trg_rrsv_guard();   -- @pg-only
CREATE FUNCTION trg_rrsl_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        IF NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = NEW.reservation_id AND r.status = 'CREATED') THEN   -- @pg-only
            RAISE EXCEPTION 'rrsl_locked' USING ERRCODE = '23514';   -- @pg-only
        END IF;   -- @pg-only
        RETURN NEW;   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id OR NEW.line_no IS DISTINCT FROM OLD.line_no   -- @pg-only
       OR NEW.sku_id IS DISTINCT FROM OLD.sku_id OR NEW.qty_milli IS DISTINCT FROM OLD.qty_milli   -- @pg-only
       OR NEW.reason_code IS DISTINCT FROM OLD.reason_code OR NEW.container_code IS DISTINCT FROM OLD.container_code   -- @pg-only
       OR OLD.received_qty_milli IS NOT NULL   -- @pg-only
       OR NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = OLD.reservation_id AND r.status = 'CREATED') THEN   -- @pg-only
        RAISE EXCEPTION 'rrsl_locked' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_rrsl_guard BEFORE INSERT OR UPDATE ON return_reservation_line FOR EACH ROW EXECUTE FUNCTION trg_rrsl_guard();   -- @pg-only
CREATE FUNCTION trg_rtn10_no_delete() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    RAISE EXCEPTION 'return_no_delete' USING ERRCODE = '23514';   -- @pg-only
END $$;   -- @pg-only
CREATE FUNCTION trg_rbr_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN   -- @pg-only
    RAISE EXCEPTION 'rbr_immutable' USING ERRCODE = '23514';   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_rrsv_no_delete BEFORE DELETE ON return_reservation FOR EACH ROW EXECUTE FUNCTION trg_rtn10_no_delete();   -- @pg-only
CREATE TRIGGER trg_rrsv_no_trunc  BEFORE TRUNCATE ON return_reservation FOR EACH STATEMENT EXECUTE FUNCTION trg_rtn10_no_delete();   -- @pg-only
CREATE TRIGGER trg_rrsl_no_delete BEFORE DELETE ON return_reservation_line FOR EACH ROW EXECUTE FUNCTION trg_rtn10_no_delete();   -- @pg-only
CREATE TRIGGER trg_rrsl_no_trunc  BEFORE TRUNCATE ON return_reservation_line FOR EACH STATEMENT EXECUTE FUNCTION trg_rtn10_no_delete();   -- @pg-only
CREATE TRIGGER trg_rbr_immutable  BEFORE UPDATE OR DELETE ON return_blind_receipt FOR EACH ROW EXECUTE FUNCTION trg_rbr_immutable();   -- @pg-only
CREATE TRIGGER trg_rbr_no_trunc   BEFORE TRUNCATE ON return_blind_receipt FOR EACH STATEMENT EXECUTE FUNCTION trg_rbr_immutable();   -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_rrsv_forward BEFORE UPDATE ON return_reservation
-- @sqlite-only WHEN NEW.status <> OLD.status AND NOT (OLD.status = 'CREATED' AND NEW.status IN ('RECEIVED','CANCELLED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rrsv_state_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsv_immutable BEFORE UPDATE ON return_reservation
-- @sqlite-only WHEN NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.store_code IS NOT OLD.store_code
-- @sqlite-only   OR NEW.outbound_order_id IS NOT OLD.outbound_order_id OR NEW.created_by IS NOT OLD.created_by OR NEW.created_at IS NOT OLD.created_at
-- @sqlite-only   OR (OLD.status <> 'CREATED' AND NEW.status = OLD.status AND (NEW.rtn_inbound_id IS NOT OLD.rtn_inbound_id
-- @sqlite-only       OR NEW.received_by IS NOT OLD.received_by OR NEW.received_at IS NOT OLD.received_at OR NEW.version IS NOT OLD.version))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rrsv_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsv_no_delete BEFORE DELETE ON return_reservation BEGIN SELECT RAISE(ABORT, 'return_no_delete'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsv_no_replace BEFORE INSERT ON return_reservation
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = NEW.id OR r.code = NEW.code)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rrsv_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsl_ins BEFORE INSERT ON return_reservation_line
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM return_reservation_line l WHERE l.id = NEW.id OR (l.reservation_id = NEW.reservation_id AND l.line_no = NEW.line_no))
-- @sqlite-only   OR NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = NEW.reservation_id AND r.status = 'CREATED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rrsl_locked'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsl_upd BEFORE UPDATE ON return_reservation_line
-- @sqlite-only WHEN NEW.id IS NOT OLD.id OR NEW.reservation_id IS NOT OLD.reservation_id OR NEW.line_no IS NOT OLD.line_no
-- @sqlite-only   OR NEW.sku_id IS NOT OLD.sku_id OR NEW.qty_milli IS NOT OLD.qty_milli OR NEW.reason_code IS NOT OLD.reason_code
-- @sqlite-only   OR NEW.container_code IS NOT OLD.container_code OR OLD.received_qty_milli IS NOT NULL
-- @sqlite-only   OR NOT EXISTS (SELECT 1 FROM return_reservation r WHERE r.id = OLD.reservation_id AND r.status = 'CREATED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rrsl_locked'); END;
-- @sqlite-only CREATE TRIGGER trg_rrsl_no_delete BEFORE DELETE ON return_reservation_line BEGIN SELECT RAISE(ABORT, 'return_no_delete'); END;
-- @sqlite-only CREATE TRIGGER trg_rbr_no_upd BEFORE UPDATE ON return_blind_receipt BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_rbr_no_del BEFORE DELETE ON return_blind_receipt BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_rbr_no_replace BEFORE INSERT ON return_blind_receipt
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM return_blind_receipt b WHERE b.id = NEW.id OR b.code = NEW.code OR b.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'rbr_immutable'); END;
GRANT SELECT, INSERT, UPDATE ON return_reservation, return_reservation_line TO wms_app;   -- @pg-only
GRANT SELECT, INSERT ON return_blind_receipt TO wms_app;   -- @pg-only
