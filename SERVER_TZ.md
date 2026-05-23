# ТЗ на сервер QuickVPN

## 1. Цель

Настроить production-ready сервер для QuickVPN, который:

- выдает VPN-профили для мобильного приложения;
- обслуживает админ-панель для управления профилями;
- принимает VLESS Reality подключения через Xray;
- работает по домену `netlumavpn.example`;
- поддерживает HTTPS для API и админки;
- позволяет создавать, отзывать, включать и удалять профили;
- стабильно работает на мобильных сетях и домашних провайдерах.

## 2. Исходные данные

```text
VPS IPv4: 192.0.2.10
OS: Ubuntu 24.04 LTS
VPN protocol: VLESS Reality
VPN core: Xray-core
Domain: netlumavpn.example
Egress: IPv4-only
```

IPv6 на текущем VPS не использовать до отдельной проверки IPv6 egress.

## 3. DNS

После регистрации домена создать DNS-зону `netlumavpn.example` и добавить A-записи:

```text
netlumavpn.example        A   192.0.2.10
www.netlumavpn.example    A   192.0.2.10
admin.netlumavpn.example  A   192.0.2.10
api.netlumavpn.example    A   192.0.2.10
vpn.netlumavpn.example    A   192.0.2.10
```

AAAA-записи не добавлять.

Для регистрации домена использовать DNS-серверы регистратора или Cloudflare. Не использовать IP VPS как nameserver.

## 4. Порты и сетевой доступ

Открыть входящие порты:

```text
22/tcp   SSH, только key-based login
80/tcp   HTTP, ACME challenge и редирект на HTTPS
443/tcp  HTTPS API/Admin и VLESS Reality через SNI routing
```

Закрыть все остальные входящие порты.

Firewall:

- default incoming: deny;
- default outgoing: allow;
- разрешить `22`, `80`, `443`;
- включить fail2ban для SSH.

## 5. SNI routing

На `443/tcp` использовать `nginx stream` с `ssl_preread`.

Маршрутизация:

```text
api.netlumavpn.example    -> HTTPS backend API/Admin
admin.netlumavpn.example  -> HTTPS backend API/Admin
default               -> Xray VLESS Reality backend
```

Xray слушает только локально:

```text
127.0.0.1:1443
```

API/Admin backend слушает локально:

```text
127.0.0.1:8000
```

## 6. HTTPS

Выпустить TLS-сертификаты через Let's Encrypt для:

```text
api.netlumavpn.example
admin.netlumavpn.example
```

HTTP `80` должен:

- обслуживать ACME challenge;
- редиректить админку/API на HTTPS;
- не открывать мобильные API endpoints без HTTPS.

## 7. Xray / VLESS Reality

Основной inbound:

```text
protocol: vless
security: reality
network: tcp
listen: 127.0.0.1
port: 1443
```

Reality параметры:

```text
sni/serverName: www.microsoft.com
dest: www.microsoft.com:443
fingerprint: chrome
spiderX: /
shortId: server-generated stable short id
```

Важно:

- генерировать клиентские профили **без** `flow=xtls-rprx-vision`;
- не включать одновременно один и тот же UUID с `flow` и без `flow`;
- старые клиентские профили с `flow=xtls-rprx-vision` считать несовместимыми и требовать переимпорта;
- outbound `freedom` настроить с `domainStrategy: UseIPv4`.

Пример ожидаемого клиентского URL:

```text
vless://UUID@vpn.netlumavpn.example:443/?security=reality&encryption=none&pbk=PUBLIC_KEY&fp=chrome&type=tcp&sni=www.microsoft.com&sid=SHORT_ID&spx=%2F#LABEL
```

## 8. Backend API/Admin

Backend должен быть FastAPI-приложением с SQLite.

Основные сущности:

- user;
- profile;
- traffic_sample;
- audit_log.

Профиль должен хранить:

```text
profile_id
user_id
device_name
credential_uuid
email / stats identifier
status: active | revoked
vless_url
upload_bytes
download_bytes
last_seen_at
created_at
revoked_at
```

## 9. Админ-панель

Админка должна быть доступна по:

```text
https://admin.netlumavpn.example
```

Функции:

- вход по логину/паролю;
- список профилей;
- создание профиля;
- просмотр VLESS URL;
- отзыв профиля;
- повторное включение профиля;
- полное удаление профиля;
- отображение traffic counters;
- отображение online/offline статуса;
- audit log для create/revoke/enable/delete/login.

Удаление профиля должно:

