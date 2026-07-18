import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Non-web compile-time stand-in. Picture Perfect is a web app, but keeping a
/// small stub lets domain and widget tests run on the Dart VM as well.
enum WebCameraFacing { front, back }

enum WebCameraStatus { idle, starting, streaming, stopping, error }

enum WebCameraPreviewFit { cover, contain, fill }

@immutable
final class WebPickedImage {
  const WebPickedImage({
    required this.bytes,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
  });

  final Uint8List bytes;
  final String name;
  final String mimeType;
  final int sizeBytes;
}

@immutable
final class WebCameraFrame {
  const WebCameraFrame({
    required this.bytes,
    required this.name,
    required this.width,
    required this.height,
    required this.capturedAt,
  });

  final Uint8List bytes;
  final String name;
  final int width;
  final int height;
  final DateTime capturedAt;
}

final class WebCaptureException implements Exception {
  const WebCaptureException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;
}

Future<WebPickedImage?> pickImageFromBrowser({int? maxBytes}) async {
  throw const WebCaptureException(
    'web-only',
    'Camera and image selection are available in the web app.',
  );
}

final class WebCameraController extends ChangeNotifier {
  WebCameraController({
    WebCameraFacing initialFacing = WebCameraFacing.front,
    this.mirrorFrontCamera = true,
    this.previewFit = WebCameraPreviewFit.cover,
  }) : _facing = initialFacing;

  final bool mirrorFrontCamera;
  final WebCameraPreviewFit previewFit;
  WebCameraFacing _facing;
  WebCameraStatus status = WebCameraStatus.idle;
  WebCaptureException? lastError;

  WebCameraFacing get facing => _facing;
  bool get isStreaming => status == WebCameraStatus.streaming;
  String get viewType => 'picture-perfect-camera-stub';

  Future<void> startCamera({WebCameraFacing? facing}) async {
    if (facing != null) _facing = facing;
    lastError = const WebCaptureException(
      'web-only',
      'Camera access is available when Picture Perfect runs in a browser.',
    );
    status = WebCameraStatus.error;
    notifyListeners();
    throw lastError!;
  }

  Future<void> switchCamera() => startCamera(
    facing: _facing == WebCameraFacing.front
        ? WebCameraFacing.back
        : WebCameraFacing.front,
  );

  Future<WebCameraFrame> captureFrame() async =>
      throw const WebCaptureException(
        'web-only',
        'Camera capture is available in the web app.',
      );

  Future<Uint8List> capturePngBytes() async => (await captureFrame()).bytes;

  void stopCamera() {
    status = WebCameraStatus.idle;
    notifyListeners();
  }
}

final class WebCameraPreview extends StatelessWidget {
  const WebCameraPreview({super.key, required this.controller});

  final WebCameraController controller;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
