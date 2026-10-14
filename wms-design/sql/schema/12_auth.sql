CREATE TABLE sys_user (
    id              BIGINT       PRIMARY KEY,
    username        VARCHAR(64)  NOT NULL,
    password_hash   VARCHAR(256) NOT NULL,
    real_name       VARCHAR(64),
    phone           VARCHAR(32),
    mp_openid       VARCHAR(64),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    last_login_at   TIMESTAMP,
    perm_version    BIGINT       NOT NULL DEFAULT 1,   -- docs/12 §3.1：角色/权限/仓分配任何变化 +1，只升不降
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMP,
    CONSTRAINT uq_user_name UNIQUE (username),
    CONSTRAINT ck_user_perm_ver CHECK (perm_version > 0)
);
CREATE INDEX ix_user_openid ON sys_user(mp_openid) WHERE mp_openid IS NOT NULL;

CREATE TABLE sys_role (
    id           BIGINT       PRIMARY KEY,
    code         VARCHAR(64)  NOT NULL,
    name         VARCHAR(64)  NOT NULL,
    data_scope   VARCHAR(16)  NOT NULL DEFAULT 'WAREHOUSE',  -- ALL/WAREHOUSE/ZONE/SELF
    is_builtin   BOOLEAN      NOT NULL DEFAULT false,
    remark       VARCHAR(256),
    CONSTRAINT uq_role_code UNIQUE (code)
);

CREATE TABLE sys_permission (
    id           BIGINT       PRIMARY KEY,
    code         VARCHAR(96)  NOT NULL,   -- module.resource.action
    name         VARCHAR(64)  NOT NULL,
    module       VARCHAR(32)  NOT NULL,
    type         VARCHAR(16)  NOT NULL DEFAULT 'API',        -- API/BUTTON/MENU
    CONSTRAINT uq_perm_code UNIQUE (code)
);

CREATE TABLE sys_user_role     (user_id BIGINT NOT NULL, role_id BIGINT NOT NULL, PRIMARY KEY(user_id, role_id));
CREATE TABLE sys_role_perm     (role_id BIGINT NOT NULL, perm_id BIGINT NOT NULL, PRIMARY KEY(role_id, perm_id));
CREATE TABLE sys_user_warehouse(user_id BIGINT NOT NULL, warehouse_id BIGINT NOT NULL, PRIMARY KEY(user_id, warehouse_id));

CREATE TABLE api_credential (
    id               BIGINT       PRIMARY KEY,
    api_key          VARCHAR(64)  NOT NULL,
    secret_encrypted VARCHAR(256) NOT NULL,
    source_system    VARCHAR(24)  NOT NULL,
    status           VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    ip_whitelist     VARCHAR(256),
    last_used_at     TIMESTAMP,
    CONSTRAINT uq_api_key UNIQUE (api_key)
);

-- -----------------------------------------------------------------------------
-- docs/12 权限与审计：设备绑定、离线令牌、主管审批
-- -----------------------------------------------------------------------------

-- 设备实例绑定：device_instance_id（App 安装实例）↔ 账号 + 仓。一个实例同时最多一条 PENDING/ACTIVE 绑定
CREATE TABLE user_device_binding (
    id                  BIGINT       PRIMARY KEY,
    device_instance_id  VARCHAR(64)  NOT NULL,
    device_id           BIGINT,                      -- 第 1 篇 device 台账；司机自有手机可为空
    client_type         VARCHAR(16)  NOT NULL,       -- PDA / DRIVER_APP
    user_id             BIGINT       NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',   -- PENDING（待主管确认）/ ACTIVE / REVOKED（终态）
    approval_id         BIGINT,                      -- DEVICE_BIND 审批单
    bound_at            TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC
    activated_at        TIMESTAMP,
    revoked_at          TIMESTAMP,
    revoked_by          BIGINT,
    revoke_reason       VARCHAR(64),
    CONSTRAINT ck_udb_client CHECK (client_type IN ('PDA','DRIVER_APP')),
    CONSTRAINT ck_udb_status CHECK ((status = 'PENDING' AND revoked_at IS NULL AND activated_at IS NULL)
        OR (status = 'ACTIVE' AND revoked_at IS NULL AND activated_at IS NOT NULL AND approval_id IS NOT NULL)
        OR (status = 'REVOKED' AND revoked_at IS NOT NULL))
);
-- 同一设备实例同时最多一条未吊销绑定（PENDING 或 ACTIVE）
CREATE UNIQUE INDEX uq_udb_active ON user_device_binding(device_instance_id) WHERE status IN ('PENDING','ACTIVE');
CREATE INDEX ix_udb_user ON user_device_binding(user_id, status);

