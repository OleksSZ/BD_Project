-- ЛР №8. Маніпулювання даними (DML): INSERT, UPDATE, DELETE
-- =====================================================================
-- Команди: INSERT (з переліком стовпців і без нього, кілька рядків, INSERT ... SELECT,
-- ON CONFLICT — аналог INSERT IGNORE / ON DUPLICATE KEY UPDATE, RETURNING),
-- UPDATE (одне поле, кілька полів, арифметика, UPDATE ... FROM), DELETE (за ключем,
-- за умовою, LIKE, кількома критеріями, без WHERE), TRUNCATE, а також аналіз
-- редагування та видалення в батьківських таблицях (RESTRICT / CASCADE).
--
-- Працює з робочими таблицями, але всередині BEGIN ... ROLLBACK — після виконання
-- дані повертаються до початкового стану.
-- Запуск: python db/lab.py 8
-- =====================================================================

-- стан до початку роботи (порівняємо з ним наприкінці)
SELECT (SELECT count(*) FROM institutions)            AS institutions,
       (SELECT count(*) FROM reviews)                 AS reviews,
       (SELECT count(*) FROM institution_specialties) AS programs,
       (SELECT count(*) FROM specialty_dict)          AS specialties;

BEGIN;

-- == 1. INSERT ==
-- без переліку стовпців: значення йдуть у порядку стовпців таблиці (code, name)
INSERT INTO specialty_dict VALUES ('901', 'Лабораторна спеціальність 1');

-- з переліком стовпців: решта стовпців отримує DEFAULT (status = 'approved', created_at = now())
INSERT INTO reviews (institution_id, author, score, comment)
VALUES ((SELECT min(id) FROM institutions), 'ЛР8 Студент', 5, 'Відгук, доданий однією командою')
RETURNING id, author, status, created_at;

-- кілька рядків однією командою
INSERT INTO specialty_dict (code, name) VALUES
    ('902', 'Лабораторна спеціальність 2'),
    ('903', 'Лабораторна спеціальність 3'),
    ('904', 'Лабораторна спеціальність 4');

-- INSERT ... SELECT: дані для вставки — результат запиту (по відгуку кожному закладу вищої освіти)
INSERT INTO reviews (institution_id, author, score, comment)
SELECT id, 'ЛР8 Абітурієнт', 4, 'Масова вставка через INSERT ... SELECT'
FROM   institutions
WHERE  category_type = 1;

-- скільки рядків додано попередньою командою
SELECT count(*) AS inserted_by_select FROM reviews WHERE author = 'ЛР8 Абітурієнт';

SAVEPOINT sp;
-- очікувана помилка: повторний первинний ключ (duplicate key)
INSERT INTO specialty_dict VALUES ('901', 'Дублікат');
ROLLBACK TO SAVEPOINT sp;

-- ON CONFLICT DO NOTHING: дублікат мовчки пропускається (аналог INSERT IGNORE)
INSERT INTO specialty_dict VALUES ('901', 'Дублікат') ON CONFLICT (code) DO NOTHING;

-- ON CONFLICT DO UPDATE: якщо ключ уже є — оновити рядок (аналог ON DUPLICATE KEY UPDATE)
INSERT INTO specialty_dict VALUES ('901', 'Оновлена назва')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
RETURNING code, name;

-- == 2. UPDATE ==
-- одне поле, умова за ключем
UPDATE specialty_dict SET name = 'Спеціальність 902 (змінено)' WHERE code = '902';

-- кілька полів однією командою
UPDATE reviews
SET    score = 3, comment = 'Оцінку та текст змінено однією командою'
WHERE  author = 'ЛР8 Студент'
RETURNING id, score, comment;

-- арифметичний вираз: збільшити кількість здобувачів на 10% в одного закладу
UPDATE institution_specialties
SET    students_count = round(students_count * 1.10)
WHERE  institution_id = (SELECT min(id) FROM institutions)
RETURNING id, program_name, students_count;

