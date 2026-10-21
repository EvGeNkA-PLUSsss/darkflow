import 'package:darkflow/src/data/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records written by a build that had reactions must still load.
///
/// Reactions were built, tested and then removed at the user's request. The one thing
/// that cannot simply be deleted is the reader: message records are the user's history,
/// and a version that throws on a field it once wrote is a version that loses that
/// history. `Message.fromJson` therefore still parses `reactions` and drops it.
///
/// Deleting the parser would be the tidier diff and the worse product. This test exists
/// so the next person to tidy it up has to delete a passing test that says why not.
void main() {
  Message base() => Message(
        id: 'm1',
        conversationId: 'c1',
        peerOnion: 'peer.onion',
        direction: MessageDirection.incoming,
        kind: MessageKind.text,
        createdAt: DateTime.utc(2026),
        body: 'hello',
      );

  test('a record carrying reactions still loads', () {
    final json = base().toJson();
    // Exactly what the removed build wrote.
    json['reactions'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'emoji': '👍',
        'by': 'someone.onion',
        'at': DateTime.utc(2026, 3, 4).millisecondsSinceEpoch,
      },
    ];

    final restored = Message.fromJson(json);
    expect(restored.body, 'hello');
    expect(restored.reactions, hasLength(1));
    expect(restored.reactions.single.emoji, '👍');
    expect(restored.reactions.single.byOnion, 'someone.onion');
  });

  test('a malformed reactions field does not break the record', () {
    // Comes off the disk, so it has to survive being wrong: a record written by a
    // partially failed migration, or by hand.
    final json = base().toJson();
    json['reactions'] = <dynamic>['not a map', 42, null];

    final restored = Message.fromJson(json);
    expect(restored.body, 'hello');
    expect(restored.reactions, isEmpty);
  });

  test('a record with no reactions field loads', () {
    final json = base().toJson()..remove('reactions');
    expect(Message.fromJson(json).reactions, isEmpty);
  });

  test('the field is never written back', () {
    // The only thing being deleted is the writer. A message saved by this build must not
    // reintroduce the field, or the records would keep carrying a dead key for ever.
    expect(base().toJson().containsKey('reactions'), isFalse);
  });

  test('a reaction round-trips through its own codec', () {
    // Kept because it is what parses the stored field.
    final reaction = Reaction.fromJson(<String, dynamic>{
      'emoji': '❤️',
      'by': 'a.onion',
      'at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
    });
    expect(reaction.emoji, '❤️');
    expect(reaction.byOnion, 'a.onion');
    expect(reaction.at, DateTime.utc(2026, 5, 1));
    expect(reaction.toJson()['emoji'], '❤️');
  });
}