-- 离线令牌：断网时边缘节点/终端本地校验用。签名在应用层，库里只存 jti 与吊销状态
CREATE TABLE offline_token (
    id                  BIGINT       PRIMARY KEY,
    jti                 VARCHAR(64)  NOT NULL,
    binding_id          BIGINT       NOT NULL,       -- user_device_binding.id
    user_id             BIGINT       NOT NULL,
    device_instance_id  VARCHAR(64)  NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    perm_version        BIGINT       NOT NULL,       -- 签发时的权限版本，权限变更后旧令牌联网即失效
    issued_at           TIMESTAMP    NOT NULL,
    expires_at          TIMESTAMP    NOT NULL,
    revoked_at          TIMESTAMP,
    CONSTRAINT uq_offline_jti UNIQUE (jti),
    CONSTRAINT ck_offline_ttl CHECK (expires_at > issued_at),
    -- 有效期上限 12 小时（docs/12 §3.3，小赵 I4）
    CONSTRAINT ck_offline_max_ttl CHECK (expires_at <= issued_at + interval '12 hours')  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_offline_max_ttl CHECK (datetime(expires_at) <= datetime(issued_at, '+12 hours'))
);
CREATE INDEX ix_offline_binding ON offline_token(binding_id) WHERE revoked_at IS NULL;

