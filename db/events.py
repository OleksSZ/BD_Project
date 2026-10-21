# -*- coding: utf-8 -*-
"""
Події СКБД (тема 14): аналог MySQL EVENT для PostgreSQL.

    python db/events.py listen              # слухач LISTEN/NOTIFY: друкує подію щойно додано відгук
    python db/events.py scheduler           # планувальник: виконує службові задачі за розкладом
    python db/events.py scheduler --once    # виконати всі задачі один раз (для демонстрації)

Для перевірки слухача в іншому терміналі додайте відгук:
  - через Swagger: http://localhost:8000/docs -> POST /api/institutions/{id}/reviews, або
  - у SQL (id реального закладу замість 4):  CALL sp_add_review(4, 'Live', 5, 'hello', NULL);
"""
import select
import sys
import time

from run_sql import connect

# (назва, інтервал у секундах, SQL)  — аналог CREATE EVENT ... ON SCHEDULE EVERY ...
TASKS = [
    ("refresh_region_stats", 30 * 60, "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_region_stats"),
    ("recalc_review_stats", 6 * 3600, "CALL sp_recalc_review_stats()"),
    ("cleanup_old_audit", 24 * 3600, "CALL sp_cleanup_old_audit(90)"),
    ("analyze", 24 * 3600, "ANALYZE"),
]


def listen():
    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("LISTEN review_added;")
    print("Слухаю канал review_added ... (Ctrl+C — вихід)")
    try:
        while True:
            if select.select([conn], [], [], 5) == ([], [], []):
                continue
            conn.poll()
            while conn.notifies:
                n = conn.notifies.pop(0)
                print(f"[ПОДІЯ] канал={n.channel} pid={n.pid} дані={n.payload}")
    except KeyboardInterrupt:
        print("\nЗавершено")


def scheduler(once=False):
    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()
    last = {name: 0.0 for name, _, _ in TASKS}
    print("Планувальник запущено" + (" (одноразово)" if once else " (Ctrl+C — вихід)"))
    try:
        while True:
            now = time.time()
            for name, interval, sql in TASKS:
                if once or now - last[name] >= interval:
                    try:
                        cur.execute(sql)
                        cur.execute("INSERT INTO maintenance_log(task, details) VALUES (%s, %s)",
                                    (name, "виконано планувальником Python"))
                        print(f"[{time.strftime('%H:%M:%S')}] OK  {name}")
                    except Exception as e:
                        print(f"[{time.strftime('%H:%M:%S')}] ERR {name}: {str(e).splitlines()[0]}")
                    last[name] = now
            if once:
                return
            time.sleep(10)
    except KeyboardInterrupt:
        print("\nЗавершено")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "listen":
        listen()
    elif cmd == "scheduler":
        scheduler(once="--once" in sys.argv)
    else:
        print(__doc__)
