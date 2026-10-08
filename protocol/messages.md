# LocalDrop Protocol v1 — сообщения

Все сообщения — CBOR map, ключ `t` — тип. Типы данных:
`uint` — CBOR unsigned int, `int` — signed, `tstr` — UTF-8 строка, `bstr` — байты,
`bool`, `[X]` — массив. `?` — необязательное поле.

Колонка **Enc**: `no` — передаётся открытым текстом, `yes` — только внутри AES-GCM фрейма.
Сообщение с неправильным уровнем шифрования → `bad_message` и закрытие.

## Handshake

### `client_hello` (Initiator → Responder, Enc: no)

| Ключ | Тип | Описание |
|------|-----|----------|
| `v` | uint | максимальная поддерживаемая версия |
| `minV` | uint | минимальная поддерживаемая версия |
| `id` | tstr | deviceId |
| `name` | tstr | имя устройства ("Pixel 5") |
| `platform` | tstr | `android` / `macos` / ... |
| `idKey` | bstr(65) | identity public key, P-256, X9.63 uncompressed (`04‖X‖Y`) |
| `eph` | bstr(65) | ephemeral ECDH public key, P-256, X9.63 uncompressed |
| `nonceCommit` | bstr(32) | `SHA-256(clientNonce)` |
| `caps` | ?[tstr] | возможности (protocol.md §2.6) |

### `server_hello` (Responder → Initiator, Enc: no)

| Ключ | Тип | Описание |
|------|-----|----------|
| `v` | uint | выбранная версия сессии |
| `id`, `name`, `platform`, `idKey`, `eph`, `caps` | | как в `client_hello` |
| `nonce` | bstr(32) | serverNonce |

### `client_nonce` (Initiator → Responder, Enc: no)

| Ключ | Тип | Описание |
|------|-----|----------|
| `nonce` | bstr(32) | clientNonce; Responder проверяет `SHA-256(nonce) == nonceCommit` |

### `server_auth` (Responder → Initiator, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `sig` | bstr | ECDSA P-256/SHA-256 (DER) над `"localdrop/v1/server-auth" ‖ th` |

### `client_auth` (Initiator → Responder, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `sig` | bstr | ECDSA P-256/SHA-256 (DER) над `"localdrop/v1/client-auth" ‖ th` |
| `trusted` | bool | Initiator уже доверяет этому identity key Responder'а |
| `keyChanged` | bool | Initiator знает этот deviceId, но с другим ключом |

### `session_status` (Responder → Initiator, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `status` | tstr | `trusted` — обе стороны доверяют ключам; `pairing_required` — нужна привязка; `key_changed` — хотя бы одна сторона видит смену ключа, нужна повторная привязка с предупреждением |
| `presenceKey` | ?bstr(32) | только при `trusted`: текущий ключ присутствия Responder'а (protocol.md §2.2). Initiator сохраняет его, заменяя прежний |

Если status ≠ `trusted`, а Responder не в режиме привязки, вместо `session_status` он
отправляет `error{pairing_unavailable}` и закрывает соединение.

### `pairing_confirm` (Initiator → Responder, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `accepted` | bool | пользователь Initiator'а подтвердил совпадение кода |

### `pairing_result` (Responder → Initiator, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `accepted` | bool | `true` только если подтвердили **оба** пользователя |
| `presenceKey` | ?bstr(32) | при `accepted = true`: ключ присутствия Responder'а |

Responder может отправить `pairing_result{accepted=false}` **в любой момент** после
`session_status`, не дожидаясь `pairing_confirm`, — если его пользователь отклонил привязку
первым. Поэтому Initiator читает соединение, пока его пользователь сравнивает код.
`pairing_result{accepted=true}` допустим только после `pairing_confirm{accepted=true}`.

Initiator может **отозвать** подтверждение: `pairing_confirm{accepted=false}` после
`pairing_confirm{accepted=true}` (пользователь нажал «Отмена», пока ждал Mac). Responder
читает соединение всё время привязки, отвечает `pairing_result{false}` и закрывает сессию.
`close` или обрыв во время привязки тоже немедленно завершают её.

