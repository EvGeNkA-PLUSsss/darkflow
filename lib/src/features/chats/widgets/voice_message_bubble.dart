import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// A voice note: a play control, the waveform, and the length.
///
/// The widget owns no player. Playback is expensive, platform specific and
/// resumable, so the app layer drives it and passes the state back in through
/// [playing] and [progress]; that keeps this file presentational. Playback
/// callbacks are preferred over an embedded player, and no audio code lives
/// here at all.
class VoiceMessageBubble extends StatelessWidget {
  const VoiceMessageBubble({
    required this.durationMs,
    required this.outgoing,
    this.waveform = const <int>[],
    this.playing = false,
    this.progress,
    this.onTogglePlayback,
    this.maxWidthFactor = AppMetrics.bubbleMaxWidthFactor,
    super.key,
  });

  /// Length of the recording in milliseconds; rendered as `mm:ss`.
  final int durationMs;

  /// Accent fill for the account's own notes, surface fill for the peer's.
  final bool outgoing;

  /// Normalised 0..100 amplitude buckets. May be empty, in which case the
  /// waveform is drawn flat — the shape is simply unknown, and inventing one
  /// would be a lie.
  final List<int> waveform;

  final bool playing;

  /// How much of the note has been heard, 0..1. Null means "nothing yet".
  final double? progress;

  /// Starts or stops playback; the parent owns the player. When null the pill
  /// is not tappable at all rather than silently swallowing taps.
  final VoidCallback? onTogglePlayback;

  /// Share of the row's free width the pill may take.
  final double maxWidthFactor;

  /// The pill width measured from `Chat.svg` (x 69..280 on a 390 pt canvas).
  static const double pillWidth = 211;

  /// The pill height from the same measurement.
  static const double pillHeight = 40;

  /// The play/pause control's diameter.
  static const double _controlSize = 28;

  @override
  Widget build(BuildContext context) {
    final fill = outgoing ? AppColors.accent : AppColors.surface;
    final foreground = outgoing ? AppColors.textOnAccent : AppColors.textPrimary;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final available = constraints.maxWidth;
        final ceiling = available.isFinite ? available * maxWidthFactor : double.infinity;
        final width = math.min(pillWidth, ceiling);

        // A play glyph that cannot be tapped invites the tap and swallows it.
        //
        // When `onTogglePlayback` is null the pill is not a control at all, so it
        // says so: a muted disc and a plain cursor instead of a bright white play
        // button that does nothing. `_PlayControl` is handed the state rather than
        // deciding it, because only this widget knows whether there is a callback.
        final playable = onTogglePlayback != null;

        return MouseRegion(
          cursor: playable ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTogglePlayback,
            child: Container(
              width: width,
              height: pillHeight,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(AppMetrics.bubbleRadius),
              ),
              child: Row(
                children: [
                  _PlayControl(
                    playing: playing,
                    size: _controlSize,
                    playable: playable,
                    outgoing: outgoing,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Waveform(
                      values: waveform,
                      progress: progress ?? 0,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDuration(durationMs),
                    style: AppTypography.body.copyWith(fontSize: 15, color: foreground),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// `mm:ss`, matching [Attachment.readableDuration] so a voice note and its
  /// attachment row never disagree.
  static String _formatDuration(int milliseconds) {
    final totalSeconds = (milliseconds / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// The disc holding a play triangle or a pause bar.
class _PlayControl extends StatelessWidget {
  const _PlayControl({
    required this.playing,
    required this.size,
    required this.playable,
    required this.outgoing,
  });

  final bool playing;
  final double size;

  /// False when there is no playback callback, which mutes the disc.
  final bool playable;

  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: playable ? AppColors.textPrimary : AppColors.surfaceHigh,
        shape: BoxShape.circle,
      ),
      // The glyph stays accent-coloured on the white disc whichever way the
      // pill is filled: the disc is the one bright element in the row.
      child: playable
          ? Icon(
              playing ? Icons.pause : Icons.play_arrow,
              size: 18,
              color: AppColors.accent,
            )
          : Icon(
              Icons.play_arrow,
              size: 18,
              color: outgoing
                  ? AppColors.textOnAccent.withValues(alpha: 0.5)
                  : AppColors.textSecondary,
            ),
    );
  }
}

/// The amplitude bars, resampled to whatever width the pill has.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.values, required this.progress, required this.color});

  final List<int> values;
  final double progress;
  final Color color;

  static const double _barWidth = 2;
  static const double _gap = 2;
  static const double _maxBarHeight = 20;
  static const double _minBarHeight = 3;

  /// A flat fallback sits slightly above the minimum so it still reads as a
  /// waveform rather than as a rule.
  static const double _flatBarHeight = 6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final slots = math.max(
          1,
          ((constraints.maxWidth + _gap) / (_barWidth + _gap)).floor(),
        );
        final heights = _resample(slots);
        final played = (progress.clamp(0.0, 1.0) * heights.length).round();

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < heights.length; i++)
              Container(
                width: _barWidth,
                height: heights[i],
                decoration: BoxDecoration(
                  color: color.withValues(alpha: i < played ? 0.85 : 0.35),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Fits [values] into exactly [slots] bars by averaging each bucket, so a
  /// short recording on a wide screen and a long one on a narrow screen both
  /// fill the pill without distorting the shape.
  List<double> _resample(int slots) {
    if (values.isEmpty) return List<double>.filled(slots, _flatBarHeight);

    final bars = <double>[];
    for (var i = 0; i < slots; i++) {
      final start = (i * values.length / slots).floor();
      final end = math.max(start + 1, ((i + 1) * values.length / slots).floor());
      var total = 0;
      var count = 0;
      for (var j = start; j < end && j < values.length; j++) {
        total += values[j];
        count++;
      }
      final average = count == 0 ? 0.0 : total / count;
      final height = average.clamp(0.0, 100.0) / 100 * _maxBarHeight;
      bars.add(height.clamp(_minBarHeight, _maxBarHeight));
    }
    return bars;
  }
}
