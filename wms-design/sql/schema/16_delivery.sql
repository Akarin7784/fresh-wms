-- -----------------------------------------------------------------------------
-- 16 配送与签收（运单 / 配送站点 / 签收聚合 / POD 现场操作 / 更正 / 容差 / 回仓交接）
--   文档：docs/16-配送与签收.md。表与约束以本文件为准。
--   本轮（第一刀）：9 张表 + PK/UK/FK/CHECK + 索引 + 授权 + 只追加与重放只读触发器。
--   下一刀（已登记 docs/16 §12）：9 张表的 SQLite no-REPLACE 守卫（00 §6.10 新表要求）、
--     两库「正向 / 按名拒绝 / 变异」断言、verify.sh 的 EXPECT_TABLES/INDEXES/PRIVS 与
--     触发器冻结基线（归磐石，随 SCHEMA_PARTS 一并改）。
--   边界（Chief 已拍）：司机 / 车辆 / 发车 / 签收的权威与快照都在本文件；06 `shipment`
--     只留 `carrier_code` + 交接字段，`vehicle_no` / `driver_*` / `planned_depart_at` /
--     `departed_at` / `signed_at` / `temp_log_ref` 随 16 落库那一笔从 06 删掉；
--     关联方向是 `waybill.shipment_id`（一张运单带多张集货/发货单），不反向。
-- -----------------------------------------------------------------------------

CREATE TABLE waybill (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,                       -- = waybill_no，WB-{仓}-{节点}-{作业日}-{序号}（00 §6.2）
    shipment_id         BIGINT       NOT NULL,                       -- 06 集货/发货单；1 运单 : 1 发货单（首版）
    warehouse_id        BIGINT       NOT NULL,
    driver_id           BIGINT,                                      -- 01 司机台账落地前先存 sys_user.id（§12 Q）
    driver_name         VARCHAR(64),                                 -- 发车时点快照，不随主数据回溯
    driver_phone        VARCHAR(32),
    vehicle_no          VARCHAR(24),                                 -- 发车时点快照
    work_date           DATE         NOT NULL,                       -- 仓时区业务日
    status              VARCHAR(16)  NOT NULL DEFAULT 'CREATED',     -- CREATED/LOADING/IN_TRANSIT/RETURNED/CLOSED/CANCELLED
    waybill_version     INT          NOT NULL DEFAULT 0,             -- 改派 / 改站点 +1（司机端版本栅栏）
    planned_depart_at   TIMESTAMP,
    departed_at         TIMESTAMP,
    signed_at           TIMESTAMP,
    temp_log_ref        VARCHAR(128),                                -- 温控记录对象存储 key
    created_by          BIGINT,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_wb_code      UNIQUE (code),
    CONSTRAINT uq_wb_shipment  UNIQUE (shipment_id),
    CONSTRAINT fk_wb_shipment  FOREIGN KEY (shipment_id)  REFERENCES shipment(id),
    CONSTRAINT fk_wb_wh        FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT ck_wb_status    CHECK (status IN ('CREATED','LOADING','IN_TRANSIT','RETURNED','CLOSED','CANCELLED')),
    CONSTRAINT ck_wb_version   CHECK (waybill_version >= 0),
    CONSTRAINT ck_wb_signed    CHECK (status <> 'CLOSED' OR signed_at IS NOT NULL)
);
CREATE INDEX ix_wb_driver ON waybill(driver_id, work_date, status);

CREATE TABLE delivery_stop (
    id                  BIGINT       PRIMARY KEY,
    waybill_id          BIGINT       NOT NULL,
    stop_no             SMALLINT     NOT NULL,                       -- 站点顺序，从 1 开始
    customer_id         BIGINT,
    address             VARCHAR(255),
    display_status      VARCHAR(24)  NOT NULL DEFAULT 'PENDING',     -- 仅展示；业务判断一律读出库单 delivery_result
    arrived_at          TIMESTAMP,
    departed_at         TIMESTAMP,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_dstop        UNIQUE (waybill_id, stop_no),
    CONSTRAINT fk_dstop_wb     FOREIGN KEY (waybill_id) REFERENCES waybill(id),
    CONSTRAINT ck_dstop_no     CHECK (stop_no >= 1),
    CONSTRAINT ck_dstop_st     CHECK (display_status IN ('PENDING','ARRIVED','DEPARTED_UNSIGNED','FULL','PARTIAL_REJECT','FULL_REJECT','MIXED'))
);
CREATE INDEX ix_dstop_wb ON delivery_stop(waybill_id, stop_no);

