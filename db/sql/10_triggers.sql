-- =====================================================================
-- 10. МОДУЛЬ 4 (тема 12): ТРИГЕРИ
-- BEFORE / AFTER / INSTEAD OF, FOR EACH ROW / FOR EACH STATEMENT, умова WHEN,
-- змінні OLD / NEW / TG_OP / TG_TABLE_NAME.
-- Тригер-функції в PostgreSQL створюються окремо (RETURNS trigger), потім прив'язуються.
-- Парсери (parser/test.py, parser/raiting.py) НЕ змінювались: їхні INSERT/UPDATE
-- автоматично проходять через ці тригери.
-- =====================================================================

-- ---------- допоміжні функції пошуку/створення довідникових записів ----------
CREATE OR REPLACE FUNCTION fn_get_city_id(p_region TEXT, p_city TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_region_id INTEGER;
    v_city_id   INTEGER;
BEGIN
    SELECT id INTO v_region_id FROM regions WHERE name = p_region;
    IF v_region_id IS NULL THEN
        INSERT INTO regions (name) VALUES (p_region)
        ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_region_id;
    END IF;

    SELECT id INTO v_city_id FROM cities WHERE region_id = v_region_id AND name = p_city;
    IF v_city_id IS NULL THEN
        INSERT INTO cities (region_id, name) VALUES (v_region_id, p_city)
        ON CONFLICT (region_id, name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_city_id;
    END IF;
    RETURN v_city_id;
END $$;

CREATE OR REPLACE FUNCTION fn_get_type_id(p_name TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
BEGIN
    SELECT id INTO v_id FROM institution_types WHERE name = p_name;
    IF v_id IS NULL THEN
        INSERT INTO institution_types (name) VALUES (p_name)
        ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION fn_get_ownership_id(p_name TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
BEGIN
    SELECT id INTO v_id FROM ownership_forms WHERE name = p_name;
    IF v_id IS NULL THEN
        INSERT INTO ownership_forms (name) VALUES (p_name)
        ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $$;

-- =====================================================================
-- ТРИГЕР 1 (BEFORE INSERT OR UPDATE, FOR EACH ROW): нормалізація й очищення даних institutions
--   * 'nan' / '' -> NULL
--   * автоматично заповнює city_id, type_id, ownership_id (підтримка 3НФ для старих парсерів)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_institutions_normalize()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.short_name := fn_clean_text(NEW.short_name);
    NEW.website    := fn_clean_text(NEW.website);
    NEW.address    := fn_clean_text(NEW.address);
    NEW.region     := fn_clean_text(NEW.region);
    NEW.city       := fn_clean_text(NEW.city);
    NEW.type       := fn_clean_text(NEW.type);
    NEW.ownership  := fn_clean_text(NEW.ownership);

    IF NEW.founded_year IS NOT NULL AND NEW.founded_year NOT BETWEEN 800 AND 2100 THEN
        RAISE WARNING 'Некоректний рік заснування % для edbo_code=% — замінено на NULL', NEW.founded_year, NEW.edbo_code;
        NEW.founded_year := NULL;
    END IF;

    NEW.city_id      := fn_get_city_id(COALESCE(NEW.region, 'Не вказано'), COALESCE(NEW.city, 'Не вказано'));
    NEW.type_id      := fn_get_type_id(COALESCE(NEW.type, 'Не вказано'));
    NEW.ownership_id := fn_get_ownership_id(COALESCE(NEW.ownership, 'Не вказано'));
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_institutions_01_normalize ON institutions;
CREATE TRIGGER trg_institutions_01_normalize
    BEFORE INSERT OR UPDATE ON institutions
    FOR EACH ROW EXECUTE FUNCTION fn_institutions_normalize();

-- =====================================================================
-- ТРИГЕР 2 (BEFORE UPDATE): автоматичне оновлення updated_at
-- (тригери одного рівня виконуються в алфавітному порядку імен: 01 -> 02)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_institutions_02_updated_at ON institutions;
CREATE TRIGGER trg_institutions_02_updated_at
    BEFORE UPDATE ON institutions
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

DROP TRIGGER IF EXISTS trg_specialties_02_updated_at ON institution_specialties;
CREATE TRIGGER trg_specialties_02_updated_at
    BEFORE UPDATE ON institution_specialties
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- =====================================================================
-- ТРИГЕР 3 (BEFORE INSERT OR UPDATE): синхронізація довідника specialty_dict + валідація
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_specialties_sync()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.specialty_code := fn_clean_text(NEW.specialty_code);
    NEW.specialty_name := fn_clean_text(NEW.specialty_name);
    NEW.students_count := GREATEST(COALESCE(NEW.students_count, 0), 0);

    IF NEW.specialty_code IS NOT NULL THEN
        INSERT INTO specialty_dict (code, name)
        VALUES (NEW.specialty_code, COALESCE(NEW.specialty_name, 'Без назви'))
        ON CONFLICT (code) DO NOTHING;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_specialties_01_sync ON institution_specialties;
CREATE TRIGGER trg_specialties_01_sync
    BEFORE INSERT OR UPDATE ON institution_specialties
    FOR EACH ROW EXECUTE FUNCTION fn_specialties_sync();

-- =====================================================================
-- ТРИГЕР 4 (AFTER INSERT / AFTER UPDATE з умовою WHEN): історія рейтингу
--   Записує знімок лише тоді, коли рейтинг ДІЙСНО змінився.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_rating_history()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO rating_history (institution_id, rating_total, city_position, general_position)
    VALUES (NEW.id, NEW.rating_total, NEW.rating_city_position, NEW.rating_general_position);
    RETURN NULL;                                  -- для AFTER-тригера значення ігнорується
END $$;

DROP TRIGGER IF EXISTS trg_institutions_rating_history_ins ON institutions;
CREATE TRIGGER trg_institutions_rating_history_ins
    AFTER INSERT ON institutions
    FOR EACH ROW WHEN (NEW.rating_total IS NOT NULL)
    EXECUTE FUNCTION fn_rating_history();

DROP TRIGGER IF EXISTS trg_institutions_rating_history_upd ON institutions;
CREATE TRIGGER trg_institutions_rating_history_upd
    AFTER UPDATE ON institutions
    FOR EACH ROW
    WHEN (OLD.rating_total IS DISTINCT FROM NEW.rating_total
          OR OLD.rating_city_position IS DISTINCT FROM NEW.rating_city_position
          OR OLD.rating_general_position IS DISTINCT FROM NEW.rating_general_position)
    EXECUTE FUNCTION fn_rating_history();

-- =====================================================================
-- ТРИГЕР 5 (AFTER, універсальний): журнал аудиту у форматі JSONB
--   TG_OP / TG_TABLE_NAME / OLD / NEW. Службові поля, що змінюються постійно
--   (updated_at, агрегати відгуків), не вважаються змінами — щоб не засмічувати журнал.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_audit_row()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_ignored TEXT[] := ARRAY['updated_at', 'avg_review_score', 'reviews_count', 'rating_updated_at'];
    v_old     JSONB;
    v_new     JSONB;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' AND (v_old - v_ignored) = (v_new - v_ignored) THEN
        RETURN NULL;                              -- нічого суттєвого не змінилось
    END IF;

    INSERT INTO audit_log (table_name, operation, row_id, old_data, new_data)
    VALUES (TG_TABLE_NAME, TG_OP, COALESCE((v_new ->> 'id')::int, (v_old ->> 'id')::int), v_old, v_new);
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_institutions_audit ON institutions;
CREATE TRIGGER trg_institutions_audit
    AFTER UPDATE OR DELETE ON institutions                 -- INSERT не логуємо: парсер вставляє тисячі рядків
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row();

DROP TRIGGER IF EXISTS trg_reviews_audit ON reviews;
CREATE TRIGGER trg_reviews_audit
    AFTER INSERT OR UPDATE OR DELETE ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row();

-- =====================================================================
-- ТРИГЕР 6 (AFTER INSERT/UPDATE/DELETE на reviews): підтримка агрегатів у institutions
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_refresh_review_stats(p_institution_id INTEGER)
RETURNS void LANGUAGE sql AS $$
    UPDATE institutions i
    SET    avg_review_score = (SELECT round(avg(score), 2) FROM reviews r
                               WHERE r.institution_id = p_institution_id AND r.status = 'approved'),
           reviews_count    = (SELECT count(*) FROM reviews r
                               WHERE r.institution_id = p_institution_id AND r.status = 'approved')
    WHERE  i.id = p_institution_id
$$;

CREATE OR REPLACE FUNCTION fn_reviews_stats()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM fn_refresh_review_stats(NEW.institution_id);
    END IF;
    IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.institution_id <> NEW.institution_id) THEN
        PERFORM fn_refresh_review_stats(OLD.institution_id);
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_reviews_stats ON reviews;
CREATE TRIGGER trg_reviews_stats
    AFTER INSERT OR UPDATE OR DELETE ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_reviews_stats();

-- =====================================================================
-- ТРИГЕР 7 (AFTER INSERT): подія «додано відгук» -> pg_notify (див. 12_admin_events.sql, db/events.py)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_notify_review()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('review_added',
                      json_build_object('id', NEW.id, 'institution_id', NEW.institution_id,
                                        'author', NEW.author, 'score', NEW.score)::text);
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_reviews_notify ON reviews;
CREATE TRIGGER trg_reviews_notify
    AFTER INSERT ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_notify_review();

-- =====================================================================
-- ТРИГЕР 8 (BEFORE TRUNCATE, FOR EACH STATEMENT): захист журналу аудиту
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_forbid_truncate()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Таблицю % очищати заборонено (використовуйте sp_cleanup_old_audit)', TG_TABLE_NAME
          USING ERRCODE = 'insufficient_privilege';
END $$;

DROP TRIGGER IF EXISTS trg_audit_no_truncate ON audit_log;
CREATE TRIGGER trg_audit_no_truncate
    BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION fn_forbid_truncate();

-- =====================================================================
-- ТРИГЕР 9 (INSTEAD OF INSERT на представленні): додавання відгуку за кодом ЄДЕБО
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_reviews_public_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_inst_id INTEGER;
BEGIN
    SELECT id INTO v_inst_id FROM institutions WHERE edbo_code = NEW.edbo_code;
    IF v_inst_id IS NULL THEN
        RAISE EXCEPTION 'Заклад з edbo_code=% не знайдено', NEW.edbo_code USING ERRCODE = 'no_data_found';
    END IF;
    INSERT INTO reviews (institution_id, author, score, comment)
    VALUES (v_inst_id, NEW.author, NEW.score, NEW.comment)
    RETURNING id, created_at INTO NEW.id, NEW.created_at;
    NEW.institution_id := v_inst_id;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_v_reviews_public_insert ON v_reviews_public;
CREATE TRIGGER trg_v_reviews_public_insert
    INSTEAD OF INSERT ON v_reviews_public
    FOR EACH ROW EXECUTE FUNCTION fn_reviews_public_insert();

-- =====================================================================
-- Після створення тригерів: приводимо агрегати відгуків у відповідність
-- =====================================================================
CALL sp_recalc_review_stats();

-- =============== ДЕМОНСТРАЦІЯ (все в транзакції з ROLLBACK — дані не змінюються) ===============

-- Демо 1. Тригер нормалізації: 'nan' -> NULL, довідники й ключі заповнюються самі
BEGIN;
INSERT INTO institutions (edbo_code, name, short_name, type, ownership, region, city, website)
VALUES (999100, 'Демонстраційний заклад', 'nan', 'Заклад вищої освіти', 'Приватна', 'Тестова область', 'Тестове місто', 'nan')
RETURNING id, short_name, website, city_id, type_id, ownership_id;

SELECT edbo_code, short_name, type_name, ownership_name, region_name, city_name
FROM   v_institutions_full WHERE edbo_code = 999100;
ROLLBACK;

-- Демо 2. Тригери історії рейтингу й аудиту: зміна рейтингу -> рядок у rating_history та audit_log
BEGIN;
UPDATE institutions SET rating_total = COALESCE(rating_total, 0) + 10
WHERE  id = (SELECT min(id) FROM institutions)
RETURNING id, rating_total;

SELECT institution_id, rating_total, recorded_at FROM rating_history ORDER BY id DESC LIMIT 2;
SELECT table_name, operation, row_id, old_data ->> 'rating_total' AS old_rating, new_data ->> 'rating_total' AS new_rating
FROM   audit_log ORDER BY id DESC LIMIT 2;
ROLLBACK;

-- Демо 3. Тригер відгуків: агрегати в institutions оновлюються автоматично
BEGIN;
INSERT INTO v_reviews_public (edbo_code, author, score, comment)       -- INSTEAD OF-тригер на представленні
SELECT edbo_code, 'Демо-автор', 5, 'Відмінно!' FROM institutions ORDER BY id LIMIT 1
RETURNING id, institution_id, author, score;

SELECT id, short_name, avg_review_score, reviews_count FROM institutions ORDER BY id LIMIT 1;
ROLLBACK;

-- Демо 4. Захист від TRUNCATE журналу аудиту
DO $$
BEGIN
    TRUNCATE audit_log;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Тригер заборонив TRUNCATE: %', SQLERRM;
END $$;

-- Список тригерів БД
SELECT event_object_table AS table_name, trigger_name, action_timing AS timing,
       string_agg(event_manipulation, ' OR ' ORDER BY event_manipulation) AS events, action_orientation AS orientation
FROM   information_schema.triggers
WHERE  trigger_schema = 'public'
GROUP  BY 1, 2, 3, 5
ORDER  BY 1, 2;
