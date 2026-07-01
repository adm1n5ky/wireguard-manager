# WireGuard Multi-Instance Manager

CLI-инструмент для Ubuntu 24/26 LTS.
Управляет несколькими WireGuard-серверами (и AmneziaWG) без БД и внешних сервисов.
Поддержка IPv6 (NAT66 / routed) опциональна и настраивается по инстансам.

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

| Пакет             | Назначение                           |
| ----------------- | ------------------------------------ |
| `wireguard-tools` | wg / wg-quick                        |
| `curl`            | определение публичного IP            |
| `qrencode`        | QR-коды (терминал + SVG), обязателен |

Поддерживаются оба бэкенда: `wg` (wireguard-tools) и `awg` (amneziawg-tools).
Выбор происходит при создании сервера и сохраняется в `.env`.

IPv6-математика (нарезка подсетей, валидация CIDR) использует системный `python3`
(стандартно установлен в Ubuntu 24.04+), внешних pip-пакетов не требует.

## Структура файлов на сервере

```
/etc/wireguard/
├── ipv6-available.conf           # реестр доступных IPv6-блоков (NAT66/routed)
├── wg100.conf                    # конфиг WireGuard (chmod 600)
├── wg100.env                     # метаданные менеджера (chmod 600)
└── server-wg100/
    ├── private.key                # (chmod 600)
    ├── public.key                 # (chmod 644)
    ├── ip-pool.dat                 # пул IPv4-адресов (chmod 600)
    ├── ip-pool6.dat                 # пул IPv6-адресов, выдача по запросу
    └── clients/
        └── phone-alice/
            ├── private.key       # (chmod 600)
            ├── public.key        # (chmod 644)
            ├── wg100-phone-alice.conf
            └── wg100-phone-alice.svg   # QR-код клиента в SVG
```

## Структура проекта

```
wg-manager/
├── wg-manager.sh        # точка входа
└── lib/
    ├── common.sh         # логирование, утилиты, пути, IPV6_AVAILABLE_CONF
    ├── backend.sh        # абстракция wg / awg
    ├── table.sh           # рендеринг таблицы серверов
    ├── validation.sh     # валидация имени, CIDR, порта, MTU
    ├── network.sh         # IP-математика IPv4, IPv6-хелперы и пул available-блоков
    ├── ports.sh           # поиск свободного UDP-порта
    ├── endpoint.sh        # определение публичного IP
    ├── ip-pool.sh          # пул IPv4 (предгенерация) + пул IPv6 (по запросу)
    ├── config-list.sh     # список серверов (managed + unmanaged)
    ├── server-create.sh   # создание сервера, включая шаги IPv6
    ├── server-delete.sh   # удаление сервера
    ├── client-create.sh   # добавление клиента (IPv4 + IPv6 + QR SVG)
    ├── client-delete.sh   # удаление клиента (освобождает IPv4 и IPv6)
    ├── client-show.sh     # просмотр конфига, QR в терминале и SVG
    ├── status.sh           # up / down интерфейса, server_status
    ├── peer-monitor.sh    # realtime дашборд пиров (заменил Interface status)
    ├── system.sh           # пакеты, модули, обновление, IPv6 Networks
    └── menu.sh             # интерактивное меню
```

## Меню

```
Main Menu
├── 1) Servers
│   ├── 1) Create server          (включает опциональные шаги IPv6)
│   ├── 2) Delete server
│   ├── 3) Start interface
│   ├── 4) Stop interface
│   ├── 5) Peer Monitor           (realtime дашборд, было "Interface status")
│   └── 6) Manage clients →
│       ├── 1) Add client
│       ├── 2) Delete client
│       └── 3) Show client .conf & QR code
├── 2) Clients                    (прямой вход, выбор сервера внутри)
│   ├── 1) Add client
│   ├── 2) Delete client
│   └── 3) Show client .conf & QR code
└── 3) System
    ├── 1) Check / install packages
    ├── 2) Check module integrity
    ├── 3) Update wg-manager
    └── 4) IPv6 Networks          (управление ipv6-available.conf)
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
WG_NETWORK6=2001:abcd:1234:1000::/64
WG_IPV6_MODE=nat66
WG_CREATED_AT=2026-01-01T00:00:00Z
```

`WG_NETWORK6` может содержать несколько блоков через запятую (один instance
может выдавать клиентам IPv6 из нескольких подсетей одновременно).
Поле пустое — instance работает в режиме IPv4-only.

## Формат ip-pool.dat (IPv4)

