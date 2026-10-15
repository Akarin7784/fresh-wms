-- -----------------------------------------------------------------------------
-- 幂等 / 集成 / 审计
-- -----------------------------------------------------------------------------

-- ===== 第 11 篇（#6）新增：upstream_push_log / offline_paper_record =====
-- 第 11 篇 集成：上游入站推送日志（只追加，部署在中心侧；保留期 ≥ 全量备份周期，默认 7 天）。
-- 每次推送都记一行（含重推），供 00 §9.1 故障恢复按时间窗对账；对不上的进第 10 篇异常队列 FAILOVER_GAP。
CREATE TABLE upstream_push_log (
    id              BIGINT       PRIMARY KEY,
    source_system   VARCHAR(24)  NOT NULL,
    biz_type        VARCHAR(32)  NOT NULL,
    source_order_no VARCHAR(64)  NOT NULL,
    warehouse_id    BIGINT       NOT NULL DEFAULT 0,
    payload_sha     VARCHAR(64)  NOT NULL,   -- 规范化报文 SHA-256（= 业务侧 source_hash）
    payload         TEXT         NOT NULL,   -- 原文（脱敏后）
    received_at     TIMESTAMP    NOT NULL,   -- 中心接收时间（UTC）
    result_status   VARCHAR(16)  NOT NULL,   -- ACCEPTED/DUPLICATE/CONFLICT/REJECTED/FAILED
    result_code     VARCHAR(8)   NOT NULL DEFAULT '0',
    wms_doc_no      VARCHAR(64),
    inbound_message_id BIGINT    NOT NULL DEFAULT 0,
    retain_until    TIMESTAMP    NOT NULL,   -- ≥ received_at + 90 天（= 长期 requestNo 去重 TTL；且 ≥ 全量备份周期 + 1 天，由启动自检保证）
    CONSTRAINT ck_upl_result CHECK (result_status IN ('ACCEPTED','DUPLICATE','CONFLICT','REJECTED','FAILED')),
    -- 小赵 I1 / 项目经理决定：保留期下限 90 天库层落地。PG 用 interval；SQLite 时间列是 TEXT，用 julianday 做等价比较
    -- （同时接受 'YYYY-MM-DD HH:MM:SS' 与 ISO 'T' 写法），并要求两列都能被解析，防止乱写的字符串让比较结果为 NULL 而放行
    CONSTRAINT ck_upl_retain CHECK (retain_until >= received_at + INTERVAL '90 days'),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_upl_retain CHECK (julianday(received_at) IS NOT NULL AND julianday(retain_until) IS NOT NULL AND julianday(retain_until) - julianday(received_at) >= 90),
    -- D6 口径：规范化报文 SHA-256，64 位小写十六进制（与 ck_obo_hash 同写法，两库通用）
    CONSTRAINT ck_upl_sha CHECK (length(payload_sha) = 64 AND lower(payload_sha) = payload_sha AND replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(payload_sha,'0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9',''),'a',''),'b',''),'c',''),'d',''),'e',''),'f','') = '')
);
CREATE INDEX ix_upl_time ON upstream_push_log(warehouse_id, received_at);
CREATE INDEX ix_upl_src  ON upstream_push_log(source_system, source_order_no, received_at);
-- 小赵 B1：只追加在库层落地（写法同 stock_movement）。wms_app 只有 SELECT/INSERT；
-- 唯一能删的是清理函数 purge_push_log()（属主 wms_purge_owner，与 02 purge_expired 同一套），且只能删 retain_until 已过（按 UTC）的行；UPDATE、TRUNCATE 对任何角色都拦。
CREATE FUNCTION trg_upl_append_only() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF TG_OP = 'DELETE' AND current_user = 'wms_purge_owner' AND OLD.retain_until < (now() AT TIME ZONE 'UTC') THEN  -- @pg-only
        RETURN OLD;                                                                                           -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RAISE EXCEPTION 'append_only_violation: %', TG_TABLE_NAME USING ERRCODE = '42501';                       -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_upl_append_only BEFORE UPDATE OR DELETE ON upstream_push_log FOR EACH ROW EXECUTE FUNCTION trg_upl_append_only();  -- @pg-only
