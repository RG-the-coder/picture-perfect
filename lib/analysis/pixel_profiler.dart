import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Measurable properties extracted locally from a decoded image.
///
/// This deliberately contains no product recommendations. The coaching engine
/// can turn the same neutral profile into different kinds of advice later.
class PixelProfile {
  const PixelProfile({
    required this.width,
    required this.height,
    required this.meanLuminance,
    required this.contrast,
    required this.dynamicRange,
    required this.shadowsClipped,
    required this.highlightsClipped,
    required this.sharpness,
    required this.saturation,
    required this.warmth,
    required this.subjectX,
    required this.subjectY,
    required this.subjectCoverage,
  });

  final int width;
  final int height;
  final double meanLuminance;
  final double contrast;
  final double dynamicRange;
  final double shadowsClipped;
  final double highlightsClipped;
  final double sharpness;
  final double saturation;
  final double warmth;
  final double subjectX;
  final double subjectY;
  final double subjectCoverage;
}

/// Fast, dependency-free pixel analysis designed for browser execution.
abstract final class PixelProfiler {
  static const int _maxSampleDimension = 360;

  @visibleForTesting
  static ({int width, int height}) sampleSizeFor(
    int intrinsicWidth,
    int intrinsicHeight,
  ) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      throw const FormatException('The decoded image has invalid dimensions.');
    }
    final longestEdge = math.max(intrinsicWidth, intrinsicHeight);
    final scale = math.min(1.0, _maxSampleDimension / longestEdge);
    return (
      width: math.max(1, (intrinsicWidth * scale).round()),
      height: math.max(1, (intrinsicHeight * scale).round()),
    );
  }

  static Future<PixelProfile> analyze(Uint8List encodedBytes) async {
    if (encodedBytes.isEmpty) {
      throw const FormatException('The selected image is empty.');
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(encodedBytes);
    ui.Codec? codec;
    ui.Image? image;
    var sourceWidth = 0;
    var sourceHeight = 0;

    try {
      // Encoded ImageDescriptor width/height getters intentionally throw on
      // Flutter Web. This API discovers the intrinsic dimensions through a
      // decoded frame, then invokes the callback on every supported renderer.
      // It also takes ownership of and disposes [buffer].
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          sourceWidth = intrinsicWidth;
          sourceHeight = intrinsicHeight;
          final sampleSize = sampleSizeFor(intrinsicWidth, intrinsicHeight);
          return ui.TargetImageSize(
            width: sampleSize.width,
            height: sampleSize.height,
          );
        },
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw const FormatException('This image format could not be decoded.');
      }

      return _measure(
        data.buffer.asUint8List(),
        image.width,
        image.height,
        sourceWidth == 0 ? image.width : sourceWidth,
        sourceHeight == 0 ? image.height : sourceHeight,
      );
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static PixelProfile _measure(
    Uint8List rgba,
    int width,
    int height,
    int sourceWidth,
    int sourceHeight,
  ) {
    final count = width * height;
    if (count == 0 || rgba.length < count * 4) {
      throw const FormatException('The decoded image has no readable pixels.');
    }

    final luminance = Float32List(count);
    final saturation = Float32List(count);
    final histogram = Uint32List(256);
    var luminanceSum = 0.0;
    var luminanceSquaredSum = 0.0;
    var saturationSum = 0.0;
    var redSum = 0.0;
    var blueSum = 0.0;
    var shadowPixels = 0;
    var highlightPixels = 0;

    for (var pixel = 0, byteIndex = 0; pixel < count; pixel++, byteIndex += 4) {
      final alpha = rgba[byteIndex + 3] / 255.0;
      final r = (rgba[byteIndex] / 255.0) * alpha + (1 - alpha) * .5;
      final g = (rgba[byteIndex + 1] / 255.0) * alpha + (1 - alpha) * .5;
      final b = (rgba[byteIndex + 2] / 255.0) * alpha + (1 - alpha) * .5;
      final luma = .2126 * r + .7152 * g + .0722 * b;
      final maxChannel = math.max(r, math.max(g, b));
      final minChannel = math.min(r, math.min(g, b));
      final sat = maxChannel == 0
          ? 0.0
          : (maxChannel - minChannel) / maxChannel;

      luminance[pixel] = luma;
      saturation[pixel] = sat;
      luminanceSum += luma;
      luminanceSquaredSum += luma * luma;
      saturationSum += sat;
      redSum += r;
      blueSum += b;
      histogram[(luma * 255).round().clamp(0, 255)]++;
      if (luma < .045) shadowPixels++;
      if (luma > .955) highlightPixels++;
    }

    final mean = luminanceSum / count;
    final variance = math.max(0, luminanceSquaredSum / count - mean * mean);
    final p10 = _percentile(histogram, count, .10);
    final p90 = _percentile(histogram, count, .90);

    final weights = Float32List(count);
    var weightSum = 0.0;
    var weightedX = 0.0;
    var weightedY = 0.0;
    var weightSquaredSum = 0.0;
    var laplacianSquaredSum = 0.0;
    var laplacianSum = 0.0;
    var laplacianCount = 0;

    if (width > 2 && height > 2) {
      for (var y = 1; y < height - 1; y++) {
        for (var x = 1; x < width - 1; x++) {
          final index = y * width + x;
          final horizontal = (luminance[index + 1] - luminance[index - 1])
              .abs();
          final vertical = (luminance[index + width] - luminance[index - width])
              .abs();
          final weight = horizontal + vertical + saturation[index] * .11;
          weights[index] = weight;
          weightSum += weight;
          weightSquaredSum += weight * weight;
          weightedX += (x / (width - 1)) * weight;
          weightedY += (y / (height - 1)) * weight;

          final laplacian =
              4 * luminance[index] -
              luminance[index - 1] -
              luminance[index + 1] -
              luminance[index - width] -
              luminance[index + width];
          laplacianSum += laplacian;
          laplacianSquaredSum += laplacian * laplacian;
          laplacianCount++;
        }
      }
    }

    var subjectCoverage = .35;
    if (weightSum > 0 && laplacianCount > 0) {
      final meanWeight = weightSum / laplacianCount;
      final weightVariance = math.max(
        0,
        weightSquaredSum / laplacianCount - meanWeight * meanWeight,
      );
      final threshold = meanWeight + math.sqrt(weightVariance) * .55;
      var salient = 0;
      for (final weight in weights) {
        if (weight > threshold) salient++;
      }
      subjectCoverage = (salient / laplacianCount * 2.3).clamp(.08, .95);
    }

    final lapMean = laplacianCount == 0 ? 0 : laplacianSum / laplacianCount;
    final lapVariance = laplacianCount == 0
        ? 0.0
        : math.max(0, laplacianSquaredSum / laplacianCount - lapMean * lapMean);
    final normalizedSharpness = (math.sqrt(lapVariance) * 6.5).clamp(0.0, 1.0);

    return PixelProfile(
      width: sourceWidth,
      height: sourceHeight,
      meanLuminance: mean.clamp(0.0, 1.0),
      contrast: (math.sqrt(variance) * 3.0).clamp(0.0, 1.0),
      dynamicRange: (p90 - p10).clamp(0.0, 1.0),
      shadowsClipped: shadowPixels / count,
      highlightsClipped: highlightPixels / count,
      sharpness: normalizedSharpness,
      saturation: (saturationSum / count).clamp(0.0, 1.0),
      warmth: ((redSum - blueSum) / count * 2.0).clamp(-1.0, 1.0),
      subjectX: weightSum == 0 ? .5 : (weightedX / weightSum).clamp(0.0, 1.0),
      subjectY: weightSum == 0 ? .5 : (weightedY / weightSum).clamp(0.0, 1.0),
      subjectCoverage: subjectCoverage,
    );
  }

  static double _percentile(Uint32List histogram, int count, double target) {
    final desired = count * target;
    var accumulated = 0;
    for (var index = 0; index < histogram.length; index++) {
      accumulated += histogram[index];
      if (accumulated >= desired) return index / 255.0;
    }
    return 1;
  }
}