Если то же устройство (тот же `deviceId`) подключается снова, пока его прошлая привязка не
завершена, Responder закрывает старую сессию и начинает привязку в новой — повтор с телефона
не должен упираться в `busy`.

После `pairing_result{accepted=true}` обе стороны сохраняют peer в trusted devices.
При `false` соединение закрывается.

### Неактивная сессия

После `session_status = trusted` или успешной привязки Responder ждёт следующее сообщение
не дольше `SESSION_IDLE_TIMEOUT = 120 s` и затем закрывает соединение.

## Передача

### `transfer_request` (Sender → Receiver, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | случайный идентификатор передачи |
| `files` | [FileInfo] | 1..1000 файлов |
| `totalSize` | uint | сумма `size` |

`FileInfo`:

| Ключ | Тип | Описание |
|------|-----|----------|
| `fileId` | uint | индекс файла в передаче, 0..n-1 |
| `name` | tstr | имя файла без пути (получатель обязан санитизировать) |
| `mimeType` | tstr | `application/octet-stream`, если неизвестен |
| `size` | uint | размер в байтах |
| `lastModified` | ?int | Unix time, мс |

### `transfer_add` (Sender → Receiver, Enc: yes)

Добавляет файлы к запросу, ожидающему решения: пользователь поделился ещё чем-то, пока на
получателе открыт запрос. Получатель показывает обновлённый список.

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `files` | [FileInfo] | 1..1000 файлов; `fileId` продолжают нумерацию запроса |
| `totalSize` | uint | новая сумма `size` всех файлов передачи |

Всего файлов в передаче — не больше 1000. Отправитель шлёт `transfer_add` только до того, как
прочитал решение. Получатель, уже ответивший на запрос, `transfer_add` игнорирует; файлы,
которые не поместятся на диск, тоже не включает. Какие файлы вошли в решение, говорит `fileCount`.

### `transfer_accept` (Receiver → Sender, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `fileCount` | ?uint | сколько первых файлов принято — те, что получатель видел при решении; отсутствует — все из `transfer_request` |

Может прийти сразу, без вопроса пользователю: получатель принял по политике этого устройства
(auto-accept). Отправитель передаёт только первые `fileCount` файлов; остальные, добавленные
слишком поздно, отправляет новой передачей.

### `transfer_reject` (Receiver → Sender, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `reason` | tstr | `declined` (пользователь или политика устройства), `busy`, `insufficient_storage`, `timeout`, `asleep` |
| `fileCount` | ?uint | к скольким первым файлам относится отказ (как в `transfer_accept`); отсутствует — ко всем из `transfer_request` |

`busy` и `asleep` — временные: отправитель сохраняет передачу и повторяет позже. `asleep`
отвечает спящий получатель: macOS в фоновых пробуждениях (крышка закрыта) принимает
соединения, но показать запрос некому, а приём оборвёт следующий сон. Запрос, ожидавший
решения в момент засыпания, тоже закрывается с `asleep`.

### `file_begin` (Sender → Receiver, Enc: yes) — FileMetadata

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `fileId` | uint | |
| `offset` | uint | v1: всегда 0 (зарезервировано под resume) |

### `file_chunk` (Sender → Receiver, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `fileId` | uint | |
| `offset` | uint | смещение первого байта `data` в файле |
| `data` | bstr | 1..`MAX_CHUNK_SIZE` байт |

Получатель проверяет, что `offset` равен количеству уже полученных байт файла,
и что сумма не превышает `size`.

### `file_end` (Sender → Receiver, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `fileId` | uint | |
| `sha256` | bstr(32) | хеш всего файла, посчитанный отправителем |

### `file_result` (Receiver → Sender, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `fileId` | uint | |
| `ok` | bool | хеш совпал и файл сохранён |
| `code` | ?tstr | код ошибки, если `ok=false` |

