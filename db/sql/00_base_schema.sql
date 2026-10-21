-- =====================================================================
-- 00. БАЗОВА СХЕМА (те, що вже створювали парсери)
-- Схема відновлена з коду parser/test.py, parser/raiting.py, web/app.py.
-- IF NOT EXISTS: на вашій існуючій БД скрипт нічого не ламає і не змінює.
-- Теми 1-2: предметна область — освітні заклади України (ЄДЕБО) + рейтинги.
-- =====================================================================

CREATE TABLE IF NOT EXISTS institutions (
    id                       SERIAL PRIMARY KEY,
    edbo_code                INTEGER      NOT NULL UNIQUE,   -- код у ЄДЕБО (природний ключ)
    name                     VARCHAR(500) NOT NULL,
    short_name               VARCHAR(200),
    type                     VARCHAR(100),
    ownership                VARCHAR(50),
    region                   VARCHAR(100),
    city                     VARCHAR(100),
    address                  VARCHAR(500),
    website                  VARCHAR(200),
    founded_year             INTEGER,
    category_type            INTEGER,                        -- ut з ЄДЕБО: 1 вища, 9 фахова передвища, 2 проф-тех ...
    coordinates              POINT,
    rating                   INTEGER,
    rating_total             INTEGER,
    rating_city_position     INTEGER,
    rating_general_position  VARCHAR(50),
    rating_nmt_score         INTEGER,
    rating_top200            INTEGER,
    rating_scopus            INTEGER,
    rating_url               VARCHAR(500),
    rating_updated_at        TIMESTAMP,
    created_at               TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS institution_specialties (
    id                         SERIAL PRIMARY KEY,
    institution_id             INTEGER NOT NULL REFERENCES institutions(id) ON DELETE CASCADE,
    specialty_name             TEXT,
    specialty_code             VARCHAR(100),
    education_level            VARCHAR(200),
    program_name               TEXT,
    specialization_name        TEXT,
    accreditation_type         VARCHAR(100),
    accreditation_series       VARCHAR(50),
    accreditation_number       VARCHAR(50),
    accreditation_valid_until  VARCHAR(30),
    students_count             INTEGER DEFAULT 0,
    source                     VARCHAR(50),
    created_at                 TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at                 TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
