# -*- coding: utf-8 -*-
import asyncio
import re
import io
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from typing import List, Dict, Optional
from playwright.async_api import async_playwright, TimeoutError as PlaywrightTimeoutError
from bs4 import BeautifulSoup
import os
from dotenv import load_dotenv
from curl_cffi import requests

# Загружаем переменные окружения
load_dotenv()


class EdboFullLoader:
    """Полный загрузчик ЕДЕБО: сначала заведения, потом программы"""

    def __init__(self):
        self.base_url = "https://registry.edbo.gov.ua"

        # Подключение к БД через SQLAlchemy
        db_url = f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
        self.engine = create_engine(db_url, echo=False)
        self.Session = sessionmaker(bind=self.engine)
        self.session = None

    def connect_db(self):
        """Подключается к БД"""
        try:
            self.session = self.Session()
            print("✅ Подключение к БД установлено")
        except Exception as e:
            print(f"❌ Ошибка подключения к БД: {e}")
            raise

    def disconnect_db(self):
        """Закрывает соединение с БД"""
        if self.session:
            self.session.close()
        print("🔌 Соединение с БД закрыто")

    # ============ 1. ЗАГРУЗКА ЗАВЕДЕНИЙ ============

    def load_institutions(self, df: pd.DataFrame, category_ut: int) -> int:
        """
        Загружает заведения в таблицу institutions

        Returns:
            Количество загруженных записей
        """
        try:
            loaded = 0
            for _, row in df.iterrows():
                edbo_code = int(row['Код'])

                # Проверяем, существует ли уже запись
                check_sql = text("SELECT id FROM institutions WHERE edbo_code = :edbo_code")
                existing = self.session.execute(check_sql, {'edbo_code': edbo_code}).first()

                # Парсим год основания
                founded_year = None
                year_val = row.get('Рік заснування', '')
                if not pd.isna(year_val) and year_val:
                    match = re.search(r'(\d{4})', str(year_val))
                    if match:
                        founded_year = int(match.group(1))

                institution_data = {
                    'edbo_code': edbo_code,
                    'name': str(row.get('Назва закладу освіти', ''))[:500],
                    'short_name': str(row.get('Коротка назва', ''))[:200],
                    'type': str(row.get('Категорія закладу освіти', ''))[:100],
                    'ownership': str(row.get('Форма власності', ''))[:50],
                    'region': str(row.get('Регіон (місцезнаходження)', ''))[:100],
                    'city': str(row.get('Населений пункт (місцезнаходження)', ''))[:100],
                    'address': str(row.get('Адреса (місцезнаходження)', ''))[:500],
                    'website': str(row.get('Веб-сайт', ''))[:200],
                    'founded_year': founded_year,
                    'category_type': category_ut,
                }

                if existing:
                    # Обновляем существующую запись
                    update_sql = text("""
                        UPDATE institutions SET
                            name = :name,
                            short_name = :short_name,
                            type = :type,
                            ownership = :ownership,
                            region = :region,
                            city = :city,
                            address = :address,
                            website = :website,
                            founded_year = :founded_year,
                            category_type = :category_type,
                            updated_at = CURRENT_TIMESTAMP
                        WHERE edbo_code = :edbo_code
                    """)
                    self.session.execute(update_sql, institution_data)
                else:
                    # Вставляем новую запись
                    insert_sql = text("""
                        INSERT INTO institutions (
                            edbo_code, name, short_name, type, ownership,
                            region, city, address, website, founded_year,
                            category_type
                        ) VALUES (
                            :edbo_code, :name, :short_name, :type, :ownership,
                            :region, :city, :address, :website, :founded_year,
                            :category_type
                        )
                    """)
                    self.session.execute(insert_sql, institution_data)

                loaded += 1

            self.session.commit()
            print(f"💾 Загружено {loaded} заведений в БД")
            return loaded

        except Exception as e:
            self.session.rollback()
            print(f"❌ Ошибка при загрузке заведений: {e}")
            return 0

    # ============ 2. ПАРСИНГ ПРОГРАММ ============

    async def parse_programs_for_university(self, university_id: int) -> List[Dict]:
        """Парсит программы для одного заведения через Playwright"""
        url = f"{self.base_url}/university/{university_id}/study-programs"

        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            context = await browser.new_context(
                viewport={'width': 1280, 'height': 800},
                user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            )
            page = await context.new_page()

            try:
                await page.goto(url, wait_until='domcontentloaded', timeout=30000)

                try:
                    await page.wait_for_selector(
                        'table.registry-table, .blocked-message, .text-center:has-text("немає")',
                        timeout=15000
                    )
                except PlaywrightTimeoutError:
                    return []

                content = await page.content()

                if 'заблоковано' in content.lower() or 'немає освітніх програм' in content.lower():
                    return []

                table_exists = await page.query_selector('table.registry-table')
                if not table_exists:
                    return []

                html = await page.content()
                programs = self._parse_programs_html(html, university_id)

                return programs

            except Exception as e:
                print(f"⚠️ Ошибка для {university_id}: {str(e)[:100]}")
                return []
            finally:
                await browser.close()

    def _parse_programs_html(self, html: str, university_id: int) -> List[Dict]:
        """Парсит HTML таблицу с программами"""
        programs = []
        soup = BeautifulSoup(html, 'html.parser')

        table = soup.find('table', class_='registry-table')
        if not table:
            return []

        rows = table.find_all('tr')
        current_level = None

        for row in rows:
            subtitle_cell = row.find('td', class_='subtitle')
            if subtitle_cell:
                current_level = subtitle_cell.get_text(strip=True)
                continue

            cells = row.find_all('td')
            if len(cells) < 4:
                continue

            first_cell = cells[0].find('div', class_='registry-cell')
            if not first_cell:
                continue

            program = self._parse_program_row(cells, university_id, current_level)
            if program:
                programs.append(program)

        return programs

    def _parse_program_row(self, cells, university_id: int, level: str) -> Optional[Dict]:
        """Парсит одну строку таблицы"""
        try:
            specialty_data = self._parse_specialty(cells[0])
            program_name = self._get_cell_text(cells[1])
            accreditation_data = self._parse_accreditation(cells[3])

            students_text = self._get_cell_text(cells[4])
            students_count = int(students_text) if students_text and students_text.isdigit() else 0

            return {
                'institution_id': university_id,
                'level': level or "Невідомий рівень",
                'specialty_name': specialty_data['name'],
                'specialty_code': specialty_data['code'],
                'specialization_name': specialty_data['specialization'],
                'program_name': program_name,
                'accreditation_type': accreditation_data['type'],
                'accreditation_series': accreditation_data['series'],
                'accreditation_number': accreditation_data['number'],
                'accreditation_valid_until': accreditation_data['valid_until'],
                'students_count': students_count,
            }
        except Exception:
            return None

    def _parse_specialty(self, cell) -> Dict:
        """Парсит специальность"""
        result = {'code': None, 'name': '', 'specialization': ''}

        try:
            text = cell.get_text(strip=True)

            code_match = re.search(r'\(([^)]+)\)', text)
            if code_match:
                result['code'] = code_match.group(1)

            if result['code']:
                name_part = text.replace(f"({result['code']})", '').strip()
            else:
                name_part = text

            if '\n' in name_part:
                parts = name_part.split('\n')
                result['name'] = parts[0].strip()
                if len(parts) > 1 and parts[1].strip():
                    result['specialization'] = parts[1].strip()
            else:
                result['name'] = name_part.strip()

            italic = cell.find('div', class_='italic')
            if italic:
                result['specialization'] = italic.get_text(strip=True)
        except:
            pass

        return result

    def _parse_accreditation(self, cell) -> Dict:
        """Парсит аккредитацию"""
        result = {'type': None, 'series': None, 'number': None, 'valid_until': None}

        try:
            text = cell.get_text(strip=True)

            type_match = re.search(r'акредитацію\s+(спеціальності|освітньої програми)', text, re.IGNORECASE)
            if type_match:
                result['type'] = type_match.group(1)

            acc_match = re.search(r'([А-Я0-9]+)\s+([0-9]+)', text)
            if acc_match:
                series = acc_match.group(1)
                number = acc_match.group(2)
                if not number.startswith('20'):
                    result['series'] = series
                    result['number'] = number

            date_match = re.search(r'до\s+([\d.]+)', text)
            if date_match:
                result['valid_until'] = date_match.group(1)
        except:
            pass

        return result

    def _get_cell_text(self, cell) -> str:
        """Получает текст из ячейки"""
        try:
            div = cell.find('div', class_=re.compile(r'(registry-cell|institution-empty-cell)'))
            if div:
                return div.get_text(strip=True)
            return cell.get_text(strip=True)
        except:
            return ""

    # ============ 3. ЗАПИСЬ ПРОГРАММ В БД ============

    def save_programs_to_db(self, programs: List[Dict]) -> int:
        """
        Сохраняет программы в БД
        """
        if not programs:
            return 0

        try:
            saved = 0
            for prog in programs:
                # Проверяем, существует ли заведение
                check_institution = text("SELECT id FROM institutions WHERE edbo_code = :edbo_code")
                institution = self.session.execute(check_institution, {'edbo_code': prog['institution_id']}).first()

                if not institution:
                    # Если заведения нет в БД - пропускаем
                    print(f"⚠️ Заведение с edbo_code={prog['institution_id']} не найдено в БД, пропускаем")
                    continue

                inst_id = institution[0]

                # Проверяем, существует ли уже такая запись
                check_sql = text("""
                    SELECT id FROM institution_specialties 
                    WHERE institution_id = :institution_id 
                    AND specialty_code = :specialty_code 
                    AND program_name = :program_name
                """)

                existing = self.session.execute(
                    check_sql,
                    {
                        'institution_id': inst_id,
                        'specialty_code': prog['specialty_code'],
                        'program_name': prog['program_name']
                    }
                ).first()

                if existing:
                    # Обновляем существующую запись
                    update_sql = text("""
                        UPDATE institution_specialties SET
                            specialty_name = :specialty_name,
                            education_level = :level,
                            specialization_name = :specialization_name,
                            accreditation_type = :accreditation_type,
                            accreditation_series = :accreditation_series,
                            accreditation_number = :accreditation_number,
                            accreditation_valid_until = :accreditation_valid_until,
                            students_count = :students_count,
                            updated_at = CURRENT_TIMESTAMP
                        WHERE institution_id = :institution_id 
                        AND specialty_code = :specialty_code 
                        AND program_name = :program_name
                    """)

                    self.session.execute(update_sql, {
                        'institution_id': inst_id,
                        'specialty_name': prog['specialty_name'],
                        'level': prog['level'],
                        'specialization_name': prog['specialization_name'],
                        'accreditation_type': prog['accreditation_type'],
                        'accreditation_series': prog['accreditation_series'],
                        'accreditation_number': prog['accreditation_number'],
                        'accreditation_valid_until': prog['accreditation_valid_until'],
                        'students_count': prog['students_count'],
                        'specialty_code': prog['specialty_code'],
                        'program_name': prog['program_name']
                    })
                else:
                    # Вставляем новую запись
                    insert_sql = text("""
                        INSERT INTO institution_specialties (
                            institution_id,
                            specialty_name,
                            specialty_code,
                            education_level,
                            program_name,
                            specialization_name,
                            accreditation_type,
                            accreditation_series,
                            accreditation_number,
                            accreditation_valid_until,
                            students_count,
                            source
                        ) VALUES (
                            :institution_id,
                            :specialty_name,
                            :specialty_code,
                            :level,
                            :program_name,
                            :specialization_name,
                            :accreditation_type,
                            :accreditation_series,
                            :accreditation_number,
                            :accreditation_valid_until,
                            :students_count,
                            'edbo'
                        )
                    """)

                    self.session.execute(insert_sql, {
                        'institution_id': inst_id,
                        'specialty_name': prog['specialty_name'],
                        'specialty_code': prog['specialty_code'],
                        'level': prog['level'],
                        'program_name': prog['program_name'],
                        'specialization_name': prog['specialization_name'],
                        'accreditation_type': prog['accreditation_type'],
                        'accreditation_series': prog['accreditation_series'],
                        'accreditation_number': prog['accreditation_number'],
                        'accreditation_valid_until': prog['accreditation_valid_until'],
                        'students_count': prog['students_count']
                    })

                saved += 1

            self.session.commit()
            print(f"💾 Сохранено {saved} программ в БД")
            return saved

        except Exception as e:
            self.session.rollback()
            print(f"❌ Ошибка при сохранении в БД: {e}")
            return 0

    # ============ 4. МАССОВЫЙ ПАРСИНГ ============

    async def parse_and_save_all(
        self,
        university_ids: List[int],
        max_concurrent: int = 3,
        save_interval: int = 50
    ):
        """
        Парсит и сохраняет программы для всех заведений
        """
        total = len(university_ids)
        successful = 0
        failed = 0
        total_programs = 0

        print(f"\n🚀 Начинаю парсинг {total} заведений...")
        print(f"   Параллельных задач: {max_concurrent}")

        semaphore = asyncio.Semaphore(max_concurrent)

        async def parse_one(uni_id, index):
            nonlocal successful, failed, total_programs
            async with semaphore:
                print(f"  [{index}/{total}] Парсинг ID: {uni_id}")
                programs = await self.parse_programs_for_university(uni_id)
                if programs:
                    successful += 1
                    saved = self.save_programs_to_db(programs)
                    total_programs += saved
                    print(f"    ✅ Найдено {len(programs)} программ, сохранено {saved}")
                    return programs
                else:
                    failed += 1
                    print(f"    ⚠️ Нет программ")
                    return []

        # Создаем задачи и выполняем их партиями
        for i in range(0, total, save_interval):
            batch_end = min(i + save_interval, total)
            batch_ids = university_ids[i:batch_end]

            print(f"\n📦 Обработка пакета {i+1}-{batch_end} из {total}")

            batch_tasks = [
                parse_one(uni_id, idx + 1)
                for idx, uni_id in enumerate(batch_ids)
            ]
            await asyncio.gather(*batch_tasks)

            print(f"  📊 Промежуточный итог: {total_programs} программ")

        print(f"\n{'=' * 60}")
        print(f"📊 ИТОГО:")
        print(f"   Обработано заведений: {total}")
        print(f"   Успешно: {successful}")
        print(f"   Без программ: {failed}")
        print(f"   Всего программ: {total_programs}")
        print(f"{'=' * 60}")

        return total_programs


