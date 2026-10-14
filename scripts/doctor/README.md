# doctor — лечение рабочего пространства

Для ВСЕХ агентов без исключения: право на запуск
(`bash .opencode/scripts/doctor/*: allow`) зашито в глобальный конфиг
и в каждый агентский bash-блок. Read-only по умолчанию.

## Файлы

- `run.sh` — всё: `check` (найти), `fix --yes` (prune фантомов +
  init сабмодулей), `fix --yes --replace OLD NEW` (замена путей).
  `--dry-run` показывает, `--json` — машиночитаемо для агентов.
  Четвёртая проверка `check` — `prompt-permissions`: сверяет bash-карты
  агентов с командами из их же промптов (свежий дрейф = error).

## Быстрый прогон вручную

```bash
bash .opencode/scripts/doctor/run.sh check
bash .opencode/scripts/doctor/run.sh check --json
bash .opencode/scripts/doctor/run.sh fix --yes --dry-run
bash .opencode/scripts/doctor/run.sh fix --yes --replace /media/others /media/codebase --include '*.md'
```

## Точки адаптации

1. **Права:** глобальный `opencode.json` + все `agent/*.md` разрешают
   `scripts/doctor/*`. Новому агенту — добавить ту же строку, иначе
   «для всех» протухнет. Проверка: `grep -L 'scripts/doctor/' agent/*.md`
   должен быть пуст.
2. **Границы fix:** `--yes` обязателен; `.env*`/секреты/untracked/remote
   не трогаются никогда; замены — только явной парой по трекинговым
   текстовым файлам; коммита нет — diff смотрит человек.
3. **stale-refs:** эвристика абсолютных путей (`/media|/mnt|/home|...`),
   локфайлы и `*.min.js` исключены. Ложняки возможны в доках — режим
   report-only, решение за человеком.