### `transfer_complete` (Sender → Receiver, Enc: yes)

`transferId`.

### `transfer_result` (Receiver → Sender, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `status` | tstr | `completed` / `failed` |
| `code` | ?tstr | код ошибки |

### `cancel` (любая сторона, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `reason` | tstr | `user_cancelled`, `source_unavailable`, ... |

### `text` (Sender → Receiver, Enc: yes)

Короткий текст (ссылка, фрагмент) для буфера обмена получателя. Отправляется, только если
получатель объявил `clipboardReceive` (protocol.md §2.6); иначе текст уходит обычной передачей
как файл `.txt`.

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | случайный идентификатор |
| `text` | tstr | 1..`MAX_TEXT_SIZE` байт UTF-8 |

`MAX_TEXT_SIZE = 262144`. Более длинный текст отправитель передаёт файлом.

### `text_result` (Receiver → Sender, Enc: yes)

| Ключ | Тип | Описание |
|------|-----|----------|
| `transferId` | bstr(16) | |
| `status` | tstr | `copied` — текст в буфере обмена; `declined` — политика получателя не принимает данные от этого устройства |

Получатель не спрашивает пользователя о тексте: он не пишется на диск, а отправка — явное
действие владельца доверенного устройства. Получатель никогда не открывает ссылку сам —
только по нажатию пользователя.

### Порядок и правила передачи

* В сессии одновременно идёт не больше одной передачи. Следующий `transfer_request` или `text`
  допустим после `transfer_result`, `transfer_reject` или `text_result`.
* Отправитель ждёт `file_result` после каждого `file_end` и только затем начинает следующий файл.
* После `transfer_accept` получатель может прислать `cancel` в любой момент, а при ошибке
  записи — `file_result{ok=false}` и `transfer_result{failed}` до `file_end`. Поэтому
  отправитель читает соединение параллельно с отправкой чанков.
* Пока получатель решает (Accept/Decline), отправитель может прислать `cancel` — получатель
  обязан его заметить и закрыть запрос.
* Получатель пишет файл во временный файл и даёт ему итоговое имя только после совпадения
  SHA-256. Файлы, уже подтверждённые `file_result{ok=true}`, остаются сохранёнными, даже если
  передача затем прервалась.
* Отказ по месту (`insufficient_storage`) получатель отправляет до запроса пользователю,
  сравнивая `totalSize` со свободным местом.

### `close` (любая сторона, Enc: yes)

Нормальное завершение сессии. Без полей.

## Ошибки

### `error` (любая сторона, Enc: yes; до установки ключей — no)

| Ключ | Тип | Описание |
|------|-----|----------|
| `code` | tstr | код из таблицы ниже |
| `message` | ?tstr | диагностический текст (для логов, не для UI) |
| `supported` | ?[uint] | только для `version_unsupported` |

После `error` отправитель закрывает соединение.

| `code` | Значение |
|--------|----------|
| `version_unsupported` | нет общей версии протокола |
| `bad_message` | неверный CBOR, неизвестный `t`, нарушение порядка или лимитов |
| `auth_failed` | подпись не прошла проверку / commit не совпал |
| `decrypt_failed` | ошибка AES-GCM (tag mismatch) |
| `pairing_rejected` | пользователь отклонил привязку |
| `pairing_timeout` | нет решения пользователя за `USER_DECISION_TIMEOUT` |
| `pairing_unavailable` | требуется привязка, но Responder не в режиме привязки |
| `not_trusted` | `transfer_request` до успешной привязки, или пользователь удалил устройство из trusted во время сессии |
| `busy` | у получателя уже идёт передача / привязка |
| `insufficient_storage` | недостаточно места |
| `write_failed` | запись запрещена / ошибка I/O на получателе |
| `checksum_mismatch` | SHA-256 не совпал |
| `source_unavailable` | отправитель не может прочитать исходный файл |
| `internal` | непредвиденная ошибка реализации |
