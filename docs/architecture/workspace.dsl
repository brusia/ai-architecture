workspace "Migration Copilot" "Агентный copilot для интеграции библиотеки migration: MVP на Qwen Code и Production на Hermes" {

    !identifiers hierarchical

    !docs docs

    model {
        // Разделитель имени группы для меню сайта (| не встречается в именах систем,
        // иначе "/" в названиях ломает дерево навигации)
        properties {
            "structurizr.groupSeparator" "|"
        }

        // ---------- Акторы ----------
        engineer = person "DS-инженер / инженер оптимизации" "Портирует модель на целевой вычислитель с помощью агента"
        lead     = person "Тимлид / MLOps" "Смотрит дашборды, ревьюит skills, реагирует на алерты"

        // ---------- Общие внешние системы и артефакты (переиспользуются MVP и Prod) ----------
        group "Common" {
            ci       = softwareSystem "GitLab CI + ClearML" "Конвейер сборки и проверки: конвертация модели (ONNX→TensorRT), кросс-платформенные тесты точности и производительности, трекинг экспериментов в ClearML. Запускается по git push / Merge Request" {
                tags "External"
            }
            registry = softwareSystem "pypi-local / artifact storage" "Внутренний артефакт-хранилище: дистрибутив библиотеки migration (pip/uv) и целевые артефакты модели (.onnx, .engine). Источник зависимостей и место публикации результатов миграции" {
                tags "External"
            }
            obs = softwareSystem "Observability + Alerting" "Наблюдаемость всей платформы: метрики (Prometheus), дашборды (Grafana), логи (Loki), трейсы (Tempo) и алертинг (Alertmanager). Собирает телеметрию вызовов LLM, tools и GATE, оповещает о деградациях" {
                tags "External"
            }
            idp = softwareSystem "IdP + Vault" "Единый вход и управление секретами: SSO по OIDC, хранение токенов и ключей, ролевой доступ (RBAC) к командным ресурсам. Гарантирует, что синхронизация и доступ к сервисам аутентифицированы" {
                tags "External"
            }

            // Репозиторий модели — общий артефакт, вне периметра агента, не синхронизируется в центр
            repo = softwareSystem "Репозиторий модели" "Рабочая копия портируемой модели: код, каталоги deploy/ и recipe/, файл прогресса MIGRATION_STATE.md. Каждая миграция ведётся в отдельной ветке migrate-<model>; агент читает и правит именно этот репозиторий" {
                tags "Repo"
            }

            // Библиотека migration — носитель протокола (зависимость)
            miglib = softwareSystem "Библиотека migration" "Носитель неизменного процесса миграции: навигатор AGENTS.md, пофазные инструкции (phase-файлы), JSON-схемы и API-контракты в METADATA. Определяет, что и в каком порядке делает агент, но не хранит накопленный опыт" {
                tags "Library"
            }
        }

        // =====================================================================
        //  MVP: Qwen Code, всё локально у инженера
        // =====================================================================
        mvp = softwareSystem "Migration Copilot — MVP (Qwen Code)" "Агентный CLI-copilot, работающий полностью локально у инженера. Контекст собирается прямым чтением файлов протокола и репозитория, без векторного поиска и без накопления опыта между миграциями" {
            tags "MVP"

            // Контейнеры (всё локально у инженера)
            mvp_qwen = container "Qwen Code CLI" "Агент-раннер: ведёт диалог с инженером, читает протокол и код, вызывает LLM, правит файлы и делает коммиты по прохождении GATE" "CLI coding agent" {

                // Компоненты внутри агентного раннера (C3 — «внутри AI Service»)
                mvp_loop  = component "Agent Loop (ReAct)" "Цикл рассуждение→действие→наблюдение; ведёт диалог и GATE/CHECKPOINT" "orchestrator"
                mvp_guide = component "Protocol / Guide Reader" "Загружает навигатор + ТОЛЬКО текущую фазу, тянет контракты из METADATA пакета (RAG без вектора — прямое чтение)" "context builder"
                mvp_prompt = component "Prompt Assembler" "Собирает system+task промпт из фазы, кодстайла и контекста репозитория" "prompt builder"
                mvp_llmcli = component "LLM Client" "Отправляет запросы на self-hosted /v1/chat/completions, парсит ответ" "OpenAI-compatible client"
                mvp_tools  = component "Tool Executor" "Читает и правит файлы репозитория, запускает команды, делает коммиты по GATE" "tools: file/shell/git"
                mvp_state  = component "State Manager" "Ведёт MIGRATION_STATE.md: текущая фаза, статусы GATE, что дальше" "state file"
            }

            mvp_llm = container "Локальная LLM" "Генерирует анализ, рекомендации и код по промптам агента. Ядро технологии — только локально" "self-hosted, OpenAI-compatible /v1" {
                tags "LLM"
            }

            // Связи уровня контейнеров MVP
            mvp_qwen -> mvp_llm "Промпты и ответы" "HTTP, OpenAI-compatible /v1/chat/completions"

            // Связи уровня компонентов MVP
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_guide "Запрашивает текущую фазу и контракты"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_prompt "Просит собрать промпт"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_tools "Действия над репозиторием"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_state "Обновляет прогресс"
            mvp_qwen.mvp_prompt -> mvp_qwen.mvp_llmcli "Готовый промпт"
            mvp_qwen.mvp_llmcli -> mvp_llm "POST /v1/chat/completions"
        }

        // Связи MVP с внешним миром / общими системами
        engineer -> mvp.mvp_qwen "Запускает, даёт указания, подтверждает GATE" "терминал"
        engineer -> mvp.mvp_qwen.mvp_loop "Указания / подтверждение GATE"
        mvp.mvp_qwen -> miglib "Читает протокол/схемы/контракты" "eai-migrate-guide -a, чтение файлов"
        mvp.mvp_qwen -> repo "Анализирует и правит код, коммитит" "файловая система, git"
        mvp.mvp_qwen.mvp_guide -> miglib "Читает AGENTS.md / phase-XX / METADATA"
        mvp.mvp_qwen.mvp_tools -> repo "read / write / commit"
        mvp.mvp_qwen.mvp_state -> repo "Пишет MIGRATION_STATE.md"

        // =====================================================================
        //  Production: Hermes, гибридная топология Local + Central
        // =====================================================================
        prod = softwareSystem "Migration Copilot — Production (Hermes)" "Гибридный агент из локального и центрального шлюзов: накапливает опыт (skills и memory) между миграциями и делится им в команде, работает на self-hosted LLM с резервированием и полной наблюдаемостью" {
            tags "Prod"

            // --- Local Gateway (машина инженера) ---
            prod_cli = container "Hermes CLI" "Точка входа: hermes agent start. Диалог, GATE/CHECKPOINT, команды skills/memory/report" "CLI coding agent"

            prod_localgw = container "Local Gateway" "Agent Loop, исполнение tools, локальный кэш skills, personal/project memory, sessions, LLM Router" "Hermes runtime (systemd, :8080)" {

                // Компоненты внутри Local Gateway (C3)
                prod_loop = component "Agent Loop (ReAct)" "Цикл рассуждение→действие→наблюдение; ведёт диалог, GATE/CHECKPOINT" "orchestrator"
                prod_guide = component "Protocol Reader" "Навигатор + ТОЛЬКО текущая фаза протокола и контракты из METADATA. Носитель неизменного процесса (не know-how)" "process/context source"
                prod_skillmgr = component "Skills Manager" "Подбирает skill по задаче/тегам, отфильтрованные по фазе; авто-применяет при confidence ≥ threshold" "skill registry + selector"
                prod_memmgr = component "Memory Manager" "Семантический поиск по personal/project/team memory через Vector Index" "context builder + retrieval"
                prod_prompt = component "Prompt Assembler" "Собирает system+task промпт из skill, кодстайла, найденного контекста" "prompt builder"
                prod_router = component "LLM Router" "Маршрутизация на основной self-hosted LLM; fallback на резерв, ретраи, таймауты, лимиты; алерт+warning при работе на резерве" "routing + fallback"
                prod_llmcli = component "LLM Client" "POST /v1/chat/completions, парсинг ответа" "OpenAI-compatible client"
                prod_tools = component "Tool Executor" "analyze_with_library, generate_migration_code, evaluate_accuracy; правки файлов, коммиты по GATE" "tools: library/file/shell/git"
                prod_state = component "State Manager" "Ведёт MIGRATION_STATE.md и session.yaml: фаза, GATE-статусы, метрики" "state file"
                prod_learn = component "Learning Loop" "Обновляет confidence/usage skill по результату; помечает best practice; готовит к синхронизации" "feedback engine"
                prod_synccli = component "Sync Client" "Push успешных skills/статистики, pull team best practices (не код!)" "sync"
                prod_telemetry = component "Telemetry Agent" "Метрики/логи/трейсы вызовов LLM, tools, GATE в Observability" "OTLP exporter"
            }

            prod_localstore = container "Local store" "~/.hermes: кэш skills, PERSONAL.md, sessions, project memory, credentials.enc" "файлы + шифрование" {
                tags "Repo"
            }

            // --- Central Gateway (командный сервер) ---
            prod_centralgw = container "Central Gateway" "API синхронизации, shared skills, team memory, conflict resolution, RBAC" "Hermes gateway (systemd, :8080)"
            prod_sync = container "Sync Engine" "Периодическая синхронизация (каждые 5 мин): push успешных skills, pull best practices" "scheduler"
            prod_shared = container "Shared Skills + Team Memory" "ml-migration skills, MEMORY/WARNINGS/RULES, usage_stats / success_rates" "файлы + метаданные" {
                tags "Repo"
            }
            prod_vdb = container "Vector Index" "Эмбеддинги для семантического поиска по skills/memory" "Chroma + FTS5" {
                tags "Repo"
            }
            prod_analytics = container "Analytics store" "Статистика миграций, success rates, accuracy-метрики, активность инженеров" "structured storage" {
                tags "Repo"
            }
            prod_dash = container "Monitoring Dashboard" "Usage/success rates, accuracy, SLO, health инженерских Gateway" "Grafana (:8081)"

            prod_llm = container "Self-hosted LLM Service" "Кластер инференса за LB. Ядро технологии — внутри периметра" "on-prem, OpenAI-compatible /v1" {
                tags "LLM"
            }

            // --- Связи уровня контейнеров Prod ---
            prod_cli -> prod_localgw "Команды агенту" "локальный сокет / HTTP :8080"
            prod_localgw -> prod_localstore "read / write" "файлы"
            prod_localgw -> prod_llm "Промпты и ответы (через LLM Router)" "HTTPS, /v1/chat/completions"
            prod_localgw -> prod_centralgw "Синхронизация skills/memory/статистики (не код!)" "HTTPS + token"
            prod_sync -> prod_shared "push/pull skills, conflict resolution"
            prod_sync -> prod_centralgw "Обслуживает sync-запросы"
            prod_centralgw -> prod_shared "read/write shared skills, team memory"
            prod_centralgw -> prod_vdb "Индексация и семантический поиск"
            prod_centralgw -> prod_analytics "Пишет статистику миграций"
            prod_dash -> prod_analytics "Читает метрики для дашбордов"

            // --- Связи уровня компонентов Prod (внутри Local Gateway) ---
            prod_localgw.prod_loop -> prod_localgw.prod_guide "Запрашивает текущую фазу и контракты"
            prod_localgw.prod_loop -> prod_localgw.prod_skillmgr "Есть ли готовый skill под текущую фазу?"
            prod_localgw.prod_guide -> prod_localgw.prod_skillmgr "Текущая фаза → фильтр релевантных skills"
            prod_localgw.prod_skillmgr -> prod_localgw.prod_memmgr "Запрос релевантного опыта"
            prod_localgw.prod_memmgr -> prod_vdb "Семантический поиск"
            prod_localgw.prod_loop -> prod_localgw.prod_prompt "Собрать промпт (skill + контекст)"
            prod_localgw.prod_prompt -> prod_localgw.prod_router "Готовый промпт"
            prod_localgw.prod_router -> prod_localgw.prod_llmcli "Выбранный инстанс (основной / резервный)"
            prod_localgw.prod_llmcli -> prod_llm "POST /v1/chat/completions"
            prod_localgw.prod_router -> prod_localgw.prod_telemetry "Fallback на резерв → алерт (деградация)"
            prod_localgw.prod_router -> prod_localgw.prod_loop "Fallback на резерв → warning инженеру"
            prod_localgw.prod_loop -> prod_localgw.prod_tools "Действия над репозиторием / библиотекой"
            prod_localgw.prod_tools -> repo "read / write / commit"
            prod_localgw.prod_loop -> prod_localgw.prod_state "Обновляет прогресс"
            prod_localgw.prod_state -> repo "Пишет MIGRATION_STATE.md"
            prod_localgw.prod_loop -> prod_localgw.prod_learn "Результат + feedback инженера"
            prod_localgw.prod_learn -> prod_localgw.prod_skillmgr "Обновляет confidence/usage"
            prod_localgw.prod_learn -> prod_localgw.prod_synccli "Помечает к синхронизации"
            prod_localgw.prod_synccli -> prod_centralgw "Push/pull (обезличенно)"
            prod_localgw.prod_loop -> prod_localgw.prod_telemetry "События для наблюдаемости"
            prod_localgw.prod_telemetry -> obs "OTLP export"
            prod_localgw.prod_guide -> miglib "Читает AGENTS.md / phase-XX / METADATA"
        }

        // Связи Prod с акторами / общими системами
        engineer -> prod.prod_cli "Задачи, подтверждение GATE" "терминал"
        engineer -> prod.prod_localgw.prod_loop "Указания / подтверждение GATE"
        lead -> prod "Ревью skills, отчёты" "CLI / Dashboard"
        lead -> obs "Смотрит метрики, получает алерты"

        prod -> miglib "Ставит библиотеку" "pip / uv"
        prod -> ci "Запускает convert/тесты" "git push / API"
        prod -> registry "Ставит библиотеку, публикует артефакты"
        prod -> obs "Метрики, логи, трейсы" "OTLP / scrape"
        prod -> idp "Аутентификация, секреты" "OIDC / Vault API"

        prod.prod_localgw -> repo "Анализирует и правит код, коммитит" "файловая система, git"
        prod.prod_localgw -> ci "Инициирует convert/тесты" "git push / API"
        prod.prod_localgw -> registry "Ставит migration, публикует артефакты" "pip/uv, upload"
        prod.prod_localgw -> obs "Метрики/логи/трейсы" "OTLP / scrape"
        prod.prod_localgw -> idp "Аутентификация, секреты" "OIDC / Vault"
        prod.prod_centralgw -> obs "Метрики/логи/трейсы" "OTLP / scrape"
        prod.prod_centralgw -> idp "RBAC, проверка токенов" "OIDC / Vault"

        // Общие связи внешних систем
        miglib -> registry "Устанавливается из" "pip / uv"
        repo -> ci "Push / Merge Request запускает" "git push"
        ci -> registry "Публикует артефакты" "upload"
        obs -> prod.prod_dash "Datasource для Grafana"

        // =====================================================================
        //  Deployment (Production)
        // =====================================================================
        deploymentEnvironment "Production" {

            deploymentNode "Рабочая станция инженера" "" "Linux / macOS" {
                deploymentNode "systemd" "" "user service" {
                    containerInstance prod.prod_localgw
                    containerInstance prod.prod_cli
                }
                deploymentNode "Локальный диск (шифрование)" "" "LUKS / FileVault" {
                    containerInstance prod.prod_localstore
                }
            }

            deploymentNode "Command Server" "on-prem / private cloud" "" {
                deploymentNode "Kubernetes / systemd" "" "team namespace" {
                    containerInstance prod.prod_centralgw
                    containerInstance prod.prod_sync
                    containerInstance prod.prod_dash
                }
                deploymentNode "Data volume" "" "encrypted PV" {
                    containerInstance prod.prod_shared
                    containerInstance prod.prod_vdb
                    containerInstance prod.prod_analytics
                }
            }

            deploymentNode "LLM Inference Cluster" "GPU-ноды, on-prem" "" {
                deploymentNode "Load Balancer" "health-check + failover" "" {
                    deploymentNode "Primary zone" "GPU-ноды" "" {
                        containerInstance prod.prod_llm
                    }
                    deploymentNode "Standby zone" "GPU-ноды (резервный инстанс)" "" {
                        containerInstance prod.prod_llm
                    }
                }
            }
        }
    }

    views {
        // Сворачиваемое дерево систем в меню сайта: группа Common уходит в отдельный узел
        properties {
            "generatr.site.nestGroups" "true"
            "generatr.style.customStylesheet" "custom.css"
        }

        // ---------- Production views ----------
        systemContext prod "Prod_C1_Context" {
            include *
            autolayout lr
            description "C1 — System Context (Production, Hermes)"
        }

        container prod "Prod_C2_Container" {
            include *
            autolayout lr
            description "C2 — Container diagram (Production): гибридная топология"
        }

        component prod.prod_localgw "Prod_C3_Component_LocalGateway" {
            include *
            autolayout lr
            description "C3 — Component diagram (Production): AI Service = Local Gateway + LLM"
        }

        deployment prod "Production" "Prod_C4_Deployment" {
            include *
            autolayout lr
            description "C4 — Deployment diagram (Production)"
        }

        // ---------- MVP views ----------
        systemContext mvp "MVP_C1_Context" {
            include *
            autolayout lr
            description "System Context (MVP, Qwen Code) — всё локально у инженера"
        }

        container mvp "MVP_C2_Container" {
            include *
            autolayout lr
            description "C2 — Container diagram (MVP): интеграция библиотеки migration"
        }

        component mvp.mvp_qwen "MVP_C3_Component_AIService" {
            include *
            autolayout lr
            description "C3 — Component diagram (MVP): AI Service = Qwen Code + локальная LLM"
        }

        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "MVP" {
                background #6b4fbb
                color #ffffff
            }
            element "Prod" {
                background #1168bd
                color #ffffff
            }
            element "LLM" {
                background #b8394a
                color #ffffff
                shape hexagon
            }
            element "Library" {
                background #7f5f27
                color #ffffff
                shape folder
            }
            element "Repo" {
                shape cylinder
                background #438dd5
                color #ffffff
            }
        }
    }
}
