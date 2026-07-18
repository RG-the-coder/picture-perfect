import 'dart:async';
import 'dart:convert';

import 'image_stats.dart';
import 'photo_analysis.dart';
import 'photo_analysis_transport.dart';
import 'photo_analysis_transport_stub.dart'
    if (dart.library.html) 'photo_analysis_transport_web.dart'
    as platform;

enum PhotoAnalysisSource { onDevice, deterministicFallback, freesoloValidated }

final class PhotoAnalysisApiResult {
  const PhotoAnalysisApiResult({
    required this.analysis,
    required this.source,
    this.modelRevision,
  });

  final PhotoAnalysis analysis;
  final PhotoAnalysisSource source;
  final String? modelRevision;
}

final class PhotoAnalysisApiException implements Exception {
  const PhotoAnalysisApiException(this.message);

  final String message;

  @override
  String toString() => 'PhotoAnalysisApiException: $message';
}

final class PhotoAnalysisApi {
  PhotoAnalysisApi({
    required String baseUrl,
    PhotoAnalysisTransport? transport,
    this.timeout = const Duration(seconds: 6),
  }) : _endpoint = _endpointFor(baseUrl),
       _transport = transport ?? platform.createPhotoAnalysisTransport();

  factory PhotoAnalysisApi.fromEnvironment() => PhotoAnalysisApi(
    baseUrl: const String.fromEnvironment(
      'PICTUREPERFECT_API_BASE_URL',
      defaultValue: '',
    ),
  );

  final Uri? _endpoint;
  final PhotoAnalysisTransport _transport;
  final Duration timeout;

  bool get configured => _endpoint != null;

  Future<PhotoAnalysisApiResult> analyze(
    ImageStats stats, {
    required String requestId,
    required int frameSeq,
    required String sessionId,
    required int adviceEpoch,
    String intent = 'auto',
  }) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const PhotoAnalysisApiException('backend is not configured');
    }
    if (!_validRequestId.hasMatch(requestId) || requestId.length > 128) {
      throw const PhotoAnalysisApiException('request ID is invalid');
    }
    if (frameSeq < 0 || adviceEpoch < 0) {
      throw const PhotoAnalysisApiException(
        'request counters must be non-negative',
      );
    }
    if (sessionId.isEmpty || sessionId.length > 128) {
      throw const PhotoAnalysisApiException('session ID is invalid');
    }
    if (!_validIntents.contains(intent)) {
      throw const PhotoAnalysisApiException('photo intent is invalid');
    }
    final requestBody = jsonEncode({
      'schemaVersion': 1,
      'requestId': requestId,
      'frameSeq': frameSeq,
      'mode': 'capture',
      'intent': intent,
      'sessionId': sessionId,
      'adviceEpoch': adviceEpoch,
      'measurements': stats.toJson(),
    });

    try {
      final response = await _transport
          .postJson(endpoint, body: requestBody, timeout: timeout)
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw PhotoAnalysisApiException(
          'backend returned HTTP ${response.statusCode}',
        );
      }
      if (response.requestId?.trim() != requestId) {
        throw const PhotoAnalysisApiException(
          'backend response request ID did not match',
        );
      }
      final source = switch (response.analysisSource) {
        'freesolo-validated' => PhotoAnalysisSource.freesoloValidated,
        'deterministic-fallback' => PhotoAnalysisSource.deterministicFallback,
        _ => throw const PhotoAnalysisApiException(
          'backend omitted valid analysis provenance',
        ),
      };
      final revision = response.modelRevision?.trim();
      if (source == PhotoAnalysisSource.freesoloValidated &&
          (revision == null || revision.isEmpty)) {
        throw const PhotoAnalysisApiException(
          'validated model response omitted its revision',
        );
      }
      if (source != PhotoAnalysisSource.freesoloValidated &&
          revision != null &&
          revision.isNotEmpty) {
        throw const PhotoAnalysisApiException(
          'fallback response claimed a model revision',
        );
      }
      return PhotoAnalysisApiResult(
        analysis: PhotoAnalysis.fromJson(jsonDecode(response.body)),
        source: source,
        modelRevision: revision,
      );
    } on PhotoAnalysisApiException {
      rethrow;
    } on TimeoutException {
      throw const PhotoAnalysisApiException('backend request timed out');
    } on Object {
      throw const PhotoAnalysisApiException('backend response was unavailable');
    }
  }

  static Uri? _endpointFor(String rawBaseUrl) {
    final trimmed = rawBaseUrl.trim();
    if (trimmed.isEmpty) return null;
    final base = Uri.tryParse(trimmed);
    if (base == null ||
        !base.hasAuthority ||
        (base.scheme != 'http' && base.scheme != 'https') ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw ArgumentError.value(rawBaseUrl, 'baseUrl', 'Invalid HTTP(S) URL');
    }
    final segments = base.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length >= 2 &&
        segments[segments.length - 2] == 'v1' &&
        segments.last == 'photo-analyses') {
      return base.replace(pathSegments: segments);
    }
    if (segments.isEmpty || segments.last != 'v1') {
      segments.add('v1');
    }
    segments.add('photo-analyses');
    return base.replace(pathSegments: segments);
  }

  static final RegExp _validRequestId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]*$',
  );
  static const Set<String> _validIntents = {
    'auto',
    'portrait',
    'landscape',
    'product',
  };
}
