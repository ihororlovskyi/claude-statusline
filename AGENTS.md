# claude-statusline

Кастомний статуслайн для Claude Code: `scripts/statusline.sh` малює головний статуслайн (`statusLine`), `scripts/subagent-statusline.sh` - рядки панелі агентів (`subagentStatusLine`).

## Файли

| Файл | Що це |
|---|---|
| `scripts/statusline.sh` | Головний статуслайн. POSIX `sh` + `jq` + `awk`, запускається через `bash` |
| `scripts/subagent-statusline.sh` | Рядки панелі агентів, ті самі залежності |
| `install.sh` | Інсталятор: кладе обидва скрипти в `~/.claude/` і прописує обидва ключі в `settings.json` через `jq` |
| `README.md` | Документація англійською |

## Як працює

- `scripts/statusline.sh` отримує payload головного статуслайну й виводить кілька рядків з ANSI-кольорами.
- `scripts/subagent-statusline.sh` отримує payload з `tasks[]` і на кожне завдання виводить JSON-рядок `{"id": ..., "content": ...}`. Для не-`running` завдань `content` порожній, і рядок ховається.

Нюанси головного статуслайну:

- Рядки `sess` / `week` малюються лише коли є `rate_limits` (підписки Pro/Max). На Enterprise/Team їх немає, і замість них показується `usage:` з часом до 1-го числа (00:00 UTC). Якщо є `~/.claude/usage-cache.json` (його пише опційний `~/.claude/usage-fetch.js`, якого в репо немає), то показується шкала `used:` з витратами за місяць.

Нюанси панелі агентів:

- Поля з `jq` розділяються `\037`, а не табом. `read` склеює підряд кілька табів, і порожні поля (наприклад, відсутній `model`) зсуваються.
- Вартості в payload немає. Її рахує `jq` з `usage` у транскрипті агента (`<session>/subagents/agent-<id>.jsonl`), з дедуплікацією за `message.id`. Таблиця цін (`def price`) жорстко прописана й береться з https://platform.claude.com/docs/en/about-claude/pricing. Оновлюй її, коли виходять нові моделі чи змінюються ціни.
- Кольори токенів ті самі, що в рядку `cntx`: зелений до 50%, жовтий від 50%, червоний від 80% від `contextWindowSize` агента.
- Фонові shell'и в payload не потрапляють, показати їх рядками неможливо.

## Кольори

Тримай узгодженими з головним статуслайном:

- модель - `\033[0;35m` (пурпуровий);
- вартість - `\033[0;36m` (бірюзовий);
- підписи й допоміжний текст (`cntx:`, `tok`) - `\033[0;90m` (сірий).

## Інсталяція

Репозиторій публічний: `install.sh` тягне raw-файли з `raw.githubusercontent.com` без токена. Якщо скрипт запущено з клону (поруч лежить `scripts/statusline.sh`), файли копіюються локально без мережі. Перед перезаписом робляться `.bak` для обох скриптів і `settings.json`. Новий файл для встановлення додавай у `FILES` в `install.sh` (файли беруться з `scripts/`).

## Перевірка змін

Мінімальний smoke-тест обох режимів:

```sh
echo '{"cwd":"/tmp","model":{"display_name":"Opus"}}' | bash scripts/statusline.sh
echo '{"transcript_path":"/nonexistent.jsonl","tasks":[{"id":"x","status":"running","label":"test","tokenCount":7981,"model":"claude-sonnet-5-5","contextWindowSize":1000000}]}' | bash scripts/subagent-statusline.sh
```

Після правок у репо онови встановлену копію: `sh install.sh`.
