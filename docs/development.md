# LocalDrop — заметки разработчика

Технические подробности: структура, системные API, ограничения платформ, сборка и статус
milestones. Обзор проекта — в [README](../README.ru.md).

Связь Android ↔ macOS, которая ощущается как возможность ОС, а не как ещё одно приложение
для передачи файлов. Главный интерфейс — Android Sharesheet, уведомления macOS и menu bar:

```
Gallery → Share → MacBook Pro → Done
```

* Постоянная криптографическая привязка устройств (один раз, 6-значный код).
* Mac — прямая цель в Android Sharesheet (Direct Share).
* Присутствие по BLE: телефон знает, что *его* Mac рядом; посторонние Mac не видят.
* Передача — TCP в локальной сети или через точку доступа телефона, AES-256-GCM, SHA-256.
* Без облака, аккаунтов и интернета.

Архитектура и продуктовые принципы: [`architecture.md`](architecture.md).
Спецификация протокола: [`protocol/protocol.md`](../protocol/protocol.md),
[`protocol/messages.md`](../protocol/messages.md), [`protocol/security.md`](../protocol/security.md).

## Структура репозитория

```
LocalDrop/
├── protocol/                 спецификация wire protocol v1
├── macos/
│   ├── LocalDrop.xcodeproj
│   ├── LocalDrop/            исходники (синхронизируемая группа Xcode)
│   │   ├── App/              точка входа, AppModel, MenuBarExtra
│   │   ├── Device/           локальное устройство (deviceId, имя)
│   │   ├── Crypto/           identity key (Keychain), fingerprint
│   │   ├── Protocol/         CBOR, константы протокола, EndpointInfo
│   │   ├── Discovery/        BLE peripheral (CoreBluetooth)
│   │   ├── Transport/        TCP listener (BSD-сокеты, DispatchIO) + Bonjour (dns_sd)
│   │   └── UI/               SwiftUI-представления меню
│   └── Support/              Info.plist, entitlements
└── android/
    └── app/src/main/java/dev/localdrop/
        ├── app/              Application, MainActivity, AppContainer
        ├── core/
        │   ├── device/       локальное устройство (deviceId, имя)
        │   ├── crypto/       identity key (Android Keystore), fingerprint
        │   ├── protocol/     CBOR, константы протокола, EndpointInfo
        │   ├── discovery/    BLE scanner + GATT-клиент
        │   ├── transport/    TCP, handshake, шифрованный канал
        │   ├── transfer/     состояние передачи, отправка файлов, источники данных
        │   └── storage/      MediaStore / ContentResolver (Milestone 5+)
        └── feature/
            ├── devices/      устройства: доверенные Mac, «Добавить Mac», по умолчанию
            ├── transfer/     передача (с M5 — Share-цель и foreground service)
            └── settings/     разрешения, настройки, диагностика
```

**Android — один Gradle-модуль**, границы — пакеты. Многомодульная сборка на MVP добавляет
конфигурацию, но не добавляет надёжности; пакеты `core/*` не зависят от `feature/*`
и могут быть вынесены в модули без переписывания. UI работает только с `ViewModel`,
которые получают `StateFlow` от `core`-слоя; BLE, сокеты и файлы в Compose не попадают.

**macOS — одно приложение-таргет** (Menu Bar, `LSUIElement`). Share Extension появится
отдельным таргетом на этапе macOS → Android.

## Системные API

| Задача | Android (Kotlin) | macOS (Swift) |
|--------|------------------|---------------|
| BLE | `BluetoothLeScanner`, `ScanFilter`, `BluetoothGatt` | `CBPeripheralManager`, `CBMutableService` |
| Сеть | `java.nio.channels.SocketChannel` на `Dispatchers.IO`, `ConnectivityManager` | BSD-сокеты + `DispatchIO` (стек ядра: `NWConnection` отдавал телефону 10–19 МБ/с против 22–35), `NWPathMonitor` |
| mDNS (fallback) | `NsdManager` | `DNSServiceRegister` (Bonjour) |
| Identity key | `KeyPairGenerator("EC", "AndroidKeyStore")`, `Signature("SHA256withECDSA")` | `P256.Signing.PrivateKey` + Keychain (`SecItem*`) |
| ECDH | `KeyAgreement("ECDH")` (JCA, в памяти) | `P256.KeyAgreement` |
| KDF | HKDF из `Mac("HmacSHA256")` | `HKDF<SHA256>` |
| AEAD | `Cipher("AES/GCM/NoPadding")` | `AES.GCM` |
| SHA-256 | `MessageDigest("SHA-256")` | `SHA256` |
| Файлы | `ContentResolver.openInputStream`, `OpenableColumns`, `MediaStore.Downloads` | `FileHandle`, security-scoped bookmarks |
| Фон | Foreground service (`dataSync`) | Menu bar app (`LSUIElement`) |
| UI | Jetpack Compose, `ViewModel`, `StateFlow` | SwiftUI `MenuBarExtra`, AppKit где нужно |
| Уведомления | `NotificationManager` | `UserNotifications` |
| Логи | `android.util.Log` (теги `LD/*`) | `os.Logger` (subsystem `dev.localdrop.mac`) |