CREATE TABLE delivery_order (
    id                  BIGINT       PRIMARY KEY,
    outbound_id         BIGINT       NOT NULL,                       -- 一张出库单只挂一张有效运单（改派 = 改 waybill_id/stop_no）
    waybill_id          BIGINT       NOT NULL,
    stop_no             SMALLINT     NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'SHIPPED',     -- 与 outbound_order.status 同事务同步
    valid_pod_id        BIGINT,                                      -- 当前生效签收（首签 = pod_op.id，更正后 = pod_correction.id）
    root_pod_id         BIGINT,                                      -- 首次签收 id，更正后不变
    correct_seq         INT          NOT NULL DEFAULT 0,             -- 首签 0，每次 APPLIED 更正 +1
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_dord_out     UNIQUE (outbound_id),
    CONSTRAINT fk_dord_out     FOREIGN KEY (outbound_id) REFERENCES outbound_order(id),
    CONSTRAINT fk_dord_wb      FOREIGN KEY (waybill_id)  REFERENCES waybill(id),
    CONSTRAINT ck_dord_status  CHECK (status IN ('SHIPPED','DELIVERED')),
    CONSTRAINT ck_dord_cseq    CHECK (correct_seq >= 0),
    -- D2：未签收 ⇔ 无生效签收 ⇔ 无首签
    CONSTRAINT ck_dord_pod     CHECK (
        (status = 'SHIPPED'   AND valid_pod_id IS NULL AND root_pod_id IS NULL)
     OR (status = 'DELIVERED' AND valid_pod_id IS NOT NULL AND root_pod_id IS NOT NULL)
    )
);
CREATE INDEX ix_dord_wb ON delivery_order(waybill_id, stop_no);

CREATE TABLE pod_op (
    id                  BIGINT       PRIMARY KEY,                    -- 签收类操作的 id 即 pod_id
    waybill_no          VARCHAR(64)  NOT NULL,
    stop_no             SMALLINT     NOT NULL DEFAULT 0,             -- 运单级操作（LOAD/CONTAINER/RETURN_COUNT）为 0
    device_instance_id  VARCHAR(64)  NOT NULL,
    op_seq              BIGINT       NOT NULL,                       -- 设备内按 (waybill_no, stop_no) 单调递增
    op_type             VARCHAR(16)  NOT NULL,                       -- 现场操作；不含 POD_CORRECT
    req_hash            VARCHAR(64)  NOT NULL,                       -- 规范化请求体 SHA-256（hex 小写）
    http_status         INT          NOT NULL,                       -- 首次结果缓存
    biz_code            VARCHAR(16)  NOT NULL,
    response            TEXT,
    client_created_at   TIMESTAMP,                                   -- 仅展示
    temperature_x10     INT,                                         -- 签收温度 0.1 ℃（POD_SIGN / POD_REJECT 必填）
    delivered_at        TIMESTAMP,                                   -- 服务端受理签收时间；失败签收为空
    correct_deadline_at TIMESTAMP,                                   -- = delivered_at + 24h（服务端写）
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_pod_op_key   UNIQUE (waybill_no, stop_no, device_instance_id, op_seq),
    CONSTRAINT ck_pod_op_type  CHECK (op_type IN ('LOAD','ARRIVE','POD_SIGN','POD_REJECT','DEPART','CONTAINER','RETURN_COUNT')),
    CONSTRAINT ck_pod_op_hash  CHECK (length(req_hash) = 64),
    CONSTRAINT ck_pod_op_seq   CHECK (op_seq >= 0),
    -- D4：缓存只存确定性结果（2xx+0 / 400+400xx / 409+409xx）
    CONSTRAINT ck_pod_op_cache CHECK (
        (http_status BETWEEN 200 AND 299 AND biz_code = '0')
     OR (http_status = 400 AND biz_code LIKE '400%')
     OR (http_status = 409 AND biz_code LIKE '409%')
    ),
    CONSTRAINT ck_pod_op_temp  CHECK (
        (op_type IN ('POD_SIGN','POD_REJECT') AND temperature_x10 IS NOT NULL AND temperature_x10 BETWEEN -400 AND 600)
     OR (op_type NOT IN ('POD_SIGN','POD_REJECT') AND temperature_x10 IS NULL)
    ),
    CONSTRAINT ck_pod_op_cdl   CHECK (
        (op_type IN ('POD_SIGN','POD_REJECT') AND http_status BETWEEN 200 AND 299 AND delivered_at IS NOT NULL)
     OR (NOT (op_type IN ('POD_SIGN','POD_REJECT') AND http_status BETWEEN 200 AND 299) AND delivered_at IS NULL)
    ),
    CONSTRAINT ck_pod_op_cdl24 CHECK (                                                          -- @pg-only
        (delivered_at IS NULL AND correct_deadline_at IS NULL)                                  -- @pg-only
     OR correct_deadline_at = delivered_at + INTERVAL '24 hours'                                -- @pg-only
    )                                                                                           -- @pg-only
-- @sqlite-only     CONSTRAINT ck_pod_op_cdl24 CHECK (
-- @sqlite-only         (delivered_at IS NULL AND correct_deadline_at IS NULL)
-- @sqlite-only      OR correct_deadline_at = datetime(delivered_at, '+24 hours')
-- @sqlite-only     )
);
CREATE INDEX ix_pod_op_dev  ON pod_op(device_instance_id, waybill_no, stop_no, op_seq);
CREATE INDEX ix_pod_op_stop ON pod_op(waybill_no, stop_no, created_at);

