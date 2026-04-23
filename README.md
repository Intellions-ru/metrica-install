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

Используйте именно актуальную команду ниже.
Старые теги вроде `v0.2.8`, `v0.2.9`, `v0.2.10` для новых установок не используйте.

```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.2.11/install_metrica.sh | sudo bash
```

Installer сам спросит:

- домен
- имя установки
- почту первого владельца
- почту для TLS
- настройку MAX

Режим `attach-path` и путь `/metrica` installer выбирает сам по умолчанию.

Если нужно заранее передать значения без интерактивных вопросов:

```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.2.11/install_metrica.sh | sudo bash -s -- \
  --publish-mode attach-path \
  --domain YOUR_DOMAIN \
  --entry-path /metrica \
  --installation-name "YOUR INSTALLATION NAME" \
  --owner-email YOUR_EMAIL
```

Во время интерактивной установки может появиться вопрос:

```text
Введите почту для TLS-уведомлений [YOUR_EMAIL]:
```

Если почта для TLS-уведомлений должна быть той же самой, просто нажмите `Enter`.

Также установщик может спросить:

```text
Настроить MAX-бота сейчас? [y/N]:
```

Отвечайте `y` только если токен MAX уже готов.

Если вы ответили `y`, а потом передумали, на шаге

```text
Введите токен MAX-бота (Enter чтобы пропустить):
```

можно просто нажать `Enter`. Установка продолжится без настройки MAX-бота.

Что происходит с `/metrica`:

- в основном сценарии `attach-path` installer пытается безопасно подключить путь `/metrica` в host `nginx` или `dockerized nginx` автоматически;
- это касается и случая, когда `dockerized nginx` смонтирован не директорией, а одним bind-mounted `nginx.conf`;
- если не удается однозначно и безопасно изменить боевой `nginx`, installer ничего не ломает и оставляет готовый proxy-шаблон для ручного подключения.

Что стало проще в типовой установке:

- первый сайт создается автоматически из домена установки;
- в сценарии `тот же сервер + /metrica + nginx` loader Метрики подключается автоматически;
- после активации владельца и первых заходов на сайт базовые просмотры и действия должны начать появляться в обзоре без ручной вставки трекера.

Для самого простого старта лучше использовать versioned install bundle из Releases:

- `intellion-metrica-install-bundle-v0.2.11.tar.gz`

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
