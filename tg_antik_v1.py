import asyncio
import re
import argparse
from pathlib import Path

import python_socks
from telethon import TelegramClient, functions, errors
from telethon.tl.types import Channel, Chat, User
from telethon.errors import (
    ChannelPrivateError,
    InviteHashInvalidError,
    InviteHashExpiredError,
    UserNotParticipantError
)

# -------------------------------------------------
# 🔑 ЗАПОЛНИТЕ СВОИ ДАННЫЕ
API_ID = 3928392989         # ← замените на ваш api_id (число)
API_HASH = ""  # ← ваш api_hash (строка)
SESSION_NAME = "session"

proxy=None # Лучше использовать прокси. Пример указан ниже.
# Заполните данную строку, если хотите прокси юзать
#proxy = {
#    'proxy_type': python_socks.ProxyType.HTTP, # (mandatory) protocol to use
#    'addr': 'ваш ip',      # (mandatory) proxy IP address
#    'port': 8080,           # (mandatory) proxy port number
#    'username': 'username',      # (optional) username if the proxy requires auth
#    'password': 'p@ssw0rd',      # (optional) password if the proxy requires auth
#    'rdns': True            # (optional) whether to use remote or local resolve, default remote
#}
# -------------------------------------------------

# Файлы
RKN_PATH = Path("rkn.txt")
RKN_NUM_PATH = Path("rkn_num.txt")
VERIFIED_PATH = Path("verified.txt")

# Регулярки (ключевые слова для поиска в описании канала)
RKN_WORD_PATTERN = re.compile(r"\b(ркн|реестр|gosuslugi|в перечень|gov\.ru)\b", re.IGNORECASE) # Реестр
RKN_NUM_PATTERN = re.compile(r"№\s*[\d\w]{2,}", re.IGNORECASE) # №

# Нормализация входных ссылок
def normalize_input_link(link: str) -> str | None:
    link = link.strip()
    if not link:
        return None
    # Invite-ссылки оставляем как есть
    if "/+" in link or link.startswith("+"):
        if link.startswith("+"):
            return f"https://t.me/{link}"
        return link
    # Извлечение username
    orig = link
    if link.startswith(("https://", "http://")):
        link = link.split("://", 1)[1]
    for prefix in ["telegram.dog/", "telegram.me/", "t.me/s/", "t.me/"]:
        if link.startswith(prefix):
            link = link[len(prefix):]
    if link.startswith("@"):
        link = link[1:]
    link = link.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if link and link.replace("_", "").replace("-", "").isalnum():
        return link
    else:
        print(f"⚠️ Не удалось нормализовать: {orig}")
        return None