-- 主管审批（docs/12 §5）
CREATE TABLE approval_request (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,       -- 审批单号 APR-{warehouse_code}-{yyyyMMdd}-{6 位序号}（ck_apr_code）；02 stock_hold.approval_no 存本列
    approval_type       VARCHAR(32)  NOT NULL,       -- POD_CORRECT / CANCEL_AFTER_PICK / UNPLANNED_FAILOVER / DEVICE_BIND / SCRAP_MISREPORT / PAPER_BACKFILL / BOX_VOID / PROCESS_YIELD_DEVIATION / LIVE_DEATH_OVER
    warehouse_id        BIGINT       NOT NULL,
    target_type         VARCHAR(32)  NOT NULL,
    target_id           VARCHAR(64)  NOT NULL,
    payload_json        TEXT         NOT NULL,       -- 申请时的完整命令，审批通过后原样执行
    payload_hash        CHAR(64)     NOT NULL,
    reason              VARCHAR(256) NOT NULL,
    requested_by        BIGINT       NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    first_approver_id   BIGINT,
    first_approver_role VARCHAR(32),                 -- 审批时实际使用的角色（服务端写入，FAILOVER 由触发器核对）
    first_approved_at   TIMESTAMP,
    second_approver_id  BIGINT,                      -- 仅 UNPLANNED_FAILOVER
    second_approver_role VARCHAR(32),
    second_approved_at  TIMESTAMP,
    result_ref          VARCHAR(64),                 -- 执行结果引用：如 POD 更正的新 pod_id + correct_seq（服务端执行时分配）
    decided_at          TIMESTAMP,
    reject_reason       VARCHAR(256),
    expires_at          TIMESTAMP    NOT NULL,
    version             INT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC；expires_at 等时间列一律存 UTC（对齐 02 ad8ec1b P1）
    CONSTRAINT uq_apr_code UNIQUE (code),
    CONSTRAINT ck_apr_type CHECK (approval_type IN ('POD_CORRECT','CANCEL_AFTER_PICK','UNPLANNED_FAILOVER','DEVICE_BIND','SCRAP_MISREPORT','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER')),
    -- 非计划切换 = 发起人 + 仓库主管 + 中心运维三人（00 §9.1），角色字符串固定；是否真持有该角色由 trg_apr_transition 查 sys_user_role
    CONSTRAINT ck_apr_failover_roles CHECK (approval_type <> 'UNPLANNED_FAILOVER'
        OR ((first_approver_id IS NULL OR first_approver_role = 'WH_SUPERVISOR')
            AND (second_approver_id IS NULL OR second_approver_role = 'CENTER_OPS'))),
    CONSTRAINT ck_apr_status CHECK (status IN ('PENDING','PARTIAL','APPROVED','REJECTED','EXPIRED','WITHDRAWN')),
    CONSTRAINT ck_apr_sod CHECK (first_approver_id IS NULL OR first_approver_id <> requested_by),
    CONSTRAINT ck_apr_dual CHECK (second_approver_id IS NULL
        OR (approval_type = 'UNPLANNED_FAILOVER' AND second_approver_id <> requested_by AND second_approver_id <> first_approver_id)),
    CONSTRAINT ck_apr_done CHECK (status <> 'APPROVED' OR (first_approver_id IS NOT NULL
        AND (approval_type <> 'UNPLANNED_FAILOVER' OR second_approver_id IS NOT NULL))),
    CONSTRAINT ck_apr_hash CHECK (length(payload_hash) = 64),
    -- 小赵 I2：审批人三列成组；PARTIAL 只用于 FAILOVER 且只有第一人；APPROVED/REJECTED 必有 decided_at，未决不能有
    CONSTRAINT ck_apr_pair CHECK (
        ((first_approver_id IS NULL AND first_approver_role IS NULL AND first_approved_at IS NULL)
          OR (first_approver_id IS NOT NULL AND first_approver_role IS NOT NULL AND first_approved_at IS NOT NULL))
        AND ((second_approver_id IS NULL AND second_approver_role IS NULL AND second_approved_at IS NULL)
          OR (second_approver_id IS NOT NULL AND second_approver_role IS NOT NULL AND second_approved_at IS NOT NULL))),
    CONSTRAINT ck_apr_partial CHECK (status <> 'PARTIAL'
        OR (approval_type = 'UNPLANNED_FAILOVER' AND first_approver_id IS NOT NULL AND second_approver_id IS NULL)),
    CONSTRAINT ck_apr_decided CHECK ((status IN ('APPROVED','REJECTED') AND decided_at IS NOT NULL)
        OR (status IN ('PENDING','PARTIAL') AND decided_at IS NULL)
        OR status IN ('EXPIRED','WITHDRAWN')),
    -- 审批单号统一格式 APR-{warehouse_code}-{yyyyMMdd}-{6 位序号}（所有审批类型共用；02 stock_hold.approval_no 存的就是它）。
    -- 小赵 T1：仓库编码段收紧为 [A-Z0-9]{2,16}（与 #8 ck_wh_code 一致），写法对齐 02 ck_hold_approval_no @92e1477：PG 用 ~，SQLite 用 GLOB + 总长 22–36
    CONSTRAINT ck_apr_code CHECK (code ~ '^APR-[A-Z0-9]{2,16}-[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-[0-9]{6}$'),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_apr_code CHECK (
-- @sqlite-only         length(code) BETWEEN 22 AND 36 AND substr(code, 1, 4) = 'APR-'
-- @sqlite-only         AND substr(code, 5, length(code) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only         AND substr(code, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only         AND (substr(code, -11, 2) GLOB '0[1-9]' OR substr(code, -11, 2) GLOB '1[0-2]')
-- @sqlite-only         AND (substr(code, -9, 2) GLOB '0[1-9]' OR substr(code, -9, 2) GLOB '[12][0-9]' OR substr(code, -9, 2) GLOB '3[01]')),
    -- SCRAP_MISREPORT 审批人：质检主管或中心运维（是否真持有由 trg_apr_final / trg_apr_role 查 sys_user_role）
    CONSTRAINT ck_apr_scrap_roles CHECK (approval_type <> 'SCRAP_MISREPORT'
        OR first_approver_id IS NULL OR first_approver_role IN ('QC_SUPERVISOR','CENTER_OPS'))
);
CREATE UNIQUE INDEX uq_apr_open ON approval_request(approval_type, target_type, target_id) WHERE status IN ('PENDING','PARTIAL');
CREATE INDEX ix_apr_wh ON approval_request(warehouse_id, status, created_at);
CREATE INDEX ix_apr_requester ON approval_request(requested_by, status, created_at);   -- GET /approvals?mine=true

-- ===== 小赵 I1/I2/I5：审批只能 INSERT 成 PENDING；迁移单向；审批人写入后不可改；过期不能再审；FAILOVER 确认人必须真持有角色 =====
CREATE FUNCTION trg_apr_insert() RETURNS trigger LANGUAGE plpgsql AS $$                                     -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.status <> 'PENDING' OR NEW.first_approver_id IS NOT NULL OR NEW.second_approver_id IS NOT NULL      -- @pg-only
       OR NEW.decided_at IS NOT NULL OR NEW.result_ref IS NOT NULL THEN                                      -- @pg-only
        RAISE EXCEPTION 'approval_insert_not_pending' USING ERRCODE = '23514';                               -- @pg-only
    END IF;                                                                                                   -- @pg-only
    -- 审批单号中的仓库编码段必须等于所属仓 warehouse.code；格式不合法时交给 ck_apr_code 报                   -- @pg-only
    IF NEW.code ~ '^APR-[A-Z0-9]{2,16}-[0-9]{8}-[0-9]{6}$' AND NOT EXISTS (                                   -- @pg-only
         SELECT 1 FROM warehouse w WHERE w.id = NEW.warehouse_id                                               -- @pg-only
            AND w.code = substr(NEW.code, 5, length(NEW.code) - 20)) THEN                                     -- @pg-only
        RAISE EXCEPTION 'approval_code_warehouse_mismatch' USING ERRCODE = '23514';                          -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.approval_type = 'SCRAP_MISREPORT' AND NOT EXISTS (                                                 -- @pg-only
         SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                                  -- @pg-only
          JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id         -- @pg-only
          WHERE ur.user_id = NEW.requested_by AND r.code = 'WH_SUPERVISOR') THEN                              -- @pg-only
        RAISE EXCEPTION 'approval_role_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_apr_insert BEFORE INSERT ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_insert();  -- @pg-only
CREATE FUNCTION trg_apr_final() RETURNS trigger LANGUAGE plpgsql AS $$                                      -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF OLD.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')                                            -- @pg-only
       OR NEW.payload_hash IS DISTINCT FROM OLD.payload_hash OR NEW.payload_json IS DISTINCT FROM OLD.payload_json  -- @pg-only
       OR NEW.requested_by IS DISTINCT FROM OLD.requested_by OR NEW.approval_type IS DISTINCT FROM OLD.approval_type  -- @pg-only
       OR NEW.code IS DISTINCT FROM OLD.code OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id               -- @pg-only
       OR NEW.target_type IS DISTINCT FROM OLD.target_type OR NEW.target_id IS DISTINCT FROM OLD.target_id       -- @pg-only
       OR NEW.expires_at IS DISTINCT FROM OLD.expires_at OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN  -- @pg-only
        RAISE EXCEPTION 'approval_final' USING ERRCODE = '23514';                                            -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NOT ((OLD.status = NEW.status AND NEW.status IN ('PENDING','PARTIAL'))                                 -- @pg-only
         OR (OLD.status = 'PENDING' AND NEW.status IN ('PARTIAL','APPROVED','REJECTED','EXPIRED','WITHDRAWN'))   -- @pg-only
         OR (OLD.status = 'PARTIAL' AND NEW.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN'))) THEN       -- @pg-only
        RAISE EXCEPTION 'approval_transition_invalid' USING ERRCODE = '23514';                               -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF (OLD.first_approver_id IS NOT NULL AND (NEW.first_approver_id IS DISTINCT FROM OLD.first_approver_id   -- @pg-only
          OR NEW.first_approver_role IS DISTINCT FROM OLD.first_approver_role OR NEW.first_approved_at IS DISTINCT FROM OLD.first_approved_at))  -- @pg-only
       OR (OLD.second_approver_id IS NOT NULL AND NEW.second_approver_id IS DISTINCT FROM OLD.second_approver_id) THEN  -- @pg-only
        RAISE EXCEPTION 'approval_approver_immutable' USING ERRCODE = '23514';                               -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status AND COALESCE(OLD.expires_at <= (now() AT TIME ZONE 'UTC'), false) THEN  -- @pg-only
        RAISE EXCEPTION 'approval_expired' USING ERRCODE = '23514';                                          -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.approval_type = 'UNPLANNED_FAILOVER' AND (                                                         -- @pg-only
         (NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NOT EXISTS (                 -- @pg-only
            SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                               -- @pg-only
             JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id      -- @pg-only
             WHERE ur.user_id = NEW.first_approver_id AND r.code = 'WH_SUPERVISOR'))                          -- @pg-only
      OR (NEW.second_approver_id IS NOT NULL AND OLD.second_approver_id IS NULL AND NOT EXISTS (              -- @pg-only
            SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                               -- @pg-only
             WHERE ur.user_id = NEW.second_approver_id AND r.code = 'CENTER_OPS'))) THEN                      -- @pg-only
        RAISE EXCEPTION 'approval_role_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    -- 小赵 T2：单人审批类型按角色权限表核对审批人持有对应审批权限点（审批时使用的角色 = first_approver_role，且在本仓）  -- @pg-only
    IF NEW.approval_type IN ('DEVICE_BIND','POD_CORRECT','CANCEL_AFTER_PICK','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER')  -- @pg-only
       AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NEW.first_approver_role IS NOT NULL AND NOT EXISTS (  -- 角色缺失交给 ck_apr_pair  -- @pg-only
         SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                                  -- @pg-only
           JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id              -- @pg-only
          WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role                       -- @pg-only
            AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw                         -- @pg-only
                 WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))   -- CENTER_OPS 数据范围 ALL  -- @pg-only
            AND p.code = CASE NEW.approval_type WHEN 'DEVICE_BIND' THEN 'device.binding.approve'              -- @pg-only
                                                WHEN 'POD_CORRECT' THEN 'delivery.pod.correct.approve'        -- @pg-only
                                                WHEN 'CANCEL_AFTER_PICK' THEN 'outbound.order.cancel_after_pick.approve'  -- @pg-only
                                                WHEN 'PAPER_BACKFILL' THEN 'offline.paper.approve'            -- @pg-only
                                                WHEN 'BOX_VOID' THEN 'pack.box.void.approve'                  -- @pg-only
                                                WHEN 'PROCESS_YIELD_DEVIATION' THEN 'process.yield.approve'   -- @pg-only
                                                WHEN 'LIVE_DEATH_OVER' THEN 'live.death.approve'              -- @pg-only
                                                ELSE NULL END) THEN                                           -- @pg-only
        RAISE EXCEPTION 'approval_perm_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.approval_type = 'SCRAP_MISREPORT' AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL  -- @pg-only
       AND NOT EXISTS (SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                    -- @pg-only
             WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role                    -- @pg-only
               AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw                      -- @pg-only
                    WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))) THEN              -- @pg-only
        RAISE EXCEPTION 'approval_role_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_apr_final BEFORE UPDATE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_final();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_apr_no_replace BEFORE INSERT ON approval_request
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM approval_request a WHERE a.id = NEW.id OR a.code = NEW.code
-- @sqlite-only   OR (a.status IN ('PENDING','PARTIAL') AND a.approval_type = NEW.approval_type AND a.target_type = NEW.target_type AND a.target_id = NEW.target_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_insert BEFORE INSERT ON approval_request
-- @sqlite-only WHEN NEW.status <> 'PENDING' OR NEW.first_approver_id IS NOT NULL OR NEW.second_approver_id IS NOT NULL
-- @sqlite-only   OR NEW.decided_at IS NOT NULL OR NEW.result_ref IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_insert_not_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_code_wh BEFORE INSERT ON approval_request
-- @sqlite-only WHEN length(NEW.code) BETWEEN 22 AND 36 AND substr(NEW.code, 1, 4) = 'APR-'
-- @sqlite-only   AND substr(NEW.code, 5, length(NEW.code) - 20) NOT GLOB '*[^A-Z0-9]*'
-- @sqlite-only   AND substr(NEW.code, -16) GLOB '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
-- @sqlite-only   AND NOT EXISTS (SELECT 1 FROM warehouse w WHERE w.id = NEW.warehouse_id AND w.code = substr(NEW.code, 5, length(NEW.code) - 20))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_code_warehouse_mismatch'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_insert_role BEFORE INSERT ON approval_request
-- @sqlite-only WHEN NEW.approval_type = 'SCRAP_MISREPORT' AND NOT EXISTS (
-- @sqlite-only     SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only      JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id
-- @sqlite-only      WHERE ur.user_id = NEW.requested_by AND r.code = 'WH_SUPERVISOR')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_final BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN OLD.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')
-- @sqlite-only   OR NEW.payload_hash IS NOT OLD.payload_hash OR NEW.payload_json IS NOT OLD.payload_json
-- @sqlite-only   OR NEW.requested_by IS NOT OLD.requested_by OR NEW.approval_type IS NOT OLD.approval_type
-- @sqlite-only   OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
-- @sqlite-only   OR NEW.target_type IS NOT OLD.target_type OR NEW.target_id IS NOT OLD.target_id
-- @sqlite-only   OR NEW.expires_at IS NOT OLD.expires_at OR NEW.created_at IS NOT OLD.created_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_final'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_transition BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN OLD.status IN ('PENDING','PARTIAL') AND NOT ((OLD.status = NEW.status AND NEW.status IN ('PENDING','PARTIAL'))
-- @sqlite-only   OR (OLD.status = 'PENDING' AND NEW.status IN ('PARTIAL','APPROVED','REJECTED','EXPIRED','WITHDRAWN'))
-- @sqlite-only   OR (OLD.status = 'PARTIAL' AND NEW.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_transition_invalid'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_approver_immutable BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN (OLD.first_approver_id IS NOT NULL AND (NEW.first_approver_id IS NOT OLD.first_approver_id
-- @sqlite-only     OR NEW.first_approver_role IS NOT OLD.first_approver_role OR NEW.first_approved_at IS NOT OLD.first_approved_at))
-- @sqlite-only   OR (OLD.second_approver_id IS NOT NULL AND NEW.second_approver_id IS NOT OLD.second_approver_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_approver_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_expired BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status AND COALESCE(datetime(OLD.expires_at) <= datetime('now'), 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_expired'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_role BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN NEW.approval_type = 'UNPLANNED_FAILOVER' AND (
-- @sqlite-only     (NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NOT EXISTS (
-- @sqlite-only        SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only         JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id
-- @sqlite-only         WHERE ur.user_id = NEW.first_approver_id AND r.code = 'WH_SUPERVISOR'))
-- @sqlite-only  OR (NEW.second_approver_id IS NOT NULL AND OLD.second_approver_id IS NULL AND NOT EXISTS (
-- @sqlite-only        SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only         WHERE ur.user_id = NEW.second_approver_id AND r.code = 'CENTER_OPS')))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_perm BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN NEW.approval_type IN ('DEVICE_BIND','POD_CORRECT','CANCEL_AFTER_PICK','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER')
-- @sqlite-only   AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NEW.first_approver_role IS NOT NULL AND NOT EXISTS (
-- @sqlite-only     SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only       JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id
-- @sqlite-only      WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
-- @sqlite-only        AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
-- @sqlite-only             WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))
-- @sqlite-only        AND p.code = CASE NEW.approval_type WHEN 'DEVICE_BIND' THEN 'device.binding.approve'
-- @sqlite-only                                            WHEN 'POD_CORRECT' THEN 'delivery.pod.correct.approve'
-- @sqlite-only                                            WHEN 'CANCEL_AFTER_PICK' THEN 'outbound.order.cancel_after_pick.approve'
-- @sqlite-only                                            WHEN 'PAPER_BACKFILL' THEN 'offline.paper.approve'
-- @sqlite-only                                            WHEN 'BOX_VOID' THEN 'pack.box.void.approve'
-- @sqlite-only                                            WHEN 'PROCESS_YIELD_DEVIATION' THEN 'process.yield.approve'
-- @sqlite-only                                            WHEN 'LIVE_DEATH_OVER' THEN 'live.death.approve'
-- @sqlite-only                                            ELSE NULL END)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_perm_not_held'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_scrap_role BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN NEW.approval_type = 'SCRAP_MISREPORT' AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL
-- @sqlite-only   AND NOT EXISTS (SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only         WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
-- @sqlite-only           AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
-- @sqlite-only                WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id)))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_role_not_held'); END;

