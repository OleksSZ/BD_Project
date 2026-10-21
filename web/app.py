from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import create_engine, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import sessionmaker
import os
from dotenv import load_dotenv
from typing import Optional
from pydantic import BaseModel, Field

load_dotenv()

app = FastAPI(
    title="Освітній простір України API",
    description="REST API поверх PostgreSQL: представлення, функції, процедури, тригери (див. db/sql)",
)

#  CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5500", "http://127.0.0.1:5500"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

#  ПОДКЛЮЧЕНИЕ К БД
DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'osvita_ua')
DB_USER = os.getenv('DB_USER', 'admin_user')
DB_PASSWORD = os.getenv('DB_PASSWORD', '')

try:
    DB_PORT = int(DB_PORT)
except (ValueError, TypeError):
    DB_PORT = 5432

db_url = f"postgresql+psycopg2://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
engine = create_engine(db_url, echo=False)
SessionLocal = sessionmaker(bind=engine)


#  ОБРОБКА ПОМИЛОК БД
#  Процедури/функції в БД кидають RAISE EXCEPTION ... USING ERRCODE = ...,
#  а API перетворює SQLSTATE на HTTP-статус.
SQLSTATE_TO_HTTP = {
    "P0002": 404,   # no_data_found          — об'єкт не знайдено
    "22023": 400,   # invalid_parameter_value — некоректний параметр
    "23514": 400,   # check_violation         — порушено CHECK
    "23505": 409,   # unique_violation        — дублікат (напр. другий відгук від автора)
    "23503": 400,   # foreign_key_violation
}


def raise_http(e: DBAPIError):
    orig = getattr(e, "orig", None)
    code = getattr(orig, "pgcode", None)
    msg = getattr(getattr(orig, "diag", None), "message_primary", None) or str(orig)
    raise HTTPException(status_code=SQLSTATE_TO_HTTP.get(code, 500), detail=msg)


#  МОДЕЛИ
class ReviewIn(BaseModel):
    author: str = Field(..., min_length=2, max_length=100)
    score: int = Field(..., ge=1, le=5)
    comment: Optional[str] = Field(None, max_length=2000)


class RatingIn(BaseModel):
    total: int
    city_position: Optional[int] = None
    general_position: Optional[str] = None
    nmt_score: Optional[int] = None
    top200: Optional[int] = None
    scopus: Optional[int] = None


class ModerationIn(BaseModel):
    status: str = Field(..., pattern="^(pending|approved|rejected)$")


#  РУЧКИ: ЗАКЛАДИ

@app.get("/api/institutions")
async def get_institutions(
    search: Optional[str] = Query(None),
    city: Optional[str] = Query(None),
    region: Optional[str] = Query(None),
    type: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0)
):
    """Список закладів. Пошук виконує SQL-функція fn_search_institutions (файл 09)."""
    session = SessionLocal()
    try:
        rows = session.execute(
            text("SELECT * FROM fn_search_institutions(:s, :c, :r, :t, :l, :o)"),
            {"s": search, "c": city, "r": region, "t": type, "l": limit, "o": offset},
        ).mappings().all()
        total = rows[0]["total_count"] if rows else 0
        if not rows and offset > 0:  # сторінка за межами результатів — рахуємо загальну кількість окремо
            total = session.execute(
                text("SELECT count(*) FROM fn_search_institutions(:s, :c, :r, :t, 200, 0)"),
                {"s": search, "c": city, "r": region, "t": type}).scalar()
        items = [{k: v for k, v in dict(r).items() if k != "total_count"} for r in rows]
        return JSONResponse({"items": items, "total": total, "limit": limit, "offset": offset})
    except DBAPIError as e:
        raise_http(e)
    finally:
        session.close()


