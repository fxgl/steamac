# Как это устроено

[English](../architecture.md) · **Русский** · [简体中文](../zh/architecture.md)

← [Руководство](README.md)

| Каталог | Что внутри |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + патчи: depth_clip_enable, YCbCr-массивы, null-дескрипторы, эмуляция геометрических шейдеров для zink/DXVK (шаг вершин, instancing, adjacency, fans, SCALED-форматы, упакованные вершинные форматы: 10-10-10-2, RG11B10F, RGB9E5, BGRA8, `gl_in`), transform feedback (stream output DXVK) и его запросы (статистика SO), доступность результатов запросов при копировании (occlusion-запросы DXVK через Venus), атомики на компонентах векторов по адресам буферов (BDA, vkd3d-proton), упакованные по компонентам выходы вершин под тесселяцией (dxil-spirv, Rift Apart), texel-буферы со смещением на любой тексель (vkd3d-proton), запись в маленькие буферы push-дескрипторов с robustness2, массивы дескрипторов переменной длины как runtime-массивы (Metal держал 32 МБ на массив кучи vkd3d-proton и программу), распределение служебных буферов, отложенное освобождение Metal-ресурсов, хеш патчей в UUID кэша конвейеров, `VK_NULL_HANDLE`-наборы дескрипторов при привязке, выходы фрагментного шейдера в числовом типе их цветового вложения, нули во входах вершинного шейдера без вершинного атрибута, целочисленные вершинные входы из вещественных форматов, проверка null у YCbCr-сэмплеров во вспомогательных функциях, отказ для неподдерживаемых форматов texel buffer; тесты в `repro/` гоняются под валидацией Metal (и на KosmicKrisp: `REPRO_DRIVER=kosmickrisp`); `bench/run.sh <libdir>…` сравнивает производительность изменений между сборками; `bench/shaders.sh <дамп или пак>` меряет компиляцию шейдеров игры (SPIR-V → MSL, MSL → библиотека Metal, pipeline state; холодный/тёплый кэш, потоки) по дампу шейдеров MoltenVK или 10%-выборке из `bench/pack.py` |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + открытые MR Mesa и патчи steamac (см. [Vulkan-драйверы](vulkan-drivers.md#драйверы-vulkan)), без LLVM во время работы (`-Dllvm=disabled`, `mesa_clc` из первой сборки), `-Db_ndebug=true`; только macOS 26+ |
| `host/dxmt/` | Закреплённый DXMT + патчи, статический LLVM 15, нативный airconv, кросс-компиляция Windows DLL и гостевые библиотеки; `build.sh fetch llvm native host pe client payload` |
| `wmtr/` | Ремотинг winemetal, BSD-3-Clause: гостевой `winemetal.so` через virtio-gpu к `libwmtr_host.dylib` (со связанными DXMT/LLVM), вывод CAMetalLayer во view ВМ |
| `host/libepoxy/` | libepoxy 1.5.10, стандартные macOS-опции Meson, сборка для macOS 15.0 вместо копирования Homebrew bottle |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + слияние с upstream main (venus-protocol 1.1.3) + LINEAR-модификатор, импорт shm как host memory, заглушки для неудавшихся конвейеров (draw отбрасываются в virglrenderer), пересоздание отвергнутого кэша, отложенный unmap shm, QoS потоков, Vulkan-драйвер открывается во время работы (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.8 (уже с `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K) и маской SME для M4) + патчи: 2D-ресурсы без virgl, `SET_SCANOUT_BLOB`, маппинг SHM-блобов, сигнализация Venus-фенсов, логи virglrenderer, `krun_display_resize` (смена разрешения на лету), QoS vCPU/GPU-потоков |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): окно на Metal (Сверхвысокое разрешение MetalFX по желанию), оверлей «FX STEAM LAUNCHER» с прогрессом загрузки/выключения, разрешение гостя = размер окна (× backing scale экрана с Разрешение Retina) при постоянном DPI (EDID из физического размера экрана), клавиатура/мышь/планшет, pad гостя Xbox 360 / DualSense / DualShock 4 из GameController.framework с вибрацией или DualSense, проброшенный как сырое HID-устройство (`fx.pad`), сеть через gvproxy, перезапуск ВМ при reboot гостя, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, всё встроено, 4K-страницы, выравнивание blob-узлов по 16K, Apple TSO для FEX; uhid, hidraw и `hid-playstation` (с нужными ему классами LED) для проброшенного DualSense |
| `guest/mesa/` | Из закреплённого Mesa: Venus ICD для aarch64 (Proton, gamescope, zink) и x86_64/i386 (FEX-провайдер графики); GL-стек zink (libgallium, GLX/EGL/GBM) поверх штатного в обоих, с бэкпортами из `guest/mesa/patches/` (Mesa 6abefa51: zink пересоздаёт pipeline, когда меняется только формат вершин; без `VK_EXT_vertex_input_dynamic_state`, которого нет у Venus на Metal, GL-игры иначе рисуют со старыми форматами вершин); x86_64-репортёр сбоев эмулируемых игр (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | загрузочный этап = «загрузчик»: выбор слота A/B со счётчиком попыток, partsets, оверлеи `/etc` и `/usr`; первичная подготовка диска, созданного лаунчером (`steamac.provision=1`: статические mkfs.fat, mke2fs, btrfstune в initramfs); `steamac.ssh=0` — без SSH-сервера; config-payload лаунчера (`steamac.config=1`) — новый пароль `steamos`; `steamac.tz=` — часовой пояс Mac в `/etc/localtime`; нетронутый procfs в `/run/steamac/proc` для песочниц Flatpak; `steamac.share=` — runtime-юнит монтирования общей папки (virtio-fs `macshare`, см. [Общая папка](clipboard-and-shared-folder.md#общая-папка)) |
| `guest/layer/` | слой для ВМ поверх `/usr` (read-only erofs): файловый `splctl`, безопасный post-install для RAUC, `VARIANT_ID=steamdeck`, сессия gamescope на DRM, режим рабочего стола (Plasma внутри gamescope), маски сервисов железа Frame, агент прогресса `fx-progress-agent` (Rust, `guest/progress-agent/`, порт virtio-console `fx.progress`) и его root-сервисы (`fx.clock`, `fx.sleep`, uinput- или uhid-геймпад на `fx.pad`), быстрые таймауты выключения, режим входа в Steam с QR-кодом (клиент Steam Deck, пока нет запомненного аккаунта), опциональная ветка клиента Steam (`/etc/steamac/steam-client-branch`), фоновая обработка шейдеров Steam включена по умолчанию (`steam-shader-defaults`), заставка Steam при бездействии по умолчанию выключена (`steam-idle-screensaver`), сброс фиксированных масок CPU affinity системного и пользовательского менеджеров, чтобы после загрузки с обновлённым слоем сервисы наследовали доступные vCPU ВМ |
| `scripts/` | сборка `work/out/steamos.img`: GPT в разметке Valve (esp, efi-A/B, rootfs-A/B, var-A/B, home); `scripts/test/provision-test-disk.sh` — dev-проверка провижининга против диска из Docker; `scripts/test/vkd3d-tiled.sh` — dev-проверка D3D12 tiled resources и feature level насквозь (тесты vkd3d-proton из Proton 11.0, `d3d12-caps`, `vk-minmax`) во временной ВМ |

### Курсор на пути DXMT

При wmtr DXMT выводит игру как `CAMetalLayer` внутри процесса ВМ на Mac. Слой расположен над
гостевым scanout и закрывает курсор гостевого композитора. В каждом новом гостевом агенте
отслеживание **выключено**. Лаунчер шлёт `cursor-track 1|0` по `fx.progress` при изменении
видимости/присоединения слоёв wmtr и повторяет текущее состояние при переподключении progress или
стартовом сообщении гостя `cursor-ready`. Повторное включение заново передаёт полный снимок курсора.
Для 1 нужны и фокус игры, допускающий игровые слои, и настоящий присоединённый, видимый
`CAMetalLayer` wmtr. Vulkan и Steam/рабочий стол без этого оверлея не требуют отслеживания курсора;
неизвестные команды хоста игнорируются для совместимости старых/новых хоста и гостя.

При включении гостевой агент (`guest/progress-agent/src/cursor.rs`) находит дисплей Xwayland,
у которого `WM_CLASS` активного окна начинается с `steam_app_`; обязательны поддержка XFixes и
активное окно игры, без подстановки корневого окна. Он получает начальную картинку через
`XFixesGetCursorImage`, затем обновляет её по событиям смены
курсора XFixes, а не периодическим опросом; `QueryPointer` опрашивает позицию не чаще 60 Гц,
только пока она нужна. Передаются лишь изменения: `cursor 0|1`,
`cursor-image <w> <h> <xhot> <yhot> <base64 BGRA>` и `cursor-pos <x> <y> <win_w> <win_h>`.
Позиция и размер — в пикселях клиентской области X-окна игры в фокусе, а не корневого X-окна:
у оконной игры корневое окно может быть больше клиентской области. Курсор 1×1 или полностью
прозрачный скрыт — Wine использует такие для игры без курсора.

Лаунчер разбирает сообщения в `Progress.swift` и через `Window.swift` передаёт их в `VMView`
из `Presenter.swift`, где есть прозрачный `CALayer` с именем `steamac.cursor-overlay` и
`zPosition` 1000. Он видим лишь при видимом игровом слое, видимом гостевом курсоре и известной
позиции; исключён из правил игровых слоёв и Metal HUD и присоединяется заново, если wmtr удаляет
подслои. Картинка становится `CGImage` с premultiplied-first. Перед отображением во view картинка
и hotspot масштабируются как при `--cursor-scale-height 720` в gamescope: при высоте окна игры H
желаемый размер — `clamp(36 * floor(H / 720), 36, 256)` пикселей. Как в gamescope, если хотя бы
одно измерение картинки больше желаемого, она уменьшается до квадрата, а координаты hotspot
усекаются до целых; иначе масштаб равномерный, не меньше 1, по отношению желаемого размера к
высоте картинки. Позиция в X-окне отображается в прямоугольник вывода активного удалённого
игрового слоя (`drawableSize`, вписанный с сохранением пропорций, как у wmtr), а не в картинку
гостя: отличие размера или пропорций игрового слоя от scanout гостя не сдвигает курсор.
Композитор выполняет окончательное масштабирование во view и альфа-смешивание.

Видимость следует **курсору самой игры**, а не скрытию gamescope после 3 секунд бездействия.
Правила курсора Mac не меняются: auto скрывает его над картинкой, захват — пока мышь захвачена;
в режиме tablet и при незахваченном `--mouse capture` могут быть видны и курсор Mac, и гостевой
оверлей. Захваченная мышь для обзора сама по себе не скрывает курсор, который игра считает видимым.

MoltenVK также исправляет fragment-хелперы с discard в иначе пустом блоке SPIR-V
(STEAMAC-1Q). `host/moltenvk/repro/msl_helpers.c` проверяет прямой и вложенный вызовы:
отброшенные пиксели остаются очищенными и не пишут в storage-буферы, остальные рисуются нормально.
Хелперы `log10(float)` переименовываются, чтобы не конфликтовать с перегрузкой Metal (STEAMAC-1R);
тот же repro читает результат compute-хелпера, а не только проверяет создание конвейера.

`vkCmdBindDescriptorSets` с `VK_NULL_HANDLE` среди наборов (допустимо с graphics pipeline
libraries) больше не роняет ВМ при отправке командного буфера (Counter-Strike 2 привязывает пять
наборов, четвёртый — null, STEAMAC-25): как в RADV, null-набор ничего не привязывает и не забирает
динамических смещений (`repro/invalid_usage.c`).

Выход фрагментного шейдера другого числового типа, чем его цветовое вложение (конвейер Left 4 Dead 2
из DXVK пишет беззнаковый выход в вложение `R32_SINT`, STEAMAC-2C; Vulkan оставляет значения
неопределёнными), не собирался в Metal, и draw с этим конвейером пропускались; теперь он объявляется
с типом вложения и записывает свои биты (`repro/frag_output.c`).

Вход вершинного шейдера без вершинного атрибута в конвейере (шейдер SCS Truck Simulator читает
`in_var_NORMAL` из location 1, который конвейер не описывает, STEAMAC-2Y; Vulkan оставляет значения
неопределёнными) не собирался в Metal («missing from the vertex descriptor»), и draw с этим конвейером
пропускались; теперь такие входы читают нули (`repro/vertex_input.c`).

Целочисленный вход вершинного шейдера с вещественным форматом атрибута (BLUE REFLECTION: Second Light
читает `BLENDINDICES1` как `int4` из атрибута `Float3`/`Float4`, STEAMAC-3N) не собирался в Metal
(«cannot be read using MTLAttributeFormatFloat3»), и персонажи были невидимы; теперь атрибут читается
в совместимом с форматом типе, а его биты переинтерпретируются (`repro/vertex_input.c`). Устойчивая
выборка через вспомогательную функцию с неизменяемым YCbCr-сэмплером больше не ломает компиляцию
(`is_null_texture`, STEAMAC-3W; `repro/texture_helpers.c`). Texel buffer view формата, для которого в
Metal нет пиксельного формата, возвращает `VK_ERROR_FORMAT_NOT_SUPPORTED` вместо падения процесса ВМ
(Uncharted, STEAMAC-3Q; `repro/texel_buffer.c`); texel buffer view шире 2^28 текселей Metal завершается
`VK_ERROR_OUT_OF_DEVICE_MEMORY` вместо аварийной остановки в проверке дескриптора Metal (STEAMAC-9E/79).
Несобравшийся графический конвейер пишет в лог точку
входа, хеш шейдера и интерфейс каждой стадии — для ошибок связывания и компилятора без MSL.

Корневая ФС SteamOS не модифицируется: все изменения приходят из initramfs и слоя. Поэтому
официальные обновления Valve (RAUC + atomupd) ставятся в другой слот и откатываются штатно —
проверено обновлением 20260922 → 20260928 и откатом.

Venus ICD слоя линкуются только с sonames, которые обновления SteamOS сохраняют
(`guest/mesa/container/verify.sh`, `check_stable_needed`); libdisplay-info не используется. SteamOS
0.6.0 (канал preview, 20261020) заменила `libdisplay-info.so.1` на `.so.3`: ICD из 1.9.7 не
загружался, gamescope не находил Vulkan-устройство и ВМ оставалась на «Starting Steam client»
(STEAMAC-72). Проверено обновлением stable → preview до 20261020 (0.6.0): Steam запускается в
обновлённом слоте.
