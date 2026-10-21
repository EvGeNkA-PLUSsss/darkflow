import 'package:darkflow/src/tor/tor_control.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tor's bootstrap lines are parsed by hand, and a parse that quietly drops
/// half a field is invisible until it reaches a screen.
///
/// That is what happened: `SUMMARY="Connected to a relay"` is one field, but
/// splitting the line on spaces turned it into four tokens and left the summary
/// as `"Connected` — opening quote included — which is what the connection
/// screen displayed on a real device. These tests pin the real line format.
void main() {
  group('bootstrap phase parsing', () {
    test('a quoted summary keeps its spaces and loses its quotes', () {
      final phase = TorBootstrapPhase.parse(
        'NOTICE BOOTSTRAP PROGRESS=10 TAG=conn_done '
        'SUMMARY="Connected to a relay"',
      );
      expect(phase, isNotNull);
      expect(phase!.progress, 10);
      expect(phase.tag, 'conn_done');
      expect(phase.summary, 'Connected to a relay');
      // The bug, stated directly.
      expect(phase.summary, isNot(startsWith('"')));
      expect(phase.summary, isNot('"Connected'));
    });

    test('a single-word quoted summary loses its quotes too', () {
      final phase = TorBootstrapPhase.parse(
        'NOTICE BOOTSTRAP PROGRESS=2 TAG=conn_pt SUMMARY="Connecting"',
      );
      expect(phase!.summary, 'Connecting');
    });

    test('a summary with punctuation and digits survives intact', () {
      final phase = TorBootstrapPhase.parse(
        'NOTICE BOOTSTRAP PROGRESS=80 TAG=conn_done '
        'SUMMARY="Connecting to a relay in 3 hops (TLS)"',
      );
      expect(phase!.summary, 'Connecting to a relay in 3 hops (TLS)');
    });

    test('an unquoted value is read as-is', () {
      final phase = TorBootstrapPhase.parse(
        'NOTICE BOOTSTRAP PROGRESS=45 TAG=conn_or SUMMARY=Loading',
      );
      expect(phase!.summary, 'Loading');
    });

    test('WARN and ERR set the warning flag, NOTICE does not', () {
      const line = 'BOOTSTRAP PROGRESS=5 TAG=conn_pt SUMMARY="x"';
      expect(TorBootstrapPhase.parse('WARN $line')!.warning, isTrue);
      expect(TorBootstrapPhase.parse('ERR $line')!.warning, isTrue);
      expect(TorBootstrapPhase.parse('NOTICE $line')!.warning, isFalse);
    });

    test('the severity is recorded as sent', () {
      expect(
        TorBootstrapPhase.parse('WARN BOOTSTRAP PROGRESS=5 TAG=conn_pt')!.severity,
        'WARN',
      );
    });

    test('a line with no PROGRESS or no TAG is not a phase', () {
      expect(TorBootstrapPhase.parse('NOTICE BOOTSTRAP TAG=conn_pt'), isNull);
      expect(TorBootstrapPhase.parse('NOTICE BOOTSTRAP PROGRESS=10'), isNull);
      expect(TorBootstrapPhase.parse('NOTICE something else entirely'), isNull);
    });

    test('an empty or blank line is not a phase', () {
      expect(TorBootstrapPhase.parse(''), isNull);
      expect(TorBootstrapPhase.parse('   '), isNull);
    });

    test('a missing SUMMARY yields an empty string, not a crash', () {
      final phase = TorBootstrapPhase.parse('NOTICE BOOTSTRAP PROGRESS=100 TAG=done');
      expect(phase!.summary, isEmpty);
      expect(phase.isDone, isTrue);
    });

    test('progress is clamped into a fraction for the bar', () {
      expect(
        TorBootstrapPhase.parse('BOOTSTRAP PROGRESS=50 TAG=conn_or')!.fraction,
        0.5,
      );
    });

    test('the WARNING field is read, and is not the summary', () {
      // This is the line that explains a stuck bootstrap. Tor sends both
      // fields, and showing the summary in the danger colour printed "Connected
      // to a relay" twice while hiding the sentence that named the reason.
      final phase = TorBootstrapPhase.parse(
        'WARN BOOTSTRAP PROGRESS=10 TAG=conn_done '
        'SUMMARY="Connected to a relay" '
        'WARNING="Your network connection is working, but Tor cannot reach the '
        'rest of the network."',
      );
      expect(phase!.warning, isTrue);
      expect(phase.summary, 'Connected to a relay');
      expect(
        phase.warningMessage,
        'Your network connection is working, but Tor cannot reach the rest of '
        'the network.',
      );
      expect(phase.warningMessage, isNot(phase.summary));
    });

    test('a NOTICE line has no warning message', () {
      final phase = TorBootstrapPhase.parse(
        'NOTICE BOOTSTRAP PROGRESS=10 TAG=conn_done SUMMARY="Connected to a relay"',
      );
      expect(phase!.warning, isFalse);
      expect(phase.warningMessage, isNull);
    });
  });
}