-- ===== 小赵 I3 + S1：设备绑定 INSERT 只能 PENDING；REVOKED 终态；身份列不可改；激活必须有本绑定的已通过 DEVICE_BIND 审批，审批人 ≠ 使用人 =====
CREATE FUNCTION trg_udb_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                      -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'INSERT' THEN                                                                                  -- @pg-only
        IF NEW.status <> 'PENDING' OR NEW.approval_id IS NOT NULL THEN                                        -- @pg-only
            RAISE EXCEPTION 'binding_insert_not_pending' USING ERRCODE = '23514';                            -- @pg-only
        END IF;                                                                                               -- @pg-only
        RETURN NEW;                                                                                           -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF OLD.status = 'REVOKED' OR (OLD.status = 'ACTIVE' AND NEW.status = 'PENDING')                          -- @pg-only
       OR NEW.device_instance_id IS DISTINCT FROM OLD.device_instance_id OR NEW.user_id IS DISTINCT FROM OLD.user_id  -- @pg-only
       OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id OR NEW.client_type IS DISTINCT FROM OLD.client_type  -- @pg-only
       OR NEW.device_id IS DISTINCT FROM OLD.device_id OR NEW.bound_at IS DISTINCT FROM OLD.bound_at            -- @pg-only
       OR (OLD.approval_id IS NOT NULL AND NEW.approval_id IS DISTINCT FROM OLD.approval_id) THEN             -- @pg-only
        RAISE EXCEPTION 'binding_immutable' USING ERRCODE = '23514';                                         -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.status = 'ACTIVE' AND OLD.status = 'PENDING' AND NOT EXISTS (                                      -- @pg-only
        SELECT 1 FROM approval_request a WHERE a.id = NEW.approval_id AND a.approval_type = 'DEVICE_BIND'     -- @pg-only
           AND a.status = 'APPROVED' AND a.target_type = 'DEVICE_BINDING' AND a.target_id = NEW.id::text      -- @pg-only
           AND a.first_approver_id <> NEW.user_id) THEN                                                       -- @pg-only
        RAISE EXCEPTION 'binding_approval_invalid' USING ERRCODE = '23514';                                  -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_udb_guard BEFORE INSERT OR UPDATE ON user_device_binding FOR EACH ROW EXECUTE FUNCTION trg_udb_guard();  -- @pg-only
