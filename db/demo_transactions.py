# -*- coding: utf-8 -*-
"""
Паралельні транзакції (тема 15): дві сесії одночасно.
    python db/demo_transactions.py
Сценарії: 1) COMMIT/ROLLBACK із SQLAlchemy; 2) non-repeatable read: READ COMMITTED vs REPEATABLE READ;
          3) блокування рядка (FOR UPDATE + lock_timeout); 4) deadlock (взаємне блокування).
Працює з таблицею reviews, після себе прибирає.
"""
import os
import threading
import time

import psycopg2
from sqlalchemy import create_engine, text

from run_sql import connect

url = (f"postgresql+psycopg2://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}@{os.getenv('DB_HOST')}:"
       f"{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}")
engine = create_engine(url)


def title(t):
    print(f"\n{'=' * 70}\n{t}\n{'=' * 70}")


def first_institution():
    with engine.connect() as c:
        return c.execute(text("SELECT min(id) FROM institutions")).scalar()


def reviews_count(author):
    with engine.connect() as c:
        return c.execute(text("SELECT count(*) FROM reviews WHERE author=:a"), {"a": author}).scalar()


def scenario1(inst):
    title("1. Атомарність: помилка всередині with engine.begin() скасовує ВСЕ")
    try:
        with engine.begin() as c:
            c.execute(text("INSERT INTO reviews(institution_id, author, score) VALUES (:i,'TX-demo',5)"), {"i": inst})
            print("   вставили відгук, всередині транзакції:", c.execute(
                text("SELECT count(*) FROM reviews WHERE author='TX-demo'")).scalar())
            c.execute(text("INSERT INTO reviews(institution_id, author, score) VALUES (:i,'TX-demo2',99)"),
                      {"i": inst})                                  # порушує CHECK (score 1..5)
    except Exception as e:
        print("   ПОМИЛКА:", str(e.orig).splitlines()[0])
    print("   після помилки відгуків 'TX-demo':", reviews_count("TX-demo"), "(0 = відкат спрацював)")


def scenario2(inst, level):
    a, b = connect(), connect()
    a.set_session(isolation_level=level)
    ca, cb = a.cursor(), b.cursor()
    ca.execute("INSERT INTO reviews(institution_id, author, score) VALUES (%s,'TX-iso',3)", (inst,))
    a.commit()
    ca.execute("SELECT score FROM reviews WHERE author='TX-iso'")
    first = ca.fetchone()[0]
    cb.execute("UPDATE reviews SET score=5 WHERE author='TX-iso'")
    b.commit()
    ca.execute("SELECT score FROM reviews WHERE author='TX-iso'")
    second = ca.fetchone()[0]
    a.commit()
    cb.execute("DELETE FROM reviews WHERE author='TX-iso'")
    b.commit()
    a.close(); b.close()
    print(f"   {level:16}: сесія A прочитала {first}, потім (після COMMIT сесії B) {second}  ->",
          "non-repeatable read" if first != second else "читання повторюване")


def scenario3(inst):
    title("3. Блокування рядка: сесія B чекає, поки A зробить COMMIT (lock_timeout=1s)")
    with engine.begin() as c:
        c.execute(text("INSERT INTO reviews(institution_id, author, score) VALUES (:i,'TX-lock',4)"), {"i": inst})
    a, b = connect(), connect()
    ca, cb = a.cursor(), b.cursor()
    ca.execute("SELECT id FROM reviews WHERE author='TX-lock' FOR UPDATE")
    print("   A: заблокував рядок (FOR UPDATE)")
    cb.execute("SET lock_timeout = '1s'")
    t = time.time()
    try:
        cb.execute("UPDATE reviews SET score=1 WHERE author='TX-lock'")
    except psycopg2.errors.LockNotAvailable:
        print(f"   B: чекав {time.time() - t:.1f} c і отримав lock_not_available (рядок заблоковано сесією A)")
        b.rollback()
    a.commit()
    cb.execute("UPDATE reviews SET score=1 WHERE author='TX-lock'")
    b.commit()
    print("   B: після COMMIT сесії A оновлення пройшло")
    cb.execute("DELETE FROM reviews WHERE author='TX-lock'")
    b.commit(); a.close(); b.close()


def scenario4(inst, inst2):
    title("4. Deadlock: дві транзакції блокують рядки у зворотному порядку")
    # відгуки про РІЗНІ заклади: тригер агрегатів оновлює рядок закладу, і спільний заклад дав би зайве блокування
    with engine.begin() as c:
        for n, i in (("TX-d1", inst), ("TX-d2", inst2)):
            c.execute(text("INSERT INTO reviews(institution_id, author, score) VALUES (:i,:a,3)"), {"i": i, "a": n})
    a, b = connect(), connect()
    ca, cb = a.cursor(), b.cursor()
    ca.execute("UPDATE reviews SET score=4 WHERE author='TX-d1'")
    cb.execute("UPDATE reviews SET score=4 WHERE author='TX-d2'")
    result = {}

    def run_a():
        try:
            ca.execute("UPDATE reviews SET score=5 WHERE author='TX-d2'")   # чекає B
            a.commit(); result["A"] = "COMMIT"
        except psycopg2.errors.DeadlockDetected:
            a.rollback(); result["A"] = "ЖЕРТВА deadlock (ROLLBACK)"

    th = threading.Thread(target=run_a); th.start(); time.sleep(0.5)
    try:
        cb.execute("UPDATE reviews SET score=5 WHERE author='TX-d1'")        # замикає цикл
        b.commit(); result["B"] = "COMMIT"
    except psycopg2.errors.DeadlockDetected:
        b.rollback(); result["B"] = "ЖЕРТВА deadlock (ROLLBACK)"
    th.join()
    print("   результат:", result, "— СКБД сама обирає жертву й розриває цикл")
    a.close(); b.close()
    with engine.begin() as c:
        c.execute(text("DELETE FROM reviews WHERE author IN ('TX-d1','TX-d2')"))


if __name__ == "__main__":
    inst = first_institution()
    if inst is None:
        raise SystemExit("У БД немає закладів: завантажте дані або db/sql/99_sample_data.sql")
    scenario1(inst)
    title("2. Рівні ізоляції: чи бачить A зміни, зафіксовані B, усередині своєї транзакції?")
    scenario2(inst, "READ COMMITTED")
    scenario2(inst, "REPEATABLE READ")
    scenario3(inst)
    with engine.connect() as c:
        inst2 = c.execute(text("SELECT id FROM institutions ORDER BY id OFFSET 1 LIMIT 1")).scalar()
    scenario4(inst, inst2)
    print("\nГотово.")