CREATE TABLE pod_line (
    id                  BIGINT       PRIMARY KEY,
    pod_id              BIGINT       NOT NULL,
    outbound_line_id    BIGINT       NOT NULL,
    lot_id              BIGINT       NOT NULL,                       -- 装车明细批次（拒收 RTN 必带批次，第 10 篇）
    shipped_qty_milli   BIGINT       NOT NULL,
    rejected_qty_milli  BIGINT       NOT NULL DEFAULT 0,
    reason_code         VARCHAR(24),                                 -- 拒收必填
    receive_temp_c10    INT          NOT NULL,                       -- 逐行到货温度 0.1 ℃（温区业务校验在 §6.2 / 42216）
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_podl        UNIQUE (pod_id, outbound_line_id, lot_id),
    CONSTRAINT fk_podl_pod    FOREIGN KEY (pod_id)           REFERENCES pod_op(id),
    CONSTRAINT fk_podl_obl    FOREIGN KEY (outbound_line_id) REFERENCES outbound_line(id),
    CONSTRAINT fk_podl_lot    FOREIGN KEY (lot_id)           REFERENCES lot(id),
    CONSTRAINT ck_podl_qty    CHECK (shipped_qty_milli > 0 AND rejected_qty_milli >= 0 AND rejected_qty_milli <= shipped_qty_milli),
    -- D3：拒收必须有原因
    CONSTRAINT ck_podl_rsn    CHECK (rejected_qty_milli = 0 OR reason_code IS NOT NULL),
    CONSTRAINT ck_podl_rsn_v  CHECK (reason_code IS NULL OR reason_code IN ('DAMAGED','QUALITY','EXPIRED','SHORT','WRONG_ITEM','TEMP_ABNORMAL','CUSTOMER_REFUSED','OTHER')),
    CONSTRAINT ck_podl_temp   CHECK (receive_temp_c10 BETWEEN -400 AND 600)
);
CREATE INDEX ix_podl_pod ON pod_line(pod_id, outbound_line_id);

