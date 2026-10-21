-- =====================================================================
-- 04. МОДУЛЬ 2 (тема 4): базисні засоби маніпулювання реляційними даними
-- Реляційна алгебра -> SQL. Кожна операція позначена символом.
-- Запити не залежать від конкретних даних (значення беруться з самої БД).
-- =====================================================================

-- σ  СЕЛЕКЦІЯ (вибірка рядків за умовою):  σ_{category_type=1}(institutions)
SELECT id, name, city FROM institutions WHERE category_type = 1 LIMIT 5;

-- π  ПРОЕКЦІЯ (вибір стовпців, без дублікатів):  π_{type}(institutions)
SELECT DISTINCT t.name AS institution_type
FROM   institutions i JOIN institution_types t ON t.id = i.type_id
ORDER  BY 1;

-- ρ  ПЕРЕЙМЕНУВАННЯ:  ρ_{назва/name_ua}(regions)
SELECT id AS region_id, name AS region_name FROM regions LIMIT 3;

-- ∪  ОБ'ЄДНАННЯ: міста закладів вищої освіти ∪ міста закладів фахової передвищої освіти
SELECT c.name AS city FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 1
UNION
SELECT c.name        FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 9
ORDER  BY 1;

-- ∩  ПЕРЕТИН: міста, де є і заклади вищої освіти, і коледжі
SELECT c.name AS city FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 1
INTERSECT
SELECT c.name        FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 9
ORDER  BY 1;

-- −  РІЗНИЦЯ: міста з університетами, де НЕМАЄ коледжів
SELECT c.name AS city FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 1
EXCEPT
SELECT c.name        FROM institutions i JOIN cities c ON c.id = i.city_id WHERE i.category_type = 9
ORDER  BY 1;

-- ×  ДЕКАРТІВ ДОБУТОК: (довідник типів) × (довідник форм власності) — усі можливі комбінації
SELECT t.name AS type, o.name AS ownership
FROM   institution_types t CROSS JOIN ownership_forms o
ORDER  BY 1, 2 LIMIT 8;

-- ⋈  З'ЄДНАННЯ (природне/еквівалентне): institutions ⋈ cities ⋈ regions
SELECT i.name, c.name AS city, r.name AS region
FROM   institutions i
JOIN   cities  c ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
LIMIT  5;

-- ⋈θ θ-З'ЄДНАННЯ (нерівність): пари закладів одного міста, де перший заснований раніше
SELECT a.short_name AS older, b.short_name AS newer, c.name AS city, a.founded_year, b.founded_year
FROM   institutions a
JOIN   institutions b ON b.city_id = a.city_id AND a.founded_year < b.founded_year
JOIN   cities c       ON c.id = a.city_id
ORDER  BY c.name, a.founded_year LIMIT 6;

-- ⟕  ЛІВЕ ЗОВНІШНЄ З'ЄДНАННЯ: усі заклади, навіть якщо в них немає жодної програми
SELECT i.short_name, count(isp.id) AS programs
FROM   institutions i LEFT JOIN institution_specialties isp ON isp.institution_id = i.id
GROUP  BY i.id, i.short_name
ORDER  BY programs, i.short_name LIMIT 6;

-- ÷  ДІЛЕННЯ: заклади, що пропонують УСІ дві найпоширеніші спеціальності
--    (подвійне заперечення: НЕ ІСНУЄ спеціальності з множини, якої в закладу НЕМАЄ)
WITH top2 AS (
    SELECT specialty_code AS code
    FROM   institution_specialties
    WHERE  specialty_code IS NOT NULL
    GROUP  BY specialty_code
    ORDER  BY count(DISTINCT institution_id) DESC, specialty_code
    LIMIT  2
)
SELECT i.id, i.short_name
FROM   institutions i
WHERE  NOT EXISTS (
           SELECT 1 FROM top2 t
           WHERE  NOT EXISTS (SELECT 1 FROM institution_specialties s
                              WHERE  s.institution_id = i.id AND s.specialty_code = t.code))
  AND  EXISTS (SELECT 1 FROM top2)
ORDER  BY i.id;

-- γ  ГРУПУВАННЯ та агрегація:  γ_{region; COUNT(*), AVG(rating_total)}
SELECT r.name AS region, count(*) AS institutions, round(avg(i.rating_total), 1) AS avg_rating
FROM   institutions i
JOIN   cities c  ON c.id = i.city_id
JOIN   regions r ON r.id = c.region_id
GROUP  BY r.name
ORDER  BY institutions DESC;

-- Ключі та цілісність у каталозі: PRIMARY KEY / FOREIGN KEY / UNIQUE / CHECK
SELECT conrelid::regclass AS table_name, conname AS constraint_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK' END AS type
FROM   pg_constraint
WHERE  connamespace = 'public'::regnamespace
ORDER  BY conrelid::regclass::text, 3, 2 LIMIT 12;
