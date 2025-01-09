#!/bin/bash

# Вставьте свои данные
TELEGRAM_API_ID=""
TELEGRAM_API_HASH=""
TELEGRAM_PHONE=""
TELEGRAM_CHANNEL_ID=""  # ID вашего канала (начинается с -100) можно взять отсюда @JsonBot
GROQ_API_KEY=""

# Проверяем наличие необходимых зависимостей
check_dependencies() {
    command -v python3 >/dev/null 2>&1 || { echo "Требуется Python3. Установите командой: pkg install python"; exit 1; }
    command -v pip >/dev/null 2>&1 || { echo "Требуется pip. Установите командой: pkg install python-pip"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "Требуется curl. Установите командой: pkg install curl"; exit 1; }
    python3 -c "import telethon" >/dev/null 2>&1 || { echo "Установка Telethon..."; pip install telethon; }
    python3 -c "import requests" >/dev/null 2>&1 || { echo "Установка requests..."; pip install requests; }
}

# Создаём директории в текущей папке
setup_directories() {
    mkdir -p ./{data,output}
}

# Создаём Python скрипт для получения постов
create_python_script() {
    cat > ./get_posts.py << EOF
from telethon import TelegramClient, sync
from telethon.errors import SessionPasswordNeededError
import json
import os
from datetime import datetime

# Данные для входа
api_id = '$TELEGRAM_API_ID'
api_hash = '$TELEGRAM_API_HASH'
phone = '$TELEGRAM_PHONE'
channel_id = int('$TELEGRAM_CHANNEL_ID')

# Создаём клиент и входим в систему
client = TelegramClient('tg_session', api_id, api_hash)
client.connect()

# Если сессия не авторизована
if not client.is_user_authorized():
    client.send_code_request(phone)
    code = input('Введите код подтверждения из Telegram: ')
    try:
        client.sign_in(phone, code)
    except SessionPasswordNeededError:
        password = input('Введите пароль двухфакторной аутентификации: ')
        client.sign_in(password=password)

async def main():
    try:
        channel = await client.get_entity(channel_id)
        posts = []
        
        print("Получение постов...")
        message_count = 0
        async for message in client.iter_messages(channel):
            if message.text:
                post = {
                    'id': message.id,
                    'date': message.date.strftime('%Y-%m-%d'),
                    'text': message.text,
                    'link': f'https://t.me/c/{str(channel_id)[4:]}/{message.id}'
                }
                posts.append(post)
                message_count += 1
                if message_count % 10 == 0:
                    print(f"Получено постов: {message_count}")
        
        print(f"Всего получено постов: {len(posts)}")
        with open('./data/posts.json', 'w', encoding='utf-8') as f:
            json.dump(posts, f, ensure_ascii=False, indent=2)
            
    except Exception as e:
        print(f"Ошибка при получении постов: {e}")
        exit(1)

client.loop.run_until_complete(main())
EOF
}

# Создаём Python скрипт для категоризации с помощью Groq
create_categorization_script() {
    cat > ./categorize.py << EOF
import json
import requests
import os
from time import sleep
import random
from datetime import datetime, timedelta
import sys

GROQ_API_KEY = '$GROQ_API_KEY'

def get_category(text, retry_count=0):
    if retry_count >= 5:
        print(f"Достигнут лимит попыток для поста. Пропускаем...")
        return "Без категории"
        
    prompt = f"""Проанализируй следующий текст и определи одну основную категорию для него. Тематика - 
    
    Текст:
    {text[:500]}

    Верни только название категории, без дополнительного текста.
    """
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {GROQ_API_KEY}"
    }
    
    data = {
        "messages": [{"role": "user", "content": prompt}],
        "model": "llama-3.3-70b-versatile",
        "temperature": 0.5,
        "max_tokens": 50,
        "top_p": 1,
        "stream": False,
        "stop": None
    }
    
    try:
        response = requests.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers=headers,
            json=data
        )
        
        if response.status_code == 429:  # Too Many Requests
            wait_time = 60 + random.randint(10, 30)  # Случайная задержка от 60 до 90 секунд
            print(f"Достигнут лимит запросов. Ожидаем {wait_time} секунд...")
            sleep(wait_time)
            return get_category(text, retry_count + 1)
            
        response.raise_for_status()
        category = response.json()["choices"][0]["message"]["content"].strip()
        return category
        
    except requests.exceptions.RequestException as e:
        print(f"Ошибка при обработке поста: {e}")
        if retry_count < 5:
            wait_time = (retry_count + 1) * 30  # Увеличиваем время ожидания с каждой попыткой
            print(f"Повторная попытка через {wait_time} секунд...")
            sleep(wait_time)
            return get_category(text, retry_count + 1)
        return "Без категории"

