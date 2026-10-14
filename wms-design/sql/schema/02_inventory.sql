-- -----------------------------------------------------------------------------
-- 库存（核心）
-- -----------------------------------------------------------------------------

-- 数量口径（docs/02-库存核心.md §4，PM 裁决）：库存四张表的数量一律 BIGINT，
-- 单位 = SKU base_uom 的 1/1000，列名统一 *_qty_milli 后缀。KG 计即"克"，PCS 计即 0.001 个。
-- ck_*_int：SQLite 的 BIGINT 是 INTEGER 亲和性，3.5 / '12.500' 会被静默存成 REAL，
--   用 x = CAST(x AS BIGINT) 拦截非整数写入；PG 侧列型已是 bigint，该 CHECK 恒真，无副作用。

CREATE TABLE stock (
    id                      BIGINT          PRIMARY KEY,
    warehouse_id            BIGINT          NOT NULL,
    location_id             BIGINT          NOT NULL,
    sku_id                  BIGINT          NOT NULL,
    lot_id                  BIGINT          NOT NULL,
    container_id            BIGINT          NOT NULL DEFAULT 0,   -- 0 = 散货无容器（哨兵值，见下）
    uom                     VARCHAR(16)     NOT NULL,             -- 恒为 sku.base_uom

    on_hand_qty_milli       BIGINT          NOT NULL DEFAULT 0,   -- 在库总量
    allocated_qty_milli     BIGINT          NOT NULL DEFAULT 0,   -- 已分配未拣（= ALLOCATE 占用汇总）
    reserved_qty_milli      BIGINT          NOT NULL DEFAULT 0,   -- 已预占（= RESERVE 占用汇总）
    quality_hold_qty_milli  BIGINT          NOT NULL DEFAULT 0,   -- 质检/盘点冻结（= QUALITY + RETURN_QC 冻结汇总）
    hold_qty_milli        BIGINT          NOT NULL DEFAULT 0,   -- 冻结（= MANUAL + RETURN_PENDING + SCRAP_PENDING + PROCESSING + LIVE_HOLD 冻结汇总），从 available 扣除，FEFO 分不到

    ledger_seq              BIGINT          NOT NULL DEFAULT 0,   -- 本行 on_hand 变更计数，与流水 stock_seq 一一对应（快照水位线）；期初/迁移行的第 1 条流水是 OPENING
    version                 BIGINT          NOT NULL DEFAULT 0,
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP       NOT NULL DEFAULT now(),

    CONSTRAINT uq_stock_dim UNIQUE (warehouse_id, location_id, sku_id, lot_id, container_id),
    -- ⚠ container_id 必须是 NOT NULL DEFAULT 0 而不是可空：
    --   唯一约束里含 NULL 列时，PG 与 SQLite 都把 NULL 视为互不相等，
    --   实测两引擎都允许同一 (wh,loc,sku,lot) 插入多行 NULL 容器行 → 不变量 I6 失效。
    --   用 0 作"无容器"哨兵值是唯一在两个引擎上都成立的写法（R1–R10 交集原则）。
    CONSTRAINT ck_stock_container CHECK (container_id >= 0),
    CONSTRAINT ck_stock_int CHECK (
        on_hand_qty_milli = CAST(on_hand_qty_milli AS BIGINT)
        AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT)
        AND reserved_qty_milli = CAST(reserved_qty_milli AS BIGINT)
        AND quality_hold_qty_milli = CAST(quality_hold_qty_milli AS BIGINT)
        AND hold_qty_milli = CAST(hold_qty_milli AS BIGINT)
    ),
    -- 数据库层兜底不变量 I1/I2：即使 Service 写错，也不会出现负数或超占
    CONSTRAINT ck_stock_nonneg CHECK (
        on_hand_qty_milli >= 0 AND allocated_qty_milli >= 0 AND reserved_qty_milli >= 0
        AND quality_hold_qty_milli >= 0 AND hold_qty_milli >= 0
        AND (allocated_qty_milli + reserved_qty_milli + quality_hold_qty_milli + hold_qty_milli) <= on_hand_qty_milli
    )
);
CREATE INDEX ix_stock_sku_avail ON stock(sku_id, warehouse_id, lot_id) WHERE on_hand_qty_milli > 0;
CREATE INDEX ix_stock_loc       ON stock(location_id, sku_id);
CREATE INDEX ix_stock_wh        ON stock(warehouse_id, sku_id);
-- [SQLite] CHECK 约束 SQLite 同样支持且强制执行 —— 这是双库交集内，务必保留
-- [SQLite] BIGINT 为 INTEGER 亲和性，比较为整数比较；ck_stock_int 拦截 REAL/TEXT 混入

