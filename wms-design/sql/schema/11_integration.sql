-- -----------------------------------------------------------------------------
-- 幂等 / 集成 / 审计
-- -----------------------------------------------------------------------------

CREATE TABLE idempotency_record (
    idem_key     VARCHAR(80)  PRIMARY KEY,
    req_hash     VARCHAR(64)  NOT NULL,
    response     TEXT         NOT NULL,
    status_code  INT          NOT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- 一律存 UTC（P1）
    expires_at   TIMESTAMP    NOT NULL                -- UTC；写入后只许往后改（trg_idem_expiry_fwd，P2）
-- @sqlite-only     -- 小赵 S1：SQLite 不约束时间类型，'garbage'、T 格式、整数都能写进去，按文本比较永远清不掉；限定为 'YYYY-MM-DD HH:MM:SS' 且是真实日期时间
-- @sqlite-only     , CONSTRAINT ck_idem_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) IS NOT NULL AND time(created_at) IS NOT NULL AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8) AND substr(created_at, 12, 2) <= '23') AND (typeof(expires_at) = 'text' AND length(expires_at) = 19 AND expires_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(expires_at) IS NOT NULL AND time(expires_at) IS NOT NULL AND date(expires_at) = substr(expires_at, 1, 10) AND time(expires_at) = substr(expires_at, 12, 8) AND substr(expires_at, 12, 2) <= '23'))
);
CREATE INDEX ix_idem_exp ON idempotency_record(expires_at);

CREATE TABLE inbound_message (
    id              BIGINT       PRIMARY KEY,
    source          VARCHAR(24)  NOT NULL,
    biz_type        VARCHAR(32)  NOT NULL,
    external_no     VARCHAR(64)  NOT NULL,
    payload         TEXT         NOT NULL,
    payload_sha     VARCHAR(64)  NOT NULL,
    status          VARCHAR(16)  NOT NULL DEFAULT 'RECEIVED',
    retry_count     SMALLINT     NOT NULL DEFAULT 0,
    next_retry_at   TIMESTAMP,
    error           VARCHAR(512),
    received_at     TIMESTAMP    NOT NULL DEFAULT now(),
    processed_at    TIMESTAMP,
    CONSTRAINT uq_in_msg UNIQUE (source, biz_type, external_no)
);
CREATE INDEX ix_in_msg_retry ON inbound_message(status, next_retry_at);

CREATE TABLE outbox_event (
    id              BIGINT       PRIMARY KEY,
    topic           VARCHAR(64)  NOT NULL,
    biz_key         VARCHAR(64)  NOT NULL,
    payload         TEXT         NOT NULL,
    headers         TEXT,
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    retry_count     SMALLINT     NOT NULL DEFAULT 0,
    next_retry_at   TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC
    last_error      VARCHAR(512),
    created_at      TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),   -- UTC
    sent_at         TIMESTAMP,                          -- UTC；写入后只许往后改（P2）
    CONSTRAINT ck_outbox_sent CHECK (status <> 'SENT' OR sent_at IS NOT NULL)   -- P3
-- @sqlite-only     , CONSTRAINT ck_outbox_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) IS NOT NULL AND time(created_at) IS NOT NULL AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8) AND substr(created_at, 12, 2) <= '23') AND (typeof(next_retry_at) = 'text' AND length(next_retry_at) = 19 AND next_retry_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(next_retry_at) IS NOT NULL AND time(next_retry_at) IS NOT NULL AND date(next_retry_at) = substr(next_retry_at, 1, 10) AND time(next_retry_at) = substr(next_retry_at, 12, 8) AND substr(next_retry_at, 12, 2) <= '23') AND (sent_at IS NULL OR (typeof(sent_at) = 'text' AND length(sent_at) = 19 AND sent_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(sent_at) IS NOT NULL AND time(sent_at) IS NOT NULL AND date(sent_at) = substr(sent_at, 1, 10) AND time(sent_at) = substr(sent_at, 12, 8) AND substr(sent_at, 12, 2) <= '23')))   -- 小赵 S1
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
CREATE INDEX ix_outbox_bizkey  ON outbox_event(biz_key, id);   -- 同键串行发送

