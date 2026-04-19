# Интеллион Метрика — Self-Hosted Install

Этот репозиторий нужен как публичный канал установки Интеллион Метрика.

Что здесь лежит:
- `install_metrica.sh` — основной установщик
- `README_SELF_HOSTED_INSTALL.md` — инструкция для self-hosted установки
- `README_SELF_HOSTED_EXAMPLE_BEAUTY_DOC.md` — пример установки для beauty-doc.pro
- GitHub Releases — install bundle для конкретных версий

Рекомендуемый путь установки:
1. Откройте `README_SELF_HOSTED_INSTALL.md`
2. Возьмите актуальную версию install bundle из Releases
3. Запустите installer по прямой ссылке или из bundle

Пример формата:
```bash
curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/main/install_metrica.sh | sudo bash -s -- \
  --publish-mode path \
  --domain example.com \
  --entry-path /analytics \
  --owner-email owner@example.com \
  --installation-name "Example Analytics" \
  --bundle-url https://github.com/Intellions-ru/metrica-install/releases/download/v0.1.0/intellion-metrica-install-bundle-v0.1.0.tar.gz \
  --image-registry ghcr.io/Intellions-ru
```
