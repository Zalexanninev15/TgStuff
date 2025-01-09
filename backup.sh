#!/bin/bash

# Параметры для доступа к Telegram API
TELEGRAM_API_ID=""
TELEGRAM_API_HASH=""
TELEGRAM_PHONE=""

# Проверка зависимостей
check_dependencies() {
    command -v python3 >/dev/null 2>&1 || { echo "Требуется Python3. Установите командой: pkg install python"; exit 1; }
    command -v pip >/dev/null 2>&1 || { echo "Требуется pip. Установите командой: pkg install python-pip"; exit 1; }
    python3 -c "import telethon" >/dev/null 2>&1 || { echo "Установка Telethon..."; pip install telethon; }
}

# Создаём директорию в текущей папке
setup_directory() {
    mkdir -p ./output
}

# Создаём Python скрипт
create_python_script() {
    cat > ./telegram_export.py << 'EOL'
from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError
from telethon.tl.types import Channel, Chat, User, Dialog
from datetime import datetime
import os
import asyncio

# Получение параметров из переменных окружения
TELEGRAM_API_ID = os.getenv('TELEGRAM_API_ID')
TELEGRAM_API_HASH = os.getenv('TELEGRAM_API_HASH')
TELEGRAM_PHONE = os.getenv('TELEGRAM_PHONE')

# Настройки для безопасной работы
BATCH_SIZE = 50
DELAY_BETWEEN_BATCHES = 30
DELAY_BETWEEN_REQUESTS = 2

# Создание клиента
client = TelegramClient('tg_session', TELEGRAM_API_ID, TELEGRAM_API_HASH)

async def main():
    # Подключаемся и проверяем авторизацию
    await client.connect()
    
    if not await client.is_user_authorized():
        print("Требуется авторизация...")
        await client.send_code_request(TELEGRAM_PHONE)
        try:
            code = input('Введите код подтверждения из Telegram: ')
            await client.sign_in(TELEGRAM_PHONE, code)
        except SessionPasswordNeededError:
            password = input('Введите пароль двухфакторной аутентификации: ')
            await client.sign_in(password=password)
        print()
    
    print("Начинаем безопасное сканирование диалогов...")
    
    current_time = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"./output/telegram_backup_{current_time}.txt"
    
    # Получаем все диалоги
    dialogs = await client.get_dialogs()
    total_dialogs = len(dialogs)
    
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(f"=== Telegram Backup (Всего диалогов: {total_dialogs}) ===\n")
        f.write(f"Дата создания: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        for i, dialog in enumerate(dialogs, 1):
            entity = dialog.entity
            
            # Определение типа диалога
            if isinstance(entity, Channel):
                type_name = "Канал" if entity.broadcast else "Группа"
            elif isinstance(entity, Chat):
                type_name = "Групповой чат"
            elif isinstance(entity, User):
                type_name = "Бот" if entity.bot else "Личный чат"
            else:
                type_name = "Другое"
            
            # Безопасное получение ссылки и дополнительной информации
            username = getattr(entity, 'username', None)
            link = f"https://t.me/{username}" if username else "Приватный чат"
            entity_id = getattr(entity, 'id', None)
            
            # Запись информации
            f.write(f"{type_name}: {dialog.name}\n")
            f.write(f"Ссылка: {link}\n")
            if entity_id:
                f.write(f"ID: {entity_id}\n")
                if isinstance(entity, Channel) and entity.broadcast:
                    f.write(f"Channel ID для API: -100{entity_id}\n")
            f.write("-" * 50 + "\n")
            
            # Прогресс
            print(f"Обработано {i}/{total_dialogs} ({(i/total_dialogs*100):.1f}%)")
            
            # Пауза после каждой пачки
            if i % BATCH_SIZE == 0 and i < total_dialogs:
                print(f"\nПауза на {DELAY_BETWEEN_BATCHES} секунд для безопасности...\n")
                await asyncio.sleep(DELAY_BETWEEN_BATCHES)
    
    print(f"\nГотово! Бэкап сохранен в файл: {filename}")

# Запуск основной функции
client.loop.run_until_complete(main())
EOL
}

# Основная функция
main() {
    clear
    echo "Telegram Channel Backup"
    echo "v1.0 by Zalexanninev15"
    echo "MIT License"
    echo "Начинаем настройку..."
    
    # Проверяем зависимости
    check_dependencies
    
    # Создаем директорию с бэкапом
    setup_directory
    
    # Создаём скрипт
    create_python_script
    
    # Экспортируем переменные окружения
    export TELEGRAM_API_ID="$TELEGRAM_API_ID"
    export TELEGRAM_API_HASH="$TELEGRAM_API_HASH"
    export TELEGRAM_PHONE="$TELEGRAM_PHONE"
    
    # Запускаем скрипт
    echo "Запускаем экспорт данных..."
    python3 ./telegram_export.py
}

# Запускаем скрипт
main