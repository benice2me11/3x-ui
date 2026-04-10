[English](/README.md) | [فارسی](/README.fa_IR.md) | [العربية](/README.ar_EG.md) |  [中文](/README.zh_CN.md) | [Español](/README.es_ES.md) | [Русский](/README.ru_RU.md)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./media/3x-ui-dark.png">
    <img alt="3x-ui" src="./media/3x-ui-light.png">
  </picture>
</p>

[![Release](https://img.shields.io/github/v/release/mhsanaei/3x-ui.svg)](https://github.com/MHSanaei/3x-ui/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/mhsanaei/3x-ui/release.yml.svg)](https://github.com/MHSanaei/3x-ui/actions)
[![GO Version](https://img.shields.io/github/go-mod/go-version/mhsanaei/3x-ui.svg)](#)
[![Downloads](https://img.shields.io/github/downloads/mhsanaei/3x-ui/total.svg)](https://github.com/MHSanaei/3x-ui/releases/latest)
[![License](https://img.shields.io/badge/license-GPL%20V3-blue.svg?longCache=true)](https://www.gnu.org/licenses/gpl-3.0.en.html)
[![Go Reference](https://pkg.go.dev/badge/github.com/mhsanaei/3x-ui/v2.svg)](https://pkg.go.dev/github.com/mhsanaei/3x-ui/v2)
[![Go Report Card](https://goreportcard.com/badge/github.com/mhsanaei/3x-ui/v2)](https://goreportcard.com/report/github.com/mhsanaei/3x-ui/v2)

**3X-UI** — продвинутая панель управления с открытым исходным кодом на основе веб-интерфейса, разработанная для управления сервером Xray-core. Предоставляет удобный интерфейс для настройки и мониторинга различных VPN и прокси-протоколов.

> [!IMPORTANT]
> Этот проект предназначен только для личного использования, пожалуйста, не используйте его в незаконных целях и в производственной среде.

Как улучшенная версия оригинального проекта X-UI, 3X-UI обеспечивает повышенную стабильность, более широкую поддержку протоколов и дополнительные функции.

## Быстрый старт

```
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

Полную документацию смотрите в [вики проекта](https://github.com/MHSanaei/3x-ui/wiki).

## Автоматическая установка на VPS (Fork)

В репозитории есть скрипт `auto-bootstrap.sh` для развёртывания на чистом VPS в один запуск:
- ставит и настраивает 3x-ui + бинарник из вашего форка,
- создаёт единый `subId` с `reality + ws + xhttp + grpc + hysteria2`,
- настраивает TLS, nginx stream-маршрутизацию и JSON API-маску,
- включает HY2 с `obfs: salamander`,
- задаёт правила для JSON-подписки (`RU/private -> direct`, `ads/bittorrent -> block`).

Пример запуска:

```bash
curl -fsSL https://raw.githubusercontent.com/<ваш-user>/3x-ui/main/auto-bootstrap.sh -o auto-bootstrap.sh
chmod +x auto-bootstrap.sh
sudo ./auto-bootstrap.sh \
  -subdomain cdn-files.example.com \
  -reality_domain cdn-highload.example.com \
  -hy2_domain cdn-files.example.com \
  -fork_repo <ваш-user>/3x-ui \
  -fork_ref main \
  -client_name first
```

Для VPS с маленькой RAM можно пропустить локальную сборку форка:

```bash
sudo SKIP_FORK_OVERLAY=1 ./auto-bootstrap.sh ...
```

Поведение подписок после установки:
- Base64/URI подписка содержит все протоколы, включая HY2.
- JSON-подписка содержит правила маршрутизации; в URI-линках правила маршрутизации не передаются.
- Текущий генератор JSON не добавляет outbound HY2; HY2 остаётся доступен в URI-подписке.

## Интеграция Hysteria2 (apernet) (Экспериментально)

- На главной странице добавлена отдельная карточка `Hysteria2 (apernet)` с действиями: `Install`, `Start`, `Stop`, `Restart`, `Logs`.
- В UI доступно управление пользователями HY2 (`Users`):
  - переключение `auth.type` в `userpass`,
  - добавление/обновление/удаление пользователей,
  - принудительное отключение активных сессий (`kick`),
  - генерация и копирование `hysteria2://` ссылок.
- Установка скачивает актуальный бинарник из `apernet/hysteria` и подготавливает:
  - `/usr/local/bin/hysteria`
  - `/etc/hysteria/config.yaml`
  - `/etc/systemd/system/hysteria2.service`
- Перед запуском отредактируйте `/etc/hysteria/config.yaml` (домен, auth, сертификаты), затем запускайте сервис из UI.
- Мониторинг трафика использует настройки `trafficStats.listen` и `trafficStats.secret` из этого конфига.

## Особая благодарность

- [alireza0](https://github.com/alireza0/)

## Благодарности

- [Iran v2ray rules](https://github.com/chocolate4u/Iran-v2ray-rules) (Лицензия: **GPL-3.0**): _Улучшенные правила маршрутизации для v2ray/xray и v2ray/xray-clients со встроенными иранскими доменами и фокусом на безопасность и блокировку рекламы._
- [Russia v2ray rules](https://github.com/runetfreedom/russia-v2ray-rules-dat) (Лицензия: **GPL-3.0**): _Этот репозиторий содержит автоматически обновляемые правила маршрутизации V2Ray на основе данных о заблокированных доменах и адресах в России._

## Поддержка проекта

**Если этот проект полезен для вас, вы можете поставить ему**:star2:

<a href="https://www.buymeacoffee.com/MHSanaei" target="_blank">
<img src="./media/default-yellow.png" alt="Buy Me A Coffee" style="height: 70px !important;width: 277px !important;" >
</a>

</br>
<a href="https://nowpayments.io/donation/hsanaei" target="_blank" rel="noreferrer noopener">
   <img src="./media/donation-button-black.svg" alt="Crypto donation button by NOWPayments">
</a>

## Звезды с течением времени

[![Stargazers over time](https://starchart.cc/MHSanaei/3x-ui.svg?variant=adaptive)](https://starchart.cc/MHSanaei/3x-ui) 
