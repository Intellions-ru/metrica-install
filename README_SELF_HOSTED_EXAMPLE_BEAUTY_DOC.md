# Пример self-hosted установки для beauty-doc.pro

Этот документ показывает пример установки `Интеллион Метрика` для проекта `beauty-doc.pro`.

Это именно пример. Он нужен, чтобы было проще увидеть живой сценарий установки и первого подключения сайта.

## Основная схема

Для `beauty-doc.pro` можно выводить на первый план такой адрес:

- `beauty-doc.pro/analytics`

Почему так:

- не нужен отдельный поддомен;
- клиенту проще воспринимать вход на своем основном домене;
- это удобнее как базовый коммерческий сценарий.

## Что должно быть подготовлено

- Linux-сервер с SSH-доступом;
- домен `beauty-doc.pro`, уже направленный на сервер;
- почта владельца;
- install bundle или прямая install-ссылка от Intellions.

Пример значений:

- installation name: `Beauty Doc Analytics`
- owner email: `owner@beauty-doc.pro`

## Пример команды установки

Если у вас уже есть install bundle:

```bash
curl -fLO https://github.com/Intellions-ru/metrica-install/releases/download/v0.1.0/intellion-metrica-install-bundle-v0.1.0.tar.gz
```

```bash
tar -xzf intellion-metrica-install-bundle-<version>.tar.gz
cd intellion-metrica-install-bundle-<version>
```

```bash
sudo bash ./scripts/install_metrica.sh \
  --publish-mode path \
  --domain beauty-doc.pro \
  --entry-path /analytics \
  --installation-name "Beauty Doc Analytics" \
  --owner-email owner@beauty-doc.pro
```

Если Intellions передала прямую install-ссылку:

```bash
curl -fsSL <INSTALLER_URL_FROM_INTELLIONS> | sudo bash -s -- \
  --publish-mode path \
  --domain beauty-doc.pro \
  --entry-path /analytics \
  --installation-name "Beauty Doc Analytics" \
  --owner-email owner@beauty-doc.pro
```

## Что должно получиться после установки

- входная точка доступна по адресу `https://beauty-doc.pro/analytics`
- есть файл `/opt/intellion-metrica/state/owner-activation.txt`
- владелец активируется по одноразовой ссылке
- после активации можно войти в Метрику

## Пример первого входа

### Шаг 1. Получите ссылку активации

```bash
cat /opt/intellion-metrica/state/owner-activation.txt
```

### Шаг 2. Откройте ссылку

Откройте ссылку в браузере и задайте пароль владельца.

### Шаг 3. Войдите в панель

Адрес входа:

- `https://beauty-doc.pro/analytics`

## Пример подключения сайта beauty-doc.pro

### Шаг 1. Добавьте сайт в панели

В `Управление -> Сайты` создайте сайт со значениями такого типа:

- код сайта: `beauty-doc-pro`
- название: `Beauty Doc`
- основной домен: `beauty-doc.pro`
- разрешенные домены:
  - `beauty-doc.pro`
  - `www.beauty-doc.pro`

### Шаг 2. Подготовьте same-site proxy на основном сайте

На стороне сайта используйте локальные маршруты:

- `/api/analytics/collect`
- `/api/analytics/consent`

Они должны проксировать запросы в:

- `https://beauty-doc.pro/api/collect`
- `https://beauty-doc.pro/api/consent`

С использованием:

- `siteCode = beauty-doc-pro`
- signed ingest secret, который показан в панели Метрики для этого сайта

### Шаг 3. Включите frontend tracking

Браузер должен отправлять запросы в same-site маршруты сайта, а не напрямую в панель.

Минимально проверьте:

- consent передается в `/api/analytics/consent`
- page view и формы передаются в `/api/analytics/collect`

## Пример базовых целей для beauty-doc.pro

Для первого рабочего набора достаточно 4–6 целей:

1. `Просмотр ключевой страницы`
   - тип: `page_view`
   - пример: страница услуги или главная

2. `Отправка формы`
   - тип: `form_submit`
   - пример: заявка на консультацию

3. `Клик по Telegram`
   - тип: `outbound_click`

4. `Клик по WhatsApp`
   - тип: `outbound_click`

5. `Переход к записи`
   - тип: `cta_click`

6. `Просмотр страницы тарифов`
   - тип: `page_view`

Для первого запуска этого достаточно. Не нужно пытаться сразу описать все действия сайта.

## Как понять, что все подключено правильно

Проверьте по порядку:

1. вход `beauty-doc.pro/analytics` открывается;
2. владелец вошел;
3. сайт `beauty-doc.pro` добавлен;
4. запрос согласия доходит до `/api/analytics/consent`;
5. page view доходит до `/api/analytics/collect`;
6. в обзоре Метрики появляются первые данные;
7. цели можно создать и привязать к событиям.

## Где смотреть, если что-то пошло не так

- install log:
  - `/opt/intellion-metrica/logs/install-<timestamp>.log`
- install summary:
  - `/opt/intellion-metrica/artifacts/install/<timestamp>-one-command-install/install-summary.json`
- файл активации владельца:
  - `/opt/intellion-metrica/state/owner-activation.txt`

## Если нужен отдельный поддомен

Для `beauty-doc.pro` можно также использовать:

- `analytics.beauty-doc.pro`

Это отдельный вариант, если нужно развести основной сайт и панель по разным адресам.

## Честный статус этого примера

Что уже соответствует продуктовой модели:

- path-публикация через `/analytics`;
- owner activation flow;
- self-hosted installer;
- signed ingest / consent;
- добавление сайта через панель.

Что еще стоит обязательно прогнать на живом запуске:

- полный внешний install именно под `beauty-doc.pro/analytics`;
- first event flow с основного сайта `beauty-doc.pro`;
- проверку первых целей на реальном трафике.