CREATE TRIGGER trg_upl_no_truncate BEFORE TRUNCATE ON upstream_push_log FOR EACH STATEMENT EXECUTE FUNCTION trg_append_only();  -- @pg-only
GRANT SELECT, INSERT ON upstream_push_log TO wms_app;                                                         -- @pg-only

-- 第 11 篇 Q1 定案：离线纸质单事后补录（00 §6.6.1 PAPER_BACKFILL，§6.6.2 backfill_deadline_at）。
-- 一行 = 一张纸质单。补录产生的库存事件走 02 post_event，biz_key 与在线事件同一规则，由 uq_mvk_biz_line 去重；本表另按 (warehouse_id, biz_key) 防同单重复补录。
CREATE TABLE offline_paper_record (
    id                   BIGINT       PRIMARY KEY,
    warehouse_id         BIGINT       NOT NULL,
    device_id            VARCHAR(64)  NOT NULL,                 -- 离线的终端
    action_type          VARCHAR(24)  NOT NULL,                 -- 拣货确认 / 收货登记 / 签收
    biz_key              VARCHAR(128) NOT NULL,                 -- 与在线事件同一 biz_key 规则
    occurred_at          TIMESTAMP    NOT NULL,                 -- UTC，纸面记录的作业时间
    operator_id          BIGINT       NOT NULL,                 -- 纸面上的实际作业人
    payload              TEXT         NOT NULL,
    photo_ids            TEXT,
    approval_type        VARCHAR(24)  NOT NULL DEFAULT 'PAPER_BACKFILL',
    applicant_id         BIGINT       NOT NULL,                 -- 补录申请人（offline.paper.backfill）
    approver_id          BIGINT,                                -- 主管（offline.paper.approve）
    approved_at          TIMESTAMP,
    status               VARCHAR(16)  NOT NULL DEFAULT 'PENDING',
    offline_since        TIMESTAMP    NOT NULL,                 -- UTC，该设备本次离线起点
    reconnected_at       TIMESTAMP    NOT NULL,                 -- UTC，恢复联网时间
    backfill_deadline_at TIMESTAMP    NOT NULL,                 -- UTC，= reconnected_at + 24h（服务端下发值，00 §6.6.2）
    submitted_at         TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    exception_case_id    BIGINT,                                -- 过期补录转的异常单（第 10 篇）
    created_at           TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    CONSTRAINT uq_paper_bizkey   UNIQUE (warehouse_id, biz_key),
    CONSTRAINT ck_paper_type     CHECK (approval_type = 'PAPER_BACKFILL'),
    CONSTRAINT ck_paper_action   CHECK (action_type IN ('PICK_CONFIRM','RECEIVE_REGISTER','POD_SIGN')),
    CONSTRAINT ck_paper_status   CHECK (status IN ('PENDING','APPROVED','REJECTED','EXPIRED')),
    CONSTRAINT ck_paper_deadline CHECK (backfill_deadline_at = reconnected_at + interval '24 hours'),   -- @pg-only
-- @sqlite-only     CONSTRAINT ck_paper_deadline CHECK (backfill_deadline_at = datetime(reconnected_at, '+24 hours')),
    CONSTRAINT ck_paper_window   CHECK (reconnected_at > offline_since AND occurred_at >= offline_since
                                        AND occurred_at <= reconnected_at AND submitted_at >= reconnected_at),
    -- 过期：提交晚于 backfill_deadline_at 只能落 EXPIRED，且必须挂异常单；未过期不能是 EXPIRED
    CONSTRAINT ck_paper_expired  CHECK ((status = 'EXPIRED' AND submitted_at > backfill_deadline_at AND exception_case_id IS NOT NULL)
                                        OR (status <> 'EXPIRED' AND submitted_at <= backfill_deadline_at AND exception_case_id IS NULL)),
    CONSTRAINT ck_paper_sod      CHECK (approver_id IS NULL OR approver_id <> applicant_id),   -- 申请人不能自批
    CONSTRAINT ck_paper_approve  CHECK ((status IN ('APPROVED','REJECTED') AND approver_id IS NOT NULL AND approved_at IS NOT NULL)
                                        OR (status IN ('PENDING','EXPIRED') AND approver_id IS NULL AND approved_at IS NULL))
);
CREATE INDEX ix_paper_pending ON offline_paper_record(warehouse_id, status, submitted_at);
GRANT SELECT, INSERT, UPDATE ON offline_paper_record TO wms_app;                                               -- @pg-only
REVOKE UPDATE, DELETE, TRUNCATE ON upstream_push_log FROM wms_app;                                            -- @pg-only
-- SQLite（边缘节点）没有角色：UPDATE/DELETE 一律拦；到期清理同流水表，由维护脚本导出后 DROP 触发器→删 retain_until 已过的行→重建，全程审计
-- @sqlite-only CREATE TRIGGER trg_upl_no_update BEFORE UPDATE ON upstream_push_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: upstream_push_log'); END;
-- @sqlite-only CREATE TRIGGER trg_upl_no_delete BEFORE DELETE ON upstream_push_log BEGIN SELECT RAISE(ABORT, 'append_only_violation: upstream_push_log'); END;