## Локализация

Английский (основной) и русский; язык берётся из системы, на Android 13+ и macOS его можно
выбрать для LocalDrop отдельно (Настройки › Приложения / Язык и регион › Приложения).

* **macOS:** String Catalog `macos/LocalDrop/Resources/Localizable.xcstrings` (с формами
  множественного числа) и `InfoPlist.xcstrings` для системных запросов. Строки в коде — через
  `Text("…")` или `String(localized:)`; сообщения ошибок для пользователя — `SessionError.userMessage`,
  `description` остаётся английским для логов. Новые строки: `xcodebuild -exportLocalizations`.
* **Android:** `res/values` и `res/values-ru`, `res/xml/locales_config.xml`.

## Ограничения платформ

### Android 10–11 (API 29–30)

* **BLE-скан требует `ACCESS_FINE_LOCATION` и включённой геолокации.** На Android 10–11 без
  включённого Location скан возвращает пустой результат без ошибки — приложение явно
  проверяет `LocationManager.isLocationEnabled` и просит включить.
* На Android 12+ вместо этого используются `BLUETOOTH_SCAN` (`neverForLocation`) и
  `BLUETOOTH_CONNECT`; location не нужен.
* Скан ограничен: не более 5 стартов за 30 секунд, иначе система молча блокирует скан.
  Сканер не перезапускается чаще, чем раз в 6 секунд.
* GATT на ряде устройств нестабилен: `status 133`. Чтение endpoint повторяется до 3 раз,
  `BluetoothGatt.close()` вызывается всегда.
* Foreground service типа `dataSync` (Android 14+) и `POST_NOTIFICATIONS` (Android 13+, один
  запрос при первой отправке) — учтены с Milestone 5.
* **Буфер обмена в фоне недоступен** (Android 10+): читать его может только приложение на
  экране или клавиатура. Автоматической синхронизации «скопировал — появилось на Mac» нет;
  вместо неё — плитка «Clipboard to Mac» (прозрачная активность читает буфер, получив фокус),
  «Send to Mac» в меню выделенного текста (`PROCESS_TEXT`) и «Поделиться». Приложения со своим
  меню выделения (Telegram) не показывают `PROCESS_TEXT` — там «Копировать» → плитка.
* Будущее ограничение: приложения с `targetSdk 37` должны запрашивать доступ к локальной сети
  (`ACCESS_LOCAL_NETWORK`). Сейчас `targetSdk = 36`; переход на 37 — отдельной задачей.

### macOS

* `CBPeripheralManager` рекламирует только local name и service UUID — manufacturer data
  недоступны, поэтому короткий id кодируется в имени (`LDa1b2c3`).
* Advertising прекращается при выходе из приложения и сне Mac. Поэтому приложение — menu bar
  агент, который работает постоянно.
* Нужен `NSBluetoothAlwaysUsageDescription`; первый запуск покажет системный запрос.
* App Sandbox: entitlements `com.apple.security.device.bluetooth`,
  `com.apple.security.network.server`, `com.apple.security.network.client`.
* Local Network Privacy (macOS 15+): `NSLocalNetworkUsageDescription` и
  `NSBonjourServices = _localdrop._tcp`.
* Application Firewall может спросить разрешение на входящие соединения при первом запуске.
* Папка для сохранения — «Загрузки» или любая выбранная в меню; выбранная хранится как
  security-scoped bookmark (`files.user-selected.read-write` + `files.bookmarks.app-scope`).
  Если она недоступна (диск отключён), файлы временно сохраняются в «Загрузки».
* Диапазон Wi-Fi (CoreWLAN, без запроса геолокации — она нужна только для имени сети):
  на 2.4 GHz меню подсказывает, что передача будет медленной.

### Сеть и скорость

Поддерживаются две топологии, выбор автоматический:

