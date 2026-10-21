-- =====================================================================
-- 02. МОДУЛЬ 3 (теми 6-7): мова SQL, складова DDL — опис структури БД
-- CREATE / ALTER / DROP / TRUNCATE, типи даних, обмеження цілісності
-- =====================================================================

-- ---------- ENUM-тип (власний тип даних) ----------
DO $$
BEGIN
    CREATE TYPE review_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------- CREATE TABLE: відгуки про заклади (зв'язок 1:M з institutions) ----------
CREATE TABLE IF NOT EXISTS reviews (
    id              SERIAL PRIMARY KEY,
    institution_id  INTEGER       NOT NULL REFERENCES institutions(id) ON DELETE CASCADE,
    author          VARCHAR(100)  NOT NULL,
    score           SMALLINT      NOT NULL,
    comment         TEXT,
    status          review_status NOT NULL DEFAULT 'approved',
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_reviews_score  CHECK (score BETWEEN 1 AND 5),
    CONSTRAINT ck_reviews_author CHECK (length(btrim(author)) >= 2)
);

-- ---------- CREATE TABLE: історія рейтингу (результат декомпозиції institutions.rating_*) ----------
CREATE TABLE IF NOT EXISTS rating_history (
    id                SERIAL PRIMARY KEY,
    institution_id    INTEGER     NOT NULL REFERENCES institutions(id) ON DELETE CASCADE,
    rating_total      INTEGER,
    city_position     INTEGER,
    general_position  VARCHAR(50),
    recorded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- CREATE TABLE: журнал аудиту (заповнюється тригерами, JSONB для старих/нових значень) ----------
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL PRIMARY KEY,
    table_name  TEXT        NOT NULL,
    operation   TEXT        NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    row_id      INTEGER,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT        NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- CREATE TABLE: журнал службових задач (адміністрування, події) ----------
CREATE TABLE IF NOT EXISTS maintenance_log (
    id           SERIAL PRIMARY KEY,
    task         TEXT        NOT NULL,
    details      TEXT,
    executed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- журнал DDL-подій (заповнюється event trigger, файл 12) ----------
CREATE TABLE IF NOT EXISTS ddl_log (
    id           SERIAL PRIMARY KEY,
    command_tag  TEXT,
    object_type  TEXT,
    object_name  TEXT,
    executed_by  TEXT        DEFAULT current_user,
    executed_at  TIMESTAMPTZ DEFAULT now()
);

-- ---------- ALTER TABLE: додавання стовпців ----------
-- Похідні агрегати відгуків зберігаються у institutions (підтримуються тригером, файл 10)
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS avg_review_score NUMERIC(3, 2);
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS reviews_count    INTEGER NOT NULL DEFAULT 0;

-- ---------- ALTER TABLE: обмеження цілісності на існуючі таблиці ----------
-- NOT VALID: нові/змінені рядки перевіряються одразу, а вже наявні (з парсера) — після очищення
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_institutions_year') THEN
        ALTER TABLE institutions
            ADD CONSTRAINT ck_institutions_year
            CHECK (founded_year IS NULL OR founded_year BETWEEN 800 AND 2100) NOT VALID;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_specialties_students') THEN
        ALTER TABLE institution_specialties
            ADD CONSTRAINT ck_specialties_students
            CHECK (students_count IS NULL OR students_count >= 0) NOT VALID;
    END IF;
END $$;

-- ---------- COMMENT: документація в самій БД ----------
COMMENT ON TABLE  reviews                  IS 'Відгуки користувачів про навчальні заклади (1:M до institutions)';
COMMENT ON TABLE  rating_history           IS 'Історія змін рейтингу закладу; заповнюється тригером';
COMMENT ON TABLE  audit_log                IS 'Аудит змін (INSERT/UPDATE/DELETE) у JSONB; заповнюється тригерами';
COMMENT ON COLUMN reviews.score            IS 'Оцінка від 1 до 5';
COMMENT ON COLUMN institutions.city_id     IS 'FK на cities (3НФ); підтримується тригером trg_institutions_01_normalize';

-- ---------- Повний цикл DDL на навчальній таблиці: CREATE -> ALTER -> RENAME -> TRUNCATE -> DROP ----------
DROP TABLE IF EXISTS demo_ddl;

CREATE TABLE demo_ddl (
    id    SERIAL PRIMARY KEY,
    title VARCHAR(50) NOT NULL
);

ALTER TABLE demo_ddl ADD COLUMN price NUMERIC(8, 2) DEFAULT 0;         -- додати стовпець
ALTER TABLE demo_ddl ALTER COLUMN title TYPE VARCHAR(200);              -- змінити тип
ALTER TABLE demo_ddl ALTER COLUMN price SET NOT NULL;                   -- додати обмеження
ALTER TABLE demo_ddl ADD CONSTRAINT ck_demo_price CHECK (price >= 0);   -- перевірочне обмеження
ALTER TABLE demo_ddl RENAME COLUMN title TO name;                       -- перейменувати стовпець
ALTER TABLE demo_ddl RENAME TO demo_ddl_renamed;                        -- перейменувати таблицю

INSERT INTO demo_ddl_renamed (name, price) VALUES ('рядок 1', 10), ('рядок 2', 20);

-- структура таблиці з системного каталогу (аналог DESCRIBE у MySQL)
SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
FROM   information_schema.columns
WHERE  table_name = 'demo_ddl_renamed'
ORDER  BY ordinal_position;

TRUNCATE TABLE demo_ddl_renamed RESTART IDENTITY;     -- швидко очистити таблицю й скинути лічильник
ALTER TABLE demo_ddl_renamed DROP COLUMN price;       -- видалити стовпець
DROP TABLE demo_ddl_renamed;                          -- видалити таблицю

-- ---------- Структура всієї БД: таблиці, їх розмір і кількість рядків ----------
SELECT c.relname AS table_name,
       c.reltuples::bigint AS approx_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'public' AND c.relkind = 'r'
ORDER  BY pg_total_relation_size(c.oid) DESC;
