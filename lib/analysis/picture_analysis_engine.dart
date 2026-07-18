import 'dart:math' as math;

import 'image_stats.dart';
import 'photo_analysis.dart';

/// Deterministic, dependency-free scoring and coaching for a photograph.
///
/// The engine is deliberately stateless, so the same instance can analyze
/// uploaded photos or be reused for a stream of preview-frame statistics.
final class PictureAnalysisEngine {
  const PictureAnalysisEngine();

  PhotoAnalysis analyze(ImageStats stats) {
    final measurements = _score(stats);
    final steps = _buildSteps(stats, measurements);

    return PhotoAnalysis(
      overallScore: measurements.overall.round(),
      compositionScore: measurements.composition.round(),
      lightingScore: measurements.lighting.round(),
      clarityScore: measurements.clarity.round(),
      colorScore: measurements.color.round(),
      steps: steps,
    );
  }

  _Measurements _score(ImageStats stats) {
    final distanceToThirds = _distance(
      stats.subjectX,
      stats.subjectY,
      _nearestThird(stats.subjectX),
      _nearestThird(stats.subjectY),
    );
    final distanceToCenter = _distance(
      stats.subjectX,
      stats.subjectY,
      0.5,
      0.5,
    );

    // Both centered symmetry and rule-of-thirds placement can be intentional.
    // The rule-of-thirds target receives the slightly higher ceiling.
    final thirdsPlacement = 100 - (distanceToThirds * 180);
    final centeredPlacement = 92 - (distanceToCenter * 180);
    final placement = math
        .max(thirdsPlacement, centeredPlacement)
        .clamp(0, 100);
    final nearestEdge = math.min(
      math.min(stats.subjectX, 1 - stats.subjectX),
      math.min(stats.subjectY, 1 - stats.subjectY),
    );
    final edgeSafety = (nearestEdge / 0.12 * 100).clamp(0, 100);

    final tilt = stats.horizonTiltDegrees;
    final level = tilt == null
        ? null
        : (100 - ((_absolute(tilt) - 1).clamp(0, 11) / 11 * 100)).clamp(0, 100);
    final composition = level == null
        ? (placement * 0.85) + (edgeSafety * 0.15)
        : (placement * 0.72) + (edgeSafety * 0.13) + (level * 0.15);

    final exposure = _plateauScore(
      stats.brightness,
      idealStart: 0.45,
      idealEnd: 0.60,
      lowerLimit: 0,
      upperLimit: 1,
    );
    final contrast = _plateauScore(
      stats.contrast,
      idealStart: 0.38,
      idealEnd: 0.68,
      lowerLimit: 0.05,
      upperLimit: 0.95,
    );
    final clipping =
        (100 - ((stats.highlightClipping + stats.shadowClipping) * 350)).clamp(
          0,
          100,
        );
    final lighting = (exposure * 0.50) + (contrast * 0.20) + (clipping * 0.30);

    final detail = (stats.sharpness / 0.85 * 100).clamp(0, 100);
    final cleanliness = ((1 - stats.noise) * 100).clamp(0, 100);
    final clarity = (detail * 0.78) + (cleanliness * 0.22);

    final saturation = _plateauScore(
      stats.saturation,
      idealStart: 0.32,
      idealEnd: 0.68,
      lowerLimit: 0,
      upperLimit: 1,
    );
    final neutrality = ((1 - stats.colorCast) * 100).clamp(0, 100);
    final color = (saturation * 0.65) + (neutrality * 0.35);

    final overall =
        (composition * 0.30) +
        (lighting * 0.30) +
        (clarity * 0.25) +
        (color * 0.15);

    return _Measurements(
      overall: overall.clamp(0, 100).toDouble(),
      composition: composition.clamp(0, 100).toDouble(),
      lighting: lighting.clamp(0, 100).toDouble(),
      clarity: clarity.clamp(0, 100).toDouble(),
      color: color.clamp(0, 100).toDouble(),
      placement: placement.toDouble(),
      edgeSafety: edgeSafety.toDouble(),
      level: level?.toDouble(),
      exposure: exposure,
      contrast: contrast,
      clipping: clipping.toDouble(),
      detail: detail.toDouble(),
      cleanliness: cleanliness.toDouble(),
      saturation: saturation,
      neutrality: neutrality.toDouble(),
    );
  }