async def get_channels_from_file() -> list[str]:
    input_path = Path("channels.txt")
    if not input_path.is_file():
        print("❌ Файл channels.txt не найден")
        return []
    raw = [line.strip() for line in input_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    targets = []
    for line in raw:
        target = normalize_input_link(line)
        if target:
            targets.append(target)
        else:
            print(f"⚠️ Пропущена недопустимая ссылка: {line}")
    return targets

async def get_subscribed_channels(client) -> list[str]:
    print("📥 Получение списка подписок...")
    dialogs = await client.get_dialogs(limit=None)
    targets = []
    for dialog in dialogs:
        ent = dialog.entity
        if isinstance(ent, Channel) and hasattr(ent, 'username') and ent.username:
            targets.append(ent.username)
        elif isinstance(ent, Channel):
            # Канал без username — используем ID (но get_entity не примет ID напрямую из списка)
            # Поэтому пропускаем — обработка только по username или invite-ссылке
            pass
    print(f"✅ Найдено {len(targets)} публичных каналов в подписках")
    return targets

async def process_channel(client, target: str, f_rkn, f_num, f_ver, delay: float):
    try:
        entity = await client.get_entity(target)

        # Отображаемое имя
        real_name = getattr(entity, 'title', '') or getattr(entity, 'first_name', '') or 'Без названия'
        username = getattr(entity, 'username', None)
        display_name = f"{real_name} (@{username})" if username else f"{real_name} (ID: {entity.id})"

        is_channel = isinstance(entity, Channel)
        is_chat = isinstance(entity, Chat)
        is_user = isinstance(entity, User)

        if not (is_channel or is_chat):
            print(f"ℹ️ {display_name} — не канал и не чат, пропускаем")
            return

        is_verified = False
        description = ""

        if is_channel:
            is_verified = bool(getattr(entity, 'verified', False))
            try:
                full = await client(functions.channels.GetFullChannelRequest(entity))
                description = full.full_chat.about or ""
            except (ChannelPrivateError, InviteHashInvalidError, InviteHashExpiredError):
                description = "🔒 Приватный канал, описание недоступно"
        elif is_chat:
            try:
                full = await client(functions.messages.GetFullChatRequest(chat_id=entity.id))
                description = getattr(full.full_chat, 'about', "") or ""
            except Exception:
                description = ""

        # title = real_name or ""

        has_rkn_word =bool(RKN_WORD_PATTERN.search(description))
        has_rkn_num = bool(RKN_NUM_PATTERN.search(description))

        channel_type = 0

        # Запись в нужные файлы
        if has_rkn_word and username:
            f_rkn.write(f"{username}\n")
            channel_type |= 1

        if has_rkn_num and username:
            f_num.write(f"{username}\n")
            channel_type |= 2

        if is_verified and username:
            f_ver.write(f"{username}\n")
            channel_type |= 4

        printed = False

        # Только для лога
        match channel_type:
            case 3:
                print(f"🔴🟠 {display_name} → Реестр + №")
                printed = True
            case 5:
                print(f"🔴🔵 {display_name} → Реестр + Верифицирован")
                printed = True
            case 6:
                print(f"🟠🔵 {display_name} → № + Верифицирован")
                printed = True
            case 7:
                print(f"🔴🟠🔵 {display_name} → Реестр + № + Верифицирован")
                printed = True
            case 0:
                print(f"⚪ {display_name} — не в категориях (требуется ручная проверка на A+)")
                printed = True

        if not printed:
            if channel_type & 1:
                print(f"🔴 {display_name} → Реестр")
            if channel_type & 2:
                print(f"🟠 {display_name} → №")
            if channel_type & 4:
                print(f"🔵 {display_name} → Верифицирован")

        await asyncio.sleep(delay)

    except (InviteHashInvalidError, InviteHashExpiredError, ChannelPrivateError):
        print(f"🔒 Недоступен (приватный/истёк): {target}")
    except Exception as exc:
        print(f"❗ Ошибка при обработке {target}: {exc}")

async def unsubscribe_from_channels(client, targets: set[str], delay: float):
    if not targets:
        print("📭 Нет каналов для отписки")
        return

    print(f"🗑️ Попытка отписаться от {len(targets)} каналов...")
    unsubscribed = 0
    for target in targets:
        try:
            entity = await client.get_entity(target)
            if isinstance(entity, Channel):
                await client(functions.channels.LeaveChannelRequest(entity))
                print(f"✅ Отписался от {target}")
                unsubscribed += 1
            else:
                print(f"ℹ️ {target} — не канал, пропускаем")
        except UserNotParticipantError:
            print(f"ℹ️ {target} — вы не участник, пропускаем")
        except Exception as e:
            print(f"❌ Не удалось отписаться от {target}: {e}")
        await asyncio.sleep(delay)

    print(f"✔️ Успешно отписались от {unsubscribed} каналов")

async def main():
    parser = argparse.ArgumentParser(
        prog='tg_antik',
        description="TG AntiK v1.0 rev.3 by Zalexanninev15 — Анализ и отписка от Telegram-каналов",
        epilog="Примеры:\n"
               "  python tg_antik.py --list --save\n"
               "  python tg_antik.py --save --kill 0\n"
               "  python tg_antik.py --kill 3\n"
               "  python tg_antik.py --time 2.0",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('--list', action='store_true',
                        help='Анализировать из channels.txt (вместо подписок)')
    parser.add_argument('--save', action='store_true',
                        help='Дописывать в файлы, не очищая их (файлы создаются при необходимости)')
    parser.add_argument('--kill', type=int, choices=[0, 1, 2, 3],
                        help='Отписаться после анализа:\n'
                             '  0 — всё (RKN + Verified + №)\n'
                             '  1 — только RKN (слова)\n'
                             '  2 — только Verified\n'
                             '  3 — только № (rkn_num.txt)')
    parser.add_argument('--time', type=float, default=1.0,
                        help='Задержка между запросами (по умолчанию: 1.0)')
    args = parser.parse_args()

    client = TelegramClient(SESSION_NAME, API_ID, API_HASH, proxy=proxy)

    await client.start()
    print("✅ Подключение установлено!")

    # Этап 1: Анализ (если нужно)
    need_analysis = (
        args.kill is None or
        args.list or
        not (RKN_PATH.exists() or RKN_NUM_PATH.exists() or VERIFIED_PATH.exists())
    )

    if need_analysis:
        if not args.save:
            RKN_PATH.write_text("", encoding="utf-8")
            RKN_NUM_PATH.write_text("", encoding="utf-8")
            VERIFIED_PATH.write_text("", encoding="utf-8")

        if args.list:
            print("📂 Режим: чтение из channels.txt")
            targets = await get_channels_from_file()
        else:
            print("📬 Режим: анализ подписок")
            targets = await get_subscribed_channels(client)

        if targets:
            print(f"🔎 Обработка {len(targets)} каналов...")
            with open(RKN_PATH, "a", encoding="utf-8") as f_rkn, \
                 open(RKN_NUM_PATH, "a", encoding="utf-8") as f_num, \
                 open(VERIFIED_PATH, "a", encoding="utf-8") as f_ver:
                for target in targets:
                    await process_channel(client, target, f_rkn, f_num, f_ver, args.time)
        else:
            print("❌ Нет каналов для обработки")
    else:
        print("⏭️ Пропуск анализа — используются существующие файлы")

    # Этап 2: Отписка
    if args.kill is not None:
        print("\n🔄 Загрузка списков для отписки...")

        def load_set(path):
            return {line.strip().lower() for line in path.read_text(encoding="utf-8").splitlines()} if path.is_file() else set()

        rkn = load_set(RKN_PATH)
        rkn_num = load_set(RKN_NUM_PATH)
        verified = load_set(VERIFIED_PATH)

        targets = set()
        if args.kill == 0:
            targets = rkn | rkn_num | verified
        elif args.kill == 1:
            targets = rkn
        elif args.kill == 2:
            targets = verified
        elif args.kill == 3:
            targets = rkn_num

        await unsubscribe_from_channels(client, targets, args.time)

    await client.disconnect()
    print("✅ Завершено")

if __name__ == "__main__":
    asyncio.run(main())