-- 第 11 篇：推送日志到期清理只经函数（替代原 wms_archiver 直删）。函数本体放本篇文件（两库：SQLite 无函数，边缘按上面维护脚本清理）。
-- 属主 wms_purge_owner、wms_cleaner 的 EXECUTE、wms_purge_owner 对 upstream_push_log 的 SELECT/DELETE 都由 #2 99_grants.sql 按目录检查授予
-- （GRANT 自 4e3a7efb；ALTER FUNCTION … OWNER 自 #2 round 7）。SECURITY DEFINER + search_path = pg_catalog, public（本库对象都在 public）。
CREATE FUNCTION public.purge_push_log(OUT push_log_deleted BIGINT)                     -- @pg-only
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$          -- @pg-only
BEGIN                                                                                  -- @pg-only
    DELETE FROM public.upstream_push_log WHERE retain_until < (now() AT TIME ZONE 'UTC');  -- @pg-only
    GET DIAGNOSTICS push_log_deleted = ROW_COUNT;                                      -- @pg-only
END $$;                                                                                -- @pg-only
REVOKE ALL ON FUNCTION public.purge_push_log() FROM PUBLIC;                            -- @pg-only


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
    biz_ref         VARCHAR(64),                 -- 第 11 篇：处理成功后生成的 WMS 单号
    CONSTRAINT uq_in_msg UNIQUE (source, biz_type, external_no),
    CONSTRAINT ck_in_msg_status CHECK (status IN ('RECEIVED','PROCESSING','DONE','FAILED','DEAD','REJECTED'))
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
    -- 第 11 篇：节点内单调序号（00 §9.1 边缘回传按 (node_id, seq) 严格顺序，缺口暂停）
    warehouse_id    BIGINT       NOT NULL DEFAULT 0,
    node_id         INT          NOT NULL DEFAULT 0,
    seq             BIGINT       NOT NULL DEFAULT 0,
    replay_count    SMALLINT     NOT NULL DEFAULT 0,   -- 死信人工重放次数（重放沿用原 id，下游按事件 id 幂等）
    -- 小吴 C2：SENT 必须注明依据：2XX = 下游 2xx；DUP_409 = 下游 409 且被识别为"同一请求重复"（docs/11 §6.3）
    ack_kind        VARCHAR(8),
    -- 小吴 C1：DEAD 人工跳过的审计（谁、何时、原因），同事务另写 audit_log
    skipped_by      BIGINT,
    skipped_at      TIMESTAMP,
    skip_reason     VARCHAR(256),
    CONSTRAINT ck_outbox_status CHECK (status IN ('PENDING','SENDING','SENT','FAILED','DEAD','SKIPPED')),
    CONSTRAINT ck_outbox_seq    CHECK (seq >= 0),
    CONSTRAINT ck_outbox_ack    CHECK ((status = 'SENT' AND ack_kind IS NOT NULL AND ack_kind IN ('2XX','DUP_409')) OR (status <> 'SENT' AND ack_kind IS NULL)),
    CONSTRAINT ck_outbox_skip   CHECK ((status = 'SKIPPED' AND skipped_by IS NOT NULL AND skipped_at IS NOT NULL AND skip_reason IS NOT NULL AND length(trim(skip_reason)) >= 4)
                                    OR (status <> 'SKIPPED' AND skipped_by IS NULL AND skipped_at IS NULL AND skip_reason IS NULL)),
    CONSTRAINT ck_outbox_sent CHECK (status <> 'SENT' OR sent_at IS NOT NULL)   -- P3