-- 小赵 Q2：去重记录与 outbox 只能清理"已过期 / 已投递且过保留期"的行（两库触发器，条件与 purge_expired() 一致）
CREATE FUNCTION trg_purge_guard() RETURNS trigger LANGUAGE plpgsql AS $$                                   -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'TRUNCATE' THEN RAISE EXCEPTION 'purge_not_allowed: %', TG_TABLE_NAME USING ERRCODE = '42501'; END IF;  -- @pg-only
    IF TG_TABLE_NAME = 'idempotency_record' THEN                                                              -- @pg-only
        IF NOT COALESCE(OLD.expires_at < (now() AT TIME ZONE 'UTC'), false) THEN                                                            -- @pg-only
            RAISE EXCEPTION 'purge_not_allowed: idempotency_record' USING ERRCODE = '42501';                 -- @pg-only
        END IF;                                                                                               -- @pg-only
    ELSIF NOT COALESCE(OLD.status = 'SENT' AND OLD.sent_at < (now() AT TIME ZONE 'UTC') - interval '7 days', false) THEN   -- outbox_event  -- @pg-only
        RAISE EXCEPTION 'purge_not_allowed: outbox_event' USING ERRCODE = '42501';                           -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN OLD;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_idem_purge_guard    BEFORE DELETE   ON idempotency_record FOR EACH ROW       EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_idem_no_truncate    BEFORE TRUNCATE ON idempotency_record FOR EACH STATEMENT EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_outbox_purge_guard  BEFORE DELETE   ON outbox_event       FOR EACH ROW       EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
CREATE TRIGGER trg_outbox_no_truncate  BEFORE TRUNCATE ON outbox_event       FOR EACH STATEMENT EXECUTE FUNCTION trg_purge_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_idem_purge_guard BEFORE DELETE ON idempotency_record WHEN NOT COALESCE(OLD.expires_at < datetime('now'), 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: idempotency_record'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_purge_guard BEFORE DELETE ON outbox_event WHEN NOT COALESCE(OLD.status = 'SENT' AND OLD.sent_at < datetime('now', '-7 days'), 0)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'purge_not_allowed: outbox_event'); END;
-- 九轮 P2：过期/投递时间写入后只许往后改，不许改早；created_at 不可改；SENT 是终态；sent_at 首次写入不得早于 created_at
CREATE FUNCTION trg_expiry_forward() RETURNS trigger LANGUAGE plpgsql AS $$                                -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN                                                    -- @pg-only
        RAISE EXCEPTION 'expiry_backdate: created_at' USING ERRCODE = '42501'; END IF;                        -- @pg-only
    IF TG_TABLE_NAME = 'idempotency_record' THEN                                                              -- @pg-only
        IF NEW.expires_at < OLD.expires_at THEN                                                               -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: expires_at' USING ERRCODE = '42501'; END IF;                    -- @pg-only
    ELSE                                                                                                      -- @pg-only
        -- R1：变成 SENT 的那次写入，sent_at 必须是当前 UTC 时间（容差 5 秒）                                    -- @pg-only
        IF NEW.status = 'SENT' AND OLD.status <> 'SENT'                                                       -- @pg-only
           AND abs(extract(epoch FROM NEW.sent_at - (now() AT TIME ZONE 'UTC'))) > 5 THEN                     -- @pg-only
            RAISE EXCEPTION 'sent_at_not_now' USING ERRCODE = '42501'; END IF;                                -- @pg-only
        IF OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR NEW.sent_at < OLD.sent_at) THEN                -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: sent_at' USING ERRCODE = '42501'; END IF;                       -- @pg-only
        IF OLD.sent_at IS NULL AND NEW.sent_at < OLD.created_at THEN                                          -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: sent_at' USING ERRCODE = '42501'; END IF;                       -- @pg-only
        IF OLD.status = 'SENT' AND NEW.status <> 'SENT' THEN                                                  -- @pg-only
            RAISE EXCEPTION 'expiry_backdate: status' USING ERRCODE = '42501'; END IF;                        -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_idem_expiry_fwd   BEFORE UPDATE ON idempotency_record FOR EACH ROW EXECUTE FUNCTION trg_expiry_forward();  -- @pg-only
