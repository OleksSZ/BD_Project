-- ЛР №4. Переведення ER-моделі в реляційну модель
-- =====================================================================
-- Що демонструється (за системним каталогом PostgreSQL):
--  * сутність -> відношення, ідентифікатор -> PRIMARY KEY (цілісність сутностей);
--  * зв'язок 1:M -> FOREIGN KEY на стороні «багато»;
--  * зв'язок M:N -> окреме відношення з двома FK (institution_specialties);
--  * слабкі сутності -> FK NOT NULL з ON DELETE CASCADE;
--  * перевірка правил зовнішніх ключів за таблицею 4.1 методички;
--  * приведення FK до правила (ALTER TABLE ... DROP/ADD CONSTRAINT) — у транзакції з ROLLBACK;
--  * перевірка відповідності схеми транзакціям користувачів (шляхи з'єднань).
-- Запуск: python db/lab.py 4
-- =====================================================================

-- == 1. Сутності -> відношення, первинні ключі ==
-- кожна таблиця схеми та її первинний ключ
SELECT c.relname AS relation,
       pg_get_constraintdef(k.oid) AS primary_key,
       (SELECT count(*) FROM information_schema.columns col
        WHERE col.table_schema = 'public' AND col.table_name = c.relname) AS attributes
FROM   pg_class c
LEFT   JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
WHERE  c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
ORDER  BY c.relname;

-- цілісність сутностей: відношення БЕЗ первинного ключа (очікується порожній результат)
SELECT c.relname AS relation_without_pk
FROM   pg_class c
WHERE  c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
  AND  NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p');

-- альтернативні (природні) ключі — обмеження UNIQUE
SELECT conrelid::regclass AS relation, conname, pg_get_constraintdef(oid) AS unique_key
FROM   pg_constraint
WHERE  contype = 'u' AND connamespace = 'public'::regnamespace
ORDER  BY 1;

-- == 2. Зв'язки -> зовнішні ключі ==
-- кожен FK: дочірнє відношення (сторона «багато»), батьківське, обов'язковість і правила
SELECT conrelid::regclass  AS child,
       a.attname           AS fk_column,
       confrelid::regclass AS parent,
       CASE WHEN a.attnotnull THEN 'обов''язковий (NOT NULL)' ELSE 'необов''язковий (NULL)' END AS participation,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' WHEN 'n' THEN 'SET NULL' ELSE 'NO ACTION' END AS on_delete,
       CASE confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' WHEN 'n' THEN 'SET NULL' ELSE 'NO ACTION' END AS on_update
FROM   pg_constraint k
JOIN   pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
WHERE  k.contype = 'f' AND k.connamespace = 'public'::regnamespace
ORDER  BY parent, child;

-- зв'язок M:N «заклад – спеціальність» реалізовано окремим відношенням з двома FK і власними атрибутами
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_name = 'institution_specialties'
  AND  column_name IN ('institution_id', 'specialty_code', 'education_level', 'program_name', 'students_count')
ORDER  BY ordinal_position;

-- == 3. Перевірка FK за таблицею 4.1 ==
-- слабка сутність: NOT NULL + ON DELETE CASCADE + ON UPDATE CASCADE
-- обов'язковий зв'язок: NOT NULL + ON DELETE RESTRICT + ON UPDATE CASCADE
-- необов'язковий зв'язок: NULL + ON DELETE SET NULL (або RESTRICT — рядок 3 таблиці 4.1) + ON UPDATE CASCADE
WITH fk AS (
    SELECT conrelid::regclass AS child, a.attname AS fk_column, confrelid::regclass AS parent,
           a.attnotnull AS not_null, confdeltype AS del, confupdtype AS upd
    FROM   pg_constraint k
    JOIN   pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
    WHERE  k.contype = 'f' AND k.connamespace = 'public'::regnamespace
)
SELECT child, fk_column, parent,
       CASE WHEN del = 'c'  THEN 'слабка сутність'
            WHEN not_null   THEN 'обов''язковий'
            ELSE                 'необов''язковий' END AS link_kind,
       CASE WHEN del = 'c'  THEN 'NOT NULL, DELETE CASCADE, UPDATE CASCADE'
            WHEN not_null   THEN 'NOT NULL, DELETE RESTRICT, UPDATE CASCADE'
            ELSE                 'NULL, DELETE SET NULL або RESTRICT, UPDATE CASCADE' END AS rule_4_1,
       CASE WHEN del = 'c' AND not_null AND upd = 'c'         THEN 'так'
            WHEN del = 'r' AND not_null AND upd = 'c'         THEN 'так'
            WHEN NOT not_null AND del IN ('n', 'r') AND upd = 'c' THEN 'так'
            ELSE 'ні' END AS matches
FROM   fk
ORDER  BY matches, child;

-- == 4. Приведення FK до правила таблиці 4.1 ==
BEGIN;

-- необов'язковий зв'язок «місто – заклад»: замінити FK на ON DELETE SET NULL ON UPDATE CASCADE
ALTER TABLE institutions DROP CONSTRAINT institutions_city_id_fkey;
ALTER TABLE institutions ADD CONSTRAINT institutions_city_id_fkey
    FOREIGN KEY (city_id) REFERENCES cities (id) ON DELETE SET NULL ON UPDATE CASCADE;

-- слабка сутність «відгук»: додати ON UPDATE CASCADE
ALTER TABLE reviews DROP CONSTRAINT reviews_institution_id_fkey;
ALTER TABLE reviews ADD CONSTRAINT reviews_institution_id_fkey
    FOREIGN KEY (institution_id) REFERENCES institutions (id) ON DELETE CASCADE ON UPDATE CASCADE;

-- SET NULL виконується як UPDATE закладу, а тригер нормалізації (10_triggers.sql) на UPDATE
-- одразу відновив би місто з текстового поля city. Щоб побачити «чисту» дію правила FK,
-- вимикаємо тригер у межах транзакції
ALTER TABLE institutions DISABLE TRIGGER trg_institutions_01_normalize;

-- перевірка дії нового правила: місто видалено -> у його закладів city_id = NULL, заклади залишились
SELECT set_config('lab.city', min(city_id)::text, true) AS deleted_city_id FROM institutions;
DELETE FROM cities WHERE id = current_setting('lab.city')::int;
SELECT id, short_name, city_id, city AS city_text FROM institutions WHERE city_id IS NULL;

-- оновлені правила в каталозі
SELECT conrelid::regclass AS child, conname, pg_get_constraintdef(oid) AS definition
FROM   pg_constraint
WHERE  conname IN ('institutions_city_id_fkey', 'reviews_institution_id_fkey');

ROLLBACK;

-- == 5. Перевірка відповідності транзакціям користувачів ==
-- Т1 «знайти заклади області, що мають програму зі спеціальності»: шлях regions -> cities -> institutions -> institution_specialties -> specialty_dict
SELECT r.name AS region, i.short_name, d.code, d.name AS specialty
FROM   regions r
JOIN   cities c ON c.region_id = r.id
JOIN   institutions i ON i.city_id = c.id
JOIN   institution_specialties s ON s.institution_id = i.id
JOIN   specialty_dict d ON d.code = s.specialty_code
WHERE  d.code = (SELECT min(code) FROM specialty_dict)
ORDER  BY r.name, i.short_name
LIMIT  6;

-- Т2 «середня оцінка відгуків і кількість відгуків закладу»: шлях institutions -> reviews
SELECT i.short_name, count(v.id) AS reviews, round(avg(v.score), 2) AS avg_score
FROM   institutions i JOIN reviews v ON v.institution_id = i.id
GROUP  BY i.id, i.short_name
ORDER  BY reviews DESC LIMIT 5;

-- Т3 «історія зміни рейтингу закладу»: шлях institutions -> rating_history
SELECT i.short_name, h.rating_total, h.recorded_at::date AS recorded
FROM   institutions i JOIN rating_history h ON h.institution_id = i.id
ORDER  BY h.recorded_at DESC LIMIT 5;
