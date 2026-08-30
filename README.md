# .opencode

Личная конфигурация [opencode](https://opencode.ai): кастомные агенты и зависимости плагинов.

## Состав репозитория

```
.
├── agents/
│   └── refactor.md      # агент для рефакторинга (FSD-монорепа)
├── package.json         # зависимости плагинов (@opencode-ai/plugin)
└── .gitignore
```

## Установка

### 1. Требования

- [opencode](https://opencode.ai/docs) установлен и работает:
  ```sh
  curl -fsSL https://opencode.ai/install | bash
  ```
- Node.js / Bun — для установки зависимостей плагинов.

### 2. Клонировать конфигурацию

**Вариант A — в домашнюю директорию** (конфиг подхватывается как project-scope при запуске opencode из home, либо как основа для ручного копирования):

```sh
git clone git@github.com:letnull19A/.opencode.git ~/.opencode
```

**Вариант B — в конкретный проект** (агенты станут доступны только в нём):

```sh
git clone git@github.com:letnull19A/.opencode.git /path/to/project/.opencode
```

### 3. Установить зависимости плагинов

```sh
cd ~/.opencode            # или /path/to/project/.opencode
npm install               # или bun install
```

### 4. Перезапустить opencode

Конфиг загружается один раз при старте — закройте сессию и запустите opencode заново. Агенты из `agents/` появятся в списке агентов (переключение — Tab / меню агентов).

## Проверка

```sh
opencode agent list       # должен быть виден refactor
```

Если opencode не стартует из-за битого конфига:

```sh
OPENCODE_DISABLE_PROJECT_CONFIG=1 opencode
```

— так можно запуститься без project-конфига и починить файл.

## Обновление

```sh
cd ~/.opencode && git pull && npm install
```

Затем перезапустить opencode.
