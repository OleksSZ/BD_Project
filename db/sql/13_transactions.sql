-- =====================================================================
-- 13. МОДУЛЬ 5 (тема 15): команди управління транзакціями
-- BEGIN / COMMIT / ROLLBACK / SAVEPOINT, рівні ізоляції, блокування, ACID.
-- Паралельні сценарії (дві сесії) — у db/demo_transactions.py.
-- Усі демонстрації нижче використовують reviews і НЕ змінюють реальні дані остаточно.
-- (У MySQL: START TRANSACTION, SET autocommit=0, SET TRANSACTION ISOLATION LEVEL.)
-- =====================================================================

-- ---------- 1. ROLLBACK: скасування всіх змін транзакції ----------
BEGIN;
INSERT INTO reviews (institution_id, author, score, comment)
SELECT id, 'Транзакція-1', 5, 'Буде скасовано' FROM institutions ORDER BY id LIMIT 1
RETURNING id, author;
SELECT count(*) AS inside_transaction FROM reviews WHERE author = 'Транзакція-1';
ROLLBACK;
SELECT count(*) AS after_rollback FROM reviews WHERE author = 'Транзакція-1';        -- 0

-- ---------- 2. COMMIT: фіксація змін ----------
BEGIN;
INSERT INTO reviews (institution_id, author, score, comment)
SELECT id, 'Транзакція-2', 4, 'Буде збережено' FROM institutions ORDER BY id LIMIT 1;
COMMIT;
SELECT count(*) AS after_commit FROM reviews WHERE author = 'Транзакція-2';           -- 1

-- ---------- 3. SAVEPOINT: часткове скасування ----------
BEGIN;
UPDATE reviews SET score = 1 WHERE author = 'Транзакція-2';
SAVEPOINT after_first_update;
UPDATE reviews SET score = 2 WHERE author = 'Транзакція-2';
SELECT score AS score_before_rollback_to FROM reviews WHERE author = 'Транзакція-2';  -- 2
ROLLBACK TO SAVEPOINT after_first_update;                                             -- скасовуємо лише 2-ге оновлення
SELECT score AS score_after_rollback_to  FROM reviews WHERE author = 'Транзакція-2';  -- 1
RELEASE SAVEPOINT after_first_update;
ROLLBACK;                                                                             -- скасовуємо і перше
SELECT score AS score_final FROM reviews WHERE author = 'Транзакція-2';               -- 4 (початкове)

-- ---------- 4. Атомарність: «усе або нічого» ----------
-- Імпорт рейтингів з одним неіснуючим кодом: процедура кидає виняток, ЖОДЕН заклад не оновлюється
DO $$
DECLARE
    v_cnt   INTEGER;
    v_first INTEGER := (SELECT edbo_code FROM institutions ORDER BY id LIMIT 1);
BEGIN
    CALL sp_import_ratings(jsonb_build_array(
            jsonb_build_object('edbo_code', v_first, 'total', 777, 'city_position', 1, 'general_position', '1'),
            jsonb_build_object('edbo_code', -1,      'total', 888)), v_cnt);
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'Імпорт скасовано повністю: %', SQLERRM;
END $$;

SELECT edbo_code, rating_total FROM institutions ORDER BY id LIMIT 1;                 -- значення не стало 777

-- ---------- 5. Рівні ізоляції ----------
-- READ COMMITTED (типовий у PostgreSQL), REPEATABLE READ, SERIALIZABLE
-- (READ UNCOMMITTED у PostgreSQL працює як READ COMMITTED: «брудне читання» неможливе)
BEGIN ISOLATION LEVEL REPEATABLE READ;
SHOW transaction_isolation;
SELECT count(*) AS reviews_snapshot FROM reviews;      -- знімок даних на момент першого запиту
COMMIT;

BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY;
SHOW transaction_isolation;
COMMIT;

SELECT current_setting('default_transaction_isolation') AS default_level;

-- ---------- 6. Блокування рядків: SELECT ... FOR UPDATE / SKIP LOCKED / NOWAIT ----------
BEGIN;
SELECT id, short_name FROM institutions WHERE id = (SELECT min(id) FROM institutions) FOR UPDATE;   -- рядок заблоковано до COMMIT
SELECT locktype, mode, granted FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'transactionid';
COMMIT;

-- Черга задач: кожен воркер бере вільний рядок і пропускає заблоковані
SELECT id FROM reviews WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;

-- ---------- 7. Таймаут блокування (захист від «зависання») ----------
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '10s';
SHOW lock_timeout;
COMMIT;

-- ---------- 8. Явне блокування таблиці ----------
BEGIN;
LOCK TABLE reviews IN SHARE ROW EXCLUSIVE MODE;        -- заборонити паралельні зміни reviews до COMMIT
SELECT mode FROM pg_locks WHERE relation = 'reviews'::regclass AND pid = pg_backend_pid();
COMMIT;

-- ---------- 9. Транзакції в процедурі ----------
-- sp_cleanup_old_audit виконує COMMIT усередині (файл 09) — викликається поза BEGIN...COMMIT
CALL sp_cleanup_old_audit(3650);

-- Прибираємо демо-дані
DELETE FROM reviews WHERE author IN ('Транзакція-1', 'Транзакція-2');
