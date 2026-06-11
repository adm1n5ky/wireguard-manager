# wg-manager — WireGuard Multi-Instance Manager

CLI-инструмент для Ubuntu 24/26 LTS.  
Управляет несколькими WireGuard-серверами без БД и внешних сервисов.

## Установка

```bash
git clone <repo> /opt/wg-manager
chmod +x /opt/wg-manager/wg-manager.sh
sudo /opt/wg-manager/wg-manager.sh
```

## Структура файлов (на сервере)

```
/etc/wireguard/
├── wg100.conf          # конфиг WireGuard (chmod 600)
├── wg100.env           # метаданные (chmod 600)
└── server-wg100/
    ├── private.key     # (chmod 600)
    └── public.key      # (chmod 644)
```

## Структура проекта

```
wg-manager/
├── wg-manager.sh       # точка входа
└── lib/
    ├── common.sh       # логирование, зависимости, утилиты
    ├── validation.sh   # валидация имени, CIDR, порта, MTU
    ├── network.sh      # IP-математика, поиск пересечений сетей
    ├── ports.sh        # обнаружение занятых портов, auto-find
    ├── endpoint.sh     # определение публичного IP
    ├── server-create.sh
    ├── server-delete.sh
    ├── config-list.sh
    ├── status.sh       # up/down/status управление
    └── menu.sh         # интерактивное меню
```

## Зависимости

Автоматически устанавливаются при первом запуске:
- `wireguard-tools`
- `ipcalc`
- `curl`

## .env формат

```dotenv
WG_NAME=wg100
WG_NETWORK=10.100.100.0/24
WG_SERVER_IP=10.100.100.1/24
WG_PORT=51820
WG_MTU=1420
WG_ENDPOINT=vpn.example.com
WG_USE_PSK=yes
WG_CLIENT_TO_CLIENT_DEFAULT=no
WG_KEY_DIR=/etc/wireguard/server-wg100
WG_PRIVATE_KEY_FILE=/etc/wireguard/server-wg100/private.key
WG_PUBLIC_KEY_FILE=/etc/wireguard/server-wg100/public.key
WG_SERVER_PUBLIC_KEY=<base64>
WG_CREATED_AT=2025-01-01T00:00:00Z
```

## Принципы безопасности

- `.env` никогда не `source`-ится — только `grep`/`cut`
- Приватные ключи: `chmod 600`
- Конфиги и env: `chmod 600`
- Каталог ключей: `chmod 700`
- Удаление: подтверждение вводом имени интерфейса

## Roadmap v2

- [ ] `lib/client-create.sh` — IP pool, генерация peer-конфигов
- [ ] `lib/client-delete.sh` — удаление peer из конфига
- [ ] `lib/qrcode.sh` — QR-код для мобильных клиентов
- [ ] `lib/ip-pool.sh` — управление пулом IP-адресов
- [ ] Экспорт конфигов (zip/tar)
- [ ] WireGuard dashboard (веб-интерфейс)
