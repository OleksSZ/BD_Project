-- =====================================================================
-- 09. МОДУЛЬ 4 (тема 11): процедури та функції користувача (PL/pgSQL)
-- Функція  — CREATE FUNCTION, викликається у SELECT, повертає значення/таблицю.
-- Процедура — CREATE PROCEDURE, викликається через CALL, може керувати транзакціями (COMMIT).
-- Помилки/винятки з процедур перехоплює web/app.py і перетворює на HTTP 400/404/409.
-- =====================================================================

-- =============== ФУНКЦІЇ ===============

-- 1. Проста SQL-функція (IMMUTABLE): текстова категорія рейтингу
CREATE OR REPLACE FUNCTION fn_rating_label(p_rating INTEGER)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
               WHEN p_rating IS NULL  THEN 'без рейтингу'
               WHEN p_rating >= 900   THEN 'топ'
               WHEN p_rating >= 700   THEN 'високий'
               WHEN p_rating >= 400   THEN 'середній'
               ELSE                        'базовий'
           END
$$;

-- 2. Функція з обробкою винятків: безпечне ділення (аналог IFNULL(a/NULLIF(b,0)) у MySQL)
CREATE OR REPLACE FUNCTION fn_safe_ratio(p_a NUMERIC, p_b NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN round(p_a / p_b, 2);
EXCEPTION
    WHEN division_by_zero THEN
        RETURN NULL;
END $$;

-- 3. Функція зі змінною кількістю аргументів (VARIADIC) та IF/ELSIF
CREATE OR REPLACE FUNCTION fn_max_of(VARIADIC p_nums INTEGER[])
RETURNS INTEGER
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_max INTEGER;
    v_n   INTEGER;
BEGIN
    FOREACH v_n IN ARRAY p_nums LOOP
        IF v_max IS NULL OR v_n > v_max THEN
            v_max := v_n;
        END IF;
    END LOOP;
    RETURN v_max;
END $$;

-- 4. Статус акредитації програми (використовує fn_parse_date з файлу 01)
CREATE OR REPLACE FUNCTION fn_accreditation_status(p_valid_until TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_date DATE := fn_parse_date(p_valid_until);
BEGIN
    IF v_date IS NULL THEN
        RETURN 'невідомо';
    ELSIF v_date < CURRENT_DATE THEN
        RETURN 'прострочена';
    ELSIF v_date < CURRENT_DATE + 365 THEN
        RETURN 'спливає протягом року';
    ELSE
        RETURN 'діє';
    END IF;
END $$;

-- 5. Табличнa функція: пошук закладів з фільтрами й пагінацією.
--    Замінює динамічне склеювання SQL у web/app.py (GET /api/institutions).
--    total_count — загальна кількість знайдених (для пагінації) в тому ж запиті.
CREATE OR REPLACE FUNCTION fn_search_institutions(
    p_search TEXT    DEFAULT NULL,
    p_city   TEXT    DEFAULT NULL,
    p_region TEXT    DEFAULT NULL,
    p_type   TEXT    DEFAULT NULL,
    p_limit  INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id          INTEGER,
    name        TEXT,
    short_name  TEXT,
    type        TEXT,
    city        TEXT,
    region      TEXT,
    rating      INTEGER,
    website     TEXT,
    total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v_search TEXT := '%' || NULLIF(btrim(p_search), '') || '%';   -- NULL, якщо рядок порожній
    v_city   TEXT := '%' || NULLIF(btrim(p_city),   '') || '%';
    v_region TEXT := '%' || NULLIF(btrim(p_region), '') || '%';
    v_type   TEXT := '%' || NULLIF(btrim(p_type),   '') || '%';
BEGIN
    IF p_limit < 1 OR p_limit > 200 THEN
        RAISE EXCEPTION 'limit має бути від 1 до 200, отримано %', p_limit
              USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    SELECT v.id,
           v.name::text,
           v.short_name::text,
           v.type_name::text,
           v.city_name::text,
           v.region_name::text,
           v.rating,
           v.website::text,
           count(*) OVER ()
    FROM   v_institutions_full v
    WHERE  (v_search IS NULL OR v.name ILIKE v_search OR v.short_name ILIKE v_search
                             OR v.city_name ILIKE v_search OR v.region_name ILIKE v_search)
      AND  (v_city   IS NULL OR v.city_name   ILIKE v_city)
      AND  (v_region IS NULL OR v.region_name ILIKE v_region)
      AND  (v_type   IS NULL OR v.type_name   ILIKE v_type)
    ORDER  BY v.name
    LIMIT  p_limit OFFSET p_offset;
END $$;

-- 6. Функція з циклом FOR та RETURN NEXT: розподіл закладів за категоріями рейтингу
CREATE OR REPLACE FUNCTION fn_rating_distribution()
RETURNS TABLE (label TEXT, institutions_count INTEGER)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT fn_rating_label(rating_total) AS lbl, count(*)::int AS cnt
        FROM   institutions
        GROUP  BY 1
        ORDER  BY 2 DESC
    LOOP
        label := rec.lbl;
        institutions_count := rec.cnt;
        RETURN NEXT;
    END LOOP;
END $$;

-- 7. Функція, що повертає JSON: «картка» закладу (для REST API)
CREATE OR REPLACE FUNCTION fn_institution_card(p_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_card JSONB;
BEGIN
    SELECT jsonb_build_object(
               'id', v.id, 'name', v.name, 'city', v.city_name, 'region', v.region_name,
               'rating', v.rating_total, 'rating_label', fn_rating_label(v.rating_total),
               'reviews', jsonb_build_object('count', v.reviews_count, 'avg', v.avg_review_score),
               'programs', (SELECT count(*) FROM institution_specialties s WHERE s.institution_id = v.id),
               'students',  (SELECT COALESCE(sum(students_count), 0) FROM institution_specialties s WHERE s.institution_id = v.id))
    INTO   v_card
    FROM   v_institutions_full v
    WHERE  v.id = p_id;

    IF v_card IS NULL THEN
        RAISE EXCEPTION 'Заклад з id=% не знайдено', p_id USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_card;
END $$;

-- =============== ПРОЦЕДУРИ ===============

-- 1. Додавання відгуку з валідацією (INOUT-параметр повертає id нового відгуку)
CREATE OR REPLACE PROCEDURE sp_add_review(
    p_institution_id INTEGER,
    p_author         TEXT,
    p_score          INTEGER,
    p_comment        TEXT,
    INOUT p_review_id INTEGER
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_score NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'Оцінка має бути від 1 до 5, отримано %', p_score USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM institutions WHERE id = p_institution_id) THEN
        RAISE EXCEPTION 'Заклад з id=% не знайдено', p_institution_id USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO reviews (institution_id, author, score, comment)
    VALUES (p_institution_id, btrim(p_author), p_score, NULLIF(btrim(p_comment), ''))
    RETURNING id INTO p_review_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Автор "%" вже залишав відгук про цей заклад', p_author USING ERRCODE = 'unique_violation';
END $$;

-- 2. Оновлення рейтингу закладу (історію пише тригер trg_institutions_rating_history)
CREATE OR REPLACE PROCEDURE sp_update_rating(
    p_institution_id INTEGER,
    p_total          INTEGER,
    p_city_position  INTEGER DEFAULT NULL,
    p_general_pos    TEXT    DEFAULT NULL,
    p_nmt            INTEGER DEFAULT NULL,
    p_top200         INTEGER DEFAULT NULL,
    p_scopus         INTEGER DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE institutions
    SET    rating                  = p_total,
           rating_total            = p_total,
           rating_city_position    = p_city_position,
           rating_general_position = p_general_pos,
           rating_nmt_score        = p_nmt,
           rating_top200           = p_top200,
           rating_scopus           = p_scopus,
           rating_updated_at       = CURRENT_TIMESTAMP
    WHERE  id = p_institution_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заклад з id=% не знайдено', p_institution_id USING ERRCODE = 'no_data_found';
    END IF;
END $$;

-- 3. Модерація відгуку
CREATE OR REPLACE PROCEDURE sp_moderate_review(p_review_id INTEGER, p_status review_status)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE reviews SET status = p_status WHERE id = p_review_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Відгук id=% не знайдено', p_review_id USING ERRCODE = 'no_data_found';
    END IF;
END $$;

-- 4. Пакетний імпорт рейтингів з JSON — усе або нічого (атомарність, тема 15)
--    p_data: [{"edbo_code": 900001, "total": 990, "city_position": 1, "general_position": "1"}, ...]
CREATE OR REPLACE PROCEDURE sp_import_ratings(p_data JSONB, INOUT p_updated INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    item JSONB;
    v_id INTEGER;
BEGIN
    p_updated := 0;
    FOR item IN SELECT * FROM jsonb_array_elements(p_data) LOOP
        SELECT id INTO v_id FROM institutions WHERE edbo_code = (item ->> 'edbo_code')::int;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Невідомий edbo_code=% — імпорт скасовано повністю', item ->> 'edbo_code'
                  USING ERRCODE = 'no_data_found';
        END IF;
        CALL sp_update_rating(v_id, (item ->> 'total')::int, (item ->> 'city_position')::int,
                              item ->> 'general_position');
        p_updated := p_updated + 1;
    END LOOP;
END $$;

-- 5. Повний перерахунок агрегатів відгуків (службова, викликається подією/планувальником)
CREATE OR REPLACE PROCEDURE sp_recalc_review_stats()
LANGUAGE plpgsql AS $$
DECLARE
    v_rows INTEGER;
BEGIN
    UPDATE institutions i
    SET    avg_review_score = s.avg_score,
           reviews_count    = COALESCE(s.cnt, 0)
    FROM  (SELECT i2.id,
                  round(avg(r.score) FILTER (WHERE r.status = 'approved'), 2) AS avg_score,
                  count(r.id)        FILTER (WHERE r.status = 'approved')     AS cnt
           FROM   institutions i2 LEFT JOIN reviews r ON r.institution_id = i2.id
           GROUP  BY i2.id) s
    WHERE  s.id = i.id
      AND (i.avg_review_score IS DISTINCT FROM s.avg_score OR i.reviews_count IS DISTINCT FROM COALESCE(s.cnt, 0));

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO maintenance_log (task, details) VALUES ('recalc_review_stats', 'оновлено закладів: ' || v_rows);
END $$;

-- 6. Очищення журналу аудиту порціями з COMMIT усередині процедури
--    (керування транзакціями в процедурі — лише PostgreSQL 11+, викликати не всередині BEGIN...COMMIT)
CREATE OR REPLACE PROCEDURE sp_cleanup_old_audit(p_days INTEGER DEFAULT 90, p_batch INTEGER DEFAULT 1000)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows  INTEGER;
    v_total INTEGER := 0;
BEGIN
    LOOP
        DELETE FROM audit_log
        WHERE  id IN (SELECT id FROM audit_log
                      WHERE  changed_at < now() - make_interval(days => p_days)
                      LIMIT  p_batch);
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXIT WHEN v_rows = 0;
        v_total := v_total + v_rows;
        COMMIT;                                      -- фіксуємо кожну порцію окремо
    END LOOP;

    INSERT INTO maintenance_log (task, details)
    VALUES ('cleanup_old_audit', format('видалено записів: %s (старші за %s днів)', v_total, p_days));
END $$;

-- =============== ВИКЛИК (демонстрація) ===============
SELECT fn_rating_label(950) AS l1, fn_rating_label(NULL) AS l2,
       fn_safe_ratio(10, 4) AS ratio, fn_safe_ratio(1, 0) AS div_by_zero,
       fn_max_of(3, 9, 4)   AS max_of,
       fn_accreditation_status('31.12.2099') AS acc_status;

SELECT * FROM fn_rating_distribution();

SELECT id, name, city, rating, total_count FROM fn_search_institutions('універс', NULL, NULL, NULL, 3, 0);

SELECT fn_institution_card((SELECT min(id) FROM institutions));

-- процедура з INOUT-параметром повертає id нового відгуку
-- (на верхньому рівні:  CALL sp_add_review(1, 'Автор', 4, 'Текст', NULL);  — у PL/pgSQL аргументом INOUT має бути змінна)
DO $$
DECLARE
    v_inst   INTEGER := (SELECT min(id) FROM institutions);
    v_review INTEGER;
BEGIN
    IF v_inst IS NULL THEN
        RAISE NOTICE 'У БД ще немає закладів — завантажте дані (parser/test.py) або db/sql/99_sample_data.sql';
        RETURN;
    END IF;
    CALL sp_add_review(v_inst, 'Тест Тестович', 4, 'Створено викликом процедури', v_review);
    RAISE NOTICE 'Процедура створила відгук id=%', v_review;
END $$;

-- помилка валідації: оцінка поза діапазоном (виняток перехоплюється нижче)
DO $$
DECLARE
    v_new_id INTEGER;            -- в PL/pgSQL INOUT-аргументом має бути змінна, а не літерал
    v_inst   INTEGER := COALESCE((SELECT min(id) FROM institutions), 1);
BEGIN
    CALL sp_add_review(v_inst, 'Інший автор', 9, 'погана оцінка', v_new_id);
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'Процедура відхилила виклик: %', SQLERRM;
END $$;

DELETE FROM reviews WHERE author = 'Тест Тестович';