CREATE TABLE pod_correction (
    id                  BIGINT       PRIMARY KEY,                    -- 同时是更正后的签收 id
    correct_op_id       BIGINT       NOT NULL,
    corrected_pod_id    BIGINT       NOT NULL,                       -- 被更正的生效签收
    outbound_id         BIGINT       NOT NULL,
    driver_id           BIGINT       NOT NULL,
    correction_client_id VARCHAR(36) NOT NULL,
    request_hash        VARCHAR(64)  NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',     -- PENDING/APPLIED/REJECTED/WITHDRAWN/EXPIRED/VOID
    approval_id         BIGINT,                                      -- 第 12 篇审批单；容差内自动更正为空
    auto_tolerance      SMALLINT     NOT NULL DEFAULT 0,             -- 1 = 容差内自动 APPLIED
    tolerance_version   BIGINT,                                      -- 命中的 pod_tolerance_config.version
    correct_seq         INT          NOT NULL DEFAULT 0,             -- APPLIED ⇔ >= 1
    response_http       INT          NOT NULL,                       -- 首次返回 200（容差内）/ 202（待审批）
    decided_by          BIGINT,
    decided_at          TIMESTAMP,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_podc_client   UNIQUE (driver_id, correction_client_id),
    CONSTRAINT fk_podc_op       FOREIGN KEY (correct_op_id)    REFERENCES pod_op(id),
    CONSTRAINT fk_podc_out      FOREIGN KEY (outbound_id)      REFERENCES outbound_order(id),
    CONSTRAINT fk_podc_apr      FOREIGN KEY (approval_id)      REFERENCES approval_request(id),
    CONSTRAINT ck_podc_client   CHECK (length(correction_client_id) = 36),
    CONSTRAINT ck_podc_hash     CHECK (length(request_hash) = 64),
    CONSTRAINT ck_podc_status   CHECK (status IN ('PENDING','APPLIED','REJECTED','WITHDRAWN','EXPIRED','VOID')),
    CONSTRAINT ck_podc_http     CHECK ((response_http = 200 AND auto_tolerance = 1) OR (response_http = 202 AND auto_tolerance = 0)),
    CONSTRAINT ck_podc_auto     CHECK (auto_tolerance IN (0,1)
        AND (auto_tolerance = 0 OR (approval_id IS NULL AND tolerance_version IS NOT NULL))),
    CONSTRAINT ck_podc_seq      CHECK ((status = 'APPLIED') = (correct_seq >= 1)),
    -- D6：更正审批人 ≠ 申请人
    CONSTRAINT ck_podc_sod      CHECK (decided_by IS NULL OR decided_by <> driver_id),
    CONSTRAINT ck_podc_decide   CHECK ((status IN ('APPLIED','REJECTED') AND decided_at IS NOT NULL) OR status NOT IN ('APPLIED','REJECTED'))
);
CREATE UNIQUE INDEX uq_podc_approval ON pod_correction(approval_id) WHERE approval_id IS NOT NULL;
CREATE UNIQUE INDEX uq_podc_pending  ON pod_correction(corrected_pod_id, outbound_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX uq_podc_seq      ON pod_correction(outbound_id, correct_seq) WHERE status = 'APPLIED';
CREATE INDEX ix_podc_out ON pod_correction(outbound_id, status);

CREATE TABLE pod_tolerance_config (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    sku_category        VARCHAR(32)  NOT NULL DEFAULT '',            -- '' = 全品类兜底（不用 NULL，好让 no-REPLACE 扫描逐列判定）
    max_abs_qty_milli   BIGINT       NOT NULL DEFAULT 0,             -- 允许绝对差异（milli）
    max_pct_bp          INT          NOT NULL DEFAULT 0,             -- 允许相对差异，万分比（100 = 1%）
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT fk_podt_wh    FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),
    CONSTRAINT ck_podt_cat   CHECK (sku_category = trim(sku_category)),
    CONSTRAINT ck_podt_abs   CHECK (max_abs_qty_milli >= 0),
    CONSTRAINT ck_podt_pct   CHECK (max_pct_bp BETWEEN 0 AND 10000),
    CONSTRAINT ck_podt_notblank CHECK (max_abs_qty_milli > 0 OR max_pct_bp > 0),
    CONSTRAINT uq_podt_scope UNIQUE (warehouse_id, sku_category)     -- '' = 全品类，同仓只能一条
);

CREATE TABLE delivery_return (
    id                  BIGINT       PRIMARY KEY,
    waybill_id          BIGINT       NOT NULL,
    stop_no             SMALLINT     NOT NULL,
    handover_seq        INT          NOT NULL,                       -- RTN 来源单号 = {waybill_no}:{stop_no}:{handover_seq}
    status              VARCHAR(16)  NOT NULL DEFAULT 'OPEN',        -- OPEN/COUNTED/CANCELLED
    rtn_inbound_id      BIGINT,                                      -- 10 篇退货入库单
    counted_by          BIGINT,
    counted_at          TIMESTAMP,
    cancel_reason       VARCHAR(128),
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_dret        UNIQUE (waybill_id, stop_no, handover_seq),
    CONSTRAINT fk_dret_wb     FOREIGN KEY (waybill_id) REFERENCES waybill(id),
    CONSTRAINT fk_dret_rtn    FOREIGN KEY (rtn_inbound_id) REFERENCES inbound_order(id),
    CONSTRAINT ck_dret_seq    CHECK (handover_seq >= 1),
    CONSTRAINT ck_dret_status CHECK (status IN ('OPEN','COUNTED','CANCELLED')),
    -- COUNTED 必须已生成 RTN
    CONSTRAINT ck_dret_cnt    CHECK (status <> 'COUNTED' OR rtn_inbound_id IS NOT NULL),
    CONSTRAINT ck_dret_cancel CHECK (status <> 'CANCELLED' OR cancel_reason IS NOT NULL)
);
CREATE INDEX ix_dret_wb ON delivery_return(waybill_id, stop_no, status);

