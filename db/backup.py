# -*- coding: utf-8 -*-
"""
Резервне копіювання та відновлення (тема 14, адміністрування).

    python db/backup.py dump                 # створити backups/<db>_<дата>.dump (формат custom)
    python db/backup.py restore FILE NEWDB   # відновити у нову БД (її треба створити: createdb NEWDB)

Потрібні утиліти pg_dump / pg_restore (встановлюються разом із PostgreSQL client).
"""
import os
import subprocess
import sys
import time

from run_sql import HERE  # також завантажує .env

env = os.environ.copy()
env["PGPASSWORD"] = os.getenv("DB_PASSWORD", "")
conn = ["-h", os.getenv("DB_HOST", "localhost"), "-p", os.getenv("DB_PORT", "5432"), "-U", os.getenv("DB_USER", "")]
db = os.getenv("DB_NAME", "osvita_ua")

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "dump":
    out_dir = os.path.join(HERE, "..", "backups")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{db}_{time.strftime('%Y%m%d_%H%M%S')}.dump")
    subprocess.run(["pg_dump", *conn, "-Fc", "-f", path, db], env=env, check=True)
    print("Резервну копію створено:", path)
elif cmd == "restore" and len(sys.argv) == 4:
    subprocess.run(["pg_restore", *conn, "-d", sys.argv[3], sys.argv[2]], env=env, check=True)
    print("Відновлено у БД", sys.argv[3])
else:
    print(__doc__)
