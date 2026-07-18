import 'photo_analysis_transport.dart';

PhotoAnalysisTransport createPhotoAnalysisTransport() =>
    const _UnsupportedPhotoAnalysisTransport();

final class _UnsupportedPhotoAnalysisTransport
    implements PhotoAnalysisTransport {
  const _UnsupportedPhotoAnalysisTransport();

  @override
  Future<PhotoAnalysisHttpResponse> postJson(
    Uri uri, {
    required String body,
    required Duration timeout,
  }) {
    throw UnsupportedError('Remote photo analysis requires a web browser.');
  }
}
