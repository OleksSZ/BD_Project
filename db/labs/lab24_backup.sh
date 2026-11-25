#!/usr/bin/env bash
# ЛР №24. Резервування структури бази даних і її даних
# =====================================================================
# Методичка використовує mysqldump і MySQL Workbench. У PostgreSQL аналогами є утиліти
# pg_dump (одна БД), pg_dumpall (усі БД і ролі сервера), pg_restore (відновлення з архівного
# формату) та psql (виконання SQL-дампу, експорт у CSV через \copy).
# Копії зберігаються в backups/lab24/ (каталог не потрапляє в git). Відновлення виконується
# в окрему тимчасову БД <назва>_lab24_restore, яку скрипт наприкінці видаляє, — робоча БД
# не змінюється. Потрібні утиліти PostgreSQL client і право CREATEDB; для пунктів 1 і 7
# (pg_dumpall) — права суперкористувача.
# Запуск: python db/lab.py 24   (або bash db/labs/lab24_backup.sh)
# =====================================================================

# Підключення: lab.py передає параметри з .env; змінні PG* розуміють усі утиліти PostgreSQL
export PGHOST="${DB_HOST:-localhost}" PGPORT="${DB_PORT:-5432}" PGUSER="${DB_USER:-$USER}" PGPASSWORD="${DB_PASSWORD:-}"
DB="${DB_NAME:-osvita_ua}"
RESTORE_DB="${DB}_lab24_restore"
OUT="${LAB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/backups/lab24"
mkdir -p "$OUT"
cd "$OUT"

# == 1. Резервування всіх баз даних ==
# pg_dumpall записує в один SQL-файл усі бази сервера разом із ролями
# (аналог mysqldump --all-databases); --no-role-passwords — без хешів паролів
pg_dumpall --no-role-passwords -f all_databases.sql
ls -lh all_databases.sql | awk '{print $5, $9}'
grep -c '^CREATE DATABASE' all_databases.sql | sed 's/^/баз даних у файлі: /'

# == 2. Резервування однієї бази даних ==
# звичайний SQL-дамп (текстовий файл з командами CREATE і COPY; аналог mysqldump osvita_ua > file.sql)
pg_dump -d "$DB" -f "$DB.sql"
ls -lh "$DB.sql" | awk '{print $5, $9}'

# архівний формат custom (-Fc): стиснутий, з нього pg_restore може відновлювати вибірково.
# Саме цей формат використовує утиліта проєкту: python db/backup.py dump
pg_dump -d "$DB" -Fc -f "$DB.dump"
ls -lh "$DB.dump" | awk '{print $5, $9}'

# == 3. Резервування окремих таблиць ==
# -t вибирає таблиці (тут — довідники областей і міст)
pg_dump -d "$DB" -t regions -t cities -f some_tables.sql
grep -E '^(CREATE TABLE|COPY)' some_tables.sql

# == 4. Резервування з архівуванням ==
# вивід pg_dump одразу стискається gzip (аналог mysqldump … | gzip > file.sql.gz)
pg_dump -d "$DB" | gzip > "$DB.sql.gz"
ls -lh "$DB.sql" "$DB.sql.gz" | awk '{print $5, $9}'
gzip -t "$DB.sql.gz" && echo "архів цілий"

# == 5. Резервування лише структури ==
# --schema-only: таблиці, представлення, функції, тригери, індекси — без рядків даних (mysqldump --no-data)
pg_dump -d "$DB" --schema-only -f schema_only.sql
echo "CREATE TABLE: $(grep -c '^CREATE TABLE' schema_only.sql), CREATE FUNCTION: $(grep -c '^CREATE FUNCTION' schema_only.sql), CREATE TRIGGER: $(grep -c '^CREATE TRIGGER' schema_only.sql), COPY (дані): $(grep -c '^COPY' schema_only.sql)"

# == 6. Резервування лише даних ==
# --data-only: лише команди COPY з рядками таблиць (mysqldump --no-create-info)
pg_dump -d "$DB" --data-only -f data_only.sql
echo "COPY (дані): $(grep -c '^COPY' data_only.sql), CREATE TABLE: $(grep -c '^CREATE TABLE' data_only.sql)"

