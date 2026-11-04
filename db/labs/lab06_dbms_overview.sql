-- ЛР №6. Дослідження можливостей СКБД (PostgreSQL замість MySQL)
-- =====================================================================
-- Методичка описує встановлення MySQL і MySQL Workbench. Проєкт працює на PostgreSQL 16,
-- тому тут ті самі дії виконуються SQL-запитами до системного каталогу — це те, що
-- Workbench показує в панелі Navigator: сервер, бази, схеми, таблиці, користувачі, сесії.
-- Аналоги команд MySQL / psql наведено в коментарях.
-- Графічні клієнти для PostgreSQL: pgAdmin 4, DBeaver (аналоги Workbench).
-- Запуск: python db/lab.py 6
-- =====================================================================

-- == 1. Сервер і підключення ==
-- версія сервера (MySQL: SELECT VERSION();)
SELECT version();

-- до чого ми підключені: БД, користувач, адреса та порт сервера
SELECT current_database() AS database, current_user AS "user", inet_server_addr() AS host,
       inet_server_port() AS port, pg_postmaster_start_time()::timestamp(0) AS server_started;

-- основні параметри сервера (MySQL: SHOW VARIABLES LIKE ...)
SELECT name, setting, short_desc
FROM   pg_settings
WHERE  name IN ('server_version', 'server_encoding', 'client_encoding', 'lc_collate', 'TimeZone',
                'max_connections', 'shared_buffers', 'default_transaction_isolation')
ORDER  BY name;

-- == 2. Бази даних і схеми ==
-- перелік баз даних з розміром (MySQL: SHOW DATABASES; psql: \l)
SELECT datname AS database, pg_encoding_to_char(encoding) AS encoding,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM   pg_database
WHERE  NOT datistemplate
ORDER  BY datname;

-- схеми поточної БД (у MySQL схема = база даних; psql: \dn)
SELECT nspname AS schema, pg_get_userbyid(nspowner) AS owner
FROM   pg_namespace
WHERE  nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'
ORDER  BY 1;

-- == 3. Об'єкти БД проєкту ==
-- таблиці з кількістю рядків і розміром (MySQL: SHOW TABLE STATUS; psql: \dt+)
SELECT c.relname AS table_name,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I', c.relname), false, true, '')))[1]::text::int AS rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM   pg_class c
WHERE  c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
ORDER  BY pg_total_relation_size(c.oid) DESC;

-- скільки об'єктів кожного виду є в схемі (таблиці, представлення, індекси, функції, тригери ...)
SELECT 'таблиці' AS object, count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
UNION ALL SELECT 'представлення',            count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'v'
UNION ALL SELECT 'матеріалізовані представлення', count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'm'
UNION ALL SELECT 'індекси',                  count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'i'
UNION ALL SELECT 'функції',                  count(*) FROM pg_proc  WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
UNION ALL SELECT 'процедури',                count(*) FROM pg_proc  WHERE pronamespace = 'public'::regnamespace AND prokind = 'p'
UNION ALL SELECT 'тригери',                  count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                                                      WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal
UNION ALL SELECT 'типи ENUM',                count(DISTINCT enumtypid) FROM pg_enum;

-- структура однієї таблиці (MySQL: DESCRIBE institutions; psql: \d institutions)
SELECT column_name, data_type, character_maximum_length AS len, is_nullable, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public' AND table_name = 'reviews'
ORDER  BY ordinal_position;

-- == 4. Типи даних СКБД ==
-- які типи даних використовуються в таблицях проєкту і скільки разів
SELECT data_type, count(*) AS columns
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')
GROUP  BY data_type
ORDER  BY columns DESC;

-- == 5. Користувачі, ролі, сесії ==
-- ролі сервера (MySQL: SELECT user, host FROM mysql.user; psql: \du)
SELECT rolname, rolsuper AS superuser, rolcreatedb AS create_db, rolcanlogin AS can_login
FROM   pg_roles
WHERE  rolname NOT LIKE 'pg\_%'
ORDER  BY rolname;

-- активні підключення (MySQL: SHOW PROCESSLIST)
SELECT pid, usename, datname, state, backend_start::timestamp(0) AS connected_at
FROM   pg_stat_activity
WHERE  datname IS NOT NULL
ORDER  BY backend_start;

-- встановлені розширення (pg_trgm використовується для пошуку в API)
SELECT extname, extversion FROM pg_extension ORDER BY extname;