Предгенерируется целиком при первом обращении (`pool_init`).

```
10.100.100.1	server	server	-
10.100.100.2	used	phone-alice	2026-01-01T00:00:00Z
10.100.100.3	free	-	-
```

## Формат ip-pool6.dat (IPv6)

Выдача **по запросу**, без предгенерации (адресное пространство /64
непрактично перечислять). Содержит только реально выданные адреса.

```
2001:abcd:1234:1000::2	used	phone-alice	2001:abcd:1234:1000::/64	2026-01-01T00:00:00Z
```

## Формат ipv6-available.conf

Глобальный реестр IPv6-блоков, которыми реально владеет сервер
(HE-туннель, нативный аплинк провайдера и т.д.). Управляется через
`System → IPv6 Networks`. Из крупных блоков (`/48` и т.д.) при создании
instance автоматически нарезаются `/64` начиная с четвёртого гекстета
`1000`, `1001`, `1002`... (адресное пространство `::0–::fff` зарезервировано
под инфраструктурные нужды и не выдаётся instance).

```
# <cidr>                  <type>    <comment>
2001:abcd:1234::/48       routed    HE Frankfurt tunnel
2a01:c001:face::/64       nat66     Provider direct uplink
```

`type`:

- `routed` — блок полностью маршрутизируется на сервер, клиенты получают
  реально достижимые IPv6-адреса
- `nat66` — у сервера один внешний IPv6, клиенты выходят через masquerade

## Принципы безопасности

- `.env` никогда не `source`-ится — только `grep` / `cut`
- Приватные ключи: `chmod 600`
- Конфиги, env, ip-pool\*.dat, ipv6-available.conf: `chmod 600`
- Каталог ключей: `chmod 700`
- Удаление сервера: подтверждение вводом имени интерфейса
- Удаление клиента: подтверждение вводом имени клиента
- Все интерактивные `read` используют `-rep` (readline), чтобы стрелки
  и спецсимволы терминала не попадали в ввод как текст
- Локальные переменные внутри функций с `local -n` (nameref) всегда имеют
  префикс `_`, чтобы избежать самозахвата nameref при совпадении имён
  с именем передаваемой переменной (см. `prompt_cidr`, `prompt_port`,
  `prompt_endpoint`, `prompt_iface_name`)

## Горячее применение изменений

При добавлении и удалении клиентов менеджер применяет изменения без перезапуска:

```
wg syncconf (через wg-quick strip)   # без разрыва соединений
    ↓ если не сработало
systemctl reload-or-restart          # мягкая перезагрузка
    ↓ если не сработало
предупреждение с командой вручную
```

## IPv6 — текущий статус

Реализовано:

- Реестр доступных IPv6-блоков (`System → IPv6 Networks`)
- Автоматическая нарезка `/64` из крупных блоков без пересечений
  (учитывает занятые подсети из `.env` всех instance **и** реальные
  `inet6`-адреса на интерфейсах сервера)
- Выдача IPv6-адресов клиентам по запросу (`ip-pool6.dat`)
- Dual-stack `Address` в клиентских `.conf` (IPv4 + все назначенные IPv6)
- `AllowedIPs` всегда `0.0.0.0/0, 2000::/3` (выбор full/split tunnel
  убран из мастера создания клиента как избыточный)
- Освобождение IPv6 при удалении клиента

Не реализовано (следующие этапы):

- Генерация и применение правил `nftables` (forward + NAT66/masquerade)
  для свежесозданных instance — пока делается вручную
- DNS для клиентов (DNS-over-TLS форвардинг на WG-интерфейсы через
  `DNSStubListenerExtra`) — пока делается вручную
- Привязка `ip6tables`/`nftables` правил к жизненному циклу instance
  (создание/удаление автоматически правит firewall)

## Известные архитектурные решения

- **NAT66 vs routed** выбирается на уровне instance (`WG_IPV6_MODE`),
  не на уровне всего сервера — один сервер может иметь несколько
  instance с разной IPv6-стратегией
- **Множественные IPv6-подсети на instance** — намеренная возможность
  (клиент может получить адреса из разных блоков для дальнейшего
  ручного выбора маршрута), но автоматический выбор маршрута на
  клиенте/роутере вне scope текущего проекта
- **`ipcalc` исключён** из зависимостей — вся валидация CIDR выполняется
  bash-арифметикой (`network.sh`) и `python3` (для IPv6), это устранило
  расхождение в выводе `ipcalc` между дистрибутивами
