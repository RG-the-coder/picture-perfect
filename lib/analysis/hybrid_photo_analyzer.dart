import 'image_stats.dart';
import 'photo_analysis.dart';
import 'photo_analysis_api.dart';
import 'picture_analysis_engine.dart';

final class HybridPhotoAnalysis {
  const HybridPhotoAnalysis({
    required this.analysis,
    required this.source,
    this.modelRevision,
  });

  final PhotoAnalysis analysis;
  final PhotoAnalysisSource source;
  final String? modelRevision;
}

/// Uses the remote policy for captured photos and preserves the existing local
/// engine as a fail-closed, zero-network fallback.
final class HybridPhotoAnalyzer {
  const HybridPhotoAnalyzer({
    required this.api,
    this.localEngine = const PictureAnalysisEngine(),
  });

  final PhotoAnalysisApi api;
  final PictureAnalysisEngine localEngine;

  Future<HybridPhotoAnalysis> analyze(
    ImageStats stats, {
    required String requestId,
    required int frameSeq,
    required String sessionId,
    required int adviceEpoch,
  }) async {
    final local = localEngine.analyze(stats);
    if (!api.configured) {
      return HybridPhotoAnalysis(
        analysis: local,
        source: PhotoAnalysisSource.onDevice,
      );
    }
    try {
      final remote = await api.analyze(
        stats,
        requestId: requestId,
        frameSeq: frameSeq,
        sessionId: sessionId,
        adviceEpoch: adviceEpoch,
      );
      return HybridPhotoAnalysis(
        analysis: remote.analysis,
        source: remote.source,
        modelRevision: remote.modelRevision,
      );
    } on PhotoAnalysisApiException {
      return HybridPhotoAnalysis(
        analysis: local,
        source: PhotoAnalysisSource.onDevice,
      );
    }
  }
}
