-- =====================================================================
-- 06. МОДУЛЬ 3 (тема 8): ПРЕДСТАВЛЕННЯ (VIEW)
-- звичайні, агрегуючі, змінювані (WITH CHECK OPTION), матеріалізовані
-- =====================================================================

-- ---------- 1. Звичайне представлення: «плоский» вигляд нормалізованих таблиць ----------
-- Приховує складні JOIN-и; web/app.py та аналітика працюють з ним як з однією таблицею.
CREATE OR REPLACE VIEW v_institutions_full AS
SELECT i.id,
       i.edbo_code,
       i.name,
       i.short_name,
       t.name  AS type_name,
       o.name  AS ownership_name,
       r.name  AS region_name,
       c.name  AS city_name,
       i.address,
       i.website,
       i.founded_year,
       i.category_type,
       i.rating,
       i.rating_total,
       i.rating_city_position,
       i.rating_general_position,
       i.avg_review_score,
       i.reviews_count
FROM   institutions i
LEFT   JOIN cities            c ON c.id = i.city_id
LEFT   JOIN regions           r ON r.id = c.region_id
LEFT   JOIN institution_types t ON t.id = i.type_id
LEFT   JOIN ownership_forms   o ON o.id = i.ownership_id;

-- ---------- 2. Агрегуюче представлення: статистика по областях ----------
CREATE OR REPLACE VIEW v_region_stats AS
SELECT r.id                                   AS region_id,
       r.name                                 AS region_name,
       count(DISTINCT i.id)                   AS institutions,
       count(DISTINCT c.id)                   AS cities,
       round(avg(i.rating_total), 1)          AS avg_rating,
       COALESCE(sum(sp.students), 0)::bigint  AS students
FROM   regions r
LEFT   JOIN cities c ON c.region_id = r.id
LEFT   JOIN institutions i ON i.city_id = c.id
LEFT   JOIN (SELECT institution_id, sum(students_count) AS students
             FROM   institution_specialties GROUP BY institution_id) sp ON sp.institution_id = i.id
GROUP  BY r.id, r.name;

-- ---------- 3. Представлення з бізнес-логікою: рейтингові ТОП-заклади ----------
CREATE OR REPLACE VIEW v_top_institutions AS
SELECT id, name, short_name, type_name, city_name, rating_total, rating_city_position,
       RANK() OVER (ORDER BY rating_total DESC) AS place
FROM   v_institutions_full
WHERE  rating_total IS NOT NULL;

-- ---------- 4. Змінюване представлення з WITH CHECK OPTION ----------
-- Через нього можна додавати/змінювати ЛИШЕ заклади вищої освіти (category_type = 1)
CREATE OR REPLACE VIEW v_higher_education AS
SELECT id, edbo_code, name, short_name, category_type, city, region
FROM   institutions
WHERE  category_type = 1
WITH CHECK OPTION;

-- демонстрація: коректний INSERT проходить, INSERT з іншою категорією — відхиляється
DO $$
BEGIN
    INSERT INTO v_higher_education (edbo_code, name, short_name, category_type, city, region)
    VALUES (999001, 'Тестовий університет', 'ТУ', 1, 'Київ', 'м. Київ');
    RAISE NOTICE 'INSERT через представлення (category_type=1) — успішно';

    BEGIN
        INSERT INTO v_higher_education (edbo_code, name, short_name, category_type)
        VALUES (999002, 'Тестовий коледж', 'ТК', 9);
    EXCEPTION WHEN with_check_option_violation THEN
        RAISE NOTICE 'INSERT з category_type=9 відхилено WITH CHECK OPTION: %', SQLERRM;
    END;

    DELETE FROM v_higher_education WHERE edbo_code = 999001;   -- прибираємо за собою
END $$;

-- ---------- 5. Представлення для публічного API: відгуки без службових полів ----------
CREATE OR REPLACE VIEW v_reviews_public AS
SELECT r.id, r.institution_id, i.edbo_code, i.short_name AS institution,
       r.author, r.score, r.comment, r.created_at
FROM   reviews r
JOIN   institutions i ON i.id = r.institution_id
WHERE  r.status = 'approved';

-- ---------- 6. Матеріалізоване представлення: «кеш» важкого агрегату ----------
DROP MATERIALIZED VIEW IF EXISTS mv_region_stats;
CREATE MATERIALIZED VIEW mv_region_stats AS
SELECT * FROM v_region_stats
WITH DATA;

-- унікальний індекс потрібен для REFRESH ... CONCURRENTLY (оновлення без блокування читання)
CREATE UNIQUE INDEX uq_mv_region_stats ON mv_region_stats (region_id);

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_region_stats;

-- ---------- Використання ----------
SELECT region_name, institutions, avg_rating, students
FROM   mv_region_stats ORDER BY institutions DESC LIMIT 5;

SELECT * FROM v_top_institutions ORDER BY place LIMIT 5;

-- ---------- Керування представленнями ----------
-- перейменування, зміна власника, видалення
CREATE OR REPLACE VIEW v_demo AS SELECT 1 AS x;
ALTER VIEW v_demo RENAME TO v_demo_renamed;
DROP VIEW v_demo_renamed;

-- перелік представлень БД і їх визначення (аналог SHOW CREATE VIEW)
SELECT viewname, left(regexp_replace(definition, '\s+', ' ', 'g'), 90) AS definition
FROM   pg_views WHERE schemaname = 'public' ORDER BY viewname;