CREATE TRIGGER trg_outbox_expiry_fwd BEFORE UPDATE ON outbox_event       FOR EACH ROW EXECUTE FUNCTION trg_expiry_forward();  -- @pg-only
-- 十六轮 R1 补洞：wms_app 只能以初始状态 PENDING（不带 sent_at）插入 outbox；SENT 只能经 UPDATE 写入（受 sent_at_not_now 约束）。
-- 种子/迁移用超级用户或迁移角色写入，不受此限
CREATE FUNCTION trg_outbox_insert_pending() RETURNS trigger LANGUAGE plpgsql AS $$                         -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF current_user = 'wms_app' AND (NEW.status IS DISTINCT FROM 'PENDING' OR NEW.sent_at IS NOT NULL) THEN   -- @pg-only
        RAISE EXCEPTION 'outbox_insert_not_pending' USING ERRCODE = '42501'; END IF;                          -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event FOR EACH ROW EXECUTE FUNCTION trg_outbox_insert_pending();  -- @pg-only
-- SQLite 没有角色：应用只能插入 PENDING（不带 sent_at）；验证脚本造 SENT 种子时临时 DROP 本触发器、写完重建（单独的种子路径）
-- @sqlite-only CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event WHEN NEW.status IS NOT 'PENDING' OR NEW.sent_at IS NOT NULL
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_insert_not_pending'); END;
-- @sqlite-only CREATE TRIGGER trg_idem_expiry_fwd BEFORE UPDATE ON idempotency_record WHEN NEW.created_at IS NOT OLD.created_at OR NEW.expires_at < OLD.expires_at
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'expiry_backdate: idempotency_record'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_expiry_fwd BEFORE UPDATE ON outbox_event WHEN NEW.created_at IS NOT OLD.created_at OR (OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR NEW.sent_at < OLD.sent_at)) OR (OLD.sent_at IS NULL AND NEW.sent_at < OLD.created_at) OR (OLD.status = 'SENT' AND NEW.status <> 'SENT')
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'expiry_backdate: outbox_event'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_sent_now BEFORE UPDATE ON outbox_event WHEN NEW.status = 'SENT' AND OLD.status <> 'SENT' AND abs(julianday(NEW.sent_at) - julianday('now')) * 86400 > 5
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'sent_at_not_now'); END;
-- SQLite REPLACE 冲突删旧行不触发 DELETE 触发器 → BEFORE INSERT 主键已存在就中止（应用把 idem_duplicate 当作"键已存在"处理，与 PG 23505 同分支）
-- @sqlite-only CREATE TRIGGER trg_idem_no_replace BEFORE INSERT ON idempotency_record WHEN EXISTS (SELECT 1 FROM idempotency_record r WHERE r.idem_key = NEW.idem_key)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'idem_duplicate'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_no_replace BEFORE INSERT ON outbox_event WHEN EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_duplicate'); END;

CREATE TABLE audit_log (
    id              BIGINT       PRIMARY KEY,
    actor_id        BIGINT,
    actor_name      VARCHAR(64),
    client_type     VARCHAR(16),
    action          VARCHAR(64)  NOT NULL,   -- outbound.cancel_after_pick / lot.expiry_override ...
    target_type     VARCHAR(32),
    target_id       VARCHAR(64),
    before_json     TEXT,
    after_json      TEXT,
    reason          VARCHAR(256),
    warehouse_id    BIGINT,
    trace_id        VARCHAR(32),
    ip              VARCHAR(45),
    occurred_at     TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_target ON audit_log(target_type, target_id, occurred_at DESC);
CREATE INDEX ix_audit_actor  ON audit_log(actor_id, occurred_at DESC);

CREATE TABLE numbering_segment (
    biz_prefix   VARCHAR(16)  NOT NULL,
    date_key     VARCHAR(8)   NOT NULL,
    next_value   BIGINT       NOT NULL,
    step         INT          NOT NULL DEFAULT 100,
    updated_at   TIMESTAMP    NOT NULL DEFAULT now(),
    PRIMARY KEY (biz_prefix, date_key)
);
-- 取号（号段预取，两库语义一致）：
--   UPDATE numbering_segment SET next_value = next_value + step WHERE biz_prefix=? AND date_key=?
--   然后 SELECT next_value - step 作为本段起点。多实例安全，不依赖 Redis 持久化。
GRANT SELECT, INSERT, UPDATE ON numbering_segment, inbound_message TO wms_app;  -- @pg-only
GRANT SELECT, INSERT, UPDATE ON idempotency_record, outbox_event TO wms_app;  -- 无 DELETE/TRUNCATE（小赵 Q2）-- @pg-only
GRANT SELECT, INSERT ON audit_log TO wms_app;  -- 只追加 -- @pg-only
