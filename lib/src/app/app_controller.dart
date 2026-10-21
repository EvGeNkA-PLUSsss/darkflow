import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';import '../crypto/crypto_engine.dart';
import '../crypto/dart_crypto_engine.dart';
import '../crypto/key_vault.dart';
import '../crypto/onion_address.dart';
import '../data/bridge_presets.dart';
import '../data/file_vault.dart';
import '../data/models/account.dart';
import '../data/models/contact.dart';
import '../data/models/conversation.dart';
import '../data/models/message.dart';
import '../data/models/protected_file.dart';
import '../data/models/relay.dart';
import '../data/models/tor_settings.dart';
import '../data/vault_store.dart';
import '../mesh/file_transfer.dart';
import '../mesh/mesh_service.dart';
import '../net/peer_server.dart';
import '../net/peer_stream.dart';
import '../notifications/notification_service.dart';
import '../tor/tor_manager.dart';
import 'log_book.dart';

/// An attachment being reassembled from chunks that arrived out of order.
class _IncomingTransfer {
  _IncomingTransfer({required this.total});

  final int total;

  /// Chunk index to the chunk, so a retry cannot double-count a piece.
  final Map<int, ChunkPayload> parts = <int, ChunkPayload>{};

  String expectedDigest = '';
  ChunkPayload? meta;
}

/// Which screen the app should be showing.
enum AppStage {
  /// Reading the vault header.
  booting,

  /// No account exists yet: the sign-up flow runs.
  needsAccount,

  /// An account exists but the master key is not in memory.
  locked,

  /// The account was just created, and the user has not yet said how to reach
  /// the Tor network. Tor is not started here on purpose: a bootstrap that
  /// stalls on a censored network should be something the user chose to try.
  torSetup,

  /// An expensive operation is running (key derivation, account creation).
  busy,

  /// The vault is open and the app shell is usable.
  ready,

  /// Something unrecoverable happened; [AppController.failure] explains it.
  failure,
}

/// The settings that are not about Tor or relaying.
class AppSettings {
  const AppSettings({
    this.notificationsEnabled = true,
    this.lockOnBackground = true,
    this.relayPolicy = const RelayPolicy(),
    this.torSettings = const TorSettings(),
    this.localeCode = 'en',
    this.microphoneId,
    this.backgroundEnabled = false,
  });

  final bool notificationsEnabled;

  /// Whether the vault locks when the app loses focus. On by default: a
  /// messenger whose key stays in memory while the laptop is unattended is not
  /// actually protecting anything.
  final bool lockOnBackground;

  final RelayPolicy relayPolicy;
  final TorSettings torSettings;
  final String localeCode;

  /// The recording input device the user chose, or null for the system default.
  ///
  /// Stored rather than held in the recorder, because it is a preference about
  /// this machine: a headset chosen once should still be chosen after a restart,
  /// and re-picking it every session is the kind of small friction that makes a
  /// feature feel broken.
  final String? microphoneId;

  /// Whether DarkFlow used to keep its connection open while the app was in the background.
  ///
  /// ## Kept deliberately, and read by nothing
  ///
  /// This field configured an Android foreground service, and the service has been removed — the
  /// capability is gone rather than switched off, because a permanent notification and a resident
  /// process were not worth what they bought. Nothing reads this any more.
  ///
  /// It stays because settings records already on disk carry the key, and `fromJson` has to be able
  /// to read a record written by an earlier build. Dropping the field would not break anything —
  /// unknown keys are ignored — but a settings model whose shape matches the files in the field is
  /// easier to reason about than one that quietly discards part of them, and this costs one bool in
  /// a structure that is already written whole on every change.
  final bool backgroundEnabled;

  AppSettings copyWith({
    bool? notificationsEnabled,
    bool? lockOnBackground,
    RelayPolicy? relayPolicy,
    TorSettings? torSettings,
    String? localeCode,
    String? microphoneId,
    bool? backgroundEnabled,
    bool clearMicrophone = false,
  }) {
    return AppSettings(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      lockOnBackground: lockOnBackground ?? this.lockOnBackground,
      relayPolicy: relayPolicy ?? this.relayPolicy,
      torSettings: torSettings ?? this.torSettings,
      localeCode: localeCode ?? this.localeCode,
      microphoneId: clearMicrophone ? null : (microphoneId ?? this.microphoneId),
      backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': 'app',
        'notificationsEnabled': notificationsEnabled,
        'lockOnBackground': lockOnBackground,
        'relayPolicy': relayPolicy.toJson(),
        'torSettings': torSettings.toJson(),
        'localeCode': localeCode,
        'microphoneId': microphoneId,
        'backgroundEnabled': backgroundEnabled,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
        lockOnBackground: json['lockOnBackground'] as bool? ?? true,
        relayPolicy: json['relayPolicy'] == null
            ? const RelayPolicy()
            : RelayPolicy.fromJson(
                Map<String, dynamic>.from(json['relayPolicy'] as Map<dynamic, dynamic>),
              ),
        torSettings: json['torSettings'] == null
            ? const TorSettings()
            : TorSettings.fromJson(
                Map<String, dynamic>.from(json['torSettings'] as Map<dynamic, dynamic>),
              ),
        localeCode: json['localeCode'] as String? ?? 'en',
        microphoneId: json['microphoneId'] as String?,
        backgroundEnabled: json['backgroundEnabled'] as bool? ?? false,
      );
}

/// The root of DarkFlow's application layer.
///
/// It owns the services — crypto engine, encrypted store, file vault, Tor
/// manager, mesh, peer server — and exposes exactly the state and the actions
/// the screens need. Keeping every cross-service decision in one place is
/// deliberate: the ordering here (unlock the vault, then unlock the file vault,
/// then hand the identity to Tor, then start the mesh with the SOCKS port Tor
/// chose) is the part of the system that is easiest to get subtly wrong.
class AppController extends ChangeNotifier {
  /// [paths] overrides where the vault lives. The app never passes it — the
  /// platform's application-support directory is the only place a real vault may
  /// go — but an integration test that exercises the whole account layer needs to
  /// write into a temporary directory instead of the developer's own vault.
  AppController({CryptoEngine? engine, VaultPaths? paths})
      : _engine = engine ?? DartCryptoEngine(),
        // The field is assigned rather than declared as an initialising formal so
        // that callers write `paths:` instead of `_paths:`, matching `VaultStore`.
        // ignore: prefer_initializing_formals
        _paths = paths;

  final CryptoEngine _engine;

  /// True once [dispose] has run, so a late notification is dropped.
  ///
  /// Several operations are started with `unawaited` — unlocking kicks off
  /// `_startNetworking`, which finishes later — so a notification can be
  /// scheduled against a controller that no longer exists. That threw
  /// "A AppController was used after being disposed" out of `notifyListeners`,
  /// which in the app means a crash on lock-then-unlock, and in the test suite
  /// an intermittent failure that looks like flakiness and is not.
  bool _disposed = false;

  /// True once [dispose] has run.
  bool get isDisposed => _disposed;

  /// [notifyListeners] for code that may outlive the controller.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ---------------------------------------------------------- notifications

  /// The alert channel, set by the shell once the platform plugin is ready.
  ///
  /// Null until then, and null in tests. Everything that shows an alert goes through
  /// the null check, so a build without the plugin still delivers messages — it just
  /// does not announce them.
  NotificationService? _notifications;

  /// True while the application is the one the user is looking at.
  ///
  /// Starts true, because the first frame is on screen by definition. An alert for a
  /// message that arrives while the user is reading the conversation is noise, and
  /// this is what suppresses it.
  bool _foreground = true;

  bool get isForeground => _foreground;

  /// The conversation an alert was tapped for, waiting for the interface to act on
  /// it.
  ///
  /// A field rather than a navigation call: the controller does not own navigation,
  /// and a notification can be tapped while the vault is locked — in which case the
  /// request has to survive until the account is open.
  String? _pendingAlertConversation;

  String? get pendingAlertConversation => _pendingAlertConversation;

  /// Clears the pending request once the shell has navigated to it.
  void clearPendingAlert() {
    if (_pendingAlertConversation == null) return;
    _pendingAlertConversation = null;
    _notify();
  }

  /// Hands the controller the platform alert channel.
  void attachNotifications(NotificationService notifications) {
    _notifications = notifications;
  }

