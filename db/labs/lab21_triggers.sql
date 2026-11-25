-- ЛР №21. Тригери
-- =====================================================================
-- Команди: CREATE FUNCTION … RETURNS trigger, CREATE TRIGGER BEFORE / AFTER INSERT / UPDATE /
-- DELETE … FOR EACH ROW / FOR EACH STATEMENT, UPDATE OF стовпець, WHEN (умова), NEW / OLD, TG_OP,
-- RAISE EXCEPTION (аналог SIGNAL SQLSTATE у MySQL), зміна NEW у BEFORE-тригері,
-- ALTER TABLE … DISABLE / ENABLE TRIGGER, DROP TRIGGER, перегляд тригерів у каталозі.
-- Тригери створюються на таблицях проєкту всередині BEGIN … ROLLBACK, тому після роботи
-- їх немає, а дані не змінились. Тригери самого проєкту (10_triggers.sql) працюють паралельно.
-- Запуск: python db/lab.py 21
-- =====================================================================

-- == 1. Тригери, які вже працюють у проєкті ==
-- аналог SHOW TRIGGERS: тригери таблиць проєкту, момент спрацювання, події, рівень
SELECT event_object_table AS table_name, trigger_name, action_timing AS timing,
       string_agg(event_manipulation, ', ' ORDER BY event_manipulation) AS events,
       action_orientation AS level
FROM   information_schema.triggers
WHERE  trigger_schema = 'public'
GROUP  BY 1, 2, 3, 5
ORDER  BY 1, 2;

BEGIN;

-- == 2. BEFORE INSERT: перевірка даних і скасування вставки ==
-- Завдання 1: перевіряти відгук перед вставкою — низька оцінка (1–2) дозволена лише з коментарем
-- не коротшим за 10 символів. RAISE EXCEPTION скасовує вставку (у MySQL: SIGNAL SQLSTATE '45000')
CREATE FUNCTION lab_check_review() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.score <= 2 AND char_length(COALESCE(btrim(NEW.comment), '')) < 10 THEN
        RAISE EXCEPTION 'Оцінка % потребує коментаря щонайменше з 10 символів', NEW.score
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;                 -- BEFORE-тригер повертає рядок, який буде записано
END $$;

CREATE TRIGGER trg_lab_check_review
BEFORE INSERT ON reviews
FOR EACH ROW EXECUTE FUNCTION lab_check_review();

SAVEPOINT sp;
-- очікувана помилка: оцінка 1 без коментаря — тригер скасовує вставку
INSERT INTO reviews (institution_id, author, score) VALUES ((SELECT min(id) FROM institutions), 'ЛР21 Тест', 1);
ROLLBACK TO SAVEPOINT sp;

-- коректний відгук проходить перевірку
INSERT INTO reviews (institution_id, author, score, comment)
VALUES ((SELECT min(id) FROM institutions), 'ЛР21 Тест', 2, 'Мало практичних занять')
RETURNING id, author, score;

-- == 3. BEFORE-тригер змінює дані перед записом ==
-- NEW можна змінювати лише в BEFORE-тригері: тут ім'я автора очищається від пробілів і
-- записується з великої літери (в AFTER-тригері зміна NEW вже нічого не дає — рядок записано)
CREATE FUNCTION lab_normalize_author() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.author := initcap(btrim(NEW.author));
    RETURN NEW;
END $$;

CREATE TRIGGER trg_lab_normalize_author
BEFORE INSERT OR UPDATE OF author ON reviews
FOR EACH ROW EXECUTE FUNCTION lab_normalize_author();

INSERT INTO reviews (institution_id, author, score, comment)
VALUES ((SELECT min(id) FROM institutions), '   марія к.   ', 5, 'Чудово')
RETURNING id, author;

-- == 4. AFTER INSERT: автоматичне оновлення іншої таблиці ==
-- Завдання 2: при додаванні програми збільшувати лічильник здобувачів закладу
-- (для цього створюється додатковий стовпець lab_students_total)
ALTER TABLE institutions ADD COLUMN lab_students_total INTEGER NOT NULL DEFAULT 0;

CREATE FUNCTION lab_add_students() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE institutions
    SET    lab_students_total = lab_students_total + COALESCE(NEW.students_count, 0)
    WHERE  id = NEW.institution_id;
    RETURN NULL;                -- значення, яке повертає AFTER-тригер, ігнорується
END $$;

CREATE TRIGGER trg_lab_add_students
AFTER INSERT ON institution_specialties
FOR EACH ROW EXECUTE FUNCTION lab_add_students();

INSERT INTO institution_specialties (institution_id, specialty_code, program_name, education_level, students_count)
VALUES ((SELECT min(id) FROM institutions), '121', 'ЛР21 Програма', 'Магістр', 40),
       ((SELECT min(id) FROM institutions), '122', 'ЛР21 Програма 2', 'Магістр', 25);