| Топология | Как подключается Android | Замер (Pixel 10 Pro → MacBook) |
|-----------|--------------------------|--------------------------------|
| Оба устройства в одной Wi-Fi сети | сокет привязан к Wi-Fi `Network` (не уходит в мобильные данные) | 16–19 MB/s (AP 5 ГГц, 40 MHz) |
| Mac подключён к точке доступа телефона | сокет без привязки, маршрут через интерфейс точки доступа | **105 MB/s** (5 ГГц, 80 MHz) |
| То же, точка доступа на 2.4 ГГц (Mi A2) | так же | 2.4 MB/s — медленнее, чем через роутер |

Точка доступа ускоряет передачу **только на 5/6 ГГц**. На 2.4 ГГц она медленнее обычной
сети, поэтому для таких телефонов этот режим не рекомендуется.

Через роутер каждый пакет проходит по воздуху дважды (телефон → AP → Mac), поэтому
скорость упирается в половину эфира канала. Точка доступа телефона даёт прямой
радиоканал. Точку доступа включает и подключает к ней Mac пользователь; автоматическое
управление сетями (и Wi-Fi Direct) в MVP не используется: Mac при этом теряет свою сеть,
а на Android 10–11 приложение не может выбрать диапазон точки доступа.


* Многие публичные/гостевые сети включают client isolation — устройства видят друг друга по
  BLE, но TCP-соединение невозможно. Это определяется по connect timeout и показывается как
  «Устройства в разных сетях или сеть блокирует соединения между устройствами».

## Сборка

### macOS

```bash
cd macos && xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop -configuration Debug build
```

Или открыть `macos/LocalDrop.xcodeproj` в Xcode 26+, выбрать свою команду в Signing и запустить.
Без команды сборка подписывается ad-hoc, подпись меняется при каждой сборке, и macOS
каждый раз спрашивает доступ к ключу в Keychain. Для локальных сборок из терминала:

```bash
xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop -configuration Debug -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<TEAM_ID> build
```
Минимальная версия — macOS 14.

### Android

```bash
cd android && ./gradlew assembleDebug
```

Интеграционный тест протокола против запущенного Mac-приложения (через loopback):

```bash
LOCALDROP_MAC_PORT=<порт из меню Mac> LOCALDROP_MAC_ID=<deviceId Mac> ./gradlew testDebugUnitTest
```

minSdk 29 (Android 10), targetSdk 36. Установка: `./gradlew installDebug`.

## Статус

| Milestone | Содержание | Статус |
|-----------|-----------|--------|
| 1 | Menu bar app, TCP listener, BLE advertising; Android BLE scan | ✅ |
| 2 | TCP + handshake (ECDH, подписи, AES-GCM) | ✅ |
| 3 | Pairing (6-значный код), trusted devices, отзыв доверия | ✅ |
| 4 | Протокол передачи, SHA-256, отмена, точка доступа телефона (105 MB/s) | ✅ |
| 5 | **Share to Mac:** Direct Share-цель на доверенный Mac, передача в foreground service, `content://` (один и несколько файлов, текст), прямое подключение по последнему endpoint (0,2–0,3 с до запроса), постоянный порт Mac, запрос — плашкой, итог — уведомлением, запуск при входе, App Nap выключен | ✅ |
| 6 | **Presence:** статусы Mac на телефоне (рядом / готов / занят / без сети / не рядом), приватный BLE-токен (HMAC от `presenceKey`, смена каждые 15 мин) со статус-буквой, зашифрованный Endpoint Info, режим привязки только по запросу (10 мин) или без доверенных устройств, capabilities в hello, Bonjour как третий путь, Mac перестаёт рекламироваться во сне | ✅ |
| 7 | **Policies:** политика приёма по устройству на Mac (спрашивать / фото и видео / до 100 MB / всё / отклонять), текст → буфер обмена Mac (сообщение `text`, ссылка — кнопка «Open Link»), Mac по умолчанию, плитка «Clipboard to Mac», «Send to Mac» в меню выделения текста | ✅ |
| 8 | **Queue:** Mac спит / далеко / в другой сети / занят — отправка ждёт, а не падает: копия во внутреннем spool (грант `content://` временный), повтор при появлении Mac по BLE (первые 5 мин — low-latency скан), смене сети и редко по таймеру (5 → 15 мин; без Bluetooth 30 с → 5 мин — каждая сетевая попытка будит спящий Mac); всё отправленное на один Mac — одной передачей, а пока на Mac открыт запрос, новые файлы добавляются в него (`transfer_add`); через час — парковка с «Try again»/«Discard», копия хранится 7 дней; спящий Mac отвечает `asleep` | ✅ |

План и обоснование — [`architecture.md`](architecture.md), раздел 8.