  List<CoachingStep> _buildSteps(ImageStats stats, _Measurements measurements) {
    final candidates = <_Candidate>[];

    _addCompositionCandidates(candidates, stats, measurements);
    _addLightingCandidates(candidates, stats, measurements);
    _addClarityCandidates(candidates, stats, measurements);
    _addColorCandidates(candidates, stats, measurements);

    // Stable sorting prevents coaching cards from jumping around when two
    // consecutive real-time frames have almost identical measurements.
    candidates.sort((a, b) {
      final priorityComparison = a.priority.index.compareTo(b.priority.index);
      if (priorityComparison != 0) return priorityComparison;
      final severityComparison = b.severity.compareTo(a.severity);
      if (severityComparison != 0) return severityComparison;
      return a.order.compareTo(b.order);
    });

    final selected = <CoachingStep>[];
    final usedOverlays = <OverlayType>{};
    for (final candidate in candidates) {
      // Avoid showing two cards that ask the user to manipulate the same guide.
      if (usedOverlays.contains(candidate.step.overlay)) continue;
      selected.add(candidate.step);
      usedOverlays.add(candidate.step.overlay);
      if (selected.length == 4) break;
    }

    final fallbacks = _fallbackSteps(stats);
    for (final step in fallbacks) {
      if (selected.length >= 3) break;
      if (usedOverlays.add(step.overlay)) selected.add(step);
    }

    return selected;
  }

  void _addCompositionCandidates(
    List<_Candidate> candidates,
    ImageStats stats,
    _Measurements measurements,
  ) {
    final tilt = stats.horizonTiltDegrees;
    if (tilt != null && _absolute(tilt) > 1.5) {
      final correction = _formatDecimal(_absolute(tilt), max: 15);
      final direction = tilt > 0 ? 'counter-clockwise' : 'clockwise';
      _addCandidate(
        candidates,
        severity: (100 - measurements.level!).clamp(0, 100).toDouble(),
        order: 0,
        title: 'Level the horizon',
        instruction:
            'Rotate the camera $correction° $direction until the level line is centered.',
        overlay: OverlayType.level,
      );
    }

    if (measurements.placement < 84 || measurements.edgeSafety < 70) {
      final targetX = _nearestThird(stats.subjectX);
      final targetY = _nearestThird(stats.subjectY);
      final horizontal = _movement(stats.subjectX, targetX, horizontal: true);
      final vertical = _movement(stats.subjectY, targetY, horizontal: false);
      final movement = [horizontal, vertical].whereType<String>().join(' and ');
      _addCandidate(
        candidates,
        severity: math.max(
          100 - measurements.placement,
          100 - measurements.edgeSafety,
        ),
        order: 1,
        title: 'Place the subject on thirds',
        instruction:
            'Shift the framing so the subject moves $movement onto the nearest grid intersection.',
        overlay: OverlayType.ruleOfThirds,
      );
    }
  }