@app.get("/api/institutions/{institution_id}")
async def get_institution_detail(institution_id: int):
    """Детальна інформація про заклад."""
    session = SessionLocal()
    try:
        query = text("""
            SELECT
                id, edbo_code, name, short_name, type, ownership,
                region, city, address, website, founded_year,
                rating, rating_total, rating_city_position,
                rating_general_position, rating_nmt_score,
                rating_top200, rating_scopus,
                avg_review_score, reviews_count,
                fn_rating_label(rating_total) AS rating_label,
                CASE
                    WHEN coordinates IS NOT NULL
                    THEN CONCAT('POINT(', coordinates[0], ' ', coordinates[1], ')')
                    ELSE NULL
                END as coordinates
            FROM institutions
            WHERE id = :id
        """)
        result = session.execute(query, {'id': institution_id}).first()
        if not result:
            raise HTTPException(status_code=404, detail="Заведение не найдено")
        return dict(result._mapping)
    finally:
        session.close()


@app.get("/api/institutions/{institution_id}/card")
async def get_institution_card(institution_id: int):
    """Картка закладу у JSON — повністю формується SQL-функцією fn_institution_card."""
    session = SessionLocal()
    try:
        return session.execute(text("SELECT fn_institution_card(:id)"), {"id": institution_id}).scalar()
    except DBAPIError as e:
        raise_http(e)
    finally:
        session.close()


@app.get("/api/institutions/{institution_id}/specialties")
async def get_institution_specialties(institution_id: int):
    """Спеціальності закладу (з статусом акредитації — функція fn_accreditation_status)."""
    session = SessionLocal()
    try:
        query = text("""
            SELECT
                specialty_name,
                specialty_code,
                education_level,
                program_name,
                students_count,
                accreditation_number,
                fn_accreditation_status(accreditation_valid_until::text) AS accreditation_status
            FROM institution_specialties
            WHERE institution_id = :institution_id
            ORDER BY education_level, specialty_name
        """)
        result = session.execute(query, {'institution_id': institution_id})
        return [dict(row._mapping) for row in result]
    finally:
        session.close()


@app.get("/api/filters")
async def get_filters():
    """Доступні фільтри — тепер беруться з довідників (3НФ), а не з DISTINCT по всій таблиці."""
    session = SessionLocal()
    try:
        cities = session.execute(text("SELECT name FROM cities WHERE name <> 'Не вказано' ORDER BY name")).fetchall()
        regions = session.execute(text("SELECT name FROM regions WHERE name <> 'Не вказано' ORDER BY name")).fetchall()
        types = session.execute(text("SELECT name FROM institution_types WHERE name <> 'Не вказано' ORDER BY name")).fetchall()
        return {
            "cities": sorted({c[0] for c in cities}),
            "regions": [r[0] for r in regions],
            "types": [t[0] for t in types],
        }
    finally:
        session.close()


@app.get("/api/top")
async def get_top_institutions(limit: int = Query(10, ge=1, le=100)):
    """ТОП закладів за рейтингом (без змін логіки порівняно з початковою версією)."""
    session = SessionLocal()
    try:
        query = text("""
            SELECT id, name, short_name, type, city, rating_total, rating_city_position
            FROM institutions
            WHERE rating_total IS NOT NULL
            ORDER BY rating_total
            LIMIT :limit
        """)
        result = session.execute(query, {'limit': limit})
        return [dict(row._mapping) for row in result]
    finally:
        session.close()


#  РУЧКИ: ВІДГУКИ (процедури, тригери, транзакції)

@app.get("/api/institutions/{institution_id}/reviews")
async def get_reviews(institution_id: int):
    """Схвалені відгуки (представлення v_reviews_public)."""
    session = SessionLocal()
    try:
        result = session.execute(
            text("SELECT id, author, score, comment, created_at FROM v_reviews_public "
                 "WHERE institution_id = :id ORDER BY created_at DESC"), {"id": institution_id})
        return [dict(r._mapping) for r in result]
    finally:
        session.close()


@app.post("/api/institutions/{institution_id}/reviews", status_code=201)
async def add_review(institution_id: int, review: ReviewIn):
    """Додати відгук: викликає процедуру sp_add_review (валідація всередині БД).
    Тригери самі оновлять avg_review_score / reviews_count, запишуть аудит і надішлють NOTIFY."""
    try:
        with engine.begin() as conn:            # одна транзакція: COMMIT при успіху, ROLLBACK при помилці
            new_id = conn.execute(
                text("CALL sp_add_review(:i, :a, :s, :c, NULL)"),
                {"i": institution_id, "a": review.author, "s": review.score, "c": review.comment},
            ).scalar()
        return {"id": new_id, "status": "created"}
    except DBAPIError as e:
        raise_http(e)


