-- =============================================================================
-- 12b_auth_audit.sql —— 第 12 篇（权限与审计，PR #9）自有 DDL
-- 加载顺序：紧跟 12_auth.sql 之后、90_available_view.sql 之前。
-- 跨篇加列一律 ALTER（README「跨篇 ALTER 登记表」已登记）。
-- =============================================================================

-- [跨篇 ALTER] audit_log（表主人：11_integration.sql）
ALTER TABLE audit_log ADD COLUMN node_id INT NOT NULL DEFAULT 0;            -- 0 = 未登记节点，应用层必填真实 node_id   -- @pg-only
-- @sqlite-only ALTER TABLE audit_log ADD COLUMN node_id INT NOT NULL DEFAULT 0;            -- 0 = 未登记节点，应用层必填真实 node_id
ALTER TABLE audit_log ADD COLUMN node_seq BIGINT NOT NULL DEFAULT 0;   -- @pg-only
-- @sqlite-only ALTER TABLE audit_log ADD COLUMN node_seq BIGINT NOT NULL DEFAULT 0;
ALTER TABLE audit_log ADD COLUMN device_instance_id VARCHAR(64);   -- @pg-only
-- @sqlite-only ALTER TABLE audit_log ADD COLUMN device_instance_id VARCHAR(64);
ALTER TABLE audit_log ADD COLUMN approval_id BIGINT;   -- PG 外键 fk_audit_approval 在 approval_request 建表后补  -- @pg-only
-- @sqlite-only ALTER TABLE audit_log ADD COLUMN approval_id BIGINT REFERENCES approval_request(id);   -- 可空、默认 NULL；SQLite 允许前向引用
CREATE UNIQUE INDEX uq_audit_node_seq ON audit_log(node_id, node_seq);
CREATE INDEX ix_audit_wh ON audit_log(warehouse_id, occurred_at DESC);
-- Doro 定：DEFAULT 0 只为兼容存量行；新写入 node_id/node_seq 必须 > 0（应用层映射 40001 PARAM_INVALID）
CREATE FUNCTION trg_audit_node_required() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                             -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.node_id <= 0 OR NEW.node_seq <= 0 THEN                                                             -- @pg-only
        RAISE EXCEPTION 'audit_node_required: 40001' USING ERRCODE = '23514';                                -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_audit_node_required BEFORE INSERT ON audit_log FOR EACH ROW EXECUTE FUNCTION trg_audit_node_required();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_audit_node_required BEFORE INSERT ON audit_log
-- @sqlite-only WHEN NEW.node_id <= 0 OR NEW.node_seq <= 0
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'audit_node_required: 40001'); END;
-- audit_log 只追加（docs/12 §6.4）：行级 UPDATE/DELETE 与 TRUNCATE 都拦；归档走按月导出 + 维护窗口内专用角色
CREATE FUNCTION trg_audit_append_only() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                             -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'append_only_violation: audit_log' USING ERRCODE = '42501';                             -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION trg_audit_append_only();  -- @pg-only
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_log FOR EACH STATEMENT EXECUTE FUNCTION trg_audit_append_only();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;
-- @sqlite-only CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;
-- 小赵 B1：SQLite REPLACE 删旧行不触发 DELETE 触发器（recursive_triggers=OFF），id 或 (node_id,node_seq) 已存在就直接 ABORT
-- @sqlite-only CREATE TRIGGER trg_audit_no_replace BEFORE INSERT ON audit_log
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM audit_log a WHERE a.id = NEW.id OR (a.node_id = NEW.node_id AND a.node_seq = NEW.node_seq))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'append_only_violation: audit_log'); END;