CREATE FUNCTION trg_no_delete_12() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                       -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_udb_no_delete BEFORE DELETE ON user_device_binding FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_apr_no_delete BEFORE DELETE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_udb_no_truncate BEFORE TRUNCATE ON user_device_binding FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_apr_no_truncate BEFORE TRUNCATE ON approval_request FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_udb_no_replace BEFORE INSERT ON user_device_binding
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM user_device_binding b WHERE b.id = NEW.id
-- @sqlite-only   OR (b.device_instance_id = NEW.device_instance_id AND b.status IN ('PENDING','ACTIVE')))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'binding_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_insert BEFORE INSERT ON user_device_binding WHEN NEW.status <> 'PENDING' OR NEW.approval_id IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'binding_insert_not_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_immutable BEFORE UPDATE ON user_device_binding
-- @sqlite-only WHEN OLD.status = 'REVOKED' OR (OLD.status = 'ACTIVE' AND NEW.status = 'PENDING')
-- @sqlite-only   OR NEW.device_instance_id IS NOT OLD.device_instance_id OR NEW.user_id IS NOT OLD.user_id
-- @sqlite-only   OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.client_type IS NOT OLD.client_type
-- @sqlite-only   OR NEW.device_id IS NOT OLD.device_id OR NEW.bound_at IS NOT OLD.bound_at
-- @sqlite-only   OR (OLD.approval_id IS NOT NULL AND NEW.approval_id IS NOT OLD.approval_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'binding_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_activate BEFORE UPDATE ON user_device_binding
-- @sqlite-only WHEN NEW.status = 'ACTIVE' AND OLD.status = 'PENDING' AND NOT EXISTS (
-- @sqlite-only   SELECT 1 FROM approval_request a WHERE a.id = NEW.approval_id AND a.approval_type = 'DEVICE_BIND'
-- @sqlite-only     AND a.status = 'APPROVED' AND a.target_type = 'DEVICE_BINDING' AND a.target_id = CAST(NEW.id AS TEXT)
-- @sqlite-only     AND a.first_approver_id <> NEW.user_id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'binding_approval_invalid'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_no_delete BEFORE DELETE ON user_device_binding BEGIN SELECT RAISE(ABORT, 'append_only_violation: user_device_binding'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_no_delete BEFORE DELETE ON approval_request BEGIN SELECT RAISE(ABORT, 'append_only_violation: approval_request'); END;

-- ===== 小赵 I4：离线令牌只能写一次 revoked_at；其余列不可改；SQLite 防 REPLACE =====
CREATE FUNCTION trg_offline_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF OLD.revoked_at IS NOT NULL OR NEW.jti IS DISTINCT FROM OLD.jti OR NEW.binding_id IS DISTINCT FROM OLD.binding_id  -- @pg-only
       OR NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.device_instance_id IS DISTINCT FROM OLD.device_instance_id  -- @pg-only
       OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id OR NEW.perm_version IS DISTINCT FROM OLD.perm_version  -- @pg-only
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN  -- @pg-only
        RAISE EXCEPTION 'offline_token_immutable' USING ERRCODE = '23514';                                   -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_offline_guard BEFORE UPDATE ON offline_token FOR EACH ROW EXECUTE FUNCTION trg_offline_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_offline_guard BEFORE UPDATE ON offline_token
-- @sqlite-only WHEN OLD.revoked_at IS NOT NULL OR NEW.jti IS NOT OLD.jti OR NEW.binding_id IS NOT OLD.binding_id
-- @sqlite-only   OR NEW.user_id IS NOT OLD.user_id OR NEW.device_instance_id IS NOT OLD.device_instance_id
-- @sqlite-only   OR NEW.warehouse_id IS NOT OLD.warehouse_id OR NEW.perm_version IS NOT OLD.perm_version
-- @sqlite-only   OR NEW.issued_at IS NOT OLD.issued_at OR NEW.expires_at IS NOT OLD.expires_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'offline_token_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_offline_no_replace BEFORE INSERT ON offline_token
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM offline_token t WHERE t.id = NEW.id OR t.jti = NEW.jti)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'offline_token_duplicate'); END;

-- sys_user.perm_version 只升不降（撤权必须让旧令牌失效）；SQLite 防 REPLACE 把版本打回 1（小赵 I7）。
-- 下发应用 USER_PERM 一律"UPDATE，0 行再 INSERT"，不用 REPLACE / UPSERT（docs/12 §4.3）
CREATE FUNCTION trg_user_perm_ver() RETURNS trigger LANGUAGE plpgsql AS $$                                  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.perm_version < OLD.perm_version THEN                                                               -- @pg-only
        RAISE EXCEPTION 'perm_version_rewind' USING ERRCODE = '23514';                                       -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_user_perm_ver BEFORE UPDATE ON sys_user FOR EACH ROW EXECUTE FUNCTION trg_user_perm_ver();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_user_perm_ver BEFORE UPDATE ON sys_user WHEN NEW.perm_version < OLD.perm_version
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'perm_version_rewind'); END;
-- @sqlite-only CREATE TRIGGER trg_user_no_replace BEFORE INSERT ON sys_user
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_user u WHERE u.id = NEW.id OR u.username = NEW.username)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_duplicate'); END;

GRANT SELECT, INSERT, UPDATE ON sys_user, sys_role, sys_permission, sys_role_perm, sys_user_role, sys_user_warehouse, api_credential TO wms_app;  -- @pg-only
-- docs/12 新表 wms_app 最小授权：不给 DELETE/TRUNCATE；离线令牌只能写吊销时间；审批只能改决策相关列
GRANT SELECT, INSERT ON user_device_binding TO wms_app;                                                       -- @pg-only
GRANT UPDATE (status, approval_id, activated_at, revoked_at, revoked_by, revoke_reason) ON user_device_binding TO wms_app;  -- @pg-only
GRANT SELECT, INSERT ON offline_token TO wms_app;                                                             -- @pg-only
GRANT UPDATE (revoked_at) ON offline_token TO wms_app;                                                        -- @pg-only
GRANT SELECT, INSERT ON approval_request TO wms_app;                                                          -- @pg-only
GRANT UPDATE (status, first_approver_id, first_approver_role, first_approved_at, second_approver_id, second_approver_role,  -- @pg-only
    second_approved_at, decided_at, reject_reason, result_ref, version) ON approval_request TO wms_app;       -- @pg-only
