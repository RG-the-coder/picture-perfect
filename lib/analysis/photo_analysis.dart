/// How quickly a coaching instruction should be addressed.
enum CoachingPriority {
  /// A severe issue likely to ruin the photograph.
  urgent,

  /// A large, immediately visible quality issue.
  high,

  /// A worthwhile adjustment that noticeably improves the photograph.
  medium,

  /// A finishing touch or a reminder to preserve an already-good setting.
  low,
}

/// The camera-preview overlay best suited to a coaching instruction.
enum OverlayType {
  none,
  ruleOfThirds,
  subjectGuide,
  level,
  exposure,
  focus,
  colorBalance,
}

/// One concise adjustment the photographer can make before taking the photo.
final class CoachingStep {
  const CoachingStep({
    required this.title,
    required this.instruction,
    required this.priority,
    required this.overlay,
  });

  final String title;
  final String instruction;
  final CoachingPriority priority;
  final OverlayType overlay;

  factory CoachingStep.fromJson(Object? value) {
    final map = _jsonObject(value, 'coaching step');
    _requireExactKeys(map, const {
      'title',
      'instruction',
      'priority',
      'overlay',
    });
    return CoachingStep(
      title: _nonEmptyString(map['title'], 'title'),
      instruction: _nonEmptyString(map['instruction'], 'instruction'),
      priority: _priority(map['priority']),
      overlay: _overlay(map['overlay']),
    );
  }
}

/// Scores and ordered coaching returned for a single image or video frame.
///
/// Every score is an integer in `0..100`. [steps] is ordered from the most
/// important adjustment to the least important and always contains 3 or 4
/// entries.
final class PhotoAnalysis {
  PhotoAnalysis({
    required this.overallScore,
    required this.compositionScore,
    required this.lightingScore,
    required this.clarityScore,
    required this.colorScore,
    required List<CoachingStep> steps,
  }) : steps = List<CoachingStep>.unmodifiable(steps) {
    _requireScore(overallScore, 'overallScore');
    _requireScore(compositionScore, 'compositionScore');
    _requireScore(lightingScore, 'lightingScore');
    _requireScore(clarityScore, 'clarityScore');
    _requireScore(colorScore, 'colorScore');
    if (this.steps.length < 3 || this.steps.length > 4) {
      throw ArgumentError.value(
        this.steps.length,
        'steps',
        'Must contain 3 or 4 coaching steps.',
      );
    }
  }

  final int overallScore;
  final int compositionScore;
  final int lightingScore;
  final int clarityScore;
  final int colorScore;
  final List<CoachingStep> steps;

  factory PhotoAnalysis.fromJson(Object? value) {
    final map = _jsonObject(value, 'photo analysis');
    _requireExactKeys(map, const {
      'overallScore',
      'compositionScore',
      'lightingScore',
      'clarityScore',
      'colorScore',
      'steps',
    });
    final rawSteps = map['steps'];
    if (rawSteps is! List<Object?> || rawSteps.length != 3) {
      throw const FormatException('steps must contain exactly 3 objects');
    }
    return PhotoAnalysis(
      overallScore: _score(map['overallScore'], 'overallScore'),
      compositionScore: _score(map['compositionScore'], 'compositionScore'),
      lightingScore: _score(map['lightingScore'], 'lightingScore'),
      clarityScore: _score(map['clarityScore'], 'clarityScore'),
      colorScore: _score(map['colorScore'], 'colorScore'),
      steps: rawSteps.map(CoachingStep.fromJson).toList(growable: false),
    );
  }

  static void _requireScore(int score, String name) {
    if (score < 0 || score > 100) {
      throw ArgumentError.value(score, name, 'Must be within 0..100.');
    }
  }
}

Map<String, Object?> _jsonObject(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be a JSON object');
  }
  return value;
}

void _requireExactKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.length != expected.length || !map.keys.every(expected.contains)) {
    throw const FormatException('JSON object has an unexpected shape');
  }
}

int _score(Object? value, String name) {
  if (value is! int || value < 0 || value > 100) {
    throw FormatException('$name must be an integer within 0..100');
  }
  return value;
}

String _nonEmptyString(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string');
  }
  return value.trim();
}

CoachingPriority _priority(Object? value) => switch (value) {
  'urgent' => CoachingPriority.urgent,
  'high' => CoachingPriority.high,
  'medium' => CoachingPriority.medium,
  'low' => CoachingPriority.low,
  _ => throw const FormatException('priority is not supported'),
};

OverlayType _overlay(Object? value) => switch (value) {
  'none' => OverlayType.none,
  'ruleOfThirds' => OverlayType.ruleOfThirds,
  'subjectGuide' => OverlayType.subjectGuide,
  'level' => OverlayType.level,
  'exposure' => OverlayType.exposure,
  'focus' => OverlayType.focus,
  'colorBalance' => OverlayType.colorBalance,
  _ => throw const FormatException('overlay is not supported'),
};