-- [本篇表，12_auth.sql 由 #2 拆分建立] sys_user 加 perm_version
ALTER TABLE sys_user ADD COLUMN perm_version BIGINT NOT NULL DEFAULT 1 CONSTRAINT ck_user_perm_ver CHECK (perm_version > 0);   -- @pg-only
-- @sqlite-only ALTER TABLE sys_user ADD COLUMN perm_version BIGINT NOT NULL DEFAULT 1 CONSTRAINT ck_user_perm_ver CHECK (perm_version > 0);

-- -----------------------------------------------------------------------------
-- docs/12 权限与审计：设备绑定、离线令牌、主管审批
-- -----------------------------------------------------------------------------

-- 设备实例绑定：device_instance_id（App 安装实例）↔ 账号 + 仓。一个实例同时最多一条 PENDING/ACTIVE 绑定
-- approval_request 建表提前到绑定表之前：fk_udb_approval 直接写在 CREATE TABLE 里（不再 ALTER）
CREATE TABLE approval_request (
    id                  BIGINT       PRIMARY KEY,
    code                VARCHAR(64)  NOT NULL,       -- 审批单号 APR-{warehouse_code}-{yyyyMMdd}-{6 位序号}（ck_apr_code）；02 stock_hold.approval_no 存本列
    approval_type       VARCHAR(32)  NOT NULL,       -- POD_CORRECT / CANCEL_AFTER_PICK / UNPLANNED_FAILOVER / DEVICE_BIND / SCRAP_MISREPORT
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
    expires_at          TIMESTAMP,                   -- 不传由库算 created_at + 按类型上限（ck_apr_ttl）；只许缩短；不许 NULL（PG NOT NULL，SQLite trg_apr_expires_null）
    version             INT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),   -- UTC 整秒；非属主写入由库覆盖（trg_apr_zclock）
    CONSTRAINT uq_apr_code UNIQUE (code),
    CONSTRAINT fk_apr_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse (id),
    CONSTRAINT fk_apr_requester FOREIGN KEY (requested_by) REFERENCES sys_user (id),
    CONSTRAINT fk_apr_first FOREIGN KEY (first_approver_id) REFERENCES sys_user (id),
    CONSTRAINT fk_apr_second FOREIGN KEY (second_approver_id) REFERENCES sys_user (id),
    -- 有效期上限按类型（docs/12 §5 默认有效期：FAILOVER 1h、拣后取消 2h、得率偏离 12h，其余 24h）；00 §6.8 第 6 条：允许缩短，不许超上限
    CONSTRAINT ck_apr_ttl CHECK (expires_at IS NULL OR (expires_at > created_at AND expires_at <= created_at + CASE approval_type WHEN 'UNPLANNED_FAILOVER' THEN interval '1 hour' WHEN 'CANCEL_AFTER_PICK' THEN interval '2 hours' WHEN 'PROCESS_YIELD_DEVIATION' THEN interval '12 hours' ELSE interval '24 hours' END)),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_apr_ttl CHECK (expires_at IS NULL OR COALESCE(CAST(strftime('%s', expires_at) AS INTEGER) - CAST(strftime('%s', created_at) AS INTEGER) BETWEEN 1 AND CASE approval_type WHEN 'UNPLANNED_FAILOVER' THEN 3600 WHEN 'CANCEL_AFTER_PICK' THEN 7200 WHEN 'PROCESS_YIELD_DEVIATION' THEN 43200 ELSE 86400 END, 0)),
    CONSTRAINT ck_apr_ts CHECK ((created_at IS NULL OR created_at = date_trunc('second', created_at)) AND (expires_at IS NULL OR expires_at = date_trunc('second', expires_at)) AND (first_approved_at IS NULL OR first_approved_at = date_trunc('second', first_approved_at)) AND (second_approved_at IS NULL OR second_approved_at = date_trunc('second', second_approved_at)) AND (decided_at IS NULL OR decided_at = date_trunc('second', decided_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_apr_ts CHECK ((created_at IS NULL OR (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(created_at) IS created_at AND substr(created_at, 12, 2) <= '23')) AND (expires_at IS NULL OR (expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(expires_at) IS expires_at AND substr(expires_at, 12, 2) <= '23')) AND (first_approved_at IS NULL OR (first_approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(first_approved_at) IS first_approved_at AND substr(first_approved_at, 12, 2) <= '23')) AND (second_approved_at IS NULL OR (second_approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(second_approved_at) IS second_approved_at AND substr(second_approved_at, 12, 2) <= '23')) AND (decided_at IS NULL OR (decided_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(decided_at) IS decided_at AND substr(decided_at, 12, 2) <= '23'))),
    CONSTRAINT ck_apr_type CHECK (approval_type IN ('POD_CORRECT','CANCEL_AFTER_PICK','UNPLANNED_FAILOVER','DEVICE_BIND','SCRAP_MISREPORT',
        'PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER','PROCESS_REWORK',
        'INBOUND_CORRECTION','INBOUND_SOD_WAIVER')),   -- 【ck_apr_type 变更】00 已登记的 4 类 + PROCESS_REWORK（Doro 06:16）+ 第 3 篇两类（00 §6.6.1）
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
    -- SCRAP_MISREPORT 审批人不再限角色：改由权限点 scrap.misreport.approve 判定（trg_apr_final 的权限点分支）。
    -- 依 Chief 裁决：00 §6.6 是三层校验（权限点 + 数据权限 + 强制边界），13 篇前端也按权限点渲染按钮，
    -- 只走角色会让「前端渲染 vs 后端拒绝」永远对不上。本 CHECK 退化为格式兜底（角色非空由 ck_apr_pair 管）。
    CONSTRAINT ck_apr_scrap_roles CHECK (approval_type <> 'SCRAP_MISREPORT'
        OR first_approver_id IS NULL OR first_approver_role IS NOT NULL)
);
ALTER TABLE audit_log ADD CONSTRAINT fk_audit_approval FOREIGN KEY (approval_id) REFERENCES approval_request (id);  -- @pg-only

CREATE TABLE user_device_binding (
    id                  BIGINT       PRIMARY KEY,
    device_instance_id  VARCHAR(64)  NOT NULL,
    device_id           BIGINT          CONSTRAINT fk_udb_device REFERENCES device(id),   -- 第 1 篇 device 台账；司机自有手机可为空（跨篇 FK 收口）
    client_type         VARCHAR(16)  NOT NULL,       -- PDA / DRIVER_APP
    user_id             BIGINT       NOT NULL,
    warehouse_id        BIGINT       NOT NULL,
    status              VARCHAR(16)  NOT NULL DEFAULT 'PENDING',   -- PENDING（待主管确认）/ ACTIVE / REVOKED（终态）
    approval_id         BIGINT,                      -- DEVICE_BIND 审批单；fk_udb_approval → approval_request(id)（两库都写在建表语句里）
    bound_at            TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),   -- UTC 整秒；非属主写入由库覆盖（trg_udb_zclock）
    activated_at        TIMESTAMP,
    revoked_at          TIMESTAMP,
    revoked_by          BIGINT,
    revoke_reason       VARCHAR(64),
    CONSTRAINT fk_udb_approval FOREIGN KEY (approval_id) REFERENCES approval_request (id),
    CONSTRAINT fk_udb_user FOREIGN KEY (user_id) REFERENCES sys_user (id),
    CONSTRAINT fk_udb_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse (id),
    CONSTRAINT fk_udb_revoker FOREIGN KEY (revoked_by) REFERENCES sys_user (id),
    CONSTRAINT ck_udb_ts CHECK ((bound_at IS NULL OR bound_at = date_trunc('second', bound_at)) AND (activated_at IS NULL OR activated_at = date_trunc('second', activated_at)) AND (revoked_at IS NULL OR revoked_at = date_trunc('second', revoked_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_udb_ts CHECK ((bound_at IS NULL OR (bound_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(bound_at) IS bound_at AND substr(bound_at, 12, 2) <= '23')) AND (activated_at IS NULL OR (activated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(activated_at) IS activated_at AND substr(activated_at, 12, 2) <= '23')) AND (revoked_at IS NULL OR (revoked_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(revoked_at) IS revoked_at AND substr(revoked_at, 12, 2) <= '23'))),
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
    CONSTRAINT fk_offline_binding FOREIGN KEY (binding_id) REFERENCES user_device_binding (id),
    CONSTRAINT fk_offline_user FOREIGN KEY (user_id) REFERENCES sys_user (id),
    CONSTRAINT fk_offline_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse (id),
    CONSTRAINT ck_offline_ts CHECK ((issued_at IS NULL OR issued_at = date_trunc('second', issued_at)) AND (expires_at IS NULL OR expires_at = date_trunc('second', expires_at)) AND (revoked_at IS NULL OR revoked_at = date_trunc('second', revoked_at))),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_offline_ts CHECK ((issued_at IS NULL OR (issued_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(issued_at) IS issued_at AND substr(issued_at, 12, 2) <= '23')) AND (expires_at IS NULL OR (expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(expires_at) IS expires_at AND substr(expires_at, 12, 2) <= '23')) AND (revoked_at IS NULL OR (revoked_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(revoked_at) IS revoked_at AND substr(revoked_at, 12, 2) <= '23'))),
    -- SQLite 一律按整数秒比较（00 §6.8 第 5 条）；解析不了 → COALESCE 成 0 → 拒（自查 B2-2 NULL 放行、B2-3 文本序误判）
    CONSTRAINT ck_offline_ttl CHECK (expires_at > issued_at),  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_offline_ttl CHECK (COALESCE(CAST(strftime('%s', expires_at) AS INTEGER) > CAST(strftime('%s', issued_at) AS INTEGER), 0)),
    -- 有效期上限 12 小时（docs/12 §3.3，小赵 I4）
    CONSTRAINT ck_offline_max_ttl CHECK (expires_at <= issued_at + interval '12 hours')  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_offline_max_ttl CHECK (COALESCE(CAST(strftime('%s', expires_at) AS INTEGER) - CAST(strftime('%s', issued_at) AS INTEGER) <= 43200, 0))
);
CREATE INDEX ix_offline_binding ON offline_token(binding_id) WHERE revoked_at IS NULL;

-- 主管审批（docs/12 §5）
CREATE UNIQUE INDEX uq_apr_open ON approval_request(approval_type, target_type, target_id) WHERE status IN ('PENDING','PARTIAL');
CREATE INDEX ix_apr_wh ON approval_request(warehouse_id, status, created_at);
CREATE INDEX ix_apr_requester ON approval_request(requested_by, status, created_at);   -- GET /approvals?mine=true

-- ===== 小赵 I1/I2/I5：审批只能 INSERT 成 PENDING；迁移单向；审批人写入后不可改；过期不能再审；FAILOVER 确认人必须真持有角色 =====
CREATE FUNCTION trg_apr_insert() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                     -- @pg-only
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
          JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id                -- @pg-only
          JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id         -- @pg-only
          WHERE ur.user_id = NEW.requested_by AND p.code = 'scrap.misreport.request') THEN                    -- @pg-only
        RAISE EXCEPTION 'approval_perm_not_held' USING ERRCODE = '23514';                                     -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_apr_insert BEFORE INSERT ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_insert();  -- @pg-only
CREATE FUNCTION trg_apr_final() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                      -- @pg-only
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
    IF NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status AND NOT COALESCE(OLD.expires_at > (now() AT TIME ZONE 'UTC'), false) THEN  -- NULL 视为已过期 -- @pg-only
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
    IF NEW.approval_type IN ('DEVICE_BIND','POD_CORRECT','CANCEL_AFTER_PICK','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER','PROCESS_REWORK','INBOUND_CORRECTION','INBOUND_SOD_WAIVER')                                -- @pg-only
       AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NEW.first_approver_role IS NOT NULL AND NOT EXISTS (  -- 角色缺失交给 ck_apr_pair  -- @pg-only
         SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                                  -- @pg-only
           JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id              -- @pg-only
          WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role                       -- @pg-only
            AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw                         -- @pg-only
                 WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))   -- CENTER_OPS 数据范围 ALL  -- @pg-only
            AND p.code = CASE NEW.approval_type WHEN 'DEVICE_BIND' THEN 'device.binding.approve'              -- @pg-only
                                                WHEN 'POD_CORRECT' THEN 'delivery.pod.correct.approve'        -- @pg-only
                                                WHEN 'PAPER_BACKFILL' THEN 'offline.paper.approve'   -- 【ck_apr_type 变更】 -- @pg-only
                                                WHEN 'BOX_VOID' THEN 'pack.box.void.approve'   -- 【ck_apr_type 变更】 -- @pg-only
                                                WHEN 'PROCESS_YIELD_DEVIATION' THEN 'process.yield.approve'   -- 【ck_apr_type 变更】 -- @pg-only
                                                WHEN 'LIVE_DEATH_OVER' THEN 'live.death.approve'   -- 【ck_apr_type 变更】 -- @pg-only
                                                WHEN 'PROCESS_REWORK' THEN 'process.rework.approve'   -- 【ck_apr_type 变更】 -- @pg-only
                                                WHEN 'INBOUND_CORRECTION' THEN 'inbound.receipt.adjust.approve'   -- 第 3 篇 -- @pg-only
                                                WHEN 'INBOUND_SOD_WAIVER' THEN 'inbound.sod.waive'   -- 第 3 篇 -- @pg-only
                                                ELSE 'outbound.order.cancel_after_pick.approve' END) THEN             -- @pg-only
        RAISE EXCEPTION 'approval_perm_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.approval_type = 'SCRAP_MISREPORT' AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL  -- @pg-only
       AND NOT EXISTS (SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id                    -- @pg-only
             JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id            -- @pg-only
             WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role                    -- @pg-only
               AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw                      -- @pg-only
                    WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))                    -- @pg-only
               AND p.code = 'scrap.misreport.approve') THEN                                                   -- @pg-only
        RAISE EXCEPTION 'approval_perm_not_held' USING ERRCODE = '23514';                                    -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_apr_final BEFORE UPDATE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_final();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_apr_no_replace BEFORE INSERT ON approval_request
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM approval_request a WHERE a.id = NEW.id OR a.code = NEW.code
-- @sqlite-only   OR (NEW.status IN ('PENDING','PARTIAL') AND a.status IN ('PENDING','PARTIAL') AND a.approval_type = NEW.approval_type AND a.target_type = NEW.target_type AND a.target_id = NEW.target_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_request_duplicate'); END;
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
-- @sqlite-only      JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id
-- @sqlite-only      JOIN sys_user_warehouse uw ON uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id
-- @sqlite-only      WHERE ur.user_id = NEW.requested_by AND p.code = 'scrap.misreport.request')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_perm_not_held'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_final BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN OLD.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN')
-- @sqlite-only   OR NEW.payload_hash IS NOT OLD.payload_hash OR NEW.payload_json IS NOT OLD.payload_json
-- @sqlite-only   OR NEW.requested_by IS NOT OLD.requested_by OR NEW.approval_type IS NOT OLD.approval_type
-- @sqlite-only   OR NEW.code IS NOT OLD.code OR NEW.warehouse_id IS NOT OLD.warehouse_id
-- @sqlite-only   OR NEW.target_type IS NOT OLD.target_type OR NEW.target_id IS NOT OLD.target_id
-- @sqlite-only   OR (NEW.expires_at IS NOT OLD.expires_at AND OLD.expires_at IS NOT NULL) OR NEW.created_at IS NOT OLD.created_at   -- OLD NULL 只在 trg_apr_ttl_fill 同语句补算时出现
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
-- @sqlite-only WHEN NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status
-- @sqlite-only   AND NOT COALESCE(CAST(strftime('%s', OLD.expires_at) AS INTEGER) > CAST(strftime('%s', 'now') AS INTEGER), 0)   -- 自查 B2-1：解析不了 / NULL 一律视为已过期
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
-- @sqlite-only WHEN NEW.approval_type IN ('DEVICE_BIND','POD_CORRECT','CANCEL_AFTER_PICK','PAPER_BACKFILL','BOX_VOID','PROCESS_YIELD_DEVIATION','LIVE_DEATH_OVER','PROCESS_REWORK','INBOUND_CORRECTION','INBOUND_SOD_WAIVER')
-- @sqlite-only   AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL AND NEW.first_approver_role IS NOT NULL AND NOT EXISTS (
-- @sqlite-only     SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only       JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id
-- @sqlite-only      WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
-- @sqlite-only        AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
-- @sqlite-only             WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))
-- @sqlite-only        AND p.code = CASE NEW.approval_type WHEN 'DEVICE_BIND' THEN 'device.binding.approve'
-- @sqlite-only                                            WHEN 'POD_CORRECT' THEN 'delivery.pod.correct.approve'
-- @sqlite-only                                            WHEN 'PAPER_BACKFILL' THEN 'offline.paper.approve'
-- @sqlite-only                                            WHEN 'BOX_VOID' THEN 'pack.box.void.approve'
-- @sqlite-only                                            WHEN 'PROCESS_YIELD_DEVIATION' THEN 'process.yield.approve'
-- @sqlite-only                                            WHEN 'LIVE_DEATH_OVER' THEN 'live.death.approve'
-- @sqlite-only                                            WHEN 'PROCESS_REWORK' THEN 'process.rework.approve'
-- @sqlite-only                                            WHEN 'INBOUND_CORRECTION' THEN 'inbound.receipt.adjust.approve'
-- @sqlite-only                                            WHEN 'INBOUND_SOD_WAIVER' THEN 'inbound.sod.waive'
-- @sqlite-only                                            ELSE 'outbound.order.cancel_after_pick.approve' END)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_perm_not_held'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_scrap_role BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN NEW.approval_type = 'SCRAP_MISREPORT' AND NEW.first_approver_id IS NOT NULL AND OLD.first_approver_id IS NULL
-- @sqlite-only   AND NOT EXISTS (SELECT 1 FROM sys_user_role ur JOIN sys_role r ON r.id = ur.role_id
-- @sqlite-only         JOIN sys_role_perm rp ON rp.role_id = r.id JOIN sys_permission p ON p.id = rp.perm_id
-- @sqlite-only         WHERE ur.user_id = NEW.first_approver_id AND r.code = NEW.first_approver_role
-- @sqlite-only           AND (r.code = 'CENTER_OPS' OR EXISTS (SELECT 1 FROM sys_user_warehouse uw
-- @sqlite-only                WHERE uw.user_id = ur.user_id AND uw.warehouse_id = NEW.warehouse_id))
-- @sqlite-only           AND p.code = 'scrap.misreport.approve')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_perm_not_held'); END;

