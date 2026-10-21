-- =====================================================================
-- 07. МОДУЛЬ 3 (тема 9): змінні, тимчасові таблиці, індекси
-- =====================================================================

-- ======================= ЗМІННІ =======================
-- У PostgreSQL є три види "змінних" (аналоги MySQL @var та DECLARE):

-- (а) локальні змінні PL/pgSQL: DECLARE ... BEGIN ... END
DO $$
DECLARE
    v_total     INTEGER;
    v_avg       NUMERIC(8, 2);
    v_oldest    INTEGER := 0;                    -- змінна з початковим значенням
    v_city      institutions.city%TYPE;          -- тип береться зі стовпця
BEGIN
    SELECT count(*), avg(rating_total), min(founded_year)
    INTO   v_total, v_avg, v_oldest
    FROM   institutions;

    RAISE NOTICE 'Закладів: %, середній рейтинг: %, найстаріший заснований у %', v_total, v_avg, v_oldest;
END $$;

-- (б) змінні сесії (аналог MySQL  SET @min_rating = 100): параметри з префіксом app.
SELECT set_config('app.min_rating', '800', false) AS min_rating_set;   -- false = на всю сесію

SELECT short_name, rating_total
FROM   institutions
WHERE  rating_total >= current_setting('app.min_rating')::int
ORDER  BY rating_total DESC LIMIT 5;

-- (в) змінні psql (лише в консолі psql, у цьому раннері не працюють):
--     \set min_year 1900
--     SELECT * FROM institutions WHERE founded_year >= :min_year;

-- ======================= ТИМЧАСОВІ ТАБЛИЦІ =======================
-- Існують тільки в поточній сесії, інші користувачі їх не бачать, зникають при відключенні.

DROP TABLE IF EXISTS tmp_big_programs;

CREATE TEMP TABLE tmp_big_programs AS
SELECT i.id AS institution_id, i.short_name, s.program_name, s.students_count
FROM   institution_specialties s JOIN institutions i ON i.id = s.institution_id
WHERE  s.students_count >= 200;

-- на тимчасову таблицю можна створювати індекси і працювати як зі звичайною
CREATE INDEX ON tmp_big_programs (institution_id);

SELECT short_name, count(*) AS big_programs, sum(students_count) AS students
FROM   tmp_big_programs GROUP BY short_name ORDER BY students DESC LIMIT 5;

-- ON COMMIT DROP: таблиця живе лише до кінця транзакції (типово для проміжних розрахунків)
BEGIN;
CREATE TEMP TABLE tmp_calc (city TEXT, n INT) ON COMMIT DROP;
INSERT INTO tmp_calc SELECT city, count(*) FROM institutions GROUP BY city;
SELECT * FROM tmp_calc ORDER BY n DESC LIMIT 3;
COMMIT;

SELECT to_regclass('pg_temp.tmp_calc') AS tmp_calc_exists_after_commit;   -- NULL: таблицю видалено

-- CTE також можна вважати «табличною змінною» одного запиту
WITH big AS (SELECT * FROM tmp_big_programs)
SELECT count(*) AS rows_in_temp FROM big;

DROP TABLE IF EXISTS tmp_big_programs;

-- ======================= ІНДЕКСИ =======================
-- pg_trgm: триграмний індекс — прискорює ILIKE '%текст%' (саме так працює пошук у web/app.py)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. B-tree (типовий): рівність, діапазони, сортування
CREATE INDEX IF NOT EXISTS idx_institutions_city_id    ON institutions (city_id);
CREATE INDEX IF NOT EXISTS idx_institutions_type_id    ON institutions (type_id);

-- 2. Складений індекс: порядок стовпців важливий (спочатку те, за чим фільтруємо рівністю)
CREATE INDEX IF NOT EXISTS idx_specialties_inst_level  ON institution_specialties (institution_id, education_level);

-- 3. Частковий індекс: лише рядки, що мають рейтинг (менший і швидший)
CREATE INDEX IF NOT EXISTS idx_institutions_rated      ON institutions (rating_total DESC) WHERE rating_total IS NOT NULL;

-- 4. Індекс за виразом: пошук без урахування регістру
CREATE INDEX IF NOT EXISTS idx_institutions_lower_name ON institutions (lower(name));

-- 5. Покриваючий індекс (INCLUDE): запит бере дані прямо з індексу
CREATE INDEX IF NOT EXISTS idx_reviews_inst_cover      ON reviews (institution_id) INCLUDE (score, status);

-- 6. GIN + триграми для повнотекстового ILIKE-пошуку
CREATE INDEX IF NOT EXISTS idx_institutions_name_trgm  ON institutions USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_institutions_short_trgm ON institutions USING gin (short_name gin_trgm_ops);

-- 7. Унікальний індекс як обмеження цілісності: один відгук від автора на заклад
CREATE UNIQUE INDEX IF NOT EXISTS uq_reviews_author_inst ON reviews (institution_id, lower(author));

-- Оновлюємо статистику, щоб планувальник бачив нові індекси
ANALYZE institutions;
ANALYZE institution_specialties;

-- ---------- EXPLAIN: чи використовується індекс ----------
-- (на малих таблицях планувальник обирає Seq Scan; вимикаємо його, щоб показати індекс)
SET enable_seqscan = off;

EXPLAIN SELECT id, name FROM institutions WHERE lower(name) = lower('Київський національний університет імені Тараса Шевченка');

EXPLAIN SELECT id, short_name FROM institutions WHERE name ILIKE '%політехн%';

EXPLAIN SELECT id FROM institutions WHERE rating_total IS NOT NULL ORDER BY rating_total DESC LIMIT 5;

RESET enable_seqscan;

-- EXPLAIN ANALYZE: реальне виконання з часом
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM institution_specialties WHERE institution_id = 1;

-- ---------- Інформація про індекси ----------
SELECT tablename, indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM   pg_indexes
WHERE  schemaname = 'public' AND tablename IN ('institutions', 'institution_specialties', 'reviews')
ORDER  BY tablename, indexname;

-- ---------- Обслуговування ----------
REINDEX INDEX idx_institutions_city_id;          -- перебудова індексу
DROP INDEX IF EXISTS idx_institutions_lower_name;  -- видалення зайвого індексу
