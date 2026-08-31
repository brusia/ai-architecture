# Архитектура (C4)

C4-модель системы описана в [`workspace.dsl`](workspace.dsl) на языке [Structurizr DSL](https://docs.structurizr.com/dsl).
Диаграммы уровней C1–C4 для MVP и Prod генерируются автоматически.

## Просмотр опубликованного сайта

При каждом push в `main` (с изменениями в `docs/architecture/**`) CI собирает статичный сайт
и публикует его на **GitHub Pages** — с кликабельной навигацией между уровнями C1→C4.

Ссылка появится после первого успешного прогона workflow **Build C4 site**
(Actions → Build C4 site → deploy), обычно вида `https://<owner>.github.io/<repo>/`.

> Разовая настройка: в репозитории **Settings → Pages → Source = GitHub Actions**.

## Локальный просмотр и отладка

Нужен только Docker. Запусти:

```bash
./docs/architecture/serve.sh
```

Открой <http://localhost:8080>. Правь `workspace.dsl` — сайт перерисуется автоматически (live-reload).
Выход — `Ctrl+C`. Порт можно поменять: `PORT=9000 ./docs/architecture/serve.sh`.

> **Важно:** сайт нужно смотреть только через сервер (`serve.sh` или GitHub Pages).
> Открывать файлы из `build/site` напрямую в браузере (`file://` или файловым листингом) нельзя —
> увидишь список файлов (`index.html`, `index.html.md5`) вместо страницы. Это не поломка сайта,
> а особенность статики: главная — это мета-редирект на `main/`, а индекс директории отдаёт только веб-сервер.

## Разовая генерация статики (как в CI)

Обычно не нужна — для просмотра используй `serve.sh`. Пригодится, только если хочешь проверить
ровно тот набор файлов, что уйдёт на Pages. Запускать из корня репозитория:

```bash
docker run --rm \
  -v "$(pwd):/var/model" \
  -w /var/model \
  ghcr.io/avisi-cloud/structurizr-site-generatr:latest \
  generate-site \
    --workspace-file docs/architecture/workspace.dsl \
    --assets-dir docs/architecture/assets \
    --output-dir build/site \
    --default-branch main
```

Результат — в корневой папке `build/site/` (папка `build/` уже в `.gitignore`, не коммитится).
