-- =====================================================================
-- 11. МОДУЛЬ 5 (тема 13): теорія адміністрування БД, складова DCL
-- Ролі (в PostgreSQL користувач = роль з LOGIN), GRANT / REVOKE, права на стовпці,
-- привілеї за замовчуванням, захист на рівні рядків (Row-Level Security).
--
-- Модель доступу проєкту:
--   role_guest   — лише читання публічних представлень (для сайту/API без входу)
--   role_editor  — читання + додавання відгуків через процедури
--   role_dba     — повний доступ до об'єктів проєкту (адміністратор додатку)
--   app_reader / app_editor — приклади користувачів із входом (LOGIN)
--
-- УВАГА: для CREATE ROLE потрібне право CREATEROLE або суперкористувач.
--        Якщо права немає — оператор виведе помилку, решта скрипта працюватиме.
-- =====================================================================

-- ---------- 1. Створення ролей ----------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_guest')  THEN CREATE ROLE role_guest  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_editor') THEN CREATE ROLE role_editor NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_dba')    THEN CREATE ROLE role_dba    NOLOGIN; END IF;
    -- користувачі з входом (пароль змініть: ALTER ROLE app_reader PASSWORD '...')
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_reader')  THEN CREATE ROLE app_reader LOGIN PASSWORD 'change_me_reader'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_editor')  THEN CREATE ROLE app_editor LOGIN PASSWORD 'change_me_editor'; END IF;
END $$;

-- ---------- 2. Ієрархія ролей: членство (успадкування прав) ----------
GRANT role_guest  TO role_editor;      -- редактор має всі права гостя
GRANT role_editor TO role_dba;         -- dba має права редактора
GRANT role_guest  TO app_reader;
GRANT role_editor TO app_editor;

-- ---------- 3. Доступ до схеми ----------
-- Для «жорсткого» режиму можна забрати права у всіх (обережно: зачепить і інших користувачів БД!):
-- REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO role_guest, role_editor, role_dba;

-- ---------- 4. GRANT на таблиці та представлення ----------
-- гість бачить лише представлення та довідники
GRANT SELECT ON v_institutions_full, v_top_institutions, v_region_stats, mv_region_stats,
                v_reviews_public, regions, cities, institution_types, ownership_forms, specialty_dict
      TO role_guest;

-- права на СТОВПЦІ: гість бачить із institutions лише публічні поля
GRANT SELECT (id, name, short_name, city, region, website, founded_year, rating_total) ON institutions TO role_guest;

-- редактор: читає базові таблиці, додає відгуки, виконує процедури
GRANT SELECT ON institutions, institution_specialties, reviews, rating_history TO role_editor;
GRANT INSERT ON reviews TO role_editor;
GRANT USAGE, SELECT ON SEQUENCE reviews_id_seq TO role_editor;
GRANT INSERT ON v_reviews_public TO role_editor;
GRANT EXECUTE ON PROCEDURE sp_add_review(INTEGER, TEXT, INTEGER, TEXT, INTEGER) TO role_editor;
GRANT EXECUTE ON FUNCTION  fn_search_institutions(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO role_guest;

-- dba: усе в схемі public
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO role_dba;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO role_dba;
GRANT EXECUTE        ON ALL ROUTINES  IN SCHEMA public TO role_dba;

-- привілеї за замовчуванням для майбутніх об'єктів
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO role_dba;

-- ---------- 5. REVOKE: відкликання прав ----------
REVOKE INSERT ON reviews FROM role_editor;                 -- редактор більше не пише у таблицю напряму…
GRANT  INSERT ON reviews TO role_editor;                   -- …повертаємо (демонстрація пари REVOKE/GRANT)

-- ---------- 6. Row-Level Security: гість бачить лише схвалені відгуки ----------
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_reviews_guest_read ON reviews;
CREATE POLICY pol_reviews_guest_read ON reviews
    FOR SELECT TO role_guest
    USING (status = 'approved');

DROP POLICY IF EXISTS pol_reviews_editor_all ON reviews;
CREATE POLICY pol_reviews_editor_all ON reviews
    FOR ALL TO role_editor, role_dba
    USING (true) WITH CHECK (true);
-- власник таблиці (користувач, що створив її) обходить RLS, якщо не вказано FORCE ROW LEVEL SECURITY

-- GRANT SELECT на reviews для гостя потрібен, щоб політика застосовувалась
GRANT SELECT ON reviews TO role_guest;

-- ---------- 7. Перевірка прав: SET ROLE імітує вхід під іншою роллю ----------
SET ROLE role_guest;
SELECT current_user AS acting_as, count(*) AS visible_reviews FROM reviews;          -- лише approved (RLS)
SELECT id, name, city FROM institutions LIMIT 2;                                      -- дозволені стовпці
RESET ROLE;

-- спроба читати заборонений стовпець — помилка «permission denied»
DO $$
BEGIN
    SET LOCAL ROLE role_guest;
    PERFORM address FROM institutions LIMIT 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'role_guest не має доступу до стовпця address: %', SQLERRM;
END $$;
RESET ROLE;

-- ---------- 8. Перегляд прав (аналог SHOW GRANTS у MySQL) ----------
SELECT grantee, table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM   information_schema.role_table_grants
WHERE  grantee IN ('role_guest', 'role_editor') AND table_schema = 'public'
GROUP  BY grantee, table_name
ORDER  BY grantee, table_name LIMIT 12;

SELECT r.rolname, r.rolcanlogin AS can_login,
       (SELECT string_agg(g.rolname, ', ') FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
        WHERE  m.member = r.oid) AS member_of
FROM   pg_roles r
WHERE  r.rolname IN ('role_guest', 'role_editor', 'role_dba', 'app_reader', 'app_editor')
ORDER  BY r.rolname;
