# -*- coding: utf-8 -*-
"""
Запуск SQL-скриптів проєкту через Python (psycopg2) — psql встановлювати не потрібно.

Приклади:
    python db/run_sql.py                      # виконати ВСІ скрипти db/sql/*.sql по порядку
    python db/run_sql.py 05                   # лише скрипт, номер якого починається з 05
    python db/run_sql.py 04 05 08 -r 8        # кілька скриптів, показувати до 8 рядків результату
    python db/run_sql.py 13 --stop            # зупинитись на першій помилці
    python db/run_sql.py --quiet              # лише підсумок (для встановлення схеми)

Підключення береться з .env (DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD) —
той самий файл, що використовують парсери та web/app.py.
"""
import argparse
import glob
import os
import sys
import textwrap

import psycopg2
from dotenv import load_dotenv

HERE = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(HERE, "..", ".env"))
load_dotenv(os.path.join(HERE, "..", "web", ".env"))


def connect():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "osvita_ua"),
        user=os.getenv("DB_USER", "admin_user"),
        password=os.getenv("DB_PASSWORD", ""),
    )


# таблиці, які створюють наші скрипти, і стовпці, без яких вони не працюватимуть.
# Якщо в БД вже є таблиця з таким ім'ям, але іншою структурою, IF NOT EXISTS її мовчки пропустить — перевіряємо наперед.
EXPECTED = {
    "regions": ["id", "name"], "cities": ["id", "region_id", "name"],
    "institution_types": ["id", "name"], "ownership_forms": ["id", "name"],
    "specialty_dict": ["code", "name"],
    "reviews": ["id", "institution_id", "author", "score", "status"],
    "rating_history": ["id", "institution_id", "rating_total"],
    "audit_log": ["id", "table_name", "operation", "row_id", "old_data", "new_data"],
    "maintenance_log": ["id", "task", "details"], "ddl_log": ["id", "command_tag"],
}


def preflight(conn):
    """Повертає список критичних проблем (порожній = можна запускати)."""
    cur = conn.cursor()
    problems, warnings = [], []
    cur.execute("SELECT current_user, (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)")
    user, is_super = cur.fetchone()

    cur.execute("""SELECT tablename, tableowner, pg_has_role(current_user, tableowner, 'member')
                   FROM pg_tables WHERE schemaname = 'public'
                   AND tablename IN ('institutions', 'institution_specialties')""")
    for table, owner, ok in cur.fetchall():
        if not ok:
            problems.append(f"Таблиця {table} належить користувачу '{owner}', а ви підключені як '{user}'.")
    if problems:
        problems.append(
            "ЯК ВИПРАВИТИ (виконайте один раз, DB_USER із .env підставте замість " + user + "):\n"
            "    sudo -u postgres psql " + os.getenv("DB_NAME", "osvita_ua") + " -c "
            "\"ALTER TABLE institutions OWNER TO " + user + "; "
            "ALTER TABLE institution_specialties OWNER TO " + user + ";\"\n"
            "    або вкажіть у .env DB_USER власника таблиць.")

    for table, cols in EXPECTED.items():
        cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=%s",
                    (table,))
        have = {r[0] for r in cur.fetchall()}
        if have and not set(cols) <= have:
            problems.append(f"У БД вже є таблиця '{table}' з іншою структурою (немає стовпців: "
                            f"{', '.join(sorted(set(cols) - have))}). Перейменуйте її або змініть назву в скриптах.")

    cur.execute("SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user")
    if not is_super and not cur.fetchone()[0]:
        warnings.append("Немає права CREATEROLE — файл 11 (ролі) виведе помилки. Виправлення: "
                        f"sudo -u postgres psql -c \"ALTER ROLE {user} CREATEROLE;\"")
    if not is_super:
        warnings.append("Ви не суперкористувач — EVENT TRIGGER у файлі 12 буде пропущено (це нормально).")
    return problems, warnings


def split_sql(script: str):
    """Розбиває скрипт на оператори по ';' з урахуванням '...', "...", $$...$$ та коментарів."""
    stmts, buf = [], []
    i, n = 0, len(script)
    state = None          # None | "'" | '"' | "--" | "/*" | "$tag$"
    dollar_tag = ""
    while i < n:
        ch = script[i]
        two = script[i:i + 2]
        if state is None:
            if two == "--":
                state = "--"; buf.append(two); i += 2; continue
            if two == "/*":
                state = "/*"; buf.append(two); i += 2; continue
            if ch in ("'", '"'):
                state = ch; buf.append(ch); i += 1; continue
            if ch == "$":
                j = i + 1
                while j < n and (script[j].isalnum() or script[j] == "_"):
                    j += 1
                if j < n and script[j] == "$":
                    dollar_tag = script[i:j + 1]
                    state = "$tag$"; buf.append(dollar_tag); i = j + 1; continue
            if ch == ";":
                stmt = "".join(buf).strip()
                if stmt:
                    stmts.append(stmt)
                buf = []; i += 1; continue
            buf.append(ch); i += 1
        elif state == "--":
            buf.append(ch); i += 1
            if ch == "\n":
                state = None
        elif state == "/*":
            if two == "*/":
                buf.append(two); i += 2; state = None
            else:
                buf.append(ch); i += 1
        elif state in ("'", '"'):
            buf.append(ch); i += 1
            if ch == state:
                if script[i:i + 1] == state:      # екранована лапка ''
                    buf.append(state); i += 1
                else:
                    state = None
        elif state == "$tag$":
            if script.startswith(dollar_tag, i):
                buf.append(dollar_tag); i += len(dollar_tag); state = None
            else:
                buf.append(ch); i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    # оператори, що складаються лише з коментарів, пропускаємо
    result = []
    for s in stmts:
        body = "\n".join(l for l in s.splitlines() if not l.strip().startswith("--")).strip()
        if body:
            result.append(s)
    return result


