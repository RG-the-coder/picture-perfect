import 'package:flutter_test/flutter_test.dart';
import 'package:picture_perfect/analysis/picture_analysis.dart';
import 'package:picture_perfect/analysis/pixel_profiler.dart';
import 'package:picture_perfect/demo_image_factory.dart';

void main() {
  test('sample sizing bounds either orientation without upscaling', () {
    expect(PixelProfiler.sampleSizeFor(40000, 20), (width: 360, height: 1));
    expect(PixelProfiler.sampleSizeFor(20, 40000), (width: 1, height: 360));
    expect(PixelProfiler.sampleSizeFor(120, 80), (width: 120, height: 80));

    for (final dimensions in <(int, int)>[
      (1, 1),
      (360, 360),
      (16384, 1),
      (1, 16384),
      (4032, 3024),
      (3024, 4032),
    ]) {
      final size = PixelProfiler.sampleSizeFor(dimensions.$1, dimensions.$2);
      expect(size.width, inInclusiveRange(1, 360));
      expect(size.height, inInclusiveRange(1, 360));
      expect(size.width * size.height, lessThanOrEqualTo(360 * 360));
    }
  });

  test('sample sizing rejects invalid dimensions', () {
    expect(() => PixelProfiler.sampleSizeFor(0, 100), throwsFormatException);
  });

  testWidgets('generated sample completes the real pixel-to-plan pipeline', (
    tester,
  ) async {
    final bytes = await tester.runAsync(DemoImageFactory.create);
    expect(bytes, isNotNull);

    final profile = await tester.runAsync(() => PixelProfiler.analyze(bytes!));
    expect(profile, isNotNull);
    expect(profile!.width, 1200);
    expect(profile.height, 900);
    expect(profile.meanLuminance, inInclusiveRange(0, 1));
    expect(profile.sharpness, inInclusiveRange(0, 1));

    final report = const PictureAnalysisEngine().analyze(
      ImageStats(
        width: profile.width,
        height: profile.height,
        brightness: profile.meanLuminance,
        contrast: profile.contrast,
        sharpness: profile.sharpness,
        saturation: profile.saturation,
        highlightClipping: profile.highlightsClipped,
        shadowClipping: profile.shadowsClipped,
        subjectX: profile.subjectX,
        subjectY: profile.subjectY,
        colorCast: profile.warmth.abs(),
      ),
    );

    expect(report.overallScore, inInclusiveRange(0, 100));
    expect(report.steps.length, inInclusiveRange(3, 4));
  });
}