  /// Records whether the application is in front.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      // The user is here, so anything still on the lock screen is stale.
      unawaited(_notifications?.clearAll());
    }
  }

  /// Records that the user tapped an alert for [conversationKey].
  void openConversationFromAlert(String conversationKey) {
    if (conversationKey.isEmpty) return;
    _pendingAlertConversation = conversationKey;
    _notify();
  }

  /// Removes one conversation's alert from the platform's tray.
  Future<void> dismissAlert(String conversationKey) async {
    await _notifications?.clear(conversationKey);
  }

  /// Announces an arriving message, when it is worth announcing.
  ///
  /// The decision itself lives in [AlertPolicy], which has no plugin in it and is
  /// therefore testable; this method only gathers the facts that decision needs.
  Future<void> _announce(Message message, String fromOnion) async {
    final channel = _notifications;
    if (channel == null) return;

    final contact = _contacts[fromOnion];
    final conversation = _conversations[fromOnion];
    final attachment = _attachments[message.attachmentId];

    final alert = AlertPolicy.build(
      conversationKey: fromOnion,
      senderName: contact?.displayName ?? _nameFor(fromOnion),
      // A message whose text is empty falls back to what it is, so a caption-less
      // photo does not produce an empty notification.
      body: message.body,
      isImage: attachment?.isImage ?? message.kind == MessageKind.image,
      isVoice: attachment?.isVoice ?? message.kind == MessageKind.voice,
      isFile: message.kind == MessageKind.file ||
          (attachment != null && !attachment.isImage && !attachment.isVoice),
      globalEnabled: _settings.notificationsEnabled,
      // A conversation the user muted says so; a contact with no record yet — the
      // first message from someone new — is announced, because silence for a first
      // contact is the worse surprise.
      contactEnabled: conversation?.muted == true
          ? false
          : (contact?.notificationsEnabled ?? true),
      isForeground: _foreground,
    );
    if (alert == null) return;

    await channel.show(alert);
  }

  /// A display name for an address with no contact record, so a notification from
  /// someone new is not headed "unknown".
  String _nameFor(String onion) =>
      onion.length >= 8 ? '${onion.substring(0, 8)}…' : onion;

  VaultPaths? _paths;
  VaultStore? _store;
  FileVault? _fileVault;
  KeyVault? _keyVault;
  TorManager? _tor;
  MeshService? _mesh;
  PeerServer? _peerServer;
  StreamSubscription<MeshEvent>? _meshSubscription;
  StreamSubscription<String>? _torSubscription;

  VaultHeader? _header;
  MasterKeyRing? _ring;

  AppStage _stage = AppStage.booting;
  String? _failure;
  String? _statusMessage;

  Account? _account;
  AppSettings _settings = const AppSettings();
  int _localPeerPort = 0;

  final Map<String, Contact> _contacts = <String, Contact>{};
  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<Message>> _messages = <String, List<Message>>{};
  final Map<String, Attachment> _attachments = <String, Attachment>{};

  /// Transport presets shown on the bridge settings screen, read from the
  /// bundled asset during [bootstrap].
  List<BridgePreset> _bridgePresets = const <BridgePreset>[];

  // ------------------------------------------------------------------ state

  AppStage get stage => _stage;
  String? get failure => _failure;
  String? get statusMessage => _statusMessage;
  Account? get account => _account;
  AppSettings get settings => _settings;
  TorManager? get tor => _tor;
  MeshService? get mesh => _mesh;
  CryptoEngine get engine => _engine;
  VaultPaths? get paths => _paths;
  FileVault? get fileVault => _fileVault;
  int get localPeerPort => _localPeerPort;

  /// The encrypted record store, once [bootstrap] has opened the vault.
  ///
  /// Exposed because it is the app layer's own store and the screens that report
  /// on storage need to read it; a test also uses it to check that a delete
  /// actually reached the log rather than only the in-memory map.
  @visibleForTesting
  VaultStore? get store => _store;

  /// The bridge transports the user can choose from.
  List<BridgePreset> get bridgePresets => _bridgePresets;

  bool get isUnlocked => _ring != null;

  List<Contact> get contacts => _contacts.values.toList(growable: false);

  Contact? contactFor(String onion) => _contacts[onion];

  List<Conversation> get conversations {
    final list = _conversations.values.toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        final left = a.lastMessageAt ?? a.createdAt;
        final right = b.lastMessageAt ?? b.createdAt;
        return right.compareTo(left);
      });
    return list;
  }

  List<Message> messagesFor(String peerOnion) =>
      List<Message>.unmodifiable(_messages[peerOnion] ?? const <Message>[]);

  Attachment? attachmentFor(String? id) => id == null ? null : _attachments[id];

  // ------------------------------------------------------- protected files

  /// The user's own sealed files, newest first.
  ///
  /// Read from the in-memory map, which is filled when the vault opens. This is a
  /// different collection from attachments on purpose: an attachment belongs to a
  /// message, and the protected-files screen is about files that belong to nobody
  /// and are never sent.
  List<ProtectedFile> get protectedFiles {
    final files = _protected.values.toList(growable: false);
    files.sort((ProtectedFile a, ProtectedFile b) => b.addedAt.compareTo(a.addedAt));
    return files;
  }

  final Map<String, ProtectedFile> _protected = <String, ProtectedFile>{};

  /// The total size of the protected vault, for the header.
  int get protectedBytes =>
      _protected.values.fold(0, (int total, ProtectedFile file) => total + file.sizeBytes);

  /// Seals a file into the vault and records it.
  ///
  /// Returns null when there is nothing to seal or the vault is closed, so the
  /// caller can say so rather than appearing to succeed.
  Future<ProtectedFile?> protectFile(File source) async {
    final vault = _fileVault;
    final store = _store;
    if (vault == null || store == null || !store.isOpen) return null;
    if (!source.existsSync()) return null;

    final id = Ids.generate();
    final fileName = source.uri.pathSegments.isEmpty
        ? 'file'
        : source.uri.pathSegments.last;
    final digest = await vault.import(attachmentId: id, source: source);
    final file = ProtectedFile(
      id: id,
      fileName: fileName,
      mimeType: _mimeFor(fileName),
      sizeBytes: await source.length(),
      sha256Hex: digest,
      addedAt: DateTime.now().toUtc(),
    );
    _protected[id] = file;
    await store.put('protected', file.toJson());
    _notify();
    return file;
  }

  /// Removes a protected file, ciphertext and decrypted copy alike.
  ///
  /// Returns false when there was nothing to remove.
  Future<bool> unprotectFile(String id) async {
    final store = _store;
    final file = _protected[id];
    if (store == null || file == null) return false;

    // The ciphertext is addressed by the record's id and the decrypted copy is
    // named after the original file, so both have to be told: deleting only the
    // first leaves a readable copy of the file the user just deleted.
    await _fileVault?.delete(id, fileName: file.fileName);
    _protected.remove(id);
    await store.delete('protected', id);
    _notify();
    return true;
  }

  /// Records where a decrypted copy was saved, so the screen can say so.
  Future<void> rememberSavedCopy(String id, String path) async {
    final store = _store;
    final file = _protected[id];
    if (store == null || file == null) return;
    _protected[id] = file.copyWith(savedTo: path);
    await store.put('protected', _protected[id]!.toJson());
    _notify();
  }

  /// Writes a decrypted copy of a protected file to [target].
  ///
  /// This is the "save for good" action: `materialise` puts the plaintext in the
  /// cache, which is wiped on every lock, and this copies it somewhere the user
  /// chose where it survives.
  Future<File?> exportProtectedFile(String id, File target) async {
    final vault = _fileVault;
    final file = _protected[id];
    if (vault == null || file == null) return null;

    final materialised = await vault.materialise(
      attachmentId: file.id,
      fileName: file.fileName,
    );
    await target.parent.create(recursive: true);
    await materialised.copy(target.path);
    await rememberSavedCopy(id, target.path);
    return target;
  }

  /// Decrypts a protected file into the cache and returns it, for opening.
  Future<File?> materialiseProtected(String id) async {
    final vault = _fileVault;
    final file = _protected[id];
    if (vault == null || file == null) return null;
    return vault.materialise(attachmentId: file.id, fileName: file.fileName);
  }

  /// True when there is an open connection to the contact, so a message could be written now.
  ///
  /// Two earlier versions of this were wrong in opposite directions, and both produced a badge
  /// that lied.
  ///
  /// It began as "we hold their exchange key", which is true for ever after a single successful
  /// handshake — so every contact showed as Online from the moment they were first seen, however
  /// long ago that was.
  ///
  /// It then became the mesh's `isReachable`, which is a note of the last time the peer
  /// answered. That note is never cleared when the connection carrying those answers dies, so a
  /// contact whose circuit had been dropped — by a Tor restart, by the proxy port moving, or
  /// simply by the peer going away — still showed as Online while nothing could be sent. That is
  /// the "it just says online" half of the report.
  ///
  /// `hasLiveConnection` cannot drift: it is derived from the connection map, and a connection
  /// that has closed leaves it.
  bool canReach(String peerOnion) => _mesh?.hasLiveConnection(peerOnion) ?? false;

  // -------------------------------------------------------------- lifecycle

  /// Reads the vault from disk and decides which screen to show.
  Future<void> bootstrap() async {
    _setStage(AppStage.booting, message: 'Opening the encrypted store…');
    try {
      await _engine.initialise();
      final paths = _paths ?? await VaultPaths.resolve();
      await paths.ensureCreated();
      _paths = paths;

      // The log file lives beside the vault, and is attached before anything interesting
      // happens so a failure during start-up is recorded rather than missing.
      await logBook.attachTo(paths.root);
      logApp('bootstrap: vault at ${paths.root.path}');

      _store = VaultStore(paths: paths, engine: _engine);
      _fileVault = FileVault(engine: _engine, paths: paths);
      _keyVault = KeyVault(_engine);
      // Read early so the bridge screen has something to show even before an
      // account exists.
      _bridgePresets = await const BridgePresetStore().load();

      if (!await paths.headerFile.exists()) {
        _setStage(AppStage.needsAccount);
        return;
      }
      final raw = await paths.headerFile.readAsString();
      _header = VaultHeader.decode(raw);
      _setStage(AppStage.locked);
    } on Object catch (error) {
      _fail('Could not open the vault: $error');
    }
  }

  /// Creates the account: keys, onion address and the encrypted vault.
  ///
  /// The account password is the only secret involved, and the master key is
  /// wrapped exactly once with it. There is deliberately no shorter convenience
  /// secret alongside: the number of ways into this vault stays equal to the
  /// number of ways to learn the password.
  Future<void> createAccount({
    required String displayName,
    required String about,
    required String password,
  }) async {
    final paths = _paths;
    final vault = _keyVault;
    if (paths == null || vault == null) {
      _fail('The vault is not ready yet.');
      return;
    }
    _setStage(AppStage.busy, message: 'Deriving your key from the password…');
    try {
      // The directory may not exist at this point, and not only on a first run.
      //
      // `bootstrap` creates it, but the two-wrong-passwords wipe deletes the
      // whole tree — and the account that gets created immediately afterwards
      // would then write `vault.json` into a path that is gone, failing with
      // PathNotFoundException and showing the user "DarkFlow could not start"
      // on the very screen that was supposed to recover from the wipe.
      await paths.ensureCreated();

      final (header, ring) = await vault.create(password: password);

      // The onion-service key is generated by Tor itself; the account's
      // Ed25519 identity remains a separate signing key, whose public key is
      // authenticated in the first handshake. Tor's on-disk secret-key format
      // differs from the standard Ed25519 seed||public format, so writing our
      // own key files gave a Tor address that did not match the account key.
      final identity = await _engine.generateEd25519();
      final exchange = await _engine.generateX25519();

      final account = Account(
        id: Ids.generate(),
        displayName: displayName,
        about: about,
        // Replaced with Tor's authoritative hostname after the first startup.
        onionAddress: '',
        identityPublicKey: identity.publicKey,
        exchangePublicKey: exchange.publicKey,
        createdAt: DateTime.now().toUtc(),
      );

      // Atomic: this file holds the only copy of the wrapped master key, so a
      // crash part-way through a truncating write would destroy the account.
      await paths.writeFileAtomically(paths.headerFile, header.encode());

      _header = header;
      _ring = ring;
      _account = account;

      // `_store` is rebuilt by `bootstrap`, and the wipe path calls it back —
      // but a guard here costs nothing and turns a hard crash on the account
      // creation screen into a recoverable state.
      if (_store == null) await bootstrap();
      await _store!.open(ring);
      // The private halves are stored inside the encrypted vault, so an
      // attacker with the files still needs the password to become this user.
      await _persistSecret('identity.private', identity.privateKey);
      await _persistSecret('exchange.private', exchange.privateKey);
      await _store!.put('account', <String, dynamic>{...account.toJson(), 'id': account.id});
      await _persistSettings(_settings);

      // A brand-new account goes through the bridge step before it can try to
      // connect, so the first thing a user sees is not a stalled bootstrap.
      await _afterUnlock(offerTorSetup: true);
    } on Object catch (error) {
      _fail('Account creation failed: $error');
    }
  }

  /// Opens the vault with the account password.
  Future<void> unlockWithPassword(String password) async {
    final vault = _keyVault;
    final header = _header;
    if (vault == null || header == null) return;
    _setStage(AppStage.busy, message: 'Deriving your key from the password…');
    try {
      final ring = await vault.unlockWithPassword(header, password);
      _ring = ring;
      await _clearUnlockFailures();
      await _afterUnlock();
    } on WrongSecretException {
      await _registerUnlockFailure('That password did not open the vault.');
    } on Object catch (error) {
      _fail('Unlock failed: $error');
    }
  }

  /// How many wrong secrets destroy the vault.
  ///
  /// Two is deliberately harsh, and it is what the owner of this build asked
  /// for: the threat is someone who has the device and can guess, and a vault
  /// that self-destructs quickly is worth more to them than one that does not.
  /// The counter lives on disk so restarting the app cannot reset it — that
  /// would make the whole mechanism decorative.
  static const int _maxUnlockFailures = 2;

  /// Counts a wrong password and destroys the vault on the second.
  Future<void> _registerUnlockFailure(String message) async {
    final paths = _paths;
    if (paths == null) {
      _setStage(AppStage.locked, message: message);
      return;
    }

    final failures = await _readUnlockFailures(paths) + 1;
    if (failures < _maxUnlockFailures) {
      await _writeUnlockFailures(paths, failures);
      final left = _maxUnlockFailures - failures;
      _setStage(
        AppStage.locked,
        message: '$message One more wrong attempt erases everything on this '
            'device ($left left).',
      );
      return;
    }

    await _wipeEverything();
    _setStage(
      AppStage.needsAccount,
      message: 'Two wrong attempts. Every DarkFlow file on this device has '
          'been erased, and the account cannot be recovered.',
    );
  }

  /// Erases the vault and returns to account creation.
  ///
  /// The escape hatch for a forgotten password. There is no recovery by design —
  /// the password is the only thing that can unwrap the master key — so the
  /// honest offer is "start again", not "reset". The caller is expected to have
  /// confirmed first; this does not ask twice.
  Future<void> eraseAndStartOver() async {
    await _wipeEverything();
    _setStage(
      AppStage.needsAccount,
      message: 'The old account was erased on this device.',
    );
  }

  Future<int> _readUnlockFailures(VaultPaths paths) async {
    try {
      final file = File('${paths.root.path}${Platform.pathSeparator}unlock_failures');
      if (!await file.exists()) return 0;
      return int.tryParse((await file.readAsString()).trim()) ?? 0;
    } on Object {
      return 0;
    }
  }

  Future<void> _writeUnlockFailures(VaultPaths paths, int count) async {
    try {
      final file = File('${paths.root.path}${Platform.pathSeparator}unlock_failures');
      await file.writeAsString('$count', flush: true);
    } on Object {
      // If the counter cannot be written the wipe simply happens on the next
      // wrong attempt rather than never.
    }
  }

  Future<void> _clearUnlockFailures() async {
    final paths = _paths;
    if (paths == null) return;
    try {
      final file = File('${paths.root.path}${Platform.pathSeparator}unlock_failures');
      if (await file.exists()) await file.delete();
    } on Object {
      // A failed reset is not worth surfacing: the worst case is one fewer
      // attempt available than the user expects.
    }
  }

  /// Erases the vault, every record, every stored file and the onion keys.
  ///
  /// The order matters: the key material goes first, so a crash part-way
  /// through leaves an unreadable vault rather than a readable one with
  /// survivors elsewhere.
  Future<void> _wipeEverything() async {
    await _store?.close();
    _store = null;
    _ring = null;
    _header = null;
    _account = null;
    _contacts.clear();
    _conversations.clear();
    _messages.clear();

    final paths = _paths;
    if (paths == null) return;
    try {
      final root = paths.root;
      if (await root.exists()) await root.delete(recursive: true);
    } on Object {
      // Nothing more can be done from here; the stage change still tells the
      // user what happened.
    }
    // The tree comes back empty rather than absent.
    //
    // Leaving it deleted means every later write races against a missing
    // parent directory — which is exactly how account creation after a wipe
    // ended up reporting PathNotFoundException.
    try {
      await paths.ensureCreated();
    } on Object {
      // `createAccount` ensures it again before writing.
    }

    // And the controller is rebuilt to the state a fresh launch would produce.
    //
    // Deleting the files is only half of a wipe. The store, the file vault, the
    // key vault and the paths were all torn down above, and the account that
    // gets created next dereferences them — which is how a second bug appeared
    // in the same place: `Null check operator used on a null value`, from
    // `_store!.open`, on the very screen meant to recover from the wipe.
    // `bootstrap` rebuilds every one of them and lands on `needsAccount`.
    try {
      await bootstrap();
    } on Object {
      // If even that fails the stage is already somewhere the user can act on.
    }
  }

  /// Changes the account password and re-wraps the master key.
  Future<void> changePassword(String newPassword) async {
    final vault = _keyVault;
    final header = _header;
    final ring = _ring;
    final paths = _paths;
    if (vault == null || header == null || ring == null || paths == null) return;
    _setStage(AppStage.busy, message: 'Re-wrapping your master key…');
    try {
      final next = await vault.changePassword(
        header: header,
        ring: ring,
        newPassword: newPassword,
      );
      // Same reason as in `createAccount`: the header is the account's only key.
      await paths.writeFileAtomically(paths.headerFile, next.encode());
      _header = next;
      _setStage(AppStage.ready, message: 'Password changed.');
    } on Object catch (error) {
      _fail('Could not change the password: $error');
    }
  }

  /// The controller, kept so the shell can suspend the automatic lock.
  ///
  /// Set by UI code that is about to open a platform dialog — a file picker, a save
  /// dialog. Those take the application out of the foreground, and the lock-on-background
  /// setting then fires while the dialog is still on screen: on Android the picker is a
  /// separate activity, so the user is choosing a file in one window while DarkFlow locks
  /// itself in the other. The file they pick then cannot be encrypted, because the key is
  /// gone.
  ///
  /// A counter rather than a flag, because two dialogs can overlap — a save dialog opened
  /// from a screen that already had a picker in flight — and the first to close would
  /// otherwise re-arm the lock while the second is still up.
  int _lockSuspensions = 0;

  /// True while the automatic lock must not fire.
  bool get isAutoLockSuspended => _lockSuspensions > 0;

  /// Suspends the automatic lock, for the duration of a platform dialog.
  ///
  /// Every call must be paired with [releaseAutoLock]; the pair is what keeps the
  /// suspension from outliving the dialog and silently disabling the setting.
  void holdAutoLock() {
    _lockSuspensions++;
  }

  /// Re-arms the automatic lock. Safe to call more often than [holdAutoLock].
  void releaseAutoLock() {
    if (_lockSuspensions > 0) _lockSuspensions--;
  }

  /// Locks the vault and stops everything that holds key material.
  Future<void> lock() async {
    await _mesh?.stop();
    await _peerServer?.stop();
    await _tor?.stop();
    await _store?.close();
    _fileVault?.lock();
    _ring?.destroy();
    _ring = null;
    _account = null;
    _contacts.clear();
    _conversations.clear();
    _messages.clear();
    _attachments.clear();
    _mesh = null;
    _setStage(AppStage.locked, message: 'Locked.');
    // The screens are told last, after the stage has changed, so a listener that
    // navigates cannot land on a tree that still believes the account is open.
    onLocked?.call();
  }

  /// Called after the vault has locked, so the interface can return to the unlock
  /// screen.
  ///
  /// The controller does not pop routes itself — navigation is the shell's — but it is
  /// the only thing that knows a lock happened, and a lock performed *from* a pushed
  /// screen needs that screen to go away. Without this the root switched to the password
  /// screen underneath a route that was still on top, so pressing "Lock" appeared to do
  /// nothing at all.
  void Function()? onLocked;

  // -------------------------------------------------------------- internals

  /// Everything that has to happen once the master key is in memory.
  ///
  /// [offerTorSetup] routes a brand-new account through the bridge screen first;
  /// a returning user goes straight to the shell, where the connection screen
  /// waits for them to press Connect.
  Future<void> _afterUnlock({bool offerTorSetup = false}) async {
    final store = _store!;
    await store.open(_ring!);
    _fileVault!.unlock(_ring!);

    final accountRows = await store.readAll('account');
    if (accountRows.isEmpty) {
      // The vault header exists but there is no account inside it. That is
      // unrecoverable — the header only holds a wrapped master key, and the
      // account keys live in the encrypted store — so the message says what to
      // do rather than leaving the user at a dead screen.
      _fail(
        'The vault opened but contains no account. The account keys are missing, '
        'so this vault cannot be used. Deleting the DarkFlow data folder and '
        'creating a new account is the only way forward.',
      );
      return;
    }
    _account = Account.fromJson(accountRows.first);

    _settings = await _loadSettings();
    await _loadContacts();
    await _loadConversations();
    await _loadAttachments();
    await _loadProtectedFiles();

    if (offerTorSetup) {
      _setStage(AppStage.torSetup, message: 'Choose how to reach the Tor network.');
    } else {
      _setStage(AppStage.ready, message: 'Unlocked.');
    }
    unawaited(_startNetworking());
  }

  /// Finishes the first-run Tor step and reveals the connection screen.
  ///
  /// Tor is deliberately *not* started here: the next screen offers a Connect
  /// button, so the attempt is the user's decision.
  void completeTorSetup() {
    _setStage(AppStage.ready, message: 'Ready.');
  }

  Future<void> _loadContacts() async {
    _contacts.clear();
    for (final row in await _store!.readAll('contacts')) {
      final contact = Contact.fromJson(row);
      _contacts[contact.onionAddress] = contact;
    }
  }

  Future<void> _loadConversations() async {
    _conversations.clear();
    for (final row in await _store!.readAll('conversations')) {
      final conversation = Conversation.fromJson(row);
      _conversations[conversation.peerOnion] = conversation;
    }
  }

  Future<void> _loadAttachments() async {
    _attachments.clear();
    for (final row in await _store!.readAll('attachments')) {
      final attachment = Attachment.fromJson(row);
      _attachments[attachment.id] = attachment;
    }
  }

  /// Loads the user's own sealed files.
  ///
  /// A separate collection from attachments, and loaded separately, because a
  /// protected file has no message and no conversation: filing it with attachments
  /// would make it appear in whichever chat happened to share its identifier, and
  /// would make the vault screen list every attachment in the account.
  Future<void> _loadProtectedFiles() async {
    _protected.clear();
    for (final row in await _store!.readAll('protected')) {
      final file = ProtectedFile.fromJson(row);
      if (file.id.isEmpty) continue;
      _protected[file.id] = file;
    }
  }

  /// Loads the message history of one conversation, on demand.
  Future<void> loadMessages(String peerOnion) async {
    final store = _store;
    if (store == null) return;
    final rows = await store.readAll('messages');
    final list = rows
        .map(Message.fromJson)
        .where((message) => message.peerOnion == peerOnion && !message.isDraft)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _messages[peerOnion] = list;
    _notify();
  }

  /// Starts the peer server, then Tor, then the mesh — in that order, because
  /// Tor has to know the local port to forward the onion service to, and the
  /// mesh has to know the SOCKS port Tor chose.
  Future<void> _startNetworking() async {
    final paths = _paths;
    final account = _account;
    if (paths == null || account == null) return;

    try {
      _peerServer ??= PeerServer(onConnection: _onInboundConnection);
      _localPeerPort = await _peerServer!.start();

      final identityPrivate = await _readSecret('identity.private');
      final exchangePrivate = await _readSecret('exchange.private');
      if (identityPrivate == null || exchangePrivate == null) {
        _fail('The account keys are missing from the vault.');
        return;
      }

      _tor ??= TorManager(
        rootDirectory: paths.root,
        // The peer server owns the loopback port; Tor forwards the onion
        // service to it. Passing it in means the two cannot drift apart.
        serviceTargetPort: _localPeerPort,
      );
      if (_torSubscription == null) {
        _torSubscription = _tor!.logStream.listen((line) {
          // Kept out of the UI for now; the connection screen reads status.
          debugPrint('tor: $line');
        });
        _tor!.addListener(_onTorChanged);
      }

      // Tor is deliberately not started here.
      //
      // There is exactly one way to launch the daemon: the Connect button on
      // the connection screen. Auto-starting meant a user on a censored network
      // watched a bootstrap stall at 10% before they had any chance to
      // configure a bridge, and a stall should be something they chose to try.
      // The manager is created and wired up, which is all that is needed for
      // the screen to offer the attempt.

      _mesh ??= MeshService(engine: _engine, storageDirectory: paths.root);

      // The event subscription is what connects the mesh to the contact list: `MeshPeerLearned`
      // becomes `_rememberPeer`, which writes the contact, its conversation and its name. Installed
      // before the mesh is started, so no event can be emitted into nothing.
      _meshSubscription ??= _mesh!.events.listen(_onMeshEvent);

      await _publishAddressAndConfigureMesh();

      // Contacts the mesh already has a key for are re-registered, and the ones it does
      // not are dialled. Split out because it has to happen in *two* places: here, and
      // again each time the mesh is configured — which is a moment later than this, since
      // Tor has not published its hostname yet. Running it only here meant a contact added
      // before Tor finished connecting was never dialled at all.
      _reconcileContactsWithMesh();

      _mesh!.start();
      _notify();
    } on Object catch (error) {
      _failure = 'Networking could not start: $error';
      _notify();
    }
  }

  void _onTorChanged() {
    // Never left to fail silently. This runs from a `ChangeNotifier` listener, so an exception
    // thrown here — or inside the future it starts — has nowhere to propagate to: it becomes an
    // unhandled asynchronous error rather than anything a caller can catch. Recording it is the
    // only way it is ever seen.
    unawaited(_publishAddressAndConfigureMesh().catchError((Object error, StackTrace stack) {
      logError('could not reconfigure the mesh after a Tor status change', detail: '$error\n$stack');
    }));
    _notify();
  }

  /// Adopts Tor's published hostname as the account's onion address, then
  /// points the mesh at the SOCKS port Tor chose.
  ///
  /// The address is adopted rather than derived because Tor owns the
  /// hidden-service key: its on-disk secret-key layout is not the standard
  /// Ed25519 `seed || publicKey`, so a key we generate produces an address Tor
  /// will not agree with. Reading the hostname back is the only way to know the
  /// address a peer can actually reach — see the note in `TorManager`.
  ///
  /// Until the address exists there is nothing to advertise, so the mesh is left
  /// unconfigured and this runs again on the next Tor status change.
  Future<void> _publishAddressAndConfigureMesh() async {
    final paths = _paths;
    final account = _account;
    final mesh = _mesh;
    final tor = _tor;
    if (paths == null || account == null || mesh == null || tor == null) return;

    // The vault can be closed while this is running, and during a lock it always is.
    //
    // `_onTorChanged` fires on every Tor status change, and locking the vault stops the daemon —
    // so this method is reached with `_store` closed and the secrets gone. Reading them then
    // throws out of an `unawaited` call, which is an unhandled asynchronous error: it does not
    // fail a future anybody awaits, it reaches the zone and shows up as "unhandled exception"
    // with a stack that names none of the code involved. Worse, the mesh would then be
    // reconfigured from a half-torn-down vault.
    final store = _store;
    if (store == null || !store.isOpen) {
      logApp('mesh not reconfigured: the vault is closed');
      return;
    }

    final published = tor.status.onionAddress;
    if (published != null && published.isNotEmpty && published != account.onionAddress) {
      final updated = account.copyWith(onionAddress: published, addressVerified: true);
      _account = updated;
      await _store?.put('account', updated.toJson());
      _notify();
    }

    final address = _account?.onionAddress;
    final socksPort = tor.status.socksPort;
    if (address == null || address.isEmpty || socksPort == null) return;

    // The one place the mesh is configured, used by the application and by a test alike.
    //
    // It used to be written out here, and a test that wanted a configured mesh had to reproduce it
    // — which is how a debug helper comes to disagree with the code it stands in for. Sharing the
    // body means a test cannot configure a mesh differently from the application, and there is
    // nothing to keep in step.
    mesh.configure(
      identity: await _meshIdentity(),
      socksHost: '127.0.0.1',
      socksPort: socksPort,
      remotePort: _settings.torSettings.virtualPort,
      policy: _settings.relayPolicy,
    );

    // The network is up, so anything recorded while it was not is now misleading.
    // See `_clearHandshakeFailures`.
    _clearHandshakeFailures();

    // And this is the first moment a dial is possible at all, so it is where the
    // handshakes that could not be attempted earlier are attempted. A contact added
    // before Tor connected is the ordinary case, not an edge case: the address is typed
    // from a code the user is looking at, and Tor takes a minute or more to bootstrap.
    _reconcileContactsWithMesh();
  }

  /// The account's identity, as the mesh needs it, read from the vault.
  ///
  /// Throws when the keys are not there: every caller has already established that the account is
  /// open, so a missing key is a programming error rather than a condition to branch on.
  Future<MeshIdentity> _meshIdentity() async {
    final account = _account;
    if (account == null) {
      throw StateError('the account is not open');
    }
    final identityPrivate = await _readSecret('identity.private');
    final exchangePrivate = await _readSecret('exchange.private');
    if (identityPrivate == null || exchangePrivate == null) {
      throw StateError('the account keys are missing from the vault');
    }
    return MeshIdentity(
      onionAddress: account.onionAddress,
      identityPrivateKey: identityPrivate,
      identityPublicKey: account.identityPublicKey,
      exchangePrivateKey: exchangePrivate,
      exchangePublicKey: account.exchangePublicKey,
      displayName: account.displayName,
      about: account.about,
    );
  }

  /// Brings the mesh in step with the contact list: keys it already holds, and dials
  /// for the ones it does not.
  ///
  /// Safe to call repeatedly, and called from both places where the mesh can become
  /// usable — after unlock and after configuration. An already-known contact is
  /// re-registered and its queued messages flushed; a contact with no key is dialled,
  /// which is the only thing that can produce one.
  void _reconcileContactsWithMesh() {
    final mesh = _mesh;
    if (mesh == null || !mesh.isConfigured) return;

    for (final contact in _contacts.values) {
      if (contact.trust == ContactTrust.keyChanged) {
        // A contact whose identity key changed must not be dialled at all: the handshake
        // itself would hand the mesh a key for an address we can no longer trust, and the
        // queued messages would go out sealed to it.
        continue;
      }
      if (contact.exchangePublicKey != null) {
        mesh.rememberPeer(
          onionAddress: contact.onionAddress,
          exchangePublicKey: contact.exchangePublicKey,
          displayName: contact.displayName,
        );
        // A message left queued by a previous session becomes sendable the moment the mesh
        // knows the key again. `rememberPeer` is the local call, not the `MeshPeerLearned`
        // event, so the flush that hangs off the event does not cover this path.
        unawaited(_flushQueued(contact.onionAddress));
      } else {
        // No key yet: this contact has never been reached, and dialling is the only thing
        // that can change that. Registered with the mesh rather than dialled once here,
        // because one attempt is not enough — see `MeshService.tick`.
        mesh.expectHandshake(contact.onionAddress);
        unawaited(mesh.warmUp(contact.onionAddress));
      }
    }
  }

  Future<void> _onInboundConnection(PeerStream stream) async {
    final mesh = _mesh;
    if (mesh == null) {
      stream.destroy();
      return;
    }
    await mesh.handleInbound(stream);
  }

  void _onMeshEvent(MeshEvent event) {
    switch (event) {
      case MeshMessageReceived(:final message, :final attachment, :final peerOnion):
        unawaited(_storeIncoming(message, attachment, peerOnion));
      case MeshReceiptReceived(:final messageIds, :final read, :final at):
        unawaited(_applyReceipts(messageIds, read, at));
      case MeshAttachmentChunk(:final fromOnion, :final payload):
        unawaited(_storeAttachmentChunk(fromOnion, payload));
      case MeshPeerLearned(
          :final onionAddress,
          :final identityPublicKey,
          :final exchangePublicKey,
          :final displayName,
          :final capabilities
        ):
        unawaited(_rememberPeer(
          onionAddress,
          identityPublicKey,
          exchangePublicKey,
          displayName,
          capabilities,
        ));
      case MeshDeliveryChanged(:final messageId, :final status, :final failureReason):
        if (messageId.isNotEmpty) unawaited(_applyStatus(messageId, status, failureReason));
      case MeshHandshakeFailed(:final onionAddress, :final reason):
        _recordHandshakeFailure(onionAddress, reason);
      case MeshHandshakeStarted(:final onionAddress):
        _noteHandshakeStarted(onionAddress);
    }
  }

  /// Contacts a dial is currently in progress for.
  ///
  /// Separate from the failure map because the two mean different things and need different
  /// words. "Trying now" is not a failure, and while a Tor circuit to an unresponsive peer
  /// can take ninety seconds, saying nothing for that long is what makes the application
  /// look broken. The entry is written when the dial starts and removed when it settles, so
  /// what it contains is true at the moment it is read.
  final Set<String> _handshakeInProgress = <String>{};

  /// True when a dial to [onionAddress] is under way right now.
  bool isHandshaking(String onionAddress) => _handshakeInProgress.contains(onionAddress);

  /// Every contact a dial is currently in progress for.
  Set<String> get handshakesInProgress => Set<String>.unmodifiable(_handshakeInProgress);

  void _noteHandshakeStarted(String onionAddress) {
    if (onionAddress.isEmpty) return;
    // A newer attempt supersedes the recorded failure of the previous one: the reason a
    // message is waiting is that we are trying, not that we tried and failed a minute ago.
    _handshakeFailures.remove(onionAddress);
    if (_handshakeInProgress.add(onionAddress)) _notify();
  }

  /// The last handshake failure per contact, for the send path to explain itself with.
  ///
  /// Kept so a message waiting on a handshake can say *why* it is waiting. Before this
  /// the reason was thrown away by `warmUp`, and a queued message said "waiting for the
  /// first handshake" whether the peer was offline, the circuit was too slow, or every
  /// attempt had failed — three different problems with three different remedies,
  /// presented as one.
  final Map<String, String> _handshakeFailures = <String, String>{};

  /// Why the last attempt to reach [onionAddress] failed, or null when none has.
  String? handshakeFailureFor(String onionAddress) => _handshakeFailures[onionAddress];

  /// Every recorded handshake failure, for the diagnostics report.
  Map<String, String> get handshakeFailures => Map<String, String>.unmodifiable(_handshakeFailures);

  /// Contacts the mesh is still trying to reach, for the diagnostics report.
  ///
  /// Read from the mesh rather than recomputed here: the retry set is what the pump
  /// actually dials, so a report built from anything else could disagree with the
  /// behaviour it is meant to describe.
  Set<String> get pendingHandshakes =>
      _mesh?.pendingHandshakes ?? const <String>{};

  /// Contacts the mesh holds an exchange key for.
  Set<String> get establishedPeers => _mesh?.establishedPeers ?? const <String>{};

  /// Records a handshake failure, as the mesh does when a dial fails.
  @visibleForTesting
  void debugRecordHandshakeFailure(String onionAddress, String reason) =>
      _recordHandshakeFailure(onionAddress, reason);

  /// Brings the mesh in step with the contact list, as the network coming up does.
  @visibleForTesting
  Future<void> debugReconcileContacts() async => _reconcileContactsWithMesh();

  /// Records what a handshake revealed, as the mesh does when a peer is learned.
  ///
  /// Exposed because this is the receiving side of a first contact and the place a whole class of
  /// "the contact never appeared" behaviour lives: it is called from a private event handler, so
  /// without this the path can only be exercised by a real handshake over a real network.
  @visibleForTesting
  Future<void> debugRememberPeer({
    required String onionAddress,
    required Uint8List exchangePublicKey,
    Uint8List? identityPublicKey,
    String displayName = '',
    Map<String, dynamic> capabilities = const <String, dynamic>{},
  }) =>
      _rememberPeer(
        onionAddress,
        identityPublicKey ?? Uint8List(32),
        exchangePublicKey,
        displayName,
        capabilities,
      );

  /// The mesh the account layer owns, or null before networking starts.
  ///
  /// Exposed so a test can hand a real inbound connection to the *controller's* mesh. A test that
  /// built its own `MeshService` and asserted on the controller would be testing a different
  /// object: the wiring between the mesh's events and the contact list, which is where the
  /// reported faults lived, would not be exercised at all.
  @visibleForTesting
  MeshService? get debugMeshForTest => _mesh;

  /// Puts an attachment in the in-memory map, as opening the vault would.
  ///
  /// The map is filled from the vault, which needs an account and an unlocked store — neither of which
  /// a test of the *playback path* should have to build. That path needs one thing from the account
  /// layer, an attachment that exists, and this is how it gets one.
  @visibleForTesting
  void debugRememberAttachment(Attachment attachment) {
    _attachments[attachment.id] = attachment;
  }

  /// Puts a message in a conversation, as receiving one would.
  ///
  /// Messages normally arrive through the mesh or the store, and both need a peer that answers. A test of
  /// what a conversation *draws* needs the list to contain one thing, and nothing more.
  @visibleForTesting
  void debugAddMessage({
    required String conversationId,
    required String body,
    String? attachmentId,
    bool outgoing = false,
  }) {
    // Looked up by peer, because that is how the map is keyed — a conversation is identified by who it is
    // with, and looking it up by its own id found nothing.
    final conversation = _conversations.values
        .where((Conversation row) => row.id == conversationId)
        .firstOrNull;
    if (conversation == null) {
      throw StateError('there is no conversation "$conversationId"');
    }
    _insertMessage(
      conversation.peerOnion,
      Message(
        id: 'debug-${_messages[conversation.peerOnion]?.length ?? 0}-$conversationId',
        conversationId: conversationId,
        peerOnion: conversation.peerOnion,
        direction: outgoing ? MessageDirection.outgoing : MessageDirection.incoming,
        kind: attachmentId == null ? MessageKind.text : MessageKind.voice,
        createdAt: DateTime.now().toUtc(),
        body: body,
        attachmentId: attachmentId,
        status: MessageStatus.delivered,
      ),
    );
    _notify();
  }

  /// Configures the account layer's mesh by hand, standing in for a running Tor daemon.
  ///
  /// `_startNetworking` takes its SOCKS port from Tor's status, which a test has no way to
  /// produce, so this is how a test reaches a configured mesh. It configures the mesh the
  /// application owns, with the account's own keys, and shares [_meshIdentity] with the real path
  /// — so a handshake through it runs the code the application runs.
  @visibleForTesting
  Future<void> debugConfigureMesh({
    required String socksHost,
    required int socksPort,
    int remotePort = 80,
  }) async {
    final mesh = _mesh;
    if (mesh == null) {
      throw StateError('the mesh is not created; call debugCreateMesh first');
    }
    mesh.configure(
      identity: await _meshIdentity(),
      socksHost: socksHost,
      socksPort: socksPort,
      remotePort: remotePort,
    );
  }

  /// Creates the mesh the account layer will use, without starting Tor.
  ///
  /// The event subscription is installed as well, because that is what connects the mesh to the
  /// contact list — `MeshPeerLearned` becomes `_rememberPeer`, which is where a contact, its
  /// conversation and its name are written. A mesh created without it emits events into nothing,
  /// and a test built on one would be testing an object the application never uses.
  @visibleForTesting
  MeshService debugCreateMesh() {
    final mesh = _mesh ??= MeshService(engine: _engine, storageDirectory: _paths!.root);
    _meshSubscription ??= mesh.events.listen(_onMeshEvent);
    return mesh;
  }

  void _recordHandshakeFailure(String onionAddress, String reason) {
    if (onionAddress.isEmpty) return;
    final trimmed = reason.trim();
    _handshakeFailures[onionAddress] = trimmed.isEmpty ? 'no route' : trimmed;
    // The dial is over, one way or the other. Leaving it in the progress set would keep the
    // interface saying "trying" about an attempt that has already failed.
    _handshakeInProgress.remove(onionAddress);
    _notify();
  }

  /// Forgets every recorded handshake failure.
  ///
  /// Called once the network is up. The failures recorded before Tor finished connecting
  /// describe the application's own start-up order rather than the peers, and keeping
  /// them meant a contact whose handshake later succeeded still explained itself with
  /// "the mesh has not been configured with an identity" — an error the user could do
  /// nothing about and that had stopped being true minutes earlier.
  void _clearHandshakeFailures() {
    if (_handshakeFailures.isEmpty) return;
    _handshakeFailures.clear();
    _notify();
  }

  Future<void> _storeIncoming(
    Message message,
    Attachment? attachment,
    String fromOnion,
  ) async {
    // The envelope's origin is authoritative; the message's own copy of it is a
    // convenience. An empty origin cannot be filed anywhere, and a message
    // arriving without one would otherwise be dropped in silence.
    final peerOnion = fromOnion.isNotEmpty ? fromOnion : message.peerOnion;
    if (peerOnion.isEmpty) return;

    final stored = message.copyWith(
      status: MessageStatus.delivered,
      attachmentId: attachment?.id,
      clearAttachmentId: attachment == null,
    );
    _insertMessage(peerOnion, stored);
    await _store!.put('messages', stored.toJson());

    if (attachment != null) {
      // Storage first, as everywhere. The message above already refers to this attachment id, so
      // an attachment that is in memory and not on disk is a bubble that draws a placeholder for
      // ever — the bytes are sealed in the file vault under an id no record mentions.
      await _store!.put('attachments', attachment.toJson());
      _attachments[attachment.id] = attachment;
    }
    await _touchConversation(peerOnion, stored, incrementUnread: true);

    // Told after the message is stored, so an alert that the user taps always leads
    // to a conversation that already contains the message.
    unawaited(_announce(stored, peerOnion));

    // Tell the sender it landed. Nothing used to send this, so an outgoing
    // message could reach `sent` — "a relay is holding it" — and go no further,
    // however long the recipient had been reading it. The receipt is what turns
    // the single tick into a double one, and `markRead` sends the second.
    unawaited(_mesh?.sendReceipt(
          peerOnion: peerOnion,
          messageIds: <String>[stored.id],
          read: false,
        ) ??
        Future<void>.value());

    _notify();
  }

  /// Chunks of a partly received attachment, keyed by attachment id.
  ///
  /// In memory only, and deliberately: a half-received voice note has no meaning
  /// on disk, and the sender retries the whole transfer, so there is nothing worth
  /// persisting. The map is dropped when the vault locks.
  final Map<String, _IncomingTransfer> _incoming = <String, _IncomingTransfer>{};

  /// Collects one chunk, and stores the attachment once the last one arrives.
  ///
  /// A chunk carries the sender's digest for the *whole* file, so the reassembled
  /// bytes are checked before anything is written: a relay that tampered with the
  /// transfer cannot produce content that hashes to what the sender recorded.
  Future<void> _storeAttachmentChunk(String fromOnion, ChunkPayload chunk) async {
    final vault = _fileVault;
    final store = _store;
    if (vault == null || store == null || !store.isOpen) return;
    if (chunk.total <= 0 || chunk.index < 0 || chunk.index >= chunk.total) return;

    final transfer = _incoming.putIfAbsent(
      chunk.attachmentId,
      () => _IncomingTransfer(total: chunk.total),
    );
    // A repeated chunk — from a retry, or from two relays carrying the same
    // envelope — must not be counted twice, or the assembly would grow past the
    // sender's digest and fail verification for the wrong reason.
    transfer.parts[chunk.index] = chunk;
    transfer.expectedDigest = chunk.sha256Hex;
    transfer.meta = chunk;

    if (transfer.parts.length < transfer.total) return;
    _incoming.remove(chunk.attachmentId);

    final bytes = <int>[];
    for (var index = 0; index < transfer.total; index++) {
      final part = transfer.parts[index];
      if (part == null) {
        // A hole. The sender retries the transfer as a whole, so this is dropped
        // rather than stored short: a truncated voice note that looks complete is
        // worse than one that says it has not arrived.
        return;
      }
      // `mesh` hands over the chunk's *plaintext*: the transport layer already
      // decrypted and authenticated it.
      bytes.addAll(part.plaintext);
    }

    final mismatch = FileTransfer.verifyDigest(
      Uint8List.fromList(bytes),
      transfer.expectedDigest,
    );
    if (mismatch != null) {
      // Nothing is stored. A file that does not match what the sender recorded is
      // not a file the user should ever be shown.
      return;
    }

    final meta = transfer.meta!;
    try {
      // Re-imported rather than copied: `importBytes` re-seals the bytes under
      // this device's own key and returns the digest. The plaintext is identical
      // to what the sender hashed, so the stored record and the sender's digest
      // agree — which is the point of checking it a moment ago.
      await vault.importBytes(attachmentId: chunk.attachmentId, bytes: bytes);
    } on Object {
      return;
    }

    // The record the message pointed at is replaced with one that knows the bytes
    // are here, which is what makes the note playable.
    final existing = _attachments[chunk.attachmentId];
    final received = Attachment(
      id: chunk.attachmentId,
      messageId: meta.messageId ?? existing?.messageId,
      fileName: meta.fileName,
      mimeType: meta.mimeType,
      sizeBytes: meta.sizeBytes == 0 ? bytes.length : meta.sizeBytes,
      sha256Hex: meta.sha256Hex,
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
      localPath: existing?.localPath,
      durationMs: existing?.durationMs,
      waveform: existing?.waveform ?? const <int>[],
      width: existing?.width,
      height: existing?.height,
      transferProgress: 1,
      transferComplete: true,
    );
    _attachments[chunk.attachmentId] = received;
    await store.put('attachments', received.toJson());
    // The bubble has to be redrawn *and* the interface's cached decrypted preview
    // dropped: a photo that had no bytes a moment ago now has them, and a
    // remembered "cannot be read" would keep it a grey box for ever.
    _attachmentRevision++;
    _notify();
  }

  /// Moves an attachment's bytes to [peerOnion], after the message that names it.
  ///
  /// Fired immediately after the message envelope and not awaited by the caller:
  /// the message is what makes the bubble appear on both sides, and a transfer is
  /// slower. Failing here is not silent — the recipient keeps a note it cannot
  /// play, and the sender's attempt is recorded in `lastFailure` — but it must not
  /// make a successful message look like a failed one.
  Future<void> _sendAttachmentBytes(String peerOnion, Attachment? attachment) async {
    final mesh = _mesh;
    final vault = _fileVault;
    if (mesh == null || vault == null || attachment == null) return;
    if (!vault.isUnlocked) return;

    try {
      final bytes = await vault.readPlaintext(attachment.id);
      await mesh.sendAttachment(
        peerOnion: peerOnion,
        attachment: attachment,
        bytes: bytes,
      );
    } on Object catch (error) {
      _appendTransferFailure(attachment.id, '$error');
    }
  }

  /// Bumped whenever an attachment gains or loses its bytes.
  ///
  /// The interface listens to this to drop its cached decrypted previews. It is a
  /// counter rather than a stream because it carries no information: the only
  /// useful message is "what you cached about an attachment may be wrong now".
  int get attachmentRevision => _attachmentRevision;
  int _attachmentRevision = 0;

  /// The most recent transfer failures, for the diagnostic report.
  ///
  /// Kept in memory and small: a transfer either succeeds within a session or is
  /// retried when the message is, and a growing log of network errors is exactly
  /// what a diagnostic report should not become.
  final List<String> _transferFailures = <String>[];

  List<String> get transferFailures => List<String>.unmodifiable(_transferFailures);

  void _appendTransferFailure(String attachmentId, String reason) {
    _transferFailures.add('$attachmentId: $reason');
    if (_transferFailures.length > 20) _transferFailures.removeAt(0);
    _notify();
  }

  /// Adds [message] to its thread in chronological order.  ///
  /// Appending was the obvious thing and it is wrong: an envelope can arrive
  /// after a newer one, and each peer stamps its own clock, so the thread on
  /// screen could show a reply above the message it answered. The list is
  /// ordered, so a new entry goes where it belongs.
  void _insertMessage(String peerOnion, Message message) {
    final list = _messages.putIfAbsent(peerOnion, () => <Message>[]);

    // A message that is already here is not inserted again.
    //
    // This is not merely cosmetic. The outbox retries, and a peer acknowledges late,
    // so the same message legitimately arrives more than once — and inserting a
    // second copy put two bubbles with the same id in the thread. Everything
    // addressed by message id then became ambiguous: a receipt marked one copy
    // delivered and left the other on a single tick, so a delivered message sat there
    // looking undelivered for ever.
    final existing = list.indexWhere((Message candidate) => candidate.id == message.id);
    if (existing >= 0) {
      // Kept, not replaced: the copy already here carries the local state the
      // duplicate does not — how far its status has advanced — and the arriving copy
      // is just as likely to be the stale one.
      return;
    }

    final at = list.indexWhere((existing) => existing.createdAt.isAfter(message.createdAt));
    if (at < 0) {
      list.add(message);
    } else {
      list.insert(at, message);
    }
  }

  /// The live thread that holds [messageId], or null.
  List<Message>? _threadOf(String messageId) {
    for (final list in _messages.values) {
      if (list.any((message) => message.id == messageId)) return list;
    }
    return null;
  }

  Future<void> _applyReceipts(List<String> ids, bool read, DateTime at) async {
    // A Set, because this is a membership test inside a loop over every message
    // in every thread.
    final wanted = ids.toSet();
    var changed = false;
    for (final list in _messages.values) {
      for (var i = 0; i < list.length; i++) {
        if (!wanted.contains(list[i].id)) continue;
        final status = read ? MessageStatus.read : MessageStatus.delivered;
        // Monotonic, like `_applyStatus`: a late "delivered" must not undo a
        // "read" that arrived first.
        if (list[i].status.rank >= status.rank) continue;
        list[i] = list[i].copyWith(
          status: status,
          deliveredAt: read ? list[i].deliveredAt : at,
          readAt: read ? at : list[i].readAt,
          clearFailureReason: true,
        );
        await _store!.put('messages', list[i].toJson());
        changed = true;
      }
    }
    if (changed) _notify();
  }


  /// Records a delivery state reported by the mesh.
  ///
  /// Two things here are deliberate.
  ///
  /// **Status only moves forward.** Delivery runs concurrently with sending: the
  /// mesh reports its outcome from a callback, so `delivered` can land *before*
  /// the `sending` write that follows the send call. The old code wrote whatever
  /// it was handed, so a message that had already been delivered was pushed back
  /// to `sending` and stayed showing an upward arrow for ever, while the outbox —
  /// which had already handed the envelope over — never said anything again. The
  /// same ordering made a delivered message keep its "No route yet" note.
  ///
  /// **A success clears the explanation.** `failureReason` used to be impossible
  /// to unset, because no `copyWith` can distinguish "not provided" from "null".
  ///
  /// The explanation is applied even when the status does not move, which is what
  /// makes "still queued, and here is why" expressible: the mesh reports
  /// `queued` with a reason when it has nowhere to leave an envelope, and the
  /// bubble shows a clock with the sentence under it. Dropping the write because
  /// the status was unchanged left the user with a clock and no reason at all.
  Future<void> _applyStatus(String messageId, MessageStatus status, String? reason) async {
    final list = _threadOf(messageId);
    if (list == null) return;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final current = list[index];

    final next = _statusWins(current.status, status) ? status : current.status;
    if (next == current.status && current.failureReason == reason) return;

    list[index] = current.copyWith(
      status: next,
      failureReason: reason,
      clearFailureReason: reason == null,
    );
    await _store!.put('messages', list[index].toJson());
    _notify();
  }

  /// Whether [next] may replace [current].
  ///
  /// A failure always may: it can happen at any point, and it is the one state the
  /// user has to see. Everything else only moves forward along
  /// [MessageStatus.rank], so a report that arrives late and describes an earlier
  /// stage cannot undo a later one.
  static bool _statusWins(MessageStatus current, MessageStatus next) {
    if (next == MessageStatus.failed) return true;
    return next.rank >= current.rank;
  }

  /// Records what a handshake revealed, pinning the peer's identity key.
  ///
  /// This is trust-on-first-use: the first key seen for an address becomes the
  /// key that address means. A later handshake presenting a *different* key is
  /// not silently accepted — the contact is marked [ContactTrust.keyChanged] so
  /// the UI can say so, because the alternative reading is that somebody else
  /// is answering for that address.
  Future<void> _rememberPeer(
    String onionAddress,
    Uint8List identityPublicKey,
    Uint8List exchangePublicKey,
    String displayName,
    Map<String, dynamic> capabilities,
  ) async {
    // A key has arrived, so whatever dial was in flight has succeeded. The failure map entry
    // is dropped for the same reason: a stale "the last attempt failed" on a contact whose
    // current attempt worked is a lie the send path would repeat.
    _handshakeInProgress.remove(onionAddress);
    _handshakeFailures.remove(onionAddress);

    final existing = _contacts[onionAddress];
    final hasIdentityKey = identityPublicKey.any((byte) => byte != 0);

    if (existing == null) {
      final contact = Contact(
        id: Ids.generate(),
        onionAddress: onionAddress,
        displayName: displayName.isEmpty ? OnionAddress.shorten(onionAddress) : displayName,
        addedAt: DateTime.now().toUtc(),
        exchangePublicKey: exchangePublicKey,
        identityPublicKey: hasIdentityKey ? identityPublicKey : null,
        trust: ContactTrust.keyed,
        isRelayForUs: capabilities['relaysForOthers'] == true,
        offersMailbox: (capabilities['mailboxQuotaBytes'] as num?)?.toInt() != null,
        lastSeenAt: DateTime.now().toUtc(),
      );
      // Storage before memory, here as everywhere the two are kept in step.
      //
      // The vault can be closing — a lock during a handshake is ordinary — and a `put` that fails
      // must not leave a contact in the map that is not on disk. Such a contact is drawn in the
      // list, opens a thread, and is gone at the next launch, which is worse than never appearing
      // at all: the user has already seen it and will believe they lost it.
      await _store!.put('contacts', contact.toJson());
      _contacts[onionAddress] = contact;
      // The conversation as well as the contact, because the message list is built from
      // conversations and a contact without one is invisible.
      //
      // This is the receiving side of a first handshake: the peer dials us, we learn who they
      // are, and a contact appears. Without this line that contact exists in storage and shows up
      // nowhere — no row in the chat list, no thread to open — until the application restarts and
      // whatever rebuilds the list walks the contacts instead. That is exactly the report: "on
      // the PC the contact only appears after a restart, and the chat does not show".
      await _ensureConversation(onionAddress);
      _notify();
      unawaited(_flushQueued(onionAddress));
      return;
    }

    final pinned = existing.identityPublicKey;
    final changed = hasIdentityKey &&
        pinned != null &&
        !_constantTimeEquals(pinned, identityPublicKey);

    final trust = changed
        // A changed key overrides "verified": the previous verification no
        // longer describes the party on the other end.
        ? ContactTrust.keyChanged
        : existing.trust == ContactTrust.verified
            ? ContactTrust.verified
            : ContactTrust.keyed;

    // The exchange key is only allowed to move when the identity key it was
    // signed by is the one this address is pinned to. A handshake proves the
    // answerer owns the exchange key it presents; it says nothing about the
    // answerer being the contact, and the pinned identity key is the only thing
    // that can tell the two apart.
    //
    // This is the moment it matters. `Contact.trust` going to `keyChanged` only
    // put a warning on the profile screen — the mesh had already been handed the
    // impostor's exchange key, so `_flushQueued` and the next `sendText` sealed
    // the message to it. The user was shown the warning and the app sent the
    // message anyway.
    //
    // `exchangeKeyTrusted` is passed rather than acted on here because the mesh
    // owns the key map and already refuses to replace a key it holds; all it
    // needs is the verdict, which only this layer can reach.
    final keyVerdict = !changed;

    _mesh?.rememberPeer(
      onionAddress: onionAddress,
      exchangePublicKey: exchangePublicKey,
      keyAccepted: keyVerdict,
      displayName: displayName.isEmpty ? existing.displayName : displayName,
      capabilities: PeerCapabilities.fromJson(capabilities),
    );

    final updated = existing.copyWith(
      exchangePublicKey: exchangePublicKey,
      // Only a first-use or a rotation writes the key; a mismatch keeps the
      // pinned one, so the pin is never silently overwritten by an impostor.
      identityPublicKey: changed ? pinned : (hasIdentityKey ? identityPublicKey : null),
      displayName: displayName.isEmpty ? existing.displayName : displayName,
      trust: trust,
      lastSeenAt: DateTime.now().toUtc(),
      isRelayForUs: capabilities['relaysForOthers'] == true,
    );
    // Storage before memory, so a refusal leaves nothing behind. This is the second half of every
    // handshake — the peer already exists — and it carries the learned name and the learned key,
    // which are exactly the two things a stale in-memory record would misreport.
    await _store!.put('contacts', updated.toJson());
    _contacts[onionAddress] = updated;
    _notify();
    // The handshake just produced the key that makes these sendable.
    unawaited(_flushQueued(onionAddress));
  }

  /// Sends everything this peer was written before their key was known.
  ///
  /// A message composed before the first handshake cannot be queued *in the
  /// mesh*, because sealing an envelope needs the peer's exchange key and there
  /// is no key yet to seal with. It was therefore stored, marked `queued`, and
  /// left there for ever: the bubble kept its clock icon, and nothing ever
  /// revisited it — not the outbox retry, which only knows about envelopes it
  /// was actually given, and not the handshake, which learned the key and moved
  /// on. This is the missing half of that pair.
  ///
  /// Order is preserved by walking the in-memory thread, which is stored in
  /// chronological order.
  Future<void> _flushQueued(String peerOnion) async {
    final mesh = _mesh;
    if (mesh == null || !_maySendTo(peerOnion)) return;

    // The thread may never have been opened in this session, in which case the
    // message that needs sending is only on disk.
    if (_messages[peerOnion] == null) {
      try {
        await loadMessages(peerOnion);
      } on Object {
        return;
      }
    }

    final pending = <Message>[
      for (final message in _messages[peerOnion] ?? const <Message>[])
        if (message.direction == MessageDirection.outgoing &&
            message.status == MessageStatus.queued)
          message,
    ];
    if (pending.isEmpty) return;

    for (final message in pending) {
      try {
        // The attachment travels with the message.
        //
        // It used to be dropped here, so a voice note that had waited for a
        // handshake was delivered as a message with no audio — the envelope
        // carried the text and nothing else. `sendVoice` passes it, and this
        // path has to pass the same thing or the two disagree.
        await mesh.sendMessage(
          message: message,
          attachment: _attachments[message.attachmentId],
        );
        await _applyStatus(message.id, MessageStatus.sending, null);
        // Anything that waited for a handshake also waited for its bytes.
        unawaited(
          _sendAttachmentBytes(peerOnion, _attachments[message.attachmentId]),
        );
      } on Object catch (error) {
        // One failure must not stop the rest of the queue.
        await _applyStatus(message.id, MessageStatus.failed, '$error');
      }
    }
  }

  /// The reason to refuse a send, or null when it may go ahead.
  ///
  /// One place, because all four send paths have to agree. Each of them grew its
  /// own copy of the exchange-key check over time and each copy was added only
  /// after the path it guarded had already failed for real; the identity check
  /// was missing from all of them.
  String? _sendRefusal(String peerOnion) {
    final mesh = _mesh;
    if (mesh == null) return 'Networking has not started yet.';
    if (!mesh.isConfigured) {
      // Distinct from "the peer is unreachable", and it is the state a message is in when
      // it is written before Tor has connected. Saying "waiting for the first handshake"
      // here blamed the peer for something the application had not done yet.
      return 'Tor is not connected yet, so nothing can be sent. The message is queued.';
    }
    if (mesh.exchangeKeyOf(peerOnion) == null) {
      // "A dial is running" before "the last one failed", because it is the more recent and
      // more useful fact. A circuit to an unresponsive onion service takes up to ninety
      // seconds, and for that whole time the honest answer is that we are trying — saying
      // nothing is what made this look like a bug.
      if (_handshakeInProgress.contains(peerOnion)) {
        return 'Connecting to this contact now. A first connection over Tor can take up '
            'to a minute. The message is queued and will be sent as soon as it succeeds.';
      }
      // The specific reason when one has been recorded, because "waiting for the first
      // handshake" is true of three different situations and useful for none of them: a
      // peer that is offline, a circuit that timed out and a peer that answered with a
      // different identity all need different things from the user.
      final failure = _handshakeFailures[peerOnion];
      if (failure != null) {
        return 'The last attempt to reach $peerOnion failed: $failure. '
            'The message is queued and will be sent when the contact is reachable.';
      }
      return 'Waiting for the first handshake with this contact.';
    }
    // The identity key this address is pinned to is not the one answering for it
    // any more. Sealing to the new key would hand the conversation to whoever
    // presented it, so nothing is sent and the message says why.
    if (_contacts[peerOnion]?.trust == ContactTrust.keyChanged) {
      return 'This contact is answering with a different identity key than the '
          'one pinned for their address. Nothing is sent until that is resolved '
          'on their profile screen.';
    }
    return null;
  }

  /// True when a message to [peerOnion] may be sealed and sent.
  bool _maySendTo(String peerOnion) => _sendRefusal(peerOnion) == null;

  /// Queues [message] locally because it cannot be sent yet, and explains why.
  Future<void> _holdMessage(String peerOnion, Message message) async {
    await _applyStatus(
      message.id,
      MessageStatus.queued,
      _sendRefusal(peerOnion) ?? 'Waiting for the first handshake with this contact.',
    );
    // Try to produce the missing key rather than waiting for one. A key that
    // cannot be produced — because the peer's identity changed — is not worth
    // dialling for, so only the key case warms up.
    //
    // The null check is on the mesh and not only on its answer: with no network at
    // all, `exchangeKeyOf` is never reached and `warmUp` was called on a null
    // manager. Sending a message before Tor started therefore threw a null-check
    // error instead of queueing the message, which is exactly the case this method
    // exists to handle.
    final mesh = _mesh;
    if (mesh != null && mesh.exchangeKeyOf(peerOnion) == null) {
      unawaited(mesh.warmUp(peerOnion));
    }
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  // --------------------------------------------------------------- actions

  /// Adds a contact from an onion address.
  Future<Contact?> addContact({required String onionAddress, String? displayName}) async {
    final contact = Contact.fromOnion(onionAddress: onionAddress, displayName: displayName);
    if (contact == null) return null;
    // Storage first, memory second. The mirror image of the receiving side: an added contact that
    // the store refused must not be in the map, or the list shows it and the next launch does not.
    await _store!.put('contacts', contact.toJson());
    _contacts[contact.onionAddress] = contact;
    await _ensureConversation(contact.onionAddress);
    _notify();
    // Connecting once establishes the exchange key, which is what makes the first message
    // possible.
    //
    // Registered as well as dialled. The dial below is the first attempt and usually the
    // one that matters — the other person is sitting there with their code on screen — but
    // it is a single attempt over a network where the peer may be starting up, and one
    // attempt that fails used to be the end of it. `expectHandshake` puts the address in
    // the pump's retry set, and `_adoptPeer` takes it out again once a key arrives.
    _mesh?.expectHandshake(contact.onionAddress);
    unawaited(_mesh?.warmUp(contact.onionAddress) ?? Future<void>.value());
    return contact;
  }

  /// Blocks or unblocks a contact.
  ///
  /// Storage first, memory second, as everywhere the two are kept in step. A block that failed to
  /// persist but was applied in memory is the worst version of this divergence: the interface says
  /// the contact is blocked, the next launch says it is not, and the user's reason for blocking
  /// them has been quietly forgotten in between.
  Future<void> setBlocked(String onionAddress, bool blocked) async {
    final contact = _contacts[onionAddress];
    if (contact == null) return;
    final next = contact.copyWith(blocked: blocked);
    await _store!.put('contacts', next.toJson());
    _contacts[onionAddress] = next;
    _notify();
  }

  /// Turns notifications for one contact on or off.
  ///
  /// Storage first, like [setBlocked], and for the same reason: a preference that is shown as set
  /// and silently reverts is worse than one that visibly failed to apply.
  Future<void> setNotifications(String onionAddress, bool enabled) async {
    final contact = _contacts[onionAddress];
    if (contact == null) return;
    final next = contact.copyWith(notificationsEnabled: enabled);
    await _store!.put('contacts', next.toJson());
    _contacts[onionAddress] = next;
    _notify();
  }

  /// Marks a contact's identity as compared out of band.
  ///
  /// Storage first. This is the one preference where a divergence is a security claim rather than
  /// a convenience: "verified" means the user compared the key with the person themselves, and a
  /// verification that is shown and then lost would let a later key change go unflagged.
  Future<void> markVerified(String onionAddress) async {
    final contact = _contacts[onionAddress];
    if (contact == null) return;
    final next = contact.copyWith(trust: ContactTrust.verified);
    await _store!.put('contacts', next.toJson());
    _contacts[onionAddress] = next;
    _notify();
  }

  /// Renames the account's own contact card.
  ///
  /// The name is what a peer sees in a handshake, so the new value is pushed to
  /// the mesh's identity as well as stored: without that, the display name this
  /// account advertises would keep the old value until the vault was re-opened,
  /// and contacts would go on seeing it.
  ///
  /// Returns false and writes nothing when [displayName] is blank or longer than
  /// [maxDisplayNameLength], matching [renameContact].
  Future<bool> renameAccount(String displayName) async {
    final account = _account;
    final store = _store;
    if (account == null || store == null) return false;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty || trimmed.length > maxDisplayNameLength) return false;
    if (trimmed == account.displayName) return true;

    final updated = account.copyWith(displayName: trimmed);
    _account = updated;
    await store.put('account', updated.toJson());

    // The mesh holds a copy of the identity it signs handshakes with, so it has
    // to be told. `configure` is the only way in, and it is idempotent.
    await _publishAddressAndConfigureMesh();
    _notify();
    return true;
  }

  /// The longest display name a contact may be given.
  ///
  /// Enforced here rather than only in the dialog so the limit also holds for a
  /// name that arrives some other way later, and so the dialog can say what the
  /// limit is instead of guessing at it.
  static const int maxDisplayNameLength = 64;

  /// Renames a contact.
  ///
  /// Returns false and writes nothing when the name is blank or longer than
  /// [maxDisplayNameLength]: a nameless contact would be indistinguishable from
  /// an unsaved address, and the conversation list renders the name it is given.
  ///
  /// The name is only a label. The onion address remains the identity the record
  /// is found by, and the pinned identity key is untouched — renaming a contact
  /// cannot change who the messages are encrypted to. A later handshake that
  /// announces a different display name still overwrites this one, because
  /// [Contact.displayName] is whatever the peer last called itself.
  Future<bool> renameContact(String onionAddress, String displayName) async {
    final contact = _contacts[onionAddress];
    if (contact == null) return false;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty || trimmed.length > maxDisplayNameLength) return false;
    if (trimmed == contact.displayName) return true;

    // Storage first. A rename that is displayed and then reverts on the next launch is the
    // failure this ordering rules out, and renaming is exactly the action a user is most likely to
    // perform right before putting the phone down and locking.
    final next = contact.copyWith(displayName: trimmed);
    await _store!.put('contacts', next.toJson());
    _contacts[onionAddress] = next;
    _notify();
    return true;
  }

  /// Deletes one conversation's messages and their attachments.
  ///
  /// Separate from [deleteContact] because keeping the contact while dropping the
  /// history is a reasonable thing to want — a contact whose key is still pinned
  /// is worth more than the transcript.
  ///
  /// The conversation row itself survives, because the contact does: the list
  /// stops showing it only because there is no last message left to preview, so
  /// the thread reappears with the next message either side sends. Its id, its
  /// pins, its draft and its disappearing-message setting are kept — none of them
  /// is history — while the preview, the timestamp and the unread count are reset,
  /// since all three describe messages that no longer exist. The pinned identity
  /// key and the pinned onion address live on the contact and are not touched
  /// here.
  Future<void> clearConversation(String peerOnion) async {
    final store = _store;
    if (store == null) return;

    // The rows on disk, not just the in-memory list: a thread that was never
    // opened has no loaded messages, and clearing it must still clear it.
    final rows = await store.readAll('messages');
    final ids = _messageIdsOf(peerOnion, rows);

    // The attachments first, while the rows that name them still exist.
    for (final id in ids) {
      final row = rows.firstWhere(
        (candidate) => candidate['id'] == id,
        orElse: () => const <String, dynamic>{},
      );
      await _deleteAttachment(row['attachmentId']);
      await store.delete('messages', id);
    }
    _messages.remove(peerOnion);

    final conversation = _conversations[peerOnion];
    if (conversation != null) {
      final cleared = Conversation(
        id: conversation.id,
        peerOnion: conversation.peerOnion,
        createdAt: conversation.createdAt,
        muted: conversation.muted,
        pinned: conversation.pinned,
        archive: conversation.archive,
        draft: conversation.draft,
        disappearingSeconds: conversation.disappearingSeconds,
      );
      _conversations[peerOnion] = cleared;
      await store.put('conversations', cleared.toJson());
    }
    _notify();
  }

  /// Removes a contact, its conversation and the history in it.
  ///
  /// Every record the peer appears in is keyed by the record's own id — the onion
  /// address is a field, not the key — so each collection has to be read back to
  /// find what to remove. Deleting by the address would silently do nothing to the
  /// contacts and conversations logs, which is the kind of bug that only shows up
  /// after a restart.
  ///
  /// What goes:
  ///
  /// * the `contacts` record, which is where the pinned identity key, the pinned
  ///   exchange key, the trust level and the block flag live — re-adding the same
  ///   address later pins whatever key answers next, so a deletion also discards
  ///   the protection that a changed key would have raised;
  /// * every `messages` record for the peer, plus each attachment they name: both
  ///   the `attachments` record and the encrypted file on disk;
  /// * the `conversations` record;
  /// * what the mesh knew about the peer, so a deleted contact stops being a
  ///   delivery candidate and stops counting as a known contact under a
  ///   contacts-only relay policy.
  ///
  /// What stays: the account, and the copies the peer holds. Nothing is sent to
  /// tell them, and their side of the history is theirs.
  ///
  /// Returns false when there is no such contact, so the caller can leave the
  /// screen open rather than navigating away from a no-op.
  Future<bool> deleteContact(String onionAddress) async {
    final store = _store;
    final contact = _contacts[onionAddress];
    if (store == null || contact == null) return false;

    final conversation = _conversations[onionAddress];
    final rows = await store.readAll('messages');
    final messageIds = _messageIdsOf(onionAddress, rows);

    for (final id in messageIds) {
      final row = rows.firstWhere(
        (candidate) => candidate['id'] == id,
        orElse: () => const <String, dynamic>{},
      );
      await _deleteAttachment(row['attachmentId']);
      await store.delete('messages', id);
    }
    // The conversation is deleted rather than emptied: the contact it belongs to
    // is going too, and `addContact` creates a fresh one if the address comes
    // back.
    if (conversation != null) {
      await store.delete('conversations', conversation.id);
    }
    await store.delete('contacts', contact.id);

    _messages.remove(onionAddress);
    _conversations.remove(onionAddress);
    _contacts.remove(onionAddress);

    _mesh?.removePeer(onionAddress);
    // And stop the pump from dialling an address nobody is waiting on. `removePeer` clears
    // the mesh's own memory of the contact, but the retry set is separate — a deleted
    // contact would otherwise keep costing a Tor circuit every five minutes for the rest of
    // the session.
    _mesh?.forgetHandshake(onionAddress);
    _handshakeFailures.remove(onionAddress);
    _notify();
    return true;
  }

  /// The ids of every message record belonging to [peerOnion].
  ///
  /// [rows] is the whole `messages` collection, because a message's own `id` is
  /// what the store is keyed by and the peer is only a field on the record.
  Set<String> _messageIdsOf(String peerOnion, List<Map<String, dynamic>> rows) {
    final ids = <String>{
      for (final row in rows)
        if (row['peerOnion'] == peerOnion && row['id'] is String) row['id'] as String,
    };
    if (_messages[peerOnion] case final loaded?) {
      for (final message in loaded) {
        ids.add(message.id);
      }
    }
    return ids;
  }

  /// Removes one attachment: its record, its bytes, and the copy in memory.
  ///
  /// Both halves have to go. Leaving the ciphertext behind would keep the user's
  /// file on disk after they asked for the thread to be cleared, which is worse
  /// than leaving a row nothing points at — and it is the half a "delete" that
  /// only touches the database gets wrong.
  Future<void> _deleteAttachment(Object? attachmentId) async {
    final store = _store;
    if (store == null || attachmentId is! String) return;
    // The file name travels with the call so the decrypted cache copy can go too,
    // not only the ciphertext: otherwise deleting a file from a thread left a
    // readable copy of it in the cache until the next lock.
    await _fileVault?.delete(
      attachmentId,
      fileName: _attachments[attachmentId]?.fileName,
    );
    _attachments.remove(attachmentId);
    await store.delete('attachments', attachmentId);
  }

  Future<Conversation> _ensureConversation(String peerOnion) async {
    final existing = _conversations[peerOnion];
    if (existing != null) return existing;

    // One creation at a time per peer, and the *disk* write is what single-threads it.
    //
    // ## The two hazards, and why this shape handles both
    //
    // Two callers can arrive together — a handshake writes a conversation, and a message being
    // sent writes one beside it — and they must not produce two rows for the same peer. A second
    // row shows the contact twice in the chat list after the next restart, because the list is
    // built from conversations.
    //
    // The obvious guard is to register the conversation in the map before awaiting anything, which
    // is what this used to do. That closes the duplicate window and opens a worse one: if the
    // write then fails the conversation is in memory and not on disk, so the chat list shows a
    // row that vanishes at the next launch. `put` can fail — the vault may be closing, which is
    // ordinary when someone types a message and immediately locks.
    //
    // Registering the *future* settles both. Concurrent callers share one creation and therefore
    // one id, and the map is only populated once the record is actually stored, so memory never
    // claims something storage does not have.
    final inFlight = _conversationCreations[peerOnion];
    if (inFlight != null) return inFlight;

    final creation = _createConversation(peerOnion);
    _conversationCreations[peerOnion] = creation;
    try {
      return await creation;
    } finally {
      // Removed once settled, so a later call re-checks the map in the ordinary way and a failed
      // creation can be retried rather than being remembered as permanently impossible.
      _conversationCreations.remove(peerOnion);
    }
  }

  Future<Conversation> _createConversation(String peerOnion) async {
    final conversation = Conversation(
      id: Ids.generate(),
      peerOnion: peerOnion,
      createdAt: DateTime.now().toUtc(),
    );
    await _store!.put('conversations', conversation.toJson());
    _conversations[peerOnion] = conversation;
    return conversation;
  }

  /// Conversation creations in flight, keyed by peer, so two callers share one.
  final Map<String, Future<Conversation>> _conversationCreations =
      <String, Future<Conversation>>{};

  Future<void> _touchConversation(
    String peerOnion,
    Message message, {
    bool incrementUnread = false,
  }) async {
    final conversation = await _ensureConversation(peerOnion);
    final next = conversation.copyWith(
      lastMessageAt: message.createdAt,
      lastMessagePreview: message.preview,
      lastMessageKind: message.kind.name,
      unreadCount: incrementUnread ? conversation.unreadCount + 1 : conversation.unreadCount,
    );
    // Written before it is remembered, and that order matters.
    //
    // The previous order put the new conversation in the map and then wrote it. If the vault
    // closed in between — locking while a message is being sent is ordinary — the write threw and
    // the map kept a summary that no longer existed on disk: a preview and an unread count for a
    // message that was never stored, gone at the next launch. Writing first means a failure leaves
    // memory untouched, so the two cannot disagree.
    await _store!.put('conversations', next.toJson());
    _conversations[peerOnion] = next;
  }

  /// The unsent text of a thread, so it survives closing the screen or the app.
  ///
  /// `Conversation.draft` has been in the model — and in the serialised record —
  /// since the beginning, and nothing ever read or wrote it, so the field was
  /// dead weight that made a promise the app did not keep. This reads the copy
  /// already in memory rather than hitting the store, because the chat screen
  /// asks for it while it is building.
  String draftFor(String peerOnion) => _conversations[peerOnion]?.draft ?? '';

  /// Remembers (or clears) the draft of a thread.
  ///
  /// Deliberately not `async` in its effect on the UI: the composer fires this on
  /// every keystroke, so the in-memory record is updated immediately and the
  /// write to disk is fired and forgotten. Nothing on screen depends on the
  /// write having landed, and a keystroke must not await an encrypted append.
  void saveDraft(String peerOnion, String draft) {
    final conversation = _conversations[peerOnion];
    if (conversation == null) return;
    if (conversation.draft == draft) return;
    final next = conversation.copyWith(draft: draft);
    _conversations[peerOnion] = next;
    // No `_notify()`: this fires on every character, and rebuilding the whole
    // shell per keystroke to re-render a string the composer already holds is
    // exactly the kind of work that makes typing feel slow.
    unawaited(_persistDraft(next));
  }

  Future<void> _persistDraft(Conversation conversation) async {
    final store = _store;
    if (store == null || !store.isOpen) return;
    try {
      await store.put('conversations', conversation.toJson());
    } on Object {
      // A draft is a convenience. Failing to write one must never surface as an
      // error over the message the user is still typing.
    }
  }

  /// Marks a conversation as read, and tells the peer so.
  ///
  /// The receipt is the whole point of the second tick. Only `markRead` knows
  /// that a human opened the thread, so this is the one place that can honestly
  /// send `read: true` — and without it the sender's message sat on "delivered"
  /// for ever, however long ago it had been read.
  Future<void> markRead(String peerOnion) async {
    final conversation = _conversations[peerOnion];
    if (conversation == null || conversation.unreadCount == 0) return;
    final next = conversation.copyWith(unreadCount: 0);
    await _store!.put('conversations', next.toJson());
    _conversations[peerOnion] = next;
    _notify();

    // Everything that arrived here and has not been acknowledged yet. Two
    // separate things are being reported: which messages were seen at all
    // (`delivered`) and which were looked at (`read`).
    final incoming = <String>[
      for (final message in _messages[peerOnion] ?? const <Message>[])
        if (!message.isOutgoing) message.id,
    ];
    if (incoming.isEmpty) return;
    final mesh = _mesh;
    if (mesh == null || mesh.exchangeKeyOf(peerOnion) == null) return;
    // One receipt rather than one per message: the frame already carries a list,
    // and a thread of fifty unread messages would otherwise open fifty
    // connections.
    unawaited(mesh.sendReceipt(peerOnion: peerOnion, messageIds: incoming, read: true));
  }

  /// Sends a text message.
  ///
  /// [replyToId] quotes an earlier message in the same thread. It travels in the
  /// envelope, so the peer renders the same quote the sender saw; the model and
  /// the wire format have always supported it, and nothing ever set it, which is
  /// how the reply gesture ended up bound to "copy to clipboard" instead.
  ///
  /// Returns true when the message was recorded, whether or not it could be sent
  /// immediately. False means it was rejected and the caller should keep the draft.
  ///
  /// ## Why the mesh is not required
  ///
  /// This used to start with `if (... || mesh == null) return;`, and that one
  /// clause is why a sent message did not appear until the conversation was
  /// reopened. Networking is started with `unawaited(_startNetworking())` right
  /// after unlock, and the shell is on screen the whole time it runs: a peer
  /// server to bind, Tor to configure, secrets to read. Any message composed
  /// during that window — or at any time before Tor has been connected, since the
  /// mesh is not configured until then — hit the guard and was thrown away
  /// without a trace. The composer had already cleared itself, so the text was
  /// simply gone, and the thread looked as though the message had never been
  /// written.
  ///
  /// A messenger must not lose what the user wrote because the network is not
  /// ready. The message is now always recorded and queued, and the network layer
  /// is a separate question that decides only what happens next.
  Future<bool> sendText(String peerOnion, String text, {String? replyToId}) async {
    final store = _store;
    if (_account == null || store == null || !store.isOpen) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    // The conversation first, so the message records the id of the row that actually exists.
    // Building the message with `_conversations[peerOnion]?.id ?? peerOnion` before this line
    // meant a first message to a new contact was filed under the onion address instead of the
    // conversation id, and the thread the chat list opened was a different one.
    final conversation = await _ensureConversation(peerOnion);

    final message = Message(
      id: Ids.generate(),
      conversationId: conversation.id,
      peerOnion: peerOnion,
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      createdAt: DateTime.now().toUtc(),
      body: trimmed,
      status: MessageStatus.queued,
      replyToId: replyToId,
    );

    // Storage before memory, here as well as in `_touchConversation`.
    //
    // The vault can be closing — locking while a message is being sent is ordinary — and a write
    // that fails must not leave the message in the in-memory thread. It would be drawn, it would
    // never have been stored, and it would vanish at the next launch, which is worse than the
    // send failing visibly.
    try {
      await store.put('messages', message.toJson());
    } on Object catch (error) {
      logStorage('a message could not be stored', detail: '$error');
      return false;
    }
    _insertMessage(peerOnion, message);
    await _touchConversation(peerOnion, message);
    _notify();

    final mesh = _mesh;
    if (mesh == null || !_maySendTo(peerOnion)) {
      // Warming up here closes a real loop: the handshake needs this peer's
      // exchange key to seal a frame, and the key only arrives from a handshake,
      // so a first message to a contact who was offline when they were added
      // could never be sent because nothing ever dialled again. If the peer is
      // reachable, `_rememberPeer` learns the key and `_flushQueued` sends what
      // is waiting; if they are not, the message stays queued and the next
      // attempt repeats this.
      //
      // With no mesh at all there is nothing to warm up and nothing to seal to:
      // the message stays queued, and `_startNetworking` flushes the queue as
      // soon as the network exists. That path already runs on every unlock — it
      // is what sends whatever a previous session left behind.
      await _holdMessage(peerOnion, message);
      return true;
    }

    try {
      await mesh.sendMessage(message: message);
      await _applyStatus(message.id, MessageStatus.sending, null);
    } on Object catch (error) {
      await _applyStatus(message.id, MessageStatus.failed, '$error');
    }
    return true;
  }

  /// Sends a file, imported into the encrypted vault first.
  ///
  /// With an empty [peerOnion] the file is imported into the vault and nothing is
  /// sent. That is not a convenience: the "Add files" action on the protected-files
  /// screen called this with a blank address, which sealed the file (the intended
  /// half) and then went on to create a message and a conversation keyed by the
  /// empty string — so the chat list grew a nameless row with a `?` avatar holding
  /// a message that could never be sent or deleted, every time somebody added a
  /// file to their own vault.
  ///
  /// Like [sendText], the mesh is not required: a file chosen before networking is
  /// ready is sealed into the vault and queued, not discarded.
  Future<bool> sendFile(String peerOnion, File file) async {
    final vault = _fileVault;
    final store = _store;
    if (vault == null || store == null || !store.isOpen) return false;
    if (peerOnion.isEmpty) {
      await importIntoVault(file);
      return false;
    }

    final attachmentId = Ids.generate();
    final stat = await file.stat();
    final fileName = file.uri.pathSegments.last;

    final attachment = Attachment(
      id: attachmentId,
      fileName: fileName,
      mimeType: _mimeFor(fileName),
      sizeBytes: stat.size,
      sha256Hex: '',
      createdAt: DateTime.now().toUtc(),
      localPath: file.path,
    );

    final digest = await vault.import(attachmentId: attachmentId, source: file);
    final stored = attachment.copyWith(localPath: file.path, transferComplete: true);
    final withDigest = Attachment(
      id: stored.id,
      messageId: stored.messageId,
      fileName: stored.fileName,
      mimeType: stored.mimeType,
      sizeBytes: stored.sizeBytes,
      sha256Hex: digest,
      createdAt: stored.createdAt,
      localPath: stored.localPath,
      durationMs: stored.durationMs,
      waveform: stored.waveform,
      width: stored.width,
      height: stored.height,
      transferProgress: 1,
      transferComplete: true,
    );
    _attachments[attachmentId] = withDigest;
    await store.put('attachments', withDigest.toJson());

    final message = Message(
      id: Ids.generate(),
      conversationId: _conversations[peerOnion]?.id ?? peerOnion,
      peerOnion: peerOnion,
      direction: MessageDirection.outgoing,
      kind: withDigest.isImage ? MessageKind.image : MessageKind.file,
      createdAt: DateTime.now().toUtc(),
      body: '',
      status: MessageStatus.queued,
      attachmentId: attachmentId,
    );
    _insertMessage(peerOnion, message);
    await store.put('messages', message.toJson());
    await _touchConversation(peerOnion, message);
    _notify();

    // Same gate as text and voice, through the one shared predicate. Files were
    // the third path to grow its own copy of it, and like text it needs the mesh
    // only to decide *how* the message goes out, not whether it is kept.
    final mesh = _mesh;
    if (mesh == null || !_maySendTo(peerOnion)) {
      await _holdMessage(peerOnion, message);
      return true;
    }

    try {
      await mesh.sendMessage(message: message, attachment: withDigest);
      await _applyStatus(message.id, MessageStatus.sending, null);
    } on Object catch (error) {
      await _applyStatus(message.id, MessageStatus.failed, '$error');
      return true;
    }
    // The bytes follow the message that announces them. Without this the recipient
    // had metadata and nothing to open — which is how a received file came to be
    // listed, drawn, tappable and permanently unopenable.
    unawaited(_sendAttachmentBytes(peerOnion, withDigest));
    return true;
  }

  /// Seals a file into the vault without sending it anywhere.
  ///
  /// This is what "protected files" means: the user's own copy, encrypted at rest
  /// under the account master key and reachable from the vault screen. It records
  /// no message and no conversation, because there is nobody to send it to.
  ///
  /// Returns the attachment that was stored, or null when the file could not be
  /// imported.
  Future<Attachment?> importIntoVault(File file) async {
    final vault = _fileVault;
    final store = _store;
    if (vault == null || store == null) return null;

    final attachmentId = Ids.generate();
    final fileName = file.uri.pathSegments.last;
    final digest = await vault.import(attachmentId: attachmentId, source: file);
    final attachment = Attachment(
      id: attachmentId,
      fileName: fileName,
      mimeType: _mimeFor(fileName),
      sizeBytes: await file.length(),
      sha256Hex: digest,
      createdAt: DateTime.now().toUtc(),
      localPath: file.path,
      transferProgress: 1,
      transferComplete: true,
    );
    _attachments[attachmentId] = attachment;
    await store.put('attachments', attachment.toJson());
    _notify();
    return attachment;
  }

  /// Sends a recorded voice note.
  ///
  /// Like [sendText], the mesh is not required: a note recorded before networking
  /// is ready is sealed into the vault and queued. Returning before the vault
  /// import would lose a recording the user cannot make again.
  Future<bool> sendVoice(
    String peerOnion,
    File recording, {
    required int durationMs,
    List<int> waveform = const <int>[],
  }) async {
    final vault = _fileVault;
    final store = _store;
    if (vault == null || store == null || !store.isOpen) return false;

    final attachmentId = Ids.generate();
    final digest = await vault.import(attachmentId: attachmentId, source: recording);
    final attachment = Attachment(
      id: attachmentId,
      fileName: 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: await recording.length(),
      sha256Hex: digest,
      createdAt: DateTime.now().toUtc(),
      localPath: recording.path,
      durationMs: durationMs,
      waveform: waveform,
      transferProgress: 1,
      transferComplete: true,
    );
    _attachments[attachmentId] = attachment;
    await store.put('attachments', attachment.toJson());

    final message = Message(
      id: Ids.generate(),
      conversationId: _conversations[peerOnion]?.id ?? peerOnion,
      peerOnion: peerOnion,
      direction: MessageDirection.outgoing,
      kind: MessageKind.voice,
      createdAt: DateTime.now().toUtc(),
      body: '',
      status: MessageStatus.queued,
      attachmentId: attachmentId,
    );
    _insertMessage(peerOnion, message);
    await store.put('messages', message.toJson());
    await _touchConversation(peerOnion, message);
    _notify();

    // The same gate `sendText` has, which this path was missing.
    //
    // Sealing an envelope needs the peer's exchange key, so `sendMessage` throws
    // when the first handshake has not happened. Without this check a voice note
    // to a contact who was offline when they were added was marked `failed` on
    // the spot — permanently, because `_flushQueued` only ever revisits messages
    // that are still `queued`. A voice message could therefore never reach a new
    // contact at all.
    final mesh = _mesh;
    if (mesh == null || !_maySendTo(peerOnion)) {
      await _holdMessage(peerOnion, message);
      return true;
    }

    try {
      await mesh.sendMessage(message: message, attachment: attachment);
      await _applyStatus(message.id, MessageStatus.sending, null);
    } on Object catch (error) {
      await _applyStatus(message.id, MessageStatus.failed, '$error');
      return true;
    }
    // The recording follows the message. Not awaited: the note has to appear on
    // both sides straight away, and the transfer is the slower half.
    unawaited(_sendAttachmentBytes(peerOnion, attachment));
    return true;
  }

  /// Retries a message that failed.
  ///
  /// The gate is the same one the original send used, and it used to be absent
  /// here. Retrying is the *only* way out of `failed`, so a message retried
  /// before the first handshake threw out of `sendMessage`, was marked `failed`
  /// again, and stayed that way for good — the tap looked like it did something
  /// and the reason never changed. Holding it instead puts it back in the queue
  /// that `_flushQueued` drains, which is the state that can still succeed.
  Future<void> retry(String messageId) async {
    for (final entry in _messages.entries) {
      final index = entry.value.indexWhere((message) => message.id == messageId);
      if (index < 0) continue;
      final message = entry.value[index];
      final peerOnion = entry.key;
      final mesh = _mesh;
      if (mesh == null) return;

      if (!_maySendTo(peerOnion)) {
        await _applyStatus(messageId, MessageStatus.queued, _sendRefusal(peerOnion));
        if (mesh.exchangeKeyOf(peerOnion) == null) unawaited(mesh.warmUp(peerOnion));
        return;
      }

      await _applyStatus(messageId, MessageStatus.sending, null);
      try {
        await mesh.sendMessage(
          message: message,
          attachment: attachmentFor(message.attachmentId),
        );
      } on Object catch (error) {
        await _applyStatus(messageId, MessageStatus.failed, '$error');
      }
      return;
    }
  }

  /// Persists new Tor settings and applies them.
  ///
  /// A running daemon is stopped, because torrc is read once at startup: one
  /// left alive keeps using the old bridges, the old ports and the old onion
  /// service, and the screen would show the new choice while Tor honoured the
  /// previous one.
  ///
  /// It is stopped **only when something actually changed**. The bridge screen's
  /// Next button calls this unconditionally — including when the user opened it
  /// merely to look and pressed Next to close it — so stopping on every call
  /// meant that closing the screen killed a working daemon. That is a
  /// regression this guard exists to prevent.
  Future<void> applyTorSettings(TorSettings next) async {
    if (jsonEncode(_settings.torSettings.toJson()) ==
        jsonEncode(next.toJson())) {
      return;
    }

    _settings = _settings.copyWith(torSettings: next);
    await _persistSettings(_settings);
    _notify();

    final wasRunning = _tor?.isStarted ?? false;
    if (wasRunning) await _tor?.stop();

    // Hand the new settings to the manager, always.
    //
    // `TorConfig` builds torrc from the manager's own copy, not from
    // `AppSettings`, so without this the daemon keeps generating the config it
    // was created with. Removing this line in favour of "stop the daemon"
    // meant bridges never reached torrc at all: the app wrote `UseBridges 0`
    // however many bridge lines the user pasted, connected directly, and
    // stalled at 10% while insisting a bridge was configured.
    await _tor?.applySettings(next);

    // The SOCKS port is gone, so the mesh has to let go of it either way.
    await _publishAddressAndConfigureMesh();
    if (wasRunning) _notify();
  }

  /// Persists a new relay policy and hands it to the mesh.
  Future<void> applyRelayPolicy(RelayPolicy next) async {
    _settings = _settings.copyWith(relayPolicy: next);
    await _persistSettings(_settings);
    _mesh?.setPolicy(next);
    _notify();
  }

  /// Persists the notification preference.
  ///
  /// Turning notifications on also asks the platform for permission, because that is
  /// the moment the request makes sense to the user — a prompt at first launch,
  /// before they have done anything, is the one people refuse.
  Future<void> setNotificationsEnabled(bool enabled) async {
    _settings = _settings.copyWith(notificationsEnabled: enabled);
    await _persistSettings(_settings);
    if (enabled) {
      // Not awaited against the settings write: the preference is the user's and is
      // saved either way, while the permission is the platform's to grant or refuse.
      final granted = await _notifications?.requestPermission() ?? false;
      // Refused permission means the switch would be a lie, so it goes back.
      if (!granted && _notifications != null && _notifications!.isReady) {
        _settings = _settings.copyWith(notificationsEnabled: false);
        await _persistSettings(_settings);
      }
    }
    _notify();
  }

  /// Chooses the microphone the recorder opens, or the system default for null.  ///
  /// Only stores the choice. Applying it is the shell's job, because the recorder
  /// is owned there: reaching into it from here would give one object two owners,
  /// and the account layer already has enough to keep in step.
  Future<void> setMicrophone(String? deviceId) async {
    _settings = deviceId == null
        ? _settings.copyWith(clearMicrophone: true)
        : _settings.copyWith(microphoneId: deviceId);
    await _persistSettings(_settings);
    _notify();
  }

  /// Starts Tor from the connection screen.
  ///
  /// Safe to call before the manager exists — the shell renders its Connect
  /// button as soon as the vault is open, which can be a frame earlier than
  /// [_startNetworking] finishing — so this brings networking up first if it
  /// has not happened yet.
  Future<void> startTor() async {
    if (_tor == null) {
      await _startNetworking();
      // `_startNetworking` may itself have been the thing that created the
      // manager, so fall through rather than returning: the push below is what
      // guarantees the daemon is started with the settings on screen.
      if (_tor == null) return;
    }
    // Hand the manager the settings that are actually in force, every time.
    //
    // `TorManager` builds torrc from its own copy, and the only other place that
    // copy is updated is `applyTorSettings`. Configuring bridges before the
    // manager existed therefore sent them to `null` and they were never seen:
    // the settings screen showed the lines, the connection screen listed
    // "Bridges: WebTunnel, 2 lines", and Tor still started with `UseBridges 0`
    // and stalled at 10%. Pushing here makes "what the user configured" and
    // "what the daemon was told" the same thing by construction.
    await _tor!.applySettings(_settings.torSettings);
    await _tor!.start();
    await _publishAddressAndConfigureMesh();
    _notify();
  }

  /// Restarts Tor after a failed bootstrap.
  ///
  /// A failure is often transient — an orphaned daemon holding the data
  /// directory, a relay that went away, or bridge lines that needed editing —
  /// so the connection screen offers this instead of leaving the user with a
  /// disabled button.
  Future<void> restartTor() async {
    final tor = _tor;
    if (tor == null) {
      await startTor();
      return;
    }
    // Stop, record, start — in that order, and for a reason.
    //
    // `TorManager.applySettings` performs its own stop-and-start when the
    // transport changed, so calling it on a running daemon and then asking for a
    // restart would restart twice. Stopping first makes `applySettings` take its
    // "not running, just remember this" path, and the single `start` below is
    // the one that actually happens.
    await tor.stop();
    await tor.applySettings(_settings.torSettings);
    await tor.start();
    await _publishAddressAndConfigureMesh();
    _notify();
  }

  /// Stops Tor.
  Future<void> stopTor() async {
    await _tor?.stop();
    _notify();
  }

  /// Re-runs bootstrap after a failure.
  Future<void> retryBootstrap() async {
    _failure = null;
    await bootstrap();
  }

  // ----------------------------------------------------------- persistence

  Future<AppSettings> _loadSettings() async {
    final row = await _store!.read('settings', 'app');
    return row == null ? const AppSettings() : AppSettings.fromJson(row);
  }

  Future<void> _persistSettings(AppSettings settings) async {
    final store = _store;
    if (store == null || !store.isOpen) return;
    await store.put('settings', settings.toJson());
  }

  Future<void> _persistSecret(String name, Uint8List value) async {
    final ring = _ring;
    if (ring == null) return;
    await _store!.put('secrets', <String, dynamic>{
      'id': name,
      'value': base64Encode(value),
    });
  }

  Future<Uint8List?> _readSecret(String name) async {
    final row = await _store?.read('secrets', name);
    final value = row?['value'];
    if (value is! String || value.isEmpty) return null;
    return base64Decode(value);
  }

  static String _mimeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    return switch (fileName.substring(dot + 1).toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'm4a' => 'audio/mp4',
      'mp3' => 'audio/mpeg',
      'ogg' || 'opus' => 'audio/ogg',
      'mp4' => 'video/mp4',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  void _setStage(AppStage stage, {String? message}) {
    _stage = stage;
    _statusMessage = message;
    if (stage != AppStage.failure) _failure = null;
    _notify();
  }

  void _fail(String message) {
    _failure = message;
    _stage = AppStage.failure;
    _notify();
  }

  @override
  void dispose() {
    // Set first, because everything below is asynchronous: an in-flight
    // `_startNetworking` can still reach `_notify()` after this returns, and
    // that is exactly what was crashing.
    _disposed = true;
    // The log file belongs to the vault, so it is released with it. Leaving it open keeps a
    // handle on the vault directory for the life of the process, which in the application means
    // the directory cannot be moved or removed while DarkFlow runs, and in a test makes the
    // temporary vault undeletable. See `LogBook.detachFromFile`.
    //
    // Not awaited, because `dispose` is synchronous by contract and the writes it waits for are
    // already scheduled; `logBook.flush()` is what a caller waits on when it needs the file
    // closed, as the test suite does.
    unawaited(logBook.detachFromFile());
    unawaited(_meshSubscription?.cancel());
    unawaited(_torSubscription?.cancel());
    _tor?.removeListener(_onTorChanged);
    unawaited(_mesh?.dispose());
    unawaited(_peerServer?.stop());
    unawaited(_engine.dispose());
    // `dispose` on the manager is synchronous — it only schedules its own stop.
    _tor?.dispose();
    super.dispose();
  }
}