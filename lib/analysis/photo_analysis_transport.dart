/// A deliberately tiny transport boundary so the API contract remains testable
/// without browser APIs.
abstract interface class PhotoAnalysisTransport {
  Future<PhotoAnalysisHttpResponse> postJson(
    Uri uri, {
    required String body,
    required Duration timeout,
  });
}

final class PhotoAnalysisHttpResponse {
  const PhotoAnalysisHttpResponse({
    required this.statusCode,
    required this.body,
    this.requestId,
    this.analysisSource,
    this.modelRevision,
  });

  final int statusCode;
  final String body;
  final String? requestId;
  final String? analysisSource;
  final String? modelRevision;
}