CREATE TABLE delivery_return_line (
    id                  BIGINT       PRIMARY KEY,
    delivery_return_id  BIGINT       NOT NULL,
    sku_id              BIGINT       NOT NULL,
    lot_id              BIGINT,
    reported_qty_milli  BIGINT       NOT NULL,                       -- 司机登记（装车未签收量）
    counted_qty_milli   BIGINT,                                      -- 实点，未点为空
    exception_case_id   BIGINT,                                      -- 第 10 篇异常单
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_dretl        UNIQUE (delivery_return_id, sku_id, lot_id),
    CONSTRAINT fk_dretl_ret    FOREIGN KEY (delivery_return_id) REFERENCES delivery_return(id),
    CONSTRAINT fk_dretl_sku    FOREIGN KEY (sku_id) REFERENCES sku(id),
    CONSTRAINT fk_dretl_lot    FOREIGN KEY (lot_id) REFERENCES lot(id),
    CONSTRAINT fk_dretl_exc    FOREIGN KEY (exception_case_id) REFERENCES exception_case(id),
    CONSTRAINT ck_dretl_qty    CHECK (reported_qty_milli >= 0 AND (counted_qty_milli IS NULL OR counted_qty_milli >= 0)),
    -- D7：实点 ≠ 登记数 ⇒ 必须挂异常单
    CONSTRAINT ck_dretl_exc    CHECK (counted_qty_milli IS NULL OR counted_qty_milli = reported_qty_milli OR exception_case_id IS NOT NULL)
);
CREATE INDEX ix_dretl_ret ON delivery_return_line(delivery_return_id);

-- -----------------------------------------------------------------------------
-- 只追加 / 重放只读
-- -----------------------------------------------------------------------------
-- pod_op 整行只追加（回放缓存；PG 侧另用授权收窄到 SELECT, INSERT）
CREATE TRIGGER trg_pod_op_append_only BEFORE UPDATE OR DELETE ON pod_op FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_pod_op_no_update BEFORE UPDATE ON pod_op BEGIN SELECT RAISE(ABORT, 'append_only_violation: pod_op'); END;
-- @sqlite-only CREATE TRIGGER trg_pod_op_no_delete BEFORE DELETE ON pod_op BEGIN SELECT RAISE(ABORT, 'append_only_violation: pod_op'); END;

-- pod_correction 去重键与首次结果建单后只读（重放结果恒定）
CREATE FUNCTION trg_podc_replay_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                    -- @pg-only
    IF NEW.driver_id IS DISTINCT FROM OLD.driver_id                                                      -- @pg-only
       OR NEW.correction_client_id IS DISTINCT FROM OLD.correction_client_id                             -- @pg-only
       OR NEW.request_hash IS DISTINCT FROM OLD.request_hash                                             -- @pg-only
       OR NEW.response_http IS DISTINCT FROM OLD.response_http                                           -- @pg-only
       OR NEW.approval_id IS DISTINCT FROM OLD.approval_id                                               -- @pg-only
       OR NEW.auto_tolerance IS DISTINCT FROM OLD.auto_tolerance                                         -- @pg-only
       OR NEW.corrected_pod_id IS DISTINCT FROM OLD.corrected_pod_id                                     -- @pg-only
       OR NEW.outbound_id IS DISTINCT FROM OLD.outbound_id THEN                                          -- @pg-only
        RAISE EXCEPTION 'podc_replay_immutable' USING ERRCODE = '23514';                                 -- @pg-only
    END IF;                                                                                              -- @pg-only
    RETURN NEW;                                                                                          -- @pg-only
