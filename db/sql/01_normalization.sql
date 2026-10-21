-- =====================================================================
-- 01. МОДУЛЬ 2 (теми 4-5): реляційна модель, функціональні залежності,
--     декомпозиція без втрат (нормалізація до 3НФ)
-- =====================================================================
--
-- ФУНКЦІОНАЛЬНІ ЗАЛЕЖНОСТІ (аналіз початкових таблиць)
--
--  institutions(id PK, edbo_code UK, name, type, ownership, region, city, ...)
--   FD1: id        -> усі атрибути                        (ключ, ок)
--   FD2: city      -> region    (населений пункт належить області)
--                   id -> city -> region   ТРАНЗИТИВНА залежність, порушує 3НФ
--   FD3: type, ownership — значення з обмеженого довідника, що повторюються
--        тисячі разів (аномалії оновлення: "Приватна" / "приватна")
--
--  institution_specialties(id PK, institution_id, specialty_code, specialty_name, ...)
--   Природний ключ: (institution_id, specialty_code, program_name)
--   FD4: specialty_code -> specialty_name   залежить лише від ЧАСТИНИ ключа
--        => ЧАСТКОВА залежність, порушує 2НФ
--
--  institutions.rating_*  — "знімок" рейтингу, що змінюється незалежно від закладу
--   => історія виноситься в rating_history (02_ddl.sql, 10_triggers.sql)
--
-- ДЕКОМПОЗИЦІЯ (без втрат інформації — перевірка в кінці файлу):
--   institutions            ->  institutions(city_id, type_id, ownership_id)
--                               + cities + regions + institution_types + ownership_forms
--   institution_specialties ->  institution_specialties(specialty_code FK) + specialty_dict
--
-- Старі текстові колонки (region, city, type, ownership) ЗАЛИШЕНІ свідомо:
-- парсери на Python пишуть саме в них. Узгодженість забезпечує тригер
-- trg_institutions_01_normalize (10_triggers.sql), який сам заповнює
-- city_id / type_id / ownership_id.
-- =====================================================================