-- тригер спрацював для кожного з двох рядків: 40 + 25
SELECT id, short_name, lab_students_total FROM institutions WHERE id = (SELECT min(id) FROM institutions);

-- == 5. BEFORE DELETE: заборона видалення ==
-- Завдання 3: заборонити видалення закладу, рейтинг якого вищий за 900
CREATE FUNCTION lab_protect_top() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Неможливо видалити заклад % з рейтингом %', OLD.short_name, OLD.rating_total;
END $$;

-- WHEN: тригер викликається лише для рядків, що задовольняють умову (OLD — рядок, що видаляється)
CREATE TRIGGER trg_lab_protect_top
BEFORE DELETE ON institutions
FOR EACH ROW WHEN (OLD.rating_total > 900)
EXECUTE FUNCTION lab_protect_top();

SAVEPOINT sp;
-- очікувана помилка: заклад з рейтингом понад 900 видалити не можна
DELETE FROM institutions WHERE rating_total = (SELECT max(rating_total) FROM institutions);
ROLLBACK TO SAVEPOINT sp;

-- заклад з нижчим рейтингом видаляється (разом із його програмами — ON DELETE CASCADE)
DELETE FROM institutions
WHERE  id = (SELECT id FROM institutions WHERE rating_total < 900 ORDER BY rating_total LIMIT 1)
RETURNING id, short_name, rating_total;

-- == 6. AFTER UPDATE: журнал змін ==
-- Завдання 4: службова таблиця lab_price_logs і тригер, що при зміні кількості здобувачів
-- записує номер програми, старе і нове значення та час зміни
CREATE TABLE lab_price_logs (
    id          SERIAL PRIMARY KEY,
    program_id  INTEGER,
    old_value   INTEGER,
    new_value   INTEGER,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE FUNCTION lab_log_students() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO lab_price_logs (program_id, old_value, new_value)
    VALUES (NEW.id, OLD.students_count, NEW.students_count);
    RETURN NULL;
END $$;

-- UPDATE OF + WHEN: лише якщо змінився саме цей стовпець і значення справді інше
CREATE TRIGGER trg_lab_log_students
AFTER UPDATE OF students_count ON institution_specialties
FOR EACH ROW WHEN (OLD.students_count IS DISTINCT FROM NEW.students_count)
EXECUTE FUNCTION lab_log_students();

UPDATE institution_specialties SET students_count = students_count + 5
WHERE  institution_id = (SELECT min(institution_id) FROM institution_specialties);

-- зміна іншого стовпця тригер не викликає
UPDATE institution_specialties SET program_name = program_name
WHERE  institution_id = (SELECT min(institution_id) FROM institution_specialties);

SELECT program_id, old_value, new_value, to_char(changed_at, 'HH24:MI:SS') AS at FROM lab_price_logs ORDER BY id LIMIT 5;

-- == 7. Тригер рівня оператора та TG_OP ==
-- FOR EACH STATEMENT спрацьовує один раз на команду, незалежно від кількості рядків;
-- TG_OP містить назву операції (INSERT / UPDATE / DELETE)
CREATE FUNCTION lab_statement_info() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Команда % над таблицею % (тригер рівня оператора)', TG_OP, TG_TABLE_NAME;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_lab_statement_info
AFTER UPDATE ON regions
FOR EACH STATEMENT EXECUTE FUNCTION lab_statement_info();

-- UPDATE зачіпає всі області, а повідомлення одне
UPDATE regions SET name = name;

-- == 8. Керування тригерами ==
-- тимчасово вимкнути тригер (наприклад, на час масового завантаження) і ввімкнути знову
ALTER TABLE reviews DISABLE TRIGGER trg_lab_check_review;

-- тепер відгук без коментаря проходить — перевірка вимкнена
INSERT INTO reviews (institution_id, author, score)
VALUES ((SELECT max(id) FROM institutions), 'ЛР21 Без перевірки', 1)
RETURNING id, author, score;

ALTER TABLE reviews ENABLE TRIGGER trg_lab_check_review;

-- створені тригери в каталозі
SELECT tgname AS trigger_name, tgrelid::regclass AS table_name,
       CASE tgenabled WHEN 'D' THEN 'вимкнено' ELSE 'увімкнено' END AS state
FROM   pg_trigger WHERE tgname LIKE 'trg\_lab\_%' ORDER BY 1;

-- видалення тригера (функцію можна залишити або видалити окремо)
DROP TRIGGER trg_lab_statement_info ON regions;
DROP FUNCTION lab_statement_info();

ROLLBACK;

-- після ROLLBACK лабораторних тригерів немає, дані не змінились
SELECT count(*) AS lab_triggers FROM pg_trigger WHERE tgname LIKE 'trg\_lab\_%';