CREATE TABLE stock_reservation (
    id                  BIGINT          PRIMARY KEY,
    stock_id            BIGINT          NOT NULL,
    stage               VARCHAR(16)     NOT NULL,   -- RESERVE（计入 reserved）/ ALLOCATE（计入 allocated）
    source_type         VARCHAR(24)     NOT NULL,   -- OUTBOUND_LINE/WAVE/COUNT/MANUAL
    source_id           BIGINT          NOT NULL,
    source_line_id      BIGINT          NOT NULL DEFAULT 0,   -- R11：0 哨兵
    op_key              VARCHAR(80)     NOT NULL,   -- RES:{doc_no}:{line_no}:{alloc_round}:{stock_id}；alloc_round 在出库行上，每次重新分配 +1
    reserve_qty_milli   BIGINT          NOT NULL,
    consumed_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'RESERVED',  -- RESERVED/CONSUMED/RELEASED，由余量决定
    expires_at          TIMESTAMP,                  -- 超时自动释放，防死锁
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_res_op  UNIQUE (op_key),
    CONSTRAINT ck_res_stage CHECK (stage IN ('RESERVE','ALLOCATE')),
    CONSTRAINT ck_res_int CHECK (
        reserve_qty_milli = CAST(reserve_qty_milli AS BIGINT)
        AND consumed_qty_milli = CAST(consumed_qty_milli AS BIGINT)
        AND released_qty_milli = CAST(released_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_res CHECK (
        reserve_qty_milli > 0 AND consumed_qty_milli >= 0 AND released_qty_milli >= 0
        AND consumed_qty_milli + released_qty_milli <= reserve_qty_milli
    ),
    -- 状态与余量绑定（超量由 ck_res 单独拦）：余量>0 ⇔ RESERVED；余量=0 时有消耗为 CONSUMED，否则 RELEASED。
    -- 这样过期任务按 status='RESERVED'（ix_res_exp）一定能找到所有还占着量的记录
    CONSTRAINT ck_res_status CHECK (
        (status = 'RESERVED' AND consumed_qty_milli + released_qty_milli < reserve_qty_milli)
        OR (status = 'CONSUMED' AND consumed_qty_milli + released_qty_milli >= reserve_qty_milli AND consumed_qty_milli > 0)
        OR (status = 'RELEASED' AND consumed_qty_milli + released_qty_milli >= reserve_qty_milli AND consumed_qty_milli = 0)
    )
);
CREATE INDEX ix_res_stock  ON stock_reservation(stock_id, stage, status);
CREATE INDEX ix_res_source ON stock_reservation(source_type, source_id, source_line_id);
CREATE INDEX ix_res_exp    ON stock_reservation(expires_at) WHERE status = 'RESERVED';

CREATE TABLE stock_hold (
    id                  BIGINT          PRIMARY KEY,
    stock_id            BIGINT          NOT NULL,
    hold_type           VARCHAR(16)     NOT NULL,   -- QUALITY、RETURN_QC → quality_hold；MANUAL、RETURN_PENDING、SCRAP_PENDING、PROCESSING、LIVE_HOLD → hold_qty
    reason_code         VARCHAR(24)     NOT NULL,   -- 见 ck_hold_reason；新增原因走迁移
    source_type         VARCHAR(24)     NOT NULL,   -- INBOUND_QC/QC/COUNT/RETURN/EXCEPTION/MANUAL/RETURN_RECORD/SCRAP/PROCESS_ORDER/LIVE_TANK_HOLD
    source_id           BIGINT          NOT NULL DEFAULT 0,
    op_key              VARCHAR(80)     NOT NULL,   -- RETURN_PENDING 固定 RRH:{return_record_id}；convert_hold 的 op_key 由调用方传入（全量常用 CVT:{原 hold_id}，部分用 CVT:{line_id}:{op_seq}）；PROCESSING 必须 PRCI:（大小写敏感）
    hold_qty_milli      BIGINT          NOT NULL,
    released_qty_milli  BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(16)     NOT NULL DEFAULT 'HELD',      -- HELD/RELEASED，由余量决定
    operator_id         BIGINT          NOT NULL,   -- 系统冻结填 0
    approval_type       VARCHAR(24),                -- 需要审批的转换才填：SCRAP_MISREPORT（SCRAP_PENDING → RETURN_QC 误报回转）
    approval_no         VARCHAR(64),                -- 审批单号
    is_reversal         BOOLEAN         NOT NULL DEFAULT false,  -- 误报回转明细（SCRAP_PENDING → RETURN_QC）显式标记，替代 op_key LIKE 'CVT:%' 识别（小赵 N1）
    from_hold_id        BIGINT,                 -- convert_hold 子明细指向被转出的父冻结；一条父冻结可多次部分转出。I3e 按此汇总，不再用 op_key = 'CVT:' || id
    version             BIGINT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_hold_op UNIQUE (op_key),
    CONSTRAINT ck_hold_type CHECK (hold_type IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')),
    -- 一套方案：hold_type 是大类（决定计入哪一列），reason_code 是细分原因，二者成对约束。
    -- PROCESSING / LIVE_HOLD 由本篇统一收进码表；#12/#13 不要再改这条 CHECK。
    CONSTRAINT ck_hold_reason CHECK (
        hold_type NOT IN ('QUALITY','RETURN_QC','MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')      -- 类型非法交给 ck_hold_type 报，避免两条约束同时报
        OR (hold_type = 'QUALITY'        AND reason_code IN ('QC_PENDING','COUNT_LOCK'))
        OR (hold_type = 'RETURN_QC'      AND reason_code = 'RETURN_QC')     -- 退货待检（A3：系统冻结，只能由质检 release_qc_hold 释放）
        OR (hold_type = 'MANUAL'      AND reason_code IN ('DAMAGE','EXCEPTION','OTHER'))
        OR (hold_type = 'RETURN_PENDING' AND reason_code = 'RETURN_PENDING')
        OR (hold_type = 'SCRAP_PENDING'  AND reason_code = 'SCRAP')        -- 报损待处置（convert_hold 自 RETURN_PENDING 转入，docs/02 §7.1.1）
        OR (hold_type = 'PROCESSING'     AND reason_code = 'PROCESSING')   -- 加工领料系统锁（第 17 篇 place_hold）
        OR (hold_type = 'LIVE_HOLD'      AND reason_code = 'LIVE_HOLD')    -- 活鲜暂存系统锁（第 18 篇 place_hold）
    ),
    -- RETURN_PENDING 是系统冻结：必须挂在一条待回库记录上、operator_id=0；人工解冻接口拒绝它（应用层），只能由 confirm/resolve 同事务释放
    CONSTRAINT ck_hold_return CHECK (
        hold_type <> 'RETURN_PENDING'
        OR (source_type = 'RETURN_RECORD' AND source_id > 0 AND operator_id = 0)
    ),
    -- SCRAP_PENDING 也是系统冻结：挂报损单 id（source_type=SCRAP，source_id=报损单 id，不是报损行 id）、operator_id=0；人工解冻拒绝（40933），只能由第 9 篇报损完成/撤销释放。不走 place_hold，继续用 hold(SCRAP_PENDING)
    -- RETURN_QC 系统冻结（A3）：挂质检单（source_type=QC，source_id=质检单 id）、operator_id=0；人工解冻拒绝（40933），只能由 release_qc_hold 释放
    CONSTRAINT ck_hold_retqc CHECK (
        hold_type <> 'RETURN_QC'
        OR (source_type = 'QC' AND source_id > 0 AND operator_id = 0)
    ),
    -- 误报回转（SCRAP_PENDING → RETURN_QC，convert_hold 生成 op_key=CVT:{原 hold_id}）必须带 SCRAP_MISREPORT 审批单号；其余明细不带审批
    CONSTRAINT ck_hold_approval CHECK (
        (NOT is_reversal AND approval_type IS NULL AND approval_no IS NULL)
        OR (is_reversal AND approval_type = 'SCRAP_MISREPORT' AND approval_no IS NOT NULL AND length(approval_no) > 0)
    ),
    -- 回转标记与类型/op_key 双向一致：只有 RETURN_QC 能是回转，RETURN_QC 的 CVT 明细必须标回转（防止不带审批伪造回转）
    -- LIKE 在 PG 区分大小写、在 SQLite 默认不区分；回转前缀用 GLOB（SQLite 区分大小写）对齐，避免 'cvt:' 在 SQLite 被当成回转
    CONSTRAINT ck_hold_reversal_key CHECK (is_reversal = (hold_type = 'RETURN_QC' AND op_key LIKE 'CVT:%')),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_hold_reversal_key CHECK (is_reversal = (hold_type = 'RETURN_QC' AND op_key GLOB 'CVT:*')),
    -- 审批单号格式 APR-{仓库编码}-{yyyyMMdd}-{6 位数字}；仓库编码字符集 [A-Z0-9]{2,16}（以第 1 篇 #8 为准）
    CONSTRAINT ck_hold_approval_no CHECK (approval_no IS NULL OR CASE  -- @pg-only
        WHEN approval_no !~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$' THEN false  -- @pg-only
        WHEN substr(substr(right(approval_no, 15), 1, 8), 1, 4) = '0000' THEN false  -- @pg-only
        -- 真实日历日（N1）：日 ≤ 当月天数（含闰年）；CASE 保证先过正则再做日期运算，不会因 2 月 30 日抛转换错误  -- @pg-only
        ELSE substr(substr(right(approval_no, 15), 1, 8), 7, 2)::int <= extract(day FROM make_date(substr(substr(right(approval_no, 15), 1, 8), 1, 4)::int, substr(substr(right(approval_no, 15), 1, 8), 5, 2)::int, 1) + interval '1 month' - interval '1 day')  -- @pg-only
    END),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_hold_approval_no CHECK (approval_no IS NULL OR (
-- @sqlite-only         length(approval_no) BETWEEN 22 AND 36 AND substr(approval_no, 1, 4) = 'APR-'
-- @sqlite-only         AND substr(approval_no, 5, length(approval_no) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only         AND substr(approval_no, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only         AND (substr(approval_no, -11, 2) GLOB '0[1-9]' OR substr(approval_no, -11, 2) GLOB '1[0-2]')
-- @sqlite-only         AND (substr(approval_no, -9, 2) GLOB '0[1-9]' OR substr(approval_no, -9, 2) GLOB '[12][0-9]' OR substr(approval_no, -9, 2) GLOB '3[01]')
-- @sqlite-only         -- 真实日历日（N1）：SQLite date() 会把 02-30 规范成 03-02，与原串不等即拒
-- @sqlite-only         AND substr(approval_no, -15, 4) <> '0000'
-- @sqlite-only         AND date(substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2)) = substr(approval_no, -15, 4) || '-' || substr(approval_no, -11, 2) || '-' || substr(approval_no, -9, 2))),
    CONSTRAINT ck_hold_scrap CHECK (
        hold_type <> 'SCRAP_PENDING'
        OR (source_type = 'SCRAP' AND source_id > 0 AND operator_id = 0)
    ),
    CONSTRAINT fk_hold_from FOREIGN KEY (from_hold_id) REFERENCES stock_hold(id),
    CONSTRAINT ck_hold_from CHECK (from_hold_id IS NULL OR from_hold_id <> id),
    -- PROCESSING：挂加工单、系统操作员、op_key 前缀 PRCI:（大小写敏感，同 CVT 的方言拆分）
    CONSTRAINT ck_hold_process CHECK (  -- @pg-only
        hold_type <> 'PROCESSING'  -- @pg-only
        OR (source_type = 'PROCESS_ORDER' AND source_id > 0 AND operator_id = 0 AND op_key LIKE 'PRCI:%')  -- @pg-only
    ),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_hold_process CHECK (
-- @sqlite-only         hold_type <> 'PROCESSING'
-- @sqlite-only         OR (source_type = 'PROCESS_ORDER' AND source_id > 0 AND operator_id = 0 AND op_key GLOB 'PRCI:*')
-- @sqlite-only     ),
    -- LIVE_HOLD：挂活鲜暂养冻结单。不强制 op_key 前缀（第 18 篇没有规定前缀，强制会拒掉合法插入）
    CONSTRAINT ck_hold_live CHECK (
        hold_type <> 'LIVE_HOLD'
        OR (source_type = 'LIVE_TANK_HOLD' AND source_id > 0 AND operator_id = 0)
    ),
    CONSTRAINT ck_hold_int CHECK (
        hold_qty_milli = CAST(hold_qty_milli AS BIGINT)
        AND released_qty_milli = CAST(released_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_hold CHECK (hold_qty_milli > 0 AND released_qty_milli >= 0 AND released_qty_milli <= hold_qty_milli),
    CONSTRAINT ck_hold_status CHECK (
        (status = 'HELD' AND released_qty_milli < hold_qty_milli)
        OR (status = 'RELEASED' AND released_qty_milli >= hold_qty_milli)   -- 超释放由 ck_hold 单独拦
    )
);
CREATE INDEX ix_hold_stock ON stock_hold(stock_id, hold_type, status);
CREATE UNIQUE INDEX uq_hold_return ON stock_hold(source_id) WHERE hold_type = 'RETURN_PENDING';
-- 非唯一：一条父冻结可以多次部分转出，多条子明细共享同一个 from_hold_id
CREATE INDEX ix_hold_from ON stock_hold(from_hold_id) WHERE from_hold_id IS NOT NULL;

-- 冻结部分释放的操作去重（A3，release_qc_hold / release_hold / release_live_hold）：一次释放一行，op_key 由调用方传入（质检如 QCR:{inbound_line_id}:{op_seq}；整池解锁如 LTH:{live_tank_hold_id}:{inspection_id}:{hold_id}），
-- 与 inbound_line.qc_passed 累加、stock_hold 释放、stock.quality_hold 扣减同一事务；重放撞 uq_hr_op → 整个事务回滚，不重复解冻。只追加。
-- 没有 qc_line 表。质检单 = inbound_order，质检行 = inbound_line（第 3/10 篇）。本表 source 不存行 id。
CREATE TABLE stock_hold_release (
    id                  BIGINT          PRIMARY KEY,
    hold_id             BIGINT          NOT NULL,
    op_key              VARCHAR(80)     NOT NULL,
    qty_milli           BIGINT          NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT uq_hr_op UNIQUE (op_key),
    CONSTRAINT fk_hr_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),   -- 小赵 S6：释放记录必须挂在真实冻结上
    CONSTRAINT ck_hr_qty CHECK (qty_milli > 0 AND qty_milli = CAST(qty_milli AS BIGINT))
);
CREATE INDEX ix_hr_hold ON stock_hold_release(hold_id);
-- @sqlite-only CREATE TRIGGER trg_hr_no_update BEFORE UPDATE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_hr_no_delete BEFORE DELETE ON stock_hold_release BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- 小赵 Q1：REPLACE 冲突删旧行不触发 DELETE 触发器，同 trg_hold_no_replace 用 BEFORE INSERT 先拦（重放撞这里，按 op_key 查回）
-- @sqlite-only CREATE TRIGGER trg_hr_no_replace BEFORE INSERT ON stock_hold_release
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM stock_hold_release r WHERE r.id = NEW.id OR r.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;
-- ↑ 一条待回库记录最多一条 RETURN_PENDING 冻结（重复拒收复用已有记录，不会重复冻结）。
--   只约束 RETURN_PENDING：convert_hold 转出的报损明细（SCRAP_PENDING/SCRAP）不受它约束（小赵 D1）
-- 原文档 §4.2"冻结记 stock_freeze"在此落地为 stock_hold，使 quality_hold/frozen 与 allocated/reserved 一样可对账（I3）

-- 记账去重表：不分区，承载所有流水业务唯一键。每条流水在同一事务里写一行，撞任一唯一键 → 整个事务回滚。
CREATE TABLE stock_movement_key (
    movement_id         BIGINT          PRIMARY KEY,    -- = stock_movement.id（雪花 ID 跨分区也唯一）
    idempotency_key     VARCHAR(160)    NOT NULL,       -- 唯一格式 {biz_no}:{line_no}:{op_ref}:{leg}，op_ref = D{op_no} | P{device_instance_id}.{op_seq}
    biz_no              VARCHAR(64)     NOT NULL,
    line_no             INT             NOT NULL,
    op_no               INT             NOT NULL,
    leg                 SMALLINT        NOT NULL,
    src_kind            VARCHAR(8)      NOT NULL,
    src_task_id         BIGINT,
    src_line_no         INT,
    device_instance_id  VARCHAR(64),
    src_op_seq          INT,
    stock_id            BIGINT          NOT NULL,
    stock_seq           BIGINT          NOT NULL,
    direction           SMALLINT        NOT NULL,
    occurred_at         TIMESTAMP       NOT NULL,       -- 冗余，便于按 key 找到所在分区
    CONSTRAINT uq_mvk_idem UNIQUE (idempotency_key),
    CONSTRAINT ck_mvk_kind CHECK (
        (src_kind = 'DOC' AND src_task_id IS NULL AND src_line_no IS NULL AND device_instance_id IS NULL AND src_op_seq IS NULL AND op_no >= 1)
        OR (src_kind = 'PDA' AND src_task_id IS NOT NULL AND src_line_no IS NOT NULL AND device_instance_id IS NOT NULL AND src_op_seq IS NOT NULL AND op_no = 0)
    ),
    -- 流水外键 fk_mv_key 的被引用键：流水的 id 与全部非空业务列必须和 key 行逐列一致（小赵 C2）
    CONSTRAINT uq_mvk_mv UNIQUE (movement_id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
);
-- 流水主表：只追加。PG 侧按月 RANGE 分区（分区表的唯一约束必须含分区键，只能保证分区内唯一），
-- 所以所有业务唯一键都放到不分区的 stock_movement_key，同一事务写入（见 docs/02 §4.4）。
CREATE TABLE stock_movement (
    id                          BIGINT          NOT NULL,
    biz_no                      VARCHAR(64)     NOT NULL,
    line_no                     INT             NOT NULL,   -- 业务单据行号；无行的单据填 1
    op_no                       INT             NOT NULL DEFAULT 1,  -- 非 PDA：调用方在该行上的第几次操作（如分批收货）；PDA 恒 0
    leg                         SMALLINT        NOT NULL DEFAULT 1,  -- 同一操作的第几条腿：拣货/收货恒 1；移库/上架 1=出 2=入
    src_kind                    VARCHAR(8)      NOT NULL,   -- DOC / PDA
    biz_type                    VARCHAR(24)     NOT NULL,   -- RECEIVE/PUTAWAY/PICK/REVERSE_PICK/SHIP/MOVE/ADJUST/COUNT/RETURN/SCRAP/CROSS_DOCK/OPENING/PROCESS_ISSUE/PROCESS_CONSUME/PROCESS_OUTPUT/PROCESS_REVERSE（无 CHECK，第 17 篇登记）
    direction                   SMALLINT        NOT NULL,   -- 1 入 / -1 出 / 0 纯事件（如 SHIP，不改 on_hand）
    stock_id                    BIGINT          NOT NULL,   -- 记账到哪一行库存，按行回放的依据
    hold_id                     BIGINT,                     -- 冻结类流水指向单条 stock_hold；非冻结流水 NULL。I3f/I3g 按此对账，不按 stock 汇总
    stock_seq                   BIGINT          NOT NULL,   -- = 该次条件 UPDATE 后的 stock.ledger_seq；direction=0 时填当前 ledger_seq（不入链）
    warehouse_id                BIGINT          NOT NULL,
    location_id                 BIGINT          NOT NULL,
    from_location_id            BIGINT,
    sku_id                      BIGINT          NOT NULL,
    lot_id                      BIGINT          NOT NULL,
    container_id                BIGINT          NOT NULL DEFAULT 0,
    -- PDA 作业来源 = 00 总体设计 §6.5 四元组 (task_id, line_no, device_instance_id, op_seq)；DOC 行四列全 NULL
    src_task_id                 BIGINT,
    src_line_no                 INT,
    device_instance_id          VARCHAR(64),
    src_op_seq                  INT,
    move_qty_milli              BIGINT          NOT NULL,
    on_hand_before_qty_milli    BIGINT          NOT NULL,
    on_hand_after_qty_milli     BIGINT          NOT NULL,
    operator_id                 BIGINT,
    device                      VARCHAR(32),
    occurred_at                 TIMESTAMP       NOT NULL,
    recorded_at                 TIMESTAMP       NOT NULL DEFAULT now(),
    cost_amount                 BIGINT,                     -- 分
    idempotency_key             VARCHAR(160)    NOT NULL,   -- 唯一格式见 stock_movement_key
    remark                      VARCHAR(256),
    PRIMARY KEY (id, occurred_at),
    CONSTRAINT ck_mv_dir     CHECK (direction IN (-1, 0, 1)),
    CONSTRAINT ck_mv_kind    CHECK (
        (src_kind = 'DOC' AND src_task_id IS NULL AND src_line_no IS NULL AND device_instance_id IS NULL AND src_op_seq IS NULL AND op_no >= 1)
        OR (src_kind = 'PDA' AND src_task_id IS NOT NULL AND src_line_no IS NOT NULL AND device_instance_id IS NOT NULL AND src_op_seq IS NOT NULL AND op_no = 0)
    ),
    CONSTRAINT ck_mv_int     CHECK (
        move_qty_milli = CAST(move_qty_milli AS BIGINT)
        AND on_hand_before_qty_milli = CAST(on_hand_before_qty_milli AS BIGINT)
        AND on_hand_after_qty_milli = CAST(on_hand_after_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_mv_pos     CHECK (move_qty_milli > 0 AND on_hand_after_qty_milli >= 0),
    CONSTRAINT ck_mv_balance CHECK (on_hand_after_qty_milli = on_hand_before_qty_milli + move_qty_milli * direction),
    CONSTRAINT ck_mv_opening CHECK (biz_type <> 'OPENING' OR (direction = 1 AND stock_seq = 1 AND on_hand_before_qty_milli = 0)),
    CONSTRAINT fk_mv_hold FOREIGN KEY (hold_id) REFERENCES stock_hold(id),
    -- 库层绑定（小赵 C2）：没有对应 key 行、或 key 行内容对不上，流水写不进去。
    -- 只列 NOT NULL 列：MATCH SIMPLE 下任一列为 NULL 会跳过整条外键检查；PDA 四元组由 ck_mv_kind / ck_mvk_kind + uq_mvk_pda_op 管。
    -- DEFERRABLE INITIALLY DEFERRED：提交时检查，同一事务内流水与 key 的写入顺序不限。
    -- PG 11+ 支持分区表引用普通表的外键，所以这里不用触发器；SQLite 需每个连接 PRAGMA foreign_keys = ON（docs/02 §4.8）。
    CONSTRAINT fk_mv_key FOREIGN KEY (id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
        REFERENCES stock_movement_key (movement_id, idempotency_key, biz_no, line_no, op_no, leg, src_kind, stock_id, stock_seq, direction, occurred_at)
        DEFERRABLE INITIALLY DEFERRED
)
PARTITION BY RANGE (occurred_at);   -- @pg-only
-- @sqlite-only ;
CREATE TABLE stock_movement_p202610 PARTITION OF stock_movement FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');   -- @pg-only
CREATE TABLE stock_movement_p202611 PARTITION OF stock_movement FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');   -- @pg-only
CREATE TABLE stock_movement_pdefault PARTITION OF stock_movement DEFAULT;   -- @pg-only
CREATE INDEX ix_mv_biz      ON stock_movement(biz_type, biz_no);
CREATE INDEX ix_mv_stock    ON stock_movement(stock_id, stock_seq);
CREATE INDEX ix_mv_hold     ON stock_movement(hold_id) WHERE hold_id IS NOT NULL;
CREATE INDEX ix_mv_time     ON stock_movement(warehouse_id, occurred_at DESC);
CREATE INDEX ix_mv_sku_time ON stock_movement(sku_id, occurred_at DESC);
-- 数据量大：PG 侧按月 RANGE 分区（分区由运维任务提前一个月建好，DEFAULT 分区兜底）；SQLite 侧按月归档导出。

CREATE UNIQUE INDEX uq_mvk_biz_line  ON stock_movement_key(biz_no, line_no, op_no, leg) WHERE src_kind = 'DOC';
CREATE UNIQUE INDEX uq_mvk_pda_op    ON stock_movement_key(src_task_id, src_line_no, device_instance_id, src_op_seq, leg) WHERE src_kind = 'PDA';
CREATE UNIQUE INDEX uq_mvk_stock_seq ON stock_movement_key(stock_id, stock_seq) WHERE direction <> 0;
-- ↑ 每行库存的记账链无分叉；direction=0 的事件流水不入链

-- 单据行的记账来源归属：一行单据只能由 DOC 或 PDA 其中一种来源记账，二者互斥（docs/02 §8.4）
CREATE TABLE stock_ledger_line (
    biz_no          VARCHAR(64)     NOT NULL,
    line_no         INT             NOT NULL,
    src_kind        VARCHAR(8)      NOT NULL,
    owner_device_instance_id VARCHAR(64),           -- PDA 行：当前唯一允许记账的设备实例；改派/重新领取时由第 5 篇条件更新换主
    post_count      INT             NOT NULL DEFAULT 0,
    created_at      TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP       NOT NULL DEFAULT now(),
    PRIMARY KEY (biz_no, line_no),
    CONSTRAINT ck_sll_kind CHECK (
        (src_kind = 'DOC' AND owner_device_instance_id IS NULL)
        OR (src_kind = 'PDA' AND owner_device_instance_id IS NOT NULL)
    )
);

-- 去重表与归属表绑定：写入 key 时，该单据行的归属必须已存在、来源一致，PDA 行还必须是当前持有设备（两库各一份触发器，语义相同）
CREATE FUNCTION trg_mvk_line_kind() RETURNS trigger LANGUAGE plpgsql AS $$                                 -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM stock_ledger_line l                                                         -- @pg-only
                    WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind  -- @pg-only
                      AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id)) THEN  -- @pg-only
        RAISE EXCEPTION 'ledger_line_owner_mismatch' USING ERRCODE = '23514';                                -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key FOR EACH ROW EXECUTE FUNCTION trg_mvk_line_kind();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mvk_line_kind BEFORE INSERT ON stock_movement_key
-- @sqlite-only WHEN NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = NEW.biz_no AND l.line_no = NEW.line_no AND l.src_kind = NEW.src_kind
-- @sqlite-only                  AND (NEW.src_kind = 'DOC' OR l.owner_device_instance_id = NEW.device_instance_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ledger_line_owner_mismatch'); END;

-- 归属行的来源不可改（小赵 C3）：src_kind / biz_no / line_no 写入后禁止 UPDATE，否则把 PDA 行改成 DOC 就能绕过互斥
CREATE FUNCTION trg_sll_immutable() RETURNS trigger LANGUAGE plpgsql AS $$                                 -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.src_kind IS DISTINCT FROM OLD.src_kind OR NEW.biz_no IS DISTINCT FROM OLD.biz_no                   -- @pg-only
       OR NEW.line_no IS DISTINCT FROM OLD.line_no THEN                                                       -- @pg-only
        RAISE EXCEPTION 'ledger_line_immutable' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line FOR EACH ROW EXECUTE FUNCTION trg_sll_immutable();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sll_immutable BEFORE UPDATE ON stock_ledger_line
-- @sqlite-only WHEN NEW.src_kind IS NOT OLD.src_kind OR NEW.biz_no IS NOT OLD.biz_no OR NEW.line_no IS NOT OLD.line_no
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'ledger_line_immutable'); END;

-- 冻结明细写入后不可改（小赵 N1）：只放行释放路径要写的 released_qty_milli / status / version / updated_at。
-- 类型转换只走 convert_hold（关旧建新），任何路径都不需要改 hold_type；否则先把 SCRAP_PENDING 改成 MANUAL 就能绕过 40933。
-- convert_hold 加锁顺序（docs/02 §7.1.1、§8.2；PG 与 SQLite 同一条）：
--   先锁 stock 行（SELECT … WHERE id = :stock_id ORDER BY id），再锁 stock_hold（ORDER BY id），
--   然后才改 released/status、插入子明细；跨列时最后改 stock 数量。
--   同列转换不改 stock 数量和 version，也要先锁 stock，避免和 release/consume 交叉等锁。
--   PG 在这两条 SELECT 上加 FOR UPDATE；SQLite 没有行锁，语句顺序相同，写事务用 BEGIN IMMEDIATE。
CREATE FUNCTION trg_hold_immutable() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.stock_id IS DISTINCT FROM OLD.stock_id                           -- @pg-only
       OR NEW.hold_type IS DISTINCT FROM OLD.hold_type OR NEW.reason_code IS DISTINCT FROM OLD.reason_code    -- @pg-only
       OR NEW.source_type IS DISTINCT FROM OLD.source_type OR NEW.source_id IS DISTINCT FROM OLD.source_id    -- @pg-only
       OR NEW.op_key IS DISTINCT FROM OLD.op_key OR NEW.hold_qty_milli IS DISTINCT FROM OLD.hold_qty_milli   -- @pg-only
       OR NEW.operator_id IS DISTINCT FROM OLD.operator_id OR NEW.created_at IS DISTINCT FROM OLD.created_at  -- @pg-only
       OR NEW.approval_type IS DISTINCT FROM OLD.approval_type OR NEW.approval_no IS DISTINCT FROM OLD.approval_no  -- @pg-only
       OR NEW.is_reversal IS DISTINCT FROM OLD.is_reversal  -- @pg-only
       OR NEW.from_hold_id IS DISTINCT FROM OLD.from_hold_id  -- @pg-only
       OR NEW.released_qty_milli < OLD.released_qty_milli  -- R1 释放量只增不减 -- @pg-only
       OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED') THEN  -- R1 RELEASED 不能回 HELD -- @pg-only
        RAISE EXCEPTION 'hold_immutable' USING ERRCODE = '23514';                                            -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold FOR EACH ROW EXECUTE FUNCTION trg_hold_immutable();  -- @pg-only
-- R2：冻结明细不可删除（wms_app 本就没有 DELETE/TRUNCATE 权限；这里兜底超级用户/迁移脚本，与流水表写法一致）
CREATE FUNCTION trg_hold_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'hold_immutable' USING ERRCODE = '23514';                                                -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_hold_no_delete   BEFORE DELETE   ON stock_hold FOR EACH ROW       EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
CREATE TRIGGER trg_hold_no_truncate BEFORE TRUNCATE ON stock_hold FOR EACH STATEMENT EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
-- stock_hold_release 只追加（A3）；TRUNCATE 也拦（小赵 S5）
CREATE TRIGGER trg_hr_no_truncate BEFORE TRUNCATE ON stock_hold_release FOR EACH STATEMENT EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
CREATE TRIGGER trg_hr_append_only BEFORE UPDATE OR DELETE ON stock_hold_release FOR EACH ROW EXECUTE FUNCTION trg_hold_no_delete();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_hold_immutable BEFORE UPDATE ON stock_hold
-- @sqlite-only WHEN NEW.id IS NOT OLD.id OR NEW.stock_id IS NOT OLD.stock_id OR NEW.hold_type IS NOT OLD.hold_type OR NEW.reason_code IS NOT OLD.reason_code
-- @sqlite-only   OR NEW.source_type IS NOT OLD.source_type OR NEW.source_id IS NOT OLD.source_id OR NEW.op_key IS NOT OLD.op_key
-- @sqlite-only   OR NEW.hold_qty_milli IS NOT OLD.hold_qty_milli OR NEW.operator_id IS NOT OLD.operator_id OR NEW.created_at IS NOT OLD.created_at
-- @sqlite-only   OR NEW.approval_type IS NOT OLD.approval_type OR NEW.approval_no IS NOT OLD.approval_no OR NEW.is_reversal IS NOT OLD.is_reversal
-- @sqlite-only   OR NEW.from_hold_id IS NOT OLD.from_hold_id
-- @sqlite-only   OR NEW.released_qty_milli < OLD.released_qty_milli OR (OLD.status = 'RELEASED' AND NEW.status <> 'RELEASED')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- R2（SQLite）：拒删除；REPLACE 冲突时删旧行在 recursive_triggers=OFF（默认，且是连接级开关）下不触发 DELETE 触发器，
-- 所以另用 BEFORE INSERT 在 id / op_key 已存在时直接 ABORT，REPLACE 走不到删除那一步（库级生效，不依赖连接设置）
-- @sqlite-only CREATE TRIGGER trg_hold_no_delete BEFORE DELETE ON stock_hold BEGIN SELECT RAISE(ABORT, 'hold_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_hold_no_replace BEFORE INSERT ON stock_hold
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM stock_hold h WHERE h.id = NEW.id OR h.op_key = NEW.op_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'hold_duplicate'); END;

-- 只追加：流水表与去重表禁止 UPDATE / DELETE。PG 侧收回应用角色权限 + 触发器（防超级用户/运维脚本误操作）；SQLite 侧触发器
CREATE FUNCTION trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                       -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_mv_append_only  BEFORE UPDATE OR DELETE ON stock_movement     FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_mvk_append_only BEFORE UPDATE OR DELETE ON stock_movement_key FOR EACH ROW EXECUTE FUNCTION trg_append_only();  -- @pg-only
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_app') THEN CREATE ROLE wms_app NOLOGIN; END IF; END $$;  -- @pg-only
GRANT SELECT, INSERT ON stock_movement, stock_movement_key TO wms_app;                                       -- @pg-only
REVOKE UPDATE, DELETE, TRUNCATE ON stock_movement, stock_movement_key FROM wms_app;                          -- @pg-only
-- TRUNCATE 不触发行级触发器，单独加语句级触发器拦（小赵 C5）；归档走 DETACH PARTITION，不用 TRUNCATE
CREATE TRIGGER trg_mv_no_truncate  BEFORE TRUNCATE ON stock_movement     FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
CREATE TRIGGER trg_mvk_no_truncate BEFORE TRUNCATE ON stock_movement_key FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
-- 应用角色授权清单（小赵 C3，docs/02 §4.9）：库存类表只给 SELECT/INSERT/UPDATE，不给 DELETE/TRUNCATE；
-- stock_ledger_line 只能改换主相关列（第 5 篇改派/重新领取），来源与单据行由 trg_sll_immutable 再拦一道（防超级用户/迁移脚本）
GRANT USAGE ON SCHEMA public TO wms_app;                                                                      -- @pg-only
GRANT SELECT, INSERT, UPDATE ON stock, stock_reservation TO wms_app;                                         -- @pg-only
-- stock_hold 只授释放相关列（小赵 N1）；其余列由 trg_hold_immutable 再拦一道（防超级用户/迁移脚本）
GRANT SELECT, INSERT ON stock_hold, stock_hold_release TO wms_app;                                                                -- @pg-only
GRANT UPDATE (released_qty_milli, status, version, updated_at) ON stock_hold TO wms_app;                     -- @pg-only
GRANT SELECT, INSERT ON stock_ledger_line TO wms_app;                                                         -- @pg-only
GRANT UPDATE (owner_device_instance_id, post_count, updated_at) ON stock_ledger_line TO wms_app;             -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_mv_no_update  BEFORE UPDATE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- @sqlite-only CREATE TRIGGER trg_mv_no_delete  BEFORE DELETE ON stock_movement     BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement'); END;
-- @sqlite-only CREATE TRIGGER trg_mvk_no_update BEFORE UPDATE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
-- @sqlite-only CREATE TRIGGER trg_mvk_no_delete BEFORE DELETE ON stock_movement_key BEGIN SELECT RAISE(ABORT, 'append_only_violation: stock_movement_key'); END;
-- 归档：PG 侧按分区 DETACH（DDL，不触发行级触发器，需 DBA 权限）；SQLite 侧导出后由维护脚本 DROP 触发器→删除→重建，全程审计

CREATE TABLE stock_snapshot_daily (
    work_date               DATE            NOT NULL,
    stock_id                BIGINT          NOT NULL,
    warehouse_id            BIGINT          NOT NULL,
    location_id             BIGINT          NOT NULL,
    sku_id                  BIGINT          NOT NULL,
    lot_id                  BIGINT          NOT NULL,
    container_id            BIGINT          NOT NULL DEFAULT 0,
    on_hand_qty_milli       BIGINT          NOT NULL,
    allocated_qty_milli     BIGINT          NOT NULL,
    reserved_qty_milli      BIGINT          NOT NULL,
    quality_hold_qty_milli  BIGINT          NOT NULL,
    hold_qty_milli        BIGINT          NOT NULL,
    ledger_seq              BIGINT          NOT NULL,   -- 快照水位线：回放该行 stock_seq <= ledger_seq 的流水应等于 on_hand
    cost_amount             BIGINT          NOT NULL DEFAULT 0,
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    PRIMARY KEY (work_date, stock_id)
);
CREATE INDEX ix_snap_sku ON stock_snapshot_daily(work_date, warehouse_id, sku_id, lot_id);

CREATE TABLE stock_recon_alert (
    id                      BIGINT          PRIMARY KEY,
    check_code              VARCHAR(24)     NOT NULL,   -- 码表见 ck_recon_code；CHECK_BOX_MISMATCH 18 位，16 放不下
    warehouse_id            BIGINT          NOT NULL,
    stock_id                BIGINT          NOT NULL DEFAULT 0,   -- 0 = 仓级汇总差异（R11）
    expected_qty_milli      BIGINT          NOT NULL,
    actual_qty_milli        BIGINT          NOT NULL,
    watermark_ledger_seq    BIGINT          NOT NULL DEFAULT 0,
    hit_count               INT             NOT NULL DEFAULT 1,   -- 同一差异重复检出只累加，不新建
    status                  VARCHAR(16)     NOT NULL DEFAULT 'OPEN',   -- OPEN/ACKED/RESOLVED
    resolved_by             BIGINT,
    resolution              VARCHAR(256),
    detected_at             TIMESTAMP       NOT NULL DEFAULT now(),
    last_seen_at            TIMESTAMP       NOT NULL DEFAULT now(),
    CONSTRAINT ck_recon_status CHECK (status IN ('OPEN','ACKED','RESOLVED')),
    CONSTRAINT ck_recon_code CHECK (check_code IN ('I3a','I3b','I3c','I3d','I3e','I4','I5','SNAP','RR_HOLD_FAILED','RR_HOLD_MISMATCH','CHECK_BOX_MISMATCH','SHIP_EVENT_MISSING','LIVE_COUNT_WEIGHT','LIVE_COUNT_LEDGER','LIVE_HOLD_MISMATCH','LIVE_INSPECT_OVERDUE'))   -- 码表见 docs/02 §4.6；活鲜四码见第 18 篇 §9 / Q6
);
CREATE INDEX ix_recon_open ON stock_recon_alert(warehouse_id, status, detected_at DESC);
CREATE UNIQUE INDEX uq_recon_open ON stock_recon_alert(check_code, warehouse_id, stock_id) WHERE status <> 'RESOLVED';
GRANT SELECT, INSERT, UPDATE ON stock_recon_alert TO wms_app;   -- @pg-only
-- ↑ 未闭环的同一差异只有一条；对账任务用 INSERT … ON CONFLICT DO UPDATE SET hit_count = hit_count + 1, last_seen_at = …
--   （PG 与 SQLite ≥ 3.24 写法相同；部分唯一索引作冲突目标时两库都要求带同样的 WHERE）

-- 对账只告警不修数：本表只记录差异，任何修正必须走调整单（adjust_order）+ 审批生成新流水
GRANT SELECT, INSERT ON stock_snapshot_daily TO wms_app;  -- 只追加 -- @pg-only
