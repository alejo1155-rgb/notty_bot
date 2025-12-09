import os
import json
import random
import requests
import logging
from datetime import datetime, timedelta
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, executor, types
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from aiogram.dispatcher import FSMContext
from aiogram.dispatcher.filters.state import State, StatesGroup
from aiogram.contrib.fsm_storage.memory import MemoryStorage


#Логирование
logging.basicConfig(level=logging.INFO)
# Машина состояний для занятия сервера

class ServerOccupation(StatesGroup):
    waiting_for_issue = State()


# ========================
# Настройка
# ========================
load_dotenv()



# Обязательные переменные
BOT_TOKEN = os.getenv("BOT_TOKEN")
CHAT_ID = os.getenv("CHAT_ID")

if not BOT_TOKEN:
    raise RuntimeError("❌ BOT_TOKEN не задан в .env")
if not CHAT_ID:
    raise RuntimeError("❌ CHAT_ID не задан в .env")

CHAT_ID = int(CHAT_ID)

# Ветка для уведомлений о серверах
NOTIFY_THREAD_ID = int(os.getenv("NOTIFY_THREAD_ID", 0))

# Jira (PAT)
JIRA_URL = os.getenv("JIRA_URL")
JIRA_PAT = os.getenv("JIRA_PAT")

# Список серверов
SERVER_NAMES = {
    "x86": "server1,
    "arm": "server2",
}

# В коде работаем с ключами: "x86", "arm"
SERVERS = list(SERVER_NAMES.keys())

# Файл состояния
STATE_FILE = "server_occupancy.json"
if not os.path.exists(STATE_FILE):
    with open(STATE_FILE, "w") as f:
        json.dump({}, f)

# Инициализация бота
bot = Bot(token=BOT_TOKEN)


# Хранилище для FSM
from aiogram.contrib.fsm_storage.memory import MemoryStorage
storage = MemoryStorage()
dp = Dispatcher(bot, storage=storage)

scheduler = AsyncIOScheduler()

# ========================
# Вспомогательные функции
# ========================
def load_state():
    with open(STATE_FILE, "r") as f:
        return json.load(f)

