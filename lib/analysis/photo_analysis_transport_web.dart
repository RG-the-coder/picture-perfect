// Browser-only JSON transport. The photo bytes never enter this module.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'photo_analysis_transport.dart';

PhotoAnalysisTransport createPhotoAnalysisTransport() =>
    const _WebPhotoAnalysisTransport();

final class _WebPhotoAnalysisTransport implements PhotoAnalysisTransport {
  const _WebPhotoAnalysisTransport();

  @override
  Future<PhotoAnalysisHttpResponse> postJson(
    Uri uri, {
    required String body,
    required Duration timeout,
  }) async {
    final request = await html.HttpRequest.request(
      uri.toString(),
      method: 'POST',
      requestHeaders: const {'Content-Type': 'application/json'},
      sendData: body,
    ).timeout(timeout);
    return PhotoAnalysisHttpResponse(
      statusCode: request.status ?? 0,
      body: request.responseText ?? '',
      requestId: request.getResponseHeader('X-Request-ID'),
      analysisSource: request.getResponseHeader('X-Analysis-Source'),
      modelRevision: request.getResponseHeader('X-Model-Revision'),
    );
  }
}