-- ===== 小赵 I3 + S1：设备绑定 INSERT 只能 PENDING；REVOKED 终态；身份列不可改；激活必须有本绑定的已通过 DEVICE_BIND 审批，审批人 ≠ 使用人 =====
CREATE FUNCTION trg_udb_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                      -- @pg-only
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
CREATE FUNCTION trg_no_delete_12() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                       -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_udb_no_delete BEFORE DELETE ON user_device_binding FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_apr_no_delete BEFORE DELETE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_udb_no_truncate BEFORE TRUNCATE ON user_device_binding FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_apr_no_truncate BEFORE TRUNCATE ON approval_request FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_udb_no_replace BEFORE INSERT ON user_device_binding
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM user_device_binding b WHERE b.id = NEW.id
-- @sqlite-only   OR (NEW.status IN ('PENDING','ACTIVE') AND b.status IN ('PENDING','ACTIVE') AND b.device_instance_id = NEW.device_instance_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'user_device_binding_duplicate'); END;
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
CREATE FUNCTION trg_offline_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                  -- @pg-only
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
CREATE FUNCTION trg_user_perm_ver() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                  -- @pg-only
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


-- [跨篇 ALTER] stock_hold.approval_no → approval_request.code（表主人：02_inventory.sql；00 第 278 行）
-- PG 外键引用 uq_apr_code。SQLite 不能 ALTER 加外键，用 AFTER 触发器：CHECK 先于 AFTER，格式错误仍报 ck_hold_approval_no。
ALTER TABLE stock_hold ADD CONSTRAINT fk_hold_approval_no FOREIGN KEY (approval_no) REFERENCES approval_request (code);  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_hold_approval_fk AFTER INSERT ON stock_hold
-- @sqlite-only WHEN NEW.approval_no IS NOT NULL AND NOT EXISTS (SELECT 1 FROM approval_request a WHERE a.code = NEW.approval_no)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'fk_hold_approval_no'); END;
-- @sqlite-only CREATE TRIGGER trg_hold_approval_fk_upd AFTER UPDATE OF approval_no ON stock_hold
-- @sqlite-only WHEN NEW.approval_no IS NOT NULL AND NOT EXISTS (SELECT 1 FROM approval_request a WHERE a.code = NEW.approval_no)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'fk_hold_approval_no'); END;

