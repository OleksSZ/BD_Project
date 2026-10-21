-- =====================================================================
-- 05. МОДУЛЬ 3 (тема 7): складова DQL — мова запитів (SELECT)
-- Від простих запитів до віконних функцій та CTE.
-- =====================================================================

-- Q1. Фільтрація: LIKE/ILIKE, IN, BETWEEN, IS NULL, логічні оператори
SELECT id, short_name, founded_year
FROM   institutions
WHERE  (name ILIKE '%університет%' OR name ILIKE '%коледж%')
  AND  founded_year BETWEEN 1800 AND 1950
  AND  ownership IN ('Державна', 'Комунальна')
  AND  website IS NOT NULL
ORDER  BY founded_year;

-- Q2. Сортування та пагінація (як у API): ORDER BY ... LIMIT ... OFFSET
SELECT id, short_name, city, rating_total
FROM   institutions
WHERE  rating_total IS NOT NULL
ORDER  BY rating_total DESC NULLS LAST, short_name
LIMIT  5 OFFSET 0;

-- Q3. Агрегація: GROUP BY + HAVING
SELECT city, count(*) AS institutions, min(founded_year) AS oldest
FROM   institutions
GROUP  BY city
HAVING count(*) >= 2
ORDER  BY institutions DESC, city;

-- Q4. Агрегація з FILTER (умовні лічильники в одному проході)
SELECT count(*)                                  AS total,
       count(*) FILTER (WHERE category_type = 1) AS higher_edu,
       count(*) FILTER (WHERE category_type = 9) AS colleges,
       count(*) FILTER (WHERE rating_total IS NOT NULL) AS rated
FROM   institutions;

-- Q5. З'єднання: INNER JOIN (3 таблиці) — програми закладів із містом і областю
SELECT i.short_name, r.name AS region, c.name AS city, s.program_name, s.students_count
FROM   institution_specialties s
JOIN   institutions i ON i.id = s.institution_id
JOIN   cities  c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
ORDER  BY s.students_count DESC NULLS LAST LIMIT 5;

-- Q6. LEFT JOIN: заклади без жодного відгуку
SELECT i.id, i.short_name
FROM   institutions i LEFT JOIN reviews r ON r.institution_id = i.id
WHERE  r.id IS NULL
ORDER  BY i.id LIMIT 5;

-- Q7. FULL JOIN: довідник спеціальностей проти реально відкритих програм
SELECT s.code, s.name, count(isp.id) AS programs
FROM   specialty_dict s FULL JOIN institution_specialties isp ON isp.specialty_code = s.code
GROUP  BY s.code, s.name
ORDER  BY programs DESC, s.code LIMIT 5;

-- Q8. Підзапити: скалярний, IN, EXISTS, корельований
SELECT i.short_name, i.rating_total,
       (SELECT round(avg(rating_total), 1) FROM institutions) AS avg_all,           -- скалярний
       (SELECT count(*) FROM institution_specialties s WHERE s.institution_id = i.id) AS programs  -- корельований
FROM   institutions i
WHERE  i.rating_total > (SELECT avg(rating_total) FROM institutions)
  AND  EXISTS (SELECT 1 FROM institution_specialties s WHERE s.institution_id = i.id)
  AND  i.city_id IN (SELECT id FROM cities WHERE name <> 'Не вказано')
ORDER  BY i.rating_total DESC LIMIT 5;

-- Q9. CTE (WITH): середній рейтинг по областях і заклади, що вищі за середнє в своїй області
WITH region_avg AS (
    SELECT c.region_id, avg(i.rating_total) AS avg_rating
    FROM   institutions i JOIN cities c ON c.id = i.city_id
    WHERE  i.rating_total IS NOT NULL
    GROUP  BY c.region_id
)
SELECT i.short_name, r.name AS region, i.rating_total, round(ra.avg_rating, 1) AS region_avg
FROM   institutions i
JOIN   cities c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
JOIN   region_avg ra ON ra.region_id = c.region_id
WHERE  i.rating_total > ra.avg_rating
ORDER  BY i.rating_total DESC;

-- Q10. Рекурсивний CTE: розподіл закладів за десятиліттями заснування (генерація послідовності)
WITH RECURSIVE decades(decade) AS (
    SELECT 1800
    UNION ALL
    SELECT decade + 50 FROM decades WHERE decade < 2000
)
SELECT d.decade AS from_year, d.decade + 49 AS to_year, count(i.id) AS institutions
FROM   decades d
LEFT   JOIN institutions i ON i.founded_year BETWEEN d.decade AND d.decade + 49
GROUP  BY d.decade
ORDER  BY d.decade;

-- Q11. Віконні функції: місце закладу в області, попередній за рейтингом, накопичувальна сума
SELECT r.name AS region, i.short_name, i.rating_total,
       RANK()  OVER (PARTITION BY r.id ORDER BY i.rating_total DESC) AS rank_in_region,
       LAG(i.rating_total) OVER (PARTITION BY r.id ORDER BY i.rating_total DESC) AS prev_rating,
       SUM(i.rating_total) OVER (PARTITION BY r.id ORDER BY i.rating_total DESC) AS running_sum
FROM   institutions i
JOIN   cities c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
WHERE  i.rating_total IS NOT NULL
ORDER  BY r.name, rank_in_region LIMIT 8;

-- Q12. DISTINCT ON: найстаріший заклад у кожній області
SELECT DISTINCT ON (r.name) r.name AS region, i.short_name, i.founded_year
FROM   institutions i
JOIN   cities c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
WHERE  i.founded_year IS NOT NULL
ORDER  BY r.name, i.founded_year;

-- Q13. CASE: класифікація закладів за віком
SELECT short_name, founded_year,
       CASE WHEN founded_year IS NULL            THEN 'невідомо'
            WHEN founded_year < 1900             THEN 'історичний (до 1900)'
            WHEN founded_year < 1991             THEN 'радянський період'
            ELSE                                      'сучасний (після 1991)' END AS era
FROM   institutions ORDER BY founded_year NULLS LAST LIMIT 6;

-- Q14. ROLLUP: підсумки по областях і загальний підсумок
SELECT COALESCE(r.name, '== УСЬОГО ==') AS region,
       COALESCE(t.name, '(усі типи)')    AS type,
       count(*) AS institutions
FROM   institutions i
JOIN   cities c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
JOIN   institution_types t ON t.id = i.type_id
GROUP  BY ROLLUP (r.name, t.name)
ORDER  BY r.name NULLS LAST, t.name NULLS LAST LIMIT 10;

-- Q15. Пошук програм, чия акредитація спливає (використовує fn_parse_date)
SELECT i.short_name, s.program_name, s.accreditation_valid_until,
       fn_parse_date(s.accreditation_valid_until::text) - CURRENT_DATE AS days_left
FROM   institution_specialties s JOIN institutions i ON i.id = s.institution_id
WHERE  fn_parse_date(s.accreditation_valid_until::text) IS NOT NULL
ORDER  BY days_left LIMIT 5;