# == 7. Резервування прав доступу ==
# ролі (користувачі) сервера та членство в групах (аналог дампу таблиць mysql.user / mysql.db)
pg_dumpall --roles-only --no-role-passwords -f roles.sql
grep -E '^(CREATE ROLE|GRANT)' roles.sql | grep -E 'role_|app_' | head -8

# права на таблиці (GRANT / REVOKE) зберігаються в дампі самої БД
grep -c '^GRANT' "$DB.sql" | sed 's/^/команд GRANT у дампі БД: /'

# == 8. Відновлення дампу БД ==
# створюємо порожню БД і відновлюємо в неї повну копію з архівного файлу
dropdb --if-exists "$RESTORE_DB" 2> /dev/null
createdb "$RESTORE_DB"
pg_restore -d "$RESTORE_DB" "$DB.dump"
psql -d "$RESTORE_DB" -At -c "SELECT 'закладів: ' || count(*) FROM institutions UNION ALL SELECT 'програм: ' || count(*) FROM institution_specialties UNION ALL SELECT 'відгуків: ' || count(*) FROM reviews"

# SQL-дамп відновлюється не pg_restore, а виконанням файлу в psql (аналог mysql osvita_ua < file.sql)
dropdb "$RESTORE_DB" && createdb "$RESTORE_DB"
psql -q -d "$RESTORE_DB" -f some_tables.sql > /dev/null
psql -d "$RESTORE_DB" -At -c "SELECT 'областей: ' || count(*) FROM regions UNION ALL SELECT 'міст: ' || count(*) FROM cities"

# == 9. Відновлення окремих таблиць ==
# з архівного дампу -t бере лише вказані таблиці (структуру і дані)
dropdb "$RESTORE_DB" && createdb "$RESTORE_DB"
pg_restore -d "$RESTORE_DB" -t regions -t specialty_dict "$DB.dump"
psql -d "$RESTORE_DB" -At -c "SELECT relname || ': ' || n_live_tup FROM pg_stat_user_tables ORDER BY relname"

# == 10. Відновлення структури ==
# --schema-only: створюються всі об'єкти, таблиці залишаються порожніми
dropdb "$RESTORE_DB" && createdb "$RESTORE_DB"
pg_restore -d "$RESTORE_DB" --schema-only "$DB.dump"
psql -d "$RESTORE_DB" -At -c "SELECT 'таблиць: ' || count(*) FROM pg_tables WHERE schemaname = 'public' UNION ALL SELECT 'закладів: ' || count(*) FROM institutions"

# == 11. Відновлення лише даних ==
# --data-only заповнює вже створену структуру. Тут — довідники, на яких немає тригерів;
# для всієї БД додають --disable-triggers (потрібен суперкористувач), щоб тригери не дублювали журнали.
# Через зовнішні ключі порядок важливий: спершу батьківські таблиці…
pg_restore -d "$RESTORE_DB" --data-only -t regions -t institution_types -t ownership_forms -t specialty_dict "$DB.dump"

# …потім дочірня (cities посилається на regions); у зворотному порядку COPY порушив би FOREIGN KEY
pg_restore -d "$RESTORE_DB" --data-only -t cities "$DB.dump"
psql -d "$RESTORE_DB" -At -c "SELECT relname || ': ' || n_live_tup FROM pg_stat_user_tables WHERE n_live_tup > 0 ORDER BY relname"

# == 12. Експорт і імпорт даних у CSV ==
# \copy виконує COPY на боці клієнта: таблиця або результат запиту -> CSV-файл (аналог SELECT … INTO OUTFILE)
psql -d "$DB" -c "\copy (SELECT id, short_name, city, rating_total FROM institutions ORDER BY id) TO 'institutions.csv' WITH (FORMAT csv, HEADER)"
head -4 institutions.csv

# і назад: CSV -> таблиця (аналог LOAD DATA INFILE)
psql -d "$RESTORE_DB" -c "CREATE TABLE inst_csv (id int, short_name text, city text, rating_total int)" -c "\copy inst_csv FROM 'institutions.csv' WITH (FORMAT csv, HEADER)" -At -c "SELECT 'імпортовано рядків: ' || count(*) FROM inst_csv"

# == 13. Прибирання ==
# тимчасова БД для перевірки відновлення більше не потрібна; файли копій залишаються в backups/lab24/
dropdb "$RESTORE_DB"
ls -lh | awk 'NR > 1 {print $5, $9}'
