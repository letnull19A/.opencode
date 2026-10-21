# git-recon — read-only разведка git для ИИ-агентов.

Зачем: сырые `git rev-parse/branch/fetch/merge`, составные `&&/;/|` и голые
`git log/status` без аргументов дают `Permission denied: shell` или ломают
linear-history. Этот скрипт собирает то же самое за один вызов, мутаций нет.

Команды (stdout — JSON, stderr — hint; `--json` — тихо):
  status / log / base / whereami / verify
См. шапку run.sh и скиллы skills/git-recon, skills/branch-work.

Вызывать только как `bash .opencode/scripts/git-recon/run.sh <cmd> [...]`
из любого места внутри репо. Не править скрипт руками агента-исполнителя:
runner-скиллы скрипты не чинят (см. skills/script-runner).