-- ---------- допоміжні функції очищення (парсер пише str(NaN) = 'nan') ----------
CREATE OR REPLACE FUNCTION fn_clean_text(p_value TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
               WHEN p_value IS NULL THEN NULL
               WHEN btrim(p_value) = '' THEN NULL
               WHEN lower(btrim(p_value)) IN ('nan', 'none', 'null', 'nat') THEN NULL
               ELSE btrim(p_value)
           END
$$;

-- дата акредитації у парсері зберігається рядком "31.12.2027"
CREATE OR REPLACE FUNCTION fn_parse_date(p_value TEXT)
RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
               WHEN p_value ~ '^\d{2}\.\d{2}\.\d{4}$' THEN to_date(p_value, 'DD.MM.YYYY')
               WHEN p_value ~ '^\d{4}-\d{2}-\d{2}'    THEN left(p_value, 10)::date
               ELSE NULL
           END
$$;

-- ---------- довідники (результат декомпозиції) ----------
CREATE TABLE IF NOT EXISTS regions (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS cities (
    id         SERIAL PRIMARY KEY,
    region_id  INTEGER      NOT NULL REFERENCES regions(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    name       VARCHAR(100) NOT NULL,
    CONSTRAINT uq_city_in_region UNIQUE (region_id, name)   -- назви міст повторюються між областями
);

CREATE TABLE IF NOT EXISTS institution_types (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS ownership_forms (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS specialty_dict (
    code  VARCHAR(100) PRIMARY KEY,     -- код спеціальності, напр. 121
    name  TEXT         NOT NULL
);

-- ---------- зовнішні ключі в institutions ----------
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS city_id      INTEGER REFERENCES cities(id);
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS type_id      INTEGER REFERENCES institution_types(id);
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS ownership_id INTEGER REFERENCES ownership_forms(id);

-- ---------- наповнення довідників з наявних даних (INSERT ... SELECT) ----------
INSERT INTO regions(name)
SELECT DISTINCT COALESCE(fn_clean_text(region), 'Не вказано') FROM institutions
ON CONFLICT (name) DO NOTHING;

INSERT INTO cities(region_id, name)
SELECT DISTINCT r.id, COALESCE(fn_clean_text(i.city), 'Не вказано')
FROM institutions i
JOIN regions r ON r.name = COALESCE(fn_clean_text(i.region), 'Не вказано')
ON CONFLICT (region_id, name) DO NOTHING;

INSERT INTO institution_types(name)
SELECT DISTINCT COALESCE(fn_clean_text(type), 'Не вказано') FROM institutions
ON CONFLICT (name) DO NOTHING;

INSERT INTO ownership_forms(name)
SELECT DISTINCT COALESCE(fn_clean_text(ownership), 'Не вказано') FROM institutions
ON CONFLICT (name) DO NOTHING;

-- ---------- проставляємо ключі (UPDATE ... FROM) ----------
UPDATE institutions i
SET    city_id = c.id
FROM   cities c
JOIN   regions r ON r.id = c.region_id
WHERE  r.name = COALESCE(fn_clean_text(i.region), 'Не вказано')
  AND  c.name = COALESCE(fn_clean_text(i.city),   'Не вказано');

UPDATE institutions i SET type_id = t.id
FROM   institution_types t
WHERE  t.name = COALESCE(fn_clean_text(i.type), 'Не вказано');

UPDATE institutions i SET ownership_id = o.id
FROM   ownership_forms o
WHERE  o.name = COALESCE(fn_clean_text(i.ownership), 'Не вказано');

-- ---------- спеціальності: часткова залежність code -> name (2НФ) ----------
UPDATE institution_specialties SET specialty_code = NULL
WHERE  specialty_code IS NOT NULL AND fn_clean_text(specialty_code) IS NULL;

INSERT INTO specialty_dict(code, name)
SELECT specialty_code,
       COALESCE(mode() WITHIN GROUP (ORDER BY fn_clean_text(specialty_name)), 'Без назви')
FROM   institution_specialties
WHERE  specialty_code IS NOT NULL
GROUP  BY specialty_code
ON CONFLICT (code) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_inst_spec_specialty') THEN
        ALTER TABLE institution_specialties
            ADD CONSTRAINT fk_inst_spec_specialty
            FOREIGN KEY (specialty_code) REFERENCES specialty_dict(code)
            ON UPDATE CASCADE ON DELETE RESTRICT;
    END IF;
END $$;

-- ---------- ПЕРЕВІРКА: декомпозиція без втрат (lossless join) ----------
-- З'єднання частин має відновити початкову таблицю: різниця в обидва боки = 0 рядків.
WITH original AS (
    SELECT id,
           COALESCE(fn_clean_text(region),    'Не вказано') AS region,
           COALESCE(fn_clean_text(city),      'Не вказано') AS city,
           COALESCE(fn_clean_text(type),      'Не вказано') AS type,
           COALESCE(fn_clean_text(ownership), 'Не вказано') AS ownership
    FROM institutions
), restored AS (
    SELECT i.id, r.name AS region, c.name AS city, t.name AS type, o.name AS ownership
    FROM institutions i
    JOIN cities c            ON c.id = i.city_id
    JOIN regions r           ON r.id = c.region_id
    JOIN institution_types t ON t.id = i.type_id
    JOIN ownership_forms o   ON o.id = i.ownership_id
)
SELECT 'lossless_join_check' AS check_name,
       (SELECT count(*) FROM original) AS rows_original,
       (SELECT count(*) FROM restored) AS rows_restored,
       (SELECT count(*) FROM (SELECT * FROM original EXCEPT SELECT * FROM restored) a) AS lost_rows,
       (SELECT count(*) FROM (SELECT * FROM restored EXCEPT SELECT * FROM original) b) AS spurious_rows;
