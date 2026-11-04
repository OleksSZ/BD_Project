-- ЛР №14. Індекси
-- =====================================================================
-- Команди: CREATE INDEX, CREATE UNIQUE INDEX, складений індекс (правило лівої частини),
-- частковий індекс (WHERE), індекс за виразом, DROP INDEX, EXPLAIN / EXPLAIN ANALYZE,
-- ANALYZE, вимкнення послідовного сканування (аналог FORCE INDEX), розмір індексів,
-- перелік індексів у каталозі (аналог SHOW INDEX).
-- На кількох десятках рядків різниця не видна, тому для замірів створюється тимчасова
-- таблиця на 200 000 рядків, згенерована з даних закладів. TEMP-таблиця існує лише
-- в поточному підключенні і зникає після нього.
-- Запуск: python db/lab.py 14 -r 15
-- =====================================================================

-- == 1. Індекси, що вже є в БД проєкту ==
-- аналог SHOW INDEX FROM ...: усі індекси таблиць проєкту з їх визначенням
SELECT tablename, indexname, indexdef
FROM   pg_indexes
WHERE  schemaname = 'public' AND tablename IN ('institutions', 'institution_specialties', 'reviews')
ORDER  BY tablename, indexname;

-- первинні ключі та UNIQUE створюють індекси автоматично
SELECT conrelid::regclass AS table_name, conname, contype AS kind, conindid::regclass AS index_name
FROM   pg_constraint
WHERE  contype IN ('p', 'u') AND connamespace = 'public'::regnamespace
ORDER  BY 1;

-- == 2. Тестова таблиця ==
DROP TABLE IF EXISTS lab_programs_big;

-- 200 000 «програм»: усі заклади, розмножені generate_series, з випадковими значеннями
CREATE TEMP TABLE lab_programs_big AS
SELECT g                                     AS id,
       i.id                                  AS institution_id,
       i.city                                AS city,
       (ARRAY['Бакалавр', 'Магістр', 'Доктор філософії'])[1 + g % 3] AS education_level,
       (100 + g % 900)::text                 AS specialty_code,
       (random() * 500)::int                 AS students_count
FROM   generate_series(1, 200000) AS g
JOIN   institutions i ON i.id = (SELECT min(id) FROM institutions) + g % (SELECT count(*) FROM institutions);

-- оновити статистику для оптимізатора
ANALYZE lab_programs_big;

SELECT count(*) AS rows_total, count(DISTINCT specialty_code) AS specialties FROM lab_programs_big;

-- == 3. Запит без індексу ==
-- EXPLAIN показує план; Seq Scan — перебір УСІЄЇ таблиці
EXPLAIN SELECT * FROM lab_programs_big WHERE specialty_code = '121';

-- EXPLAIN ANALYZE реально виконує запит і показує фактичний час (Execution Time)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT * FROM lab_programs_big WHERE specialty_code = '121';

-- == 4. CREATE INDEX ==
-- звичайний (B-tree) індекс на одному стовпці
CREATE INDEX idx_lab_big_specialty ON lab_programs_big (specialty_code);

-- той самий запит тепер іде через індекс (Index Scan / Bitmap Index Scan) — значно менше рядків і часу
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT * FROM lab_programs_big WHERE specialty_code = '121';

-- == 5. Складений індекс і правило лівої частини ==
CREATE INDEX idx_lab_big_inst_level ON lab_programs_big (institution_id, education_level);

-- умова на ПЕРШИЙ стовпець індексу — індекс використовується
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE institution_id = 5;

-- умова на обидва стовпці — індекс використовується повністю
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE institution_id = 5 AND education_level = 'Магістр';

-- умова лише на ДРУГИЙ стовпець — ліва частина відсутня, тому Seq Scan
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE education_level = 'Магістр';

-- == 6. UNIQUE, частковий індекс, індекс за виразом ==
-- унікальний індекс: забороняє повтори значень
CREATE UNIQUE INDEX uq_lab_big_id ON lab_programs_big (id);

-- очікувана помилка: значення id = 1 уже є, унікальний індекс не дозволить дубль
INSERT INTO lab_programs_big (id, institution_id) VALUES (1, 1);

-- частковий індекс: лише рядки, що задовольняють умову (менший за розміром)
CREATE INDEX idx_lab_big_large ON lab_programs_big (students_count) WHERE students_count > 450;
EXPLAIN (COSTS OFF) SELECT count(*) FROM lab_programs_big WHERE students_count > 480;

-- індекс за виразом: пошук без урахування регістру
CREATE INDEX idx_lab_big_lower_city ON lab_programs_big (lower(city));
EXPLAIN (COSTS OFF) SELECT count(*) FROM lab_programs_big WHERE lower(city) = 'київ';

-- == 7. Коли оптимізатор ігнорує індекс ==
-- низька селективність: умова відбирає більшість рядків -> вигідніше читати таблицю цілком
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE specialty_code > '1';

-- «примусове» використання індексу (аналог FORCE INDEX): вимкнути послідовне сканування в сесії
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE education_level = 'Магістр';
RESET enable_seqscan;

-- == 8. Розмір і видалення індексів ==
-- індекси займають місце на диску
SELECT indexrelid::regclass AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM   pg_index
WHERE  indrelid = 'lab_programs_big'::regclass
ORDER  BY pg_relation_size(indexrelid) DESC;

SELECT pg_size_pretty(pg_relation_size('lab_programs_big')) AS table_size;

-- DROP INDEX: після видалення запит знову виконується послідовним скануванням
DROP INDEX idx_lab_big_specialty;
EXPLAIN (COSTS OFF) SELECT * FROM lab_programs_big WHERE specialty_code = '121';

-- прибрати тестову таблицю
DROP TABLE lab_programs_big;
