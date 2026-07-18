// Browser-only capture primitives for the Picture Perfect web app.
//
// `dart:html` is used deliberately here to keep the project dependency-free.
// Keep imports of this file behind a web implementation if native targets are
// added in the future.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Which physical direction the camera should face.
enum WebCameraFacing {
  front,
  back;

  String get _constraint => switch (this) {
    WebCameraFacing.front => 'user',
    WebCameraFacing.back => 'environment',
  };

  WebCameraFacing get opposite => switch (this) {
    WebCameraFacing.front => WebCameraFacing.back,
    WebCameraFacing.back => WebCameraFacing.front,
  };
}

/// Lifecycle state of a [WebCameraController].
enum WebCameraStatus { idle, starting, streaming, stopping, error }

/// How the browser video should fit inside the Flutter preview bounds.
enum WebCameraPreviewFit {
  cover,
  contain,
  fill;

  String get _cssValue => name;
}

/// An image selected from the browser's native file picker.
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

/// A PNG snapshot captured from the currently playing camera frame.
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

  String get mimeType => 'image/png';
}

/// A stable, user-presentable error produced by browser capture operations.
final class WebCaptureException implements Exception {
  const WebCaptureException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WebCaptureException($code): $message';
}

/// Opens the browser's native image picker and reads the selected file.
///
/// Returns `null` when the user cancels. This function must be called directly
/// from a user interaction (for example, a button's `onPressed` callback), or
/// browsers may block the picker.
Future<WebPickedImage?> pickImageFromBrowser({int? maxBytes}) async {
  if (maxBytes != null && maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be greater than 0.');
  }

  final input = html.FileUploadInputElement()
    ..accept = 'image/*'
    ..multiple = false
    ..style.display = 'none';

  final selectedFile = Completer<html.File?>();
  final subscriptions = <StreamSubscription<html.Event>>[];
  Timer? cancellationCheck;
  var pickerWasHidden = false;

  void complete(html.File? file) {
    if (!selectedFile.isCompleted) {
      selectedFile.complete(file);
    }
  }

  void checkForCancellation() {
    cancellationCheck?.cancel();
    cancellationCheck = Timer(const Duration(milliseconds: 500), () {
      final files = input.files;
      if (files == null || files.isEmpty) {
        complete(null);
      }
    });
  }

  subscriptions.add(
    input.onChange.listen((_) {
      final files = input.files;
      complete(files == null || files.isEmpty ? null : files.first);
    }),
  );
  // Modern Chromium, Firefox, and Safari emit `cancel` on file inputs.
  subscriptions.add(input.on['cancel'].listen((_) => complete(null)));
  // Focus/visibility fallbacks cover older browsers that do not emit it.
  subscriptions.add(html.window.onFocus.listen((_) => checkForCancellation()));
  subscriptions.add(
    html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'hidden') {
        pickerWasHidden = true;
      } else if (pickerWasHidden) {
        checkForCancellation();
      }
    }),
  );

  html.document.body?.children.add(input);
  try {
    input.click();
  } catch (error) {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    input.remove();
    throw WebCaptureException(
      'file-picker-unavailable',
      'The browser could not open the image picker. Try again from a button or tap.',
      cause: error,
    );
  }

  final file = await selectedFile.future;
  cancellationCheck?.cancel();
  for (final subscription in subscriptions) {
    unawaited(subscription.cancel());
  }
  input.remove();

  if (file == null) {
    return null;
  }
  if (file.type.isNotEmpty && !file.type.toLowerCase().startsWith('image/')) {
    throw const WebCaptureException(
      'invalid-image-type',
      'Please choose an image file.',
    );
  }
  if (maxBytes != null && file.size > maxBytes) {
    throw WebCaptureException(
      'image-too-large',
      'That image is too large. Choose one smaller than '
          '${_formatByteCount(maxBytes)}.',
    );
  }

  final bytes = await _readBlob(file, operation: 'read the selected image');
  return WebPickedImage(
    bytes: bytes,
    name: file.name,
    mimeType: file.type.isEmpty ? 'application/octet-stream' : file.type,
    sizeBytes: file.size,
  );
}