-- @sqlite-only     , CONSTRAINT ck_outbox_ts CHECK ((typeof(created_at) = 'text' AND length(created_at) = 19 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(created_at) IS NOT NULL AND time(created_at) IS NOT NULL AND date(created_at) = substr(created_at, 1, 10) AND time(created_at) = substr(created_at, 12, 8) AND substr(created_at, 12, 2) <= '23') AND (typeof(next_retry_at) = 'text' AND length(next_retry_at) = 19 AND next_retry_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(next_retry_at) IS NOT NULL AND time(next_retry_at) IS NOT NULL AND date(next_retry_at) = substr(next_retry_at, 1, 10) AND time(next_retry_at) = substr(next_retry_at, 12, 8) AND substr(next_retry_at, 12, 2) <= '23') AND (sent_at IS NULL OR (typeof(sent_at) = 'text' AND length(sent_at) = 19 AND sent_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND date(sent_at) IS NOT NULL AND time(sent_at) IS NOT NULL AND date(sent_at) = substr(sent_at, 1, 10) AND time(sent_at) = substr(sent_at, 12, 8) AND substr(sent_at, 12, 2) <= '23')))   -- 小赵 S1
);
CREATE INDEX ix_outbox_pending ON outbox_event(status, next_retry_at);
CREATE INDEX ix_outbox_bizkey  ON outbox_event(biz_key, id);   -- 同键串行发送
CREATE UNIQUE INDEX uq_outbox_seq ON outbox_event(node_id, seq) WHERE seq > 0;
-- 小吴 C1：同一 biz_key 同时最多一条 DEAD（它之后的事件都被阻塞在 PENDING/FAILED，不可能再进死信）
CREATE UNIQUE INDEX uq_outbox_dead_bizkey ON outbox_event(biz_key) WHERE status = 'DEAD';
-- 形态 A：relay 扫待补 seq 的事件（seq=0），按 id 顺序补号（小吴 C3）
CREATE INDEX ix_outbox_noseq ON outbox_event(node_id, id) WHERE seq = 0;
-- 小吴 C1/C3：投递顺序与 seq 的库层守卫（两库同义）
--   ① 进 SENDING 时，同 biz_key 更早（id 更小）的事件必须都已 SENT 或 SKIPPED，否则 outbox_bizkey_blocked
--   ② SKIPPED 只能从 DEAD 来，且 SKIPPED / SENT 是终态
--   ③ seq 只能从 0 补成正数一次，之后不可改（relay 补号、边缘事务内取号都满足）
CREATE FUNCTION trg_outbox_order_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
BEGIN                                                                                                         -- @pg-only
    IF NEW.status = 'SENDING' AND OLD.status <> 'SENDING' AND EXISTS (SELECT 1 FROM outbox_event e WHERE e.biz_key = NEW.biz_key AND e.id < NEW.id AND e.status NOT IN ('SENT','SKIPPED')) THEN  -- @pg-only
        RAISE EXCEPTION 'outbox_bizkey_blocked' USING ERRCODE = '23514';                                      -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF (NEW.status = 'SKIPPED' AND OLD.status NOT IN ('DEAD','SKIPPED')) OR (OLD.status IN ('SENT','SKIPPED') AND NEW.status <> OLD.status) THEN  -- @pg-only
        RAISE EXCEPTION 'outbox_illegal_transition' USING ERRCODE = '23514';                                  -- @pg-only
    END IF;                                                                                                   -- @pg-only
    IF NEW.seq <> OLD.seq AND OLD.seq <> 0 THEN                                                               -- @pg-only
        RAISE EXCEPTION 'outbox_seq_immutable' USING ERRCODE = '23514';                                       -- @pg-only
    END IF;                                                                                                   -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_outbox_order_guard BEFORE UPDATE ON outbox_event FOR EACH ROW EXECUTE FUNCTION trg_outbox_order_guard();  -- @pg-only