  void _addLightingCandidates(
    List<_Candidate> candidates,
    ImageStats stats,
    _Measurements measurements,
  ) {
    if (stats.brightness < 0.42) {
      final stops = _exposureStops(stats.brightness, 0.50);
      _addCandidate(
        candidates,
        severity: 100 - measurements.exposure,
        order: 2,
        title: 'Brighten the exposure',
        instruction:
            'Raise exposure by $stops EV, then keep the meter just below the center mark.',
        overlay: OverlayType.exposure,
      );
    } else if (stats.brightness > 0.64) {
      final stops = _exposureStops(0.54, stats.brightness);
      _addCandidate(
        candidates,
        severity: 100 - measurements.exposure,
        order: 2,
        title: 'Reduce the exposure',
        instruction:
            'Lower exposure by $stops EV, then keep the meter just below the center mark.',
        overlay: OverlayType.exposure,
      );
    } else if (stats.highlightClipping > 0.025) {
      final amount = stats.highlightClipping > 0.12 ? '0.7' : '0.3';
      _addCandidate(
        candidates,
        severity: (100 - measurements.clipping).clamp(0, 100).toDouble(),
        order: 3,
        title: 'Recover bright detail',
        instruction:
            'Lower exposure by $amount EV until the highlight warning disappears.',
        overlay: OverlayType.exposure,
      );
    } else if (stats.shadowClipping > 0.035) {
      _addCandidate(
        candidates,
        severity: (100 - measurements.clipping).clamp(0, 100).toDouble(),
        order: 3,
        title: 'Open the shadows',
        instruction:
            'Turn the subject toward the main light or add fill light from camera-left.',
        overlay: OverlayType.exposure,
      );
    }

    if (stats.contrast < 0.30) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.contrast,
        order: 4,
        title: 'Add tonal separation',
        instruction:
            'Move 30° to one side of the main light so it creates visible highlights and shadows.',
        overlay: OverlayType.subjectGuide,
      );
    } else if (stats.contrast > 0.76) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.contrast,
        order: 4,
        title: 'Soften the contrast',
        instruction:
            'Move the subject into open shade or place a white reflector opposite the main light.',
        overlay: OverlayType.subjectGuide,
      );
    }
  }

  void _addClarityCandidates(
    List<_Candidate> candidates,
    ImageStats stats,
    _Measurements measurements,
  ) {
    if (stats.sharpness < 0.70) {
      final focusPoint = _focusPoint(stats);
      _addCandidate(
        candidates,
        severity: 100 - measurements.detail,
        order: 5,
        title: 'Lock focus on the subject',
        instruction:
            'Tap $focusPoint, brace both elbows, and wait for focus lock before shooting.',
        overlay: OverlayType.focus,
      );
    }

    if (stats.noise > 0.18) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.cleanliness,
        order: 6,
        title: 'Reduce visible noise',
        instruction:
            'Add light to the subject, then lower ISO one step while keeping the camera steady.',
        overlay: OverlayType.none,
      );
    }
  }

  void _addColorCandidates(
    List<_Candidate> candidates,
    ImageStats stats,
    _Measurements measurements,
  ) {
    if (stats.colorCast > 0.12) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.neutrality,
        order: 7,
        title: 'Neutralize the color cast',
        instruction:
            'Aim at a neutral white or gray surface and lock white balance before reframing.',
        overlay: OverlayType.colorBalance,
      );
    } else if (stats.saturation < 0.27) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.saturation,
        order: 8,
        title: 'Strengthen the color',
        instruction:
            'Move the subject toward clean daylight and avoid mixing indoor and window light.',
        overlay: OverlayType.colorBalance,
      );
    } else if (stats.saturation > 0.74) {
      _addCandidate(
        candidates,
        severity: 100 - measurements.saturation,
        order: 8,
        title: 'Tame intense color',
        instruction:
            'Switch to a neutral color profile and reduce saturation by 10% before capture.',
        overlay: OverlayType.colorBalance,
      );
    }
  }

  List<CoachingStep> _fallbackSteps(ImageStats stats) {
    return [
      CoachingStep(
        title: 'Lock focus precisely',
        instruction:
            'Tap ${_focusPoint(stats)} and wait for the focus indicator to stop pulsing.',
        priority: CoachingPriority.low,
        overlay: OverlayType.focus,
      ),
      const CoachingStep(
        title: 'Keep the camera level',
        instruction:
            'Match the horizon to the level guide and hold it within 1° of center.',
        priority: CoachingPriority.low,
        overlay: OverlayType.level,
      ),
      const CoachingStep(
        title: 'Protect highlight detail',
        instruction:
            'Hold the exposure where it is and confirm no highlight warning is visible.',
        priority: CoachingPriority.low,
        overlay: OverlayType.exposure,
      ),
      const CoachingStep(
        title: 'Take the clean frame',
        instruction:
            'Brace both elbows, exhale slowly, and press the shutter without moving the camera.',
        priority: CoachingPriority.low,
        overlay: OverlayType.none,
      ),
    ];
  }

  void _addCandidate(
    List<_Candidate> candidates, {
    required double severity,
    required int order,
    required String title,
    required String instruction,
    required OverlayType overlay,
  }) {
    final normalizedSeverity = severity.clamp(0, 100).toDouble();
    candidates.add(
      _Candidate(
        severity: normalizedSeverity,
        order: order,
        priority: _priorityFor(normalizedSeverity),
        step: CoachingStep(
          title: title,
          instruction: instruction,
          priority: _priorityFor(normalizedSeverity),
          overlay: overlay,
        ),
      ),
    );
  }

  CoachingPriority _priorityFor(double severity) {
    if (severity >= 72) return CoachingPriority.urgent;
    if (severity >= 45) return CoachingPriority.high;
    if (severity >= 22) return CoachingPriority.medium;
    return CoachingPriority.low;
  }

  static double _plateauScore(
    double value, {
    required double idealStart,
    required double idealEnd,
    required double lowerLimit,
    required double upperLimit,
  }) {
    if (value >= idealStart && value <= idealEnd) return 100;
    if (value < idealStart) {
      return ((value - lowerLimit) / (idealStart - lowerLimit) * 100)
          .clamp(0, 100)
          .toDouble();
    }
    return ((upperLimit - value) / (upperLimit - idealEnd) * 100)
        .clamp(0, 100)
        .toDouble();
  }

  static double _nearestThird(double value) => value <= 0.5 ? 1 / 3 : 2 / 3;

  static double _distance(double x1, double y1, double x2, double y2) =>
      math.sqrt(math.pow(x1 - x2, 2) + math.pow(y1 - y2, 2));

  static double _absolute(double value) => value.abs().toDouble();

  static String? _movement(
    double current,
    double target, {
    required bool horizontal,
  }) {
    final delta = target - current;
    final percent = (_absolute(delta) * 100).round();
    if (percent < 2) return null;
    final direction = horizontal
        ? (delta < 0 ? 'left' : 'right')
        : (delta < 0 ? 'up' : 'down');
    return '$percent% $direction';
  }

  static String _focusPoint(ImageStats stats) {
    final x = (stats.subjectX * 100).round();
    final y = (stats.subjectY * 100).round();
    return 'the subject at $x% from the left and $y% from the top';
  }

  static String _exposureStops(double darker, double brighter) {
    final safeDarker = math.max(darker, 0.03);
    final stops = (math.log(brighter / safeDarker) / math.ln2)
        .clamp(0.3, 2.0)
        .toDouble();
    return _formatDecimal(stops);
  }

  static String _formatDecimal(double value, {double? max}) {
    final limited = max == null ? value : math.min(value, max);
    return limited.toStringAsFixed(1);
  }
}

final class _Measurements {
  const _Measurements({
    required this.overall,
    required this.composition,
    required this.lighting,
    required this.clarity,
    required this.color,
    required this.placement,
    required this.edgeSafety,
    required this.level,
    required this.exposure,
    required this.contrast,
    required this.clipping,
    required this.detail,
    required this.cleanliness,
    required this.saturation,
    required this.neutrality,
  });

  final double overall;
  final double composition;
  final double lighting;
  final double clarity;
  final double color;
  final double placement;
  final double edgeSafety;
  final double? level;
  final double exposure;
  final double contrast;
  final double clipping;
  final double detail;
  final double cleanliness;
  final double saturation;
  final double neutrality;
}

final class _Candidate {
  const _Candidate({
    required this.severity,
    required this.order,
    required this.priority,
    required this.step,
  });

  final double severity;
  final int order;
  final CoachingPriority priority;
  final CoachingStep step;
}
