-- ЛР №22. Налаштування сервера СКБД (PostgreSQL замість MySQL)
-- =====================================================================
-- Методичка розглядає встановлення MySQL, каталоги сервера і файл my.ini / my.cnf.
-- У PostgreSQL аналогами є postgresql.conf (основні параметри), pg_hba.conf (хто і звідки
-- може підключатися) і postgresql.auto.conf (зміни через ALTER SYSTEM).
-- Команди: version(), SHOW, current_setting(), pg_settings (контекст і джерело параметра),
-- SET / SET LOCAL / RESET (параметри сесії й транзакції — аналог SET SESSION у MySQL),
-- pg_stat_activity (SHOW PROCESSLIST), pg_stat_database, параметри журналів (аналог slow query log).
-- Скрипт нічого не змінює на сервері: SET діє лише в поточному підключенні.
-- Запуск: python db/lab.py 22
-- =====================================================================

-- == 1. Сервер і його стан ==
-- версія сервера (MySQL: SELECT VERSION() / mysqladmin version)
SELECT version();

-- час запуску сервера і скільки він працює (аналог Uptime у mysqladmin status)
SELECT pg_postmaster_start_time()::timestamp(0)                    AS started,
       date_trunc('second', now() - pg_postmaster_start_time())::text AS uptime;

-- файли конфігурації та каталог даних (аналог my.ini і datadir).
-- Ці параметри бачить лише суперкористувач або роль pg_read_all_settings — іншим рядки не показуються
SELECT name, setting FROM pg_settings
WHERE  name IN ('config_file', 'hba_file', 'data_directory')
ORDER  BY name;

-- == 2. Основні параметри сервера ==
-- мережа: порт і адреси, на яких сервер приймає підключення (MySQL: port, bind-address)
SELECT name, setting, unit, short_desc FROM pg_settings
WHERE  name IN ('port', 'listen_addresses', 'max_connections', 'superuser_reserved_connections')
ORDER  BY name;

-- пам'ять (MySQL: innodb_buffer_pool_size, key_buffer_size, sort_buffer_size)
SELECT name, setting, unit, short_desc FROM pg_settings
WHERE  name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size')
ORDER  BY name;

-- кодування і часовий пояс (MySQL: character_set_server, collation_server, time_zone)
SELECT name, setting FROM pg_settings
WHERE  name IN ('server_encoding', 'client_encoding', 'lc_collate', 'lc_messages', 'TimeZone', 'DateStyle')
ORDER  BY name;

-- SHOW і current_setting() — короткий спосіб прочитати один параметр
SHOW max_connections;

SELECT current_setting('server_version') AS server_version, current_setting('TimeZone') AS timezone;

-- == 3. Рівні дії параметрів ==
-- context показує, коли зміна набуває чинності:
-- postmaster — лише після перезапуску сервера; sighup — після перечитування конфігурації;
-- superuser / user — можна змінити командою SET у сесії (аналог GLOBAL і SESSION у MySQL)
SELECT context, count(*) AS parameters,
       string_agg(name, ', ' ORDER BY name) FILTER (WHERE name IN ('port', 'max_connections', 'shared_buffers',
                 'log_min_duration_statement', 'work_mem', 'TimeZone', 'statement_timeout')) AS examples
FROM   pg_settings
GROUP  BY context
ORDER  BY parameters DESC;

-- source показує, звідки взято значення: за замовчуванням, з конфігураційного файлу, з команди SET тощо
SELECT name, setting, source FROM pg_settings
WHERE  source NOT IN ('default', 'override')
ORDER  BY source, name
LIMIT  12;

-- == 4. Зміна параметрів ==
-- SET змінює параметр для ПОТОЧНОЇ сесії (MySQL: SET SESSION sort_buffer_size = …)
SET work_mem = '16MB';
SHOW work_mem;

-- RESET повертає значення за замовчуванням
RESET work_mem;
SHOW work_mem;

-- SET LOCAL діє лише до кінця транзакції
BEGIN;
SET LOCAL statement_timeout = '5s';
SHOW statement_timeout;
COMMIT;

-- після завершення транзакції значення повернулося
SHOW statement_timeout;

-- Постійна зміна для всього сервера (MySQL: SET GLOBAL / SET PERSIST, правка my.ini) виконується
-- суперкористувачем і змінює файл postgresql.auto.conf, тому тут не виконується:
--   ALTER SYSTEM SET max_connections = 200;   -- потрібен перезапуск (context = postmaster)
--   ALTER SYSTEM SET work_mem = '8MB';         -- достатньо SELECT pg_reload_conf();
--   ALTER DATABASE osvita_ua SET TimeZone = 'Europe/Kyiv';   -- параметр для однієї БД
-- Доступ «хто і звідки» задається рядками pg_hba.conf, напр.:
--   host  osvita_ua  admin_user  127.0.0.1/32  scram-sha-256

-- == 5. Журнали сервера ==
-- параметри журналювання (MySQL: log_error, general_log, slow_query_log, long_query_time).
-- log_min_duration_statement — поріг «повільного» запиту в мс (-1 — вимкнено)
SELECT name, setting, unit, short_desc FROM pg_settings
WHERE  name IN ('logging_collector', 'log_destination', 'log_directory', 'log_min_duration_statement',
                'log_statement', 'log_connections')
ORDER  BY name;

-- == 6. Підключення і статистика ==
-- поточні підключення та запити, що виконуються (MySQL: SHOW PROCESSLIST)
SELECT pid, usename, datname, client_addr, state, left(query, 50) AS query
FROM   pg_stat_activity
WHERE  backend_type = 'client backend'
ORDER  BY backend_start;

-- статистика роботи бази даних (аналог SHOW GLOBAL STATUS): транзакції, читання з кешу і диска
SELECT datname, numbackends AS connections, xact_commit AS commits, xact_rollback AS rollbacks,
       blks_hit AS cache_hits, blks_read AS disk_reads,
       round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 1) AS cache_hit_pct
FROM   pg_stat_database
WHERE  datname = current_database();

-- службові бази сервера (аналог mysql, performance_schema у MySQL):
-- template0 / template1 — шаблони для CREATE DATABASE, postgres — БД для адміністрування
SELECT datname, datistemplate AS is_template, datallowconn AS allow_connections,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM   pg_database ORDER BY datname;
