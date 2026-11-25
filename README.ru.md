<p align="center"><img src="docs/media/icon.png" width="96" height="96" alt=""></p>

<h1 align="center">FX Steam Launcher</h1>

<p align="center">
Официальный ARM64 SteamOS от Valve — сборка для Steam Frame — в лёгкой ВМ на Apple Silicon.<br>
Windows-игры с ускорением графики, любой геймпад, родной звук.
</p>

<p align="center">
<a href="https://github.com/fxgl/steamac/releases/latest"><b>Скачать</b></a> ·
<a href="https://fxgl.github.io/steamac/">Сайт</a> ·
<a href="https://fxgl.github.io/steamac/games.html">Статистика игр</a> ·
<a href="manual/ru/README.md">Руководство</a>
</p>

<p align="center"><a href="README.md">English</a> · <b>Русский</b> · <a href="README.zh.md">简体中文</a></p>

![Игровой интерфейс Steam в FX Steam Launcher](docs/media/shot-library.jpg)

## Установка

1. Скачайте DMG со страницы [Releases](https://github.com/fxgl/steamac/releases/latest), откройте и
   перетащите FX Steam Launcher в «Программы». Приложение подписано и нотаризовано Apple.
2. Запустите и выберите **Новый диск…**: укажите ветку SteamOS, размер раздела под игры и клиент Steam,
   примите лицензию SteamOS и Соглашение подписчика Steam от Valve. Лаунчер скачает подписанный образ
   Valve (~4,5 ГБ), проверит его и запишет диск.
3. Войдите в Steam и ставьте игры — Proton 11 (ARM64) и FEX Steam поставит сам.

Нужен Mac на Apple silicon, macOS 15 или новее и ~20 ГБ свободного места на создание диска. Диск
разреженный и растёт по мере установки игр. Обновления ставятся прямо из приложения.

## Что работает

- **DirectX 9/10/11** через DXVK, **DirectX 12** через vkd3d-proton, OpenGL через zink.
- **x86-64 игры для Windows и Linux** через Proton 11 для ARM64 и FEX, с аппаратным TSO Apple.
- **Контроллеры**: Xbox, DualSense (в том числе проброс с тачпадом, гироскопом и адаптивными курками),
  DualShock 4, MFi и Steam Controller, с вибрацией. Захват мыши для обзора.
- **Звук** через CoreAudio, до 12 каналов (5.1, 7.1, 7.1.4), и микрофон.
- **Приостановка** в памяти, **режим рабочего стола**, общие **буфер обмена** и **папка**, стриминг в
  **Moonlight** и **Steam Remote Play** в локальной сети.
- Два драйвера Vulkan: **KosmicKrisp** (Metal 4, macOS 26+, там по умолчанию) и **MoltenVK** (Metal 3).

Какие игры идут и как, по данным игроков: [статистика игр](https://fxgl.github.io/steamac/games.html).

## Ограничения

- Игры, которым нужен DirectX 12 уровня 12_1 или shader model 6.6 (Unreal Engine 5), не запустятся.
- Античиты, блокирующие виртуальные машины, не пропустят.
- Новый эффект один раз подтормаживает, пока Metal его компилирует (~50–100 мс); дальше он в кеше.

Подробнее — в разделе [Статус и ограничения](manual/ru/status.md).

## Как это устроено

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

libkrun загружает подписанный образ SteamOS от Valve на Hypervisor.framework, без QEMU. Корневая файловая
система SteamOS не изменяется, поэтому официальные A/B-обновления работают как на Steam Deck. Все
компоненты и наборы патчей — в разделе [Как это устроено](manual/ru/architecture.md).

## Сборка из исходников

```sh
git clone https://github.com/fxgl/steamac
cd steamac
./build.sh    # MoltenVK, KosmicKrisp, virglrenderer, libkrun, лаунчер, ядро гостя, Mesa, диск
./run.sh      # SteamOS в окне
```

Нужны Xcode 26+, Homebrew, rustup и OrbStack (или Docker с arm64 и привилегированными контейнерами).
Полное руководство — [Сборка из исходников](manual/ru/building.md).

## Руководство

| Раздел | Что внутри |
|---|---|
| [Работа с лаунчером](manual/ru/using.md) | Приложение, удаление, языки, клиент Steam, вход |
| [Настройки](manual/ru/settings.md) | Все вкладки окна настроек и профили для игр |
| [Контроллеры](manual/ru/controllers.md) | Геймпады, проброс DualSense, Steam Controller, мышь и клавиатура |
| [Драйверы Vulkan](manual/ru/vulkan-drivers.md) | MoltenVK и KosmicKrisp: что поддерживает каждый и как переключать |
| [Стриминг и Remote Play](manual/ru/streaming.md) | Локальная сеть, Steam Remote Play и Moonlight |
| [Приостановка и сон](manual/ru/suspend-and-sleep.md) | Приостановка SteamOS в памяти и собственный сон SteamOS |
| [Режим рабочего стола](manual/ru/desktop-mode.md) | Рабочий стол Plasma внутри ВМ |
| [Буфер обмена и общая папка](manual/ru/clipboard-and-shared-folder.md) | Общие текст, картинки и папка Mac с SteamOS |
| [Отчёты о сбоях, обновления и статистика игр](manual/ru/privacy-and-updates.md) | Что отправляется, когда и как это выключить |
| [Сообщить о проблеме](manual/ru/report-a-problem.md) | Что входит в отчёт о проблеме и как его отправить |

## Участие

Отчёты об ошибках и играх, переводы и патчи приветствуются. Начните с [CONTRIBUTING.md](CONTRIBUTING.md) (на английском).

## Лицензия (License)

Код проекта — Apache License 2.0 (`LICENSE`), © 2026 FX GAMES FZ LLC. Исключения перечислены в
`NOTICE`: патчи и конфигурация ядра Linux — GPL-2.0-only, патчи для virglrenderer и Mesa — MIT
(как у этих проектов), пять файлов сессии gamescope, производные от пакета Valve
`deckard-steamvr-session`, — MIT © Valve Corporation; сертификат CA Valve и скриншоты в `docs/media`
лицензией проекта не покрываются. Тексты лицензий — в `LICENSES/`.

SteamOS в проект не входит и с ним не распространяется: приложение скачивает подписанный образ
с серверов Valve после того, как пользователь принял лицензию Valve (см. «Создание диска SteamOS
без Docker»).

Steam, логотип Steam, SteamOS, Steam Deck и Steam Frame — товарные знаки и/или зарегистрированные
товарные знаки Valve Corporation в США и/или других странах. Проект не связан с Valve Corporation и
не одобрен ею.
