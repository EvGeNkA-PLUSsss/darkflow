import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// A notification to show for an arriving message.
///
/// A value type rather than passing a `Message`, so the decision about *what* to
/// show can be made and tested in the account layer — where the contact's
/// preferences and the conversation's unread count live — while this layer only has
/// to know how to put it on screen.
class MessageAlert {
  const MessageAlert({
    required this.conversationKey,
    required this.title,
    required this.body,
    this.direct = false,
  });

  /// Identifies the conversation, so a second message from the same person
  /// replaces the first alert rather than stacking a wall of them.
  final String conversationKey;

  /// Who the message is from, as the notification's headline.
  final String title;

  /// The message, shortened.
  final String body;

  /// True when the alert describes a message whose contents DarkFlow chose not to
  /// put on screen — a file, a photo, a voice note. The body is then a description
  /// rather than the content, which is also what the lock screen shows.
  final bool direct;

  /// Android notification ids are 32-bit, so the conversation key has to be folded
  /// into one. A stable fold matters: the whole point of the id is that the same
  /// conversation's next alert replaces the previous one.
  int get notificationId => conversationKey.hashCode & 0x7fffffff;
}

/// Shows message alerts.
///
/// ## What this deliberately does not do
///
/// Nothing here runs when the application is closed. DarkFlow receives over Tor
/// through a daemon running inside the application's own process, so there is no
/// code alive to be woken and no push service to deliver from: a notification can
/// only be produced while the process is running. On a phone that means alerts
/// arrive while DarkFlow is in the background *and still alive*, and stop when the
/// system reclaims it.
///
/// Doing better would need a foreground service on Android — a permanent
/// notification and a permanently running Tor, which is a large battery cost and a
/// decision the user has to make deliberately. That is not implemented, and the
/// settings screen says so rather than letting the switch imply more than it
/// delivers.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  bool _ready = false;

  /// True once the platform channel has accepted the initialisation.
  bool get isReady => _ready;

  /// Whether this platform can show a notification at all.
  ///
  /// Windows is the one that cannot: the plugin carries implementations for Android,
  /// iOS, macOS and Linux, and its Windows support lives in a separate package whose
  /// build needs the ATL headers from a Visual Studio workload that is not part of a
  /// standard Flutter desktop toolchain. Rather than make the Windows build depend on
  /// that, the platform is reported as unable to notify — and the settings switch
  /// says so instead of pretending.
  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux;

  /// Prepares the plugin. Safe to call more than once.
  ///
  /// [onOpened] is handed the conversation key of a notification the user tapped,
  /// which is what lets the app open that conversation rather than the list.
  Future<bool> initialise({void Function(String conversationKey)? onOpened}) async {
    if (_ready) return true;
    if (!isSupported) return false;

    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // Asked for when the first message needs to be shown, not at launch:
          // a permission prompt before the user has done anything is the one
          // people refuse.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      final accepted = await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final key = response.payload;
          if (key != null && key.isNotEmpty) onOpened?.call(key);
        },
      );
      _ready = accepted ?? false;
    } on Object {
      // A platform without an implementation raises here. Treated as "not
      // available" rather than as a crash on startup.
      _ready = false;
    }
    return _ready;
  }

  /// Asks for permission, where the platform requires it.
  ///
  /// Called when the user turns notifications on, because that is the moment the
  /// request makes sense to them.
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
      if (Platform.isIOS || Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } on Object {
      return false;
    }
    return false;
  }

  /// Shows, or replaces, the alert for one conversation.
  Future<void> show(MessageAlert alert) async {
    if (!_ready) return;
    try {
      // One channel for message alerts. It cannot be deleted once created, so the
      // name and description are deliberately plain: a wrong choice here is
      // permanent for everyone who installed that build.
      const android = AndroidNotificationDetails(
        'darkflow_messages',
        'Messages',
        channelDescription: 'Alerts for messages from your contacts',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        // Only the sender and a short description are exposed; the message itself is
        // end-to-end encrypted, and putting its text on a lock screen would undo that.
        visibility: NotificationVisibility.private,
        // A second message from the same person replaces the first alert rather than
        // buzzing again for it.
        onlyAlertOnce: true,
      );
      const apple = DarwinNotificationDetails();
      await _plugin.show(
        alert.notificationId,
        alert.title,
        alert.body,
        const NotificationDetails(android: android, iOS: apple, macOS: apple),
        payload: alert.conversationKey,
      );
    } on Object {
      // A failed alert must never take down the message path that produced it.
    }
  }

  /// Clears one conversation's alert, for when the user opens it here.
  Future<void> clear(String conversationKey) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(conversationKey.hashCode & 0x7fffffff);
    } on Object {
      // Nothing to clear.
    }
  }

  /// Clears every alert.
  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } on Object {
      // Nothing to clear.
    }
  }
}

/// What a notification should say about a message, and whether it should be shown.
///
/// A separate function with no plugin in it, because these are the rules worth
/// testing: which messages alert, what they say, and what is deliberately left out
/// of the text.
abstract final class AlertPolicy {
  /// The longest body shown before it is shortened.
  ///
  /// A lock screen shows a few lines; past that, a long message is noise, and the
  /// whole thing on a lock screen is more than the user asked to expose.
  static const int maxBodyLength = 120;

  /// Builds the alert for a message, or null when nothing should be shown.
  ///
  /// [globalEnabled] is the app-wide switch, [contactEnabled] the per-contact one —
  /// both exist in the settings, and a contact's own preference has to win, because
  /// it is the more specific statement of intent.
  /// [isForeground] suppresses the alert while the user is already looking at the
  /// application: an alert for a message that just appeared on screen is an
  /// interruption with no information in it.
  static MessageAlert? build({
    required String conversationKey,
    required String senderName,
    required String body,
    required bool isImage,
    required bool isVoice,
    required bool isFile,
    required bool globalEnabled,
    required bool contactEnabled,
    required bool isForeground,
  }) {
    if (!globalEnabled || !contactEnabled) return null;
    if (isForeground) return null;
    if (conversationKey.isEmpty) return null;

    // The text wins when there is any. A photo sent with a caption is a text
    // message as far as the reader is concerned, and announcing it as "Photo" throws
    // away the words the sender actually wrote; the description is the fallback for
    // the attachment-only case.
    final words = shorten(body);
    final String description;
    final bool direct;
    if (words.isNotEmpty) {
      description = words;
      direct = true;
    } else if (isVoice) {
      description = 'Voice message';
      direct = false;
    } else if (isImage) {
      description = 'Photo';
      direct = false;
    } else if (isFile) {
      description = 'File';
      direct = false;
    } else {
      description = 'New message';
      direct = false;
    }

    return MessageAlert(
      conversationKey: conversationKey,
      title: senderName.isEmpty ? 'New message' : senderName,
      body: description,
      direct: direct,
    );
  }

  /// Trims a body to something a notification can show.
  static String shorten(String body, {int limit = maxBodyLength}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= limit) return flat;
    // Cut at the limit rather than at a word boundary: a notification does not need
    // to read well, it needs to be short, and searching backwards for a space
    // produces a ragged edge that looks like a bug for a single long word.
    return '${flat.substring(0, limit)}…';
  }
}
