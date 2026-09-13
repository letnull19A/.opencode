---
name: module-develop
description: Develop a module end-to-end via one of the add/update/delete/decompose strategies: spec → planning → tests → implementation → verification, delegating tests to @unit-test and implementation of updates to @refactor. Use when the user starts `/new-module` or asks to create/add/update/delete/decompose a module in the repo.
---

Ты проводишь модульную разработку по стратегиям add/update/delete/decompose
(те же стратегии, что у платформы-оркестратора opencode-workflow; этот навык —
портируемый близнец `ModulePipeline`). Все команды — из корня проекта.

## 0. Детекция стратегии (приоритет: decompose > delete > update > add)

Из текста задачи/имени модуля (`$ARGUMENTS`):
- decompose: «разбить», «разнести», «разделить», «вынести», «измельчить».
- delete: «удалить», «выпилить», «убрать модуль», «снести».
- update: «обновить», «изменить», «дополнить», «починить», «улучшить»,
  «добавить фичу/файл в существующий модуль», «расширить».
- add: иначе — новый модуль («создать модуль X», «добавить модуль X»,
  «завести auth»).

## 1. Детекция домена (только по файлам проекта, не из головы)

- nestjs: есть `nest-cli.json` / `@nestjs` в `package.json`.
- dotnet: есть `*.csproj` / `*.sln`.
- frontend: `package.json` с react/vue/svelte или `vite.config.*`/`next.config.*`.
- general: ничего из перечисленного.

## 2. Карта фаз

| Стратегия | Фазы |
|---|---|
| add | spec → planning → tests → implementation → verification |
| update | tests → implementation → verification |
| delete | implementation → verification |
| decompose | spec → planning → implementation → verification |

## 3. Выполнение фаз

- **spec**: изучи структуру проекта и соседние модули (как устроен похожий
  модуль — конвенции именования, файлы); напиши `SPEC.md` (цель, требования,
  acceptance criteria). Покажи пользователю — жди явного «да».
- **planning**: напиши `PLAN.md` (полный список файлов: создать/изменить,
  ответственность каждого, порядок). Покажи — жди явного «да».
- **tests**: делегируй `@unit-test` — тесты на SPEC/PLAN. Для add сначала
  красный прогон — нормально (TDD).
- **implementation**: add — реализуешь сам (`build`); update/delete/decompose —
  делегируй `@refactor`. Не ломай контракт тестов: они берутся из **tests**,
  а не переписываются под код.
- **verification**: запусти реальный раннер проекта (jest/vitest/pytest/
  `dotnet test` — определяй по манифестам, не выдумывай). Все зелёные →
  `done`. Красные → возврат: add/update → **tests**, delete/decompose →
  **implementation**. Бюджет возвратов — `PIPELINE_MAX_RETRIES` (env, дефолт 3);
  исчерпан → `failed`.

## Правила

- Компактный план (стратегия, домен, фазы) — показать **до любых правок**;
  мутации после явного «да».
- Синтаксис фреймворка — только из манифестов проекта / Context7, не из памяти.
- git не трогаешь (коммиты — только `/commit`, пуш — только `/push`);
  секреты в файлы не пишешь.
- Финал — краткий отчёт: стратегия, домен, пройденные фазы, результат
  (`done`/`failed`), созданные артефакты (SPEC.md/PLAN.md/список файлов).