END $$;                                                                                                  -- @pg-only
CREATE TRIGGER trg_podc_replay_immutable BEFORE UPDATE ON pod_correction FOR EACH ROW EXECUTE FUNCTION trg_podc_replay_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_podc_replay_immutable BEFORE UPDATE ON pod_correction
-- @sqlite-only WHEN (NEW.driver_id IS NOT OLD.driver_id OR NEW.correction_client_id IS NOT OLD.correction_client_id
-- @sqlite-only        OR NEW.request_hash IS NOT OLD.request_hash OR NEW.response_http IS NOT OLD.response_http
-- @sqlite-only        OR NEW.approval_id IS NOT OLD.approval_id OR NEW.auto_tolerance IS NOT OLD.auto_tolerance
-- @sqlite-only        OR NEW.corrected_pod_id IS NOT OLD.corrected_pod_id OR NEW.outbound_id IS NOT OLD.outbound_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'podc_replay_immutable'); END;

-- -----------------------------------------------------------------------------
-- SQLite no-REPLACE 守卫（00 §6.10 第 3/4 条：逐唯一键，每个唯一键的每列都要在 WHEN 里）
-- PG 侧没有 REPLACE，唯一键冲突由 ON CONFLICT / 唯一约束本身拦（应用层不用 REPLACE）。
-- -----------------------------------------------------------------------------
-- @sqlite-only CREATE TRIGGER trg_wb_no_replace BEFORE INSERT ON waybill
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM waybill w WHERE w.id = NEW.id OR w.code = NEW.code OR w.shipment_id = NEW.shipment_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'waybill_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_dstop_no_replace BEFORE INSERT ON delivery_stop
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM delivery_stop d WHERE d.id = NEW.id OR (d.waybill_id = NEW.waybill_id AND d.stop_no = NEW.stop_no))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'delivery_stop_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_dord_no_replace BEFORE INSERT ON delivery_order
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM delivery_order o WHERE o.id = NEW.id OR o.outbound_id = NEW.outbound_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'delivery_order_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_pod_op_no_replace BEFORE INSERT ON pod_op
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM pod_op p WHERE p.id = NEW.id OR (p.waybill_no = NEW.waybill_no AND p.stop_no = NEW.stop_no AND p.device_instance_id = NEW.device_instance_id AND p.op_seq = NEW.op_seq))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'pod_op_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_podl_no_replace BEFORE INSERT ON pod_line
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM pod_line l WHERE l.id = NEW.id OR (l.pod_id = NEW.pod_id AND l.outbound_line_id = NEW.outbound_line_id AND l.lot_id = NEW.lot_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'pod_line_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_podc_no_replace BEFORE INSERT ON pod_correction
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM pod_correction c WHERE c.id = NEW.id
-- @sqlite-only   OR (c.driver_id = NEW.driver_id AND c.correction_client_id = NEW.correction_client_id)
-- @sqlite-only   OR (NEW.approval_id IS NOT NULL AND c.approval_id = NEW.approval_id)
-- @sqlite-only   OR (NEW.status = 'PENDING' AND c.status = 'PENDING' AND c.corrected_pod_id = NEW.corrected_pod_id AND c.outbound_id = NEW.outbound_id)
-- @sqlite-only   OR (NEW.status = 'APPLIED' AND c.status = 'APPLIED' AND c.outbound_id = NEW.outbound_id AND c.correct_seq = NEW.correct_seq))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'pod_correction_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_podt_no_replace BEFORE INSERT ON pod_tolerance_config
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM pod_tolerance_config t WHERE t.id = NEW.id OR (t.warehouse_id = NEW.warehouse_id AND t.sku_category = NEW.sku_category))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'pod_tolerance_config_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_dret_no_replace BEFORE INSERT ON delivery_return
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM delivery_return r WHERE r.id = NEW.id OR (r.waybill_id = NEW.waybill_id AND r.stop_no = NEW.stop_no AND r.handover_seq = NEW.handover_seq))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'delivery_return_duplicate'); END;

-- @sqlite-only CREATE TRIGGER trg_dretl_no_replace BEFORE INSERT ON delivery_return_line
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM delivery_return_line x WHERE x.id = NEW.id OR (x.delivery_return_id = NEW.delivery_return_id AND x.sku_id = NEW.sku_id AND x.lot_id = NEW.lot_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'delivery_return_line_duplicate'); END;

-- -----------------------------------------------------------------------------
-- 授权（PG；pod_op 只追加，不授 UPDATE）
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON waybill, delivery_stop, delivery_order, pod_line, pod_correction, pod_tolerance_config, delivery_return, delivery_return_line TO wms_app;  -- @pg-only
GRANT SELECT, INSERT ON pod_op TO wms_app;  -- @pg-only
