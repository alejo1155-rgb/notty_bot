

# 🤖 Team Reminder Bot (ОТУ)

Telegram-бот для автоматических напоминаний команде ОТУ и интеграции с тестовой инфраструктурой:

    Ежедневно в 11:50 (пн–пт): напоминание о дейли в 12:00
    Понедельник в 12:50: напоминание о weekly-митинге в 13:00
    Пятница в 18:00: напоминание о заполнении Tempo за неделю
    Последнего числа каждого месяца в 10:00 и 17:00: напоминание об автоматической выгрузке Tempo 1-го числа
    Автоматические уведомления о старте/окончании тестовых прогонов
    Отслеживание занятости серверов-агентов (10.190.9.63, 10.177.5.114) с привязкой к задаче в Jira
    Уведомления при прерывании прогона (Ctrl+C)
    Статус пакетной сборки стендов (./main.sh all 18)

Бот работает в фоне через systemd и использует безопасную загрузку конфигурации из .env.
🛠️ Требования

    Python 3.7
    Linux-сервер (для systemd)
    Доступ к Telegram API (бот через @BotFather)
    testo 10.0+ (для корректных флагов --nn-server, --stop-on-fail)
    Доступ к Jira: https://jira.astralinux.ru

---

## 📦 Установка

1. **Клонируй репозиторий**
  ```bash
  git clone ssh://git@git.astralinux.ru:7999/qa/mobile-testo.git
  cd mobile-testo/bot


## Создай виртуальное окружение и установи зависимости
python3.7 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

## Настрой секреты
Создай файл .env в папке bot/:
BOT_TOKEN=ваш_токен_от_BotFather
CHAT_ID=-ваш_chat_id

## Проверь запуск вручную
python notify.py
→ Должно появиться: ✅ Бот запускается...

## Запуск через systemd (автозапуск при старте)

    Создай службу:
    sudo cp /home/user/git/mobile-testo/bot/telegram-reminder.service.example /etc/systemd/system/telegram-reminder.service

## Активируй службу:
sudo systemctl daemon-reload
sudo systemctl enable --now telegram-reminder

## Управление:
sudo systemctl status telegram-reminder   # статус
sudo systemctl restart telegram-reminder   # перезапуск
sudo journalctl -u telegram-reminder -f   # логи в реальном времени

## Безопасность

    Никогда не коммить:
        .env
        venv/
        Логи (*.log)

    Все секреты хранятся только на сервере
    Токен бота можно в любой момент отозвать в @BotFather

## 📁 Структура проекта

mobile-testo/
├── bot/
│   ├── notify.py                 # основной скрипт бота (напоминания)
│   ├── send_messages.sh         # уведомления для тестовых прогонов
│   ├── requirements.txt         # зависимости
│   ├── .env                     # секреты (не в Git!)
│   └── server_occupancy.json     # статус серверов (автообновление)
├── lib/
│   ├── mobile_jira               # запуск тестовых прогонов
│   └── stand/
│       └── main.sh               # сборка стендов
├── logs/
│   └── testo-tm4j/               # логи прогонов
├── .gitignore                   # исключает секреты из репозитория
└── README.md
Использование


Запуск тестового прогона (автоматические уведомления): ./mobile_jira -yc 14601 18 s

При нажатии Ctrl+C:

    Сервер автоматически освобождается
    В Telegram приходит уведомление с длительностью

Сборка стендов (только для 18/48): cd lib/stand ./main.sh all 18

    Уведомление в телеграм об успешной/не успешной сборке стендов

