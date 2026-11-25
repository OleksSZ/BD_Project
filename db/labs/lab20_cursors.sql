-- ЛР №20. Курсори
-- =====================================================================
-- Команди (PL/pgSQL): DECLARE курсор CURSOR FOR …, OPEN, FETCH … INTO, EXIT WHEN NOT FOUND,
-- CLOSE (аналог MySQL DECLARE CONTINUE HANDLER FOR NOT FOUND), курсор з параметром,
-- FOR запис IN курсор LOOP (неявні OPEN / FETCH / CLOSE), UPDATE / DELETE … WHERE CURRENT OF,
-- два послідовні курсори, вкладені курсори; курсор рівня SQL: DECLARE … CURSOR, FETCH, MOVE, CLOSE.
-- Процедури створюються всередині BEGIN … ROLLBACK, тож після роботи їх у БД немає,
-- а зміни даних відкочуються. Результат процедур виводиться через RAISE NOTICE.
-- Запуск: python db/lab.py 20
-- =====================================================================

BEGIN;

-- == 1. Курсор: перебір рядків і повідомлення ==
-- Завдання 1: пройти курсором по закладах з рейтингом і вивести «Заклад [назва] має рейтинг [значення]».
-- Повний цикл явного курсора: DECLARE -> OPEN -> FETCH у циклі -> EXIT WHEN NOT FOUND -> CLOSE
CREATE PROCEDURE lab_print_ratings()
LANGUAGE plpgsql AS $$
DECLARE
    cur_inst CURSOR FOR
        SELECT short_name, rating_total FROM institutions
        WHERE  rating_total IS NOT NULL
        ORDER  BY rating_total DESC;
    v_name   TEXT;
    v_rating INTEGER;
BEGIN
    OPEN cur_inst;
    LOOP
        FETCH cur_inst INTO v_name, v_rating;
        EXIT WHEN NOT FOUND;               -- у MySQL: CONTINUE HANDLER FOR NOT FOUND SET done = 1
        RAISE NOTICE 'Заклад % має рейтинг %', v_name, v_rating;
    END LOOP;
    CLOSE cur_inst;
END $$;

CALL lab_print_ratings();

