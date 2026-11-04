-- ЛР №18. Функції керування потоком: CASE, IF, IFNULL, NULLIF
-- =====================================================================
-- У PostgreSQL: CASE (проста і пошукова форма), COALESCE (= MySQL IFNULL), NULLIF,
-- GREATEST / LEAST; функції IF() немає — її замінює CASE WHEN ... THEN ... ELSE ... END.
-- Застосування: у SELECT, ORDER BY, GROUP BY, агрегатах (SUM(CASE ...) і FILTER), HAVING,
-- UPDATE, DELETE, INSERT ... SELECT, а також IF / ELSIF у процедурному блоці (DO).
-- Зміни даних — всередині BEGIN ... ROLLBACK.
-- Запуск: python db/lab.py 18
-- =====================================================================

-- == 1. CASE ==
-- проста форма: порівняння виразу зі значеннями (категорія закладу за кодом ЄДЕБО)
SELECT short_name, category_type,
       CASE category_type
           WHEN 1  THEN 'Вища освіта'
           WHEN 9  THEN 'Фахова передвища'
           WHEN 2  THEN 'Професійна'
           ELSE         'Інше'
       END AS category
FROM   institutions ORDER BY category_type, short_name LIMIT 8;

-- пошукова форма: діапазони значень
SELECT short_name, rating_total,
       CASE
           WHEN rating_total >= 950 THEN 'ТОП'
           WHEN rating_total >= 850 THEN 'Високий'
           WHEN rating_total IS NOT NULL THEN 'Середній'
           ELSE 'Без рейтингу'
       END AS level
FROM   institutions ORDER BY rating_total DESC NULLS LAST;

-- аналог IF(умова, так, ні) — CASE з однією гілкою WHEN (у MySQL: IF(ownership = 'Державна', ...))
SELECT short_name, ownership,
       CASE WHEN ownership = 'Державна' THEN 'бюджетні місця' ELSE 'лише контракт' END AS funding
FROM   institutions LIMIT 5;

-- == 2. COALESCE (IFNULL) та NULLIF ==
-- COALESCE повертає перше не-NULL значення (MySQL: IFNULL(a, b) = COALESCE(a, b))
SELECT short_name, COALESCE(rating_total::text, 'немає даних') AS rating,
       COALESCE(website, address, 'контактів немає') AS contact
FROM   institutions ORDER BY rating_total NULLS FIRST LIMIT 5;

-- NULLIF(a, b) повертає NULL, якщо a = b: безпечне ділення (середня кількість здобувачів на програму)
SELECT i.short_name, sum(s.students_count) AS students, count(s.id) AS programs,
       round(sum(s.students_count)::numeric / NULLIF(count(s.id), 0), 1) AS avg_per_program
FROM   institutions i LEFT JOIN institution_specialties s ON s.institution_id = i.id
GROUP  BY i.id, i.short_name
ORDER  BY avg_per_program DESC NULLS LAST LIMIT 6;

-- LEFT JOIN + COALESCE: заклади без відгуків отримують 0 замість NULL
SELECT i.short_name, COALESCE(sum(r.score), 0) AS score_sum, count(r.id) AS reviews
FROM   institutions i LEFT JOIN reviews r ON r.institution_id = i.id
GROUP  BY i.id, i.short_name
ORDER  BY reviews, i.short_name LIMIT 5;

-- GREATEST / LEAST: обмежити значення межами (не менше 0, не більше 100)
SELECT short_name, rating, GREATEST(0, LEAST(100, COALESCE(rating, 0))) AS clamped
FROM   institutions LIMIT 4;

-- == 3. CASE в агрегатах, GROUP BY, ORDER BY, HAVING ==
-- умовний підрахунок: SUM(CASE ...) і стандартний FILTER дають однаковий результат
SELECT count(*)                                              AS total,
       sum(CASE WHEN category_type = 1 THEN 1 ELSE 0 END)    AS higher_case,
       count(*) FILTER (WHERE category_type = 1)             AS higher_filter,
       sum(CASE WHEN rating_total IS NULL THEN 1 ELSE 0 END) AS without_rating
FROM   institutions;

-- групування за категорією, обчисленою через CASE
SELECT CASE WHEN founded_year < 1900 THEN 'до 1900'
            WHEN founded_year < 1991 THEN '1900-1990'
            ELSE 'після 1990' END AS era,
       count(*) AS institutions
FROM   institutions
GROUP  BY 1 ORDER BY 1;

-- власний порядок сортування: спершу Київ, потім Львів, далі решта за алфавітом
SELECT short_name, city
FROM   institutions
ORDER  BY CASE city WHEN 'Київ' THEN 1 WHEN 'Львів' THEN 2 ELSE 3 END, city, short_name
LIMIT  8;

-- CASE у HAVING і в SELECT для групи: міста з великою кількістю здобувачів
SELECT i.city, sum(s.students_count) AS students,
       CASE WHEN sum(s.students_count) > 2000 THEN 'великий центр' ELSE 'звичайне місто' END AS kind
FROM   institutions i JOIN institution_specialties s ON s.institution_id = i.id
GROUP  BY i.city
HAVING sum(CASE WHEN s.education_level = 'Магістр' THEN 1 ELSE 0 END) > 0
ORDER  BY students DESC;

-- маскування даних у звіті: ім'я автора низької оцінки приховується
SELECT CASE WHEN score <= 3 THEN left(author, 1) || '***' ELSE author END AS author, score
FROM   reviews ORDER BY score LIMIT 5;

-- == 4. CASE у командах зміни даних ==
BEGIN;

-- UPDATE: різний приріст залежно від умови (у MySQL: SET x = x + IF(cond, 0.02, 0.01))
UPDATE institution_specialties
SET    students_count = students_count + CASE WHEN education_level = 'Магістр' THEN 20 ELSE 10 END
WHERE  institution_id = (SELECT min(institution_id) FROM institution_specialties)
RETURNING education_level, students_count;

-- INSERT ... SELECT з обчисленням через CASE: архів рейтингу з бонусом
CREATE TEMP TABLE lab_rating_bonus (institution_id INTEGER, rating INTEGER, bonus INTEGER) ON COMMIT DROP;

INSERT INTO lab_rating_bonus
SELECT id, rating_total,
       CASE WHEN rating_total >= 900 THEN rating_total / 10 ELSE rating_total / 20 END
FROM   institutions WHERE rating_total IS NOT NULL;

SELECT * FROM lab_rating_bonus ORDER BY bonus DESC LIMIT 5;

-- DELETE з умовою через CASE: видалити відгуки з оцінкою нижче за поріг, що залежить від закладу
DELETE FROM reviews r
USING  institutions i
WHERE  i.id = r.institution_id
  AND  r.score < CASE WHEN i.rating_total >= 900 THEN 4 ELSE 3 END
RETURNING r.author, r.score, i.short_name;

-- процедурний IF / ELSIF / ELSE (PL/pgSQL) — керування потоком у блоці коду
DO $$
DECLARE
    v_cnt INTEGER;
BEGIN
    SELECT count(*) INTO v_cnt FROM reviews;
    IF v_cnt = 0 THEN
        RAISE NOTICE 'Відгуків немає';
    ELSIF v_cnt < 20 THEN
        RAISE NOTICE 'Відгуків мало: %', v_cnt;
    ELSE
        RAISE NOTICE 'Відгуків багато: %', v_cnt;
    END IF;
END $$;

ROLLBACK;
