-- ЛР №23. Керування обліковими записами користувачів
-- =====================================================================
-- У PostgreSQL користувач — це роль з правом LOGIN. Команди: CREATE ROLE / CREATE USER
-- (PASSWORD, CONNECTION LIMIT, VALID UNTIL), атрибути CREATEDB / CREATEROLE (глобальні права),
-- GRANT / REVOKE на рівнях БД, схеми, усіх таблиць, однієї таблиці, стовпців,
-- WITH GRANT OPTION, GRANT роль TO користувач (групи), SET ROLE (перевірка прав),
-- ALTER ROLE (пароль, блокування), DROP OWNED, DROP ROLE; перевірка за системними
-- таблицями pg_roles, pg_auth_members, information_schema.*_privileges, has_table_privilege().
-- Потрібне право CREATEROLE (як і для 11_dcl_roles.sql). Ролі створюються всередині
-- BEGIN … ROLLBACK — у PostgreSQL це транзакційні команди, тож на сервері нічого не залишається.
-- Запуск: python db/lab.py 23
-- =====================================================================

-- == 1. Облікові записи, що вже є ==
-- ролі сервера та їх глобальні атрибути (MySQL: SELECT user, host FROM mysql.user)
SELECT rolname, rolcanlogin AS can_login, rolsuper AS superuser, rolcreatedb AS create_db,
       rolcreaterole AS create_role, rolconnlimit AS conn_limit
FROM   pg_roles
WHERE  rolname NOT LIKE 'pg\_%'
ORDER  BY rolname;

-- ролі проєкту з 11_dcl_roles.sql: членство в групових ролях
SELECT r.rolname AS group_role, m.rolname AS member
FROM   pg_auth_members am
JOIN   pg_roles r ON r.oid = am.roleid
JOIN   pg_roles m ON m.oid = am.member
WHERE  r.rolname LIKE 'role\_%'
ORDER  BY 1, 2;

BEGIN;

-- == 2. Створення користувачів ==
-- користувач з паролем, обмеженням кількості підключень і терміном дії облікового запису
CREATE USER lab23_reader WITH PASSWORD 'Reader_2025' CONNECTION LIMIT 3 VALID UNTIL '2027-01-01';

-- CREATE ROLE без LOGIN — група, через яку видаються права кільком користувачам
CREATE ROLE lab23_editors NOLOGIN;
CREATE USER lab23_editor WITH PASSWORD 'Editor_2025';
CREATE USER lab23_manager WITH PASSWORD 'Manager_2025';

-- глобальні привілеї — атрибути ролі (MySQL: GRANT … ON *.*): право створювати бази даних
CREATE USER lab23_admin WITH PASSWORD 'Admin_2025' CREATEDB;

-- щоб перевіряти права командою SET ROLE, поточний користувач стає членом цих ролей
GRANT lab23_reader, lab23_editor, lab23_manager TO CURRENT_USER;

-- == 3. Привілеї рівня бази даних і схеми ==
-- право підключатися до БД і використовувати схему (без цього таблиці недоступні взагалі).
-- Ім'я БД підставляється з current_database(), тому використано format() і EXECUTE
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO lab23_reader, lab23_editors, lab23_manager', current_database());
    EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO lab23_admin', current_database());
END $$;

GRANT USAGE ON SCHEMA public TO lab23_reader, lab23_editors, lab23_manager, lab23_admin;

-- «усі привілеї до однієї БД» на рівні даних: усі таблиці схеми
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO lab23_admin;

-- маніпулювання даними та перегляд для всієї БД: SELECT / INSERT / UPDATE / DELETE на всі таблиці
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO lab23_editors;

-- групова роль: користувач отримує всі права групи
GRANT lab23_editors TO lab23_editor;

-- == 4. Привілеї рівня таблиці ==
-- лише перегляд кількох таблиць
GRANT SELECT ON regions, cities, institutions TO lab23_reader;

-- усі привілеї до однієї таблиці
GRANT ALL PRIVILEGES ON specialty_dict TO lab23_manager;

-- маніпулювання даними однієї таблиці
GRANT SELECT, INSERT, UPDATE, DELETE ON reviews TO lab23_manager;

