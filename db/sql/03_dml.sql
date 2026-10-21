-- =====================================================================
-- 03. МОДУЛЬ 3 (тема 7): складова DML — маніпулювання даними
-- INSERT / UPDATE / DELETE / UPSERT / RETURNING
-- Демонстрації працюють з таблицею reviews та довідниками, реальні дані не псують.
-- Скрипт ідемпотентний (можна запускати багато разів).
-- =====================================================================

-- ---------- INSERT: один рядок з поверненням згенерованого ключа (RETURNING) ----------
INSERT INTO reviews (institution_id, author, score, comment)
SELECT id, 'Олена К.', 5, 'Чудові викладачі та сучасні лабораторії'
FROM   institutions
WHERE  NOT EXISTS (SELECT 1 FROM reviews WHERE author = 'Олена К.')
ORDER  BY id
LIMIT  1
RETURNING id, institution_id, author, score;

-- ---------- INSERT ... SELECT: масове створення демо-відгуків для перших 8 закладів ----------
INSERT INTO reviews (institution_id, author, score, comment)
SELECT i.id, 'Demo user', 3 + (i.id % 3), 'Автоматично створений демонстраційний відгук'
FROM   institutions i
WHERE  NOT EXISTS (SELECT 1 FROM reviews r WHERE r.institution_id = i.id AND r.author = 'Demo user')
ORDER  BY i.id
LIMIT  8;

-- ---------- INSERT з кількома рядками (VALUES) ----------
INSERT INTO reviews (institution_id, author, score, comment, status)
SELECT i.id, v.author, v.score, v.comment, v.status::review_status
FROM  (VALUES ('Максим Д.', 4, 'Непогана стипендія',  'approved'),
              ('Ігор П.',   3, NULL,                   'approved'),
              ('Anonymous', 1, 'спам-повідомлення',   'rejected')) AS v(author, score, comment, status)
CROSS JOIN LATERAL (SELECT id FROM institutions ORDER BY id LIMIT 1) i
WHERE NOT EXISTS (SELECT 1 FROM reviews r WHERE r.author = v.author);

-- ---------- UPDATE: проста умова + RETURNING ----------
UPDATE reviews
SET    comment = comment || ' (редаговано)'
WHERE  author = 'Максим Д.' AND comment NOT LIKE '%(редаговано)'
RETURNING id, author, comment;

-- ---------- UPDATE ... FROM: оновлення на основі іншої таблиці ----------
-- відгуки без тексту отримують коментар «Оцінка без коментаря» + назву міста
UPDATE reviews r
SET    comment = 'Оцінка без коментаря (' || COALESCE(c.name, '—') || ')'
FROM   institutions i
LEFT   JOIN cities c ON c.id = i.city_id
WHERE  i.id = r.institution_id AND r.comment IS NULL;

-- ---------- UPDATE з підзапитом: нормалізація «сміттєвих» значень парсера ----------
-- парсер записує str(NaN) = 'nan'; перетворюємо на справжній NULL
-- (на даних, завантажених ДО створення тригерів, оновить тисячі рядків; далі це робить тригер)
UPDATE institutions
SET    short_name = fn_clean_text(short_name),
       website    = fn_clean_text(website),
       address    = fn_clean_text(address)
WHERE  short_name IS DISTINCT FROM fn_clean_text(short_name)
   OR  website    IS DISTINCT FROM fn_clean_text(website)
   OR  address    IS DISTINCT FROM fn_clean_text(address);

-- ---------- UPSERT: INSERT ... ON CONFLICT DO UPDATE (в MySQL — ON DUPLICATE KEY UPDATE) ----------
INSERT INTO specialty_dict (code, name)
VALUES ('999', 'Демонстраційна спеціальність')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
RETURNING code, name;

-- ---------- INSERT ... ON CONFLICT DO NOTHING ----------
INSERT INTO regions (name) VALUES ('м. Київ') ON CONFLICT (name) DO NOTHING;

-- ---------- DELETE з умовою + RETURNING ----------
DELETE FROM reviews WHERE status = 'rejected' RETURNING id, author, status;

-- ---------- DELETE ... USING: видалення за даними іншої таблиці ----------
DELETE FROM specialty_dict s
USING  (SELECT s2.code FROM specialty_dict s2
        LEFT JOIN institution_specialties isp ON isp.specialty_code = s2.code
        WHERE isp.id IS NULL) AS unused
WHERE  s.code = unused.code AND s.code = '999'
RETURNING s.code;

-- ---------- Масове видалення «осиротілих» міст (довідник без закладів) ----------
-- (на практиці виконується обережно: спочатку SELECT, потім DELETE)
SELECT c.id, c.name, 'без закладів' AS note
FROM   cities c
WHERE  NOT EXISTS (SELECT 1 FROM institutions i WHERE i.city_id = c.id);

-- ---------- Результат ----------
SELECT count(*) AS reviews_total, round(avg(score), 2) AS avg_score FROM reviews;

-- Примітка: у PostgreSQL 15+ існує також оператор MERGE
--   MERGE INTO target t USING source s ON t.id = s.id
--   WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...
