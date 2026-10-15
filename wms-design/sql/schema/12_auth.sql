-- -----------------------------------------------------------------------------
-- 权限（RBAC + 数据权限）
-- -----------------------------------------------------------------------------

CREATE TABLE sys_user (
    id              BIGINT       PRIMARY KEY,
    username        VARCHAR(64)  NOT NULL,
    password_hash   VARCHAR(256) NOT NULL,
    real_name       VARCHAR(64),
    phone           VARCHAR(32),
    mp_openid       VARCHAR(64),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    last_login_at   TIMESTAMP,
    created_at      TIMESTAMP    NOT NULL DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC')),   -- 00 §6.8：UTC 整秒
    deleted_at      TIMESTAMP,
    CONSTRAINT uq_user_name UNIQUE (username)
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

CREATE TABLE sys_user_role     (user_id BIGINT NOT NULL, role_id BIGINT NOT NULL, PRIMARY KEY(user_id, role_id),
    CONSTRAINT fk_ur_user FOREIGN KEY (user_id) REFERENCES sys_user (id), CONSTRAINT fk_ur_role FOREIGN KEY (role_id) REFERENCES sys_role (id));
CREATE TABLE sys_role_perm     (role_id BIGINT NOT NULL, perm_id BIGINT NOT NULL, PRIMARY KEY(role_id, perm_id),
    CONSTRAINT fk_rp_role FOREIGN KEY (role_id) REFERENCES sys_role (id), CONSTRAINT fk_rp_perm FOREIGN KEY (perm_id) REFERENCES sys_permission (id));
CREATE TABLE sys_user_warehouse(user_id BIGINT NOT NULL, warehouse_id BIGINT NOT NULL, PRIMARY KEY(user_id, warehouse_id),
    CONSTRAINT fk_uw_user FOREIGN KEY (user_id) REFERENCES sys_user (id), CONSTRAINT fk_uw_wh FOREIGN KEY (warehouse_id) REFERENCES warehouse (id));

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
GRANT SELECT, INSERT, UPDATE ON sys_user, sys_role, sys_permission, sys_role_perm, sys_user_role, sys_user_warehouse, api_credential TO wms_app;  -- @pg-only
-- Doro 裁定：audit_log.actor_id → sys_user(id)。SQLite 由 11 写进 CREATE TABLE；PG 在 sys_user 建好后由此处补（不搬文件、不改加载顺序）
ALTER TABLE audit_log ADD CONSTRAINT fk_audit_actor FOREIGN KEY (actor_id) REFERENCES sys_user (id);  -- @pg-only
