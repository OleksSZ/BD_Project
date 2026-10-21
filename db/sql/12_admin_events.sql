-- =====================================================================
-- 12. МОДУЛЬ 5 (тема 14): команди адміністрування даних, ПОДІЇ в СКБД
--
-- У MySQL: CREATE EVENT ... ON SCHEDULE EVERY 1 DAY DO ...
-- У PostgreSQL вбудованого планувальника подій немає, тому "події" реалізовано трьома способами:
--   1) EVENT TRIGGER  — реакція на DDL-команди (CREATE/ALTER/DROP)      [нижче, потрібен суперкористувач]
--   2) LISTEN / NOTIFY — публікація/підписка (тригер trg_reviews_notify) [db/events.py listen]
--   3) Планові завдання — pg_cron (якщо встановлено) або db/events.py scheduler
-- =====================================================================

-- ======================= АДМІНІСТРУВАННЯ =======================

-- Поточна сесія та версія
SELECT current_user, current_database(), inet_server_port() AS port,
       split_part(version(), ',', 1) AS version;

-- Розмір БД, таблиць та індексів (аналог SHOW TABLE STATUS)
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;

SELECT relname AS table_name,
       pg_size_pretty(pg_table_size(relid))          AS table_size,
       pg_size_pretty(pg_indexes_size(relid))        AS indexes_size,
       n_live_tup AS live_rows, n_dead_tup AS dead_rows
FROM   pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 8;

-- Активні сесії (аналог SHOW PROCESSLIST)
SELECT pid, usename, state, left(query, 50) AS query
FROM   pg_stat_activity WHERE datname = current_database() ORDER BY pid LIMIT 5;

-- Використання індексів: які індекси реально потрібні (idx_scan = 0 -> кандидат на видалення)
SELECT relname AS table_name, indexrelname AS index_name, idx_scan
FROM   pg_stat_user_indexes ORDER BY idx_scan LIMIT 5;

-- Налаштування сервера (аналог SHOW VARIABLES)
SELECT name, setting, unit FROM pg_settings
WHERE  name IN ('max_connections', 'shared_buffers', 'work_mem', 'default_transaction_isolation', 'timezone');

SHOW transaction_isolation;

-- Обслуговування: оновлення статистики та очищення «мертвих» рядків
ANALYZE institutions;
VACUUM (ANALYZE) institution_specialties;

-- Блокування: хто кого блокує (корисно під час конкурентних транзакцій, тема 15)
SELECT blocked.pid AS blocked_pid, blocking.pid AS blocking_pid, left(blocked.query, 40) AS blocked_query
FROM   pg_stat_activity blocked
JOIN   pg_stat_activity blocking ON blocking.pid = ANY (pg_blocking_pids(blocked.pid));

-- Резервна копія і відновлення виконуються утилітами ОС (див. db/backup.py):
--   pg_dump -Fc -f backup.dump osvita_ua        |   pg_restore -d osvita_ua_copy backup.dump

-- ======================= ПОДІЯ 1: EVENT TRIGGER (реакція на DDL) =======================
CREATE OR REPLACE FUNCTION fn_log_ddl()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO ddl_log (command_tag, object_type, object_name)
        VALUES (tg_tag, r.object_type, r.object_identity);
    END LOOP;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'evt_log_ddl') THEN
        DROP EVENT TRIGGER evt_log_ddl;
    END IF;
    CREATE EVENT TRIGGER evt_log_ddl ON ddl_command_end
        WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE', 'CREATE INDEX', 'CREATE VIEW')
        EXECUTE FUNCTION fn_log_ddl();
    RAISE NOTICE 'Event trigger evt_log_ddl створено';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Для CREATE EVENT TRIGGER потрібен суперкористувач — пропущено';
END $$;

-- перевірка: DDL-команда потрапляє в журнал автоматично
CREATE TABLE IF NOT EXISTS demo_event_check (id INT);
DROP TABLE IF EXISTS demo_event_check;
SELECT command_tag, object_type, object_name, executed_at FROM ddl_log ORDER BY id DESC LIMIT 3;

-- ======================= ПОДІЯ 2: LISTEN / NOTIFY =======================
-- Тригер trg_reviews_notify (файл 10) надсилає повідомлення в канал review_added.
-- Слухач:  python db/events.py listen    — друкує подію щойно хтось додасть відгук.
LISTEN review_added;
NOTIFY review_added, '{"demo": "ручне повідомлення з SQL"}';
UNLISTEN review_added;

-- ======================= ПОДІЯ 3: планові завдання (аналог MySQL EVENT) =======================
-- Якщо на сервері є розширення pg_cron — планування прямо в БД; інакше див. db/events.py scheduler
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('cleanup-audit',  '0 3 * * *', 'CALL sp_cleanup_old_audit(90)');
        PERFORM cron.schedule('refresh-stats',  '*/30 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_region_stats');
        RAISE NOTICE 'pg_cron: завдання заплановано';
    ELSE
        RAISE NOTICE 'pg_cron не встановлено — використовуйте: python db/events.py scheduler';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron недоступний (%): використовуйте python db/events.py scheduler', SQLERRM;
END $$;

-- Вручну виконуємо те, що робила б подія, і фіксуємо в журналі
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_region_stats;
CALL sp_cleanup_old_audit(90);
SELECT task, details, executed_at FROM maintenance_log ORDER BY id DESC LIMIT 3;
