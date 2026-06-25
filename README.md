# WireGuard Multi-Instance Manager

CLI-инструмент для Ubuntu 24/26 LTS.  
Управляет несколькими WireGuard-серверами (и AmneziaWG) без БД и внешних сервисов.

## Установка

```bash
git clone https://github.com/adm1n5ky/wireguard-manager /opt/wg-manager
chmod +x /opt/wg-manager/wg-manager.sh
sudo /opt/wg-manager/wg-manager.sh
```

## Обновление

```bash
cd /opt/wg-manager && git pull
```

## Зависимости

Проверяются и устанавливаются автоматически при первом запуске:

| Пакет             | Назначение                |
| ----------------- | ------------------------- |
| `wireguard-tools` | wg / wg-quick             |
| `ipcalc`          | валидация CIDR            |
| `curl`            | определение публичного IP |
| `qrencode`        | QR-коды (опционально)     |

Поддерживаются оба бэкенда: `wg` (wireguard-tools) и `awg` (amneziawg-tools).  
Выбор происходит при создании сервера и сохраняется в `.env`.

## Структура файлов на сервере

```
/etc/wireguard/
├── wg100.conf                    # конфиг WireGuard (chmod 600)
├── wg100.env                     # метаданные менеджера (chmod 600)
└── server-wg100/
    ├── private.key               # (chmod 600)
    ├── public.key                # (chmod 644)
    ├── ip-pool.dat               # пул IP-адресов (chmod 600)
    └── clients/
        └── phone-alice/
            ├── private.key       # (chmod 600)
            ├── public.key        # (chmod 644)
            └── wg100-phone-alice.conf
```

## Структура проекта

```
wg-manager/
├── wg-manager.sh        # точка входа
└── lib/
    ├── common.sh        # логирование, утилиты, пути
    ├── backend.sh       # абстракция wg / awg
    ├── table.sh         # рендеринг таблицы серверов
    ├── validation.sh    # валидация имени, CIDR, порта, MTU
    ├── network.sh       # IP-математика, поиск пересечений сетей
    ├── ports.sh         # поиск свободного UDP-порта
    ├── endpoint.sh      # определение публичного IP
    ├── ip-pool.sh       # пул IP-адресов на сервер
    ├── config-list.sh   # список серверов (managed + unmanaged)
    ├── server-create.sh # создание сервера
    ├── server-delete.sh # удаление сервера
    ├── client-create.sh # добавление клиента
    ├── client-delete.sh # удаление клиента
    ├── client-show.sh   # просмотр конфига и QR-код
    ├── status.sh        # up / down / status интерфейса
    ├── system.sh        # пакеты, модули, обновление
    └── menu.sh          # интерактивное меню
```

## Меню

```
Main Menu
├── 1) Servers
│   ├── 1) Create server
│   ├── 2) Delete server
│   ├── 3) Start interface
│   ├── 4) Stop interface
│   ├── 5) Interface status
│   └── 6) Manage clients →
│       ├── 1) Add client
│       ├── 2) Delete client
│       └── 3) Show config & QR
└── 3) System
    ├── 1) Check / install packages
    ├── 2) Check module integrity
    └── 3) Update wg-manager
```

## Формат .env

```dotenv
WG_NAME=wg100
WG_BACKEND=wg
WG_NETWORK=10.100.100.0/24
WG_SERVER_IP=10.100.100.1/24
WG_PORT=51820
WG_MTU=1420
WG_ENDPOINT=vpn.example.com
WG_USE_PSK=yes
WG_KEY_DIR=/etc/wireguard/server-wg100
WG_PRIVATE_KEY_FILE=/etc/wireguard/server-wg100/private.key
WG_PUBLIC_KEY_FILE=/etc/wireguard/server-wg100/public.key
WG_SERVER_PUBLIC_KEY=<base64>
WG_CREATED_AT=2026-01-01T00:00:00Z
```

## Формат ip-pool.dat

```
10.100.100.1	server	server	-
10.100.100.2	used	phone-alice	2026-01-01T00:00:00Z
10.100.100.3	free	-	-
```

## Принципы безопасности

- `.env` никогда не `source`-ится — только `grep` / `cut`
- Приватные ключи: `chmod 600`
- Конфиги и env: `chmod 600`
- Каталог ключей: `chmod 700`
- Удаление сервера: подтверждение вводом имени интерфейса
- Удаление клиента: подтверждение вводом имени клиента

## Горячее применение изменений

При добавлении и удалении клиентов менеджер применяет изменения без перезапуска:

```
wg syncconf (через wg-quick strip)   # без разрыва соединений
    ↓ если не сработало
systemctl reload-or-restart          # мягкая перезагрузка
    ↓ если не сработало
предупреждение с командой вручную
```
