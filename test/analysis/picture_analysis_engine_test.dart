import 'package:flutter_test/flutter_test.dart';
import 'package:picture_perfect/analysis/picture_analysis.dart';

void main() {
  const engine = PictureAnalysisEngine();

  group('ImageStats', () {
    test('accepts normalized values and an omitted horizon', () {
      final stats = idealStats(horizonTiltDegrees: null);

      expect(stats.width, 1920);
      expect(stats.height, 1080);
      expect(stats.noise, 0);
      expect(stats.colorCast, 0);
      expect(stats.horizonTiltDegrees, isNull);
    });

    test('rejects non-positive dimensions', () {
      expect(() => idealStats(width: 0), throwsArgumentError);
      expect(() => idealStats(height: -1), throwsArgumentError);
    });

    test('rejects every normalized value outside 0..1', () {
      expect(() => idealStats(brightness: -0.01), throwsArgumentError);
      expect(() => idealStats(contrast: 1.01), throwsArgumentError);
      expect(() => idealStats(sharpness: double.nan), throwsArgumentError);
      expect(
        () => idealStats(saturation: double.infinity),
        throwsArgumentError,
      );
      expect(() => idealStats(highlightClipping: -1), throwsArgumentError);
      expect(() => idealStats(shadowClipping: 2), throwsArgumentError);
      expect(() => idealStats(subjectX: -0.01), throwsArgumentError);
      expect(() => idealStats(subjectY: 1.01), throwsArgumentError);
      expect(() => idealStats(noise: -0.01), throwsArgumentError);
      expect(() => idealStats(colorCast: 1.01), throwsArgumentError);
    });

    test('allows boundary values and rejects a non-finite horizon', () {
      expect(() => idealStats(brightness: 0, saturation: 1), returnsNormally);
      expect(
        () => idealStats(horizonTiltDegrees: double.negativeInfinity),
        throwsArgumentError,
      );
    });
  });

  group('scores', () {
    test('gives an ideal frame perfect category and overall scores', () {
      final result = engine.analyze(idealStats());

      expect(result.overallScore, 100);
      expect(result.compositionScore, 100);
      expect(result.lightingScore, 100);
      expect(result.clarityScore, 100);
      expect(result.colorScore, 100);
    });

    test('keeps all scores in 0..100 for worst-case boundary input', () {
      final result = engine.analyze(
        idealStats(
          brightness: 0,
          contrast: 0,
          sharpness: 0,
          saturation: 1,
          highlightClipping: 1,
          shadowClipping: 1,
          subjectX: 0,
          subjectY: 1,
          noise: 1,
          colorCast: 1,
          horizonTiltDegrees: 180,
        ),
      );

      for (final score in [
        result.overallScore,
        result.compositionScore,
        result.lightingScore,
        result.clarityScore,
        result.colorScore,
      ]) {
        expect(score, inInclusiveRange(0, 100));
      }
      expect(result.steps.length, inInclusiveRange(3, 4));
    });

    test('treats centered and rule-of-thirds placement as intentional', () {
      final thirds = engine.analyze(idealStats());
      final centered = engine.analyze(idealStats(subjectX: 0.5, subjectY: 0.5));

      expect(thirds.compositionScore, 100);
      expect(centered.compositionScore, greaterThanOrEqualTo(90));
      expect(thirds.compositionScore, greaterThan(centered.compositionScore));
    });

    test('penalizes subjects touching an edge', () {
      final safe = engine.analyze(idealStats());
      final edge = engine.analyze(idealStats(subjectX: 0.01, subjectY: 0.5));

      expect(edge.compositionScore, lessThan(safe.compositionScore - 40));
    });

    test('penalizes a tilted detected horizon but not a missing horizon', () {
      final level = engine.analyze(idealStats(horizonTiltDegrees: 0));
      final tilted = engine.analyze(idealStats(horizonTiltDegrees: 12));
      final unknown = engine.analyze(idealStats(horizonTiltDegrees: null));

      expect(tilted.compositionScore, lessThan(level.compositionScore));
      expect(unknown.compositionScore, level.compositionScore);
    });

    test('lighting responds independently to exposure and clipping', () {
      final good = engine.analyze(idealStats());
      final dark = engine.analyze(idealStats(brightness: 0.12));
      final clipped = engine.analyze(
        idealStats(highlightClipping: 0.25, shadowClipping: 0.10),
      );

      expect(dark.lightingScore, lessThan(good.lightingScore));
      expect(clipped.lightingScore, lessThan(good.lightingScore));
      expect(dark.compositionScore, good.compositionScore);
      expect(clipped.clarityScore, good.clarityScore);
    });

    test('clarity rewards sharp detail and low noise', () {
      final clean = engine.analyze(idealStats());
      final blurry = engine.analyze(idealStats(sharpness: 0.10));
      final noisy = engine.analyze(idealStats(noise: 0.80));

      expect(blurry.clarityScore, lessThan(clean.clarityScore - 50));
      expect(noisy.clarityScore, lessThan(clean.clarityScore));
      expect(blurry.lightingScore, clean.lightingScore);
    });

    test('color rewards moderate saturation and neutral balance', () {
      final neutral = engine.analyze(idealStats());
      final desaturated = engine.analyze(idealStats(saturation: 0.03));
      final cast = engine.analyze(idealStats(colorCast: 0.90));

      expect(desaturated.colorScore, lessThan(neutral.colorScore));
      expect(cast.colorScore, lessThan(neutral.colorScore));
      expect(cast.clarityScore, neutral.clarityScore);
    });

    test('overall score follows the documented category weighting', () {
      final result = engine.analyze(
        idealStats(
          brightness: 0.30,
          sharpness: 0.50,
          saturation: 0.20,
          subjectX: 0.12,
        ),
      );
      final weightedFromRoundedCategories =
          result.compositionScore * 0.30 +
          result.lightingScore * 0.30 +
          result.clarityScore * 0.25 +
          result.colorScore * 0.15;

      expect(result.overallScore, closeTo(weightedFromRoundedCategories, 1));
    });
  });

  group('coaching steps', () {
    test('returns three low-priority finishing steps for an ideal frame', () {
      final result = engine.analyze(idealStats());

      expect(result.steps, hasLength(3));
      expect(
        result.steps.map((step) => step.priority),
        everyElement(CoachingPriority.low),
      );
      expect(result.steps.first.title, 'Lock focus precisely');
      expect(result.steps.first.overlay, OverlayType.focus);
      expect(result.steps.first.instruction, contains('33% from the left'));
    });

    test('returns four top fixes for a severely flawed frame', () {
      final result = engine.analyze(
        idealStats(
          brightness: 0.05,
          contrast: 0.05,
          sharpness: 0.05,
          saturation: 0.05,
          subjectX: 0.99,
          subjectY: 0.99,
          noise: 0.9,
          colorCast: 0.9,
          horizonTiltDegrees: 15,
        ),
      );

      expect(result.steps, hasLength(4));
      expect(result.steps.first.title, 'Level the horizon');
      expect(result.steps.first.priority, CoachingPriority.urgent);
      expect(result.steps.first.overlay, OverlayType.level);
      expect(
        result.steps.map((step) => step.overlay).toSet(),
        hasLength(result.steps.length),
      );
    });

    test('gives signed, exact horizon correction', () {
      final clockwiseCorrection = engine.analyze(
        idealStats(horizonTiltDegrees: 4),
      );
      final counterClockwiseCorrection = engine.analyze(
        idealStats(horizonTiltDegrees: -3.5),
      );

      final first = clockwiseCorrection.steps.first;
      expect(first.title, 'Level the horizon');
      expect(first.instruction, contains('4.0° counter-clockwise'));
      expect(first.overlay, OverlayType.level);
      expect(
        counterClockwiseCorrection.steps.first.instruction,
        contains('3.5° clockwise'),
      );
    });

    test('computes a concrete exposure change in EV', () {
      final result = engine.analyze(idealStats(brightness: 0.25));
      final exposure = result.steps.singleWhere(
        (step) => step.overlay == OverlayType.exposure,
      );

      expect(exposure.title, 'Brighten the exposure');
      expect(exposure.instruction, contains('1.0 EV'));
    });

    test('computes exact two-axis movement toward the nearest third', () {
      final result = engine.analyze(idealStats(subjectX: 0.05, subjectY: 0.90));
      final composition = result.steps.singleWhere(
        (step) => step.overlay == OverlayType.ruleOfThirds,
      );

      expect(composition.instruction, contains('28% right and 23% up'));
    });

    test('focus guidance includes the measured subject coordinates', () {
      final result = engine.analyze(
        idealStats(sharpness: 0.20, subjectX: 0.42, subjectY: 0.61),
      );
      final focus = result.steps.singleWhere(
        (step) => step.overlay == OverlayType.focus,
      );

      expect(focus.title, 'Lock focus on the subject');
      expect(
        focus.instruction,
        contains('42% from the left and 61% from the top'),
      );
    });

    test('does not emit duplicate overlay instructions', () {
      final result = engine.analyze(
        idealStats(
          brightness: 0.8,
          highlightClipping: 0.4,
          shadowClipping: 0.2,
        ),
      );

      final overlays = result.steps.map((step) => step.overlay).toList();
      expect(overlays.toSet(), hasLength(overlays.length));
      expect(
        result.steps.where((step) => step.overlay == OverlayType.exposure),
        hasLength(1),
      );
    });

    test('orders steps from highest to lowest priority', () {
      final result = engine.analyze(
        idealStats(
          brightness: 0.05,
          sharpness: 0.45,
          saturation: 0.20,
          colorCast: 0.20,
        ),
      );
      final priorityIndexes = result.steps
          .map((step) => step.priority.index)
          .toList();

      expect(priorityIndexes, orderedEquals([...priorityIndexes]..sort()));
    });

    test('is deterministic for repeated real-time frames', () {
      final stats = idealStats(
        brightness: 0.31,
        sharpness: 0.52,
        subjectX: 0.18,
        horizonTiltDegrees: -2.5,
      );
      final first = engine.analyze(stats);
      final second = engine.analyze(stats);

      expect(second.overallScore, first.overallScore);
      expect(second.compositionScore, first.compositionScore);
      expect(second.lightingScore, first.lightingScore);
      expect(second.clarityScore, first.clarityScore);
      expect(second.colorScore, first.colorScore);
      expect(
        second.steps.map((step) => step.title),
        orderedEquals(first.steps.map((step) => step.title)),
      );
      expect(
        second.steps.map((step) => step.instruction),
        orderedEquals(first.steps.map((step) => step.instruction)),
      );
    });

    test('exposes an immutable coaching list', () {
      final result = engine.analyze(idealStats());

      expect(
        () => result.steps.add(
          const CoachingStep(
            title: 'Extra',
            instruction: 'Extra',
            priority: CoachingPriority.low,
            overlay: OverlayType.none,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('PhotoAnalysis invariants', () {
    const step = CoachingStep(
      title: 'Test',
      instruction: 'Test instruction',
      priority: CoachingPriority.low,
      overlay: OverlayType.none,
    );

    test('rejects scores outside 0..100', () {
      expect(
        () => PhotoAnalysis(
          overallScore: 101,
          compositionScore: 50,
          lightingScore: 50,
          clarityScore: 50,
          colorScore: 50,
          steps: const [step, step, step],
        ),
        throwsArgumentError,
      );
    });

    test('requires three or four steps', () {
      expect(
        () => PhotoAnalysis(
          overallScore: 50,
          compositionScore: 50,
          lightingScore: 50,
          clarityScore: 50,
          colorScore: 50,
          steps: const [step, step],
        ),
        throwsArgumentError,
      );
      expect(
        () => PhotoAnalysis(
          overallScore: 50,
          compositionScore: 50,
          lightingScore: 50,
          clarityScore: 50,
          colorScore: 50,
          steps: const [step, step, step, step, step],
        ),
        throwsArgumentError,
      );
    });
  });
}

ImageStats idealStats({
  int width = 1920,
  int height = 1080,
  double brightness = 0.52,
  double contrast = 0.50,
  double sharpness = 0.85,
  double saturation = 0.50,
  double highlightClipping = 0,
  double shadowClipping = 0,
  double subjectX = 1 / 3,
  double subjectY = 1 / 3,
  double noise = 0,
  double colorCast = 0,
  double? horizonTiltDegrees = 0,
}) => ImageStats(
  width: width,
  height: height,
  brightness: brightness,
  contrast: contrast,
  sharpness: sharpness,
  saturation: saturation,
  highlightClipping: highlightClipping,
  shadowClipping: shadowClipping,
  subjectX: subjectX,
  subjectY: subjectY,
  noise: noise,
  colorCast: colorCast,
  horizonTiltDegrees: horizonTiltDegrees,
);