def save_state(data):
    with open(STATE_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def check_jira_issue(issue_key: str):
    if not JIRA_PAT or not JIRA_URL:
        return None
    url = f"{JIRA_URL.rstrip('/')}/rest/api/2/issue/{issue_key}"
    headers = {
        "Authorization": f"Bearer {JIRA_PAT}",
        "Accept": "application/json"
    }
    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 200:
            data = response.json()
            return {
                "key": data["key"],
                "summary": data["fields"]["summary"],
                "url": f"{JIRA_URL}/browse/{data['key']}"
            }
    except Exception:
        pass
    return None


def get_business_days(start_date: datetime, end_date: datetime) -> int:
    """Считает количество рабочих дней (пн-пт) между двумя датами (включительно)."""
    business_days = 0
    current = start_date.date()
    end = end_date.date()

    while current <= end:
        if current.weekday() < 5:  # 0=пн, ..., 4=пт
            business_days += 1
        current += timedelta(days=1)
    return business_days

# ========================
# Команды бота
# ========================
@dp.message_handler(commands=["start"])
async def cmd_start(message: types.Message):
    await message.answer(
        "👋 Привет! Я бот для проверки свободности серверов и напоминаний.\n\n"
        "🔹 Нажмите /servers — чтобы занять/освободить сервер\n"
        "🔹 Нажмите /status — чтобы посмотреть текущее состояние"
    )

@dp.message_handler(commands=["cancel"], state="*")
async def cancel_handler(message: types.Message, state: FSMContext):
    await state.finish()
    await message.answer("❌ Операция отменена. Готов к новому запросу!")


@dp.message_handler(commands=["status"])
async def cmd_status(message: types.Message):
    state = load_state()
    if not state:
        await message.answer("✅ Все серверы свободны!")
        return

    text = "📊 Текущее состояние серверов:\n\n"
    for srv in SERVERS:
        if srv in state:
            info = state[srv]
            # Экранируем summary для HTML
            summary = info.get("issue_summary") or ""
            summary = summary.replace("&", "&amp;").replace("<", "<").replace(">", ">")
            line = f"🔒 <code>{srv}</code> — {info['user']} (с {info['since']})"
            if info.get("issue_key"):
                line += f'\n  → <a href="{info["issue_url"]}">{info["issue_key"]}</a>: {summary}'
            text += line + "\n\n"
        else:
            text += f"✅ <code>{srv}</code> — свободен\n\n"
    await message.answer(text, parse_mode="HTML", disable_web_page_preview=True)

@dp.message_handler(commands=["servers"])
async def cmd_servers(message: types.Message):
    keyboard = InlineKeyboardMarkup(row_width=1)
    state = load_state()

    for srv_key in SERVERS:
        srv_name = SERVER_NAMES[srv_key]  # ← 8 пробелов (2 уровня)
        if srv_key in state:
            occupant = state[srv_key]["user"]
            btn = InlineKeyboardButton(f"🔒 {srv_name} — {occupant}", callback_data=f"release_{srv_key}")
        else:
            btn = InlineKeyboardButton(f"✅ {srv_name} — свободен", callback_data=f"occupy_{srv_key}")
        keyboard.add(btn)  # ← 4 пробела (1 уровень)

    await message.answer("Выберите сервер для управления:", reply_markup=keyboard)

@dp.callback_query_handler(lambda c: c.data.startswith(('occupy_', 'release_')))
async def handle_server_action(callback_query: types.CallbackQuery, state: FSMContext):
    # === Безопасный парсинг callback_data ===
    try:
        parts = callback_query.data.split('_', 1)
        if len(parts) != 2:
            raise ValueError("Invalid format")
        action, server_key = parts
    except Exception:
        await callback_query.answer("❌ Ошибка: некорректный запрос", show_alert=True)
        return

    # === Проверка сервера ===
    if server_key not in SERVER_NAMES:
        await callback_query.answer("❌ Неизвестный сервер", show_alert=True)
        return

    srv_name = SERVER_NAMES[server_key]
    user = callback_query.from_user
    username = f"@{user.username}" if user.username else user.full_name
    current_state = load_state()

    # === Занятие сервера ===
    if action == "occupy":
        if server_key in current_state:
            occupant = current_state[server_key]["user"]
            await callback_query.answer(f"❌ Уже занят {occupant}!", show_alert=True)
            return

        await state.set_state(ServerOccupation.waiting_for_issue)
        await state.update_data(server=server_key)

        await callback_query.message.answer(
            f"✏️ Укажите Jira-задачу для `{srv_name}` (например, `DEVQA-5003`) или отправьте `-`, чтобы пропустить:"
        )
        await callback_query.answer()

    # === Освобождение сервера ===
    elif action == "release":
        if server_key not in current_state:
            await callback_query.answer("✅ Сервер и так свободен", show_alert=True)
            return

        owner = current_state[server_key]["user"]
        del current_state[server_key]
        save_state(current_state)

        await bot.send_message(
            chat_id=CHAT_ID,
            text=f"✅ Сервер `{srv_name}` **освобождён** ({owner})",
            message_thread_id=NOTIFY_THREAD_ID
        )
        await callback_query.answer("🔓 Освобождено!")
        await cmd_servers(callback_query.message)

@dp.message_handler(state=ServerOccupation.waiting_for_issue)
async def process_issue_key(message: types.Message, state: FSMContext):
    data = await state.get_data()
    server_key = data.get("server")
    username = f"@{message.from_user.username}" if message.from_user.username else message.from_user.full_name

    if not server_key:
        await message.answer("❌ Ошибка: сервер не выбран. Начните заново: /servers")
        await state.finish()
        return

    issue_key = message.text.strip()
    issue_info = None

    if issue_key != "-":
        issue_info = check_jira_issue(issue_key.upper())
        if not issue_info:
            await message.answer(f"❌ Задача `{issue_key}` не найдена. Попробуйте снова: /servers")
            await state.finish()
            return

    # Сохраняем сервер
    current_state = load_state()
    current_state[server_key] = {
        "user": username,
        "issue_key": issue_info["key"] if issue_info else None,
        "issue_summary": issue_info["summary"] if issue_info else "",
        "issue_url": issue_info.get("url", "") if issue_info else ""
        "since": datetime.now().isoformat()
    }
    save_state(current_state)

    # Отправляем в ветку 
    srv_name = SERVER_NAMES[server_key]
    if issue_info:
        summary = issue_info['summary'].replace("&", "&amp;").replace("<", "<").replace(">", ">")
        msg = f'🔒 <code>{srv_name}</code> <b>занят</b> {username} для <a href="{issue_info["url"]}">{issue_info["key"]}</a>: {summary}'
    else:
        msg = f'🔒 <code>{srv_name}</code> <b>занят</b> {username}'

    await bot.send_message(
        chat_id=CHAT_ID,
        text=msg,
        parse_mode="HTML",
        disable_web_page_preview=True,
        message_thread_id=NOTIFY_THREAD_ID
    )
    await message.answer("✅ Сервер успешно занят!")
    await state.finish()

# ========================
# Напоминания (в основном разделе)
# ========================
async def daily_reminder():
    await bot.send_message(
        CHAT_ID,
        "📢 Напоминание: ежедневный стендап через 10 минут.\n"
        "🔗 Присоединиться: https://meet.example.com/qa-team"
    )

async def weekly_reminder():
    await bot.send_message(
        CHAT_ID,
        "📢 Сегодня понедельник! В 13:00 будет weekly-митинг.\n"
        "🔗 Присоединиться: https://meet.example.com/qa-team"
    )

async def tempo_reminder_friday():
    await bot.send_message(CHAT_ID, "📆 Не забудьте заполнить Tempo за эту неделю! \n"
        "📆 Внесите комментарии в рабочие задачи, которые не окончены.\n"
        "📆 Проверьте статусы у задач, которые назначены на вас.")

async def tempo_monthly_reminder():
    await bot.send_message(CHAT_ID, "📆 Месяц подходит к концу! Убедитесь, что все часы и комментарии в системе учёта времени актуальны."

async def check_long_occupied_servers():
    state = load_state()
    now = datetime.now()

    for server, info in state.items():
        try:
            since = datetime.fromisoformat(info["since"])
        except (ValueError, TypeError):
            continue

        # Считаем рабочие дни с момента занятия
        business_days = get_business_days(since, now)

        if business_days > 5:
            user = info["user"]
            msg = f"⚠️ {user}, сервер `{server}` занят уже больше 5 рабочих дней. Не забудь освободить, если не используешь!"
            await bot.send_message(
                chat_id=CHAT_ID,
                text=msg,
                message_thread_id=NOTIFY_THREAD_ID
            )


# Расписание
scheduler.add_job(daily_reminder, 'cron', day_of_week='mon-fri', hour=11, minute=50)
#scheduler.add_job(weekly_reminder, 'cron', day_of_week='mon', hour=12, minute=50)
scheduler.add_job(tempo_reminder_friday, 'cron', day_of_week='fri', hour=16, minute=0)
scheduler.add_job(tempo_monthly_reminder, CronTrigger(day="last", hour=10, minute=0))
scheduler.add_job(check_long_occupied_servers, 'cron', day_of_week='mon-fri', hour=9, minute=0)  # каждый день в 9:00

# ========================
# Запуск
# ========================
if __name__ == '__main__':
    logging.info("Bot started. Scheduler active.")
    scheduler.start()
    executor.start_polling(dp, skip_updates=True)
