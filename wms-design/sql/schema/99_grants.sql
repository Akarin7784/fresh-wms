-- ============================================================
-- 清理角色与 purge_expired()。各表的 wms_app GRANT 写在该表所在的篇文件末尾，
-- 后续篇章只加自己的 sql/schema/NN_*.sql，不要再改一份总 GRANT。
-- ============================================================
-- 清理只能经 purge_expired()：属主 wms_purge_owner（非超级用户、NOLOGIN，只有这两张表的 SELECT/DELETE），
-- 调用方 wms_cleaner 只有 EXECUTE，对表没有任何权限；删除条件写死在函数里，不接受参数
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_purge_owner') THEN CREATE ROLE wms_purge_owner NOLOGIN NOSUPERUSER NOINHERIT; END IF; END $$;  -- @pg-only
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_cleaner') THEN CREATE ROLE wms_cleaner NOLOGIN NOSUPERUSER; END IF; END $$;  -- @pg-only
GRANT USAGE ON SCHEMA public TO wms_purge_owner, wms_cleaner;                          -- @pg-only
GRANT SELECT, DELETE ON idempotency_record, outbox_event TO wms_purge_owner;           -- @pg-only
CREATE FUNCTION public.purge_expired(OUT idem_deleted BIGINT, OUT outbox_deleted BIGINT)  -- @pg-only
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$          -- @pg-only
BEGIN                                                                                  -- @pg-only
    DELETE FROM public.idempotency_record WHERE expires_at < (now() AT TIME ZONE 'UTC');  -- @pg-only
    GET DIAGNOSTICS idem_deleted = ROW_COUNT;                                          -- @pg-only
    DELETE FROM public.outbox_event WHERE status = 'SENT' AND sent_at < (now() AT TIME ZONE 'UTC') - interval '7 days';  -- @pg-only
    GET DIAGNOSTICS outbox_deleted = ROW_COUNT;                                        -- @pg-only
END $$;                                                                                -- @pg-only
ALTER FUNCTION public.purge_expired() OWNER TO wms_purge_owner;                        -- @pg-only
REVOKE ALL ON FUNCTION public.purge_expired() FROM PUBLIC;                             -- @pg-only
GRANT EXECUTE ON FUNCTION public.purge_expired() TO wms_cleaner;                       -- @pg-only
-- upstream_push_log / purge_push_log() 属于第 11 篇。本分支的 11_integration.sql 还没有这张表，也没有这个函数。 -- @pg-only
-- 表或函数不存在就跳过对应 GRANT，避免 99 在 #11 落库前把 verify 打红。当前两次目录检查都不命中，两笔授权都跳过。 -- @pg-only
DO $$ BEGIN                                                                              -- @pg-only
  IF to_regclass('public.upstream_push_log') IS NOT NULL THEN                           -- @pg-only
    GRANT SELECT, DELETE ON upstream_push_log TO wms_purge_owner;                       -- @pg-only
  END IF;                                                                                -- @pg-only
  IF to_regprocedure('public.purge_push_log()') IS NOT NULL THEN                        -- @pg-only
    GRANT EXECUTE ON FUNCTION public.purge_push_log() TO wms_cleaner;                   -- @pg-only
  END IF;                                                                                -- @pg-only
END $$;                                                                                  -- @pg-only