/// Controls a browser camera stream and exposes it to Flutter as an HTML view.
///
/// Camera access requires HTTPS (or localhost) and explicit user permission.
/// Always call [dispose] from the owning widget; it stops every media track.
final class WebCameraController extends ChangeNotifier {
  WebCameraController({
    WebCameraFacing initialFacing = WebCameraFacing.front,
    this.mirrorFrontCamera = true,
    this.previewFit = WebCameraPreviewFit.cover,
  }) : _facing = initialFacing,
       _viewType = 'picture-perfect-camera-${_nextViewType++}' {
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId, {Object? params}) => _createVideoElement(viewId),
    );
  }

  static int _nextViewType = 0;

  final bool mirrorFrontCamera;
  final WebCameraPreviewFit previewFit;
  final String _viewType;
  final List<html.VideoElement> _videoElements = <html.VideoElement>[];
  final List<StreamSubscription<html.Event>> _trackSubscriptions =
      <StreamSubscription<html.Event>>[];

  WebCameraFacing _facing;
  WebCameraStatus _status = WebCameraStatus.idle;
  WebCaptureException? _lastError;
  html.MediaStream? _stream;
  int _requestEpoch = 0;
  bool _disposed = false;

  WebCameraFacing get facing => _facing;
  WebCameraStatus get status => _status;
  WebCaptureException? get lastError => _lastError;
  bool get isStreaming => _status == WebCameraStatus.streaming;

  /// The view type used internally by [WebCameraPreview].
  String get viewType => _viewType;

  /// Requests permission and starts a live camera stream.
  Future<void> startCamera({WebCameraFacing? facing}) async {
    _ensureNotDisposed();
    final requestedFacing = facing ?? _facing;
    final requestEpoch = ++_requestEpoch;

    _releaseCurrentStream();
    _facing = requestedFacing;
    _lastError = null;
    _status = WebCameraStatus.starting;
    _updatePreviewPresentation();
    notifyListeners();

    // A listener may synchronously stop or dispose the controller above.
    if (_disposed || requestEpoch != _requestEpoch) {
      return;
    }

    html.MediaStream? requestedStream;
    try {
      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        throw const WebCaptureException(
          'camera-unsupported',
          'This browser does not support camera access. Try a current browser over HTTPS.',
        );
      }

      requestedStream = await mediaDevices.getUserMedia(<String, Object>{
        'audio': false,
        'video': <String, Object>{
          'facingMode': <String, String>{'ideal': requestedFacing._constraint},
          'width': <String, int>{'ideal': 1920},
          'height': <String, int>{'ideal': 1080},
        },
      });

      if (_disposed || requestEpoch != _requestEpoch) {
        _stopTracks(requestedStream);
        return;
      }

      _stream = requestedStream;
      _listenForEndedTracks(requestedStream);
      await _attachStreamToPreviews(requestedStream);

      if (_disposed || requestEpoch != _requestEpoch) {
        _stopTracks(requestedStream);
        return;
      }

      _status = WebCameraStatus.streaming;
      notifyListeners();
    } catch (error) {
      if (requestedStream != null) {
        _stopTracks(requestedStream);
      }
      if (_disposed || requestEpoch != _requestEpoch) {
        return;
      }
      _releaseCurrentStream();
      final captureError = _asCameraError(error);
      _lastError = captureError;
      _status = WebCameraStatus.error;
      notifyListeners();
      throw captureError;
    }
  }

  /// Stops the current stream and requests the opposite-facing camera.
  Future<void> switchCamera() => startCamera(facing: _facing.opposite);

  /// Captures the currently visible frame as PNG data plus useful metadata.
  Future<WebCameraFrame> captureFrame() async {
    _ensureNotDisposed();
    if (!isStreaming || _stream == null) {
      throw const WebCaptureException(
        'camera-not-running',
        'Start the camera before taking a picture.',
      );
    }

    final video = _activeVideoElement;
    if (video == null) {
      throw const WebCaptureException(
        'preview-not-mounted',
        'The camera preview is not ready yet.',
      );
    }
    final width = video.videoWidth;
    final height = video.videoHeight;
    if (width <= 0 ||
        height <= 0 ||
        video.readyState < html.MediaElement.HAVE_CURRENT_DATA) {
      throw const WebCaptureException(
        'frame-not-ready',
        'The camera is still warming up. Wait a moment and try again.',
      );
    }

    try {
      final canvas = html.CanvasElement(width: width, height: height);
      final context = canvas.context2D;
      if (_shouldMirror) {
        context
          ..save()
          ..translate(width, 0)
          ..scale(-1, 1)
          ..drawImageScaled(video, 0, 0, width, height)
          ..restore();
      } else {
        context.drawImageScaled(video, 0, 0, width, height);
      }

      final blob = await canvas.toBlob('image/png');
      final bytes = await _readBlob(blob, operation: 'encode the camera frame');
      final capturedAt = DateTime.now();
      return WebCameraFrame(
        bytes: bytes,
        name: 'picture-perfect-${capturedAt.millisecondsSinceEpoch}.png',
        width: width,
        height: height,
        capturedAt: capturedAt,
      );
    } catch (error) {
      if (error is WebCaptureException) {
        rethrow;
      }
      throw WebCaptureException(
        'frame-capture-failed',
        'The current camera frame could not be captured. Please try again.',
        cause: error,
      );
    }
  }

  /// Convenience form of [captureFrame] when only PNG bytes are needed.
  Future<Uint8List> capturePngBytes() async => (await captureFrame()).bytes;

  /// Stops every track immediately and detaches the stream from the preview.
  void stopCamera() {
    if (_disposed) {
      return;
    }
    _requestEpoch++;
    if (_stream != null || _status == WebCameraStatus.starting) {
      _status = WebCameraStatus.stopping;
      notifyListeners();
    }
    _releaseCurrentStream();
    _lastError = null;
    _status = WebCameraStatus.idle;
    notifyListeners();
  }

  html.VideoElement _createVideoElement(int viewId) {
    final video = html.VideoElement()
      ..id = 'picture-perfect-camera-view-$viewId'
      ..autoplay = true
      ..muted = true
      ..controls = false
      ..setAttribute('playsinline', 'true')
      ..setAttribute('aria-label', 'Live camera preview')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..style.backgroundColor = 'transparent';
    _videoElements.add(video);
    _applyPreviewPresentation(video);

    final stream = _stream;
    if (!_disposed && stream != null) {
      video.srcObject = stream;
      // `autoplay` starts playback once Flutter attaches the element to the DOM.
    }
    return video;
  }

  html.VideoElement? get _activeVideoElement {
    for (final video in _videoElements.reversed) {
      if (video.isConnected == true) {
        return video;
      }
    }
    return _videoElements.isEmpty ? null : _videoElements.last;
  }

  bool get _shouldMirror =>
      mirrorFrontCamera && _facing == WebCameraFacing.front;

  void _applyPreviewPresentation(html.VideoElement video) {
    video.style
      ..objectFit = previewFit._cssValue
      ..transform = _shouldMirror ? 'scaleX(-1)' : 'none';
  }

  void _updatePreviewPresentation() {
    for (final video in _videoElements) {
      _applyPreviewPresentation(video);
    }
  }

  Future<void> _attachStreamToPreviews(html.MediaStream stream) async {
    for (final video in _videoElements) {
      video.srcObject = stream;
    }
    final activeVideo = _activeVideoElement;
    if (activeVideo != null && activeVideo.isConnected == true) {
      try {
        await activeVideo.play();
      } catch (error) {
        throw WebCaptureException(
          'camera-playback-failed',
          'The browser opened the camera but could not play its preview.',
          cause: error,
        );
      }
    }
  }

  void _listenForEndedTracks(html.MediaStream stream) {
    for (final track in stream.getTracks()) {
      _trackSubscriptions.add(
        track.onEnded.listen((_) {
          if (_disposed || !identical(_stream, stream)) {
            return;
          }
          _releaseCurrentStream();
          _lastError = const WebCaptureException(
            'camera-ended',
            'The camera stopped. Check browser permissions and try again.',
          );
          _status = WebCameraStatus.error;
          notifyListeners();
        }),
      );
    }
  }

  void _releaseCurrentStream() {
    for (final subscription in _trackSubscriptions) {
      unawaited(subscription.cancel());
    }
    _trackSubscriptions.clear();
    final stream = _stream;
    _stream = null;
    for (final video in _videoElements) {
      video
        ..pause()
        ..srcObject = null;
    }
    if (stream != null) {
      _stopTracks(stream);
    }
  }

  static void _stopTracks(html.MediaStream stream) {
    for (final track in stream.getTracks()) {
      track.stop();
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const WebCaptureException(
        'controller-disposed',
        'This camera controller has already been disposed.',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _requestEpoch++;
    _releaseCurrentStream();
    _videoElements.clear();
    _disposed = true;
    super.dispose();
  }
}

/// Embeds a [WebCameraController]'s real browser video element in Flutter.
///
/// Place this inside a widget with bounded width and height (for example,
/// `AspectRatio(aspectRatio: 3 / 4, child: WebCameraPreview(...))`).
final class WebCameraPreview extends StatelessWidget {
  const WebCameraPreview({super.key, required this.controller});

  final WebCameraController controller;

  @override
  Widget build(BuildContext context) => HtmlElementView(
    viewType: controller.viewType,
    key: ValueKey<String>(controller.viewType),
  );
}

Future<Uint8List> _readBlob(html.Blob blob, {required String operation}) async {
  final reader = html.FileReader();
  final completed = Completer<Uint8List>();
  final subscriptions = <StreamSubscription<html.ProgressEvent>>[];

  void fail(String message, [Object? cause]) {
    if (!completed.isCompleted) {
      completed.completeError(
        WebCaptureException('image-read-failed', message, cause: cause),
      );
    }
  }

  subscriptions.add(
    reader.onLoad.listen((_) {
      if (completed.isCompleted) {
        return;
      }
      final result = reader.result;
      if (result is Uint8List) {
        completed.complete(Uint8List.fromList(result));
      } else if (result is ByteBuffer) {
        completed.complete(Uint8List.view(result));
      } else {
        fail('The browser returned invalid data while trying to $operation.');
      }
    }),
  );
  subscriptions.add(
    reader.onError.listen((_) {
      fail('The browser could not $operation.', reader.error);
    }),
  );
  subscriptions.add(
    reader.onAbort.listen((_) {
      fail('The browser cancelled while trying to $operation.');
    }),
  );

  reader.readAsArrayBuffer(blob);
  try {
    return await completed.future;
  } finally {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  }
}

WebCaptureException _asCameraError(Object error) {
  if (error is WebCaptureException) {
    return error;
  }
  if (error is html.DomException) {
    final details = error.message;
    return switch (error.name) {
      'NotAllowedError' || 'PermissionDeniedError' => WebCaptureException(
        'camera-permission-denied',
        'Camera access was denied. Allow camera permission in your browser and try again.',
        cause: error,
      ),
      'NotFoundError' || 'DevicesNotFoundError' => WebCaptureException(
        'camera-not-found',
        'No camera was found on this device.',
        cause: error,
      ),
      'NotReadableError' || 'TrackStartError' => WebCaptureException(
        'camera-busy',
        'The camera is already in use by another app or browser tab.',
        cause: error,
      ),
      'OverconstrainedError' ||
      'ConstraintNotSatisfiedError' => WebCaptureException(
        'camera-constraints-unsupported',
        'This camera does not support the requested mode.',
        cause: error,
      ),
      'SecurityError' => WebCaptureException(
        'camera-insecure-context',
        'Camera access requires HTTPS (localhost is also allowed).',
        cause: error,
      ),
      'AbortError' => WebCaptureException(
        'camera-aborted',
        'The browser interrupted camera startup. Please try again.',
        cause: error,
      ),
      _ => WebCaptureException(
        'camera-start-failed',
        details == null || details.isEmpty
            ? 'The browser could not start the camera.'
            : 'The browser could not start the camera: $details',
        cause: error,
      ),
    };
  }
  return WebCaptureException(
    'camera-start-failed',
    'The browser could not start the camera. Check permissions and try again.',
    cause: error,
  );
}

String _formatByteCount(int bytes) {
  const megabyte = 1024 * 1024;
  const kilobyte = 1024;
  if (bytes >= megabyte) {
    return '${(bytes / megabyte).toStringAsFixed(1)} MB';
  }
  if (bytes >= kilobyte) {
    return '${(bytes / kilobyte).toStringAsFixed(0)} KB';
  }
  return '$bytes bytes';
}