def save_progress(categorized_posts, last_processed_index):
    with open('./data/progress.json', 'w', encoding='utf-8') as f:
        json.dump({
            'categorized_posts': categorized_posts,
            'last_processed_index': last_processed_index
        }, f, ensure_ascii=False, indent=2)

def load_progress():
    try:
        with open('./data/progress.json', 'r', encoding='utf-8') as f:
            return json.load(f)
    except FileNotFoundError:
        return None

print("Загрузка постов...")
with open('./data/posts.json', 'r', encoding='utf-8') as f:
    posts = json.load(f)

# Проверяем наличие сохранённого прогресса
progress = load_progress()
if progress:
    categorized_posts = progress['categorized_posts']
    start_index = progress['last_processed_index'] + 1
    print(f"Загружен сохранённый прогресс. Продолжаем с поста {start_index}")
else:
    categorized_posts = {}
    start_index = 0

total_posts = len(posts)

try:
    for i in range(start_index, total_posts):
        post = posts[i]
        print(f"Обработка поста {i + 1}/{total_posts}")
        
        category = get_category(post['text'])
        if category not in categorized_posts:
            categorized_posts[category] = []
        categorized_posts[category].append(post)
        
        # Сохраняем прогресс каждые 5 постов
        if (i + 1) % 5 == 0:
            save_progress(categorized_posts, i)
        
        # Делаем паузу между запросами
        sleep_time = random.uniform(3, 5)  # Случайная пауза от 3 до 5 секунд
        sleep(sleep_time)

except KeyboardInterrupt:
    print("\nПрерывание пользователем. Сохраняем прогресс...")
    save_progress(categorized_posts, i)
    print("Прогресс сохранён. Вы можете продолжить позже.")
    sys.exit(1)

# Создаём markdown файл
print("Создание итогового документа...")
with open('./output/index.md', 'w', encoding='utf-8') as f:
    f.write('# Каталог постов канала\n\n')
    
    # Добавляем информацию о времени создания
    f.write(f"Обновлено: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n")
    
    # Записываем оглавление
    f.write('## Содержание\n\n')
    for category in sorted(categorized_posts.keys()):
        count = len(categorized_posts[category])
        f.write(f"- [{category}](#{category.lower().replace(' ', '-')}) ({count} постов)\n")
    
    f.write('\n---\n\n')
    
    # Записываем категории с постами
    for category, posts in sorted(categorized_posts.items()):
        f.write(f'\n## {category}\n\n')
        post_count = len(posts)
        f.write(f"Всего постов в категории: {post_count}\n\n")
        for post in sorted(posts, key=lambda x: x['date'], reverse=True):
            title = post['text'].split('\n')[0][:100]
            if len(post['text'].split('\n')[0]) > 100:
                title += '...'
            f.write(f"- [{title}]({post['link']}) ({post['date']})\n")

print("Готово! Результат сохранён в ./output/index.md")
EOF
}

# Основная функция
main() {
    clear
    echo "Telegram Channel Parser with Croq"
    echo "v1.0 by Zalexanninev15"
    echo "MIT License"
    echo "Начинаем настройку..."
    check_dependencies
    setup_directories
    create_python_script
    create_categorization_script
    
    echo "Скрипты созданы. Выполняем..."
    echo "1. Получение постов из Telegram..."
    python3 ./get_posts.py
    echo "2. Категоризация постов..."
    python3 ./categorize.py
}

# Запускаем скрипт
main