# ============ 5. ЗАПУСК ============

async def main():
    loader = EdboFullLoader()

    # Подключаемся к БД
    loader.connect_db()

    try:
        # ШАГ 1: Загружаем заведения
        print("=" * 60)
        print("ШАГ 1: Загрузка заведений в БД")
        print("=" * 60)

        categories = [
            {'ut': 1, 'name': 'вищої_освіти'},
            {'ut': 9, 'name': 'фахової_передвищої_освіти'},
            {'ut': 2, 'name': 'професійно_технічної_освіти'},
            {'ut': 3, 'name': 'середньої_освіти', 'endpoint': 'institutions'},
            {'ut': 8, 'name': 'наукових_інститутів'},
            {'ut': 10, 'name': 'післядипломної_освіти'},
        ]

        all_ids = []
        total_institutions = 0

        for cat in categories:
            ut = cat['ut']
            name = cat['name']
            endpoint = cat.get('endpoint', 'universities')

            url = f"https://registry.edbo.gov.ua/api/opendata/{endpoint}?rg=0&ut={ut}&exp=xlsx"
            print(f"📥 Загрузка {name} (ut={ut})...")

            try:
                response = requests.get(url, impersonate="chrome", timeout=60)
                if response.status_code == 200:
                    df = pd.read_excel(io.BytesIO(response.content))

                    # Загружаем заведения в БД
                    loaded = loader.load_institutions(df, ut)
                    total_institutions += loaded

                    # Собираем ID для парсинга программ
                    ids = df[df['Код'].notna()]['Код'].astype(int).tolist()
                    all_ids.extend(ids)

                    print(f"   ✅ Загружено {loaded} заведений, получено {len(ids)} ID")
                else:
                    print(f"   ❌ Ошибка: {response.status_code}")
            except Exception as e:
                print(f"   ❌ Ошибка для {name}: {e}")

        print(f"\n📋 Всего загружено заведений: {total_institutions}")
        print(f"📋 Всего ID для парсинга: {len(all_ids)}")


       

        print(f"📋 Для парсинга программ выбрано {len(all_ids)} заведений")

        # ШАГ 2: Парсим программы
        print("\n" + "=" * 60)
        print("ШАГ 2: Парсинг и сохранение программ")
        print("=" * 60)

        await loader.parse_and_save_all(all_ids, max_concurrent=3)

        print("\n🎉 Готово!")

    except Exception as e:
        print(f"❌ Критическая ошибка: {e}")
        import traceback
        traceback.print_exc()

    finally:
        loader.disconnect_db()


if __name__ == "__main__":
    asyncio.run(main())