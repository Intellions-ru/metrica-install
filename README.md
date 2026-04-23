# Интеллион Метрика — Self-Hosted Install

Публичный канал установки `Интеллион Метрика`.

Здесь лежит только то, что нужно клиенту для запуска:

- `install_metrica.sh` — основной установщик
- `README_SELF_HOSTED_INSTALL.md` — основная инструкция
- `README_SELF_HOSTED_MANUAL_TESTS.md` — ручная проверка после установки
- GitHub Releases — versioned install bundle

Основная модель публикации:

- основной режим — тот же сервер и путь `/metrica`
- второй режим — отдельный поддомен
- standalone — только дополнительный вариант

Рекомендуемый старт:

```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.2.4/install_metrica.sh | sudo bash -s -- \
  --publish-mode attach-path \
  --domain YOUR_DOMAIN \
  --entry-path /metrica \
  --installation-name "YOUR INSTALLATION NAME" \
  --owner-email YOUR_EMAIL
```

Что заменить в команде:

- `YOUR_DOMAIN` — домен клиента
- `YOUR INSTALLATION NAME` — имя установки
- `YOUR_EMAIL` — почта первого владельца

Во время интерактивной установки может появиться вопрос:

```text
Email for TLS notifications [YOUR_EMAIL]:
```

Если почта для TLS-уведомлений должна быть той же самой, просто нажмите `Enter`.

Также установщик может спросить:

```text
Configure MAX bot now? [y/N]:
```

Отвечайте `y` только если токен MAX уже готов.

Если вы ответили `y`, а потом передумали, на шаге

```text
MAX bot token (leave empty to skip):
```

можно просто нажать `Enter`. Установка продолжится без настройки MAX-бота.

Что происходит с `/metrica`:

- в основном сценарии `attach-path` installer пытается безопасно подключить путь `/metrica` в `nginx` автоматически;
- если не удается однозначно и безопасно изменить боевой `nginx`, installer ничего не ломает и оставляет готовый proxy-шаблон для ручного подключения.

Для самого простого старта лучше использовать versioned install bundle из Releases:

- `intellion-metrica-install-bundle-v0.2.4.tar.gz`

Он уже включает product images, поэтому отдельный Docker registry login для обычной установки не нужен.

Если нужен полный buyer-facing путь со всеми шагами, открывайте:

- `README_SELF_HOSTED_INSTALL.md`

Безопасное удаление после установки:

```bash
sudo bash /opt/intellion-metrica/scripts/uninstall_metrica.sh --yes
```

Полное удаление с backup перед purge:

```bash
sudo bash /opt/intellion-metrica/scripts/uninstall_metrica.sh --yes --purge-all
```