-- == 2. Курсор з підрахунком і умовою ==
-- Завдання 2: для кожного міста порахувати загальну кількість здобувачів і вивести лише міста,
-- де вона перевищує поріг. Курсор з ПАРАМЕТРОМ: внутрішній запит отримує id міста
CREATE PROCEDURE lab_city_students(p_min INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    cur_cities CURSOR FOR SELECT id, name FROM cities ORDER BY name;
    cur_students CURSOR (p_city INTEGER) FOR
        SELECT COALESCE(sum(s.students_count), 0)
        FROM   institution_specialties s JOIN institutions i ON i.id = s.institution_id
        WHERE  i.city_id = p_city;
    v_id    INTEGER;
    v_name  TEXT;
    v_total BIGINT;
BEGIN
    OPEN cur_cities;
    LOOP
        FETCH cur_cities INTO v_id, v_name;
        EXIT WHEN NOT FOUND;
        OPEN cur_students(v_id);              -- відкриття курсора з параметром
        FETCH cur_students INTO v_total;
        CLOSE cur_students;
        IF v_total > p_min THEN
            RAISE NOTICE 'Місто %: здобувачів %', v_name, v_total;
        END IF;
    END LOOP;
    CLOSE cur_cities;
END $$;

CALL lab_city_students(1500);

-- == 3. Курсор, що змінює дані ==
-- Завдання 3: якщо загальна кількість здобувачів закладу більша за 1000,
-- збільшити його рейтинг на 10. UPDATE … WHERE CURRENT OF змінює саме поточний рядок курсора
CREATE PROCEDURE lab_bonus_rating()
LANGUAGE plpgsql AS $$
DECLARE
    cur_inst CURSOR FOR
        SELECT i.id, i.short_name, i.rating_total
        FROM   institutions i
        WHERE  i.rating_total IS NOT NULL
        FOR UPDATE;                           -- рядки блокуються для зміни через курсор
    rec     RECORD;
    v_total BIGINT;
BEGIN
    OPEN cur_inst;
    LOOP
        FETCH cur_inst INTO rec;
        EXIT WHEN NOT FOUND;
        SELECT COALESCE(sum(students_count), 0) INTO v_total
        FROM   institution_specialties WHERE institution_id = rec.id;
        IF v_total > 1000 THEN
            UPDATE institutions SET rating_total = rating_total + 10 WHERE CURRENT OF cur_inst;
            RAISE NOTICE '% (здобувачів %): рейтинг % -> %', rec.short_name, v_total, rec.rating_total, rec.rating_total + 10;
        END IF;
    END LOOP;
    CLOSE cur_inst;
END $$;

-- рейтинги до виклику процедури
SELECT short_name, rating_total FROM institutions WHERE rating_total IS NOT NULL ORDER BY rating_total DESC LIMIT 5;

CALL lab_bonus_rating();

-- рейтинги після: змінились лише заклади з понад 1000 здобувачів
SELECT short_name, rating_total FROM institutions WHERE rating_total IS NOT NULL ORDER BY rating_total DESC LIMIT 5;

-- == 4. Два послідовні курсори ==
-- Завдання 4: перший курсор обчислює середню кількість здобувачів на програму,
-- другий проходить по програмах і переносить в архів ті, де здобувачів удвічі менше за середнє
CREATE TABLE lab_programs_archive (LIKE institution_specialties);

CREATE PROCEDURE lab_archive_small_programs()
LANGUAGE plpgsql AS $$
DECLARE
    cur_avg CURSOR FOR SELECT avg(students_count) FROM institution_specialties;
    cur_prog CURSOR FOR SELECT * FROM institution_specialties FOR UPDATE;
    v_avg  NUMERIC;
    rec    institution_specialties%ROWTYPE;
    v_cnt  INTEGER := 0;
BEGIN
    OPEN cur_avg;
    FETCH cur_avg INTO v_avg;
    CLOSE cur_avg;
    RAISE NOTICE 'Середня кількість здобувачів на програму: %', round(v_avg, 1);

    OPEN cur_prog;
    LOOP
        FETCH cur_prog INTO rec;
        EXIT WHEN NOT FOUND;
        IF rec.students_count < v_avg / 2 THEN
            INSERT INTO lab_programs_archive SELECT rec.*;
            DELETE FROM institution_specialties WHERE CURRENT OF cur_prog;
            v_cnt := v_cnt + 1;
        END IF;
    END LOOP;
    CLOSE cur_prog;
    RAISE NOTICE 'Перенесено в архів програм: %', v_cnt;
END $$;

CALL lab_archive_small_programs();

SELECT institution_id, program_name, students_count FROM lab_programs_archive ORDER BY students_count;

-- == 5. Вкладені курсори ==
-- Завдання 5: зовнішній курсор перебирає області, внутрішній — заклади поточної області;
-- для кожної області виводиться список закладів одним рядком.
-- FOR … IN курсор LOOP сам виконує OPEN, FETCH, перевірку кінця даних і CLOSE
CREATE PROCEDURE lab_regions_report()
LANGUAGE plpgsql AS $$
DECLARE
    cur_regions CURSOR FOR SELECT id, name FROM regions ORDER BY name;
    cur_inst CURSOR (p_region INTEGER) FOR
        SELECT i.short_name FROM institutions i JOIN cities c ON c.id = i.city_id
        WHERE  c.region_id = p_region ORDER BY i.short_name;
    v_list TEXT;
BEGIN
    FOR r IN cur_regions LOOP
        v_list := '';
        FOR inst IN cur_inst(r.id) LOOP
            v_list := v_list || CASE WHEN v_list = '' THEN '' ELSE ', ' END || COALESCE(inst.short_name, '?');
        END LOOP;
        RAISE NOTICE '%: %', r.name, NULLIF(v_list, '');
    END LOOP;
END $$;

CALL lab_regions_report();

-- == 6. Курсор рівня SQL ==
-- Курсор можна оголосити і без процедури — всередині транзакції. Так клієнт читає великий
-- результат частинами (як «сторінки»), не завантажуючи його повністю
DECLARE cur_programs SCROLL CURSOR FOR
    SELECT id, program_name, students_count FROM institution_specialties ORDER BY id;

-- перші 3 рядки
FETCH 3 FROM cur_programs;

-- наступні 2 рядки — курсор пам'ятає позицію
FETCH 2 FROM cur_programs;

-- MOVE пересуває курсор без виводу рядків (тут — на 10-й рядок результату)
MOVE ABSOLUTE 10 IN cur_programs;

-- SCROLL дозволяє рух назад: FETCH PRIOR повертає 9-й рядок
FETCH PRIOR FROM cur_programs;

-- відкриті курсори сесії
SELECT name, statement, is_scrollable FROM pg_cursors;

CLOSE cur_programs;

ROLLBACK;

-- після ROLLBACK процедур і архівної таблиці немає, дані не змінились
SELECT count(*) AS lab_procedures FROM pg_proc WHERE proname LIKE 'lab\_%';