-- ===== 第 12 篇时间加固（自查 B2/B3，00 §6.8）=====
-- PG：服务端时间由 BEFORE 触发器对非表属主写入强制覆盖为 date_trunc('second', now() AT TIME ZONE 'UTC')；表属主（迁移/种子角色）豁免，
--     同第 11 篇 outbox / 退供 trg_srtn_zclock 口径。函数名带 z，同表 BEFORE 触发器按名字排在业务守卫之后。
--     只写一次的时间列对任何角色都不可改（*_time_immutable → 40004）。
-- SQLite（不能改 NEW）：时间列只收整秒 'YYYY-MM-DD HH:MM:SS'（ck_*_ts），服务端时间只收与 now 相差 ≤ 300 s（*_clock_skew → 40003），一律按 strftime('%s') 整数秒比较。
ALTER TABLE approval_request ALTER COLUMN expires_at SET NOT NULL;  -- @pg-only
CREATE FUNCTION trg_apr_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
    t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');   -- @pg-only
BEGIN   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.approval_request'::regclass;   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        IF current_user IS DISTINCT FROM owner_name THEN NEW.created_at := t; END IF;   -- @pg-only
        IF NEW.expires_at IS NULL THEN   -- @pg-only
            NEW.expires_at := NEW.created_at + CASE NEW.approval_type WHEN 'UNPLANNED_FAILOVER' THEN interval '1 hour' WHEN 'CANCEL_AFTER_PICK' THEN interval '2 hours'   -- @pg-only
                WHEN 'PROCESS_YIELD_DEVIATION' THEN interval '12 hours' ELSE interval '24 hours' END;   -- @pg-only
        END IF;   -- @pg-only
        RETURN NEW;   -- @pg-only
    END IF;   -- @pg-only
    -- *_approved_at / decided_at 写入后的不可改由 trg_apr_final（approval_approver_immutable / approval_final，终态整行锁）负责   -- @pg-only
    IF current_user IS NOT DISTINCT FROM owner_name THEN RETURN NEW; END IF;   -- @pg-only
    IF OLD.first_approver_id IS NULL AND NEW.first_approver_id IS NOT NULL THEN NEW.first_approved_at := t; END IF;   -- @pg-only
    IF OLD.second_approver_id IS NULL AND NEW.second_approver_id IS NOT NULL THEN NEW.second_approved_at := t; END IF;   -- @pg-only
    IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('APPROVED','REJECTED','EXPIRED','WITHDRAWN') THEN NEW.decided_at := t; END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_apr_zclock BEFORE INSERT OR UPDATE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_apr_clock_ins BEFORE INSERT ON approval_request
