import 'package:darkflow/src/features/auth/qr_scanner_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading an onion address out of whatever a QR code contains.
///
/// The scanner does not control what is printed on the other screen, so this is the
/// part with rules: which strings become a contact, and which are refused. Refusing
/// silently would leave a user pointing a camera at a code for ever with nothing to
/// correct, which is why the screen reports the text it read.
void main() {
  /// A valid v3 address: 56 base32 characters.
  ///
  /// Spelled out rather than assembled from a repeated alphabet, so the length is
  /// visible and the `setUp` assertion below is checking a fact rather than
  /// restating an expression. The alphabet is 32 characters and contains no `0`,
  /// `1`, `8` or `9`, which is exactly what base32 omits.
  const v3 = 'abcdefghijklmnopqrstuvwxyz234567'
      'abcdefghijklmnopqrstuabc';
  const v3Full = '$v3.onion';
  /// A valid v2 address: 16 base32 characters.
  const v2Full = 'abcdefghijklmnop.onion';

  setUp(() {
    expect(v3.length, OnionAddressParser.v3Length,
        reason: 'the fixture must be a real v3 length');
    expect('abcdefghijklmnop'.length, OnionAddressParser.v2Length);
    // And it must be all base32, or the accepted cases would be testing the
    // alphabet check rather than the parsing.
    expect(RegExp(r'^[a-z2-7]+$').hasMatch(v3), isTrue);
  });

  group('a bare address is accepted', () {
    test('v3', () => expect(OnionAddressParser.extract(v3Full), v3Full));
    test('v2', () => expect(OnionAddressParser.extract(v2Full), v2Full));
    test('surrounding whitespace', () {
      expect(OnionAddressParser.extract('  $v3Full\n'), v3Full);
    });
    test('uppercase is normalised', () {
      // Base32 is case-insensitive, and a code printed by hand may be upper case.
      expect(OnionAddressParser.extract('${v3.toUpperCase()}.ONION'), v3Full);
    });
  });

  group('the forms a copied link takes are accepted', () {
    test('https with a trailing slash', () {
      expect(OnionAddressParser.extract('https://$v3Full/'), v3Full);
    });
    test('http with a path', () {
      expect(OnionAddressParser.extract('http://$v3Full/some/page'), v3Full);
    });
    test('a query string is not part of the address', () {
      expect(OnionAddressParser.extract('$v3Full?x=1'), v3Full);
    });
    test('a fragment is not part of the address', () {
      expect(OnionAddressParser.extract('$v3Full#top'), v3Full);
    });
    test('the onion scheme', () {
      expect(OnionAddressParser.extract('onion:$v3Full'), v3Full);
    });
    test('a scheme-relative link', () {
      expect(OnionAddressParser.extract('//$v3Full'), v3Full);
    });
    test('user info is dropped', () {
      // A pasted URL from a browser can carry credentials; they are not the host.
      expect(OnionAddressParser.extract('https://user@$v3Full/'), v3Full);
    });
    test('a port is dropped', () {
      expect(OnionAddressParser.extract('$v3Full:8080'), v3Full);
    });
  });

  group('anything that is not an onion address is refused', () {
    test('empty', () => expect(OnionAddressParser.extract('   '), isNull));
    test('a plain web address', () {
      expect(OnionAddressParser.extract('https://example.com'), isNull);
    });
    test('an onion address of the wrong length', () {
      expect(OnionAddressParser.extract('tooshort.onion'), isNull);
      expect(OnionAddressParser.extract('${v3}a.onion'), isNull);
    });
    test('a non-base32 character', () {
      // `0`, `1`, `8` and `9` are not in the base32 alphabet; accepting them would
      // store a contact that can never be reached. This one is the right length and
      // has the right suffix, so only the alphabet check can reject it.
      const broken = 'abcdefghijklmnopqrstuvwxyz0123456789'
          'abcdefghijklmnopqrst';
      expect(broken.length, OnionAddressParser.v3Length);
      expect(OnionAddressParser.extract('$broken.onion'), isNull);
    });
    test('the suffix missing', () {
      expect(OnionAddressParser.extract(v3), isNull);
    });
    test('a sentence that merely mentions one', () {
      // A code carrying prose is not an address; taking the first word would guess.
      expect(OnionAddressParser.extract('add me at $v3Full please'), isNull);
    });
    test('arbitrary text', () {
      expect(OnionAddressParser.extract('hello world'), isNull);
      expect(OnionAddressParser.extract('12345'), isNull);
    });
  });

  group('the result is always a bare address', () {
    test('every accepted form collapses to one string', () {
      // What gets stored must not depend on how the code was printed.
      final forms = <String>[
        v3Full,
        '  $v3Full  ',
        '${v3.toUpperCase()}.onion',
        'https://$v3Full',
        'https://$v3Full/',
        'http://$v3Full/path?a=b#c',
        'onion:$v3Full',
        '//$v3Full',
        'https://u@$v3Full:1234/x',
      ];
      for (final form in forms) {
        expect(OnionAddressParser.extract(form), v3Full, reason: 'form: $form');
      }
    });
  });
}
