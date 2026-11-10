# ArcadeOS

Экспериментальная «аркадная» операционная система на базе Debian для
[linuxloader](https://github.com/lindbergh-loader/linuxloader) (бывший lindbergh-loader,
игры SEGA Lindbergh). Устроена по образцу настоящих аркадных систем:

- загрузочная флешка с чёрным экраном и одной кнопкой **INSTALL**;
- неизменяемый корень (squashfs + dm-verity), как прошивка аркадной платы;
- шифрование дисков с привязкой к конкретной материнской плате (HWID), **без TPM**;
- собственный Secure Boot: свои ключи в firmware, всё подписано тобой;
- после включения сразу игра или меню выбора, в систему не выйти.

> ⚠️ **Статус: научный эксперимент, версия 0.1.0.** Скрипты проверены shellcheck и по логике,
> вывод ключа протестирован на подставных DMI, но **полная сборка и установка на реальном
> железе ещё не прогонялись**. Начинай с виртуальной машины ([раздел 9](#9-тест-в-qemu)),
> потом пробуй на ПК без важных данных. Установка **стирает целевой диск полностью**.

---

## Содержание

1. [Как это устроено](#1-как-это-устроено)
2. [Модель угроз: что защищено, а что нет](#2-модель-угроз-что-защищено-а-что-нет)
3. [Требования](#3-требования)
4. [Подготовка хоста сборки](#4-подготовка-хоста-сборки)
5. [Настройка `config.env`](#5-настройка-configenv)
6. [Сборка](#6-сборка)
7. [Установка на ПК](#7-установка-на-пк)
8. [Первая загрузка: MokManager](#8-первая-загрузка-mokmanager)
9. [Тест в QEMU](#9-тест-в-qemu)
10. [Игры: формат и импорт](#10-игры-формат-и-импорт)
11. [Работа с системой: меню](#11-работа-с-системой-меню)
12. [Обновление системы](#12-обновление-системы)
13. [Ключ восстановления и замена железа](#13-ключ-восстановления-и-замена-железа)
14. [Ключи подписи: хранение и бэкап](#14-ключи-подписи-хранение-и-бэкап)
15. [Отладка и решение проблем](#15-отладка-и-решение-проблем)
16. [Кастомизация](#16-кастомизация)
17. [Структура репозитория](#17-структура-репозитория)
18. [Планы](#18-планы)
19. [Лицензии и правовое](#19-лицензии-и-правовое)

---

## 1. Как это устроено

### Цепочка загрузки

```
UEFI firmware
│   db/KEK/PK = ТВОИ ключи (+ опционально Microsoft UEFI CA, см. 5.2)
│
└─ shimx64.efi ·········· собран из исходников, вшит твой db-сертификат, подписан db
    ├─ mmx64.efi ········ MokManager: один раз зачислить MOK-ключ (для nvidia.ko)
    └─ grubx64.efi ······ на самом деле UKI = ядро + initramfs + cmdline, подписан db
         │                 в cmdline зашит root hash образа системы
         └─ initramfs (boot=arcadeos)
              ├─ hwid-key root ─► LUKS2 «ARC_ROOT»
              │                     └─ dm-verity (проверка по root hash)
              │                          └─ squashfs (только чтение)
              │                               + tmpfs overlay (изменения в RAM) = /
              └─ hwid-key data ─► LUKS2 «ARC_DATA» ─► ext4 = /data
                   │
                   └─ systemd ─► автологин tty1 ─► arcade-launcher
                                                    └─ xinit ─► linuxloader ─► игра
```

Каждое звено проверяет следующее. Поменяй один байт где угодно (ESP, initramfs, cmdline,
образ системы), и система не загрузится или откажется монтировать корень.

### Разметка диска

| Раздел | Метка GPT | Размер | Содержимое |
|---|---|---|---|
| 1 | `ARC_ESP` | 512 МБ, FAT32 | shim, MokManager, UKI. Не зашифрован, но всё подписано |
| 2 | `ARC_ROOT` | ≥ 12 ГБ, LUKS2 | squashfs + хэш-дерево dm-verity. Записывается целиком при установке/обновлении |
| 3 | `ARC_DATA` | остаток диска, LUKS2 → ext4 | `/data/games`, `/data/config`, `/data/saves` |

### Ключи шифрования

У каждого LUKS-тома **два слота ключей**:

1. **HWID-ключ**: `sha256("arcadeos-hwid-v1" | назначение | product_uuid | board_serial |
   board_vendor | board_name | product_serial)`. Значения берутся из DMI/SMBIOS платы
   (`/sys/class/dmi/id`). Для `root` и `data` ключи разные.
2. **Ключ восстановления**: 32 случайных символа вида `ABCD-EFGH-…`. Показывается
   **один раз** в конце установки.

При загрузке initramfs сначала пробует HWID-ключ. Если плата не та (или поменялась),
Plymouth спрашивает ключ восстановления.

### Почему shim и MOK, а не просто подписанный UKI

Ядро Debian при включённом Secure Boot входит в режим *lockdown* и грузит **только
подписанные модули**, причём проверяет их по встроенным ключам и ключам **MOK**, а не
по db. Драйвер NVIDIA собирается через DKMS, поэтому:

- `nvidia.ko` при сборке подписывается твоим **MOK-ключом**;
- MOK нужно один раз зачислить через MokManager (часть shim);
- shim собирается **из исходников** с твоим сертификатом. Стоковый shim Debian доверяет
  любому GRUB, подписанному Debian, и через него можно загрузить что угодно в обход твоей
  цепочки.

---

## 2. Модель угроз: что защищено, а что нет

| Сценарий | Защищено? | Почему |
|---|---|---|
| Сняли диск и скопировали / подключили к другому ПК | ✅ | Без DMI именно этой платы ключ не получить (нужен ключ восстановления) |
| Подменили UKI, initramfs или cmdline на ESP | ✅ | Неподписанное firmware не запустит |
| Подменили или испортили образ системы | ✅ | dm-verity, root hash внутри подписанного UKI |
| Пытаются выйти из лаунчера в shell | ✅ | Shell нет; VT-переключение, Ctrl-Alt-Del, Ctrl-Alt-Backspace и SysRq отключены |
| Загрузка с live-USB на **этой** машине | ⚠️ | Мешают только пароль на BIOS и запрет загрузки с USB |
| Сброс CMOS → загрузка своей системы | ❌ | DMI читаются любым ПО → ключ вычисляется |
| Включён `SB_MS_UEFI_CA=1` | ⚠️ | firmware запустит всё, что подписано Microsoft 3rd-party CA (например, чужой shim) |
| Злоумышленник с полным физическим доступом и временем | ❌ | Без TPM/keychip секрет — это сами ID железа |

**Итог:** это **привязка к железу и защита целостности**, а не стойкая криптографическая
защита от владельца ПК. Похоже на ранние аркадные системы. Как усилить, см. [раздел 18](#18-планы)
(внешний keychip).

---

## 3. Требования

### Целевой ПК

| Компонент | Требование |
|---|---|
| Прошивка | UEFI с Secure Boot и возможностью очистить ключи (Setup Mode). Legacy/CSM не поддерживается |
| Видеокарта | NVIDIA с поддержкой текущего драйвера Debian (проверялось в расчёте на RTX 3050). AMD/Intel пока не настроены |
| Диск | ≥ 32 ГБ, **будет полностью стёрт** |
| ОЗУ | ≥ 4 ГБ (tmpfs-оверлей корня занимает до 25% ОЗУ) |
| DMI | Плата должна отдавать **уникальные** `product_uuid` и серийник. Установщик проверяет это сам |

### Хост сборки

- **Debian 13 (trixie) amd64**: физический, ВМ или контейнер с `--privileged`
  (нужны `chroot`, `mount`, loop-устройства);
- root-доступ;
- ~35 ГБ свободного места;
- интернет: зеркало Debian, archive.ubuntu.com (окружение сборки linuxloader), GitHub
  (shim, SDL3, FAudio), microsoft.com (сертификаты UEFI CA).

---

## 4. Подготовка хоста сборки

### 4.1 Клонирование

linuxloader подключён как **git submodule**, поэтому клонируй рекурсивно:

```sh
git clone --recursive https://github.com/andruxaster/arcadeos
cd arcadeos

# если уже склонировал без --recursive:
git submodule update --init
```

### 4.2 Пакеты

```sh
sudo apt update
sudo apt install \
  debootstrap ubuntu-keyring squashfs-tools cryptsetup-bin \
  sbsigntool efitools openssl uuid-runtime git \
  live-build wget bzip2 build-essential dos2unix libelf-dev \
  ovmf qemu-system-x86 qemu-utils
```

| Пакет | Зачем |
|---|---|
| `debootstrap` | сборка корневой ФС Debian и окружения сборки linuxloader |
| `ubuntu-keyring` | проверка подписи архива Ubuntu (окружение сборки linuxloader) |
| `squashfs-tools`, `cryptsetup-bin` | `mksquashfs`, `veritysetup` |
| `sbsigntool` | `sbsign` / `sbverify`: подпись EFI-файлов |
| `efitools` | `cert-to-efi-sig-list`, `sign-efi-sig-list`: переменные Secure Boot |
| `build-essential`, `dos2unix`, `libelf-dev` | сборка shim |
| `live-build` | сборка ISO установщика |
| `ovmf`, `qemu-*` | тестовая ВМ |

### 4.3 linuxloader

linuxloader — submodule `vendor/linuxloader`, закреплённый на релизном теге
(сейчас **v3.0.14**). Отдельно ничего скачивать не нужно: стадия `loader` соберёт его из
исходников (см. [6.1](#61-стадии)). Лицензия CC BY-NC-SA 4.0, некоммерческое использование,
подробности в [`THIRD_PARTY.md`](THIRD_PARTY.md) и [разделе 19](#19-лицензии-и-правовое).

Почему сборка идёт в отдельном **Ubuntu 22.04**-chroot, а не в Debian:

- так собирает сам upstream (их CI на `ubuntu-22.04`), поэтому результат совпадает с
  официальным релизом;
- в Debian trixie нет `libstdc++5:i386` и `libncurses5:i386`, а старые игры Lindbergh их
  требуют. Из jammy они попадают в `ll-deps/` и в целевую систему ставить их не нужно.

**Обновить linuxloader** до новой версии:

```sh
cd vendor/linuxloader
git fetch --tags
git checkout v3.0.15            # нужный тег
cd ../..
git add vendor/linuxloader
git commit -m "linuxloader v3.0.15"
sudo ./build.sh loader rootfs image boot installer
```

**Готовый бинарный релиз вместо сборки** (быстрее, но без проверки исходников): распакуй его
в любую папку (должны быть `./linuxloader` и `ll-deps/`) и укажи её в `config.env`:
`LINUXLOADER_PREBUILT="vendor/linuxloader-bin"`. Стадию `loader` тогда можно пропустить.

---

## 5. Настройка `config.env`

Все параметры в одном файле, его подключают все стадии сборки.

### 5.1 Основные

| Параметр | По умолчанию | Описание |
|---|---|---|
| `ARCADEOS_VERSION` | `0.1.0` | Версия, видна в меню и установщике |
| `DEBIAN_SUITE` | `trixie` | Ветка Debian |
| `DEBIAN_MIRROR` | `deb.debian.org` | Зеркало (можно указать локальное) |
| `NVIDIA_KMOD` | `nvidia-kernel-dkms` | Модуль ядра: проприетарный или `nvidia-open-kernel-dkms` (Turing+, в т. ч. RTX 3050) |
| `ROOT_PART_MIB` | `12288` | Минимальный размер раздела системы (с запасом под обновления) |
| `KERNEL_CMDLINE_EXTRA` | `quiet splash …` | Доп. параметры ядра. Зашиваются в подписанный UKI |
| `DEBUG_ROOT_PASSWORD` | пусто | Отладочный режим, см. [15.1](#151-отладочная-сборка) |

### 5.2 `SB_MS_UEFI_CA`: важный выбор

Прошивка (GOP) дискретной видеокарты, **в том числе RTX 3050**, подписана сертификатом
**Microsoft UEFI CA**. Если в db только твои ключи, firmware откажется её запускать, и
**экран останется чёрным** до старта Linux. На ПК без встроенной графики это значит, что не
видно ни BIOS, ни MokManager, ни экрана ввода ключа восстановления.

| Значение | Плюс | Минус |
|---|---|---|
| `1` (по умолчанию) | Видеокарта показывает картинку с самого старта | firmware будет запускать всё, что подписано Microsoft 3rd-party CA (например, shim других дистрибутивов). **Обязательно** пароль на BIOS и запрет загрузки с USB |
| `0` | Запускается только подписанное тобой | Риск чёрного экрана. Выход: сброс CMOS. Используй, только если у CPU есть iGPU и вывод BIOS переключён на него |

### 5.3 linuxloader

| Параметр | По умолчанию | Описание |
|---|---|---|
| `LL_BUILD_SUITE` | `jammy` | Ubuntu для окружения сборки (как в upstream CI) |
| `LL_BUILD_MIRROR` | `archive.ubuntu.com` | Зеркало Ubuntu |
| `LINUXLOADER_PREBUILT` | пусто | Папка с готовым релизом. Если задана, сборка из submodule не нужна |

### 5.4 Пути

| Параметр | Описание |
|---|---|
| `WORK_DIR` | промежуточные файлы (`work/`): chroot сборки лоадера, rootfs, образ, исходники shim |
| `OUT_DIR` | результаты (`out/`): payload и ISO |
| `KEYS_DIR` | **ключи подписи** (`keys/`), см. [раздел 14](#14-ключи-подписи-хранение-и-бэкап) |

---

## 6. Сборка

```sh
sudo ./build.sh                          # все стадии по порядку
sudo ./build.sh image boot installer     # выборочно (например, после правки лаунчера)
```

### 6.1 Стадии

| Стадия | Скрипт | Что делает | Результат |
|---|---|---|---|
| `keys` | `build/00-keys.sh` | Генерирует PK, KEK, db (RSA-2048, 20 лет) и MOK; собирает и подписывает `.auth` для записи в firmware; при `SB_MS_UEFI_CA=1` скачивает сертификаты Microsoft и добавляет их в db | `keys/` |
| `loader` | `build/05-linuxloader.sh` | Ubuntu 22.04-chroot (переиспользуется между запусками), зависимости по upstream-скрипту `install-packages.sh`, 32-битные SDL3/SDL3_ttf/SDL3_image/FAudio по `build-deps.sh`, затем `make-linux.sh`. Добавляет SDL3 в `ll-deps/`, проверяет зависимости через `ldd`, пишет `LICENSE-NOTICE` с ревизией | `work/linuxloader-dist/` |
| `rootfs` | `build/10-rootfs.sh` | `debootstrap` (minbase) + i386 multiarch; ядро, NVIDIA (модуль подписан MOK через DKMS), X, Plymouth, 32-битные библиотеки, linuxloader + атрибуция в `/usr/share/doc/linuxloader/`, проверка `ldd` внутри целевой системы, оверлей `rootfs/`, пользователь `arcade`, отключение лишних сервисов. Приватный MOK-ключ **удаляется** из rootfs | `work/rootfs/` |
| `image` | `build/20-image.sh` | Собирает initramfs (проверяет, что внутри есть скрипт `arcadeos`), пакует корень в squashfs (zstd), считает хэш-дерево dm-verity и проверяет его | `work/root.img`, `work/root.env` (root hash, offset, размеры) |
| `boot` | `build/30-boot.sh` | Собирает shim с твоим сертификатом; собирает UKI (`ukify`) с cmdline, где зашит root hash; подписывает shim, MokManager, UKI ключом db и проверяет подписи; складывает всё в payload с `SHA256SUMS` | `out/payload/` |
| `installer` | `build/40-installer.sh` | Собирает live-ISO (live-build) с GUI-установщиком и payload внутри | `out/arcadeos-installer-<версия>.iso` |

### 6.2 Когда какие стадии перезапускать

| Что изменилось | Команда |
|---|---|
| Скрипты лаунчера, конфиги в `rootfs/`, список пакетов | `sudo ./build.sh rootfs image boot installer` |
| Только `KERNEL_CMDLINE_EXTRA` | `sudo ./build.sh boot installer` |
| Только GUI установщика | `sudo ./build.sh installer` |
| Новая версия linuxloader (тег submodule) | `sudo ./build.sh loader rootfs image boot installer` |
| Пересоздать окружение сборки лоадера с нуля | `sudo rm -rf work/llbuild && sudo ./build.sh loader` |

Стадию `keys` перезапускать **не нужно**: существующие ключи переиспользуются. Новые ключи
появятся, только если удалить `keys/`, и тогда все установленные машины придётся переустанавливать.

### 6.3 Только payload, без ISO

Если ISO не нужен (например, ставишь вручную), достаточно `keys rootfs image boot`. В
`out/payload/` лежат `install.sh` и всё нужное, установку можно запустить с любого
live-Linux в UEFI-режиме (см. [7.5](#75-ручная-установка-без-gui)).

---

## 7. Установка на ПК

### 7.1 Подготовка BIOS/UEFI

1. **Boot mode:** UEFI only. CSM / Legacy **выключить**.
2. **Secure Boot:** включить и перевести в **Setup Mode**. В разных BIOS это называется
   «Clear Secure Boot keys», «Delete all keys», «Reset to Setup Mode», «Key Management →
   Clear». После этого firmware не содержит ключей и примет новые.
3. Сохранить и выйти.

> В Setup Mode Secure Boot фактически не проверяет подписи, поэтому установочная флешка
> загрузится, хотя её загрузчик подписан Debian, а не тобой.

### 7.2 Запись флешки

```sh
sudo dd if=out/arcadeos-installer-0.1.0.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

(`/dev/sdX` — флешка, **не** системный диск. На Windows: Rufus в режиме DD или balenaEtcher.)

### 7.3 Мастер установки

1. Загрузиться с флешки (меню загрузки: F8/F11/F12/Esc, зависит от платы).
2. Появится чёрный экран с логотипом **ARCADE** и кнопкой **INSTALL**.
3. **INSTALL** → список дисков (флешка установщика в список не попадает) → выбрать диск.
4. **ERASE AND INSTALL**: весь диск будет стёрт.
5. Установщик:
   - проверяет контрольные суммы payload;
   - проверяет уникальность DMI. Если ID платы «заводские», появится экран **WEAK HARDWARE
     ID** (можно продолжить, но привязка будет слабой);
   - размечает диск, создаёт LUKS2 (aes-xts-plain64, 512 бит, argon2id) с двумя слотами;
   - пишет образ системы и сверяет его с root hash;
   - создаёт `/data`, копирует shim/UKI на ESP, добавляет загрузочную запись «ArcadeOS»;
   - записывает db → KEK → PK в firmware (PK последним, это выводит из Setup Mode);
   - ставит в очередь зачисление MOK.
6. **Финальный экран. Сфотографируй или перепиши:**
   - **RECOVERY KEY**: ключ восстановления. Больше нигде не хранится и **больше не будет показан**;
   - **пароль MOK**: 8 цифр для MokManager при следующей загрузке.
7. Вынуть флешку → **REBOOT**.

### 7.4 После установки

- Пароль на вход в BIOS (Supervisor/Administrator password).
- Запретить загрузку с USB или убрать USB из boot order.
- Проверить, что Secure Boot = Enabled (в меню: SYSTEM → System info → `SecureBoot`).

### 7.5 Ручная установка без GUI

С любого live-Linux в UEFI-режиме, где есть `cryptsetup`, `sgdisk`, `efitools`, `mokutil`,
`efibootmgr`:

```sh
cd /путь/к/payload
sudo ./install.sh --list-disks
sudo ./install.sh --check-hwid
sudo ./install.sh --install --disk /dev/nvme0n1
# опции: --no-secureboot     не трогать ключи firmware
#        --force-weak-hwid   продолжить при «заводских» ID платы
```

Строки `@@PROGRESS`, `@@RECOVERY`, `@@MOKPASS`, `@@NOTE` — машиночитаемый вывод для GUI,
ключ восстановления и пароль MOK будут в них.

### 7.6 Если firmware не была в Setup Mode

Установка завершится, но с предупреждением: ключи Secure Boot **не** записаны. Система
загрузится при **выключенном** Secure Boot (shim/UKI всё равно подписаны твоим ключом).
Чтобы включить защиту позже: очистить ключи в BIOS → загрузиться с флешки → **UPDATE**.

---

## 8. Первая загрузка: MokManager

Сразу после установки shim покажет **синий экран MokManager** (видимо только при
`SB_MS_UEFI_CA=1` или с iGPU, см. [5.2](#52-sb_ms_uefi_ca-важный-выбор)):

1. Нажать любую клавишу (у тебя ~10 секунд, иначе загрузка продолжится без зачисления).
2. **Enroll MOK** → **Continue** → **Yes**.
3. Ввести **пароль MOK** с экрана установщика (символы не отображаются).
4. **Reboot**.

После этого ядро будет загружать подписанный `nvidia.ko`.

**Пропустил MokManager?** Система загрузится, но драйвер NVIDIA не загрузится (чёрный
экран после заставки или X не стартует). Решение: загрузиться с флешки → **UPDATE**: MOK
снова будет поставлен в очередь, только если firmware в Setup Mode. Иначе нужна отладочная
сборка и `mokutil --import` вручную. Проще всего не пропускать.

---

## 9. Тест в QEMU

Перед реальным железом обязательно прогони всю цепочку в виртуальной машине. OVMF с
Secure Boot стартует в Setup Mode, как ПК после очистки ключей.

```sh
# 1. установка
tools/qemu-test.sh out/arcadeos-installer-0.1.0.iso
#    INSTALL → диск /dev/nvme0n1 → ERASE AND INSTALL → записать ключ и пароль MOK
#    → REBOOT → закрыть QEMU

# 2. загрузка с диска (MokManager → Enroll → пароль → Reboot)
tools/qemu-test.sh

# 3. имитация «другой платы»: должен появиться запрос ключа восстановления
SERIAL=OTHER-BOARD tools/qemu-test.sh

# начать с нуля
rm -rf work/qemu
```

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `UUID` | фиксированный | SMBIOS `product_uuid` виртуальной платы |
| `SERIAL` | `ARCADE-BOARD-0001` | серийник платы и системы |

Что **проверяется** в QEMU: запись ключей Secure Boot, shim, MokManager, подпись UKI,
LUKS + HWID, dm-verity, ключ восстановления, Plymouth, лаунчер, импорт игр.
Что **не проверяется**: NVIDIA и запуск игр (в ВМ virtio-vga). Лаунчер и меню работают,
игра упадёт на инициализации GPU.

---

## 10. Игры: формат и импорт

### 10.1 Подготовка флешки

Флешка в FAT32, exFAT или ext4. В корне папка `arcadeos-games`, в ней по папке на игру:

```
USB/
└── arcadeos-games/
    ├── hotd4/
    │   ├── game.conf
    │   └── disk0/elf/hod4M.elf …
    ├── vf5fs/
    │   ├── game.conf
    │   └── …
    └── outrun2sp/
        ├── game.conf
        └── …
```

**Имя папки** = ID игры: только `a-z`, `0-9`, `_`, `-`, начинается с буквы или цифры, до 64 символов.
Папки с другими именами при импорте пропускаются.

### 10.2 `game.conf`

```sh
NAME="The House of the Dead 4"   # название в меню
PLATFORM=lindbergh               # пока поддерживается только lindbergh
GAMEPATH="disk0/elf"             # папка с ELF игры (относительно game.conf)
ELF=""                           # имя ELF, если автоопределение linuxloader ошибается
ARGS=""                          # доп. аргументы linuxloader
```

Пример: `examples/game.conf`. Файл — фрагмент shell-скрипта, кавычки обязательны,
если в значении есть пробелы.

### 10.3 Импорт

1. Вставить флешку.
2. **SYSTEM → Import games from USB**.
3. Система найдёт `arcadeos-games` на всех USB-накопителях, скопирует каждую игру в
   `/data/games/<id>` и покажет отчёт. Игра с тем же ID **заменяется** (старая копия
   удаляется только после успешного копирования новой).

Флешка монтируется только для чтения с `noexec`, на ней ничего не меняется.

### 10.4 Настройки игры и управления

**SYSTEM → Edit game config / controls** → выбрать игру:

- `linuxloader.ini`: настройки эмуляции (разрешение, регион, тип кабинета и т. д.);
- `controls.ini`: назначение кнопок.

Если файла ещё нет, он создаётся командой `linuxloader --create`. Открывается в редакторе
`nano` (сохранить: Ctrl-O, Enter; выйти: Ctrl-X). Файлы лежат рядом с ELF игры на `/data`,
поэтому переживают обновления системы.

Особенности отдельных игр (Outrun 2 SP SDX, Hummer, Let's Go Jungle и др.) описаны в
[гайде linuxloader](https://github.com/lindbergh-loader/linuxloader/blob/main/docs/guide-linux.md).

### 10.5 Совместимость

Список игр и их статус смотри в документации linuxloader. ArcadeOS ничего не меняет в
самом лоадере: если игра работает в linuxloader на обычном Debian с NVIDIA, она должна
работать и здесь.

---

## 11. Работа с системой: меню

### 11.1 Включение

1. Заставка Plymouth (логотип ARCADE).
2. Если назначен **автозапуск**: надпись `Starting <игра>... Press any key for the menu`.
   Нажми любую клавишу в течение 3 секунд, чтобы попасть в меню, иначе запустится игра.
3. Иначе сразу **MAIN MENU**.

Управление в меню: стрелки, Enter, Tab (переход между кнопками), Esc (назад).

### 11.2 Структура меню

```
MAIN MENU
├── GAME SELECT ··········· запустить игру
├── TEST MODE ············· запустить игру в тест-режиме (linuxloader -t)
├── SYSTEM
│   ├── Set autoboot game ·· игра при включении (или «Show menu at boot»)
│   ├── Import games from USB
│   ├── Edit game config / controls
│   ├── Sound test ········· тестовый звук в оба канала
│   ├── System info ········ версия, ядро, GPU, Secure Boot, verity, свободное место, HWID
│   └── Back
├── Reboot
└── Power off
```

### 11.3 Выход из игры

Когда процесс игры завершается, X закрывается и снова появляется меню. Если игра упала
(ненулевой код), показывается лог X/linuxloader (`/tmp/arcade-x.log`), он помогает понять причину.

### 11.4 System info

| Строка | Норма |
|---|---|
| `SecureBoot` | `SecureBoot enabled` |
| `Root` | `verity verified` |
| `HWID check` | `product_uuid ok`, `board_serial ok` … (значения скрыты: это ключевой материал) |

### 11.5 Где что хранится

| Путь | Что | Переживает перезагрузку | Переживает UPDATE |
|---|---|---|---|
| `/` | система | изменения теряются (tmpfs) | заменяется |
| `/data/games/<id>/` | игры, их `linuxloader.ini`, `controls.ini` | ✅ | ✅ |
| `/data/config/arcadeos.conf` | автозапуск и задержка | ✅ | ✅ |
| `/data/saves/` | зарезервировано под сейвы | ✅ | ✅ |
| `/tmp`, журнал systemd | временное | ❌ | ❌ |

---

## 12. Обновление системы

1. Собери новую версию **с теми же ключами** (`keys/` не трогать), увеличь `ARCADEOS_VERSION`.
2. Запиши новый ISO на флешку.
3. Загрузись с флешки (временно разреши загрузку с USB в BIOS).
4. На главном экране будет кнопка **UPDATE** (она появляется, если найден диск с ArcadeOS).
5. **UPDATE** → выбрать диск → **UPDATE NOW**.

Что происходит:

- `ARC_ROOT` открывается HWID-ключом (на этой же плате) и **перезаписывается** новым образом;
- на ESP копируются новые shim и UKI, загрузочная запись пересоздаётся;
- если firmware снова в Setup Mode, ключи записываются заново;
- **`/data` не трогается**: игры и настройки сохраняются.

> ⚠️ Обновление пишет корень «на месте». Выключение питания во время UPDATE оставит
> нерабочую систему, тогда помогает повторный UPDATE (данные `/data` не пострадают).

Ключи сборки обязаны совпадать: UKI новой версии подписан db-ключом, и firmware примет
его, только если это **тот же** ключ, что был записан при установке.

---

## 13. Ключ восстановления и замена железа

### 13.1 Когда он понадобится

HWID-ключ перестанет подходить, если изменится что-то из списка:

- материнская плата (замена, ремонт с перепрошивкой серийника);
- прошивка BIOS, если новая версия по-другому заполняет DMI;
- перенос диска на другой ПК.

Сетевая карта, видеокарта, ОЗУ, процессор на ключ **не влияют**: в него входят только поля DMI.

### 13.2 При загрузке

Plymouth покажет: **`Hardware changed. Recovery key (root):`**. Введи ключ, дефисы и регистр
можно не соблюдать (`abcd-efgh…` = `ABCDEFGH…`). Затем то же для `(data)`. Даётся 5 попыток на том.

Система загрузится, но **при следующей загрузке снова попросит ключ**: при загрузке
привязка к новой плате не обновляется, корень только для чтения.

### 13.3 Перепривязка к новой плате

1. Загрузиться с флешки установщика (той же или более новой версии, собранной теми же ключами).
2. **UPDATE** → выбрать диск.
3. Установщик увидит, что HWID не подходит, и покажет экран **HARDWARE CHANGED**.
4. Ввести ключ восстановления → **UNLOCK AND UPDATE**.
5. В оба тома добавится новый HWID-слот, система обновится, `/data` сохранится.

### 13.4 Если ключ восстановления потерян

И плата поменялась — **данные не восстановить**, это и есть смысл шифрования.
Останется только переустановка (INSTALL) с потерей `/data`.

### 13.5 Проверка DMI своей платы заранее

Загрузи любой live-Linux и выполни:

```sh
sudo sh rootfs/usr/local/sbin/hwid-key --check
```

`VERDICT ok` — привязка нормальная. `VERDICT weak` — плата отдаёт «заводские» значения
(`To be filled by O.E.M.`, `Default string`, нулевой UUID). Тогда привязка формальная:
такие же ID у тысяч плат.

---

## 14. Ключи подписи: хранение и бэкап

Папка `keys/` — **самое ценное** в проекте:

| Файл | Назначение |
|---|---|
| `PK.key/.crt` | Platform Key: владелец firmware |
| `KEK.key/.crt` | Key Exchange Key: разрешает менять db |
| `db.key/.crt/.der` | подписывает shim, MokManager, UKI; вшит в shim |
| `MOK.key/.der` | подписывает модули ядра (`nvidia.ko`) |
| `*.esl`, `*.auth` | подготовленные переменные для записи в firmware |
| `GUID.txt` | GUID владельца ключей |
| `ms/` | сертификаты Microsoft UEFI CA (если `SB_MS_UEFI_CA=1`) |

Правила:

- `keys/` в `.gitignore`, **никогда не коммить и не выкладывай**;
- держи зашифрованный бэкап офлайн (например, `tar c keys | gpg -c > keys.tar.gpg` на отдельной флешке);
- **потерял `keys/`** — не сможешь выпустить обновление для уже установленных машин. Придётся
  на каждой очищать ключи в BIOS и переустанавливать (или UPDATE из Setup Mode с новыми ключами);
- **утёк `db.key`** — злоумышленник сможет подписать свой UKI. Тогда нужно сгенерировать
  новые ключи и переустановить ключи на всех машинах.

---

## 15. Отладка и решение проблем

### 15.1 Отладочная сборка

В `config.env`:

```sh
DEBUG_ROOT_PASSWORD="test123"
```

После пересборки (`rootfs image boot installer`) у root будет пароль, а на **tty2** — экран
входа. `DontVTSwitch` в X не даёт переключиться во время игры, поэтому выходи в меню и
жми Ctrl-Alt-F2.

Полезное в отладочном режиме:

```sh
journalctl -b                       # лог загрузки (в RAM)
cat /tmp/arcade-x.log               # лог последнего запуска игры
veritysetup status arcroot-v        # состояние verity
mokutil --sb-state; mokutil --list-enrolled
modinfo -F signer nvidia            # кем подписан драйвер
nvidia-smi
cryptsetup luksDump /dev/disk/by-partlabel/ARC_ROOT
```

Для «боевой» сборки `DEBUG_ROOT_PASSWORD` **должен быть пустым**.

### 15.2 Таблица проблем

| Симптом | Причина | Что делать |
|---|---|---|
| Чёрный экран с момента включения, ничего не видно | GOP видеокарты не подписан твоими ключами (`SB_MS_UEFI_CA=0`) | Сбросить CMOS, пересобрать с `SB_MS_UEFI_CA=1` или переключиться на iGPU |
| Флешка не грузится: «Security violation» | Secure Boot включён и firmware не в Setup Mode | Очистить ключи в BIOS или временно выключить Secure Boot |
| Установщик: `not booted in UEFI mode` | Загружено в Legacy/CSM | Выключить CSM, выбрать UEFI-вариант флешки в boot menu |
| Установщик: `WEAK HARDWARE ID` | Плата отдаёт «заводские» DMI | Продолжить (слабая привязка) или выбрать другую плату |
| Установщик: `installer media is corrupted` | Повреждённая запись ISO | Перезаписать флешку, проверить sha256 ISO |
| Установщик: `efi-updatevar … failed` | firmware отвергла ключ | Проверить, что Setup Mode включён; некоторые BIOS требуют сначала «Install default keys», затем «Clear» |
| После заставки чёрный экран / меню в текстовом режиме, игры не стартуют | Не зачислен MOK, `nvidia.ko` не загружен | См. [раздел 8](#8-первая-загрузка-mokmanager) |
| `ArcadeOS: root image failed verification` | Образ на диске повреждён или не соответствует UKI | Загрузиться с флешки → UPDATE |
| `ArcadeOS: device … not found` | Не найден раздел (драйвер диска не попал в initramfs, редкий контроллер) | Отладочная сборка; добавить модуль в `MODULES` или в hook |
| Каждую загрузку спрашивает ключ восстановления | Плата/BIOS поменялись | [13.3](#133-перепривязка-к-новой-плате) |
| Игра сразу выходит, показан лог | Неверный `GAMEPATH`/`ELF`, не та версия дампа, не хватает библиотек | Проверить `game.conf`, лог, гайд linuxloader |
| Нет звука | Выбрана не та звуковая карта (HDMI vs аналог) | Sound test; настроить ALSA (см. [16.4](#164-звук)) |
| JVS-адаптер не виден | Другие VID/PID | Поправить `rootfs/etc/udev/rules.d/90-arcadeos.rules` |

### 15.3 Сборка падает

| Ошибка | Решение |
|---|---|
| `submodule missing` | `git submodule update --init` |
| Стадия `loader`: ошибка `apt` или сборки SDL3 | Upstream мог поменять `install-packages.sh`/`build-deps.sh`. Удали `work/llbuild` и запусти снова; если не помогло, попробуй предыдущий тег submodule |
| `linuxloader: unresolved libraries in target: …` | Не хватает 32-битной библиотеки в целевой системе. Найди пакет (`apt-file search <lib>`) и добавь `<пакет>:i386` в `packages/i386.list` |
| `package X not available, skipped` (i386) | Не критично, многие библиотеки есть в `ll-deps`. Исправь имя в `packages/i386.list` |
| `nvidia.ko for … missing or unsigned` | DKMS не собрал модуль: проверь, что `linux-headers-amd64` совпадает с ядром; см. `work/rootfs/var/lib/dkms/nvidia/*/build/make.log` |
| Ошибка сборки shim | Смени `SHIM_VERSION` на актуальный релиз [rhboot/shim](https://github.com/rhboot/shim/releases), проверь зависимости |
| `initramfs does not contain the arcadeos boot script` | Не скопировался оверлей `rootfs/` или нет прав на hook |
| После прерванной сборки «device busy» | `sudo umount -R work/rootfs/{run,dev,sys,proc}` и перезапуск |

---

## 16. Кастомизация

### 16.1 Логотип загрузки

`rootfs/usr/share/plymouth/themes/arcadeos/logo.png` — PNG с прозрачностью, рекомендуется
~900×260. Скрипт темы (`arcadeos.script`) сам масштабирует его до 80% ширины экрана.
Цвета точек и подсказок задаются там же (`Image.Text(…, r, g, b, a, …)`).

### 16.2 Цвета меню

Переменная `NEWT_COLORS` в начале `rootfs/opt/arcadeos/bin/arcade-launcher`.

### 16.3 Установщик

`installer/installer.py`: цвета в константах `BG`, `FG`, `ACC`, `ERR`. Тексты экранов в
методах `screen_*`. Логика установки целиком в `installer/install.sh`.

### 16.4 Звук

Чтобы закрепить вывод за конкретной картой, создай в оверлее `rootfs/etc/asound.conf`:

```
defaults.pcm.card 1
defaults.ctl.card 1
```

Номер карты: `aplay -l` в отладочной сборке.

### 16.5 JVS и последовательные порты

`rootfs/etc/udev/rules.d/90-arcadeos.rules` даёт адаптеру стабильное имя `/dev/ttyJVS0`.
Подставь VID/PID своего USB-RS485 (`lsusb`). Пользователь `arcade` состоит в группе
`dialout`, отдельные права не нужны.

### 16.6 Дополнительные пакеты

Добавь имена в `packages/base.list` (по одному в строке) и пересобери с `rootfs`.

### 16.7 Новые платформы

`rootfs/opt/arcadeos/bin/arcade-run` выбирает способ запуска по `PLATFORM` из `game.conf`.
Чтобы добавить, например, Wine для Taito Type X, добавь ветку в `case "$PLATFORM"`, а
нужные пакеты — в списки.

### 16.8 Сеть

По умолчанию проводной интерфейс получает адрес по DHCP (`systemd-networkd`,
`rootfs/etc/systemd/network/80-wired.network`). Для статического IP (например, для
линковки кабинетов) поправь этот файл.

---

## 17. Структура репозитория

```
arcadeos/
├── build.sh                         точка входа сборки
├── config.env                       все настройки
├── build/
│   ├── lib.sh                       общие функции (лог, chroot, пути)
│   ├── 00-keys.sh                   ключи Secure Boot и MOK
│   ├── 05-linuxloader.sh            сборка linuxloader из submodule
│   ├── 10-rootfs.sh                 корневая ФС Debian
│   ├── 20-image.sh                  initramfs, squashfs, dm-verity
│   ├── 30-boot.sh                   shim, UKI, подписи, payload
│   └── 40-installer.sh              ISO установщика
├── packages/
│   ├── base.list                    базовая система
│   ├── nvidia.list                  драйвер NVIDIA
│   └── i386.list                    32-битные библиотеки для игр
├── rootfs/                          оверлей, копируется поверх системы
│   ├── etc/initramfs-tools/
│   │   ├── hooks/arcadeos           что положить в initramfs
│   │   ├── scripts/arcadeos         разблокировка LUKS, verity, overlay, /data
│   │   └── conf.d/arcadeos
│   ├── etc/systemd/…                автологин, logind, journald, сеть
│   ├── etc/X11/xorg.conf.d/         запрет VT-переключения, DPMS
│   ├── etc/sysctl.d/                SysRq, dmesg, kptr
│   ├── etc/sudoers.d/arcadeos       лаунчеру разрешён только arcade-admin
│   ├── etc/udev/rules.d/            JVS
│   ├── usr/local/sbin/
│   │   ├── hwid-key                 вывод ключа из DMI (POSIX sh)
│   │   └── arc-open-pass            ввод ключа восстановления
│   ├── usr/share/plymouth/themes/arcadeos/
│   └── opt/arcadeos/
│       ├── bin/arcade-launcher      меню на tty1
│       ├── bin/arcade-run           запуск игры внутри X
│       ├── bin/arcade-admin         root-действия по белому списку
│       ├── lib/common.sh            чтение game.conf, настройки
│       └── skel/bash_profile        tty1 → лаунчер
├── installer/
│   ├── install.sh                   бэкенд установки/обновления
│   ├── installer.py                 GUI (Tk): INSTALL / UPDATE
│   └── live/                        конфигурация live-build
├── tools/qemu-test.sh               ВМ с Secure Boot
├── examples/game.conf
├── vendor/linuxloader/              git submodule → lindbergh-loader/linuxloader
└── THIRD_PARTY.md                   атрибуция и лицензии сторонних компонентов
```

Не в репозитории (`.gitignore`): `keys/`, `work/`, `out/`.

---

## 18. Планы

- [ ] **Keychip**: внешний аппаратный ключ (FIDO2 или самодельный на RP2040 + ATECC608)
  как второй фактор в `hwid-key`. Без него диск не откроется даже на родной плате
- [ ] **A/B-разделы** для атомарных обновлений без риска при отключении питания
- [ ] Платформа **Wine/Taito Type X** (`PLATFORM=typex`, DXVK, префиксы на `/data`)
- [ ] Графическое меню (SDL2) с обложками и управлением от JVS
- [ ] Вход в тест-режим аппаратной кнопкой Test при загрузке
- [ ] Поддержка AMD/Intel (Mesa)
- [ ] Аппаратный watchdog

---

## 19. Лицензии и правовое

- **ArcadeOS** (этот репозиторий): некоммерческий экспериментальный проект.
- **linuxloader** © Linux Loader Development Team, лицензия
  [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Подключён как
  submodule и собирается **без изменений**. Лицензия разрешает некоммерческое
  распространение с указанием авторства, поэтому лоадер входит в собранный образ, а
  атрибуция лежит в системе в `/usr/share/doc/linuxloader/`. Авторы **запрещают
  коммерческое использование** без их согласия: игровые автоматы за деньги, подписки,
  продажа сборок. Это ограничение распространяется и на образы ArcadeOS. Если меняешь код
  лоадера, публикуй изменения под той же лицензией, а лучше присылай их upstream.
  Подробности: [`THIRD_PARTY.md`](THIRD_PARTY.md).
- **Игры** не входят ни в репозиторий, ни в образ. Используй только дампы, на которые у тебя есть права.
- Драйвер NVIDIA, firmware и пакеты Debian — под своими лицензиями (non-free компоненты Debian).
