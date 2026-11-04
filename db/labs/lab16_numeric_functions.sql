-- ЛР №16. Вбудовані функції: опрацювання чисел
-- =====================================================================
-- Оператори: + - * / % (і цілочисельне ділення), унарний мінус.
-- Функції: abs, sign, round, trunc, ceil, floor, mod, div, power, sqrt, cbrt, exp, ln, log,
-- pi, random, greatest / least, width_bucket, to_char для чисел (аналог FORMAT),
-- NULLIF / COALESCE у розрахунках; переповнення, ділення на нуль, float проти numeric.
-- Застосування у SELECT, INSERT, UPDATE; нове відношення для збереження результатів.
-- Зміни даних — всередині BEGIN ... ROLLBACK.
-- Запуск: python db/lab.py 16
-- =====================================================================

-- == 1. Арифметичні оператори ==
SELECT 3 + 5 AS plus, 3 - 5 AS minus, 3 * 5 AS mult, - 2 AS unary_minus;

-- ділення цілих — ЦІЛОЧИСЕЛЬНЕ (у MySQL 3/5 = 0.6000); щоб отримати дріб, одне з чисел має бути дробовим
SELECT 7 / 2 AS int_div, 7 / 2.0 AS real_div, 7::numeric / 2 AS cast_div, 7 % 2 AS remainder;

-- очікувана помилка: ділення на нуль (у MySQL результат NULL)
SELECT 102 / (1 - 1);

-- NULLIF робить ділення безпечним: дільник 0 -> NULL -> результат NULL
SELECT 102 / NULLIF(1 - 1, 0) AS safe_div;

-- очікувана помилка: переповнення BIGINT (64 біти)
SELECT 18014398509481984 * 18014398509481984;

-- з типом numeric переповнення немає
SELECT 18014398509481984::numeric * 18014398509481984 AS numeric_mult;

-- float — наближене значення, numeric — точне (для грошей і балів)
SELECT 0.1::float8 + 0.2::float8 AS float_sum, 0.1::numeric + 0.2 AS numeric_sum,
       (0.1::float8 + 0.2::float8) = 0.3 AS float_equal;

-- == 2. Математичні функції ==
-- модуль, знак, остача, цілочисельне ділення
SELECT abs(-17) AS abs, sign(-17) AS sign, mod(17, 5) AS mod, div(17, 5) AS div;

-- округлення: round (до найближчого), trunc (відкинути, MySQL: TRUNCATE), ceil вгору, floor вниз
SELECT round(4.567, 2) AS round_2, round(4.5) AS round_0, trunc(4.567, 1) AS trunc_1,
       ceil(4.1) AS ceil, floor(4.9) AS floor, ceil(-4.1) AS ceil_neg, floor(-4.1) AS floor_neg;

-- степені, корені, логарифми
SELECT power(2, 10) AS pow, sqrt(144) AS sqrt, cbrt(27) AS cbrt,
       round(exp(1)::numeric, 5) AS e, round(ln(10)::numeric, 5) AS ln, log(1000) AS log10,
       round(pi()::numeric, 6) AS pi;

-- випадкові числа: дріб від 0 до 1 і ціле від 1 до 100 (MySQL: RAND(), FLOOR(1 + RAND() * 100))
SELECT random() AS rnd, floor(1 + random() * 100)::int AS rnd_1_100;

-- найбільше / найменше з переліку значень (не агрегат!)
SELECT greatest(3, 17, 9) AS max_of_list, least(3, 17, 9) AS min_of_list;

-- форматування числа (MySQL: FORMAT(n, 2)): розділювач тисяч і два знаки після коми
SELECT to_char(1234567.891, 'FM9G999G999D00') AS formatted;

-- == 3. Функції в запитах на вибір ==
-- середня оцінка закладу різними способами округлення
SELECT i.short_name, avg(r.score)               AS avg_raw,
       round(avg(r.score), 2)                    AS avg_round,
       trunc(avg(r.score), 1)                    AS avg_trunc,
       ceil(avg(r.score))                        AS avg_ceil
FROM   institutions i JOIN reviews r ON r.institution_id = i.id
GROUP  BY i.id, i.short_name
ORDER  BY avg_raw DESC LIMIT 5;

-- частка закладу в загальній кількості здобувачів (%) і відхилення від середнього (abs)
SELECT institution_id, sum(students_count) AS students,
       round(100.0 * sum(students_count) / sum(sum(students_count)) OVER (), 2)    AS percent,
       abs(sum(students_count) - avg(sum(students_count)) OVER ())::int             AS deviation
FROM   institution_specialties
GROUP  BY institution_id
ORDER  BY students DESC LIMIT 5;

-- розподіл рейтингу на 4 рівні інтервали (width_bucket) — гістограма
SELECT width_bucket(rating_total, 600, 1000, 4) AS bucket, min(rating_total), max(rating_total), count(*)
FROM   institutions WHERE rating_total IS NOT NULL
GROUP  BY 1 ORDER BY 1;

-- COALESCE: NULL у розрахунку дає NULL, тому підставляємо 0
SELECT short_name, rating_total, rating_total + 10 AS plus_null, COALESCE(rating_total, 0) + 10 AS plus_coalesce
FROM   institutions ORDER BY rating_total NULLS FIRST LIMIT 4;

-- == 4. Функції в INSERT і UPDATE ==
BEGIN;

-- нове відношення для збереження розрахованої статистики
CREATE TABLE lab_institution_stats (
    institution_id  INTEGER PRIMARY KEY REFERENCES institutions (id),
    programs        INTEGER       NOT NULL,
    students        INTEGER       NOT NULL,
    avg_per_program NUMERIC(8, 2) NOT NULL,
    share_percent   NUMERIC(5, 2) NOT NULL
);

-- INSERT ... SELECT з обчисленнями
INSERT INTO lab_institution_stats
SELECT institution_id,
       count(*),
       sum(students_count),
       round(avg(students_count), 2),
       round(100.0 * sum(students_count) / (SELECT sum(students_count) FROM institution_specialties), 2)
FROM   institution_specialties
GROUP  BY institution_id;

SELECT * FROM lab_institution_stats ORDER BY share_percent DESC LIMIT 5;

-- UPDATE з арифметикою та округленням: +7.5% здобувачів, результат округлено вгору
UPDATE institution_specialties
SET    students_count = ceil(students_count * 1.075)
WHERE  institution_id = (SELECT institution_id FROM lab_institution_stats ORDER BY students DESC LIMIT 1)
RETURNING program_name, students_count;

-- UPDATE з power / sqrt: нормування рейтингу до шкали 0..100
UPDATE institutions
SET    rating = round(100 * sqrt(rating_total::numeric / 1000))
WHERE  rating_total IS NOT NULL
RETURNING short_name, rating_total, rating;

ROLLBACK;
