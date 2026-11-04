# -*- coding: utf-8 -*-
"""
Демонстрація лабораторних робіт: кожна ЛР — окремий скрипт db/labs/labNN_*.sql.

Приклади:
    python db/lab.py list            # перелік лабораторних і їх тем
    python db/lab.py 9               # показати ЛР №9 (повний текст кожного запиту + результат)
    python db/lab.py 9 -r 20         # показувати до 20 рядків результату
    python db/lab.py 7 8             # кілька лабораторних поспіль
    python db/lab.py all             # усі лабораторні (перевірка перед захистом)
    python db/lab.py 14 --brief      # коротко: лише заголовки і результати, без тексту SQL

Перед першим запуском має бути встановлена схема:  python db/run_sql.py --quiet
Підключення — з того самого .env, що й у run_sql.py / web/app.py.

Скрипти не змінюють робочі дані: усе, що змінює БД, виконується всередині
BEGIN ... ROLLBACK або у тимчасових (TEMP) таблицях. Навмисні помилки
(порушення обмежень тощо) позначені в скриптах коментарем «очікувана помилка».
"""
import argparse
import glob
import os
import re
import sys

import psycopg2.extensions as ext

from run_sql import connect, print_table, split_sql

HERE = os.path.dirname(os.path.abspath(__file__))
LABS = os.path.join(HERE, "labs")
EXPECTED_ERROR = "очікувана помилка"


def lab_files():
    """{номер ЛР: шлях} для файлів labNN_*.sql."""
    found = {}
    for path in sorted(glob.glob(os.path.join(LABS, "lab*.sql"))):
        m = re.match(r"lab(\d+)_", os.path.basename(path))
        if m:
            found[int(m.group(1))] = path
    return found


def lab_title(path):
    """Перший рядок шапки «-- ЛР №N. Тема»."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("-- ЛР"):
                return line[2:].strip()
    return os.path.basename(path)


def parse_statement(stmt):
    """Розділяє оператор на розділи (-- == ... ==), заголовок (інші коментарі) і сам SQL."""
    sections, title, body = [], [], []
    for line in stmt.splitlines():
        s = line.strip()
        if not body and s.startswith("--"):
            text = s[2:].strip()
            if text and set(text) <= set("=-"):
                title = []              # рядок-роздільник закриває шапку файлу
            elif text.startswith("=="):
                sections.append(text.strip("= "))
            elif text:
                title.append(text)
        elif s or body:
            body.append(line.rstrip())
    return sections, " ".join(title), "\n".join(body).strip()


def run_lab(conn, path, max_rows, brief):
    with open(path, encoding="utf-8") as f:
        statements = split_sql(f.read())
    print(f"\n{'#' * 78}\n# {lab_title(path)}\n# файл: db/labs/{os.path.basename(path)}\n{'#' * 78}")
    cur = conn.cursor()
    unexpected = 0
    for idx, stmt in enumerate(statements, 1):
        sections, title, sql = parse_statement(stmt)
        for sec in sections:
            print(f"\n{'=' * 78}\n  {sec}\n{'=' * 78}")
        expect_error = EXPECTED_ERROR in title.lower()
        print(f"\n[{idx}] {title}" if title else f"\n[{idx}]")
        if not brief:
            for line in sql.splitlines():
                print(f"    {line}")
        conn.notices.clear()
        try:
            cur.execute(stmt)
            if cur.description:
                print_table([d[0] for d in cur.description], cur.fetchall(), max_rows, max_width=90)
            else:
                print(f"    -> {cur.statusmessage}")
            if expect_error:
                print("    (помилку очікували, але оператор виконався)")
        except Exception as e:
            msg = str(e).strip().splitlines()[0]
            if expect_error:
                print(f"    -> ОЧІКУВАНА ПОМИЛКА: {msg}")
            else:
                unexpected += 1
                print(f"    !! ПОМИЛКА: {msg}")
        for nt in conn.notices:
            print(f"    {nt.strip()}")
    # страховка: якщо скрипт залишив відкриту транзакцію — відкочуємо її
    if conn.info.transaction_status != ext.TRANSACTION_STATUS_IDLE:
        conn.rollback()
        print("\n(відкриту транзакцію відкочено)")
    print(f"\n--- {os.path.basename(path)}: операторів {len(statements)}, неочікуваних помилок: {unexpected}")
    return unexpected


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("labs", nargs="+", help="номери ЛР (напр. 9 або 7 8), 'list' або 'all'")
    ap.add_argument("-r", "--rows", type=int, default=8, help="скільки рядків результату показувати")
    ap.add_argument("--brief", action="store_true", help="не друкувати текст SQL, лише заголовки і результати")
    args = ap.parse_args()

    labs = lab_files()
    if args.labs == ["list"]:
        for num, path in labs.items():
            print(f"  {num:>2}  {lab_title(path)}")
        print("\nЛР №3 (специфікації обмежень) — документальна, окремого скрипта не має.")
        return

    if args.labs == ["all"]:
        chosen = list(labs.values())
    else:
        chosen = []
        for a in args.labs:
            if not a.isdigit() or int(a) not in labs:
                print(f"Немає скрипта для ЛР '{a}'. Доступні: {', '.join(map(str, labs))}")
                sys.exit(1)
            chosen.append(labs[int(a)])

    conn = connect()
    conn.autocommit = True          # явні BEGIN / ROLLBACK у скриптах керують транзакціями самі
    cur = conn.cursor()
    cur.execute("SELECT to_regclass('public.v_institutions_full') IS NOT NULL")
    if not cur.fetchone()[0]:
        print("Схему проєкту не встановлено. Спочатку виконайте:  python db/run_sql.py --quiet")
        sys.exit(2)
    total = 0
    try:
        for path in chosen:
            total += run_lab(conn, path, args.rows, args.brief)
    finally:
        conn.close()
    print(f"\nЗавершено. Лабораторних: {len(chosen)}, неочікуваних помилок: {total}")


if __name__ == "__main__":
    main()
