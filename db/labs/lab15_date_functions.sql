-- ЛР №15. Вбудовані функції: опрацювання дат і часу
-- =====================================================================
-- Функції: now(), CURRENT_DATE, CURRENT_TIME, CURRENT_TIMESTAMP, EXTRACT / date_part,
-- date_trunc, to_char (форматування, назви днів і місяців), to_date / to_timestamp,
-- арифметика з INTERVAL, різниця дат, age(), make_date, generate_series для дат,
-- перетворення ::date, часові пояси (AT TIME ZONE).
-- Застосування у SELECT, INSERT, UPDATE; зміна структури (новий стовпець DATE).
-- Відповідники MySQL наведено в коментарях.
-- Зміни даних — всередині BEGIN ... ROLLBACK.
-- Запуск: python db/lab.py 15
-- =====================================================================

-- == 1. Поточна дата й час ==
-- MySQL: NOW(), CURDATE(), CURTIME()
SELECT now()             AS now_ts,
       CURRENT_DATE      AS today,
       CURRENT_TIME      AS time_now,
       CURRENT_TIMESTAMP AS current_ts,
       localtimestamp    AS without_tz;

-- == 2. Частини дати ==
-- MySQL: YEAR(), MONTH(), DAY(), DAYOFWEEK(), DAYOFYEAR(), WEEK(), QUARTER()
SELECT extract(year    FROM d) AS year,
       extract(month   FROM d) AS month,
       extract(day     FROM d) AS day,
       extract(dow     FROM d) AS day_of_week_0_sun,  -- 0 = неділя (у MySQL DAYOFWEEK: 1 = неділя)
       extract(isodow  FROM d) AS iso_day_1_mon,      -- 1 = понеділок (MySQL WEEKDAY + 1)
       extract(doy     FROM d) AS day_of_year,
       extract(week    FROM d) AS week,
       extract(quarter FROM d) AS quarter
FROM   (SELECT DATE '2022-02-03' AS d) t;

-- date_part — те саме у вигляді функції; date_trunc — «обрізати» дату до місяця / року
SELECT date_part('hour', now())            AS hour_now,
       date_trunc('month', now())::date    AS month_start,
       date_trunc('year',  now())::date    AS year_start;

-- == 3. Форматування і розбір дат ==
-- to_char (MySQL: DATE_FORMAT): дата у вигляді ДД.ММ.РРРР, назва дня тижня і місяця
SELECT to_char(now(), 'DD.MM.YYYY HH24:MI')     AS formatted,
       to_char(now(), 'TMDay')                  AS day_name,      -- MySQL: DAYNAME(); мова — за параметром lc_time
       to_char(now(), 'TMMonth')                AS month_name,    -- MySQL: MONTHNAME()
       to_char(now(), '"Q"Q YYYY, "тиждень" IW') AS quarter_week;

-- to_date / to_timestamp (MySQL: STR_TO_DATE): рядок -> дата
SELECT to_date('31.12.2027', 'DD.MM.YYYY')                    AS from_text,
       to_timestamp('03-02-2022 22:23', 'DD-MM-YYYY HH24:MI') AS ts_from_text,
       '2022-02-03'::date                                     AS cast_to_date;

-- очікувана помилка: некоректна дата (у MySQL залежно від sql_mode може стати 0000-00-00)
SELECT DATE '2022-02-31';

-- == 4. Арифметика дат ==
-- + / - INTERVAL (MySQL: DATE_ADD / DATE_SUB), різниця дат у днях (MySQL: DATEDIFF)
SELECT CURRENT_DATE + INTERVAL '1 month'               AS plus_month,
       CURRENT_DATE - INTERVAL '2 years 3 days'        AS minus_interval,
       CURRENT_DATE + 30                               AS plus_30_days,
       DATE '2027-12-31' - CURRENT_DATE                AS days_until,
       age(DATE '2027-12-31', CURRENT_DATE)::text      AS age_interval;

-- останній день місяця (MySQL: LAST_DAY) і дата з частин (MySQL: MAKEDATE)
SELECT (date_trunc('month', CURRENT_DATE) + INTERVAL '1 month - 1 day')::date AS last_day,
       make_date(2025, 9, 1)                                                AS academic_year_start;

-- послідовність дат: перші дні наступних 6 місяців
SELECT generate_series(date_trunc('month', CURRENT_DATE), date_trunc('month', CURRENT_DATE) + INTERVAL '5 months',
                       INTERVAL '1 month')::date AS month_start;

-- часовий пояс
SELECT now() AT TIME ZONE 'Europe/Kyiv' AS kyiv_time, now() AT TIME ZONE 'UTC' AS utc_time;

-- == 5. Функції дат у запитах на вибір ==
-- вік закладу: поточний рік мінус рік заснування
SELECT short_name, founded_year, extract(year FROM CURRENT_DATE)::int - founded_year AS age_years
FROM   institutions WHERE founded_year IS NOT NULL
ORDER  BY age_years DESC LIMIT 5;

-- акредитація зберігається рядком «ДД.ММ.РРРР»: перетворюємо на дату і рахуємо, скільки днів лишилось
SELECT program_name,
       accreditation_valid_until                                   AS as_text,
       to_date(accreditation_valid_until, 'DD.MM.YYYY')            AS as_date,
       to_date(accreditation_valid_until, 'DD.MM.YYYY') - CURRENT_DATE AS days_left
FROM   institution_specialties
WHERE  accreditation_valid_until ~ '^\d{2}\.\d{2}\.\d{4}$'
ORDER  BY days_left LIMIT 5;

-- групування за роком закінчення акредитації
SELECT extract(year FROM to_date(accreditation_valid_until, 'DD.MM.YYYY')) AS year_expires, count(*) AS programs
FROM   institution_specialties
WHERE  accreditation_valid_until ~ '^\d{2}\.\d{2}\.\d{4}$'
GROUP  BY 1 ORDER BY 1;

-- відгуки за останні 7 днів, дата у зручному форматі
SELECT author, to_char(created_at, 'DD.MM.YYYY HH24:MI') AS created, date_trunc('second', now() - created_at)::text AS ago
FROM   reviews
WHERE  created_at >= now() - INTERVAL '7 days'
ORDER  BY created_at DESC LIMIT 5;

-- == 6. Функції дат у INSERT, UPDATE і зміні структури ==
BEGIN;

-- INSERT: дата, обчислена функцією (відгук «три дні тому»)
INSERT INTO reviews (institution_id, author, score, comment, created_at)
VALUES ((SELECT min(id) FROM institutions), 'ЛР15 Автор', 4, 'Дата створення обчислена', now() - INTERVAL '3 days')
RETURNING author, created_at, CURRENT_DATE - created_at::date AS days_ago;

-- зміна структури: новий стовпець типу DATE і перенесення в нього дат із текстового поля
ALTER TABLE institution_specialties ADD COLUMN accreditation_date DATE;

UPDATE institution_specialties
SET    accreditation_date = to_date(accreditation_valid_until, 'DD.MM.YYYY')
WHERE  accreditation_valid_until ~ '^\d{2}\.\d{2}\.\d{4}$';

-- UPDATE: продовжити на 1 рік акредитації, що спливають протягом найближчих 2 років
UPDATE institution_specialties
SET    accreditation_date = accreditation_date + INTERVAL '1 year'
WHERE  accreditation_date < CURRENT_DATE + INTERVAL '2 years'
RETURNING program_name, accreditation_valid_until AS old_text, accreditation_date AS new_date;

ROLLBACK;
