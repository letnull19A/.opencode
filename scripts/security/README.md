# security — валидация входных/выходных данных (фронт + бэк)

Реализация философии пака: **правила — в коде guard, думает только
аудитор, утверждает человек**. Первый инструмент отдела безопасности —
валидаторы I/O: фронт и бэк валидируют данные на границах, опасные
приёмники запрещены.

## Конвенция (обязательна для всего нового кода)

- **Вход бэка:** каждый API-хендлер валидирует тело/query/params готовой
  schema до бизнес-логики: `zod` (`.safeParse`/`.parse`, tRPC/router),
  `pydantic` (`BaseModel`), `go-playground/validator`, `DTO` +
  `class-validator`, `marshmallow` serializers. Сырой `req.body` в логику
  не идёт.
- **Выход бэка:** ответы сериализуются через те же schemas (никогда сырые
  строки/объекты БД наружу — ни лишних полей, ни внутренних ошибок/stracktrace).
- **Вход фронта:** формы валидируются тем же schemas, что API
  (`zodResolver`/`yupResolver`, общий пакет схем монорепо). Рендер
  пользовательского HTML — только через санитайзер (DOMPurify), никаких
  `dangerouslySetInnerHTML`/`innerHTML=` с сырыми данными.
- **SQL/шелл:** только параметризованные запросы и вызовы без `shell=True`;
  конкатенация строк в запрос — запрет (исключение помечается `sec:ignore`
  с причиной, что значение не из входа).

## Файлы

- `guard.sh` — guardrail перед коммитом: сверяет только незакоммиченные
  изменения (error: `dangerous-sink`; warn: `sql-concat`,
  `unvalidated-input`, `unvalidated-form`). Пропускает комментарии,
  тесты/моки/сиды/фикстуры/сториз и строки с `sec:ignore`.
  stdout — только JSON, exit 0 чисто / 1 error (коммит только после явного
  approve человека) / 2 не git. Прогоняется для КАЖДОГО коммита
  (фронт и бэк), см. `skills/commit/SKILL.md`.
- `README.md` — этот файл (конвенция выше).

## Быстрый прогон вручную (без opencode, для проверки скрипта)

```bash
bash .opencode/scripts/security/guard.sh
bash .opencode/scripts/security/guard.sh --staged --json
```
