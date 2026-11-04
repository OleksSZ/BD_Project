-- ЛР №13. Представлення (VIEW)
-- =====================================================================
-- Команди: CREATE VIEW, CREATE OR REPLACE VIEW, представлення з переліком стовпців,
-- агрегуюче представлення, представлення на основі іншого представлення,
-- модифіковане (updatable) представлення: INSERT / UPDATE / DELETE через нього,
-- WITH LOCAL / CASCADED CHECK OPTION, немодифіковане представлення (помилка),
-- MATERIALIZED VIEW + REFRESH, ALTER VIEW ... RENAME, DROP VIEW (RESTRICT / CASCADE),
-- перелік представлень у каталозі.
-- Усе — всередині BEGIN ... ROLLBACK (робочі представлення з 06_views.sql не змінюються).
-- Запуск: python db/lab.py 13
-- =====================================================================

BEGIN;

-- == 1. Створення представлень ==
-- просте представлення: приховує з'єднання трьох таблиць
CREATE VIEW lab_v_institutions AS
SELECT i.id, i.short_name, i.category_type, i.rating_total, c.name AS city, r.name AS region
FROM   institutions i
JOIN   cities  c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id;

-- з представленням працюють як із таблицею
SELECT * FROM lab_v_institutions WHERE region = 'м. Київ' ORDER BY rating_total DESC NULLS LAST;

-- перелік стовпців у CREATE VIEW (v (a, b, c)) задає імена стовпців представлення
CREATE VIEW lab_v_city_count (city, institutions, best_rating) AS
SELECT city, count(*), max(rating_total)
FROM   lab_v_institutions
GROUP  BY city;

SELECT * FROM lab_v_city_count ORDER BY institutions DESC;

-- представлення на основі іншого представлення: заклади з найвищим рейтингом у своєму місті
CREATE VIEW lab_v_city_leaders AS
SELECT v.short_name, v.city, v.rating_total
FROM   lab_v_institutions v
JOIN   lab_v_city_count c ON c.city = v.city AND c.best_rating = v.rating_total;

SELECT * FROM lab_v_city_leaders ORDER BY rating_total DESC;

-- агрегуюче представлення: середня і загальна кількість здобувачів кожного закладу
CREATE VIEW lab_v_students AS
SELECT i.short_name, count(s.id) AS programs,
       sum(s.students_count) AS students_total, round(avg(s.students_count), 1) AS students_avg
FROM   institutions i
JOIN   institution_specialties s ON s.institution_id = i.id
GROUP  BY i.id, i.short_name;

SELECT * FROM lab_v_students ORDER BY students_total DESC;

-- CREATE OR REPLACE: змінити визначення (дозволено ДОДАВАТИ стовпці в кінець)
CREATE OR REPLACE VIEW lab_v_students AS
SELECT i.short_name, count(s.id) AS programs,
       sum(s.students_count) AS students_total, round(avg(s.students_count), 1) AS students_avg,
       max(s.students_count) AS students_max
FROM   institutions i
JOIN   institution_specialties s ON s.institution_id = i.id
GROUP  BY i.id, i.short_name;

SELECT * FROM lab_v_students ORDER BY students_max DESC LIMIT 3;

-- == 2. Модифіковане представлення ==
-- одна таблиця, без агрегатів і DISTINCT -> через представлення можна змінювати дані
-- (аналог Commissions з методички: лише частина стовпців таблиці)
CREATE VIEW lab_v_ratings AS
SELECT id, short_name, rating_total
FROM   institutions
WHERE  rating_total IS NOT NULL;

UPDATE lab_v_ratings SET rating_total = rating_total + 5
WHERE  id = (SELECT min(id) FROM lab_v_ratings)
RETURNING id, short_name, rating_total;

-- зміна через представлення потрапила в базову таблицю
SELECT id, short_name, rating_total FROM institutions WHERE id = (SELECT min(id) FROM lab_v_ratings);

-- == 3. WITH CHECK OPTION ==
-- LOCAL CHECK OPTION: через представлення не можна записати рядок, який воно потім «не побачить»
CREATE VIEW lab_v_top AS
SELECT id, short_name, rating_total FROM lab_v_ratings WHERE rating_total >= 900
WITH LOCAL CHECK OPTION;

SAVEPOINT sp;
-- очікувана помилка: рейтинг 500 не задовольняє умові rating_total >= 900
UPDATE lab_v_top SET rating_total = 500 WHERE id = (SELECT min(id) FROM lab_v_top);
ROLLBACK TO SAVEPOINT sp;

-- LOCAL перевіряє лише умову цього представлення: NULL-рейтинг (умова базового представлення) пропускається
UPDATE lab_v_top SET rating_total = rating_total WHERE id = (SELECT min(id) FROM lab_v_top);

-- CASCADED перевіряє умови і цього, і всіх базових представлень
CREATE OR REPLACE VIEW lab_v_top AS
SELECT id, short_name, rating_total FROM lab_v_ratings WHERE rating_total >= 900
WITH CASCADED CHECK OPTION;

-- очікувана помилка: NULL не проходить умову базового представлення (rating_total IS NOT NULL)
UPDATE lab_v_top SET rating_total = NULL WHERE id = (SELECT min(id) FROM lab_v_top);
ROLLBACK TO SAVEPOINT sp;

-- == 4. Немодифіковане представлення ==
-- очікувана помилка: представлення з GROUP BY / агрегатами змінювати не можна
UPDATE lab_v_students SET programs = 0;
ROLLBACK TO SAVEPOINT sp;

-- які представлення модифіковані — з каталогу
SELECT table_name, is_updatable, is_insertable_into, check_option
FROM   information_schema.views
WHERE  table_name LIKE 'lab\_v\_%'
ORDER  BY table_name;

-- == 5. Матеріалізоване представлення ==
-- результат зберігається фізично (як кеш) і оновлюється командою REFRESH
CREATE MATERIALIZED VIEW lab_mv_city_count AS SELECT * FROM lab_v_city_count;

-- дані змінились, а матеріалізоване представлення — ще ні
UPDATE institutions SET rating_total = 1000 WHERE id = (SELECT min(id) FROM institutions WHERE rating_total IS NOT NULL);
SELECT city, best_rating AS old_value_in_mv FROM lab_mv_city_count ORDER BY best_rating DESC NULLS LAST LIMIT 1;

REFRESH MATERIALIZED VIEW lab_mv_city_count;
SELECT city, best_rating AS after_refresh FROM lab_mv_city_count ORDER BY best_rating DESC NULLS LAST LIMIT 1;

-- == 6. Керування представленнями ==
-- перейменування
ALTER VIEW lab_v_city_leaders RENAME TO lab_v_leaders;

-- очікувана помилка: DROP (RESTRICT за замовчуванням) — від представлення залежать інші
DROP VIEW lab_v_institutions;
ROLLBACK TO SAVEPOINT sp;

-- DROP ... CASCADE видаляє представлення разом із залежними; дані таблиць не зачіпаються
DROP VIEW lab_v_institutions CASCADE;

-- перелік представлень, що залишились у схемі (аналог SHOW FULL TABLES WHERE table_type = 'VIEW')
SELECT table_name FROM information_schema.views WHERE table_schema = 'public' ORDER BY 1;

ROLLBACK;
