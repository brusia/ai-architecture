workspace "Migration Copilot" "Агентный ассистент для интеграции библиотеки migration: MVP на Qwen Code и Production на Hermes Agent API (NousResearch)" {

    !identifiers hierarchical

    !docs docs

    model {
        // Разделитель имени группы для меню сайта (| не встречается в именах систем,
        // иначе «/» в названиях ломает дерево навигации)
        properties {
            "structurizr.groupSeparator" "|"
        }

        // ---------- Акторы ----------
        engineer = person "DS-инженер / инженер оптимизации" "Ведёт модельную часть миграции (фазы 0-11): окружение, экспорт, конвертация, тестирование, сравнение. Работает с ассистентом и подтверждает GATE. Создаёт скрипты развёртывания вместе с агентом. Делится находками обычным git PR (commit/push/PR), но не участвует в релизном цикле дистрибуции"
        mlops    = person "MLOps-инженер" "Продолжает миграцию с фазы CI-интеграции (12+): пайплайн ClearML, задачи CI, матрица сборки образов для развёртывания. Тот же ассистент, другой уровень ответственности. Принимает передачу работы от DS-инженера на GATE"
        lead     = person "Тимлид" "Смотрит дашборды и реагирует на алерты. Общее владение продуктом"

        // ---------- Роли ревью и релиза банка skills (гибридная топология) ----------
        skillsOwner = person "Skills Owner" "Экспертиза по ML и миграции. Проверяет содержание PR со skill вместе с MLOps Reviewer (двойной approve на каждый PR, а не только для фаз 0-11). Имеет узкое право rollback(version) через Gateway API с журналом аудита: «красная кнопка» при «отравленном» skill. Технический откат выполняет DevOps, доступа к инфраструктуре Gateway и CI у Skills Owner нет"
        mlopsReviewer = person "MLOps Reviewer" "Экспертиза по CI и развёртыванию (фазы 12+: пайплайн ClearML, матрица сборки). Проверяет содержание PR со skill вместе со Skills Owner. Двойной approve обязателен для каждого PR независимо от фазы, так как skill может затрагивать обе области"
        devops = person "DevOps (оператор Gateway)" "Владеет инфраструктурой Central Gateway и CI-пайплайном релизов дистрибуции: настраивает авто-релиз на merge, выполняет технический rollback (git revert и новый тег) по запросу Skills Owner, следит за внедрением и аналитикой. Не участвует в ревью содержания skills: это не его экспертиза"

        // ---------- Общие внешние системы и артефакты (переиспользуются MVP и Prod) ----------
        group "Common" {
            ci       = softwareSystem "ClearML pipeline + GitLab CI" "Единая связка конвейеров. ClearML: вычислительные ресурсы для конвертации (test-tools отправляет задачу на воркеры), оркестрация стадий (экспорт, конвертация, тесты, сравнение) и трекинг экспериментов. Пайплайн ClearML запускает GitLab CI, который параллельно собирает образы для развёртывания под целевые платформы (amd-cu12 / amd-cu13 / arm-cu13). Параллелизм по платформам живёт здесь, а не в агенте" {
                tags "External"
            }
            registry = softwareSystem "pypi-local / artifact storage" "Внутреннее хранилище артефактов: дистрибутив библиотеки migration (pip/uv) и целевые артефакты модели (.onnx, .engine). Источник зависимостей и место публикации результатов миграции" {
                tags "External"
            }
            obs = softwareSystem "Observability + Alerting" "Наблюдаемость всей платформы: метрики (Prometheus), дашборды (Grafana), логи (Loki), трейсы (Tempo) и алертинг (Alertmanager). Собирает телеметрию вызовов LLM, инструментов и GATE, оповещает о деградациях" {
                tags "External"
            }
            idp = softwareSystem "IdP + Vault" "Единый вход и управление секретами: SSO по OIDC, хранение токенов и ключей, ролевой доступ (RBAC) к командным ресурсам. Гарантирует, что синхронизация и доступ к сервисам аутентифицированы" {
                tags "External"
            }

            // Репозиторий модели: общий артефакт вне периметра агента
            repo = softwareSystem "Репозиторий модели" "Рабочая копия портируемой модели: код, каталоги deploy/ и recipe/, файл прогресса MIGRATION_STATE.md. Каждая миграция ведётся в отдельной ветке migrate-<model>; агент читает и правит именно этот репозиторий" {
                tags "Repo"
            }

            // Библиотека migration: носитель протокола (зависимость)
            miglib = softwareSystem "Библиотека migration" "Носитель неизменного процесса миграции: навигатор AGENTS.md, пофазные инструкции (phase-файлы), JSON-схемы и API-контракты в METADATA. Определяет, что и в каком порядке делает агент, но не хранит накопленный опыт" {
                tags "Library"
            }
        }

        // =====================================================================
        //  MVP: Qwen Code, всё локально у инженера
        // =====================================================================
        mvp = softwareSystem "Migration Copilot: MVP (Qwen Code)" "Агентный CLI-ассистент, работающий полностью локально у инженера. Контекст собирается прямым чтением файлов протокола и репозитория, без векторного поиска и без накопления опыта между миграциями" {
            tags "MVP"

            // Контейнеры (всё локально у инженера)
            mvp_qwen = container "Qwen Code CLI" "Агент-раннер: ведёт диалог с инженером, читает протокол и код, вызывает LLM, правит файлы и делает коммиты после прохождения GATE" "CLI-агент для кода" {

                // Компоненты внутри агентного раннера (C3: внутри AI Service)
                mvp_loop  = component "Agent Loop (ReAct)" "Цикл «рассуждение, действие, наблюдение»; ведёт диалог, GATE и контрольные точки" "оркестратор"
                mvp_guide = component "Protocol / Guide Reader" "Загружает навигатор и только текущую фазу, берёт контракты из METADATA пакета (RAG без векторного поиска: прямое чтение)" "сборщик контекста"
                mvp_prompt = component "Prompt Assembler" "Собирает системный промпт и промпт задачи из фазы, стиля кода и контекста репозитория" "сборщик промптов"
                mvp_llmcli = component "LLM Client" "Отправляет запросы на self-hosted /v1/chat/completions, разбирает ответ" "клиент, совместимый с OpenAI"
                mvp_tools  = component "Tool Executor" "Читает и правит файлы репозитория, запускает команды, делает коммиты по GATE" "инструменты: файлы, shell, git"
                mvp_state  = component "State Manager" "Ведёт MIGRATION_STATE.md: текущая фаза, статусы GATE, что дальше" "файл состояния"
            }

            mvp_llm = container "Локальная LLM" "Генерирует анализ, рекомендации и код по промптам агента. Ядро технологии работает только локально" "self-hosted, совместима с OpenAI /v1" {
                tags "LLM"
            }

            // Связи уровня контейнеров MVP
            mvp_qwen -> mvp_llm "Промпты и ответы" "HTTP, совместимый с OpenAI /v1/chat/completions"

            // Связи уровня компонентов MVP
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_guide "Запрашивает текущую фазу и контракты"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_prompt "Просит собрать промпт"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_tools "Действия над репозиторием"
            mvp_qwen.mvp_loop -> mvp_qwen.mvp_state "Обновляет прогресс"
            mvp_qwen.mvp_prompt -> mvp_qwen.mvp_llmcli "Готовый промпт"
            mvp_qwen.mvp_llmcli -> mvp_llm "POST /v1/chat/completions"
        }

        // Связи MVP с внешним миром и общими системами
        engineer -> mvp.mvp_qwen "Запускает, даёт указания, подтверждает GATE" "терминал"
        engineer -> mvp.mvp_qwen.mvp_loop "Указания и подтверждение GATE"
        mvp.mvp_qwen -> miglib "Читает протокол, схемы и контракты" "eai-migrate-guide -a, чтение файлов"
        mvp.mvp_qwen -> repo "Анализирует и правит код, коммитит" "файловая система, git"
        mvp.mvp_qwen.mvp_guide -> miglib "Читает AGENTS.md, phase-XX и METADATA"
        mvp.mvp_qwen.mvp_tools -> repo "Чтение, запись, коммит"
        mvp.mvp_qwen.mvp_state -> repo "Пишет MIGRATION_STATE.md"

        // =====================================================================
        //  Production: спроектировано на Hermes Agent API.
        // =====================================================================
        prod = softwareSystem "Migration Copilot: Production (Hermes)" "Один и тот же профиль Hermes Agent (Profile Distribution) у DS-инженера и у MLOps-инженера. Протокол живёт как project-local skills (поэтапная подгрузка, progressive disclosure), а не как собственный векторный индекс. Единственный наш код: GATE и числовая проверка допусков (tolerance), то есть плагин-инструмент уровня агента, который перехватывается до диспетчеризации в registry (того же класса, что встроенные memory и todo)" {
            tags "Prod"

            // --- Среда выполнения Hermes: внешняя технология, не наш код ---
            hermes_agent = container "Hermes AIAgent" "Единый ReAct-раннер (run_agent.py): сборка промпта, вызов провайдера, затем либо выполнение tool_calls, либо возврат ответа. Тот же класс обслуживает CLI, Gateway, ACP и cron. Владеет историей сообщений, сжатием контекста и сохранением сессий (SQLite+FTS5)" "Hermes runtime (NousResearch), отдельный процесс на профиль" {

                hermes_loop = component "Agent Loop (AIAgent)" "Синхронный движок оркестрации: строит промпт, вызывает провайдера, выполняет tool_calls и повторяет. Ничего не знает о фазах, GATE и допусках: это универсальный диалоговый цикл, вся доменная семантика приходит из project-skills и нашего плагина" "run_agent.py"
                hermes_terminal = component "Инструмент терминала" "Встроенный инструмент выполнения команд: обнаружение опасных команд (rm -rf, DROP TABLE, systemctl stop и др.), подтверждение пользователем (запрос в CLI или сообщение через gateway), список разрешённых команд на сессию, 7 окружений выполнения (local, docker, ssh и др.). Заменяет наш ранний subprocess.run() без какой-либо защиты" "встроенный инструмент"
                hermes_delegate = component "delegate_task" "Встроенный инструмент делегирования: создаёт дочерний AIAgent с изолированным контекстом (цель и контекст текстом, без истории родителя). Потомок наследует набор инструментов родителя за вычетом delegate_task, clarify, memory, send_message и cronjob. До 3 параллельно. Заменяет наши SubagentSpec и SubagentResult: типизация переносится на границу, наш плагин просит вернуть строгий JSON и сам его валидирует" "встроенный инструмент"
                hermes_fallback = component "Fallback Providers" "Встроенное переключение между провайдерами: при 429, 5xx, 401 и 403 пробует fallback_providers по списку, обновляет учётные данные при ошибках аутентификации. Заменяет наш собственный LLM Router" "встроенный, настраивается конфигом"
                hermes_memory = component "Built-in Memory" "MEMORY.md и USER.md: ограниченные по размеру (2200 и 1375 символов) заметки, которыми управляет сам агент. Проверено вручную: встроенных числовых confidence и usage_count нет, что запомнить, решает сама LLM (self-improvement), а gate здесь только approve или reject (write_approval), не порог" "встроенный, на профиль"
                hermes_skills = component "Skills (поэтапная подгрузка)" "skills_list() (около 3k токенов), затем skill_view(name), затем skill_view(name, path). Наши 14 фаз протокола это project-local skills в .hermes/skills/phase-NN-*/SKILL.md; phase-01-env состоит из core.md и references/{uv,poetry,pdm,pip,conda}.md. Тот же паттерн, что мы вручную реализовали в migration, но с готовой семантикой поэтапной подгрузки" "встроенный, .hermes/skills/"
            }

            // --- Наш код: единственное, чего в Hermes нет ---
            gate_plugin = container "Migration Gate Plugin" "Плагин-инструмент уровня агента (наш единственный существенный код). Регистрируется как ~memory и ~todo, перехватывается AIAgent до обычной диспетчеризации в registry. Даёт то, чего нет в Hermes «из коробки»: блокирующий GATE (а не дисциплину на уровне промпта) и числовую проверку допусков по diff (а не «модель сама посчитает в уме»)" "Python-плагин, ~/.hermes/plugins/ или .hermes/plugins/" {
                gate_tool = component "Инструмент migration_gate" "Инструмент с параметром action (status, confirm_gate, record_diff, choose_platforms), по аналогии с memory(action=add/replace/remove). confirm_gate физически не возвращает управление модели без явного подтверждения инженера: тот же механизм approval-callback, что инструмент терминала использует для опасных команд" "инструмент уровня агента"
                gate_tolerance = component "Tolerance Judge" "torch-onnx=1e-4, onnx-engine=1e-2, torch-engine=1e-2: проверка в коде, а не в LLM. Получает структурированный JSON от субагента (через delegate_task и наш контракт в промпте «верни строго {ok,summary,diffs}») и сам решает: допустимо или вне допуска" "чистая функция"
                gate_state = component "State Writer" "Пишет MIGRATION_STATE.md при каждом confirm_gate. Файловый контракт тот же, что в MVP, для совместимости с библиотекой migration и ручным чтением человеком" "файл состояния"
            }

            // --- Distribution: как это раздаётся в команде (задокументированная практика Hermes) ---
            skills_distribution = container "migration-copilot Distribution" "Git-репозиторий Profile Distribution (рекомендованная практика Hermes для сценария «команда поставляет проверенного внутреннего агента»; их собственный пример: бот для PR-ревью). Содержит то, что принадлежит дистрибуции: SOUL.md, config.yaml, skills/ (14 фаз), gate_plugin. Никогда не содержит memories, sessions, auth.json и .env: они принадлежат пользователю, остаются у каждого инженера локально и не покидают машину" "git-репозиторий, distribution.yaml" {
                tags "Repo"
            }

            hermes_llm = container "Сервис LLM (self-hosted)" "Кластер инференса. Hermes сам не диктует, где хостить модель, а задаёт только протокол доступа (OpenAI-compatible /v1)" "on-prem, совместим с OpenAI /v1" {
                tags "LLM"
            }

            // --- Central Gateway: гибридная топология поверх git, не второй источник истины ---
            gateway = container "Central Gateway" "On-prem сервис, который скрывает от инженера релизный цикл skills_distribution: git остаётся единственным источником содержимого, Gateway только отражает «что сейчас актуально» и собирает обезличенные метрики. Владелец: DevOps. Позволяет hermes profile update работать внутри контура без прямого доступа инженера к внешнему git" "on-prem сервис" {
                gw_manifest = component "Release Manifest Service" "GET /distribution/latest, GET /distribution/{version}/manifest.json. Манифест генерируется CI-джобом на каждый push тега в skills_distribution (version, git_tag, skills[{name,hash,phase}], changelog). Тонкий слой метаданных над git, без собственного состояния «какая версия содержимого актуальна сейчас»" "HTTP API"
                gw_adoption = component "Adoption Tracker" "Принимает обезличенные чекины {profile_hash, skills_distribution_version, timestamp} при каждом hermes profile update. Показывает DevOps и тимлиду, какая доля команды на актуальной версии банка skills" "HTTP API и хранилище"
                gw_analytics = component "Skill Analytics Aggregator" "Принимает обезличенную числовую статистику применения skill (success_count и failure_count по имени skill, без кода, diff и содержимого). Источник: локальный self-improvement review каждой сессии. Основа для решения Skills Owner о rollback" "HTTP API и хранилище"
                gw_rollback = component "Rollback Trigger" "Узкая операция rollback(version) с журналом аудита, доступная Skills Owner. Собственной «активной версии» не имеет: запускает git revert и новый тег тем же CI-механизмом, что обычный релиз (вариант B1: git остаётся единственным источником истины)" "HTTP API, с аудитом"

                gw_manifest -> gw_adoption "Версия, которую подтвердил чекин"
                gw_rollback -> gw_manifest "Запускает генерацию нового манифеста после revert-релиза"
            }

            // --- Связи ---
            hermes_agent.hermes_loop -> hermes_agent.hermes_terminal "tool_call: terminal(...)"
            hermes_agent.hermes_loop -> hermes_agent.hermes_delegate "tool_call: delegate_task(goal, context)"
            hermes_agent.hermes_loop -> hermes_agent.hermes_skills "skills_list() / skill_view(name[, path])"
            hermes_agent.hermes_loop -> hermes_agent.hermes_memory "Заметки под управлением агента (не наше состояние GATE)"
            hermes_agent.hermes_loop -> hermes_agent.hermes_fallback "Провайдер недоступен: переключение на резервного"
            hermes_agent.hermes_loop -> hermes_llm "Вызов API (chat_completions / anthropic_messages)"
            hermes_agent.hermes_fallback -> hermes_llm "Резервный инстанс при 429, 5xx, 401, 403"

            hermes_agent.hermes_loop -> gate_plugin.gate_tool "tool_call: migration_gate(action=..., ...), перехвачено до registry, как memory и todo"
            gate_plugin.gate_tool -> gate_plugin.gate_tolerance "diff: допустимо или вне допуска"
            gate_plugin.gate_tool -> gate_plugin.gate_state "Подтверждённый GATE: запись прогресса"
            gate_plugin.gate_state -> repo "Пишет MIGRATION_STATE.md"
            gate_plugin.gate_tool -> hermes_agent.hermes_loop "Блокирует до явного подтверждения: раньше управление модели не возвращается"

            hermes_agent.hermes_terminal -> repo "Чтение, запись, коммит; команды окружения; конвертация через test-tools"
            hermes_agent.hermes_terminal -> ci "test-tools: задача ClearML (конвертация), конфиги CI (фаза 12+)"
            hermes_agent.hermes_delegate -> repo "Субагент (дочерний AIAgent): экспорт, тесты, сравнение; читает и пишет через terminal внутри своего контекста"
            hermes_agent.hermes_skills -> gateway.gw_manifest "hermes profile update: GET /distribution/latest; инженер git не видит, только Gateway API"
            gateway.gw_adoption -> gateway.gw_manifest "Чекин версии при каждом profile update"
            gate_plugin -> gateway.gw_manifest "Поставляется как часть дистрибуции, приходит тем же манифестом, а не отдельно"
        }

        prod.gateway.gw_manifest -> prod.hermes_agent "hermes profile update: доставляет новую версию skills и плагина в установленный профиль" "HTTP, Gateway API (не git pull напрямую)"

        // Релизный цикл skills_distribution: git остаётся единственным источником истины,
        // Gateway это зеркало для DS/MLOps-инженера и точка агрегированной
        // наблюдаемости для DevOps и Skills Owner (вариант B из ADR-003).
        prod.skills_distribution -> prod.gateway "CI-джоб на push git-тега: повышает версию, генерирует manifest.json, публикует в Release Manifest Service" "CI, авто-релиз на каждый merge в main"

        // Связи Prod с акторами и общими системами.
        // Один профиль для обеих ролей: роль определяется тем, какую фазу
        // протокола сейчас проходят (0-11 или 12+), а не разными профилями Hermes.
        // Передача работы это ручная эстафета на конкретном GATE.
        engineer -> prod.hermes_agent "hermes -p migration-copilot chat; подтверждает GATE (фазы 0-11)" "терминал / CLI"
        mlops -> prod.hermes_agent "Тот же профиль, с фазы CI (12+); принимает работу после сравнения" "терминал / CLI"

        // Ревью содержания: двойной approve на каждый PR со skill независимо
        // от фазы (skill может затрагивать и модельную, и CI-часть).
        skillsOwner -> prod.skills_distribution "Ревью PR (экспертиза по ML и миграции): approve обязателен для merge" "git PR review"
        mlopsReviewer -> prod.skills_distribution "Ревью PR (экспертиза по CI и развёртыванию): approve обязателен для merge, наравне со Skills Owner" "git PR review"

        // Релизный цикл целиком в руках DevOps; роли, проверяющие содержание, релиз не трогают.
        devops -> prod.gateway "Владеет инфраструктурой: настраивает авто-релиз на merge, следит за внедрением и аналитикой" "admin"
        devops -> prod.skills_distribution "Выполняет технический rollback: git revert и новый тег, по запросу Skills Owner" "git, при инциденте"

        // Rollback: узкое действие Skills Owner с журналом аудита, без доступа к
        // инфраструктуре Gateway и CI (см. ADR-003: решение о содержании у Skills
        // Owner, техническое исполнение у DevOps).
        skillsOwner -> prod.gateway.gw_rollback "rollback(version) при «отравленном» skill (по сигналу Skill Analytics или при всплеске отклонений на GATE)" "HTTP, с аудитом"
        prod.gateway.gw_rollback -> devops "Уведомление: инициирован rollback, DevOps выполняет git revert и тег" "журнал аудита"

        engineer -> prod.skills_distribution "Открывает Pull Request с новым или изменённым skill (обычный git commit/push)" "git"
        mlops -> prod.skills_distribution "Открывает Pull Request с новым или изменённым skill (обычный git commit/push)" "git"
        engineer -> skillsOwner "Просит ревью PR" "git PR"
        engineer -> mlopsReviewer "Просит ревью PR" "git PR"
        lead -> obs "Смотрит дашборды (здоровье, внедрение, динамика качества), реагирует на алерты. Общее владение продуктом, без прямого участия в ревью и релизе" "Grafana"

        prod -> miglib "Библиотека migration генерирует project-skills дистрибуции (phase-NN в SKILL.md)" "кодогенерация при релизе библиотеки"
        prod -> registry "Ставит библиотеку, публикует артефакты .onnx и .engine" "pip/uv, загрузка"

        prod.hermes_agent -> obs "Метрики и логи (если настроен OTLP-плагин; Hermes сам пишет логи в agent.log)" "OTLP / scrape, опционально"
        prod.gateway -> obs "Метрики внедрения и аналитики: доля команды на актуальной версии, доля успешных применений skills" "OTLP / scrape"
        prod.skills_distribution -> idp "Приватный git-репозиторий, доступ через существующую git-аутентификацию (SSH/PAT), без отдельного контура OIDC" "git auth (SSH/PAT)"
        prod.gateway -> idp "Аутентификация для Gateway API (profile update, rollback), RBAC: rollback только для роли Skills Owner" "OIDC / service auth"

        // =====================================================================
        //  Развёртывание (Production): гибридная топология. Git-хостинг остаётся
        //  единственным источником истины для содержимого skills_distribution,
        //  Central Gateway это новый on-prem сервис (владелец DevOps), который
        //  скрывает релизный цикл от DS/MLOps-инженера. Он размещён рядом с
        //  кластером инференса LLM в том же корпоративном контуре и не требует
        //  прямого доступа рабочей станции инженера к внешнему git (ADR-003).
        // =====================================================================
        deploymentEnvironment "Production" {

            deploymentNode "Рабочая станция инженера" "" "Linux / macOS" {
                deploymentNode "Процесс профиля Hermes" "" "hermes -p migration-copilot" {
                    containerInstance prod.hermes_agent
                }
                deploymentNode "Локальный профиль (~/.hermes/profiles/migration-copilot)" "" "на диске, данные пользователя исключены из skills_distribution" {
                    containerInstance prod.gate_plugin
                }
            }

            deploymentNode "Git-хостинг команды" "существующий GitLab/GitHub, отдельный сервер не поднимаем" "" {
                containerInstance prod.skills_distribution
            }

            deploymentNode "Корпоративный контур (on-prem, без прямого доступа рабочей станции к внешнему git)" "" {
                deploymentNode "Central Gateway" "владелец: DevOps" "" {
                    containerInstance prod.gateway
                }
            }

            deploymentNode "Кластер инференса LLM" "GPU-узлы, on-prem" "" {
                deploymentNode "Балансировщик нагрузки" "проверка состояния и переключение при отказе" "" {
                    deploymentNode "Основная зона" "GPU-узлы" "" {
                        containerInstance prod.hermes_llm
                    }
                    deploymentNode "Резервная зона" "GPU-узлы (резервный инстанс для fallback_providers)" "" {
                        containerInstance prod.hermes_llm
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

        // ---------- Production views (Hermes) ----------
        systemContext prod "Prod_C1_Context" {
            include *
            autolayout lr
            description "C1, контекст системы (Production, Hermes): один Profile Distribution на обе роли"
        }

        container prod "Prod_C2_Container" {
            include *
            autolayout lr
            description "C2, контейнеры (Production): Hermes AIAgent (внешняя технология), наш код (Migration Gate Plugin) и Central Gateway. Гибридная топология релиза skills_distribution (ADR-003), git остаётся единственным источником истины содержимого"
        }

        component prod.hermes_agent "Prod_C3_Component_HermesAgent" {
            include *
            autolayout lr
            description "C3, компоненты (Production): встроенные компоненты Hermes AIAgent (terminal, delegate_task, skills, fallback, memory; это не наш код) и наш плагин migration_gate, который перехватывается тем же путём, что встроенные memory и todo"
        }

        component prod.gateway "Prod_C3_Component_Gateway" {
            include *
            autolayout lr
            description "C3, компоненты (Production): Central Gateway. Release Manifest Service (тонкий слой метаданных над git), Adoption Tracker и Skill Analytics Aggregator (обезличенные метрики), Rollback Trigger (узкая операция с аудитом для Skills Owner)"
        }

        deployment prod "Production" "Prod_C4_Deployment" {
            include *
            autolayout lr
            description "C4, развёртывание (Production): git-хостинг как источник истины содержимого; Central Gateway как новый on-prem сервис в корпоративном контуре рядом с кластером LLM, скрывающий релизный цикл от рабочей станции инженера без прямого доступа к внешнему git"
        }

        // Последовательность: путь одного skill от локальной находки DS-инженера до
        // появления у остальных. Это человеческий процесс с обязательным ревью,
        // задокументированная практика Hermes для командного обмена, а не наша надстройка.
        dynamic prod "Prod_Skill_Sharing" {
            engineer -> prod.hermes_agent "1. Работает по протоколу; фоновый self-improvement review (или явная команда /learn) сохраняет находку локально как SKILL.md"
            engineer -> prod.hermes_agent "2. Проверяет: hermes skills list и skills diff (если включён write_approval), при необходимости правит"
            engineer -> prod.skills_distribution "3. Решает поделиться: копирует SKILL.md в клон репозитория skills_distribution, коммитит, пушит в ветку (обычный git, этот шаг не скрыт за Gateway)"
            engineer -> skillsOwner "4a. Открывает Pull Request с новым или изменённым skill"
            engineer -> mlopsReviewer "4b. Тот же PR: ревью нужно от обеих ролей"
            skillsOwner -> prod.skills_distribution "5a. Ревью содержания (экспертиза по ML и миграции): approve"
            mlopsReviewer -> prod.skills_distribution "5b. Ревью содержания (экспертиза по CI и развёртыванию): approve; merge требует обоих approve"
            prod.skills_distribution -> prod.gateway "6. CI-джоб на push тега: повышает версию, генерирует manifest.json, публикует в Release Manifest Service автоматически, без участия ревьюеров"
            prod.gateway -> prod.hermes_agent "7. hermes profile update: каждый инженер подтягивает новый skill через Gateway API, а не через git"

            autolayout lr
            description "Путь одного skill от локальной находки DS-инженера до появления у всей команды: ревью с двойным approve (Skills Owner и MLOps Reviewer), авто-релиз в CI, раздача через Central Gateway (ADR-003, гибридная топология)"
        }

        // Последовательность: релизный цикл и rollback целиком в зоне ответственности
        // DevOps и Skills Owner, отдельно от ревью содержания выше.
        dynamic prod "Prod_Release_Rollback_Flow" {
            prod.skills_distribution -> prod.gateway "1. Forward-релиз: CI на каждый merge в main автоматически повышает версию, ставит тег и публикует манифест, ручного шага нет"
            prod.gateway -> prod.hermes_agent "2. Все профили подтягивают новую версию при следующем hermes profile update"
            prod.hermes_agent -> prod.gateway "3. Обезличенные сигналы: чекины внедрения и статистика успехов и ошибок по skill (Skill Analytics Aggregator)"
            skillsOwner -> prod.gateway "4. Skills Owner замечает «отравленный» skill (по аналитике или по всплеску отклонений на GATE) и вызывает rollback(version): узкая операция с аудитом, без доступа к инфраструктуре Gateway и CI"
            prod.gateway -> devops "5. Уведомление DevOps о rollback (журнал аудита)"
            devops -> prod.skills_distribution "6. DevOps выполняет технический откат: git revert и новый тег, тем же механизмом, что обычный релиз (вариант B1: git остаётся единственным источником истины)"
            prod.skills_distribution -> prod.gateway "7. CI публикует revert-релиз как обычный новый тег"

            autolayout lr
            description "Forward-релиз полностью автоматический (CI на merge); rollback единственный ручной путь: решение о содержании у Skills Owner (rollback trigger), техническое исполнение у DevOps (git revert). Skills Owner и MLOps Reviewer доступа к инфраструктуре Gateway и CI не имеют"
        }

        // Последовательность: путь одного факта в memory (MEMORY.md и USER.md).
        // В отличие от skills, memory физически не может уйти через skills_distribution:
        // Hermes жёстко исключает memories/ (по их формулировке, инвариант, покрытый
        // регрессионными тестами), а не просто рекомендует, и обойти это конфигом нельзя.
        // Поэтому единственный способ поделиться содержимым: переписать факт как skill
        // и пройти тот же PR-путь, что на предыдущей диаграмме. Иначе факт остаётся
        // строго локальным навсегда.
        dynamic prod "Prod_Memory_Handling" {
            engineer -> prod.hermes_agent "1. Работает по протоколу; фоновый self-improvement review (или явный запрос) сохраняет короткий факт в MEMORY.md или USER.md, только локально, на профиль"
            engineer -> prod.hermes_agent "2. Факт остаётся только на этой машине: memories/ жёстко исключён из skills_distribution (инвариант Hermes, покрытый регрессионными тестами, а не настройка), поэтому не коммитится, не пушится и не передаётся"
            engineer -> prod.hermes_agent "3a. Обычный случай: факт остаётся локальным, потому что специфичен для этой машины или сессии (пути, локальные учётные данные, личные предпочтения инженера)"
            engineer -> prod.hermes_agent "3b. Факт оказался ценным для команды (например, воспроизводимая проблема окружения): инженер вручную переформулирует его как SKILL.md. Memory не экспортируется, а только пересоздаётся в другом формате"
            engineer -> prod.skills_distribution "4. Дальше тот же PR-путь, что и для skills (см. Prod_Skill_Sharing): коммит, PR, двойной approve (Skills Owner и MLOps Reviewer), релиз через Gateway"

            autolayout lr
            description "Путь одного факта в MEMORY.md и USER.md: по умолчанию остаётся локальным навсегда (жёстко исключён из skills_distribution, «инвариант, покрытый регрессионными тестами» в терминах Hermes). Единственный путь до команды: вручную переписать как skill и пройти PR-процесс с предыдущей диаграммы"
        }

        // ---------- MVP views ----------
        systemContext mvp "MVP_C1_Context" {
            include *
            autolayout lr
            description "C1, контекст системы (MVP, Qwen Code): всё локально у инженера"
        }

        container mvp "MVP_C2_Container" {
            include *
            autolayout lr
            description "C2, контейнеры (MVP): интеграция библиотеки migration"
        }

        component mvp.mvp_qwen "MVP_C3_Component_AIService" {
            include *
            autolayout lr
            description "C3, компоненты (MVP): AI Service = Qwen Code и локальная LLM"
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
