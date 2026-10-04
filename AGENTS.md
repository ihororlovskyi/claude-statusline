# claude-statusline

Кастомний статуслайн для Claude Code. Один скрипт `statusline.sh` обслуговує і головний статуслайн (`statusLine`), і рядки панелі агентів (`subagentStatusLine`).

## Файли

| Файл | Що це |
|---|---|
| `statusline.sh` | Сам статуслайн. POSIX `sh` + `jq` + `awk`, запускається через `bash` |
| `install.sh` | Інсталятор: кладе скрипт у `~/.claude/` і прописує обидва ключі в `settings.json` через `jq` |
| `README.md` | Документація англійською |

## Як працює `statusline.sh`

Режим визначається за stdin:

- **є `.tasks`** - payload панелі агентів. На кожне завдання виводиться JSON-рядок `{"id": ..., "content": ...}`. Для не-`running` завдань `content` порожній, і рядок ховається.
- **інакше** - payload головного статуслайну, багаторядковий вивід з ANSI-кольорами.

Важливі нюанси панелі агентів:

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

Репозиторій приватний, тому `install.sh` тягне raw-файли з токеном (`GITHUB_TOKEN` або `gh auth token`). Якщо поруч з `install.sh` лежить `statusline.sh` (запуск з клону), скрипт копіює локальний файл без мережі. Перед перезаписом робляться `.bak` для `statusline.sh` і `settings.json`.

## Перевірка змін

Мінімальний smoke-тест обох режимів:

```sh
echo '{"cwd":"/tmp","model":{"display_name":"Opus"}}' | bash statusline.sh
echo '{"transcript_path":"/nonexistent.jsonl","tasks":[{"id":"x","status":"running","label":"test","tokenCount":7981,"model":"claude-sonnet-5-5","contextWindowSize":1000000}]}' | bash statusline.sh
```

Після правок у репо онови встановлену копію: `sh install.sh`.
