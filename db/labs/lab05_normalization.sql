-- ЛР №5. Нормалізація відношень: 1НФ, 2НФ, 3НФ
-- =====================================================================
-- Що демонструється:
--  * ненормалізоване відношення з повторюваною групою і приведення до 1НФ (unnest);
--  * перевірка функціональних залежностей запитами (GROUP BY ... HAVING count(DISTINCT ...));
--  * часткова залежність (порушення 2НФ) і транзитивна залежність (порушення 3НФ);
--  * аномалія оновлення в ненормалізованій таблиці і її відсутність після декомпозиції;
--  * декомпозиція без втрат: з'єднання частин відновлює початкові дані (EXCEPT в обидва боки).
-- Ненормалізовані дані будуються в TEMP-таблицях, робочі таблиці не змінюються.
-- Повна нормалізація робочої БД виконана у db/sql/01_normalization.sql.
-- Запуск: python db/lab.py 5
-- =====================================================================

-- == 1. Ненормалізоване відношення -> 1НФ ==
DROP TABLE IF EXISTS lab_unf;

-- повторювана група: усі коди спеціальностей закладу в ОДНОМУ полі (не атомарне значення)
CREATE TEMP TABLE lab_unf AS
SELECT i.id, i.short_name, i.city, i.region,
       string_agg(DISTINCT s.specialty_code, ', ' ORDER BY s.specialty_code) AS specialty_codes
FROM   institutions i
JOIN   institution_specialties s ON s.institution_id = i.id
GROUP  BY i.id, i.short_name, i.city, i.region;

SELECT * FROM lab_unf ORDER BY id LIMIT 5;

-- 1НФ: кожне значення — в окремому рядку (string_to_table розбиває рядок на рядки)
SELECT id, short_name, city, region, string_to_table(specialty_codes, ', ') AS specialty_code
FROM   lab_unf
ORDER  BY id, specialty_code
LIMIT  8;

-- == 2. Перевірка функціональних залежностей ==
-- ФЗ city -> region виконується, якщо в кожного міста рівно одна область (очікується порожній результат)
SELECT city, count(DISTINCT region) AS regions
FROM   institutions
WHERE  city IS NOT NULL
GROUP  BY city
HAVING count(DISTINCT region) > 1;

-- ФЗ specialty_code -> specialty_name: скільки разів кожна назва повторюється в таблиці програм
SELECT specialty_code, count(*) AS rows_with_same_name, count(DISTINCT specialty_name) AS different_names
FROM   institution_specialties
WHERE  specialty_code IS NOT NULL
GROUP  BY specialty_code
ORDER  BY rows_with_same_name DESC
LIMIT  6;

-- == 3. Порушення 2НФ: часткова залежність ==
-- ключ програми: (institution_id, specialty_code, program_name); specialty_name залежить лише від
-- ЧАСТИНИ ключа (specialty_code) -> надлишковість. Рішення: довідник specialty_dict(code, name)
SELECT s.specialty_code, s.specialty_name AS name_in_programs, d.name AS name_in_dict
FROM   institution_specialties s
JOIN   specialty_dict d ON d.code = s.specialty_code
GROUP  BY s.specialty_code, s.specialty_name, d.name
ORDER  BY 1
LIMIT  6;

-- == 4. Порушення 3НФ: транзитивна залежність id -> city -> region ==
-- у початковій таблиці назва області повторюється для кожного закладу
SELECT region, count(*) AS repeated_times FROM institutions GROUP BY region ORDER BY 2 DESC;

-- аномалія оновлення: змінили область лише в ОДНОМУ рядку — дані стали суперечливими
CREATE TEMP TABLE lab_denorm AS SELECT id, short_name, city, region FROM institutions;
UPDATE lab_denorm SET region = 'Київська обл.' WHERE id = (SELECT min(id) FROM lab_denorm);
SELECT city, string_agg(DISTINCT region, ' | ') AS regions_for_city
FROM   lab_denorm GROUP BY city HAVING count(DISTINCT region) > 1;

-- після декомпозиції назва області зберігається ОДИН раз (regions), тож аномалія неможлива:
-- оновлення одного рядка довідника змінює область для всіх закладів
BEGIN;
UPDATE regions SET name = name || ' (оновлено)' WHERE id = (SELECT min(region_id) FROM cities) RETURNING id, name;
SELECT i.short_name, r.name AS region
FROM   institutions i JOIN cities c ON c.id = i.city_id JOIN regions r ON r.id = c.region_id
WHERE  r.name LIKE '%(оновлено)' LIMIT 5;
ROLLBACK;

-- == 5. Результат декомпозиції (3НФ) ==
-- institutions(city_id, type_id, ownership_id) + cities(region_id) + regions + institution_types + ownership_forms
SELECT i.short_name, c.name AS city, r.name AS region, t.name AS type, o.name AS ownership
FROM   institutions i
JOIN   cities c            ON c.id = i.city_id
JOIN   regions r           ON r.id = c.region_id
JOIN   institution_types t ON t.id = i.type_id
JOIN   ownership_forms o   ON o.id = i.ownership_id
ORDER  BY i.id LIMIT 5;

-- == 6. Декомпозиція без втрат ==
-- з'єднання частин має дати рівно початкові дані: різниця в обидва боки = 0 рядків
WITH original AS (
    SELECT id, COALESCE(fn_clean_text(region), 'Не вказано') AS region,
               COALESCE(fn_clean_text(city),   'Не вказано') AS city
    FROM   institutions
), restored AS (
    SELECT i.id, r.name AS region, c.name AS city
    FROM   institutions i
    JOIN   cities c  ON c.id = i.city_id
    JOIN   regions r ON r.id = c.region_id
)
SELECT (SELECT count(*) FROM original) AS rows_original,
       (SELECT count(*) FROM restored) AS rows_restored,
       (SELECT count(*) FROM (SELECT * FROM original EXCEPT SELECT * FROM restored) a) AS lost_rows,
       (SELECT count(*) FROM (SELECT * FROM restored EXCEPT SELECT * FROM original) b) AS spurious_rows;

DROP TABLE lab_unf, lab_denorm;
