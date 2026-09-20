# NetlumaVPN Fresh Server Redeploy

Эта инструкция нужна для случая, когда старый VPS больше не используется, а новый сервер пустой и получил новый IPv4.

Целевой домен: `netlumavpn.example`.

## Что подготовлено в репозитории

- `ops/deploy-fresh-server.sh` копирует `ops/` и `server_mvp/` на новый VPS и запускает полный bootstrap.
- `ops/provision-fresh-server.sh` ставит nginx, Xray, WireGuard, FastAPI admin/API, systemd units, fail2ban, ufw и выпускает Let's Encrypt сертификат.
- `ops/verify-fresh-server.sh` проверяет DNS, HTTPS admin, API и mobile API.
- `ops/quickvpn.env.example` показывает итоговую структуру `/etc/quickvpn/quickvpn.env` без секретов.

## 1. DNS перед запуском bootstrap

После получения нового IPv4 создайте или обновите A-записи:

```text
netlumavpn.example         A   NEW_SERVER_IP
www.netlumavpn.example     A   NEW_SERVER_IP
api.netlumavpn.example     A   NEW_SERVER_IP
admin.netlumavpn.example   A   NEW_SERVER_IP
vpn.netlumavpn.example     A   NEW_SERVER_IP
trojan.netlumavpn.example  A   NEW_SERVER_IP
```

AAAA-записи пока не добавлять. Если домен подключен через Cloudflare, все эти записи ставить в режим **DNS only**, без проксирования.

Проверка с локального компьютера:

```bash
dig +short A api.netlumavpn.example
dig +short A admin.netlumavpn.example
dig +short A vpn.netlumavpn.example
dig +short A trojan.netlumavpn.example
```

Все ответы должны вернуть новый IP. Let's Encrypt выпуск сертификата не пройдет, пока DNS не указывает на новый VPS.

## 2. Запуск раскатки

На локальной машине из корня репозитория:

```bash
NEW_SERVER_IP=203.0.113.10 \
NETLUMAVPN_DOMAIN=netlumavpn.example \
NETLUMAVPN_MOBILE_API_KEY='<значение AppConstants.Backend.mobileClientKey>' \
NETLUMAVPN_CERTBOT_EMAIL='you@example.com' \
./ops/deploy-fresh-server.sh
```

Для текущего live VPS `192.0.2.10` SSH работает на порту `22`, поэтому
добавляйте `SSH_PORT=22 SSH_USER=root`. Подробности: [`SSH_ACCESS.md`](PUBLIC_REPOSITORY.md).

Если root-доступ сначала только по паролю, скрипт даст SSH ввести пароль интерактивно. Если локальный ключ `~/.ssh/quickvpn_vps_ed25519.pub` существует, он будет добавлен на сервер для `root` и `quickadmin`.

Скрипт сгенерирует новые секреты и сохранит их только на VPS:

```text
/root/quickvpn-app-credentials.txt
/root/quickvpn-ssh-credentials.txt
/etc/quickvpn/quickvpn.env
```

Не коммитить эти файлы и не пересылать их целиком.

## 3. Что будет поднято на новом VPS

```text
22/tcp        SSH на свежем сервере по умолчанию; текущий live VPS использует 22/tcp
80/tcp        ACME challenge + redirect, mobile API на HTTP закрыт
443/tcp       nginx stream SNI routing
51820/udp     WireGuard
127.0.0.1:8000   FastAPI admin/API
127.0.0.1:8443   HTTPS backend для root/www/api/admin
127.0.0.1:1443   Xray VLESS Reality
127.0.0.1:2443   Xray Trojan TLS
127.0.0.1:10085  Xray stats API
```

SNI routing:

```text
netlumavpn.example         -> 127.0.0.1:8443
www.netlumavpn.example     -> 127.0.0.1:8443
api.netlumavpn.example     -> 127.0.0.1:8443
admin.netlumavpn.example   -> 127.0.0.1:8443
trojan.netlumavpn.example  -> 127.0.0.1:2443
default                -> 127.0.0.1:1443
```

## 4. Проверка после раскатки

Локально:

```bash
NETLUMAVPN_DOMAIN=netlumavpn.example \
EXPECTED_IP=203.0.113.10 \
NETLUMAVPN_MOBILE_API_KEY='<значение AppConstants.Backend.mobileClientKey>' \
./ops/verify-fresh-server.sh
```

На VPS:

```bash
systemctl status xray quickvpn-api quickvpn-stats.timer nginx fail2ban --no-pager
ufw status verbose
ss -ltnup | grep -E ':(22|80|443|1443|2443|51820|8000|8443|10085)'
```

Проверка admin:

```bash
ssh root@203.0.113.10 'sed -n "1,20p" /root/quickvpn-app-credentials.txt'
open https://netlumavpn.example
open https://netlumavpn.example/support
open https://netlumavpn.example/admin
open https://admin.netlumavpn.example/admin
```

Проверка mobile API:

```bash
curl https://api.netlumavpn.example/api/v1/mobile/servers \
  -H "X-NetlumaVPN-Client-Key: MOBILE_API_KEY"
```

## 5. iOS-приложение

`NetlumaVPNShared/Models/AppConstants.swift` уже указывает на:

```text
https://api.netlumavpn.example
```

Если `NETLUMAVPN_MOBILE_API_KEY` на сервере оставлен таким же, как `AppConstants.Backend.mobileClientKey`, новую сборку приложения делать не нужно только из-за переезда IP.

Если mobile key ротируется, обновить `AppConstants.Backend.mobileClientKey`, пересобрать приложение и только потом менять `MOBILE_API_KEY` на сервере.

Сейчас `mobileTLSCertificateSHA256Base64` пустой, поэтому приложение использует обычную системную проверку Let's Encrypt сертификата. Если включаем pinning, после выпуска сертификата вычислить pin и обновить приложение:

```bash
openssl s_client -connect api.netlumavpn.example:443 -servername api.netlumavpn.example </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
```

## 6. Если нужно сначала поднять сервер до DNS

Можно установить SSH-доступ и базовые пакеты вручную, но полный `deploy-fresh-server.sh` лучше запускать после DNS, потому что он сразу выпускает Let's Encrypt сертификат. Без DNS `https://api.netlumavpn.example` не станет рабочим для приложения.

Минимальная ручная проверка нового VPS до DNS:

```bash
ssh root@NEW_SERVER_IP 'uname -a && ip addr && ip route'
```
