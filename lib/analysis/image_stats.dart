/// Normalized, platform-independent measurements extracted from an image.
///
/// This class intentionally knows nothing about cameras, browser APIs, or image
/// codecs. An adapter can derive these values from a video frame, an uploaded
/// image, or a server response and then pass them to [PictureAnalysisEngine].
///
/// All `double` values except [horizonTiltDegrees] are normalized to `0..1`.
/// [subjectX] and [subjectY] are measured from the image's top-left corner.
/// A positive horizon tilt means the horizon falls clockwise (down to the
/// right); a negative value means it falls counter-clockwise.
final class ImageStats {
  ImageStats({
    required this.width,
    required this.height,
    required this.brightness,
    required this.contrast,
    required this.sharpness,
    required this.saturation,
    required this.highlightClipping,
    required this.shadowClipping,
    required this.subjectX,
    required this.subjectY,
    this.noise = 0,
    this.colorCast = 0,
    this.horizonTiltDegrees,
  }) {
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'Must be greater than zero.');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'Must be greater than zero.');
    }

    _requireNormalized(brightness, 'brightness');
    _requireNormalized(contrast, 'contrast');
    _requireNormalized(sharpness, 'sharpness');
    _requireNormalized(saturation, 'saturation');
    _requireNormalized(highlightClipping, 'highlightClipping');
    _requireNormalized(shadowClipping, 'shadowClipping');
    _requireNormalized(subjectX, 'subjectX');
    _requireNormalized(subjectY, 'subjectY');
    _requireNormalized(noise, 'noise');
    _requireNormalized(colorCast, 'colorCast');

    final tilt = horizonTiltDegrees;
    if (tilt != null && !tilt.isFinite) {
      throw ArgumentError.value(
        tilt,
        'horizonTiltDegrees',
        'Must be finite when supplied.',
      );
    }
  }

  final int width;
  final int height;

  /// Mean perceptual luminance: `0` is black and `1` is white.
  final double brightness;

  /// Overall tonal separation: `0` is flat and `1` is extremely contrasty.
  final double contrast;

  /// Normalized edge/detail strength after accounting for image dimensions.
  final double sharpness;

  /// Mean color intensity: `0` is grayscale and `1` is fully saturated.
  final double saturation;

  /// Fraction of pixels with irrecoverable bright detail.
  final double highlightClipping;

  /// Fraction of pixels with irrecoverable dark detail.
  final double shadowClipping;

  /// Horizontal center of the primary subject, from left (`0`) to right (`1`).
  final double subjectX;

  /// Vertical center of the primary subject, from top (`0`) to bottom (`1`).
  final double subjectY;

  /// Estimated visible noise/grain, where `1` is very noisy.
  final double noise;

  /// Strength of an unwanted tint, where `0` is neutral and `1` is severe.
  final double colorCast;

  /// Signed angle of the detected horizon, or `null` when none was detected.
  final double? horizonTiltDegrees;

  /// The exact camel-case measurement object accepted by the Picture Perfect
  /// backend. Image pixels are never included.
  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'brightness': brightness,
    'contrast': contrast,
    'sharpness': sharpness,
    'saturation': saturation,
    'highlightClipping': highlightClipping,
    'shadowClipping': shadowClipping,
    'subjectX': subjectX,
    'subjectY': subjectY,
    'noise': noise,
    'colorCast': colorCast,
    'horizonTiltDegrees': horizonTiltDegrees,
  };

  static void _requireNormalized(double value, String name) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, name, 'Must be finite and within 0..1.');
    }
  }
}
