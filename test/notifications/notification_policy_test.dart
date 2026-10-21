import 'dart:io';

import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// When a message is announced, and what the announcement says.
///
/// The rules live in [AlertPolicy], which has no platform plugin in it, so they can
/// be checked without a notification channel. That separation is the point: the
/// plugin is a thin wrapper, and everything that could be wrong about *when* to
/// interrupt somebody is here.
void main() {
  /// A well-formed call with everything turned on and the app in the background.
  MessageAlert? build({
    String conversationKey = 'peer.onion',
    String senderName = 'Alice',
    String body = 'hello',
    bool isImage = false,
    bool isVoice = false,
    bool isFile = false,
    bool globalEnabled = true,
    bool contactEnabled = true,
    bool isForeground = false,
  }) =>
      AlertPolicy.build(
        conversationKey: conversationKey,
        senderName: senderName,
        body: body,
        isImage: isImage,
        isVoice: isVoice,
        isFile: isFile,
        globalEnabled: globalEnabled,
        contactEnabled: contactEnabled,
        isForeground: isForeground,
      );

  group('when nothing is shown', () {
    test('while the user is looking at the app', () {
      // An alert for a message that just appeared on screen interrupts with no
      // information in it.
      expect(build(isForeground: true), isNull);
    });

    test('when notifications are off globally', () {
      expect(build(globalEnabled: false), isNull);
    });

    test('when the contact or conversation is muted', () {
      // The per-contact preference is the more specific statement of intent, so it
      // has to win over the global switch being on.
      expect(build(contactEnabled: false), isNull);
    });

    test('with no conversation to attach it to', () {
      // Cannot be replaced or cleared afterwards, so it would accumulate.
      expect(build(conversationKey: ''), isNull);
    });
  });

  group('what is shown for each kind of message', () {
    test('a text message shows its own words', () {
      final alert = build(body: 'meet me at six');
      expect(alert, isNotNull);
      expect(alert!.body, 'meet me at six');
      expect(alert.direct, isTrue);
    });

    test('a voice note is described, not transcribed', () {
      final alert = build(body: '', isVoice: true);
      expect(alert!.body, 'Voice message');
      expect(alert.direct, isFalse);
    });

    test('a photo is described', () {
      final alert = build(body: '', isImage: true);
      expect(alert!.body, 'Photo');
      expect(alert.direct, isFalse);
    });

    test('a file is described', () {
      final alert = build(body: '', isFile: true);
      expect(alert!.body, 'File');
      expect(alert.direct, isFalse);
    });

    test('a text message with a caption still shows the caption', () {
      // A photo with words attached is a text message as far as the user is
      // concerned; describing it as "Photo" would throw away what they wrote.
      final alert = build(body: 'look at this', isImage: true);
      expect(alert!.body, 'look at this');
      expect(alert.direct, isTrue);
    });

    test('an empty body still says something', () {
      final alert = build(body: '');
      expect(alert!.body, 'New message');
    });

    test('a nameless sender is not left blank', () {
      final alert = build(senderName: '');
      expect(alert!.title, 'New message');
    });
  });

  group('the body is shortened', () {
    test('a long message is cut to the limit', () {
      final alert = build(body: 'x' * 500);
      expect(alert!.body.length, AlertPolicy.maxBodyLength + 1,
          reason: 'the limit plus the ellipsis');
      expect(alert.body.endsWith('…'), isTrue);
    });

    test('a message at exactly the limit is left alone', () {
      final body = 'y' * AlertPolicy.maxBodyLength;
      expect(build(body: body)!.body, body);
    });

    test('newlines collapse to single spaces', () {
      // A multi-line paste would otherwise put a paragraph on the lock screen and
      // make the notification taller than the tray allows.
      expect(AlertPolicy.shorten('one\n\ntwo   three'), 'one two three');
    });

    test('surrounding whitespace is dropped', () {
      expect(AlertPolicy.shorten('   spaced   '), 'spaced');
    });

    test('a single long word is cut rather than rejected', () {
      final alert = build(body: 'z' * 300);
      expect(alert!.body.startsWith('zzz'), isTrue);
      expect(alert.body.length, lessThanOrEqualTo(AlertPolicy.maxBodyLength + 1));
    });
  });

  group('the notification identity', () {
    test('one conversation maps to one id', () {
      // The id is what makes a second message from the same person replace the
      // first alert instead of stacking a wall of them.
      final first = build(conversationKey: 'a.onion');
      final second = build(conversationKey: 'a.onion');
      expect(first!.notificationId, second!.notificationId);
    });

    test('different conversations do not collide', () {
      final a = build(conversationKey: 'a.onion');
      final b = build(conversationKey: 'b.onion');
      expect(a!.notificationId, isNot(b!.notificationId));
    });

    test('the id fits in a signed 32-bit integer', () {
      // Android rejects anything larger, and the failure is a dropped notification
      // rather than an error — which is exactly the kind of bug that survives to
      // production.
      for (final key in <String>['a.onion', 'b.onion', 'x' * 200]) {
        final id = build(conversationKey: key)!.notificationId;
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThanOrEqualTo(0x7fffffff));
      }
    });
  });

  group('the service itself', () {
    test('reports that it cannot show notifications on this platform', () {
      // The tests run on the build host, which is Windows here. Windows is the one
      // platform the plugin set has no implementation for, so the service has to say
      // so rather than pretend — that answer is what keeps the settings switch honest.
      final service = NotificationService();
      expect(service.isReady, isFalse);
      if (Platform.isWindows) {
        expect(NotificationService.isSupported, isFalse);
      }
    });

    test('initialising on an unsupported platform fails quietly', () async {
      // The failure has to be a false return, not an exception: this runs during
      // start-up, and a throw here would take the whole application with it.
      final service = NotificationService();
      final ready = await service.initialise();
      if (Platform.isWindows || Platform.isLinux) {
        expect(ready, isFalse);
      }
      expect(service.isReady, ready);
    });

    test('showing without initialisation does nothing, and does not throw',
        () async {
      // A message still has to be delivered even when it cannot be announced.
      final service = NotificationService();
      await service.show(const MessageAlert(
        conversationKey: 'a.onion',
        title: 'Alice',
        body: 'hi',
      ));
      await service.clear('a.onion');
      await service.clearAll();
    });
  });

  group('a message that is not built by the policy', () {
    test('the alert carries the conversation it belongs to', () {
      // This is the payload a tap returns, and it is how the tap finds the right
      // thread rather than the conversation list.
      final alert = build(conversationKey: 'someone.onion');
      expect(alert!.conversationKey, 'someone.onion');
    });

    test('a voice message kind is enough without an attachment record', () {
      // The attachment may not have arrived yet when the message is announced, so the
      // message's own kind has to be able to stand in.
      expect(build(isVoice: true, body: '').runtimeType, MessageAlert);
    });
  });

  group('the message model agrees about what a message is', () {
    test('a kind of voice is recognised', () {
      final message = Message(
        id: 'm',
        conversationId: 'c',
        peerOnion: 'p.onion',
        direction: MessageDirection.incoming,
        kind: MessageKind.voice,
        createdAt: DateTime.utc(2026),
        body: '',
      );
      expect(message.kind, MessageKind.voice);
      expect(message.preview, 'Voice message');
    });
  });
}
