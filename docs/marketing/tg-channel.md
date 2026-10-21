# Telegram channel: name, description and first post

Everything here is written to be used as-is. Facts, links and hashes match the
`v0.1.0` release; when a new release is published, update the links and the hashes
together, because a post that says one thing while the download says another is how a
project loses the benefit of the doubt.

---

## Channel name

```
DarkFlow
```

## Username

```
@darkflow_msg
```

If that one is taken, `@darkflow_app` reads better than a string of digits: a channel
about an anonymity tool should not need a numbered handle.

## Description (the bio, 255 characters maximum)

```
Мессенджер на Tor без сервера: каждый аккаунт — свой onion-сервис, а его адрес и есть ник.
Windows и Android. Всё шифруется на устройстве. Звонков нет — они удалены, а не спрятаны.
```

That is 183 characters. It says the three things a person deciding whether to care needs:
what it is, where it runs, and one honest absence. It makes no promise about anonymity
that the project cannot keep.

### A shorter variant, if the full one feels crowded

```
P2P-мессенджер на Tor. Без сервера: аккаунт — это onion-адрес.
Windows и Android, шифрование на устройстве.
```

---

## First post

Attach `docs/marketing/banner-1280x640.png`.

```
DarkFlow 0.1.0 — мессенджер, у которого нет сервера.

Как это устроено: каждый аккаунт — отдельный onion-сервис в сети Tor. Ваш адрес — это
ваш ник. Нет сервера, который хранит переписку, нет базы пользователей, нет компании,
которой можно предъявить запрос. Сообщение идёт напрямую между двумя машинами или через
ретрансляцию у контактов, которым вы это разрешили.

Что внутри:
— Argon2id по паролю, Ed25519 для личности, X25519 для обмена. Всё на диске зашифровано,
  базы данных в открытом виде нет вообще.
— Tor встроен и управляется приложением. Мосты: obfs4, WebTunnel, Snowflake, meek,
  conjure — с проверкой строки моста до того, как её увидит демон.
— Переписка, вложения, голосовые, ответы, черновики, поиск по переписке.
— Шестизначный PIN к хранилищу ключей ОС.
— Диагностика: журнал Tor, состояние сети и лог событий — чтобы отказ можно было описать,
  а не угадывать.

Windows: github.com/EvGeNkA-PLUSsss/darkflow/releases/download/v0.1.0/darkflow-0.1.0-windows-x64.zip
Android (arm64), подписан:
github.com/EvGeNkA-PLUSsss/darkflow/releases/download/v0.1.0/darkflow-0.1.0-android-arm64.apk

Расшифровка больших ссылок — первым комментарием.

Чего нет, и я не буду делать вид, что есть:
— Звонков. Их нельзя провести через Tor без собственного медиарелея, и кнопка, которая
  иногда соединяет, хуже отсутствующей. Код удалён, а не отключён.
— iOS. App Store запрещает поставлять исполняемый Tor.
— Group chats и синхронизации между устройствами.
— Windows-сборка не подписана: SmartScreen предупредит. Это честное предупреждение, а не
  признак подделки, но проверить SHA-256 всё равно нужно.
— Проверки доставки между двумя живыми устройствами через Tor не было. Всё, что можно
  проверить тестами, проверено: 529 тестов, и каждое исправление проверено поломкой —
  ломаешь, тест падает. Но это не то же самое, что полевой тест.

Код открыт, AGPL-3.0: github.com/EvGeNkA-PLUSsss/darkflow
```

## The comment with the unwrapped links

Telegram clips long URLs inside a post, and a link cut in the middle looks like a broken
one. Post this as a reply to the announcement and pin it.

```
Ссылки целиком:

Релиз v0.1.0
https://github.com/EvGeNkA-PLUSsss/darkflow/releases/tag/v0.1.0

Windows x64 — zip, внутри exe и папка tor рядом
https://github.com/EvGeNkA-PLUSsss/darkflow/releases/download/v0.1.0/darkflow-0.1.0-windows-x64.zip

Android arm64 — apk, подписан
https://github.com/EvGeNkA-PLUSsss/darkflow/releases/download/v0.1.0/darkflow-0.1.0-android-arm64.apk

Контрольные суммы (сверяйте перед запуском):

SHA-256  darkflow-0.1.0-windows-x64.zip
A35D130B2E12DF1E820E425BF5A4BCA2FC871DBD171BB1B0FF219E3471FD1A06

SHA-256  darkflow-0.1.0-android-arm64.apk
4BFAE78B6D46A18F3648FC892065378CA97169F99C26B5548881D2834B560F30

На Windows: Get-FileHash <файл> -Algorithm SHA256
Сертификат подписи APK: C9:4A:E1:F1:1E:65:A2:E5:5F:53:42:E5:E9:95:FE:7C:03:6C:37:77:90:5A:31:74:BE:38:44:E6:39:0E:A7:15

Первый запуск: приложение создаёт onion-адрес, это занимает до минуты. Адрес — то, что вы
даёте собеседнику. Чтобы написать кому-то впервые, нужен один успешный рукопожатный обмен:
сообщение до него стоит в очереди с пометкой, пока этого обмена не было.
```

---

## Notes on tone

- **No "анонимность" as a slogan.** The project protects content and metadata as far as
  Tor and the design allow; a compromised device defeats it, and a global observer can
  see that two addresses talk. Saying so is what makes the rest believable.
- **The limitations are in the announcement, not in a footnote.** A privacy tool that
  hides its gaps teaches people to trust it more than they should.
- **One call to action.** Two links, both in the post and repeated in a comment; nothing
  else to click.
