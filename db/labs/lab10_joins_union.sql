-- ЛР №10. Об'єднання таблиць (JOIN) та об'єднання запитів (UNION)
-- =====================================================================
-- Команди: з'єднання через WHERE і через JOIN ... ON, INNER JOIN, JOIN ... USING, NATURAL JOIN,
-- LEFT / RIGHT / FULL OUTER JOIN, CROSS JOIN, самоз'єднання (self join), з'єднання 3+ таблиць,
-- складена умова з'єднання, JOIN + GROUP BY, UNION, UNION ALL, INTERSECT, EXCEPT.
-- Запуск: python db/lab.py 10
-- =====================================================================

-- == 1. Внутрішнє з'єднання ==
-- «старий» синтаксис: таблиці через кому, умова з'єднання у WHERE
SELECT i.short_name, c.name AS city
FROM   institutions i, cities c
WHERE  c.id = i.city_id
LIMIT  5;

-- те саме через INNER JOIN ... ON (умова з'єднання окремо від умов фільтрації)
SELECT i.short_name, c.name AS city
FROM   institutions i
INNER  JOIN cities c ON c.id = i.city_id
WHERE  i.category_type = 1
LIMIT  5;

-- з'єднання трьох таблиць: заклад -> місто -> область
SELECT i.short_name, c.name AS city, r.name AS region
FROM   institutions i
JOIN   cities  c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
ORDER  BY r.name, i.short_name
LIMIT  8;

-- JOIN ... USING: коли стовпці з'єднання мають однакову назву (тут city_id в обох підзапитах)
SELECT short_name, city_name
FROM   (SELECT short_name, city_id FROM institutions) i
JOIN   (SELECT id AS city_id, name AS city_name FROM cities) c USING (city_id)
LIMIT  5;

-- NATURAL JOIN: з'єднання за ВСІМА однаковими назвами стовпців (зручно, але ризиковано)
SELECT region_id, region_name, name AS city
FROM   (SELECT id AS region_id, name AS region_name FROM regions) r
NATURAL JOIN cities
ORDER  BY region_name;

-- складена умова з'єднання (AND у ON) та θ-з'єднання (нерівність)
SELECT a.short_name AS older, b.short_name AS younger, a.city, a.founded_year, b.founded_year
FROM   institutions a
JOIN   institutions b ON b.city_id = a.city_id AND a.founded_year < b.founded_year
ORDER  BY a.city, a.founded_year
LIMIT  6;

-- == 2. Самоз'єднання (self join) ==
-- усі пари закладів з одного міста; a.id < b.id прибирає пари «сам із собою» та дзеркальні дублікати
SELECT a.short_name AS first, b.short_name AS second, a.city
FROM   institutions a
JOIN   institutions b ON a.city_id = b.city_id AND a.id < b.id
ORDER  BY a.city, 1, 2
LIMIT  8;

-- == 3. Зовнішні з'єднання ==
-- LEFT JOIN: усі заклади, навіть без жодного відгуку (тоді поля відгуку = NULL)
SELECT i.short_name, r.author, r.score
FROM   institutions i
LEFT   JOIN reviews r ON r.institution_id = i.id
ORDER  BY r.score NULLS FIRST, i.short_name
LIMIT  6;

-- LEFT JOIN + IS NULL: пошук «відсутніх» даних — заклади без жодної програми
SELECT i.id, i.short_name
FROM   institutions i
LEFT   JOIN institution_specialties s ON s.institution_id = i.id
WHERE  s.id IS NULL;

-- RIGHT JOIN: те саме, що LEFT, але зберігаються всі рядки ПРАВОЇ таблиці (усі міста)
SELECT c.name AS city, count(i.id) AS institutions
FROM   institutions i
RIGHT  JOIN cities c ON c.id = i.city_id
GROUP  BY c.name
ORDER  BY institutions DESC;

-- FULL JOIN: усі рядки обох таблиць — спеціальності довідника і програми, навіть без пари
SELECT d.code, d.name, count(s.id) AS programs
FROM   specialty_dict d
FULL   JOIN institution_specialties s ON s.specialty_code = d.code
GROUP  BY d.code, d.name
ORDER  BY programs DESC;

-- CROSS JOIN: декартів добуток — усі комбінації типу закладу та форми власності
SELECT t.name AS type, o.name AS ownership
FROM   institution_types t
CROSS  JOIN ownership_forms o
ORDER  BY 1, 2
LIMIT  8;

-- == 4. JOIN + GROUP BY ==
-- кількість програм і здобувачів у кожній області
SELECT r.name AS region, count(s.id) AS programs, sum(s.students_count) AS students
FROM   regions r
JOIN   cities c ON c.region_id = r.id
JOIN   institutions i ON i.city_id = c.id
JOIN   institution_specialties s ON s.institution_id = i.id
GROUP  BY r.name
ORDER  BY students DESC;

-- заклади, що мають більше ніж один відгук (HAVING після з'єднання)
SELECT i.short_name, count(r.id) AS reviews
FROM   institutions i
JOIN   reviews r ON r.institution_id = i.id
GROUP  BY i.id, i.short_name
HAVING count(r.id) > 1
ORDER  BY i.short_name;

-- == 5. UNION, UNION ALL, INTERSECT, EXCEPT ==
-- UNION двох запитів з текстовою міткою; дублікати прибираються
SELECT short_name, rating_total, 'Високий рейтинг' AS label FROM institutions WHERE rating_total >= 900
UNION
SELECT short_name, rating_total, 'Низький рейтинг'          FROM institutions WHERE rating_total < 900
ORDER  BY rating_total DESC;

-- UNION ALL залишає дублікати: одне місто потрапляє в результат кілька разів
SELECT city FROM institutions WHERE category_type = 1
UNION ALL
SELECT city FROM institutions WHERE category_type = 9
ORDER  BY 1;

-- три запити разом: UNION прибирає повтори з першим запитом, UNION ALL зберігає повтори між іншими
SELECT 'область' AS kind, name FROM regions WHERE name LIKE 'м.%'
UNION
(SELECT 'місто', name FROM cities WHERE name LIKE 'К%'
 UNION ALL
 SELECT 'місто', city FROM institutions WHERE city LIKE 'К%' AND category_type = 1)
ORDER  BY 1, 2;

-- INTERSECT: міста, де є і заклади вищої освіти, і фахові коледжі
SELECT city FROM institutions WHERE category_type = 1
INTERSECT
SELECT city FROM institutions WHERE category_type = 9;

-- EXCEPT: міста з університетами, де НЕМАЄ фахових коледжів
SELECT city FROM institutions WHERE category_type = 1
EXCEPT
SELECT city FROM institutions WHERE category_type = 9;
