-- ЛР №12. Маніпулювання даними за результатами запитів на вибір
-- =====================================================================
-- Команди: INSERT ... SELECT (з умовою, GROUP BY / HAVING), CREATE TABLE ... AS SELECT,
-- UPDATE з підзапитом (скалярним, IN, корельованим), UPDATE ... FROM,
-- DELETE з підзапитом (IN, EXISTS / NOT EXISTS), DELETE ... USING,
-- DML з RETURNING всередині CTE (WITH ... DELETE ... RETURNING ... INSERT).
-- Усе — всередині BEGIN ... ROLLBACK, робочі дані не змінюються.
-- Запуск: python db/lab.py 12
-- =====================================================================

BEGIN;

-- == 1. INSERT за результатами SELECT ==
-- нова таблиця з тією ж структурою, що й довідник міст (аналог Multicust у методичці)
CREATE TABLE lab_multi_cities (LIKE cities INCLUDING DEFAULTS);

-- вставити лише ті міста, в яких більше одного закладу (умова на групу — HAVING)
INSERT INTO lab_multi_cities (id, region_id, name)
SELECT c.id, c.region_id, c.name
FROM   cities c
JOIN   institutions i ON i.city_id = c.id
GROUP  BY c.id, c.region_id, c.name
HAVING count(*) > 1;

SELECT * FROM lab_multi_cities ORDER BY name;

-- CREATE TABLE ... AS SELECT: створити таблицю одразу з результатом запиту
CREATE TABLE lab_city_stats AS
SELECT i.city, count(*) AS institutions, max(i.rating_total) AS best_rating
FROM   institutions i
GROUP  BY i.city;

SELECT * FROM lab_city_stats ORDER BY institutions DESC;

-- == 2. UPDATE за результатами SELECT ==
-- скалярний підзапит: +20% здобувачів у програмах закладу з найвищим рейтингом
UPDATE institution_specialties
SET    students_count = round(students_count * 1.2)
WHERE  institution_id = (SELECT id FROM institutions ORDER BY rating_total DESC NULLS LAST LIMIT 1)
RETURNING institution_id, program_name, students_count;

-- IN + GROUP BY/HAVING: +20% лише закладам, у яких загальна кількість здобувачів перевищує 1000
UPDATE institution_specialties
SET    students_count = round(students_count * 1.2)
WHERE  institution_id IN (SELECT institution_id FROM institution_specialties
                          GROUP BY institution_id HAVING sum(students_count) > 1000);

-- корельований підзапит в SET: перерахувати середню оцінку і кількість відгуків закладу
UPDATE institutions i
SET    avg_review_score = (SELECT round(avg(r.score), 2) FROM reviews r WHERE r.institution_id = i.id),
       reviews_count    = (SELECT count(*)               FROM reviews r WHERE r.institution_id = i.id)
WHERE  EXISTS (SELECT 1 FROM reviews r WHERE r.institution_id = i.id)
RETURNING id, short_name, avg_review_score, reviews_count;

-- UPDATE ... FROM з агрегуючим підзапитом: записати в статистику міст кількість програм
ALTER TABLE lab_city_stats ADD COLUMN programs INTEGER DEFAULT 0;

UPDATE lab_city_stats st
SET    programs = p.cnt
FROM  (SELECT i.city, count(s.id) AS cnt
       FROM   institutions i JOIN institution_specialties s ON s.institution_id = i.id
       GROUP  BY i.city) AS p
WHERE  p.city = st.city;

SELECT * FROM lab_city_stats ORDER BY programs DESC;

-- == 3. DELETE за результатами SELECT ==
-- IN: видалити відгуки про заклади, засновані до 1850 року
DELETE FROM reviews
WHERE  institution_id IN (SELECT id FROM institutions WHERE founded_year < 1850)
RETURNING id, institution_id;

-- додамо до довідника спеціальність, якої немає в жодній програмі, — щоб наступній команді було що видалити
INSERT INTO specialty_dict VALUES ('LAB', 'Невикористана спеціальність');

-- NOT EXISTS: видалити з довідника спеціальності, не використані в жодній програмі
DELETE FROM specialty_dict d
WHERE  NOT EXISTS (SELECT 1 FROM institution_specialties s WHERE s.specialty_code = d.code)
RETURNING code;

-- EXISTS: видалити програми закладів, засновані після 1990 року
DELETE FROM institution_specialties s
WHERE  EXISTS (SELECT 1 FROM institutions i WHERE i.id = s.institution_id AND i.founded_year > 1990)
RETURNING s.institution_id, s.program_name;

-- DELETE ... USING (з'єднання в DELETE, аналог багатотабличного DELETE у MySQL):
-- видалити з lab_multi_cities міста Львівської області
DELETE FROM lab_multi_cities m
USING  regions r
WHERE  r.id = m.region_id AND r.name = 'Львівська область'
RETURNING m.name;

-- == 4. Комбінація: перенесення рядків однією командою ==
-- CTE з DELETE ... RETURNING: видалені рядки одразу вставляються в архівну таблицю
CREATE TABLE lab_reviews_archive (LIKE reviews);

WITH moved AS (
    DELETE FROM reviews WHERE score <= 3
    RETURNING *
)
INSERT INTO lab_reviews_archive SELECT * FROM moved;

SELECT (SELECT count(*) FROM lab_reviews_archive) AS archived,
       (SELECT count(*) FROM reviews)             AS left_in_reviews;

ROLLBACK;

-- після ROLLBACK робочі таблиці не змінились, тимчасових таблиць немає
SELECT count(*) AS reviews, to_regclass('lab_city_stats') AS lab_table FROM reviews;
