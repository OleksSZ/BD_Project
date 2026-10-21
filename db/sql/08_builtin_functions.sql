-- =====================================================================
-- 08. МОДУЛЬ 4 (тема 10): вбудовані функції СКБД
-- (в MySQL: CONCAT, SUBSTRING, DATE_FORMAT, IFNULL ... — нижче PostgreSQL-аналоги)
-- =====================================================================

-- ---------- Рядкові функції ----------
SELECT short_name,
       upper(short_name)                          AS upper_name,          -- UPPER
       lower(short_name)                          AS lower_name,          -- LOWER
       length(name)                               AS name_len,            -- LENGTH / CHAR_LENGTH
       left(name, 25) || '...'                    AS name_short,          -- LEFT + конкатенація ||
       concat_ws(' | ', short_name, city, region) AS card,                -- CONCAT_WS
       replace(name, 'університет', 'ун-т')       AS replaced,            -- REPLACE
       position('університет' IN lower(name))     AS pos,                 -- POSITION / LOCATE
       split_part(name, ' ', 1)                   AS first_word           -- SPLIT_PART
FROM   institutions
WHERE  name ILIKE '%університет%'
ORDER  BY id LIMIT 4;

SELECT initcap('київська область')                       AS initcap_demo,   -- перша літера велика
       lpad('42', 6, '0')                                AS lpad_demo,      -- 000042
       btrim('   пробіли   ')                            AS trim_demo,
       substring('https://knu.example/page' from '//([^/]+)') AS domain,    -- підрядок за регулярним виразом
       regexp_replace('(044) 123-45-67', '\D', '', 'g')  AS only_digits,    -- REGEXP_REPLACE
       format('Заклад %s, рейтинг %s', 'КПІ', 955)       AS formatted;      -- FORMAT

-- ---------- Числові функції ----------
SELECT round(avg(rating_total), 2)  AS avg_rating,     -- ROUND
       ceil(avg(rating_total))      AS ceil_avg,       -- CEIL
       floor(avg(rating_total))     AS floor_avg,      -- FLOOR
       abs(-15)                     AS abs_demo,
       mod(17, 5)                   AS mod_demo,       -- MOD / %
       power(2, 10)                 AS power_demo,
       sqrt(144)                    AS sqrt_demo,
       trunc(3.987, 1)              AS trunc_demo,
       sign(-7)                     AS sign_demo
FROM   institutions;

-- ---------- Функції дати й часу ----------
SELECT now()                                         AS now_ts,           -- NOW()
       CURRENT_DATE                                  AS today,            -- CURDATE()
       extract(year FROM CURRENT_DATE)               AS year_now,         -- EXTRACT / YEAR()
       date_trunc('month', now())                    AS month_start,      -- DATE_TRUNC
       to_char(now(), 'DD.MM.YYYY HH24:MI')          AS formatted,        -- DATE_FORMAT
       CURRENT_DATE + INTERVAL '30 days'             AS plus_30_days,     -- DATE_ADD
       age(DATE '2000-01-01')                        AS age_demo;         -- TIMESTAMPDIFF

SELECT short_name, founded_year,
       extract(year FROM CURRENT_DATE)::int - founded_year AS age_years
FROM   institutions WHERE founded_year IS NOT NULL ORDER BY age_years DESC LIMIT 3;

-- ---------- Умовні функції та робота з NULL ----------
SELECT short_name,
       COALESCE(website, 'сайт не вказано')              AS website,     -- IFNULL / COALESCE
       NULLIF(rating_total, 0)                           AS rating_nz,   -- NULLIF
       GREATEST(rating_total, rating_nmt_score, 0)       AS greatest,    -- GREATEST
       LEAST(founded_year, 2000)                         AS least,       -- LEAST
       CASE WHEN rating_total IS NULL THEN 'без рейтингу' ELSE 'є рейтинг' END AS has_rating   -- CASE / IF()
FROM   institutions ORDER BY id LIMIT 5;

-- ---------- Агрегатні функції ----------
SELECT count(*)                                AS cnt,
       count(DISTINCT city)                    AS cities,
       sum(rating_total)                       AS sum_rating,
       round(avg(rating_total), 1)             AS avg_rating,
       min(founded_year)                       AS min_year,
       max(founded_year)                       AS max_year,
       string_agg(DISTINCT short_name, ', ' ORDER BY short_name) FILTER (WHERE city = 'Львів') AS lviv_list,  -- GROUP_CONCAT
       array_agg(DISTINCT city ORDER BY city)  AS city_array,
       bool_and(website IS NOT NULL)           AS all_have_site,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY rating_total) AS median_rating,
       mode() WITHIN GROUP (ORDER BY city)     AS most_common_city
FROM   institutions;

-- ---------- Перетворення типів ----------
SELECT CAST('2025' AS INTEGER) + 1              AS cast_demo,      -- CAST
       '3.14'::numeric * 2                      AS double_colon,   -- оператор ::
       to_number('1,250.50', '9G999D99')        AS to_number_demo,
       to_date('31.12.2027', 'DD.MM.YYYY')      AS to_date_demo,
       fn_parse_date('31.12.2027')              AS own_function;   -- власна функція (файл 09 / 01)

-- ---------- JSON-функції (дані для REST API) ----------
SELECT jsonb_build_object('id', id, 'name', short_name, 'city', city_name, 'rating', rating_total) AS card
FROM   v_institutions_full ORDER BY id LIMIT 2;

SELECT region_name, jsonb_agg(short_name ORDER BY short_name) AS institutions
FROM   v_institutions_full
GROUP  BY region_name ORDER BY region_name LIMIT 3;

-- ---------- Системні функції ----------
SELECT current_user, current_database(), version() AS server_version, pg_size_pretty(pg_database_size(current_database())) AS db_size;