-- @sqlite-only WHEN NOT COALESCE(NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_request_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_ttl_fill AFTER INSERT ON approval_request WHEN NEW.expires_at IS NULL
-- @sqlite-only BEGIN UPDATE approval_request SET expires_at = datetime(NEW.created_at, '+' || CASE NEW.approval_type WHEN 'UNPLANNED_FAILOVER' THEN 3600 WHEN 'CANCEL_AFTER_PICK' THEN 7200
-- @sqlite-only   WHEN 'PROCESS_YIELD_DEVIATION' THEN 43200 ELSE 86400 END || ' seconds') WHERE id = NEW.id; END;
-- @sqlite-only CREATE TRIGGER trg_apr_expires_null BEFORE UPDATE OF expires_at ON approval_request WHEN NEW.expires_at IS NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_request_expires_null'); END;
-- @sqlite-only CREATE TRIGGER trg_apr_clock_upd BEFORE UPDATE ON approval_request
-- @sqlite-only WHEN (NEW.first_approved_at IS NOT OLD.first_approved_at AND NEW.first_approved_at IS NOT NULL AND NOT COALESCE(NEW.first_approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.first_approved_at) IS NEW.first_approved_at AND substr(NEW.first_approved_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.first_approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only   OR (NEW.second_approved_at IS NOT OLD.second_approved_at AND NEW.second_approved_at IS NOT NULL AND NOT COALESCE(NEW.second_approved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.second_approved_at) IS NEW.second_approved_at AND substr(NEW.second_approved_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.second_approved_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only   OR (NEW.decided_at IS NOT OLD.decided_at AND NEW.decided_at IS NOT NULL AND NOT COALESCE(NEW.decided_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.decided_at) IS NEW.decided_at AND substr(NEW.decided_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.decided_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'approval_request_clock_skew'); END;

CREATE FUNCTION trg_udb_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
    t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');   -- @pg-only
BEGIN   -- @pg-only
    IF TG_OP = 'UPDATE' AND OLD.activated_at IS NOT NULL AND NEW.activated_at IS DISTINCT FROM OLD.activated_at   -- @pg-only
       AND OLD.status <> 'REVOKED' AND NEW.status <> 'PENDING' THEN   -- 终态 / 回退交给 binding_immutable   -- @pg-only
        RAISE EXCEPTION 'user_device_binding_time_immutable' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.user_device_binding'::regclass;   -- @pg-only
    IF current_user IS NOT DISTINCT FROM owner_name THEN RETURN NEW; END IF;   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        NEW.bound_at := t;   -- @pg-only
    ELSE   -- @pg-only
        IF NEW.status = 'ACTIVE' AND OLD.status = 'PENDING' THEN NEW.activated_at := t; END IF;   -- @pg-only
        IF NEW.status = 'REVOKED' AND OLD.status <> 'REVOKED' THEN NEW.revoked_at := t; END IF;   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_udb_zclock BEFORE INSERT OR UPDATE ON user_device_binding FOR EACH ROW EXECUTE FUNCTION trg_udb_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_udb_clock_ins BEFORE INSERT ON user_device_binding
-- @sqlite-only WHEN NOT COALESCE(NEW.bound_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.bound_at) IS NEW.bound_at AND substr(NEW.bound_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.bound_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'user_device_binding_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_clock_upd BEFORE UPDATE ON user_device_binding
-- @sqlite-only WHEN (NEW.activated_at IS NOT OLD.activated_at AND NEW.activated_at IS NOT NULL AND NOT COALESCE(NEW.activated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.activated_at) IS NEW.activated_at AND substr(NEW.activated_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.activated_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only   OR (NEW.revoked_at IS NOT OLD.revoked_at AND NEW.revoked_at IS NOT NULL AND NOT COALESCE(NEW.revoked_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.revoked_at) IS NEW.revoked_at AND substr(NEW.revoked_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.revoked_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'user_device_binding_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_udb_time_lock BEFORE UPDATE ON user_device_binding
-- @sqlite-only WHEN OLD.activated_at IS NOT NULL AND NEW.activated_at IS NOT OLD.activated_at AND OLD.status <> 'REVOKED' AND NEW.status <> 'PENDING'
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'user_device_binding_time_immutable'); END;

CREATE FUNCTION trg_offline_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
    t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');   -- @pg-only
BEGIN   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.offline_token'::regclass;   -- @pg-only
    IF current_user IS NOT DISTINCT FROM owner_name THEN RETURN NEW; END IF;   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        NEW.issued_at := t;   -- expires_at 仍由 ck_offline_ttl / ck_offline_max_ttl 约束在 (issued_at, issued_at + 12h]   -- @pg-only
    ELSIF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN   -- @pg-only
        NEW.revoked_at := t;   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_offline_zclock BEFORE INSERT OR UPDATE ON offline_token FOR EACH ROW EXECUTE FUNCTION trg_offline_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_offline_clock_ins BEFORE INSERT ON offline_token
-- @sqlite-only WHEN NOT COALESCE(NEW.issued_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.issued_at) IS NEW.issued_at AND substr(NEW.issued_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.issued_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'offline_token_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_offline_clock_upd BEFORE UPDATE OF revoked_at ON offline_token
-- @sqlite-only WHEN OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL AND NOT COALESCE(NEW.revoked_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.revoked_at) IS NEW.revoked_at AND substr(NEW.revoked_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.revoked_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'offline_token_clock_skew'); END;

-- ===== 设备恢复联网记录（第 11 篇纸单补录 T1 的服务端证据：offline_paper_record 引用 device_reconnect.id）=====
-- 只追加：wms_app 只有 SELECT / INSERT；UPDATE / DELETE / TRUNCATE 触发器全拦（含属主）。occurred_at 由库写，整行写入后不可改。
-- offline_jti：本次离线期间用的离线令牌，可空（离线前可能没签过令牌）；非空时必须属于同一绑定，绑定必须属于同一仓（device_reconnect_binding_mismatch）。
CREATE TABLE device_reconnect (
    id                  BIGINT       PRIMARY KEY,
    warehouse_id        BIGINT       NOT NULL,
    binding_id          BIGINT       NOT NULL,
    offline_jti         VARCHAR(64),
    occurred_at         TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),   -- UTC 整秒，库写
    CONSTRAINT fk_drc_binding FOREIGN KEY (binding_id) REFERENCES user_device_binding (id),
    CONSTRAINT fk_drc_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse (id),
    CONSTRAINT fk_drc_jti FOREIGN KEY (offline_jti) REFERENCES offline_token (jti),
    CONSTRAINT uq_drc_id_binding UNIQUE (id, binding_id),   -- 第 22 个唯一键：11 纸质补录用复合外键 (reconnect_id, binding_id) 引用，保证补录挂的绑定就是这次重连的绑定
    CONSTRAINT ck_drc_ts CHECK (occurred_at = date_trunc('second', occurred_at))  -- @pg-only
-- @sqlite-only     CONSTRAINT ck_drc_ts CHECK (occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(occurred_at) IS occurred_at AND substr(occurred_at, 12, 2) <= '23')
);
CREATE INDEX ix_drc_binding ON device_reconnect(binding_id, occurred_at);
CREATE INDEX ix_drc_jti ON device_reconnect(offline_jti) WHERE offline_jti IS NOT NULL;
CREATE FUNCTION trg_drc_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
BEGIN   -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM user_device_binding b WHERE b.id = NEW.binding_id AND b.warehouse_id = NEW.warehouse_id)   -- @pg-only
       OR (NEW.offline_jti IS NOT NULL AND NOT EXISTS (SELECT 1 FROM offline_token o WHERE o.jti = NEW.offline_jti AND o.binding_id = NEW.binding_id)) THEN   -- @pg-only
        RAISE EXCEPTION 'device_reconnect_binding_mismatch' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.device_reconnect'::regclass;   -- @pg-only
    IF current_user IS DISTINCT FROM owner_name THEN NEW.occurred_at := date_trunc('second', now() AT TIME ZONE 'UTC'); END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_drc_guard BEFORE INSERT ON device_reconnect FOR EACH ROW EXECUTE FUNCTION trg_drc_guard();  -- @pg-only
CREATE TRIGGER trg_drc_append_only BEFORE UPDATE OR DELETE ON device_reconnect FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_drc_no_truncate BEFORE TRUNCATE ON device_reconnect FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_drc_no_replace BEFORE INSERT ON device_reconnect
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM device_reconnect d WHERE d.id = NEW.id OR (d.id = NEW.id AND d.binding_id = NEW.binding_id))   -- 后一项 = uq_drc_id_binding（PK 的超集；§6.10 每个唯一键每列都要出现）
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'device_reconnect_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_drc_guard BEFORE INSERT ON device_reconnect
-- @sqlite-only WHEN NOT EXISTS (SELECT 1 FROM user_device_binding b WHERE b.id = NEW.binding_id AND b.warehouse_id = NEW.warehouse_id)
-- @sqlite-only   OR (NEW.offline_jti IS NOT NULL AND NOT EXISTS (SELECT 1 FROM offline_token o WHERE o.jti = NEW.offline_jti AND o.binding_id = NEW.binding_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'device_reconnect_binding_mismatch'); END;
-- @sqlite-only CREATE TRIGGER trg_drc_clock BEFORE INSERT ON device_reconnect
-- @sqlite-only WHEN NOT COALESCE(NEW.occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.occurred_at) IS NEW.occurred_at AND substr(NEW.occurred_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.occurred_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'device_reconnect_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_drc_no_update BEFORE UPDATE ON device_reconnect BEGIN SELECT RAISE(ABORT, 'append_only_violation: device_reconnect'); END;
-- @sqlite-only CREATE TRIGGER trg_drc_no_delete BEFORE DELETE ON device_reconnect BEGIN SELECT RAISE(ABORT, 'append_only_violation: device_reconnect'); END;


-- ===== 12 篇 no-REPLACE 扩到全部去重 / 序号类唯一键（00 §6.10）+ 键列不可改 + 计数器只增 =====
-- 权限映射 / 码表 / 凭证的唯一键都在做去重：SQLite REPLACE 会先删旧行（DELETE 触发器不触发），所以每个唯一键都要在 WHEN 里。
-- @sqlite-only CREATE TRIGGER trg_sys_role_no_replace BEFORE INSERT ON sys_role
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_role r WHERE (r.id = NEW.id) OR (r.code = NEW.code))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_role_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_permission_no_replace BEFORE INSERT ON sys_permission
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_permission p WHERE (p.id = NEW.id) OR (p.code = NEW.code))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_permission_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_role_no_replace BEFORE INSERT ON sys_user_role
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_user_role m WHERE (m.user_id = NEW.user_id AND m.role_id = NEW.role_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_role_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_role_perm_no_replace BEFORE INSERT ON sys_role_perm
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_role_perm m WHERE (m.role_id = NEW.role_id AND m.perm_id = NEW.perm_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_role_perm_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_warehouse_no_replace BEFORE INSERT ON sys_user_warehouse
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM sys_user_warehouse m WHERE (m.user_id = NEW.user_id AND m.warehouse_id = NEW.warehouse_id))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_warehouse_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_api_credential_no_replace BEFORE INSERT ON api_credential
-- @sqlite-only WHEN EXISTS (SELECT 1 FROM api_credential c WHERE (c.id = NEW.id) OR (c.api_key = NEW.api_key))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'api_credential_duplicate'); END;
-- 键列不可改（改键 = 绕过去重/改写映射；要换键只能新插一行）。PG 用一个通用函数，列名走触发器参数；PG 触发器统一命名 trg_0_key_lock（按名排序最先触发，报错稳定为 key_immutable）。
CREATE FUNCTION trg_12_key_lock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE c text;                                                                                              -- @pg-only
BEGIN                                                                                                        -- @pg-only
    FOREACH c IN ARRAY TG_ARGV LOOP                                                                          -- @pg-only
        IF to_jsonb(NEW) -> c IS DISTINCT FROM to_jsonb(OLD) -> c THEN                                       -- @pg-only
            RAISE EXCEPTION '%_key_immutable', TG_TABLE_NAME USING ERRCODE = '23514', DETAIL = c;            -- @pg-only
        END IF;                                                                                              -- @pg-only
    END LOOP;                                                                                                -- @pg-only
    RETURN NEW;                                                                                              -- @pg-only
END $$;                                                                                                      -- @pg-only
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_user FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'username');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_user_key_lock BEFORE UPDATE ON sys_user WHEN NEW.id IS NOT OLD.id OR NEW.username IS NOT OLD.username BEGIN SELECT RAISE(ABORT, 'sys_user_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'code', 'approval_type', 'target_type', 'target_id');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_approval_request_key_lock BEFORE UPDATE ON approval_request WHEN NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code OR NEW.approval_type IS NOT OLD.approval_type OR NEW.target_type IS NOT OLD.target_type OR NEW.target_id IS NOT OLD.target_id BEGIN SELECT RAISE(ABORT, 'approval_request_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON user_device_binding FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'device_instance_id');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_user_device_binding_key_lock BEFORE UPDATE ON user_device_binding WHEN NEW.id IS NOT OLD.id OR NEW.device_instance_id IS NOT OLD.device_instance_id BEGIN SELECT RAISE(ABORT, 'user_device_binding_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON offline_token FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'jti');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_offline_token_key_lock BEFORE UPDATE ON offline_token WHEN NEW.id IS NOT OLD.id OR NEW.jti IS NOT OLD.jti BEGIN SELECT RAISE(ABORT, 'offline_token_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_role FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'code');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_role_key_lock BEFORE UPDATE ON sys_role WHEN NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'sys_role_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_permission FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'code');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_permission_key_lock BEFORE UPDATE ON sys_permission WHEN NEW.id IS NOT OLD.id OR NEW.code IS NOT OLD.code BEGIN SELECT RAISE(ABORT, 'sys_permission_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_user_role FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('user_id', 'role_id');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_user_role_key_lock BEFORE UPDATE ON sys_user_role WHEN NEW.user_id IS NOT OLD.user_id OR NEW.role_id IS NOT OLD.role_id BEGIN SELECT RAISE(ABORT, 'sys_user_role_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_role_perm FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('role_id', 'perm_id');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_role_perm_key_lock BEFORE UPDATE ON sys_role_perm WHEN NEW.role_id IS NOT OLD.role_id OR NEW.perm_id IS NOT OLD.perm_id BEGIN SELECT RAISE(ABORT, 'sys_role_perm_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON sys_user_warehouse FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('user_id', 'warehouse_id');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_sys_user_warehouse_key_lock BEFORE UPDATE ON sys_user_warehouse WHEN NEW.user_id IS NOT OLD.user_id OR NEW.warehouse_id IS NOT OLD.warehouse_id BEGIN SELECT RAISE(ABORT, 'sys_user_warehouse_key_immutable'); END;
CREATE TRIGGER trg_0_key_lock BEFORE UPDATE ON api_credential FOR EACH ROW EXECUTE FUNCTION trg_12_key_lock('id', 'api_key');  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_api_credential_key_lock BEFORE UPDATE ON api_credential WHEN NEW.id IS NOT OLD.id OR NEW.api_key IS NOT OLD.api_key BEGIN SELECT RAISE(ABORT, 'api_credential_key_immutable'); END;
-- sys_user 行承载 perm_version 计数器：删行 / 清空会让同 id 重建后版本回到 1（旧离线令牌复活），所有角色（含属主）都拒；停用走 status。
CREATE TRIGGER trg_user_no_delete BEFORE DELETE ON sys_user FOR EACH ROW EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
CREATE TRIGGER trg_user_no_truncate BEFORE TRUNCATE ON sys_user FOR EACH STATEMENT EXECUTE FUNCTION trg_no_delete_12();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_user_no_delete BEFORE DELETE ON sys_user BEGIN SELECT RAISE(ABORT, 'append_only_violation: sys_user'); END;
-- 计数器只增：approval_request.version（乐观锁）；sys_user.perm_version 已由 trg_user_perm_ver 管；audit_log.node_seq 只追加。
CREATE FUNCTION trg_apr_version() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN IF NEW.version < OLD.version THEN RAISE EXCEPTION 'approval_request_version_regress' USING ERRCODE = '23514'; END IF; RETURN NEW; END $$;  -- @pg-only
CREATE TRIGGER trg_apr_version BEFORE UPDATE ON approval_request FOR EACH ROW EXECUTE FUNCTION trg_apr_version();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_apr_version BEFORE UPDATE ON approval_request WHEN NEW.version < OLD.version BEGIN SELECT RAISE(ABORT, 'approval_request_version_regress'); END;

-- ===== 用户停用 + 权限映射只经函数变更（第 12 篇 §权限变更；00 §6.6.4）=====
-- 用户只停用不物删（trg_user_no_delete）；status / deleted_at 一变，perm_version 由库 +1，已签发的令牌联网即失效。
-- 登录名 username 唯一（uq_user_name）、不可改（trg_0_key_lock）、行不可删 → 永不释放、不可复用。
CREATE FUNCTION trg_user_status_bump() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
BEGIN                                                                                                        -- @pg-only
    IF NEW.status IS DISTINCT FROM OLD.status OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN         -- @pg-only
        NEW.perm_version := GREATEST(NEW.perm_version, OLD.perm_version + 1);                                -- @pg-only
    END IF;                                                                                                  -- @pg-only
    RETURN NEW;                                                                                              -- @pg-only
END $$;                                                                                                      -- @pg-only
CREATE TRIGGER trg_user_status_bump BEFORE UPDATE ON sys_user FOR EACH ROW EXECUTE FUNCTION trg_user_status_bump();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_user_status_bump AFTER UPDATE OF status, deleted_at ON sys_user
-- @sqlite-only WHEN (NEW.status IS NOT OLD.status OR NEW.deleted_at IS NOT OLD.deleted_at) AND NEW.perm_version <= OLD.perm_version
-- @sqlite-only BEGIN UPDATE sys_user SET perm_version = OLD.perm_version + 1 WHERE id = NEW.id; END;

-- PG（中心）：wms_app 对 sys_user_role / sys_role_perm / sys_user_warehouse 只留 SELECT；增删只经下面 6 个 SECURITY DEFINER 函数
-- （属主 wms_rbac_owner：NOLOGIN、非超级用户，只有必要的权限）。同一事务里：
--   调用人取自会话变量 wms.actor_id（未设 → rbac_actor_unset），且会话里的 wms.actor_perm_version 必须等于库里当前值（令牌签发后权限变过 → rbac_actor_stale）；
--   调用人持有对应权限点且 ACTIVE；不能改自己（含给自己所在角色加减权限）；改映射；受影响用户 perm_version +1；
--   写 audit_log：id、node_seq 由库分配（应用不能传），node_id 取会话变量 wms.node_id（未设即拒）；
--   审计单次消费：同一 (权限点, 目标, 请求号 p_request_id → trace_id) 只能成功一次，重放 → audit_log_rbac_replay（uq_audit_rbac_once 兜底）。
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_rbac_owner') THEN CREATE ROLE wms_rbac_owner NOLOGIN NOSUPERUSER NOINHERIT; END IF; END $$;  -- @pg-only
GRANT USAGE ON SCHEMA public TO wms_rbac_owner;                                                              -- @pg-only
GRANT SELECT ON sys_user, sys_permission, sys_role TO wms_rbac_owner;                                       -- @pg-only
GRANT UPDATE (perm_version) ON sys_user TO wms_rbac_owner;                                                   -- @pg-only
GRANT SELECT, INSERT, DELETE ON sys_user_role, sys_role_perm, sys_user_warehouse TO wms_rbac_owner;         -- @pg-only
GRANT SELECT (id, node_id, node_seq, action, target_type, target_id, trace_id), INSERT ON audit_log TO wms_rbac_owner;  -- @pg-only
REVOKE INSERT, UPDATE ON sys_user_role, sys_role_perm, sys_user_warehouse FROM wms_app;                      -- @pg-only
CREATE UNIQUE INDEX uq_audit_rbac_once ON audit_log (action, target_type, target_id, trace_id) WHERE action LIKE 'sys.%';  -- @pg-only
CREATE FUNCTION public.rbac_mapping_change(p_kind text, p_op text, p_a bigint, p_b bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$                                           -- @pg-only
DECLARE perm text; n bigint; bumped bigint; actor bigint; node int; tgt text; aid bigint; aseq bigint;         -- @pg-only
BEGIN                                                                                                          -- @pg-only
    perm := 'sys.' || CASE p_kind WHEN 'USER_ROLE' THEN 'user.role' WHEN 'ROLE_PERM' THEN 'role.perm' WHEN 'USER_WAREHOUSE' THEN 'user.warehouse' END  -- @pg-only
            || '.' || CASE p_op WHEN 'GRANT' THEN 'grant' WHEN 'REVOKE' THEN 'revoke' END;                     -- @pg-only
    IF perm IS NULL OR p_a IS NULL OR p_b IS NULL OR p_request_id IS NULL OR length(p_request_id) NOT BETWEEN 1 AND 32 THEN  -- @pg-only
        RAISE EXCEPTION 'rbac_change_invalid' USING ERRCODE = '22023'; END IF;                                 -- @pg-only
    actor := NULLIF(current_setting('wms.actor_id', true), '')::bigint;                         /*ACTOR*/      -- @pg-only
    node := NULLIF(current_setting('wms.node_id', true), '')::int;                                             -- @pg-only
    IF actor IS NULL OR node IS NULL OR node <= 0 THEN RAISE EXCEPTION 'rbac_actor_unset' USING ERRCODE = '28000'; END IF;  -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM sys_user u WHERE u.id = actor                                   /*STALECHK*/   -- @pg-only
                   AND u.perm_version::text = current_setting('wms.actor_perm_version', true)) THEN            -- @pg-only
        RAISE EXCEPTION 'rbac_actor_stale' USING ERRCODE = '28000'; END IF;                                    -- @pg-only
    IF NOT EXISTS (SELECT 1 FROM sys_user u JOIN sys_user_role ur ON ur.user_id = u.id JOIN sys_role_perm rp ON rp.role_id = ur.role_id  -- @pg-only
                   JOIN sys_permission p ON p.id = rp.perm_id                                                  -- @pg-only
                   WHERE u.id = actor AND u.status = 'ACTIVE' AND u.deleted_at IS NULL AND p.code = perm) THEN  /*PERMCHK*/  -- @pg-only
        RAISE EXCEPTION 'rbac_perm_not_held' USING ERRCODE = '42501', DETAIL = perm;                           -- @pg-only
    END IF;                                                                                                    -- @pg-only
    IF (p_kind <> 'ROLE_PERM' AND p_a = actor)                                                 /*SELFCHK*/     -- @pg-only
       OR (p_kind = 'ROLE_PERM' AND EXISTS (SELECT 1 FROM sys_user_role WHERE user_id = actor AND role_id = p_a)) THEN  -- @pg-only
        RAISE EXCEPTION 'rbac_self_change' USING ERRCODE = '42501';                                            -- @pg-only
    END IF;                                                                                                    -- @pg-only
    tgt := p_a::text || ':' || p_b::text;                                                                      -- @pg-only
    IF EXISTS (SELECT 1 FROM audit_log WHERE action = perm AND target_type = 'SYS_' || p_kind  /*ONCECHK*/     -- @pg-only
               AND target_id = tgt AND trace_id = p_request_id) THEN                                           -- @pg-only
        RAISE EXCEPTION 'audit_log_rbac_replay' USING ERRCODE = '23505'; END IF;                               -- @pg-only
    IF p_kind = 'USER_ROLE' THEN                                                                               -- @pg-only
        IF p_op = 'GRANT' THEN INSERT INTO sys_user_role (user_id, role_id) VALUES (p_a, p_b);                 -- @pg-only
        ELSE DELETE FROM sys_user_role WHERE user_id = p_a AND role_id = p_b; GET DIAGNOSTICS n = ROW_COUNT;     -- @pg-only
             IF n = 0 THEN RAISE EXCEPTION 'sys_user_role_absent' USING ERRCODE = '23514'; END IF; END IF;      -- @pg-only
        UPDATE sys_user SET perm_version = perm_version + 1 WHERE id = p_a;                       /*BUMP*/     -- @pg-only
    ELSIF p_kind = 'USER_WAREHOUSE' THEN                                                                       -- @pg-only
        IF p_op = 'GRANT' THEN INSERT INTO sys_user_warehouse (user_id, warehouse_id) VALUES (p_a, p_b);       -- @pg-only
        ELSE DELETE FROM sys_user_warehouse WHERE user_id = p_a AND warehouse_id = p_b; GET DIAGNOSTICS n = ROW_COUNT;  -- @pg-only
             IF n = 0 THEN RAISE EXCEPTION 'sys_user_warehouse_absent' USING ERRCODE = '23514'; END IF; END IF; -- @pg-only
        UPDATE sys_user SET perm_version = perm_version + 1 WHERE id = p_a;                                    -- @pg-only
    ELSE                                                                                                       -- @pg-only
        IF p_op = 'GRANT' THEN INSERT INTO sys_role_perm (role_id, perm_id) VALUES (p_a, p_b);                 -- @pg-only
        ELSE DELETE FROM sys_role_perm WHERE role_id = p_a AND perm_id = p_b; GET DIAGNOSTICS n = ROW_COUNT;    -- @pg-only
             IF n = 0 THEN RAISE EXCEPTION 'sys_role_perm_absent' USING ERRCODE = '23514'; END IF; END IF;      -- @pg-only
        UPDATE sys_user SET perm_version = perm_version + 1 WHERE id IN (SELECT user_id FROM sys_user_role WHERE role_id = p_a);  -- @pg-only
    END IF;                                                                                                    -- @pg-only
    GET DIAGNOSTICS bumped = ROW_COUNT;                                                                        -- @pg-only
    PERFORM pg_advisory_xact_lock(hashtext('audit_log.id'));                                                   -- @pg-only
    SELECT coalesce(max(id), 0) + 1 INTO aid FROM audit_log;                                                   -- @pg-only
    SELECT coalesce(max(node_seq), 0) + 1 INTO aseq FROM audit_log WHERE node_id = node;                       -- @pg-only
    INSERT INTO audit_log (id, actor_id, action, target_type, target_id, trace_id, reason, node_id, node_seq)  /*AUDIT*/  -- @pg-only
    VALUES (aid, actor, perm, 'SYS_' || p_kind, tgt, p_request_id, p_reason, node, aseq);                      -- @pg-only
    RETURN bumped;                                                                                             -- @pg-only
END $$;                                                                                                        -- @pg-only
ALTER FUNCTION public.rbac_mapping_change(text, text, bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.rbac_mapping_change(text, text, bigint, bigint, text, text) FROM PUBLIC;      -- @pg-only
CREATE FUNCTION public.sys_user_role_grant(p_user_id bigint, p_role_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('USER_ROLE', 'GRANT', p_user_id, p_role_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_user_role_grant(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_user_role_grant(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_user_role_grant(bigint, bigint, text, text) TO wms_app;  -- @pg-only
CREATE FUNCTION public.sys_user_role_revoke(p_user_id bigint, p_role_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('USER_ROLE', 'REVOKE', p_user_id, p_role_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_user_role_revoke(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_user_role_revoke(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_user_role_revoke(bigint, bigint, text, text) TO wms_app;  -- @pg-only
CREATE FUNCTION public.sys_role_perm_grant(p_role_id bigint, p_perm_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('ROLE_PERM', 'GRANT', p_role_id, p_perm_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_role_perm_grant(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_role_perm_grant(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_role_perm_grant(bigint, bigint, text, text) TO wms_app;  -- @pg-only
CREATE FUNCTION public.sys_role_perm_revoke(p_role_id bigint, p_perm_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('ROLE_PERM', 'REVOKE', p_role_id, p_perm_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_role_perm_revoke(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_role_perm_revoke(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_role_perm_revoke(bigint, bigint, text, text) TO wms_app;  -- @pg-only
CREATE FUNCTION public.sys_user_warehouse_grant(p_user_id bigint, p_warehouse_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('USER_WAREHOUSE', 'GRANT', p_user_id, p_warehouse_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_user_warehouse_grant(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_user_warehouse_grant(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_user_warehouse_grant(bigint, bigint, text, text) TO wms_app;  -- @pg-only
CREATE FUNCTION public.sys_user_warehouse_revoke(p_user_id bigint, p_warehouse_id bigint, p_request_id text, p_reason text) RETURNS bigint  -- @pg-only
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp                                    -- @pg-only
AS $$ SELECT public.rbac_mapping_change('USER_WAREHOUSE', 'REVOKE', p_user_id, p_warehouse_id, p_request_id, p_reason) $$;  -- @pg-only
ALTER FUNCTION public.sys_user_warehouse_revoke(bigint, bigint, text, text) OWNER TO wms_rbac_owner;  -- @pg-only
REVOKE ALL ON FUNCTION public.sys_user_warehouse_revoke(bigint, bigint, text, text) FROM PUBLIC;  -- @pg-only
GRANT EXECUTE ON FUNCTION public.sys_user_warehouse_revoke(bigint, bigint, text, text) TO wms_app;  -- @pg-only
-- SQLite（边缘库）：三张映射表只读。权限变更只在中心 PG 做，经同步下发。应用连接上任何直接 INSERT / UPDATE / DELETE 都拒（<表>_edge_read_only → 40312）。
-- 同步落库只经同步进程自己的连接：它在连接上注册 edge_sync_active() = 1（应用连接 connect_main() 注册为 0）。
-- 这个开关只存在于连接里，库里没有任何表 / 列 / 标志可以被 SQL 改写，应用连接用 SQL 打不开；没注册该函数的连接写映射时报 no such function，同样失败（失败即关）。
-- 同步过程不在边缘本地递增 perm_version、不写审计：sys_user.perm_version 与 audit_log 都以中心为准随同步下发。
-- @sqlite-only CREATE TRIGGER trg_sys_user_role_edge_ro_ins BEFORE INSERT ON sys_user_role WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_role_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_role_edge_ro_upd BEFORE UPDATE ON sys_user_role WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_role_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_role_edge_ro_del BEFORE DELETE ON sys_user_role WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_role_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_role_perm_edge_ro_ins BEFORE INSERT ON sys_role_perm WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_role_perm_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_role_perm_edge_ro_upd BEFORE UPDATE ON sys_role_perm WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_role_perm_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_role_perm_edge_ro_del BEFORE DELETE ON sys_role_perm WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_role_perm_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_warehouse_edge_ro_ins BEFORE INSERT ON sys_user_warehouse WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_warehouse_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_warehouse_edge_ro_upd BEFORE UPDATE ON sys_user_warehouse WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_warehouse_edge_read_only'); END;
-- @sqlite-only CREATE TRIGGER trg_sys_user_warehouse_edge_ro_del BEFORE DELETE ON sys_user_warehouse WHEN NOT edge_sync_active() BEGIN SELECT RAISE(ABORT, 'sys_user_warehouse_edge_read_only'); END;

-- 授权（PG）
-- docs/12 新表 wms_app 最小授权：不给 DELETE/TRUNCATE；离线令牌只能写吊销时间；审批只能改决策相关列
GRANT SELECT, INSERT ON user_device_binding TO wms_app;                                                       -- @pg-only
GRANT UPDATE (status, approval_id, activated_at, revoked_at, revoked_by, revoke_reason) ON user_device_binding TO wms_app;  -- @pg-only
GRANT SELECT, INSERT ON offline_token TO wms_app;                                                             -- @pg-only
GRANT UPDATE (revoked_at) ON offline_token TO wms_app;                                                        -- @pg-only
GRANT SELECT, INSERT ON approval_request TO wms_app;                                                          -- @pg-only
GRANT UPDATE (status, first_approver_id, first_approver_role, first_approved_at, second_approver_id, second_approver_role,  -- @pg-only
    second_approved_at, decided_at, reject_reason, result_ref, version) ON approval_request TO wms_app;       -- @pg-only
GRANT SELECT, INSERT ON device_reconnect TO wms_app;                                                          -- @pg-only

-- ===== 第 12 篇时间加固第二轮（镜鉴实测：B3 遗漏的 4 个时间列；00 §6.8）=====
-- 第一轮覆盖 approval_request / user_device_binding / offline_token / device_reconnect 四张表；
-- 本篇自有表里 sys_user.created_at / sys_user.last_login_at / sys_user.deleted_at / api_credential.last_used_at
-- 仍可被 wms_app 直接倒填（实测：传 '2000-01-01 00:00:00' 原样落库），此处补齐。
-- PG：非属主写入由库覆盖为 date_trunc('second', now() AT TIME ZONE 'UTC')；表属主（迁移/种子角色）豁免，同第一轮 *_zclock 口径。
-- SQLite：不能改 NEW，改为拒收——与 now 相差 > 300 s（*_clock_skew）、或非法整秒格式（ck_user_ts / ck_api_ts）。
-- 两库同一条口径：INSERT 时 last_login_at / deleted_at / last_used_at 必须为 NULL（新用户没登录过、不是停用态、凭证没用过）。
CREATE FUNCTION trg_user_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
    t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');   -- @pg-only
BEGIN   -- @pg-only
    IF TG_OP = 'INSERT' AND (NEW.last_login_at IS NOT NULL OR NEW.deleted_at IS NOT NULL) THEN   -- @pg-only
        RAISE EXCEPTION 'sys_user_insert_time_set' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.sys_user'::regclass;   -- @pg-only
    IF current_user IS NOT DISTINCT FROM owner_name THEN RETURN NEW; END IF;   -- @pg-only
    IF TG_OP = 'INSERT' THEN   -- @pg-only
        NEW.created_at := t;   -- @pg-only
        RETURN NEW;   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN   -- @pg-only
        RAISE EXCEPTION 'sys_user_created_at_immutable' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    IF NEW.last_login_at IS DISTINCT FROM OLD.last_login_at THEN NEW.last_login_at := t; END IF;   -- @pg-only
    IF NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN   -- @pg-only
        IF NEW.deleted_at IS NULL THEN   -- @pg-only
            RAISE EXCEPTION 'sys_user_deleted_at_immutable' USING ERRCODE = '23514';   -- 停用是事实，记录不可清（恢复启用只改 status）   -- @pg-only
        END IF;   -- @pg-only
        NEW.deleted_at := t;   -- @pg-only
    END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_user_zclock BEFORE INSERT OR UPDATE ON sys_user FOR EACH ROW EXECUTE FUNCTION trg_user_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_user_ins_time_set BEFORE INSERT ON sys_user
-- @sqlite-only WHEN NEW.last_login_at IS NOT NULL OR NEW.deleted_at IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_insert_time_set'); END;
-- @sqlite-only CREATE TRIGGER trg_user_clock_ins BEFORE INSERT ON sys_user
-- @sqlite-only WHEN NOT COALESCE(NEW.created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.created_at) IS NEW.created_at AND substr(NEW.created_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.created_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_clock_skew'); END;
-- @sqlite-only CREATE TRIGGER trg_user_created_immutable BEFORE UPDATE ON sys_user
-- @sqlite-only WHEN NEW.created_at IS NOT OLD.created_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_created_at_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_user_deleted_immutable BEFORE UPDATE ON sys_user
-- @sqlite-only WHEN NEW.deleted_at IS NOT OLD.deleted_at AND NEW.deleted_at IS NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_deleted_at_immutable'); END;
-- @sqlite-only CREATE TRIGGER trg_user_clock_upd BEFORE UPDATE ON sys_user
-- @sqlite-only WHEN (NEW.last_login_at IS NOT OLD.last_login_at AND NEW.last_login_at IS NOT NULL AND NOT COALESCE(NEW.last_login_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.last_login_at) IS NEW.last_login_at AND substr(NEW.last_login_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.last_login_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only   OR (NEW.deleted_at IS NOT OLD.deleted_at AND NEW.deleted_at IS NOT NULL AND NOT COALESCE(NEW.deleted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.deleted_at) IS NEW.deleted_at AND substr(NEW.deleted_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.deleted_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sys_user_clock_skew'); END;

CREATE FUNCTION trg_api_zclock() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$  -- @pg-only
DECLARE   -- @pg-only
    owner_name name;   -- @pg-only
    t timestamp := date_trunc('second', now() AT TIME ZONE 'UTC');   -- @pg-only
BEGIN   -- @pg-only
    IF TG_OP = 'INSERT' AND NEW.last_used_at IS NOT NULL THEN   -- @pg-only
        RAISE EXCEPTION 'api_credential_insert_time_set' USING ERRCODE = '23514';   -- @pg-only
    END IF;   -- @pg-only
    SELECT r.rolname INTO owner_name FROM pg_catalog.pg_roles r JOIN pg_catalog.pg_class c ON c.relowner = r.oid   -- @pg-only
     WHERE c.oid = 'public.api_credential'::regclass;   -- @pg-only
    IF current_user IS NOT DISTINCT FROM owner_name THEN RETURN NEW; END IF;   -- @pg-only
    IF TG_OP = 'UPDATE' AND NEW.last_used_at IS DISTINCT FROM OLD.last_used_at THEN NEW.last_used_at := t; END IF;   -- @pg-only
    RETURN NEW;   -- @pg-only
END $$;   -- @pg-only
CREATE TRIGGER trg_api_zclock BEFORE INSERT OR UPDATE ON api_credential FOR EACH ROW EXECUTE FUNCTION trg_api_zclock();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_api_ins_time_set BEFORE INSERT ON api_credential
-- @sqlite-only WHEN NEW.last_used_at IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'api_credential_insert_time_set'); END;
-- @sqlite-only CREATE TRIGGER trg_api_clock_upd BEFORE UPDATE ON api_credential
-- @sqlite-only WHEN NEW.last_used_at IS NOT OLD.last_used_at AND NEW.last_used_at IS NOT NULL AND NOT COALESCE(NEW.last_used_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND datetime(NEW.last_used_at) IS NEW.last_used_at AND substr(NEW.last_used_at, 12, 2) <= '23' AND abs(CAST(strftime('%s', NEW.last_used_at) AS INTEGER) - CAST(strftime('%s', 'now') AS INTEGER)) <= 300, 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'api_credential_clock_skew'); END;
