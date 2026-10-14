CREATE TABLE outbound_order (
    id                      BIGINT          PRIMARY KEY,
    code                    VARCHAR(64)     NOT NULL,
    warehouse_id            BIGINT          NOT NULL,
    order_type              VARCHAR(24)     NOT NULL,
    source_system           VARCHAR(24)     NOT NULL,
    source_order_no         VARCHAR(64)     NOT NULL,
    customer_id             BIGINT          NOT NULL,
    route_code              VARCHAR(32),                 -- 波次聚合维度
    temperature_required    VARCHAR(16)     NOT NULL DEFAULT 'AMBIENT',
    required_delivery_date  TIMESTAMP,
    work_date               DATE            NOT NULL,
    cutoff_at               TIMESTAMP,
    priority                SMALLINT        NOT NULL DEFAULT 5,
    status                  VARCHAR(24)     NOT NULL,   -- 迁移表见 docs/04 §5.1
    source_hash             VARCHAR(64)     NOT NULL,   -- 上游单据规范化内容的 SHA-256 hex；同号不同 hash → 40910（04 I1）；无默认值（小赵 D6）
    wave_id                 BIGINT,
    short_ship_policy       VARCHAR(16)     NOT NULL DEFAULT 'ALLOW_SHORT',
    total_qty_milli         BIGINT          NOT NULL DEFAULT 0,   -- 以下汇总量均为基本单位 milli（00 R2），由 Service 维护
    allocated_qty_milli     BIGINT          NOT NULL DEFAULT 0,
    picked_qty_milli        BIGINT          NOT NULL DEFAULT 0,
    shipped_qty_milli       BIGINT          NOT NULL DEFAULT 0,
    short_qty_milli         BIGINT          NOT NULL DEFAULT 0,
    total_amount            BIGINT          NOT NULL DEFAULT 0,
    picker_id               BIGINT,
    checker_id              BIGINT,
    driver_id               BIGINT,
    consignee_name          VARCHAR(64),                 -- 以下均为下单时快照
    consignee_phone         VARCHAR(32),
    address_snapshot        VARCHAR(512),
    lat                     NUMERIC(10,7),
    lng                     NUMERIC(10,7),
    tags                    VARCHAR(128),
    remark                  VARCHAR(512),
    created_at              TIMESTAMP       NOT NULL DEFAULT now(),
    updated_at              TIMESTAMP       NOT NULL DEFAULT now(),
    status_changed_at       TIMESTAMP,
    reserve_expires_at      TIMESTAMP,                   -- 预占过期时刻（04 T6）
    version                 BIGINT          NOT NULL DEFAULT 0,   -- 状态条件更新时 +1
    shipped_at              TIMESTAMP,
    delivered_at            TIMESTAMP,
    created_by              BIGINT,
    CONSTRAINT uq_obo_code UNIQUE (code),
    CONSTRAINT uq_obo_src  UNIQUE (source_system, source_order_no),
    CONSTRAINT ck_obo_sod  CHECK (checker_id IS NULL OR picker_id IS NULL OR picker_id <> checker_id),
    -- 小写十六进制 64 位（小赵 N4）。两库通用写法：不用 PG 的 ~、也不用 SQLite 的 GLOB，嵌套 replace 去掉 0-9a-f 后必须为空串；
    -- 大写 A-F、非 hex、汉字都会剩下字符。生成器原样输出到 SQLite，两库约束文本一致
    CONSTRAINT ck_obo_hash CHECK (length(source_hash) = 64 AND lower(source_hash) = source_hash AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(source_hash,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = ''),
    CONSTRAINT ck_obo_qty CHECK (
        total_qty_milli >= 0 AND allocated_qty_milli >= 0 AND picked_qty_milli >= 0
        AND shipped_qty_milli >= 0 AND short_qty_milli >= 0
        AND total_qty_milli = CAST(total_qty_milli AS BIGINT) AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT)
        AND picked_qty_milli = CAST(picked_qty_milli AS BIGINT) AND shipped_qty_milli = CAST(shipped_qty_milli AS BIGINT)
        AND short_qty_milli = CAST(short_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_obo_status CHECK (status IN ('CREATED','PENDING_ALLOC','ALLOCATED','SHORT','WAVED','PICKING','PICKED',
                                               'CHECKED','STAGED','SHIPPED','DELIVERED','COMPLETED','CANCELLED'))
);
CREATE INDEX ix_obo_pool   ON outbound_order(warehouse_id, route_code, temperature_required, priority)
    WHERE status = 'ALLOCATED';                          -- 波次待处理池
CREATE INDEX ix_obo_wh     ON outbound_order(warehouse_id, status, work_date DESC);
CREATE INDEX ix_obo_wave   ON outbound_order(wave_id) WHERE wave_id IS NOT NULL;
CREATE INDEX ix_obo_cust   ON outbound_order(customer_id, created_at DESC);

CREATE TABLE outbound_line (
    id              BIGINT          PRIMARY KEY,
    outbound_id     BIGINT          NOT NULL,
    line_no         SMALLINT        NOT NULL,
    sku_id          BIGINT          NOT NULL,
    order_qty_milli     BIGINT      NOT NULL,             -- 基本单位 milli（00 R2）
    reserved_qty_milli  BIGINT      NOT NULL DEFAULT 0,
    allocated_qty_milli BIGINT      NOT NULL DEFAULT 0,
    picked_qty_milli    BIGINT      NOT NULL DEFAULT 0,   -- 累计拣出量（不因撤销/回冲减少）
    shipped_qty_milli   BIGINT      NOT NULL DEFAULT 0,
    short_qty_milli     BIGINT      NOT NULL DEFAULT 0,
    uom             VARCHAR(16)     NOT NULL,
    unit_price      BIGINT          NOT NULL DEFAULT 0,
    amount          BIGINT          NOT NULL DEFAULT 0,
    short_reason    VARCHAR(24),
    alloc_round     INT             NOT NULL DEFAULT 0,   -- 每次重新分配 +1，进入占用幂等键（04 B1）
    reversed_qty_milli  BIGINT      NOT NULL DEFAULT 0,   -- 已撤销/回冲累计量；条件更新 reversed + qty <= picked，否则 42214（04 §6.3）
    CONSTRAINT ck_obl_int CHECK (
        order_qty_milli = CAST(order_qty_milli AS BIGINT) AND reserved_qty_milli = CAST(reserved_qty_milli AS BIGINT)
        AND allocated_qty_milli = CAST(allocated_qty_milli AS BIGINT) AND picked_qty_milli = CAST(picked_qty_milli AS BIGINT)
        AND shipped_qty_milli = CAST(shipped_qty_milli AS BIGINT) AND short_qty_milli = CAST(short_qty_milli AS BIGINT)
        AND reversed_qty_milli = CAST(reversed_qty_milli AS BIGINT)
    ),
    CONSTRAINT ck_obl_nonneg CHECK (
        order_qty_milli > 0 AND reserved_qty_milli >= 0 AND allocated_qty_milli >= 0 AND picked_qty_milli >= 0
        AND shipped_qty_milli >= 0 AND short_qty_milli >= 0 AND reversed_qty_milli >= 0
    ),
    CONSTRAINT ck_obl_reversed CHECK (reversed_qty_milli <= picked_qty_milli),   -- 库层兜底：回冲不超过拣出（04 D4）
    CONSTRAINT ck_obl_sum CHECK (
        (picked_qty_milli - reversed_qty_milli) + short_qty_milli <= order_qty_milli
        AND reserved_qty_milli + allocated_qty_milli + (picked_qty_milli - reversed_qty_milli) <= order_qty_milli
        AND shipped_qty_milli <= picked_qty_milli - reversed_qty_milli
    ),
    CONSTRAINT uq_obo_line UNIQUE (outbound_id, line_no)
);
CREATE INDEX ix_obl_sku ON outbound_line(sku_id);
GRANT SELECT, INSERT, UPDATE ON outbound_order, outbound_line TO wms_app;  -- @pg-only
