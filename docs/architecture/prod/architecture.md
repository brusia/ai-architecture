# Архитектура системы (Production): агент интеграции библиотеки миграции на Hermes

Целевая (to-be) production-архитектура: раннером выступает **Hermes Agent** в **гибридной
топологии** (Central + Local Gateway) с накоплением опыта (skills/memory), self-hosted
LLM-сервисом и полным набором production-решений — мониторинг, алертинг, CI/CD, безопасность.
Ключевой инвариант: **код проектов и промпты не покидают периметр** — инференс идёт на
self-hosted LLM-сервисе, в центр синхронизируются только обезличенные skills и статистика.

## C1. System Context Diagram

Кто и с чем взаимодействует на уровне системы в целом.

> Диаграмма ведётся в Structurizr DSL: [`../workspace.dsl`](../workspace.dsl), view `Prod_C1_Context`.
> Отрендерить: `structurizr export -workspace workspace.dsl -format mermaid` или открыть онлайн на [structurizr.com/dsl](https://structurizr.com/dsl).

---

## C2. Container Diagram

Контейнеры (в терминах C4) production-системы. **Гибридная топология**: один Central Gateway
на команду + Local Gateway у каждого инженера. «Тяжёлые» шаги (convert ONNX→TRT, тесты) — в
ClearML через GitLab CI. Инференс — на выделенном self-hosted LLM-сервисе.

> Диаграмма ведётся в Structurizr DSL: [`../workspace.dsl`](../workspace.dsl), view `Prod_C2_Container`.
> Отрендерить: `structurizr export -workspace workspace.dsl -format mermaid` или открыть онлайн на [structurizr.com/dsl](https://structurizr.com/dsl).

**Отличия от MVP:**

| Аспект | MVP (Qwen Code) | Production (Hermes) |
|--------|-----------------|---------------------|
| Раннер | Qwen Code CLI, локально | Hermes, гибридный Gateway (Local + Central) |
| Накопление опыта | нет | Skills + Memory + Learning Loop, шаринг между инженерами |
| Контекст | прямое чтение файлов | + семантический поиск по Vector Index |
| LLM | локальная LLM инженера | выделенный self-hosted LLM-сервис (кластер за LB) |
| Наблюдаемость | нет | Prometheus/Grafana/Loki/Tempo + Alertmanager |
| CI/CD | ручной запуск | авто-триггер на новый чекпоинт/архитектуру/датасет |
| Безопасность | ключ в конфиге | OIDC SSO, Vault, RBAC, шифрование memory/sessions |

---

## C3. Component Diagram — «внутри AI Service»

«AI Service» = **Local Gateway (Hermes runtime) + Self-hosted LLM**. Показаны реальные
внутренние части.

> Диаграмма ведётся в Structurizr DSL: [`../workspace.dsl`](../workspace.dsl), view `Prod_C3_Component_LocalGateway`.
> Отрендерить: `structurizr export -workspace workspace.dsl -format mermaid` или открыть онлайн на [structurizr.com/dsl](https://structurizr.com/dsl).

**Три источника контекста (важно не смешивать):**

- **Protocol Reader → процесс.** Носитель неизменного протокола: навигатор `AGENTS.md`, текущая
  фаза, контракты из METADATA пакета. Детерминирован, версионируется вместе с библиотекой
  `migration`, одинаков для всех. Это **не** skill — у фазы нет confidence/usage.
- **Skills Manager + Learning Loop → накопленный опыт (know-how).** Skills применяются
  автоматически при `confidence ≥ threshold`, иначе идут через GATE. У skill есть привязка к
  фазе (тег `phase`), поэтому на текущей фазе подтягиваются только релевантные ей skills.
- **Memory Manager + Vector Index → семантический поиск** по personal/project/team memory, в
  отличие от MVP, где контекст собирался прямым чтением файлов.

**Что появилось относительно MVP:**

- **Skills Manager / Learning Loop / Memory Manager + Vector Index** — накопление, поиск и
  переиспользование опыта (в MVP их не было).
- **LLM Router** — маршрутизация на основной self-hosted LLM с fallback на резервный
  self-hosted инстанс, ретраи и лимиты (в MVP клиент бил в одну
  локальную LLM напрямую).
- **Telemetry Agent + Sync Client** — наблюдаемость и командный шаринг знаний.

---

## C4. Deployment Diagram

Как контейнеры размещаются на инфраструктуре в production.

> Диаграмма ведётся в Structurizr DSL: [`../workspace.dsl`](../workspace.dsl), view `Prod_C4_Deployment`.
> Отрендерить: `structurizr export -workspace workspace.dsl -format mermaid` или открыть онлайн на [structurizr.com/dsl](https://structurizr.com/dsl).

---

## Sequence Diagram 1 — «Инженер запрашивает рекомендацию» (с накопленным опытом)

Тот же доменный сценарий, что в MVP (фазы 2–3 протокола), но production-путь: сначала проверяем
накопленные skills/memory, применяем известное решение автоматически (при высокой уверенности),
неизвестное — через GATE. Всё логируется в наблюдаемость.

```mermaid
sequenceDiagram
    autonumber
    actor Eng as DS-инженер
    participant Loop as Agent Loop (Local GW)
    participant Skill as Skills Manager
    participant Mem as Memory Manager
    participant VDB as Vector Index
    participant Prompt as Prompt Assembler
    participant Router as LLM Router
    participant LLM as Self-hosted LLM
    participant Tools as Tool Executor
    participant Repo as Репозиторий модели
    participant Learn as Learning Loop
    participant Obs as Observability

    Eng->>Loop: «Как разрезать модель / переписать эту операцию?»
    Loop->>Skill: Есть готовый skill под операцию?
    Skill->>Mem: Запрос релевантного опыта
    Mem->>VDB: Семантический поиск (skills/memory)
    VDB-->>Mem: Похожие кейсы + confidence
    Mem-->>Skill: Контекст (best practices, warnings)

    alt Skill найден, confidence ≥ threshold
        Skill-->>Loop: Известное решение (авто-применение)
        Loop->>Tools: Применить skill в deploy/
        Tools->>Repo: write + git commit (migrate-<model>)
        Loop-->>Eng: Применено известное решение (📊 из N успешных кейсов)
    else Skill не найден / низкая уверенность → GATE
        Loop->>Tools: Прочитать релевантный код
        Tools->>Repo: read (модель, MIGRATION_STATE.md)
        Repo-->>Tools: Исходники + состояние
        Tools-->>Loop: Контекст репозитория
        Loop->>Prompt: Собрать промпт (контекст + найденный опыт)
        Prompt->>Router: Готовый промпт
        Router->>LLM: POST /v1/chat/completions (основной инстанс)
        opt Основной недоступен → fallback на резерв
            Router->>LLM: POST /v1/chat/completions (резервный self-hosted инстанс)
            Router->>Obs: 🔔 Алерт: работа на резерве (деградация)
            Router-->>Loop: Флаг деградации
            Loop-->>Eng: ⚠️ Warning: ответ получен с резервного инстанса
        end
        LLM-->>Router: Рекомендация + вопросы
        Router-->>Loop: Ответ
        Loop-->>Eng: Предложение + вопросы (🚦 GATE)
        Eng->>Loop: Согласовано ✅
        Loop->>Tools: Применить изменения
        Tools->>Repo: write + git commit
        Loop->>Learn: Зафиксировать результат (новый/обновлённый skill)
    end

    Loop->>Obs: Метрики/трейс (латентность LLM, tokens, GATE-исход)
    Loop-->>Eng: Готово, перехожу к следующей фазе
```

---

## Sequence Diagram 2 — Learning Loop и фоновая синхронизация

Как успешный опыт закрепляется и становится доступен команде — без утечки кода проектов.

```mermaid
sequenceDiagram
    autonumber
    participant Loop as Agent Loop (Local GW)
    participant Learn as Learning Loop
    participant SkillL as Local Skills
    participant SyncC as Sync Client
    participant SyncE as Sync Engine (Central)
    participant Shared as Shared Skills
    participant Analytics as Analytics store
    participant Obs as Observability

    Loop->>Learn: Результат миграции + feedback инженера
    alt Успех (accuracy_loss в норме)
        Learn->>SkillL: confidence += 0.05, usage_count += 1
        Learn->>SkillL: Обновить typical_accuracy_loss (EMA)
        opt usage ≥ 10 и confidence ≥ 0.95
            Learn->>SkillL: mark_as_best_practice
            Learn->>SyncC: Пометить skill к push
        end
    else Неудача
        Learn->>SkillL: confidence -= 0.1, failure_count += 1
        Learn->>SkillL: Добавить WARNING в память
        opt failure_count ≥ 3
            Learn->>SkillL: trigger_skill_review
        end
    end

    Note over SyncC,SyncE: Фоновая синхронизация (каждые 5 мин)
    SyncC->>SyncE: Push: skills (conf ≥ 0.8, usage ≥ 3) + обезличенная статистика
    Note right of SyncC: ❌ Код, диалоги, артефакты — НЕ отправляются
    SyncE->>Shared: Merge + conflict resolution
    SyncE->>Analytics: Записать success rate / accuracy
    SyncE-->>SyncC: Pull: обновлённые team best practices
    SyncC->>SkillL: Обновить локальный кэш skills
    SyncE->>Obs: Метрики синхронизации (lag, конфликты)
```

---

## Наблюдаемость, алертинг и SLO (production-зрелость)

**Метрики (Prometheus):**

| Домен | Примеры метрик |
|-------|----------------|
| LLM | латентность `/v1/chat/completions` (p50/p95/p99), tokens in/out, ошибки/таймауты, доля запросов на резервном инстансе (fallback rate) |
| Агент | длительность миграции, доля авто-применённых skills, доля GATE-отклонений, ошибки tools |
| Качество | распределение `accuracy_loss`, доля миграций в пределах threshold, speedup |
| Skills | usage/success rate, число best practices, skills с падающей confidence |
| Sync | lag синхронизации, число конфликтов, размер очереди offline |
| Инфра | health Local/Central Gateway, GPU-утилизация инференс-кластера |

**Логи (Loki) и трейсы (Tempo):** структурированные логи агентного цикла и распределённый
трейс `запрос инженера → skill lookup → LLM → tools → commit` для разбора инцидентов.

**Алертинг (Alertmanager, примеры правил):**

| Алерт | Условие | Реакция |
|-------|---------|---------|
| LLM основной недоступен | error rate `/v1` > 5% за 5 мин | авто-fallback на резерв + on-call |
| Работа на резервном LLM | роутер использует резервный инстанс | on-call (деградация) + warning инженеру в CLI |
| Деградация качества | медиана `accuracy_loss` растёт неделя-к-неделе | ревью skills |
| «Отравленный» skill | success_rate skill < 0.7 при usage > 5 | заморозить skill, review |
| Sync-лаг | lag > 30 мин | проверить Central Gateway |
| Всплеск GATE-отклонений | доля отклонений > базовой на X% | инженерам не доверяют предложения — разбор |

**SLO (пример):** доступность LLM-сервиса 99.5%; p95 латентности рекомендации < N сек; доля
миграций в пределах accuracy-threshold ≥ 95%.

---

## Безопасность (production-зрелость)

- **AuthN:** SSO через OIDC (IdP); сервис-токены Local↔Central из Vault.
- **AuthZ / RBAC:** роли `engineer` (свои сессии, применение skills), `lead` (ревью/промоут
  skills, отчёты), `admin` (управление Central Gateway). Промоут skill в team-scope — только
  `lead`.
- **Транспорт:** mTLS между Local Gateway и LLM-сервисом / Central Gateway.
- **Секреты:** ключи и токены — в Vault; локально `credentials.enc` (шифрование на диске).
- **Приватность (инвариант):** код проектов, диалоги, артефакты и личные заметки **не покидают
  машину инженера**; в центр уходят только обезличенные skills и статистика.
- **Аудит:** промоуты skills, изменения RBAC и обращения к секретам логируются.

---

## API Spec

См. отдельный файл [`openapi.yaml`](openapi.yaml). Он описывает реальные сетевые контракты:

1. **LLM transport** (`/v1/chat/completions`) — фактический OpenAI-compatible вызов
   Local Gateway → self-hosted LLM (единственный внешний вызов агента к модели, унаследован из
   MVP).
2. **Ops** (`/healthz`, `/readyz`, `/metrics`) — эндпоинты наблюдаемости и проб Gateway.
3. **Sync** (`/sync/*`) — синхронизация Local ↔ Central Gateway (обезличенно).

Доменная логика (подбор skill, поиск по накопленному опыту, сбор контекста, промптинг, оценка
точности) — это **внутренние tools агентного цикла**, а не сетевые HTTP-эндпоинты. Отдельного
доменного API (вида `get_recommendation`) в системе нет — как и в MVP, наружу от агента идёт
только вызов LLM; в production добавляются ops- и sync-контуры.
