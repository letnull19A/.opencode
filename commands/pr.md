---
description: PR под управлением скриптов — /pr --new (создать), /pr --update [number] (обновить), /pr --list (список со статусами)
agent: build
---

Ты — исполнитель команды `/pr`. Ты думаешь над содержимым PR (title/body
по JSON-стандарту), исполняешь только скриптами пака. PR никогда не мержишь
(мерж — только человек, см. PR merge rule в `AGENTS.md`).

## Режимы (`$ARGUMENTS`)

- `/pr --new [--base <branch>] [--draft] [--labels "a,b"]` — создать PR текущей ветки.
- `/pr --update [<number>] [--title ...] [--base ...] [--labels ...] [--ready]` — обновить
  существующий (номер явно или PR текущей ветки). Body меняется только через JSON (ниже).
- `/pr --list [--status <lifecycle>] [--filter=open|closed|merged|all] [--author me] [--json]` —
  список PR с живыми статусами (read-only).

## Процедура --list

1. Ровно одна команда: `bash .opencode/scripts/pr/list-prs.sh [--filter ...] [--status ...] [--author me] [--json]`
   (`--filter=open` из сообщения нормализуй в `--filter open`). Скрипт сам считает
   lifecycle по той же лестнице, что `status-pr.sh`.
2. Отвечай СТРОГО по её выводу: таблица + строки `PR: #N <url> | lifecycle=X`.
   `unknown` — «не знаю», а не «всё хорошо». Хочешь детали по конкретному PR —
   `bash .opencode/scripts/pr/status-pr.sh --branch <head из списка>`.
3. `--json` — когда нужен разбор/агрегация, не для красоты.

## Процедура --new

1. Проверь ветку: `git branch --show-current` — совпадает с base (main/master)? Стоп,
   PR из ветки в саму себя не создают. Ветка не запушена (нет upstream)? Сначала
   `bash .opencode/scripts/push/run.sh` — PR требует ветку на remote.
2. Собери `pr.json` по `scripts/pr/schema/pr.schema.json` из diff ветки
   (`git log main..HEAD --oneline`, `git diff main...HEAD --stat`) + провалидируй
   через `validate-pr-data.py`. Текст свободной формой запрещён.
3. `bash .opencode/scripts/pr/create-pr.sh --title "<title>" --json /tmp/pr.json --base <base> [--draft]`.
4. Ретранслируй `PR_URL:` как кликабельную ссылку + короткий snapshot
   `bash .opencode/scripts/pr/status-pr.sh --short` (отвечаешь строго по нему).

## Процедура --update

1. Определи цель: число из аргументов или PR текущей ветки (резолвит сам скрипт).
   Нет открытого PR — скажи создать через `/pr --new`, не выдумывай номер.
2. Что меняется — из сообщения пользователя: title (строка), base/labels/ready (флаги).
   Body — только через новый `pr.json` (схема + `validate-pr-data.py`), иначе не трогай.
3. `bash .opencode/scripts/pr/update-pr.sh [--number N] [--title ...] [--json /tmp/pr.json] [--base ...] [--labels ...] [--ready]`.
4. Ретранслируй `PR_URL:` + свежий `status-pr.sh --short` (строго по выводу).

Правила: `--dry-run` для предпросмотра; gitea-обновление скрипт не умеет (честный exit 2) —
тогда обнови вручную и скажи как; `--force` запрещён; мерж запрещён; `gh`/`glab`/`tea`
напрямую агент не вызывает — только через скрипты (`create-pr.sh` / `update-pr.sh`).
