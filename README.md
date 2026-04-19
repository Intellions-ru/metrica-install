# Интеллион Метрика — Self-Hosted Install

Публичный канал установки Интеллион Метрика.

Что здесь лежит:
- `install_metrica.sh` — основной установщик
- `README_SELF_HOSTED_INSTALL.md` — основная инструкция для self-hosted установки
- `README_SELF_HOSTED_MANUAL_TESTS.md` — ручной чек-лист после установки
- GitHub Releases — install bundle по версиям

Рекомендуемый путь:
1. Откройте `README_SELF_HOSTED_INSTALL.md`
2. Возьмите актуальный install bundle из Releases или запустите installer по прямой ссылке
3. После установки пройдите `README_SELF_HOSTED_MANUAL_TESTS.md`

Базовая команда:
```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.1.0/install_metrica.sh | sudo bash -s -- \
  --publish-mode path \
  --domain example.com \
  --entry-path /analytics \
  --owner-email owner@example.com \
  --installation-name "Example Analytics"
```
