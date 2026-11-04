-- ЛР №17. Вбудовані функції: опрацювання символів і перетворення типів
-- =====================================================================
-- Функції: upper / lower / initcap, || і concat / concat_ws, length / char_length / octet_length,
-- substring / left / right, trim / ltrim / rtrim, position / strpos (MySQL: LOCATE / INSTR),
-- replace, translate, lpad / rpad, repeat, reverse, split_part, string_agg, regexp_replace,
-- format, ascii / chr, md5, CAST і :: (число <-> рядок, рядок -> дата), to_char / to_number,
-- COALESCE для текстових замінників NULL.
-- Застосування у SELECT, INSERT, UPDATE. Зміни даних — всередині BEGIN ... ROLLBACK.
-- Запуск: python db/lab.py 17
-- =====================================================================

-- == 1. Регістр, об'єднання, довжина ==
SELECT upper('київ') AS upper, lower('КИЇВ') AS lower, initcap('львівська політехніка') AS initcap;

-- || і concat: concat пропускає NULL, а || з NULL дає NULL; concat_ws — з роздільником
SELECT 'КНУ' || ' - ' || NULL       AS pipe_with_null,
       concat('КНУ', ' - ', NULL)   AS concat_with_null,
       concat_ws(', ', 'Київ', 'вул. Володимирська', '60') AS concat_ws;

-- довжина в символах і в байтах: кирилиця в UTF-8 займає 2 байти на символ
SELECT length('Київ') AS length, char_length('Київ') AS char_length, octet_length('Київ') AS bytes,
       octet_length('Kyiv') AS bytes_latin;

-- == 2. Підрядки та пошук ==
SELECT substring('Інженерія програмного забезпечення' FROM 1 FOR 9) AS substring,
       left('Комп''ютерні науки', 4)  AS left_4,
       right('Комп''ютерні науки', 5) AS right_5,
       position('наук' IN 'Комп''ютерні науки') AS position,
       strpos('Комп''ютерні науки', 'наук')     AS strpos;

-- split_part: частина рядка за роздільником
SELECT split_part('https://knu.example/abiturient', '/', 3) AS domain;

-- == 3. Заміна, очищення, доповнення ==
SELECT replace('http://knu.example', 'http://', 'https://') AS replace,
       translate('КНУ-2024', '-0123456789', '_') AS translate,   -- видалити цифри, '-' -> '_'
       trim('   КПІ   ')  AS trim, ltrim('   КПІ') AS ltrim, rtrim('КПІ   ') AS rtrim,
       btrim('**КПІ**', '*') AS btrim_chars;

-- lpad / rpad: доповнити до заданої довжини (напр. код ЄДЕБО до 6 цифр)
SELECT lpad('41', 6, '0') AS lpad, rpad('КНУ', 8, '.') AS rpad, repeat('=', 10) AS repeat,
       reverse('КПІ') AS reverse;

-- регулярні вирази: прибрати все, крім цифр
SELECT regexp_replace('тел.: +38 (044) 239-33-33', '[^0-9]', '', 'g') AS digits_only;

-- format: шаблон з підстановкою (%s — значення, %I — ідентифікатор, %L — літерал)
SELECT format('Заклад %s засновано в %s році', 'КНУ', 1834) AS formatted;

-- коди символів: ascii / chr (MySQL: ASCII / CHAR, ORD)
SELECT ascii('A') AS ascii_a, chr(65) AS chr_65, ascii('К') AS unicode_k, chr(1050) AS chr_1050;

-- == 4. Перетворення типів ==
-- CAST і скорочення :: (рядок -> число, число -> рядок, рядок -> дата)
SELECT CAST('2024' AS INTEGER) + 1 AS text_to_int,
       '3.75'::numeric * 2         AS text_to_numeric,
       1834::text || ' рік'        AS int_to_text,
       CAST('31.12.2027' AS TEXT)  AS text,
       '2027-12-31'::date          AS text_to_date;

-- to_char / to_number: перетворення з форматом
SELECT to_char(1234.5, 'FM9999.00') AS number_to_text,
       to_number('1,234.50', '9,999.99') AS text_to_number,
       to_char(DATE '2027-12-31', 'DD.MM.YYYY') AS date_to_text;

-- очікувана помилка: рядок не є числом
SELECT 'дві тисячі'::integer;

-- == 5. Функції у запитах на вибір ==
-- назва у верхньому регістрі, перші 25 символів і довжина
SELECT upper(short_name) AS short_upper, left(name, 25) || '...' AS name_short, char_length(name) AS len
FROM   institutions ORDER BY len DESC LIMIT 5;

-- COALESCE: замість NULL — текстова примітка (MySQL: IFNULL)
SELECT short_name, COALESCE(website, 'сайт не вказано') AS website
FROM   institutions ORDER BY website NULLS FIRST LIMIT 5;

-- домен сайту закладу
SELECT short_name, split_part(website, '/', 3) AS domain
FROM   institutions WHERE website LIKE 'http%' LIMIT 5;

-- string_agg: усі заклади міста одним рядком через кому
SELECT city, string_agg(short_name, ', ' ORDER BY short_name) AS institutions
FROM   institutions GROUP BY city ORDER BY city;

-- картка закладу одним рядком
SELECT format('%s (%s, %s) — засн. %s', short_name, city, ownership, COALESCE(founded_year::text, '?')) AS card
FROM   institutions ORDER BY id LIMIT 5;

-- == 6. Функції в INSERT і UPDATE ==
BEGIN;

-- INSERT: прибрати зайві пробіли та виправити регістр імені автора перед збереженням
INSERT INTO reviews (institution_id, author, score, comment)
VALUES ((SELECT min(id) FROM institutions), initcap(btrim('   оксана м.   ')), 5,
        concat_ws(' ', 'Відгук', 'зібрано', 'функцією', 'concat_ws'))
RETURNING author, comment;

-- UPDATE: перевести сайти на https і в нижній регістр
UPDATE institutions
SET    website = lower(replace(website, 'http://', 'https://'))
WHERE  website IS NOT NULL
RETURNING short_name, website;

-- очищення «сміттєвих» значень парсера ('nan', порожні рядки) — так працює fn_clean_text у проєкті
SELECT v AS raw, NULLIF(NULLIF(lower(btrim(v)), 'nan'), '') AS cleaned
FROM   (VALUES ('  КНУ '), ('NaN'), ('   '), ('nan')) AS t(v);

-- md5 — хеш рядка (напр. для анонімізації автора у звіті)
SELECT left(md5(author), 10) AS author_hash, score FROM reviews LIMIT 3;

ROLLBACK;
