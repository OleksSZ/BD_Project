-- ЛР №11. Структуровані запити (підзапити)
-- =====================================================================
-- Команди: скалярний підзапит (у WHERE та SELECT), IN / NOT IN, EXISTS / NOT EXISTS,
-- корельований (співвіднесений) підзапит, ANY / SOME / ALL, підзапит у HAVING,
-- підзапит у FROM (похідна таблиця), багаторівневі підзапити,
-- порівняння рішення через підзапит і через JOIN.
-- Запуск: python db/lab.py 11
-- =====================================================================

-- == 1. Скалярний підзапит (повертає одне значення) ==
-- програми закладу, коли відома лише його коротка назва, а id — ні
SELECT program_name, education_level, students_count
FROM   institution_specialties
WHERE  institution_id = (SELECT id FROM institutions WHERE short_name = 'КНУ' LIMIT 1);

-- заклади з рейтингом вищим за середній
SELECT short_name, rating_total
FROM   institutions
WHERE  rating_total > (SELECT avg(rating_total) FROM institutions)
ORDER  BY rating_total DESC;

-- скалярний підзапит у списку SELECT: частка закладу в загальній кількості здобувачів
SELECT i.short_name,
       (SELECT sum(s.students_count) FROM institution_specialties s WHERE s.institution_id = i.id) AS students,
       round(100.0 * (SELECT sum(s.students_count) FROM institution_specialties s WHERE s.institution_id = i.id)
                   / (SELECT sum(students_count) FROM institution_specialties), 1) AS percent
FROM   institutions i
WHERE  EXISTS (SELECT 1 FROM institution_specialties s WHERE s.institution_id = i.id)
ORDER  BY students DESC
LIMIT  5;

-- == 2. IN / NOT IN ==
-- заклади з міст Дніпропетровської області (підзапит повертає СТОВПЕЦЬ значень)
SELECT short_name, city
FROM   institutions
WHERE  city_id IN (SELECT c.id FROM cities c JOIN regions r ON r.id = c.region_id
                   WHERE r.name = 'Дніпропетровська область');

-- NOT IN: заклади, про які ще немає жодного відгуку
SELECT short_name FROM institutions
WHERE  id NOT IN (SELECT institution_id FROM reviews)
ORDER  BY short_name;

-- пастка NOT IN: якщо підзапит повертає хоч один NULL, результат завжди порожній
SELECT count(*) AS rows_found
FROM   institutions
WHERE  id NOT IN (SELECT 999999 UNION ALL SELECT NULL);

-- == 3. EXISTS / NOT EXISTS та корельовані підзапити ==
-- EXISTS: заклади, які мають хоча б один відгук з оцінкою 5
SELECT i.short_name
FROM   institutions i
WHERE  EXISTS (SELECT 1 FROM reviews r WHERE r.institution_id = i.id AND r.score = 5);

-- NOT EXISTS: заклади без жодної програми
SELECT i.short_name
FROM   institutions i
WHERE  NOT EXISTS (SELECT 1 FROM institution_specialties s WHERE s.institution_id = i.id);

-- корельований підзапит: заклади з НАЙВИЩИМ рейтингом у своєму місті
-- (внутрішній запит виконується для кожного рядка зовнішнього, посилаючись на o.city_id)
SELECT o.short_name, o.city, o.rating_total
FROM   institutions o
WHERE  o.rating_total = (SELECT max(i.rating_total) FROM institutions i WHERE i.city_id = o.city_id)
ORDER  BY o.rating_total DESC;

-- == 4. ANY / SOME / ALL ==
-- > ANY: рейтинг вищий хоча б за ОДИН заклад Львова
SELECT short_name, city, rating_total
FROM   institutions
WHERE  rating_total > ANY (SELECT rating_total FROM institutions WHERE city = 'Львів' AND rating_total IS NOT NULL)
ORDER  BY rating_total DESC;

-- > ALL: рейтинг вищий за ВСІ заклади Харкова (рівносильно > MAX)
SELECT short_name, city, rating_total
FROM   institutions
WHERE  rating_total > ALL (SELECT rating_total FROM institutions WHERE city = 'Харків' AND rating_total IS NOT NULL);

-- те саме через MAX
SELECT short_name, city, rating_total
FROM   institutions
WHERE  rating_total > (SELECT max(rating_total) FROM institutions WHERE city = 'Харків');

-- = SOME — синонім ANY і рівносильний IN
SELECT short_name FROM institutions
WHERE  category_type = SOME (SELECT category_type FROM institutions WHERE short_name IN ('ККЗ', 'ХПЛБТ'));

-- <> ALL — рівносильний NOT IN: заклади таких категорій, яких немає в Києві
SELECT short_name, city, category_type FROM institutions
WHERE  category_type <> ALL (SELECT category_type FROM institutions WHERE city = 'Київ' AND category_type IS NOT NULL);

-- == 5. Підзапит у HAVING та у FROM ==
-- міста, де сумарна кількість здобувачів більша за найбільшу програму в БД
SELECT i.city, sum(s.students_count) AS students
FROM   institutions i
JOIN   institution_specialties s ON s.institution_id = i.id
GROUP  BY i.city
HAVING sum(s.students_count) > (SELECT max(students_count) FROM institution_specialties)
ORDER  BY students DESC;

-- похідна таблиця в FROM (обов'язково з псевдонімом): середня кількість програм на заклад по містах
SELECT city, round(avg(programs), 1) AS avg_programs
FROM  (SELECT i.city, count(s.id) AS programs
       FROM   institutions i
       LEFT   JOIN institution_specialties s ON s.institution_id = i.id
       GROUP  BY i.id, i.city) AS per_institution
GROUP  BY city
ORDER  BY avg_programs DESC;

-- == 6. Багаторівневий підзапит ==
-- відгуки про заклади з тієї області, де розташований найстаріший заклад
SELECT r.author, r.score, i.short_name
FROM   reviews r
JOIN   institutions i ON i.id = r.institution_id
WHERE  i.city_id IN (SELECT id FROM cities
                     WHERE region_id = (SELECT region_id FROM cities
                                        WHERE id = (SELECT city_id FROM institutions
                                                    WHERE founded_year IS NOT NULL
                                                    ORDER BY founded_year LIMIT 1)));

-- == 7. Одна задача — два рішення ==
-- міста, де є і заклади з рейтингом, і заклади без нього: через корельований підзапит
SELECT DISTINCT a.city
FROM   institutions a
WHERE  a.rating_total IS NOT NULL
  AND  EXISTS (SELECT 1 FROM institutions b WHERE b.city_id = a.city_id AND b.rating_total IS NULL);

-- те саме через самоз'єднання (JOIN)
SELECT DISTINCT a.city
FROM   institutions a
JOIN   institutions b ON b.city_id = a.city_id
WHERE  a.rating_total IS NOT NULL AND b.rating_total IS NULL;