@app.patch("/api/reviews/{review_id}")
async def moderate_review(review_id: int, body: ModerationIn):
    """Модерація відгуку: sp_moderate_review."""
    try:
        with engine.begin() as conn:
            conn.execute(text("CALL sp_moderate_review(:id, CAST(:st AS review_status))"),
                         {"id": review_id, "st": body.status})
        return {"id": review_id, "status": body.status}
    except DBAPIError as e:
        raise_http(e)


#  РУЧКИ: РЕЙТИНГ І ІСТОРІЯ

@app.put("/api/institutions/{institution_id}/rating")
async def update_rating(institution_id: int, body: RatingIn):
    """Оновити рейтинг: sp_update_rating; історію пише тригер у rating_history."""
    try:
        with engine.begin() as conn:
            conn.execute(
                text("CALL sp_update_rating(:id, :t, :cp, :gp, :n, :t2, :sc)"),
                {"id": institution_id, "t": body.total, "cp": body.city_position, "gp": body.general_position,
                 "n": body.nmt_score, "t2": body.top200, "sc": body.scopus})
        return {"id": institution_id, "rating_total": body.total}
    except DBAPIError as e:
        raise_http(e)


@app.get("/api/institutions/{institution_id}/rating-history")
async def get_rating_history(institution_id: int):
    session = SessionLocal()
    try:
        result = session.execute(
            text("SELECT rating_total, city_position, general_position, recorded_at "
                 "FROM rating_history WHERE institution_id = :id ORDER BY recorded_at DESC"), {"id": institution_id})
        return [dict(r._mapping) for r in result]
    finally:
        session.close()


#  РУЧКИ: АНАЛІТИКА ТА АДМІНІСТРУВАННЯ

@app.get("/api/stats/regions")
async def region_stats():
    """Статистика по областях з матеріалізованого представлення mv_region_stats."""
    session = SessionLocal()
    try:
        result = session.execute(text(
            "SELECT region_name, institutions, cities, avg_rating, students "
            "FROM mv_region_stats ORDER BY institutions DESC"))
        return [dict(r._mapping) for r in result]
    finally:
        session.close()


@app.get("/api/stats/ratings")
async def rating_distribution():
    """Розподіл закладів за категоріями рейтингу (функція fn_rating_distribution)."""
    session = SessionLocal()
    try:
        result = session.execute(text("SELECT label, institutions_count FROM fn_rating_distribution()"))
        return [dict(r._mapping) for r in result]
    finally:
        session.close()


@app.get("/api/admin/audit")
async def get_audit(limit: int = Query(20, ge=1, le=200)):
    """Журнал аудиту, який заповнюють тригери."""
    session = SessionLocal()
    try:
        result = session.execute(
            text("SELECT id, table_name, operation, row_id, changed_by, changed_at FROM audit_log "
                 "ORDER BY id DESC LIMIT :l"), {"l": limit})
        return [dict(r._mapping) for r in result]
    finally:
        session.close()


@app.get("/api/admin/db-info")
async def db_info():
    """Службова інформація СКБД: розмір БД і таблиць (команди адміністрування)."""
    session = SessionLocal()
    try:
        size = session.execute(text("SELECT pg_size_pretty(pg_database_size(current_database()))")).scalar()
        tables = session.execute(text(
            "SELECT relname AS table_name, n_live_tup AS rows, "
            "pg_size_pretty(pg_total_relation_size(relid)) AS total_size "
            "FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC"))
        return {"database_size": size, "tables": [dict(r._mapping) for r in tables]}
    finally:
        session.close()


@app.post("/api/admin/refresh-stats")
async def refresh_stats():
    """Оновити матеріалізоване представлення (ручний аналог події-планувальника)."""
    try:
        with engine.begin() as conn:
            conn.execute(text("REFRESH MATERIALIZED VIEW mv_region_stats"))
        return {"status": "refreshed"}
    except DBAPIError as e:
        raise_http(e)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
