---
name: react-fix
description: Fix React components (markup + styles) by CSS class name via .opencode/scripts/react-fix/find-class.sh. Use when any agent needs to locate a class in tsx/css, clarify an imprecise fix request, or apply a minimal confirmed style/markup change.
---

Ты умеешь качественно чинить React-компоненты через скрипты пака, а не
через ручной grep. Все команды — из корня проекта. Если в сессии доступен
агент `@react-fix` — предпочтителен он (у него весь workflow в промпте);
этот скилл — для остальных случаев и для проверки чужой работы.

## Предпосылки

- Конвенции consumer-проекта — из его `AGENTS.md` / `CLAUDE.md`
  (слои, нейминг, команды проверки). Правки — в них, проверка — его
  `package.json` scripts. Своих команд не выдумываешь.
- Имя класса — с точкой или без (`.journal` == `journal`).

## Рецепты (порядок важен)

1. Поиск (только чтение, подтверждения не надо) — ВСЕГДА скриптом:
   `bash .opencode/scripts/react-fix/find-class.sh --class <имя> [--class ...] [--root <dir>]`
   Вывод — блоки `== class: X ==` + таблица `FILE | LINE | KIND | TEXT`
   (`markup` — ts/tsx/js/jsx, `style` — css/scss/sass/less) + итог
   `=> X: M matches in N files`. Таблицу показываешь пользователю как есть.
2. Непонятно что/где править — спрашиваешь (question tool), не правишь.
   Классика: «блок `.journal` — отсутствуют пунктиры от Самара до Берлин»:
   показываешь, где `.journal` живёт, и уточняешь элемент (tsx или css),
   какой пунктир и что в оригинале. Без ответа — никаких `edit`.
3. Правка (мутация — только после явного «что менять» + «где»):
   точечно, только подтверждённые файлы, только попрошенное свойство.
   CSS-модули — парой (`styles.x` + класс в css); BEM-детей без просьбы
   не трогаешь. Каждый пункт чеклиста — за своим «да», не скопом.
4. Проверка — командами проекта (typecheck/lint/test, что есть).
   Чужое упавшее не чинишь — показываешь вывод и останавливаешься.

## Правила качества

- Поиск классов — только `find-class.sh`. Сырой `grep`/`rg` — для всего
  остального (компоненты, импорты, пропсы), но не для классов: скрипт даёт
  точный класс + BEM-детей и отсекает подстроки (`journal` ≠ `journalism`).
- `0 matches` — не гадаешь, а идёшь по подсказке скрипта: написание,
  BEM-суффикс, другой `--root`, класс генерируется кодом. Имена файлов
  и строк — только из таблицы, никогда из головы.
- camelCase-ключи CSS-модулей (`styles.journalTitle`) — отдельные имена:
  их ищешь прямым `--class journalTitle`, а не через `journal`.
- Коммиты/пуш — не твои: изменения — через `/commit`, отправка — `/push`.

## Типичная связка

```bash
# Запрос: "блок .journal — нет пунктиров от Самара до Берлин"
bash .opencode/scripts/react-fix/find-class.sh --class journal
# → таблица пользователю → вопрос «какой элемент и что в оригинале?» →
# → «да, правь .journal__route в journal.module.css:12» → edit → проверка
#   командами проекта (например: pnpm typecheck && pnpm lint)

# Чеклист из нескольких блоков — по одному классу за раз:
bash .opencode/scripts/react-fix/find-class.sh --class journal --class header
```
