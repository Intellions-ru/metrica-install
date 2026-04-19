# Интеллион Метрика — Self-Hosted Install

Публичный канал установки Интеллион Метрика.

Что здесь лежит:
- `install_metrica.sh` — основной установщик
- `README_SELF_HOSTED_INSTALL.md` — основная инструкция для self-hosted установки
- `README_SELF_HOSTED_EXAMPLE_BEAUTY_DOC.md` — пример под beauty-doc.pro
- GitHub Releases — install bundle по версиям

Рекомендуемая команда:
```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/main/install_metrica.sh | sudo bash -s -- \
  --publish-mode path \
  --domain example.com \
  --entry-path /analytics \
  --owner-email owner@example.com \
  --installation-name "Example Analytics"
```

Если нужен зафиксированный релиз, используйте tag-URL, например `v0.1.0`:
```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/v0.1.0/install_metrica.sh | sudo bash -s -- \
  --publish-mode path \
  --domain example.com \
  --entry-path /analytics \
  --owner-email owner@example.com \
  --installation-name "Example Analytics"
```
