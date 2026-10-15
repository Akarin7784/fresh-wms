-- =============================================================================
-- 第 3 篇 入库：收货、质检、上架（docs/03-入库.md）
--   库存只经第 2 篇原语：收货 post_in(RECEIVE) + hold(QUALITY, QC_PENDING)（UC1）；质检放行 unhold / 不合格 convert_hold → SCRAP_PENDING
--   （UC9；不合格、待处置一律 hold(SCRAP_PENDING)，挂 09 报损单）；上架 move(PUTAWAY)（UC2）；关单后收货更正单 post_in / post_out(ADJUST)。本文件不写 stock。
--   数量一律 BIGINT *_qty_milli（00 R2）；温度一律 *_c10（0.1 ℃ 整数）；时长一律 *_sec。
--   #5（10_returns.sql）对 inbound_order / inbound_line 的 ALTER（ck_inb_rtn_src、received/qc_passed/qc_failed 三列、
--   ck_inbl_int、ck_inbl_qc）已在基线落库，本篇不重复定义，也不改 10_returns.sql；本篇自己的整数约束叫 ck_inbl_int3。
--   本篇新建的 PG 函数一律 SET search_path = pg_catalog, public。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 入库单头
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_order (
    id              BIGINT       PRIMARY KEY,
    code            VARCHAR(64)  NOT NULL,   -- INB-/RTN- 前缀 + 00 §6.2 单号
    warehouse_id    BIGINT       NOT NULL,
    order_type      VARCHAR(24)  NOT NULL,   -- PURCHASE / RETURN / TRANSFER_IN
    source_system   VARCHAR(24)  NOT NULL,
    source_order_no VARCHAR(64)  NOT NULL,
    source_hash     CHAR(64),                -- 上游推单内容哈希（00 §6.5），小写 hex；内部生成的单（拒收回仓、盲收）可空
    supplier_id     BIGINT,
    status          VARCHAR(24)  NOT NULL DEFAULT 'CREATED',   -- 见 ck_inb_status
    work_date       DATE         NOT NULL,
    expected_at     TIMESTAMP,               -- 上游给的预计到货；预约到货 / 月台排班未定（03 §12 Q1），不建表
    dock_code       VARCHAR(32),             -- 实际卸货月台（自由文本，不做排班）
    vehicle_no      VARCHAR(24),
    arrived_at      TIMESTAMP,               -- 车辆到场（登记到货）
    unload_start_at TIMESTAMP,               -- 开始卸货 = 离开车厢冷链的起点（默认值，行上可覆盖）
    received_at     TIMESTAMP,
    closed_at       TIMESTAMP,
    supplier_reconciled_at TIMESTAMP,        -- 供应商对账结算时间（11 回写）；非空后不再接受收货更正（转 08）
    remark          VARCHAR(512),
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    created_by      BIGINT,
    CONSTRAINT uq_inb_code  UNIQUE (code),
    CONSTRAINT uq_inb_src   UNIQUE (source_system, source_order_no),   -- 业务层幂等（00 §6.5）
    CONSTRAINT ck_inb_type  CHECK (order_type IN ('PURCHASE','RETURN','TRANSFER_IN')),
    CONSTRAINT ck_inb_status CHECK (status IN ('CREATED','ARRIVED','RECEIVING','RECEIVED','PUTTING_AWAY','COMPLETED','CANCELLED')),
    CONSTRAINT ck_inb_hash  CHECK (source_hash IS NULL OR (length(source_hash) = 64 AND lower(source_hash) = source_hash)),
    -- 退货入库来源白名单 ck_inb_rtn_src 由 10_returns.sql ALTER（README 跨篇登记表），本篇不重复
    CONSTRAINT ck_inb_closed CHECK (status NOT IN ('COMPLETED','CANCELLED') OR closed_at IS NOT NULL),
    CONSTRAINT ck_inb_recon  CHECK (supplier_reconciled_at IS NULL OR (status = 'COMPLETED' AND supplier_reconciled_at >= closed_at)),
    CONSTRAINT fk_inb_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    -- 时间列整秒（B2）：PG 不许小数秒；SQLite 只收 'YYYY-MM-DD HH:MM:SS'（拒非 ISO、时区偏移、小数秒）。时区约定见 docs/03 §12 Q11
    CONSTRAINT ck_inb_ts CHECK ((closed_at IS NULL OR closed_at = date_trunc('second', closed_at)) AND (supplier_reconciled_at IS NULL OR supplier_reconciled_at = date_trunc('second', supplier_reconciled_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_inb_ts CHECK ((closed_at IS NULL OR (typeof(closed_at) = 'text' AND length(closed_at) = 19 AND datetime(closed_at) IS closed_at)) AND (supplier_reconciled_at IS NULL OR (typeof(supplier_reconciled_at) = 'text' AND length(supplier_reconciled_at) = 19 AND datetime(supplier_reconciled_at) IS supplier_reconciled_at))),
    CONSTRAINT ck_inb_ts2 CHECK ((expected_at IS NULL OR expected_at = date_trunc('second', expected_at)) AND (arrived_at IS NULL OR arrived_at = date_trunc('second', arrived_at)) AND (unload_start_at IS NULL OR unload_start_at = date_trunc('second', unload_start_at)) AND (received_at IS NULL OR received_at = date_trunc('second', received_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_inb_ts2 CHECK ((expected_at IS NULL OR (typeof(expected_at) = 'text' AND length(expected_at) = 19 AND datetime(expected_at) IS expected_at)) AND (arrived_at IS NULL OR (typeof(arrived_at) = 'text' AND length(arrived_at) = 19 AND datetime(arrived_at) IS arrived_at)) AND (unload_start_at IS NULL OR (typeof(unload_start_at) = 'text' AND length(unload_start_at) = 19 AND datetime(unload_start_at) IS unload_start_at)) AND (received_at IS NULL OR (typeof(received_at) = 'text' AND length(received_at) = 19 AND datetime(received_at) IS received_at))),
-- @sqlite-only     CONSTRAINT ck_inb_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
-- @sqlite-only     CONSTRAINT ck_inb_date CHECK ((work_date IS NULL OR (typeof(work_date) = 'text' AND length(work_date) = 10 AND date(work_date) IS work_date))),
    CONSTRAINT uq_inb_closed UNIQUE (id, closed_at)   -- 收货更正单组合外键：关单时间快照必须是真值
);
CREATE INDEX ix_inb_wh_status ON inbound_order(warehouse_id, status, work_date DESC);

-- -----------------------------------------------------------------------------
-- 入库行（也是质检行：02 §7.1.3 release_qc_hold 在这里累加 qc_passed）
--   received_qty_milli / qc_passed_qty_milli / qc_failed_qty_milli 三列和 ck_inbl_int、ck_inbl_qc 由 10_returns.sql ALTER 加（基线已有）。
--   received_qty_milli = Σ 收货记录（关单前维护）；关单后行不再改，净实收 = received_qty_milli + Σ inbound_correction(direction × qty)
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_line (
    id                  BIGINT       PRIMARY KEY,
    inbound_id          BIGINT       NOT NULL,   -- inbound_order.id（02 §7.1.3 写作 inbound_order_id，指的就是这一列）
    line_no             SMALLINT     NOT NULL,
    sku_id              BIGINT       NOT NULL,
    uom                 VARCHAR(16)  NOT NULL,   -- = sku.base_uom
    temp_zone           VARCHAR(16),             -- 下单时快照 sku.temperature_required：AMBIENT/CHILLED/FROZEN/FRESH
    ordered_qty_milli   BIGINT       NOT NULL DEFAULT 0,
    rejected_qty_milli  BIGINT       NOT NULL DEFAULT 0,   -- 月台拒收（不入账）
    putaway_qty_milli   BIGINT       NOT NULL DEFAULT 0,
    lot_id              BIGINT,
    production_date     DATE,
    expiry_date         DATE,
    cost_amount_fen     BIGINT,
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uq_inb_line UNIQUE (inbound_id, line_no),
    CONSTRAINT uq_inbl_ord UNIQUE (id, inbound_id),          -- 子表组合外键用：记录必须挂在本单的行上
    CONSTRAINT fk_inbl_order FOREIGN KEY (inbound_id) REFERENCES inbound_order(id),
    CONSTRAINT fk_inbl_sku   FOREIGN KEY (sku_id) REFERENCES sku(id),   -- R3：sku_id 补外键（小玛丽 r12）
    CONSTRAINT ck_inbl_tz  CHECK (temp_zone IS NULL OR temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_inbl_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_inbl_int3 CHECK (ordered_qty_milli = CAST(ordered_qty_milli AS BIGINT)
        AND rejected_qty_milli = CAST(rejected_qty_milli AS BIGINT) AND putaway_qty_milli = CAST(putaway_qty_milli AS BIGINT)),
-- @sqlite-only     CONSTRAINT ck_inbl_date CHECK ((production_date IS NULL OR (typeof(production_date) = 'text' AND length(production_date) = 10 AND date(production_date) IS production_date)) AND (expiry_date IS NULL OR (typeof(expiry_date) = 'text' AND length(expiry_date) = 10 AND date(expiry_date) IS expiry_date))),
    CONSTRAINT ck_inbl_qty CHECK (ordered_qty_milli >= 0 AND rejected_qty_milli >= 0 AND putaway_qty_milli >= 0)
    -- 「上架 ≤ 质检合格」要引用 qc_passed_qty_milli（10 的 ALTER 列，03 建表时还不存在），改由上架原语条件更新兜底，见 docs/03 §6.3
);
CREATE INDEX ix_inbl_sku ON inbound_line(sku_id, inbound_id);

-- -----------------------------------------------------------------------------
-- 到货测温（只追加）：scope=ZONE 按温区整车/整批测一次；scope=LINE 按行测（冷藏/冷冻行必测）
--   上下限是测温当时从温区配置取的快照；result 必须和读数一致；不合格只能拒收或转质检冻结
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_temp_check (
    id              BIGINT       PRIMARY KEY,
    warehouse_id    BIGINT       NOT NULL,
    inbound_id      BIGINT       NOT NULL,
    scope           VARCHAR(8)   NOT NULL,   -- ZONE / LINE
    temp_zone       VARCHAR(16)  NOT NULL,
    inbound_line_id BIGINT,                  -- scope=LINE 必填
    measured_c10    INTEGER      NOT NULL,   -- 实测中心温度 ×10
    min_c10         INTEGER,                 -- 快照；AMBIENT 可空
    max_c10         INTEGER,
    result          VARCHAR(8)   NOT NULL,   -- PASS / FAIL
    disposition     VARCHAR(8)   NOT NULL,   -- ACCEPT / QC_HOLD / REJECT
    op_key          VARCHAR(80)  NOT NULL,   -- TMP:{inbound_id}:{client_uuid}
    measured_by     BIGINT       NOT NULL,
    measured_at     TIMESTAMP    NOT NULL,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_itc_op   UNIQUE (op_key),
    CONSTRAINT uq_itc_ref  UNIQUE (id, inbound_id, disposition),
    CONSTRAINT fk_itc_order FOREIGN KEY (inbound_id) REFERENCES inbound_order(id),
    CONSTRAINT fk_itc_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT ck_itc_scope CHECK ((scope = 'ZONE' AND inbound_line_id IS NULL) OR (scope = 'LINE' AND inbound_line_id IS NOT NULL)),
    CONSTRAINT ck_itc_tz   CHECK (temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_itc_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_itc_range CHECK (measured_c10 BETWEEN -600 AND 600 AND (min_c10 IS NULL OR max_c10 IS NULL OR min_c10 <= max_c10)
        AND (temp_zone = 'AMBIENT' OR (min_c10 IS NOT NULL OR max_c10 IS NOT NULL))),
    CONSTRAINT ck_itc_result CHECK (
        (result = 'PASS' AND (min_c10 IS NULL OR measured_c10 >= min_c10) AND (max_c10 IS NULL OR measured_c10 <= max_c10))
        OR (result = 'FAIL' AND ((min_c10 IS NOT NULL AND measured_c10 < min_c10) OR (max_c10 IS NOT NULL AND measured_c10 > max_c10)))),
    CONSTRAINT ck_itc_ts CHECK ((measured_at IS NULL OR measured_at = date_trunc('second', measured_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_itc_ts CHECK ((measured_at IS NULL OR (typeof(measured_at) = 'text' AND length(measured_at) = 19 AND datetime(measured_at) IS measured_at))),
-- @sqlite-only     CONSTRAINT ck_itc_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_itc_disp CHECK (disposition IN ('ACCEPT','QC_HOLD','REJECT') AND (result = 'PASS' OR disposition <> 'ACCEPT'))
);
CREATE INDEX ix_itc_order ON inbound_temp_check(inbound_id, temp_zone);

-- -----------------------------------------------------------------------------
-- 收货记录（只追加，UC1）：一次收货 = post_in(RECEIVE) 到收货暂存位 + hold(QUALITY, QC_PENDING) 同量
--   冷链：offchain_sec = 离开车厢冷链到进入收货暂存冷区的秒数；上限是温区配置快照（未查到盒马 DC 标准，可配置）
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_receipt (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    op_key              VARCHAR(80)  NOT NULL,   -- RCV:{inbound_line_id}:{op_seq}；PDA 另走流水四元组
    qty_milli           BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,   -- 收货暂存位库存行（post_in 目标）
    hold_id             BIGINT       NOT NULL,   -- 同事务 hold(QUALITY, QC_PENDING)
    movement_biz_no     VARCHAR(64)  NOT NULL,   -- 流水 biz_no（= inbound_order.code）
    lot_id              BIGINT,
    temp_zone           VARCHAR(16)  NOT NULL,
    temp_check_id       BIGINT,                  -- 非 AMBIENT 必填，且只能引用 ACCEPT / QC_HOLD 的测温
    temp_check_disp     VARCHAR(8),
    offchain_start_at   TIMESTAMP,
    offchain_end_at     TIMESTAMP,
    offchain_sec        INTEGER,
    offchain_limit_sec  INTEGER,                 -- 快照（可配置）
    is_offchain_over    SMALLINT     NOT NULL DEFAULT 0,
    received_by         BIGINT       NOT NULL,
    received_at         TIMESTAMP    NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_rcp_op   UNIQUE (op_key),
    CONSTRAINT uq_rcp_hold UNIQUE (hold_id),
    CONSTRAINT uq_rcp_ref  UNIQUE (id, inbound_line_id, received_by),   -- 上架记录 SoD 组合外键用
    CONSTRAINT fk_rcp_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_rcp_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_rcp_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_rcp_temp FOREIGN KEY (temp_check_id, inbound_id, temp_check_disp) REFERENCES inbound_temp_check(id, inbound_id, disposition),
    CONSTRAINT ck_rcp_qty  CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_rcp_tz   CHECK (temp_zone IN ('AMBIENT','CHILLED','FROZEN','FRESH')),
    CONSTRAINT fk_rcp_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_rcp_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_rcp_temp CHECK (
        (temp_check_id IS NULL AND temp_check_disp IS NULL AND temp_zone = 'AMBIENT')
        OR (temp_check_id IS NOT NULL AND temp_check_disp IN ('ACCEPT','QC_HOLD'))),
    CONSTRAINT ck_rcp_ts CHECK ((offchain_start_at IS NULL OR offchain_start_at = date_trunc('second', offchain_start_at)) AND (offchain_end_at IS NULL OR offchain_end_at = date_trunc('second', offchain_end_at)) AND (received_at IS NULL OR received_at = date_trunc('second', received_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_rcp_ts CHECK ((offchain_start_at IS NULL OR (typeof(offchain_start_at) = 'text' AND length(offchain_start_at) = 19 AND datetime(offchain_start_at) IS offchain_start_at)) AND (offchain_end_at IS NULL OR (typeof(offchain_end_at) = 'text' AND length(offchain_end_at) = 19 AND datetime(offchain_end_at) IS offchain_end_at)) AND (received_at IS NULL OR (typeof(received_at) = 'text' AND length(received_at) = 19 AND datetime(received_at) IS received_at))),
-- @sqlite-only     CONSTRAINT ck_rcp_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_rcp_chain CHECK (
        (temp_zone = 'AMBIENT' AND offchain_sec IS NULL AND is_offchain_over = 0)
        OR (temp_zone <> 'AMBIENT' AND offchain_start_at IS NOT NULL AND offchain_end_at IS NOT NULL
            AND offchain_sec IS NOT NULL AND offchain_sec >= 0 AND offchain_limit_sec IS NOT NULL AND offchain_limit_sec > 0
            AND is_offchain_over = (CASE WHEN offchain_sec > offchain_limit_sec THEN 1 ELSE 0 END)))
);
CREATE INDEX ix_rcp_line ON inbound_receipt(inbound_line_id, received_at);

-- -----------------------------------------------------------------------------
-- 收货更正单（只追加，盒马「收货更正」对应物；fresh-rules-decisions §5）：关单后不改原单、不改收货记录、不改入库行，
--   只经 02 原语补一条正/反向流水：+ post_in(ADJUST)，− post_out(ADJUST)（biz_type=ADJUST，biz_no = 本更正单号），movement_id 挂这条流水。
--   一行 = 一张已终审、已过账的更正单（审批在 12 审批单 approval_no 上走完再落本表）。审批窗口按 approved_at − 关单时间：
--     ≤ 24h：approval_tier=SUPERVISOR（仓库主管）；> 24h 且 ≤ 7d：DUAL（主管 + 采购）；> 7d 或已对账结算：拒绝，改走 08 盘点差异/库存调整。
--   收货人（received_by，经组合外键从收货记录带过来）不能当任何一级审批人；申请人也不能自批。
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_correction (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(64)  NOT NULL,   -- IRC- 前缀单号（00 §6.2），也是流水 biz_no
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    receipt_id          BIGINT       NOT NULL,   -- 被更正的收货记录（不改它）
    received_by         BIGINT       NOT NULL,   -- = 该收货记录的 received_by（fk_irc_rcp）
    order_closed_at     TIMESTAMP    NOT NULL,   -- = inbound_order.closed_at（fk_irc_closed），窗口起点
    op_key              VARCHAR(80)  NOT NULL,   -- IRC:{receipt_id}:{op_seq}
    direction           SMALLINT     NOT NULL,   -- 1 正向补收 / -1 反向冲减
    qty_milli           BIGINT       NOT NULL,
    stock_id            BIGINT       NOT NULL,   -- 过账的库存行
    movement_id         BIGINT       NOT NULL,   -- 02 原语写出的 ADJUST 流水（trg_irc_guard 核对方向、数量、库存行、biz_no）
    reason_code         VARCHAR(16)  NOT NULL,   -- COUNT_ERROR / WEIGHT_ERROR / WRONG_SKU / WRONG_BATCH / QUALITY_FOUND / OTHER
    reason_note         VARCHAR(512),            -- OTHER 必填
    approval_no         VARCHAR(64)  NOT NULL,   -- 12 审批单号 APR-…
    approval_tier       VARCHAR(16)  NOT NULL,   -- SUPERVISOR / DUAL
    requested_by        BIGINT       NOT NULL,
    requested_at        TIMESTAMP    NOT NULL,
    supervisor_id       BIGINT       NOT NULL,
    purchasing_id       BIGINT,                  -- DUAL 必填
    approved_at         TIMESTAMP    NOT NULL,   -- 终审 = 过账时间（B3）：PG 非属主写入由 trg_irc_guard 覆盖成库时钟（statement_timestamp，整秒 UTC）；SQLite 须在 now ±300s 内（trg_irc_now），窗口按落库 approved_at 算
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_irc_code UNIQUE (code),
    CONSTRAINT uq_irc_op   UNIQUE (op_key),
    CONSTRAINT uq_irc_mv   UNIQUE (movement_id),   -- 一条流水只能挂一张更正单
    CONSTRAINT fk_irc_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_irc_rcp FOREIGN KEY (receipt_id, inbound_line_id, received_by) REFERENCES inbound_receipt(id, inbound_line_id, received_by),
    CONSTRAINT fk_irc_closed FOREIGN KEY (inbound_id, order_closed_at) REFERENCES inbound_order(id, closed_at),
    CONSTRAINT fk_irc_stock FOREIGN KEY (stock_id) REFERENCES stock(id),
    CONSTRAINT fk_irc_mv FOREIGN KEY (movement_id) REFERENCES stock_movement_key(movement_id),
    CONSTRAINT ck_irc_dir CHECK (direction IN (1, -1)),
    CONSTRAINT ck_irc_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_irc_reason CHECK (reason_code IN ('COUNT_ERROR','WEIGHT_ERROR','WRONG_SKU','WRONG_BATCH','QUALITY_FOUND','OTHER')
        AND (reason_code <> 'OTHER' OR (reason_note IS NOT NULL AND length(trim(reason_note)) >= 4))),
    CONSTRAINT ck_irc_apr CHECK (approval_no LIKE 'APR-%' AND length(approval_no) BETWEEN 22 AND 36),
    CONSTRAINT ck_irc_tier CHECK ((approval_tier = 'SUPERVISOR' AND purchasing_id IS NULL)
        OR (approval_tier = 'DUAL' AND purchasing_id IS NOT NULL AND purchasing_id <> supervisor_id)),
    -- 职责分离（§5.2）：收货人不能审批（任何一级）
    CONSTRAINT ck_irc_receiver_sod CHECK (supervisor_id <> received_by AND (purchasing_id IS NULL OR purchasing_id <> received_by)),
    -- 申请人不能自批
    CONSTRAINT ck_irc_self_apr CHECK (supervisor_id <> requested_by AND (purchasing_id IS NULL OR purchasing_id <> requested_by)),
    CONSTRAINT ck_irc_time CHECK (requested_at <= approved_at),
    CONSTRAINT fk_irc_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
-- @sqlite-only     CONSTRAINT ck_irc_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_irc_ts CHECK ((order_closed_at IS NULL OR order_closed_at = date_trunc('second', order_closed_at)) AND (requested_at IS NULL OR requested_at = date_trunc('second', requested_at)) AND (approved_at IS NULL OR approved_at = date_trunc('second', approved_at)))  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_irc_ts CHECK ((order_closed_at IS NULL OR (typeof(order_closed_at) = 'text' AND length(order_closed_at) = 19 AND datetime(order_closed_at) IS order_closed_at)) AND (requested_at IS NULL OR (typeof(requested_at) = 'text' AND length(requested_at) = 19 AND datetime(requested_at) IS requested_at)) AND (approved_at IS NULL OR (typeof(approved_at) = 'text' AND length(approved_at) = 19 AND datetime(approved_at) IS approved_at)))
);
CREATE INDEX ix_irc_line ON inbound_correction(inbound_line_id);

-- -----------------------------------------------------------------------------
-- 上架记录（只追加，UC2）：move(PUTAWAY) 暂存位 → 存储位。received_by 经组合外键从收货记录带过来，
--   ck_inbp_sod 在库层拦「收货人 = 上架人」（00 §2 SoD）。小仓放宽须带审批单号（00：放宽本身要记审计），格式同 12b ck_apr_code（ck_inbp_waiver，两库都区分大小写）。
--   计数：trg_inbp_apply（AFTER INSERT，PG SECURITY DEFINER）累加 inbound_line.putaway_qty_milli，超 qc_passed 或单已关即报错；wms_app 不能直接 UPDATE 计数列
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_putaway (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    receipt_id          BIGINT       NOT NULL,
    received_by         BIGINT       NOT NULL,   -- 必须等于该收货记录的 received_by（fk_inbp_rcp）
    putaway_by          BIGINT       NOT NULL,
    sod_waiver_no       VARCHAR(64),             -- 放宽 SoD 的审批单号；为空即强制分离
    op_key              VARCHAR(80)  NOT NULL,   -- PUT:{receipt_id}:{op_seq}
    from_stock_id       BIGINT       NOT NULL,
    to_location_id      BIGINT       NOT NULL,
    qty_milli           BIGINT       NOT NULL,
    movement_biz_no     VARCHAR(64)  NOT NULL,
    offchain_sec        INTEGER,                 -- 暂存位 → 存储位途中离开冷链的秒数（非 AMBIENT 必填）
    putaway_at          TIMESTAMP    NOT NULL,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_inbp_op  UNIQUE (op_key),
    CONSTRAINT fk_inbp_rcp FOREIGN KEY (receipt_id, inbound_line_id, received_by) REFERENCES inbound_receipt(id, inbound_line_id, received_by),
    CONSTRAINT fk_inbp_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_inbp_loc FOREIGN KEY (to_location_id) REFERENCES location(id),
    CONSTRAINT ck_inbp_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT)),
    CONSTRAINT ck_inbp_sod CHECK (putaway_by <> received_by OR sod_waiver_no IS NOT NULL),
    CONSTRAINT fk_inbp_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_inbp_waiver CHECK (sod_waiver_no IS NULL OR sod_waiver_no ~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$'),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_inbp_waiver CHECK (sod_waiver_no IS NULL OR (length(sod_waiver_no) BETWEEN 22 AND 36 AND substr(sod_waiver_no, 1, 4) = 'APR-' AND substr(sod_waiver_no, 5, length(sod_waiver_no) - 20) NOT GLOB '*[^A-Z0-9]*' AND substr(sod_waiver_no, 5, length(sod_waiver_no) - 20) <> '' AND substr(sod_waiver_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' AND (substr(sod_waiver_no, -11, 2) GLOB '0[1-9]' OR substr(sod_waiver_no, -11, 2) GLOB '1[0-2]') AND (substr(sod_waiver_no, -9, 2) GLOB '0[1-9]' OR substr(sod_waiver_no, -9, 2) GLOB '[12][0-9]' OR substr(sod_waiver_no, -9, 2) GLOB '3[01]'))),
    CONSTRAINT ck_inbp_ts CHECK ((putaway_at IS NULL OR putaway_at = date_trunc('second', putaway_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_inbp_ts CHECK ((putaway_at IS NULL OR (typeof(putaway_at) = 'text' AND length(putaway_at) = 19 AND datetime(putaway_at) IS putaway_at))),
-- @sqlite-only     CONSTRAINT ck_inbp_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_inbp_chain CHECK (offchain_sec IS NULL OR offchain_sec >= 0)
);
CREATE INDEX ix_inbp_line ON inbound_putaway(inbound_line_id);
CREATE INDEX ix_inbp_rcp  ON inbound_putaway(receipt_id);

-- -----------------------------------------------------------------------------
-- 入库后质量反馈（盒马「质量反馈单」对应物）：上架复检或在库发现来货质量问题，冻结受影响库存并向上游反馈
--   发现时 hold(QUALITY, QC_PENDING, source_type=INBOUND_FB)；处置：SCRAP（convert_hold → SCRAP_PENDING，第 9 篇）、
--   RETURN_SUPPLIER（退供：同样先 convert_hold → SCRAP_PENDING 待处置，退供/报废由 10/09 完成）、REJECTED（反馈驳回，unhold）、CLAIM_ONLY（只索赔，库存另行处理）
-- -----------------------------------------------------------------------------
CREATE TABLE inbound_quality_feedback (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    code                VARCHAR(64)  NOT NULL,   -- IQF- 前缀单号
    inbound_id          BIGINT       NOT NULL,
    inbound_line_id     BIGINT       NOT NULL,
    lot_id              BIGINT,
    stage               VARCHAR(16)  NOT NULL,   -- PUTAWAY_RECHECK / IN_STOCK
    issue_code          VARCHAR(16)  NOT NULL,   -- ROT / DAMAGE / TEMP / SPEC / SHORT_WEIGHT / FOREIGN / OTHER
    affected_qty_milli  BIGINT       NOT NULL,
    stock_id            BIGINT,
    hold_id             BIGINT,                  -- CLAIM_ONLY 可无冻结
    scrap_hold_id       BIGINT,                  -- SCRAP / RETURN_SUPPLIER：convert_hold 出的 hold(SCRAP_PENDING)（挂 09 报损单），trg_iqf_guard 核对类型
    status              VARCHAR(16)  NOT NULL DEFAULT 'OPEN',      -- OPEN / CLOSED
    disposition         VARCHAR(24)  NOT NULL DEFAULT 'PENDING',   -- PENDING / SCRAP / RETURN_SUPPLIER / REJECTED / CLAIM_ONLY
    reported_by         BIGINT       NOT NULL,
    found_at            TIMESTAMP    NOT NULL,
    closed_by           BIGINT,
    closed_at           TIMESTAMP,
    remark              VARCHAR(512),
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    updated_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),
    CONSTRAINT uq_iqf_code UNIQUE (code),
    CONSTRAINT fk_iqf_line FOREIGN KEY (inbound_line_id, inbound_id) REFERENCES inbound_line(id, inbound_id),
    CONSTRAINT fk_iqf_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    CONSTRAINT fk_iqf_scrap FOREIGN KEY (scrap_hold_id) REFERENCES stock_hold(id),
    CONSTRAINT ck_iqf_scrap CHECK ((disposition IN ('SCRAP','RETURN_SUPPLIER')) = (scrap_hold_id IS NOT NULL)),
    CONSTRAINT ck_iqf_stage CHECK (stage IN ('PUTAWAY_RECHECK','IN_STOCK')),
    CONSTRAINT ck_iqf_issue CHECK (issue_code IN ('ROT','DAMAGE','TEMP','SPEC','SHORT_WEIGHT','FOREIGN','OTHER')),
    CONSTRAINT ck_iqf_qty CHECK (affected_qty_milli > 0 AND affected_qty_milli = CAST(affected_qty_milli AS BIGINT)),
    CONSTRAINT ck_iqf_disp CHECK (disposition IN ('PENDING','SCRAP','RETURN_SUPPLIER','REJECTED','CLAIM_ONLY')),
    CONSTRAINT ck_iqf_hold CHECK (disposition = 'CLAIM_ONLY' OR hold_id IS NOT NULL),
    CONSTRAINT fk_iqf_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_iqf_lot FOREIGN KEY (lot_id) REFERENCES lot(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT fk_iqf_stock FOREIGN KEY (stock_id) REFERENCES stock(id),   -- R3：补外键（小玛丽 r12）
    CONSTRAINT ck_iqf_ts CHECK ((found_at IS NULL OR found_at = date_trunc('second', found_at)) AND (closed_at IS NULL OR closed_at = date_trunc('second', closed_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_iqf_ts CHECK ((found_at IS NULL OR (typeof(found_at) = 'text' AND length(found_at) = 19 AND datetime(found_at) IS found_at)) AND (closed_at IS NULL OR (typeof(closed_at) = 'text' AND length(closed_at) = 19 AND datetime(closed_at) IS closed_at))),
-- @sqlite-only     CONSTRAINT ck_iqf_cts CHECK ((created_at IS NULL OR (typeof(created_at) = 'text' AND length(created_at) = 19 AND datetime(created_at) IS created_at))),
    CONSTRAINT ck_iqf_close CHECK (
        (status = 'OPEN' AND disposition = 'PENDING' AND closed_by IS NULL AND closed_at IS NULL)
        OR (status = 'CLOSED' AND disposition <> 'PENDING' AND closed_by IS NOT NULL AND closed_at IS NOT NULL AND closed_by <> reported_by))
);
CREATE INDEX ix_iqf_line ON inbound_quality_feedback(inbound_line_id);
CREATE INDEX ix_iqf_open ON inbound_quality_feedback(warehouse_id, status, found_at DESC);

-- -----------------------------------------------------------------------------
-- 只追加：测温、收货、更正单、上架四张记录表（复用第 2 篇 trg_append_only；SQLite 等价触发器；TRUNCATE 另拦）
-- 质量反馈单：关单后不能再改；发现时的事实列（行、数量、冻结、发现人）任何时候不能改；SCRAP / RETURN_SUPPLIER 必须挂 hold(SCRAP_PENDING)
-- 已关单（COMPLETED）的入库单和它的行：不能再改、删、加行；单头只许把 supplier_reconciled_at 由空补上（11 回写对账）
-- 本篇 9 个 PG 函数都固定 search_path = pg_catalog, public, pg_temp（pg_temp 显式放最后：不写时 PG 会先查会话临时表，可被 CREATE TEMP TABLE 冒充）（trg_iqf_guard / trg_inb_closed_guard / trg_inbl_closed_guard / trg_irc_guard / trg_inbp_apply / trg_inbl_counter_guard / trg_inb_time_now / trg_inb_created_now / trg_inb_forward）
-- 时间约定（Doro 09:10）：服务端生成的审批 / 状态时间（inbound_order.closed_at、supplier_reconciled_at，质量反馈 closed_at，更正单 approved_at）
--   PG 在 BEFORE 触发器里把非属主写入覆盖成 date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')（表属主豁免：种子 / 迁移，同 10 trg_srtn_zclock）；
--   SQLite 不能改 NEW：CHECK 只收 length 19 且 datetime(x) IS x 的整秒 'YYYY-MM-DD HH:MM:SS'，触发器再要求与 now 相差 ≤ 300 秒（strftime 为 NULL 也报 inbound_clock_skew）。
--   窗口 / 对账比较用落库值按整秒：PG 原生 TIMESTAMP（ck_*_ts 保证整秒），SQLite 一律 CAST(strftime('%s', x) AS INTEGER)。
--   设备 / 业务上报时间（测温、收货、上架、发现、离冷链、预计 / 到场 / 卸货、申请时间）不强制 now，SQLite 只校验格式。比较一律按整秒。
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_itc_append_only BEFORE UPDATE OR DELETE ON inbound_temp_check     FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_rcp_append_only BEFORE UPDATE OR DELETE ON inbound_receipt        FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_irc_append_only BEFORE UPDATE OR DELETE ON inbound_correction     FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_inbp_append_only BEFORE UPDATE OR DELETE ON inbound_putaway       FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_itc_no_truncate BEFORE TRUNCATE ON inbound_temp_check FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_rcp_no_truncate BEFORE TRUNCATE ON inbound_receipt FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_irc_no_truncate BEFORE TRUNCATE ON inbound_correction FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_inbp_no_truncate BEFORE TRUNCATE ON inbound_putaway FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE FUNCTION trg_iqf_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'iqf_immutable' USING ERRCODE = '42501'; END IF;  -- @pg-only
    IF TG_OP = 'UPDATE' AND (OLD.status = 'CLOSED' OR NEW.id <> OLD.id OR NEW.inbound_line_id <> OLD.inbound_line_id  -- @pg-only
       OR NEW.affected_qty_milli <> OLD.affected_qty_milli OR NEW.hold_id IS DISTINCT FROM OLD.hold_id  -- @pg-only
       OR NEW.reported_by <> OLD.reported_by OR NEW.found_at <> OLD.found_at) THEN  -- @pg-only
        RAISE EXCEPTION 'iqf_immutable' USING ERRCODE = '42501';  -- @pg-only
    END IF;  -- @pg-only
    IF NEW.status = 'CLOSED' AND (TG_OP = 'INSERT' OR OLD.status <> 'CLOSED') AND current_user IS DISTINCT FROM (SELECT r.rolname FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid WHERE c.oid = 'public.inbound_quality_feedback'::regclass) THEN NEW.closed_at := date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'); END IF;   -- 时间约定：服务端状态时间取 now  -- @pg-only
    IF NEW.scrap_hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.scrap_hold_id AND h.hold_type = 'SCRAP_PENDING') THEN  -- @pg-only
        RAISE EXCEPTION 'iqf_scrap_hold_not_scrap_pending' USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_iqf_guard BEFORE INSERT OR UPDATE OR DELETE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_iqf_guard();  -- @pg-only
CREATE FUNCTION trg_inb_closed_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF OLD.status = 'COMPLETED' AND (TG_OP = 'DELETE'  -- @pg-only
       OR (to_jsonb(NEW) - 'supplier_reconciled_at' - 'version' - 'updated_at') <> (to_jsonb(OLD) - 'supplier_reconciled_at' - 'version' - 'updated_at')  -- @pg-only
       OR (OLD.supplier_reconciled_at IS NOT NULL AND NEW.supplier_reconciled_at IS DISTINCT FROM OLD.supplier_reconciled_at)) THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_order_closed_immutable: %', OLD.id USING ERRCODE = '42501';  -- @pg-only
    END IF;  -- @pg-only
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inb_closed_guard BEFORE UPDATE OR DELETE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_inb_closed_guard();  -- @pg-only
CREATE FUNCTION trg_inbl_closed_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF EXISTS (SELECT 1 FROM inbound_order o WHERE o.status = 'COMPLETED'  -- @pg-only
               AND o.id IN (CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.inbound_id END, CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.inbound_id END)) THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_line_closed_immutable' USING ERRCODE = '42501';  -- @pg-only
    END IF;  -- @pg-only
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inbl_closed_guard BEFORE INSERT OR UPDATE OR DELETE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_inbl_closed_guard();  -- @pg-only
CREATE FUNCTION trg_irc_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE  -- @pg-only
    v_status VARCHAR(24); v_recon TIMESTAMP; v_ok BOOLEAN;  -- @pg-only
BEGIN  -- @pg-only
    IF NEW.approved_at IS NULL THEN RAISE EXCEPTION 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at NULL' USING ERRCODE = '23514'; END IF;  -- 显式 NULL 拒绝  -- @pg-only
    IF current_user IS DISTINCT FROM (SELECT r.rolname FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid WHERE c.oid = 'public.inbound_correction'::regclass) THEN NEW.approved_at := date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC'); END IF;   -- B3：非属主传的值一律覆盖成库时钟（属主豁免：种子 / 迁移，同 10 trg_srtn_zclock）  -- @pg-only
    SELECT o.status, o.supplier_reconciled_at INTO v_status, v_recon FROM inbound_order o WHERE o.id = NEW.inbound_id;  -- @pg-only
    IF v_status IS DISTINCT FROM 'COMPLETED' THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_order_not_closed: %', NEW.inbound_id USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    IF v_recon IS NOT NULL AND v_recon <= NEW.approved_at THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust' USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    IF NEW.approved_at < NEW.order_closed_at THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_before_close' USING ERRCODE = '23514';  -- @pg-only
    ELSIF NEW.approved_at - NEW.order_closed_at > interval '7 days' THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_window_closed: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust' USING ERRCODE = '23514';  -- @pg-only
    ELSIF NEW.approved_at - NEW.order_closed_at > interval '24 hours' AND NEW.approval_tier <> 'DUAL' THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_dual_approval_required' USING ERRCODE = '23514';  -- @pg-only
    ELSIF NEW.approved_at - NEW.order_closed_at <= interval '24 hours' AND NEW.approval_tier <> 'SUPERVISOR' THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_tier_mismatch' USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    SELECT EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = NEW.movement_id AND m.biz_type = 'ADJUST' AND m.biz_no = NEW.code  -- @pg-only
                   AND m.direction = NEW.direction AND m.move_qty_milli = NEW.qty_milli AND m.stock_id = NEW.stock_id) INTO v_ok;  -- @pg-only
    IF NOT v_ok THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_correction_movement_mismatch: %', NEW.movement_id USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_irc_guard BEFORE INSERT ON inbound_correction FOR EACH ROW EXECUTE FUNCTION trg_irc_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_itc_no_update BEFORE UPDATE ON inbound_temp_check BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
-- @sqlite-only CREATE TRIGGER trg_itc_no_delete BEFORE DELETE ON inbound_temp_check BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
-- @sqlite-only CREATE TRIGGER trg_rcp_no_update BEFORE UPDATE ON inbound_receipt BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
-- @sqlite-only CREATE TRIGGER trg_rcp_no_delete BEFORE DELETE ON inbound_receipt BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_no_update BEFORE UPDATE ON inbound_correction BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_no_delete BEFORE DELETE ON inbound_correction BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
-- @sqlite-only CREATE TRIGGER trg_inbp_no_update BEFORE UPDATE ON inbound_putaway BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
-- @sqlite-only CREATE TRIGGER trg_inbp_no_delete BEFORE DELETE ON inbound_putaway BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
-- trg_inb_rec_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_irc_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inbp_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_itc_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- @sqlite-only CREATE TRIGGER trg_iqf_guard_upd BEFORE UPDATE ON inbound_quality_feedback
-- @sqlite-only WHEN OLD.status = 'CLOSED' OR NEW.id <> OLD.id OR NEW.inbound_line_id <> OLD.inbound_line_id OR NEW.affected_qty_milli <> OLD.affected_qty_milli
-- @sqlite-only   OR NEW.hold_id IS NOT OLD.hold_id OR NEW.reported_by <> OLD.reported_by OR NEW.found_at <> OLD.found_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_no_delete BEFORE DELETE ON inbound_quality_feedback BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;
-- trg_iqf_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inb_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- trg_inbl_no_replace：挪到文件末尾（SQLite 后建的触发器先执行，no-replace 必须先于时钟 / 业务触发器判定）
-- @sqlite-only CREATE TRIGGER trg_iqf_scrap_ins BEFORE INSERT ON inbound_quality_feedback WHEN NEW.scrap_hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.scrap_hold_id AND h.hold_type = 'SCRAP_PENDING') BEGIN SELECT RAISE(ABORT, 'iqf_scrap_hold_not_scrap_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_scrap_upd BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.scrap_hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.scrap_hold_id AND h.hold_type = 'SCRAP_PENDING') BEGIN SELECT RAISE(ABORT, 'iqf_scrap_hold_not_scrap_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_closed_upd BEFORE UPDATE ON inbound_order
-- @sqlite-only WHEN OLD.status = 'COMPLETED' AND (NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.order_type IS NOT OLD.order_type
-- @sqlite-only   OR NEW.source_system IS NOT OLD.source_system OR NEW.source_order_no IS NOT OLD.source_order_no OR NEW.source_hash IS NOT OLD.source_hash
-- @sqlite-only   OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.status IS NOT OLD.status OR NEW.work_date IS NOT OLD.work_date OR NEW.expected_at IS NOT OLD.expected_at
-- @sqlite-only   OR NEW.dock_code IS NOT OLD.dock_code OR NEW.vehicle_no IS NOT OLD.vehicle_no OR NEW.arrived_at IS NOT OLD.arrived_at OR NEW.unload_start_at IS NOT OLD.unload_start_at
-- @sqlite-only   OR NEW.received_at IS NOT OLD.received_at OR NEW.closed_at IS NOT OLD.closed_at OR NEW.remark IS NOT OLD.remark OR NEW.created_at IS NOT OLD.created_at
-- @sqlite-only   OR NEW.created_by IS NOT OLD.created_by OR (OLD.supplier_reconciled_at IS NOT NULL AND NEW.supplier_reconciled_at IS NOT OLD.supplier_reconciled_at))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'inbound_order_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_closed_del BEFORE DELETE ON inbound_order WHEN OLD.status = 'COMPLETED' BEGIN SELECT RAISE(ABORT, 'inbound_order_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_closed_ins BEFORE INSERT ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_closed_upd BEFORE UPDATE ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.status = 'COMPLETED' AND o.id IN (OLD.inbound_id, NEW.inbound_id)) BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_closed_del BEFORE DELETE ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = OLD.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_line_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_not_closed BEFORE INSERT ON inbound_correction WHEN NOT EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_correction_order_not_closed'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_reconciled BEFORE INSERT ON inbound_correction WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.supplier_reconciled_at IS NOT NULL AND CAST(strftime('%s', o.supplier_reconciled_at) AS INTEGER) <= CAST(strftime('%s', NEW.approved_at) AS INTEGER)) BEGIN SELECT RAISE(ABORT, 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_now BEFORE INSERT ON inbound_correction WHEN strftime('%s', NEW.approved_at) IS NULL OR substr(NEW.approved_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300 BEGIN SELECT RAISE(ABORT, 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_before_close BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) < 0 BEGIN SELECT RAISE(ABORT, 'inbound_correction_before_close'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_window BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) > 604800 BEGIN SELECT RAISE(ABORT, 'inbound_correction_window_closed: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_dual BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) > 86400 AND (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) <= 604800 AND NEW.approval_tier <> 'DUAL' BEGIN SELECT RAISE(ABORT, 'inbound_correction_dual_approval_required'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_tier BEFORE INSERT ON inbound_correction WHEN (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) >= 0 AND (CAST(strftime('%s', NEW.approved_at) AS INTEGER) - CAST(strftime('%s', NEW.order_closed_at) AS INTEGER)) <= 86400 AND NEW.approval_tier <> 'SUPERVISOR' BEGIN SELECT RAISE(ABORT, 'inbound_correction_tier_mismatch'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_movement BEFORE INSERT ON inbound_correction WHEN NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = NEW.movement_id AND m.biz_type = 'ADJUST' AND m.biz_no = NEW.code AND m.direction = NEW.direction AND m.move_qty_milli = NEW.qty_milli AND m.stock_id = NEW.stock_id) BEGIN SELECT RAISE(ABORT, 'inbound_correction_movement_mismatch'); END;
CREATE FUNCTION trg_inbp_apply() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE v_status VARCHAR(24); v_n BIGINT;  -- @pg-only
BEGIN  -- @pg-only
    SELECT o.status INTO v_status FROM inbound_order o WHERE o.id = NEW.inbound_id;  -- @pg-only
    IF v_status = 'COMPLETED' THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_putaway_closed_immutable' USING ERRCODE = '42501';  -- @pg-only
    END IF;  -- @pg-only
    UPDATE inbound_line l SET putaway_qty_milli = l.putaway_qty_milli + NEW.qty_milli, version = l.version + 1  -- @pg-only
     WHERE l.id = NEW.inbound_line_id AND l.putaway_qty_milli + NEW.qty_milli <= l.qc_passed_qty_milli;  -- @pg-only
    GET DIAGNOSTICS v_n = ROW_COUNT;  -- @pg-only
    IF v_n = 0 THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_putaway_over_qty: 42214 OVER_QTY reason=OVER_PUTAWAY' USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    RETURN NULL;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inbp_apply AFTER INSERT ON inbound_putaway FOR EACH ROW EXECUTE FUNCTION trg_inbp_apply();  -- @pg-only
CREATE FUNCTION trg_inbl_counter_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF NEW.putaway_qty_milli > NEW.qc_passed_qty_milli THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_putaway_over_qc_passed: %', NEW.id USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    IF (TG_OP = 'INSERT' AND NEW.putaway_qty_milli <> 0)  -- @pg-only
       OR (TG_OP = 'UPDATE' AND NEW.putaway_qty_milli IS DISTINCT FROM OLD.putaway_qty_milli  -- @pg-only
           AND NEW.putaway_qty_milli <> (SELECT COALESCE(sum(p.qty_milli), 0) FROM inbound_putaway p WHERE p.inbound_line_id = NEW.id)) THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_putaway_counter_mismatch: %', NEW.id USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inbl_counter_guard BEFORE INSERT OR UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_inbl_counter_guard();  -- @pg-only
REVOKE ALL ON FUNCTION trg_inbp_apply() FROM PUBLIC;  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inbp_closed BEFORE INSERT ON inbound_putaway WHEN EXISTS (SELECT 1 FROM inbound_order o WHERE o.id = NEW.inbound_id AND o.status = 'COMPLETED') BEGIN SELECT RAISE(ABORT, 'inbound_putaway_closed_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_inbp_over BEFORE INSERT ON inbound_putaway WHEN NOT EXISTS (SELECT 1 FROM inbound_line l WHERE l.id = NEW.inbound_line_id AND l.putaway_qty_milli + NEW.qty_milli <= l.qc_passed_qty_milli) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_over_qty: 42214 OVER_QTY reason=OVER_PUTAWAY'); END;
-- @sqlite-only CREATE TRIGGER trg_inbp_apply AFTER INSERT ON inbound_putaway BEGIN UPDATE inbound_line SET putaway_qty_milli = putaway_qty_milli + NEW.qty_milli, version = version + 1 WHERE id = NEW.inbound_line_id; END;
-- @sqlite-only CREATE TRIGGER trg_inbl_put_qc BEFORE UPDATE ON inbound_line WHEN NEW.putaway_qty_milli > NEW.qc_passed_qty_milli BEGIN SELECT RAISE(ABORT, 'inbound_putaway_over_qc_passed'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_put_sum BEFORE UPDATE ON inbound_line WHEN NEW.putaway_qty_milli IS NOT OLD.putaway_qty_milli AND NEW.putaway_qty_milli <= NEW.qc_passed_qty_milli AND NEW.putaway_qty_milli <> (SELECT COALESCE(sum(p.qty_milli), 0) FROM inbound_putaway p WHERE p.inbound_line_id = NEW.id) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_counter_mismatch'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_put_ins BEFORE INSERT ON inbound_line WHEN NEW.putaway_qty_milli <> 0 BEGIN SELECT RAISE(ABORT, 'inbound_putaway_counter_mismatch'); END;
CREATE FUNCTION trg_inb_time_now() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF current_user IS NOT DISTINCT FROM (SELECT r.rolname FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid WHERE c.oid = 'public.inbound_order'::regclass) THEN RETURN NEW; END IF;   -- 属主豁免（种子 / 迁移）  -- @pg-only
    IF NEW.status IN ('COMPLETED','CANCELLED') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('COMPLETED','CANCELLED')) THEN  -- @pg-only
        NEW.closed_at := date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC');  -- @pg-only
    END IF;  -- @pg-only
    IF NEW.supplier_reconciled_at IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.supplier_reconciled_at IS NULL) THEN  -- @pg-only
        NEW.supplier_reconciled_at := date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC');  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inb_time_now BEFORE INSERT OR UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_inb_time_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inb_closed_tol_ins BEFORE INSERT ON inbound_order WHEN NEW.status IN ('COMPLETED','CANCELLED') AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_closed_tol_upd BEFORE UPDATE ON inbound_order WHEN NEW.status IN ('COMPLETED','CANCELLED') AND OLD.status NOT IN ('COMPLETED','CANCELLED') AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_recon_tol BEFORE UPDATE ON inbound_order WHEN OLD.supplier_reconciled_at IS NULL AND (NEW.supplier_reconciled_at IS NOT NULL AND (strftime('%s', NEW.supplier_reconciled_at) IS NULL OR substr(NEW.supplier_reconciled_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.supplier_reconciled_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID supplier_reconciled_at'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_recon_tol_ins BEFORE INSERT ON inbound_order WHEN (NEW.supplier_reconciled_at IS NOT NULL AND (strftime('%s', NEW.supplier_reconciled_at) IS NULL OR substr(NEW.supplier_reconciled_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.supplier_reconciled_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID supplier_reconciled_at'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_closed_tol BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.status = 'CLOSED' AND OLD.status <> 'CLOSED' AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_closed_tol_ins BEFORE INSERT ON inbound_quality_feedback WHEN NEW.status = 'CLOSED' AND (NEW.closed_at IS NOT NULL AND (strftime('%s', NEW.closed_at) IS NULL OR substr(NEW.closed_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.closed_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300)) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID closed_at'); END;
-- created_at（Doro 终版）：非属主一律改成库时钟 UTC 整秒；属主（种子 / 迁移）只截到整秒；建后任何人不可改  -- @pg-only
CREATE FUNCTION trg_inb_created_now() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF TG_OP = 'UPDATE' THEN  -- @pg-only
        IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN  -- @pg-only
            RAISE EXCEPTION '%_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at', TG_TABLE_NAME USING ERRCODE = '23514';  -- @pg-only
        END IF;  -- @pg-only
        RETURN NEW;  -- @pg-only
    END IF;  -- @pg-only
    IF NEW.created_at IS NULL THEN  -- @pg-only
        RAISE EXCEPTION '%_clock_skew: 40003 CLIENT_TIME_INVALID created_at NULL', TG_TABLE_NAME USING ERRCODE = '23514';  -- 显式传 NULL 拒绝（不传列走 DEFAULT 不受影响），同 #2 round11 movement_clock_skew  -- @pg-only
    END IF;  -- @pg-only
    IF current_user IS DISTINCT FROM (SELECT r.rolname FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid WHERE c.oid = TG_RELID) THEN  -- @pg-only
        NEW.created_at := date_trunc('second', now() AT TIME ZONE 'UTC');  -- @pg-only
    ELSE  -- @pg-only
        NEW.created_at := date_trunc('second', NEW.created_at);  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inb_created_now BEFORE INSERT OR UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inb_created_tol BEFORE INSERT ON inbound_order WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_created_lock BEFORE UPDATE ON inbound_order WHEN NEW.created_at IS NOT OLD.created_at BEGIN SELECT RAISE(ABORT, 'inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at'); END;
CREATE TRIGGER trg_itc_created_now BEFORE INSERT OR UPDATE ON inbound_temp_check FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_itc_created_tol BEFORE INSERT ON inbound_temp_check WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_temp_check_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_rcp_created_now BEFORE INSERT OR UPDATE ON inbound_receipt FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_rcp_created_tol BEFORE INSERT ON inbound_receipt WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_receipt_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_irc_created_now BEFORE INSERT OR UPDATE ON inbound_correction FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_irc_created_tol BEFORE INSERT ON inbound_correction WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_inbp_created_now BEFORE INSERT OR UPDATE ON inbound_putaway FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inbp_created_tol BEFORE INSERT ON inbound_putaway WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_putaway_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
CREATE TRIGGER trg_iqf_created_now BEFORE INSERT OR UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_inb_created_now();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_iqf_created_tol BEFORE INSERT ON inbound_quality_feedback WHEN (strftime('%s', NEW.created_at) IS NULL OR substr(NEW.created_at, 12, 2) > '23' OR abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) > 300) BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID created_at'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_created_lock BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.created_at IS NOT OLD.created_at BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at'); END;
-- 状态迁移表（同 09 trg_scr_forward）：只许前进；COMPLETED / CANCELLED 终态。质量反馈 OPEN → CLOSED，CLOSED 终态  -- @pg-only
CREATE FUNCTION trg_inb_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN  -- @pg-only
    IF TG_TABLE_NAME = 'inbound_order' THEN  -- @pg-only
        IF NEW.status <> OLD.status AND NOT ((OLD.status = 'CREATED' AND NEW.status IN ('ARRIVED','RECEIVING','CANCELLED'))  -- @pg-only
       OR (OLD.status = 'ARRIVED' AND NEW.status IN ('RECEIVING','CANCELLED'))  -- @pg-only
       OR (OLD.status = 'RECEIVING' AND NEW.status IN ('RECEIVED','PUTTING_AWAY','COMPLETED','CANCELLED'))  -- @pg-only
       OR (OLD.status = 'RECEIVED' AND NEW.status IN ('PUTTING_AWAY','COMPLETED'))  -- @pg-only
       OR (OLD.status = 'PUTTING_AWAY' AND NEW.status = 'COMPLETED')) THEN  -- @pg-only
            RAISE EXCEPTION 'inbound_order_state_forward_only: % -> %', OLD.status, NEW.status USING ERRCODE = '23514';  -- @pg-only
        END IF;  -- @pg-only
    ELSIF NEW.status <> OLD.status AND NOT (OLD.status = 'OPEN' AND NEW.status = 'CLOSED') THEN  -- @pg-only
        RAISE EXCEPTION 'inbound_quality_feedback_state_forward_only: % -> %', OLD.status, NEW.status USING ERRCODE = '23514';  -- @pg-only
    END IF;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_inb_forward BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_inb_forward();  -- @pg-only
CREATE TRIGGER trg_iqf_forward BEFORE UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_inb_forward();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inb_forward BEFORE UPDATE ON inbound_order WHEN NEW.status <> OLD.status AND NOT ((OLD.status = 'CREATED' AND NEW.status IN ('ARRIVED','RECEIVING','CANCELLED')) OR (OLD.status = 'ARRIVED' AND NEW.status IN ('RECEIVING','CANCELLED')) OR (OLD.status = 'RECEIVING' AND NEW.status IN ('RECEIVED','PUTTING_AWAY','COMPLETED','CANCELLED')) OR (OLD.status = 'RECEIVED' AND NEW.status IN ('PUTTING_AWAY','COMPLETED')) OR (OLD.status = 'PUTTING_AWAY' AND NEW.status = 'COMPLETED')) BEGIN SELECT RAISE(ABORT, 'inbound_order_state_forward_only'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_forward BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.status <> OLD.status AND NOT (OLD.status = 'OPEN' AND NEW.status = 'CLOSED') BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_state_forward_only'); END;
GRANT SELECT, INSERT, UPDATE ON inbound_order, inbound_quality_feedback TO wms_app;  -- @pg-only
-- B1：inbound_line 不给表级 UPDATE；计数列（received / rejected / qc_passed / qc_failed / putaway）只能走守卫路径
GRANT SELECT, INSERT ON inbound_line TO wms_app;  -- @pg-only
GRANT UPDATE (sku_id, uom, temp_zone, ordered_qty_milli, lot_id, production_date, expiry_date, cost_amount_fen, version) ON inbound_line TO wms_app;  -- @pg-only
GRANT SELECT, INSERT ON inbound_temp_check, inbound_receipt, inbound_correction, inbound_putaway TO wms_app;  -- @pg-only

-- X1/X2：no-replace 触发器（WHEN 覆盖本表全部 PK / UNIQUE，部分索引带谓词；由 genreplace 生成）
-- @sqlite-only CREATE TRIGGER trg_inb_no_replace BEFORE INSERT ON inbound_order WHEN EXISTS (SELECT 1 FROM inbound_order k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.closed_at = NEW.closed_at) OR (k.source_system = NEW.source_system AND k.source_order_no = NEW.source_order_no) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'inbound_order_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_inbl_no_replace BEFORE INSERT ON inbound_line WHEN EXISTS (SELECT 1 FROM inbound_line k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_id = NEW.inbound_id) OR (k.inbound_id = NEW.inbound_id AND k.line_no = NEW.line_no)) BEGIN SELECT RAISE(ABORT, 'inbound_line_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_itc_no_replace BEFORE INSERT ON inbound_temp_check WHEN EXISTS (SELECT 1 FROM inbound_temp_check k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_id = NEW.inbound_id AND k.disposition = NEW.disposition) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_temp_check'); END;
-- @sqlite-only CREATE TRIGGER trg_inb_rec_no_replace BEFORE INSERT ON inbound_receipt WHEN EXISTS (SELECT 1 FROM inbound_receipt k WHERE (k.id = NEW.id) OR (k.id = NEW.id AND k.inbound_line_id = NEW.inbound_line_id AND k.received_by = NEW.received_by) OR (k.hold_id = NEW.hold_id) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_receipt'); END;
-- @sqlite-only CREATE TRIGGER trg_irc_no_replace BEFORE INSERT ON inbound_correction WHEN EXISTS (SELECT 1 FROM inbound_correction k WHERE (k.id = NEW.id) OR (k.movement_id = NEW.movement_id) OR (k.op_key = NEW.op_key) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_correction'); END;
-- @sqlite-only CREATE TRIGGER trg_inbp_no_replace BEFORE INSERT ON inbound_putaway WHEN EXISTS (SELECT 1 FROM inbound_putaway k WHERE (k.id = NEW.id) OR (k.op_key = NEW.op_key)) BEGIN SELECT RAISE(ABORT, 'append_only_violation: inbound_putaway'); END;
-- @sqlite-only CREATE TRIGGER trg_iqf_no_replace BEFORE INSERT ON inbound_quality_feedback WHEN EXISTS (SELECT 1 FROM inbound_quality_feedback k WHERE (k.id = NEW.id) OR (k.code = NEW.code)) BEGIN SELECT RAISE(ABORT, 'iqf_immutable'); END;

-- 去重键不可改、计数器只增（由 genlock 生成；PG 触发器名 trg_0keylock_* 让它按字母序最先执行）
-- 去重键不可改 / 计数器只增（03 与 18 共用；TG_ARGV[0] 键列、[1] 可回填键列、[2] 计数器列，逗号分隔）。两库都不设属主豁免  -- @pg-only
CREATE FUNCTION trg_keylock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE o jsonb := pg_catalog.to_jsonb(OLD); n jsonb := pg_catalog.to_jsonb(NEW); c text;  -- @pg-only
BEGIN  -- @pg-only
    FOREACH c IN ARRAY pg_catalog.string_to_array(TG_ARGV[0], ',') LOOP  -- @pg-only
        IF (o -> c) IS DISTINCT FROM (n -> c) AND NOT (c = ANY (pg_catalog.string_to_array(TG_ARGV[1], ',')) AND (o -> c) = 'null'::jsonb) THEN  -- @pg-only
            RAISE EXCEPTION '%_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE %', TG_TABLE_NAME, c USING ERRCODE = '23514';  -- @pg-only
        END IF;  -- @pg-only
    END LOOP;  -- @pg-only
    FOREACH c IN ARRAY pg_catalog.string_to_array(TG_ARGV[2], ',') LOOP  -- @pg-only
        IF (n ->> c)::numeric < (o ->> c)::numeric THEN  -- @pg-only
            RAISE EXCEPTION '%_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC %', TG_TABLE_NAME, c USING ERRCODE = '23514';  -- @pg-only
        END IF;  -- @pg-only
    END LOOP;  -- @pg-only
    RETURN NEW;  -- @pg-only
END $$;  -- @pg-only
CREATE TRIGGER trg_0keylock_inbound_order BEFORE UPDATE ON inbound_order FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,closed_at,source_system,source_order_no,code', 'closed_at', 'version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inbound_order_keylock BEFORE UPDATE ON inbound_order WHEN NEW.id IS NOT OLD.id OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at) OR NEW.source_system IS NOT OLD.source_system OR NEW.source_order_no IS NOT OLD.source_order_no OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_inbound_order_monotonic BEFORE UPDATE ON inbound_order WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_order_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_0keylock_inbound_line BEFORE UPDATE ON inbound_line FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,inbound_id,line_no', '', 'received_qty_milli,rejected_qty_milli,qc_passed_qty_milli,qc_failed_qty_milli,putaway_qty_milli,version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inbound_line_keylock BEFORE UPDATE ON inbound_line WHEN NEW.id IS NOT OLD.id OR NEW.inbound_id IS NOT OLD.inbound_id OR NEW.line_no IS NOT OLD.line_no BEGIN SELECT RAISE(ABORT, 'inbound_line_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_inbound_line_monotonic BEFORE UPDATE ON inbound_line WHEN NEW.received_qty_milli < OLD.received_qty_milli OR NEW.rejected_qty_milli < OLD.rejected_qty_milli OR NEW.qc_passed_qty_milli < OLD.qc_passed_qty_milli OR NEW.qc_failed_qty_milli < OLD.qc_failed_qty_milli OR NEW.putaway_qty_milli < OLD.putaway_qty_milli OR NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
CREATE TRIGGER trg_0keylock_inbound_quality_feedback BEFORE UPDATE ON inbound_quality_feedback FOR EACH ROW EXECUTE FUNCTION trg_keylock('id,code', '', 'version');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_inbound_quality_feedback_keylock BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END;
-- @sqlite-only CREATE TRIGGER trg_inbound_quality_feedback_monotonic BEFORE UPDATE ON inbound_quality_feedback WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'inbound_quality_feedback_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END;
