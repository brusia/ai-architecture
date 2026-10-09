# ADR-005, приложение: что из контура качества уже есть на схеме

Приложение к [ADR-004](adr-004-quality-assurance-security-observability.md).

## Уже есть на схеме

**Безопасность.** Блокирующее подтверждение человеком обеспечивает инструмент `migration_gate`
(`gate_plugin.gate_tool`): `confirm_gate` не возвращает управление модели без явного подтверждения
инженера. Опасные команды ограничены встроенным обнаружением Hermes с подтверждением пользователем
(`hermes_agent.hermes_terminal`). Численная проверка допусков выполняется в коде, а не в LLM
(`gate_plugin.gate_tolerance`: torch-onnx=1e-4, onnx-engine=1e-2, torch-engine=1e-2). Ответ субагента
имеет строгий формат `{ok, summary, diffs}` и валидируется плагином, а сам субагент работает с
изолированным контекстом (`hermes_agent.hermes_delegate`). От отравления skills защищают двойной approve,
узкая операция `rollback(version)` и технический откат у DevOps (`skillsOwner`, `mlopsReviewer`,
`gateway.gw_rollback`). Утечку memory исключает инвариант Hermes: `memories/` не попадает в дистрибуцию
(`skills_distribution`, view `Prod_Memory_Handling`). Аутентификация и роли заданы через `idp` (SSO по OIDC,
RBAC, git-доступ по SSH и PAT). Данные не покидают контур благодаря self-hosted LLM и on-prem Gateway
(`hermes_llm`, `gateway`, ADR-001). Устойчивость к отказу провайдера даёт `hermes_agent.hermes_fallback`.

**Наблюдаемость.** Стек метрик, логов, трейсов и алертов (Prometheus, Grafana, Loki, Tempo, Alertmanager)
описан системой `obs`. Доля команды на актуальной версии банка skills считается в `gateway.gw_adoption`,
успех и неудача применения skills в `gateway.gw_analytics`. Прогресс миграции записывает
`gate_plugin.gate_state` в `MIGRATION_STATE.md`.

**Тестирование и релиз.** Сборку и конвертацию модели, а также кросс-платформенные тесты выполняет `ci`
(пайплайн ClearML и GitLab CI). Сравнение исходной и портированной модели обеспечивает библиотека
`migration` (`miglib`) вместе с `gate_tolerance`. Версионирование и откат банка skills даёт авто-релиз на
merge: манифест версий в `gateway.gw_manifest`, git revert и новый тег.

## Личные ключи и учёт по ролям и командам

Общий LLM-endpoint (`hermes_llm`) и IdP (`idp`) на схеме уже были, нового элемента для этого не добавлялось.
Изменились описания и связи: `hermes_llm` принимает запросы только с личным ключом инженера, связь
`hermes_loop -> hermes_llm` уточнена, добавлена связь `hermes_llm -> idp` (проверка и отзыв ключей, роль и
команда как атрибуты ключа). Узел балансировщика в развёртывании дополнен учётом и лимитами нагрузки по ключу.
Личный ключ хранится в локальном профиле вместе с остальными данными пользователя и в дистрибуцию не
попадает. Метки `role` и `team` добавлены к описанию `gate_plugin.gate_telemetry`.

## Что предлагает сам Hermes

Возможности Hermes относятся к уже существующему контейнеру `hermes_agent` и отдельными элементами на
схеме не показаны.

Хук `pre_tool_call`, который может блокировать вызов инструмента, становится основой компонента
`gate_plugin.gate_policy`. Хуки `transform_tool_result` и `transform_terminal_output`, заменяющие результат
до попадания в контекст модели, реализуют `gate_plugin.gate_context_guard`. Хук `pre_verify`, срабатывающий
перед завершением хода с правками кода, реализует `gate_plugin.gate_api_check`. Observer hooks (события
провайдера, инструментов, подтверждений, субагентов, skills) питают `gate_plugin.gate_telemetry` и
`gate_plugin.gate_budget`. Встроенные лимит итераций, обнаружение циклов и маскирование секретов в выводе
инструментов уже работают и в модель отдельно не добавлялись, наши компоненты их дополняют.

Локальные логи (`agent.log`, `errors.log`) и `hermes insights` остаются на машине инженера и в центральные
системы не уходят. Плагин Langfuse и экспортёры NeMo Relay по умолчанию не используются: Langfuse был бы
новой системой вне схемы, а общие метрики Relay выключены ради границы данных.

У Hermes нет нативного Prometheus-endpoint, нет учёта стоимости для локальных моделей и нет возможности
изменить исходящий запрос к модели хуками. Первые два пробела закрывает `gate_telemetry` (метрики и расчёт
стоимости по токенам), последний принят как ограничение (см. ADR-005, раздел про Security Layer).

## Новые элементы

В `gate_plugin` добавлены четыре компонента: `gate_context_guard` (Context Guard), `gate_api_check`
(API Check), `gate_budget` (Token Budget) и `gate_telemetry` (Telemetry Exporter). Ранее добавленный
`gate_policy` (Command Policy) остался и теперь связан с циклом агента через хук `pre_tool_call`. Встроенного
эквивалента у этих компонентов нет: Hermes не знает про ветку `migrate-<model>`, границы нашего репозитория,
контракты METADATA, токены ClearML и GitLab, лимит токенов на фазу и наши метрики.

Добавлена система `evals` (Eval Harness): эталонный набор репозиториев, сценарии миграции и набор атак, метрики
качества и блокировка merge в `skills_distribution` при падении ниже порога. В `ci` есть сборка и конвертация
модели, но нет проверки качества самого агента и skills, поэтому это отдельный элемент, запускаемый задачами
существующего CI. Связи: `ci -> evals`, `skills_distribution -> evals`, `evals -> hermes_agent`,
`evals -> obs`, `skillsOwner -> evals`, а также `gate_telemetry -> obs` и `gate_api_check -> miglib`.

Добавлены view `Prod_C3_Component_GatePlugin` (компоненты плагина) и `Prod_Guarded_Tool_Call` (путь одного
вызова инструмента под защитой плагина). Существующие view не менялись.
