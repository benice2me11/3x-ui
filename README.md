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

**3X-UI** — advanced, open-source web-based control panel designed for managing Xray-core server. It offers a user-friendly interface for configuring and monitoring various VPN and proxy protocols.

> [!IMPORTANT]
> This project is only for personal usage, please do not use it for illegal purposes, and please do not use it in a production environment.

As an enhanced fork of the original X-UI project, 3X-UI provides improved stability, broader protocol support, and additional features.

## Automated VPS Bootstrap (Fork)

This repository also includes `auto-bootstrap.sh` for one-shot deployment on a fresh VPS:
- installs and configures 3x-ui + fork overlay build from `benice2me11/3x-ui` (default),
- provisions one subscription id with `reality + ws + xhttp + grpc + hysteria2`,
- enables TLS, nginx stream routing, API-like JSON mask endpoints,
- enables HY2 with `obfs: salamander`,
- applies JSON subscription split-routing defaults (`RU/private -> direct`, `ads/bittorrent -> block`).

Install from this fork:

```bash
curl -fsSL https://raw.githubusercontent.com/benice2me11/3x-ui/main/auto-bootstrap.sh -o auto-bootstrap.sh
chmod +x auto-bootstrap.sh
sudo ./auto-bootstrap.sh \
  -subdomain cdn-files.example.com \
  -reality_domain cdn-highload.example.com \
  -hy2_domain cdn-files.example.com \
  -fork_ref main \
  -client_name first
```

`-fork_repo` is optional. By default the script uses `benice2me11/3x-ui`.

Low-memory servers can skip local fork build:

```bash
sudo SKIP_FORK_OVERLAY=1 ./auto-bootstrap.sh ...
```

Subscription behavior after install:
- Base64 URI subscription contains all protocols, including HY2.
- JSON subscription contains routing rules; URI links do not carry routing rules.
- Current JSON generator does not include HY2 outbound; HY2 remains available in URI subscription.

For full documentation, please visit the [fork Wiki](https://github.com/benice2me11/3x-ui/wiki).

## Hysteria2 (apernet) Integration (Experimental)

- The dashboard includes a dedicated `Hysteria2 (apernet)` card with `Install`, `Start`, `Stop`, `Restart`, and `Logs`.
- HY2 user management is available in UI (`Users`):
  - switch `auth.type` to `userpass`,
  - add/update/delete users,
  - kick active sessions,
  - generate and copy `hysteria2://` links.
- The installer downloads the latest official binary from `apernet/hysteria` and prepares:
  - `/usr/local/bin/hysteria`
  - `/etc/hysteria/config.yaml`
  - `/etc/systemd/system/hysteria2.service`
- Edit `/etc/hysteria/config.yaml` first (domain/auth/cert settings), then start the service from the dashboard.
- Runtime monitoring reads HY2 traffic stats from `trafficStats.listen` / `trafficStats.secret` in that config.

## Acknowledgment

- [Iran v2ray rules](https://github.com/chocolate4u/Iran-v2ray-rules) (License: **GPL-3.0**): _Enhanced v2ray/xray and v2ray/xray-clients routing rules with built-in Iranian domains and a focus on security and adblocking._
- [Russia v2ray rules](https://github.com/runetfreedom/russia-v2ray-rules-dat) (License: **GPL-3.0**): _This repository contains automatically updated V2Ray routing rules based on data on blocked domains and addresses in Russia._

## Stargazers over Time

[![Stargazers over time](https://starchart.cc/MHSanaei/3x-ui.svg?variant=adaptive)](https://starchart.cc/MHSanaei/3x-ui)