-- @sqlite-only CREATE TRIGGER trg_outbox_bizkey_blocked BEFORE UPDATE OF status ON outbox_event
-- @sqlite-only WHEN NEW.status = 'SENDING' AND OLD.status <> 'SENDING' AND EXISTS (SELECT 1 FROM outbox_event e WHERE e.biz_key = NEW.biz_key AND e.id < NEW.id AND e.status NOT IN ('SENT','SKIPPED'))
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_bizkey_blocked'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_illegal_transition BEFORE UPDATE OF status ON outbox_event
-- @sqlite-only WHEN (NEW.status = 'SKIPPED' AND OLD.status NOT IN ('DEAD','SKIPPED')) OR (OLD.status IN ('SENT','SKIPPED') AND NEW.status <> OLD.status)
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_illegal_transition'); END;
-- @sqlite-only CREATE TRIGGER trg_outbox_seq_immutable BEFORE UPDATE OF seq ON outbox_event
-- @sqlite-only WHEN NEW.seq <> OLD.seq AND OLD.seq <> 0
-- @sqlite-only BEGIN SELECT RAISE(ABORT, 'outbox_seq_immutable'); END;

-- 小赵 Q2：去重记录与 outbox 只能清理"已过期 / 已投递且过保留期"的行（两库触发器，条件与 purge_expired() 一致）
-- search_path 固定为 pg_catalog, public。now()、interval、AT TIME ZONE 走 pg_catalog。
CREATE FUNCTION trg_purge_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
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
-- search_path 固定为 pg_catalog, public。now()、extract、interval、AT TIME ZONE 走 pg_catalog，调用方 schema 里的 now() 不生效。
CREATE FUNCTION trg_expiry_forward() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
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
-- 不是 outbox_event 表属主的角色，只能以初始状态 PENDING（不带 sent_at）插入。SENT 只能经 UPDATE 写入（受 sent_at_not_now 约束）。
-- wms_app 是 NOLOGIN，应用用的是继承它的登录角色，current_user 不是 wms_app，所以不能按角色名判断。
-- 非属主插入非 PENDING、或带上 sent_at：直接拒绝（outbox_insert_not_pending），不把 status 改写成 PENDING。
-- 表属主（建表的迁移角色）可以插入其他状态，种子和迁移走这条。
-- search_path 固定为 pg_catalog, public。属主查询全部写在 pg_catalog。
CREATE FUNCTION trg_outbox_insert_pending() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$  -- @pg-only
DECLARE                                                                                                       -- @pg-only
    owner_name name;                                                                                          -- @pg-only
BEGIN                                                                                                         -- @pg-only
    SELECT r.rolname INTO owner_name                                                                          -- @pg-only
      FROM pg_catalog.pg_roles r                                                                              -- @pg-only
      JOIN pg_catalog.pg_class c ON c.relowner = r.oid                                                        -- @pg-only
     WHERE c.oid = 'public.outbox_event'::regclass;                                                           -- @pg-only
    IF current_user IS DISTINCT FROM owner_name                                                               -- @pg-only
       AND (NEW.status IS DISTINCT FROM 'PENDING' OR NEW.sent_at IS NOT NULL) THEN                            -- @pg-only
        RAISE EXCEPTION 'outbox_insert_not_pending' USING ERRCODE = '42501'; END IF;                          -- @pg-only
    RETURN NEW;                                                                                               -- @pg-only
END $$;                                                                                                       -- @pg-only
CREATE TRIGGER trg_outbox_insert_pending BEFORE INSERT ON outbox_event FOR EACH ROW EXECUTE FUNCTION trg_outbox_insert_pending();  -- @pg-only
-- SQLite 没有角色：所有插入都按“非属主”处理，只能是 PENDING 且不带 sent_at，FAILED 同样拒绝。
-- 验证脚本造 SENT 种子时临时 DROP 本触发器、写完重建（单独的种子路径）
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