-- UPDATE ... FROM: нові значення беруться з іншої (пов'язаної) таблиці
UPDATE reviews r
SET    comment = r.comment || ' [' || c.name || ']'
FROM   institutions i
JOIN   cities c ON c.id = i.city_id
WHERE  i.id = r.institution_id AND r.author = 'ЛР8 Абітурієнт'
RETURNING r.id, r.comment;

-- == 3. DELETE ==
-- спершу SELECT з тією самою умовою — перевіряємо, ЩО буде видалено
SELECT code, name FROM specialty_dict WHERE code LIKE '90%';

-- видалення за ключем
DELETE FROM specialty_dict WHERE code = '904';

-- видалення за шаблоном (LIKE)
DELETE FROM specialty_dict WHERE name LIKE 'Лабораторна%' RETURNING code, name;

-- видалення за кількома критеріями
DELETE FROM reviews WHERE author = 'ЛР8 Абітурієнт' AND score >= 4;

-- DELETE без WHERE видаляє ВСІ рядки таблиці (тут — у межах транзакції)
DELETE FROM reviews;
SELECT count(*) AS reviews_left FROM reviews;

-- TRUNCATE — швидке очищення таблиці (без перебору рядків, тригери рядків не спрацьовують)
TRUNCATE TABLE rating_history;
SELECT count(*) AS rating_history_left FROM rating_history;

-- == 4. Редагування та видалення в батьківських таблицях ==
-- які зовнішні ключі посилаються на кожну батьківську таблицю і з якими правилами
SELECT confrelid::regclass AS parent, conrelid::regclass AS child, conname,
       CASE confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' WHEN 'n' THEN 'SET NULL' ELSE 'NO ACTION' END AS on_update,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' WHEN 'n' THEN 'SET NULL' ELSE 'NO ACTION' END AS on_delete
FROM   pg_constraint
WHERE  contype = 'f' AND connamespace = 'public'::regnamespace
ORDER  BY 1, 2;

-- ON UPDATE CASCADE: зміна первинного ключа області каскадно змінює cities.region_id
UPDATE regions SET id = id + 1000
WHERE  id = (SELECT min(region_id) FROM cities)
RETURNING id AS new_region_id, name;

SELECT c.name AS city, c.region_id FROM cities c WHERE c.region_id > 1000;

-- ON UPDATE CASCADE: новий код спеціальності переходить у всі програми
UPDATE specialty_dict SET code = code || '-X'
WHERE  code = (SELECT min(specialty_code) FROM institution_specialties);

SELECT specialty_code, count(*) AS programs
FROM   institution_specialties WHERE specialty_code LIKE '%-X' GROUP BY specialty_code;

SAVEPOINT sp;
-- очікувана помилка: ON DELETE RESTRICT — не можна видалити спеціальність, яку використовують програми
DELETE FROM specialty_dict WHERE code IN (SELECT specialty_code FROM institution_specialties);
ROLLBACK TO SAVEPOINT sp;

-- очікувана помилка: ON DELETE RESTRICT — не можна видалити область, у якій є міста
DELETE FROM regions WHERE id IN (SELECT region_id FROM cities);
ROLLBACK TO SAVEPOINT sp;

-- очікувана помилка: NO ACTION — не можна видалити місто, у якому є заклади
DELETE FROM cities WHERE id IN (SELECT city_id FROM institutions);
ROLLBACK TO SAVEPOINT sp;

-- ON DELETE CASCADE: видалення закладу видаляє і його програми (слабка сутність)
SELECT (SELECT count(*) FROM institution_specialties) AS programs_before;

DELETE FROM institutions
WHERE  id = (SELECT institution_id FROM institution_specialties
             GROUP BY institution_id ORDER BY count(*) DESC LIMIT 1)
RETURNING id, short_name;

SELECT (SELECT count(*) FROM institution_specialties) AS programs_after;

-- правильний порядок, коли каскаду немає (RESTRICT): спершу дочірні рядки, потім батьківський.
-- Код спеціальності запам'ятовуємо у змінній сесії, щоб обидві команди працювали з тим самим значенням
SELECT set_config('lab.code', max(specialty_code), true) AS chosen_code FROM institution_specialties;

DELETE FROM institution_specialties WHERE specialty_code = current_setting('lab.code');
DELETE FROM specialty_dict WHERE code = current_setting('lab.code') RETURNING code, name;

ROLLBACK;

-- після ROLLBACK усе повернулося до початкового стану
SELECT (SELECT count(*) FROM institutions)            AS institutions,
       (SELECT count(*) FROM reviews)                 AS reviews,
       (SELECT count(*) FROM institution_specialties) AS programs,
       (SELECT count(*) FROM specialty_dict)          AS specialties;