-- == 5. Привілеї рівня стовпців ==
-- перегляд лише окремих стовпців і зміна лише одного стовпця
GRANT SELECT (id, short_name, website), UPDATE (website) ON institutions TO lab23_manager;

-- усі привілеї до стовпця (SELECT, INSERT, UPDATE, REFERENCES)
GRANT ALL (name) ON ownership_forms TO lab23_manager;

-- == 6. Передавання привілеїв ==
-- WITH GRANT OPTION: lab23_manager може сам видавати право SELECT на regions іншим
GRANT SELECT ON regions TO lab23_manager WITH GRANT OPTION;

SET ROLE lab23_manager;
GRANT SELECT ON regions TO lab23_editor;
RESET ROLE;

-- хто видав право (grantor) і чи можна його передавати далі (is_grantable)
SELECT grantor, grantee, table_name, privilege_type, is_grantable
FROM   information_schema.table_privileges
WHERE  table_name = 'regions' AND grantee LIKE 'lab23\_%'
ORDER  BY grantee;

-- == 7. Перевірка прав ==
-- SET ROLE імітує вхід під іншим користувачем
SET ROLE lab23_reader;
SELECT current_user, count(*) AS institutions FROM institutions;

SAVEPOINT sp;
-- очікувана помилка: у lab23_reader немає права читати відгуки
SELECT count(*) FROM reviews;
ROLLBACK TO SAVEPOINT sp;

-- очікувана помилка: права змінювати дані в lab23_reader теж немає
UPDATE regions SET name = name;
ROLLBACK TO SAVEPOINT sp;

RESET ROLE;

-- права на стовпці: lab23_manager бачить лише дозволені стовпці
SET ROLE lab23_manager;
SELECT id, short_name, website FROM institutions ORDER BY id LIMIT 3;

-- очікувана помилка: стовпець rating_total не входить до дозволених
SELECT rating_total FROM institutions;
ROLLBACK TO SAVEPOINT sp;

RESET ROLE;

-- has_table_privilege / has_column_privilege — перевірка без перемикання ролі
SELECT u AS "user",
       has_table_privilege(u, 'reviews', 'SELECT')                 AS reviews_select,
       has_table_privilege(u, 'reviews', 'INSERT')                 AS reviews_insert,
       has_column_privilege(u, 'institutions', 'website', 'UPDATE') AS website_update
FROM   unnest(ARRAY['lab23_reader', 'lab23_editor', 'lab23_manager', 'lab23_admin']) AS u;

-- == 8. Керування привілеями і обліковими записами ==
-- REVOKE: відкликати право
REVOKE DELETE ON reviews FROM lab23_manager;

-- відкликати лише право передавати привілей (саме право SELECT залишається)
REVOKE GRANT OPTION FOR SELECT ON regions FROM lab23_manager CASCADE;

-- права на стовпці з каталогу
SELECT grantee, table_name, column_name, privilege_type
FROM   information_schema.column_privileges
WHERE  grantee = 'lab23_manager' AND table_name = 'institutions'
ORDER  BY column_name, privilege_type;

-- змінити пароль, обмеження підключень; заблокувати вхід (NOLOGIN)
ALTER ROLE lab23_reader WITH PASSWORD 'New_Reader_2025' CONNECTION LIMIT 1;
ALTER ROLE lab23_admin NOLOGIN;

-- стан облікових записів після змін
SELECT rolname, rolcanlogin AS can_login, rolcreatedb AS create_db, rolconnlimit AS conn_limit,
       rolvaliduntil::date AS valid_until
FROM   pg_roles WHERE rolname LIKE 'lab23\_%' ORDER BY rolname;

-- == 9. Видалення користувачів ==
-- перед DROP ROLE треба відкликати всі права ролі (DROP OWNED) — інакше помилка залежностей
SAVEPOINT sp_drop;
-- очікувана помилка: у ролі ще є привілеї на об'єкти БД
DROP ROLE lab23_manager;
ROLLBACK TO SAVEPOINT sp_drop;

DROP OWNED BY lab23_manager;
DROP ROLE lab23_manager;

ROLLBACK;

-- після ROLLBACK жодної ролі lab23_* на сервері немає
SELECT count(*) AS lab23_roles FROM pg_roles WHERE rolname LIKE 'lab23\_%';
