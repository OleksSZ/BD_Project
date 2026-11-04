-- ЛР №9. Запити до одного відношення: SELECT ... FROM ... WHERE ... ORDER BY
-- =====================================================================
-- Команди: SELECT (стовпці, *, псевдоніми AS), DISTINCT, WHERE з операторами порівняння,
-- AND / OR / NOT, IN / NOT IN, BETWEEN, LIKE / ILIKE (%, _), IS [NOT] NULL,
-- агрегатні функції COUNT / SUM / AVG / MIN / MAX, COUNT(DISTINCT), GROUP BY, HAVING,
-- ORDER BY (ASC / DESC, кілька полів, номер стовпця, NULLS LAST), LIMIT / OFFSET,
-- обчислювані стовпці та текст у виводі.
-- Кожен запит звертається лише до ОДНІЄЇ таблиці.
-- Запуск: python db/lab.py 9
-- =====================================================================

-- == 1. Вибір стовпців ==
-- усі стовпці таблиці
SELECT * FROM regions;

-- лише потрібні стовпці в заданому порядку + псевдоніми (AS)
SELECT short_name AS "Заклад", founded_year AS "Рік заснування", city AS "Місто"
FROM   institutions
LIMIT  5;

-- DISTINCT: значення без повторень — які освітні рівні взагалі зустрічаються
SELECT DISTINCT education_level FROM institution_specialties ORDER BY 1;

-- == 2. Умови WHERE ==
-- оператор порівняння: заклади, засновані до 1900 року
SELECT short_name, founded_year FROM institutions WHERE founded_year < 1900 ORDER BY founded_year;

-- AND: державні заклади вищої освіти з рейтингом понад 900
SELECT short_name, ownership, rating_total
FROM   institutions
WHERE  category_type = 1 AND ownership = 'Державна' AND rating_total > 900;

-- OR / NOT: заклади з Києва або Львова, які НЕ є державними
SELECT short_name, city, ownership
FROM   institutions
WHERE  (city = 'Київ' OR city = 'Львів') AND NOT ownership = 'Державна';

-- IN: місто з переліку
SELECT short_name, city FROM institutions WHERE city IN ('Харків', 'Одеса', 'Дніпро') ORDER BY city;

-- NOT IN: усі, крім закладів вищої освіти (1) та фахової передвищої (9)
SELECT short_name, category_type FROM institutions WHERE category_type NOT IN (1, 9);

-- BETWEEN для чисел (межі включно)
SELECT short_name, rating_total FROM institutions WHERE rating_total BETWEEN 800 AND 900 ORDER BY 2 DESC;

-- BETWEEN для рядків: назви, що починаються на літери від «К» до «Л»
SELECT short_name FROM institutions WHERE short_name BETWEEN 'К' AND 'Лz' ORDER BY 1;

-- LIKE з шаблоном: «%» — будь-яка кількість символів, «_» — рівно один символ
SELECT name FROM institutions WHERE name LIKE 'Київ%';
SELECT short_name FROM institutions WHERE short_name LIKE '_НУ';

-- ILIKE — LIKE без урахування регістру (у MySQL LIKE і так не чутливий до регістру)
SELECT name FROM institutions WHERE name ILIKE '%ПОЛІТЕХН%';

-- IS NULL / IS NOT NULL: «= NULL» не працює, потрібен саме IS
SELECT short_name, website FROM institutions WHERE website IS NULL LIMIT 5;
SELECT count(*) AS with_rating FROM institutions WHERE rating_total IS NOT NULL;

-- == 3. Агрегатні функції ==
-- COUNT(*) рахує рядки, COUNT(стовпець) — лише не-NULL значення, COUNT(DISTINCT) — різні значення
SELECT count(*)               AS all_rows,
       count(rating_total)    AS with_rating,
       count(DISTINCT city)   AS different_cities
FROM   institutions;

-- SUM, AVG, MIN, MAX
SELECT sum(students_count)          AS students_total,
       round(avg(students_count), 1) AS students_avg,
       min(students_count)          AS min_program,
       max(students_count)          AS max_program
FROM   institution_specialties;

-- == 4. GROUP BY та HAVING ==
-- кількість закладів і найстаріший рік заснування в кожному місті
SELECT city, count(*) AS institutions, min(founded_year) AS oldest
FROM   institutions
GROUP  BY city
ORDER  BY institutions DESC, city;

-- найвищий рейтинг у кожному місті
SELECT city, max(rating_total) AS best_rating FROM institutions GROUP BY city ORDER BY 2 DESC NULLS LAST;

-- групування за кількома полями: програми за рівнем і спеціальністю
SELECT education_level, specialty_code, count(*) AS programs
FROM   institution_specialties
GROUP  BY education_level, specialty_code
ORDER  BY education_level, programs DESC
LIMIT  8;

-- HAVING — умова на ГРУПУ (WHERE фільтрує рядки до групування, HAVING — після)
SELECT city, count(*) AS institutions
FROM   institutions
WHERE  category_type = 1
GROUP  BY city
HAVING count(*) >= 2;

-- кількість різних закладів, що мають програми з кожної спеціальності (заклад рахується один раз)
SELECT specialty_code, count(DISTINCT institution_id) AS institutions
FROM   institution_specialties
GROUP  BY specialty_code
ORDER  BY institutions DESC;

-- == 5. Сортування та обмеження виводу ==
-- кілька полів, різні напрямки
SELECT city, short_name, founded_year FROM institutions ORDER BY city ASC, founded_year DESC LIMIT 8;

-- сортування за номером стовпця та NULLS LAST (рядки без рейтингу — в кінці)
SELECT short_name, rating_total FROM institutions ORDER BY 2 DESC NULLS LAST LIMIT 5;

-- LIMIT / OFFSET — «сторінка» результатів (друга сторінка по 5 рядків)
SELECT id, short_name FROM institutions ORDER BY id LIMIT 5 OFFSET 5;

-- == 6. Обчислення у запитах ==
-- обчислюваний стовпець: вік закладу та «прогноз» кількості здобувачів +12%
SELECT short_name,
       founded_year,
       extract(year FROM current_date)::int - founded_year AS age_years
FROM   institutions
WHERE  founded_year IS NOT NULL
ORDER  BY age_years DESC
LIMIT  5;

SELECT program_name, students_count, round(students_count * 1.12) AS forecast_plus_12
FROM   institution_specialties
ORDER  BY students_count DESC
LIMIT  5;

-- текст у виводі: «Для міста X найвищий рейтинг: Y»
SELECT 'Для міста ' || city || ' найвищий рейтинг: ' || max(rating_total) AS report
FROM   institutions
WHERE  rating_total IS NOT NULL
GROUP  BY city
ORDER  BY max(rating_total) DESC;