def short(stmt: str, width=110):
    lines = [l for l in stmt.splitlines() if l.strip() and not l.strip().startswith("--")]
    return textwrap.shorten(" ".join(l.strip() for l in lines), width=width, placeholder=" ...")


def lead_comment(stmt: str):
    out = []
    for l in stmt.splitlines():
        s = l.strip()
        if s.startswith("--"):
            out.append(s.lstrip("- ").strip())
        elif s:
            break
    return " | ".join(x for x in out if x and not set(x) <= set("=-"))


def print_table(cols, rows, max_rows):
    shown = rows[:max_rows]
    cells = [[("NULL" if v is None else str(v)) for v in r] for r in shown]
    widths = [min(max([len(str(c))] + [len(r[i]) for r in cells]), 42) for i, c in enumerate(cols)]
    line = " | ".join(str(c).ljust(widths[i])[:widths[i]] for i, c in enumerate(cols))
    print("      " + line)
    print("      " + "-+-".join("-" * w for w in widths))
    for r in cells:
        print("      " + " | ".join(v.ljust(widths[i])[:widths[i]] for i, v in enumerate(r)))
    if len(rows) > max_rows:
        print(f"      ... ще {len(rows) - max_rows} рядків")


def run_file(conn, path, max_rows, quiet, stop):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        statements = split_sql(f.read())
    print(f"\n{'=' * 78}\n>>> {name}   ({len(statements)} операторів)\n{'=' * 78}")
    errors = 0
    notices = []
    conn.notices.clear()
    cur = conn.cursor()
    for idx, stmt in enumerate(statements, 1):
        title = lead_comment(stmt)
        if not quiet:
            print(f"\n[{idx}] {title}" if title else f"\n[{idx}]")
            print(f"    SQL> {short(stmt)}")
        try:
            cur.execute(stmt)
            if cur.description:
                cols = [d[0] for d in cur.description]
                rows = cur.fetchall()
                if not quiet:
                    print_table(cols, rows, max_rows)
            elif not quiet:
                print(f"    OK  {cur.statusmessage}")
        except Exception as e:                      # демо-скрипти містять навмисні помилки
            errors += 1
            msg = str(e).strip().splitlines()[0]
            print(f"    !!  {msg}")
            if stop:
                print("Зупинено (--stop).")
                sys.exit(1)
        if conn.notices:
            for nt in conn.notices:
                nt = nt.strip()
                if not quiet:
                    print(f"    NOTICE: {nt}")
                notices.append(nt)
            conn.notices.clear()
    print(f"\n--- {name}: готово, помилок/попереджень: {errors}")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="номери або імена скриптів (напр. 05 або 05_dql_queries)")
    ap.add_argument("-r", "--rows", type=int, default=6, help="скільки рядків результату показувати")
    ap.add_argument("--quiet", action="store_true", help="не показувати кожен оператор")
    ap.add_argument("--stop", action="store_true", help="зупинитись на першій помилці")
    ap.add_argument("--skip-checks", action="store_true", help="не виконувати перевірку перед запуском")
    args = ap.parse_args()

    all_files = sorted(glob.glob(os.path.join(HERE, "sql", "*.sql")))
    if args.files:
        files = [f for f in all_files if any(os.path.basename(f).startswith(a) or a in os.path.basename(f)
                                              for a in args.files)]
    else:
        files = [f for f in all_files if not os.path.basename(f).startswith("99_")]
    if not files:
        print("Скриптів не знайдено"); sys.exit(1)

    conn = connect()
    conn.autocommit = True          # щоб працювали явні BEGIN/COMMIT/ROLLBACK, VACUUM, CALL з COMMIT
    if not args.skip_checks:
        problems, warnings = preflight(conn)
        for w in warnings:
            print("УВАГА:", w)
        if problems:
            print("\nЗАПУСК ЗУПИНЕНО — у БД нічого не змінено:")
            for pr in problems:
                print(" *", pr)
            sys.exit(2)
    total_err = 0
    try:
        for f in files:
            total_err += run_file(conn, f, args.rows, args.quiet, args.stop)
    finally:
        conn.close()
    print(f"\nЗавершено. Скриптів: {len(files)}, помилок/попереджень: {total_err}")


if __name__ == "__main__":
    main()
