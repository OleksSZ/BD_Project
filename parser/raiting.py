# -*- coding: utf-8 -*-
import asyncio
import re
from typing import List, Dict, Optional
from playwright.async_api import async_playwright
from bs4 import BeautifulSoup
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
import os
from dotenv import load_dotenv

load_dotenv()


class VstupOsvitaRatingParser:
    """Парсер рейтингов с Вступ.ОСВІТА.UA"""

    def __init__(self):
        self.base_url = "https://ru.osvita.ua/vnz/"
        self.db_url = f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
        self.engine = create_engine(self.db_url, echo=False)
        self.Session = sessionmaker(bind=self.engine)
        self.session = None

    def connect_db(self):
        self.session = self.Session()
        print("✅ Подключение к БД установлено")

    def disconnect_db(self):
        if self.session:
            self.session.close()
        print("🔌 Соединение с БД закрыто")

    async def get_rating_categories(self) -> List[Dict]:
        """Получает список категорий рейтингов со страницы rating/goroda.html"""
        url = f"{self.base_url}rating/goroda.html"

        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            context = await browser.new_context(
                viewport={'width': 1280, 'height': 800},
                user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            )
            page = await context.new_page()

            try:
                await page.goto(url, wait_until='domcontentloaded', timeout=30000)
                await page.wait_for_selector('.publications-by-topic__link-name', timeout=10000)

                html = await page.content()
                soup = BeautifulSoup(html, 'html.parser')

                categories = []
                for link in soup.select('.publications-by-topic__link-name'):
                    name = link.get_text(strip=True)
                    href = link.get('href')
                    if href:
                        if href.startswith('/'):
                            full_url = f"https://ru.osvita.ua{href}"
                        elif href.startswith('http'):
                            full_url = href
                        else:
                            full_url = f"https://ru.osvita.ua/vnz/{href}"
                        
                        categories.append({
                            'name': name,
                            'url': full_url
                        })

                print(f"📋 Найдено {len(categories)} категорий рейтингов")
                return categories

            except Exception as e:
                print(f"❌ Ошибка получения категорий: {e}")
                return []
            finally:
                await browser.close()

    async def parse_rating_page(self, url: str) -> List[Dict]:
        """Парсит одну страницу с рейтингом"""
        print(f"🌐 Парсинг: {url}")

        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            context = await browser.new_context(
                viewport={'width': 1280, 'height': 800},
                user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            )
            page = await context.new_page()

            try:
                await page.goto(url, wait_until='domcontentloaded', timeout=30000)

                try:
                    await page.wait_for_selector('div.table-responsive', timeout=15000)
                except Exception as e:
                    print(f"⚠️ div.table-responsive не найден: {e}")
                    return []

                html = await page.content()
                soup = BeautifulSoup(html, 'html.parser')

                ratings = []

                table_div = soup.find('div', class_='table-responsive')
                if not table_div:
                    print(f"⚠️ div.table-responsive не найден")
                    return []

                table = table_div.find('table')
                if not table:
                    print(f"⚠️ Таблица не найдена")
                    return []

                rows = table.find_all('tr')
                print(f"📊 Найдено {len(rows)} строк")

                for row in rows[1:]:
                    rating_data = self._parse_rating_row(row)
                    if rating_data:
                        ratings.append(rating_data)

                print(f"✅ Найдено {len(ratings)} записей рейтинга")
                return ratings

            except Exception as e:
                print(f"❌ Ошибка при парсинге: {e}")
                return []
            finally:
                await browser.close()

    def _parse_rating_row(self, row) -> Optional[Dict]:
        """Парсит строку таблицы"""
        try:
            cells = row.find_all('td')
            if len(cells) < 7:
                return None

            name_cell = cells[0]
            name_link = name_cell.find('a')
            if name_link:
                university_name = name_link.get_text(strip=True)
                university_url = name_link.get('href')
            else:
                university_name = name_cell.get_text(strip=True)
                university_url = None

            return {
                'university_name': university_name,
                'university_url': university_url,
                'position_city': self._parse_int(cells[1].get_text(strip=True)),
                'position_general': cells[2].get_text(strip=True),
                'nmt_score': self._parse_int(cells[3].get_text(strip=True)),
                'top200': self._parse_int(cells[4].get_text(strip=True)),
                'scopus': self._parse_int(cells[5].get_text(strip=True)),
                'total_score': self._parse_int(cells[6].get_text(strip=True)),
            }

        except Exception as e:
            return None

    def _parse_int(self, text: str) -> Optional[int]:
        if not text:
            return None
        text = text.strip().replace(',', '')
        if text.isdigit():
            return int(text)
        return None

    def save_ratings_to_db(self, ratings: List[Dict]) -> int:
        """Сохраняет рейтинги в БД"""
        if not ratings:
            return 0

        try:
            saved = 0
            for rating_data in ratings:
                # Ищем заведение по названию
                search_sql = text("""
                    SELECT id FROM institutions 
                    WHERE name ILIKE :name 
                    LIMIT 1
                """)

                search_name = rating_data['university_name']
                search_name = re.sub(r'\s*\([^)]*\)', '', search_name).strip()
                search_name = search_name.replace('"', '').replace('«', '').replace('»', '')

                inst = self.session.execute(search_sql, {
                    'name': f"%{search_name}%"
                }).first()

                if inst:
                    update_sql = text("""
                        UPDATE institutions SET
                            rating_total = :total_score,
                            rating_city_position = :position_city,
                            rating_general_position = :position_general,
                            rating_nmt_score = :nmt_score,
                            rating_top200 = :top200,
                            rating_scopus = :scopus,
                            rating_url = :url,
                            rating_updated_at = CURRENT_TIMESTAMP,
                            rating = :total_score
                        WHERE id = :id
                    """)
                    
                    self.session.execute(update_sql, {
                        'id': inst[0],
                        'total_score': rating_data.get('total_score'),
                        'position_city': rating_data.get('position_city'),
                        'position_general': rating_data.get('position_general'),
                        'nmt_score': rating_data.get('nmt_score'),
                        'top200': rating_data.get('top200'),
                        'scopus': rating_data.get('scopus'),
                        'url': rating_data.get('university_url'),
                    })
                    saved += 1
                    print(f"  ✅ {rating_data['university_name']} → {rating_data.get('total_score', 'N/A')} баллов")
                else:
                    print(f"  ⚠️ Не найдено: {rating_data['university_name']}")

            self.session.commit()
            print(f"💾 Обновлено {saved} рейтингов")
            return saved

        except Exception as e:
            self.session.rollback()
            print(f"❌ Ошибка сохранения: {e}")
            return 0


async def main():
    parser = VstupOsvitaRatingParser()
    parser.connect_db()

    try:
        print("=" * 60)
        print("ШАГ 1: Получение категорий рейтингов")
        print("=" * 60)

        categories = await parser.get_rating_categories()

        if not categories:
            print("❌ Категории не найдены")
            return

        print(f"\n📋 Найдено категорий: {len(categories)}")

        for cat in categories[:10]:
            print(f"\n{'=' * 60}")
            print(f"📚 Категория: {cat['name']}")
            print(f"🔗 URL: {cat['url']}")
            print(f"{'=' * 60}")

            ratings = await parser.parse_rating_page(cat['url'])
            if ratings:
                parser.save_ratings_to_db(ratings)
            else:
                print("⚠️ Рейтингов не найдено")

            await asyncio.sleep(1)

        print("\n🎉 Готово!")

    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()

    finally:
        parser.disconnect_db()


if __name__ == "__main__":
    asyncio.run(main())