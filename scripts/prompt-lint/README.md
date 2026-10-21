# prompt-lint — линтер запрещённых форм в промптах

## Зачем

Аудит из 6 человек пропустил обучение запрещённым формам: в `agents/`,
`skills/`, `commands/` остались примеры, которые агенты копируют в работу
(пайпы в `head`/`tail`, shell-цепочки `&&`/`||`, голый `git status/log/diff/branch`
без `--`-флага, сырой `gh pr` вместо `scripts/pr`). Глазами такое не ловится —
ловит машина: этот скрипт построчно сканирует промпты и флагает бектиковые
примеры до того, как они уедут в копипасту.

## Контракт

- **Сканируемые пути** (от корня consumer-репо):
  `<root>/agents/*.md`, `<root>/skills/*/SKILL.md`, `<root>/commands/*.md`.
  Default root — `git rev-parse --show-toplevel`; для тестов — `--root <path>`.
- **4 правила** (флагать построчно, только бектиковые спаны; просто
  упоминание слов без бектиков не флагается):
  - R1 pipes: span matches `` `[^`]*\|\s*(head|tail|grep|awk|sed|cut|sort|xargs|tee)\b `` —
    пайп именно в команду. Прозаические `|` без команды
    (`AKIA|sk-live` в регексах, «без пайпов») не флагать.
    Пример да: `` `cmd 2>&1 | head -20` ``; пример нет: `` `AKIA|sk-live` ``.
  - R2 chains: span содержит `&&` или `||` И (начинается с известной команды
    `^(git|bash|docker|npm|pnpm|npx|bun|make|cat|ls|cd|gh|curl|python3|pytest|go|cargo|echo|mkdir|rm|cp|mv|tree)\s`
    ИЛИ содержит `--` ИЛИ содержит `/`). Голые `stage_a && stage_b`,
    `need_deploy && deploy_host`, `${{a||b}}`, сами запреты «без `&&`» — не флагать.
    Пример да: `` `git status --short && echo done` ``;
    пример нет: `` `stage_a && stage_b` ``.
  - R3 bare git: ТОЛЬКО точный голый спан `` `git (status|log|diff|branch|rev-parse)` ``
    (между бектиками ничего кроме команды).
    `git diff HEAD`, `git log --oneline`, `a/b`-списки, `-D`-флаги — не флагать.
    Пример да: `` `git status` ``; пример нет: `` `git diff HEAD` ``,
    `` `git log --oneline` ``.
  - R4 raw gh: `` `gh\s+pr\b `` без изменений.
    Пример да: `` `gh pr list` ``.
- **Accepted gap:** цепочки из несуществующих команд (`deploy && restart`)
  не ловятся R2 — они и не выполнятся нигде, осознанный пробел.
- **Пропуски** (не нарушения, не флагать):
  - строки с `→` — таблицы замен «было → стало»;
  - спаны содержащие `${{` — GitHub Actions expressions, не shell (во всех R1–R4);
  - строки с ЛЮБОЙ подстрокой из `waivers.txt` (рядом, по одной подстроке
    на строку, сравнение literal contains).
- **Выход:** stdout — всегда JSON
  `{"violations":[{"file","line","text"}],"count"}` (даже при 0);
  stderr — human hint (тихо при `--json`).
- **Exit-коды:** `0` — чисто; `1` — есть нарушения; `2` — ошибка
  использования / нет каталогов / нет файлов для сканирования.

## Пример запуска

```bash
bash .opencode/scripts/prompt-lint/run.sh --json
bash .opencode/scripts/prompt-lint/run.sh --root /tmp/fake-root --json
```

## Пример нарушения

Промпт содержит строку:

````markdown
Проверь `git status --porcelain` пуст, затем `cmd 2>&1 | head -20`.
````

Вывод (`--json`):

```json
{
  "violations": [
    {"file": "agents/example.md", "line": 12, "text": "Проверь `git status --porcelain` пуст, затем `cmd 2>&1 | head -20`."}
  ],
  "count": 1
}
```

`git status --porcelain` здесь чист (есть `--`), а `| head -20` в бектиках —
нарушение правила 1. Правится сам пример в промпте (убрать пайп / заменить
на детерминированный скрипт), exit станет 0.

## Связь со скиллами

Правится **промпт, не waivers**: нашёл нарушение — перепиши пример
в `agents/`/`skills/`/`commands/` так, чтобы запрещённой формы не было.
`waivers.txt` — только для мета-упоминаний о правилах (строки вида
`без \`&&\` / \`||\` / \`;\` / \`|\``), а не для отмазки живых примеров.
Новый waiver добавляется только если строка описывает правило, а не учит
запрещённому приёму.
