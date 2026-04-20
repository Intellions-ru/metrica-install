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
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.2.0/install_metrica.sh | sudo bash -s -- \
  --publish-mode attach-path \
  --domain example.com \
  --entry-path /metrica \
  --installation-name "Example Analytics" \
  --owner-email owner@example.com
```

Если нужен полный buyer-facing путь со всеми шагами, открывайте:

- `README_SELF_HOSTED_INSTALL.md`