- удалить профиль из SQLite;
- удалить связанные `traffic_samples`;
- удалить user, если у него больше нет профилей;
- перерендерить Xray config;
- перезапустить Xray;
- записать audit event.

## 10. Mobile API

Mobile API должен быть доступен по:

```text
https://api.netlumavpn.example
```

Авторизация:

```text
X-QuickVPN-Client-Key: MOBILE_CLIENT_KEY
```

Endpoints:

```text
GET  /api/v1/mobile/servers
POST /api/v1/mobile/servers/{server_id}/profile
```

`GET /servers` возвращает:

```json
{
  "ok": true,
  "servers": [
    {
      "id": "quickvpn-mvp-eu-1",
      "name": "QuickVPN Global",
      "country": "Germany",
      "city": "Nuremberg",
      "region": "Europe",
      "protocol": "VLESS Reality",
      "is_available": true,
      "ip_mode": "ipv4_only"
    }
  ]
}
```

`POST /profile`:

- принимает `X-QuickVPN-Device-ID`;
- выдает один активный профиль на устройство;
- переиспользует существующий активный профиль для того же устройства;
- возвращает `config_url` без `flow`.

## 11. Admin API

Admin API защищается отдельным ключом:

```text
X-QuickVPN-API-Key: ADMIN_API_KEY
```

Endpoints:

```text
GET  /api/v1/status
POST /api/v1/profiles
POST /api/v1/profiles/{profile_id}/revoke
```

Опционально добавить:

```text
POST /api/v1/profiles/{profile_id}/enable
DELETE /api/v1/profiles/{profile_id}
```

## 12. Xray config lifecycle

При каждом изменении профилей:

1. Сгенерировать `/usr/local/etc/xray/config.json`.
2. Проверить config:

   ```bash
   xray run -test -format json -config /usr/local/etc/xray/config.json
   ```

3. Если проверка успешна, заменить config atomically.
4. Перезапустить Xray.
5. Проверить `systemctl is-active xray`.

Важно: рендер config должен выполняться с environment-файлом сервера, чтобы не подставились default-значения вроде неправильного `REALITY_SERVER_NAME`.

## 13. Логи и мониторинг

Логи:

```text
/var/log/xray/access.log
/var/log/xray/error.log
/var/log/nginx/access.log
/var/log/nginx/error.log
journalctl -u quickvpn-api
journalctl -u xray
```

Нужно логировать:

- создание профиля;
- переиспользование mobile profile;
- отзыв;
- включение;
- удаление;
- ошибки рендера Xray config;
- ошибки restart Xray;
- admin login.

Не логировать:

- API keys;
- пароли;
- private key Reality.

## 14. Backup

Минимально:

- daily backup SQLite базы;
- backup `/etc/quickvpn/quickvpn.env`;
- backup `/usr/local/etc/xray/config.json`;
- backup nginx configs.

Хранить минимум 7 daily backups.

## 15. Acceptance Criteria

Сервер считается готовым, если выполняются все проверки.

DNS:

```bash
dig +short A netlumavpn.example
dig +short A api.netlumavpn.example
dig +short A admin.netlumavpn.example
dig +short A vpn.netlumavpn.example
```

Все должны вернуть:

```text
192.0.2.10
```

HTTPS:

```bash
curl -I https://admin.netlumavpn.example/login
curl -I https://api.netlumavpn.example/api/v1/status
```

Ожидается `200` или корректный redirect/login response.

Mobile API:

```bash
curl https://api.netlumavpn.example/api/v1/mobile/servers \
  -H "X-QuickVPN-Client-Key: MOBILE_CLIENT_KEY"
```

Ожидается `ok: true` и `ip_mode: ipv4_only`.

VPN:

1. Создать новый профиль.
2. Убедиться, что URL не содержит `flow=`.
3. Подключиться через Xray-compatible клиент.
4. Проверить внешний IP:

   ```bash
   curl https://api64.ipify.org
   ```

Ожидается:

```text
192.0.2.10
```

Xray logs:

```text
[vless-reality >> direct]
```

Admin delete:

1. Создать временный профиль.
2. Удалить через админку.
3. Проверить, что профиль исчез из базы.
4. Проверить, что UUID исчез из Xray config.
5. Проверить, что Xray остался active.

## 16. Что не входит в MVP

- IPv6 VPN egress;
- multiple VPN locations;
- billing/subscriptions;
- auto-renew certificates for arbitrary user domains beyond configured hostnames;
- WireGuard server;
- web dashboard analytics beyond basic counters.
