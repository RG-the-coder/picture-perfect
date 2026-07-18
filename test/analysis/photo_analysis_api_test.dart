import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picture_perfect/analysis/picture_analysis.dart';

void main() {
  group('PhotoAnalysis backend contract', () {
    test(
      'serializes measurements and accepts pinned model provenance',
      () async {
        late Uri requestedUri;
        late Map<String, Object?> requestJson;
        final transport = _FakeTransport((uri, body, timeout) async {
          requestedUri = uri;
          requestJson = jsonDecode(body) as Map<String, Object?>;
          expect(timeout, const Duration(seconds: 6));
          return PhotoAnalysisHttpResponse(
            statusCode: 200,
            body: jsonEncode(_validResponse()),
            requestId: 'frame-42',
            analysisSource: 'freesolo-validated',
            modelRevision: 'run@final.immutable',
          );
        });
        final api = PhotoAnalysisApi(
          baseUrl: 'http://localhost:8000',
          transport: transport,
        );

        final result = await api.analyze(
          _stats(),
          requestId: 'frame-42',
          frameSeq: 42,
          sessionId: 'session-1',
          adviceEpoch: 3,
        );

        expect(
          requestedUri.toString(),
          'http://localhost:8000/v1/photo-analyses',
        );
        expect(requestJson['schemaVersion'], 1);
        expect(requestJson['requestId'], 'frame-42');
        expect(requestJson['frameSeq'], 42);
        expect(requestJson['mode'], 'capture');
        expect(requestJson['intent'], 'auto');
        expect(requestJson['sessionId'], 'session-1');
        expect(requestJson['adviceEpoch'], 3);
        final measurements =
            requestJson['measurements'] as Map<String, Object?>;
        expect(measurements['brightness'], .30);
        expect(measurements['horizonTiltDegrees'], isNull);
        expect(measurements, isNot(contains('bytes')));
        expect(result.source, PhotoAnalysisSource.freesoloValidated);
        expect(result.modelRevision, 'run@final.immutable');
        expect(result.analysis.steps, hasLength(3));
        expect(transport.calls, 1);
      },
    );

    test(
      'accepts a deterministic backend fallback without model attribution',
      () async {
        final api = PhotoAnalysisApi(
          baseUrl: 'http://localhost:8000/v1',
          transport: _FakeTransport((uri, body, timeout) async {
            return PhotoAnalysisHttpResponse(
              statusCode: 200,
              body: jsonEncode(_validResponse()),
              requestId: 'frame-1',
              analysisSource: 'deterministic-fallback',
            );
          }),
        );

        final result = await api.analyze(
          _stats(),
          requestId: 'frame-1',
          frameSeq: 1,
          sessionId: 'session-1',
          adviceEpoch: 0,
        );

        expect(result.source, PhotoAnalysisSource.deterministicFallback);
        expect(result.modelRevision, isNull);
      },
    );

    test('rejects fallback responses that claim a model revision', () async {
      final api = PhotoAnalysisApi(
        baseUrl: 'http://localhost:8000',
        transport: _FakeTransport((uri, body, timeout) async {
          return PhotoAnalysisHttpResponse(
            statusCode: 200,
            body: jsonEncode(_validResponse()),
            requestId: 'frame-1',
            analysisSource: 'deterministic-fallback',
            modelRevision: 'misleading-revision',
          );
        }),
      );

      expect(
        () => api.analyze(
          _stats(),
          requestId: 'frame-1',
          frameSeq: 1,
          sessionId: 'session-1',
          adviceEpoch: 0,
        ),
        throwsA(isA<PhotoAnalysisApiException>()),
      );
    });

    test('rejects a response for a different request', () async {
      final api = PhotoAnalysisApi(
        baseUrl: 'http://localhost:8000',
        transport: _FakeTransport((uri, body, timeout) async {
          return PhotoAnalysisHttpResponse(
            statusCode: 200,
            body: jsonEncode(_validResponse()),
            requestId: 'stale-frame',
            analysisSource: 'deterministic-fallback',
          );
        }),
      );

      expect(
        () => api.analyze(
          _stats(),
          requestId: 'frame-1',
          frameSeq: 1,
          sessionId: 'session-1',
          adviceEpoch: 0,
        ),
        throwsA(isA<PhotoAnalysisApiException>()),
      );
    });
  });

  group('strict PhotoAnalysis parsing', () {
    test(
      'rejects extra keys, non-integer scores, bad enums, and wrong step count',
      () {
        final extra = _validResponse()..['unexpected'] = true;
        final doubleScore = _validResponse()..['overallScore'] = 80.0;
        final badEnum = _validResponse();
        (badEnum['steps'] as List<Object?>).first = {
          ...(badEnum['steps'] as List<Object?>).first as Map<String, Object?>,
          'priority': 'eventually',
        };
        final shortSteps = _validResponse()
          ..['steps'] = (_validResponse()['steps'] as List<Object?>)
              .take(2)
              .toList();

        expect(() => PhotoAnalysis.fromJson(extra), throwsFormatException);
        expect(
          () => PhotoAnalysis.fromJson(doubleScore),
          throwsFormatException,
        );
        expect(() => PhotoAnalysis.fromJson(badEnum), throwsFormatException);
        expect(() => PhotoAnalysis.fromJson(shortSteps), throwsFormatException);
      },
    );
  });

  group('HybridPhotoAnalyzer', () {
    test('uses the existing local engine when the backend fails', () async {
      final transport = _FakeTransport((uri, body, timeout) async {
        return const PhotoAnalysisHttpResponse(statusCode: 503, body: '');
      });
      final analyzer = HybridPhotoAnalyzer(
        api: PhotoAnalysisApi(
          baseUrl: 'http://localhost:8000',
          transport: transport,
        ),
      );

      final result = await analyzer.analyze(
        _stats(),
        requestId: 'frame-1',
        frameSeq: 1,
        sessionId: 'session-1',
        adviceEpoch: 0,
      );

      expect(result.source, PhotoAnalysisSource.onDevice);
      expect(result.analysis.steps, hasLength(3));
      expect(transport.calls, 1);
    });

    test(
      'does not attempt a request when no backend URL is configured',
      () async {
        final transport = _FakeTransport((uri, body, timeout) async {
          throw StateError('must not be called');
        });
        final analyzer = HybridPhotoAnalyzer(
          api: PhotoAnalysisApi(baseUrl: '', transport: transport),
        );

        final result = await analyzer.analyze(
          _stats(),
          requestId: 'frame-1',
          frameSeq: 1,
          sessionId: 'session-1',
          adviceEpoch: 0,
        );

        expect(result.source, PhotoAnalysisSource.onDevice);
        expect(transport.calls, 0);
      },
    );

    test('times out once and falls back without retrying', () async {
      final transport = _FakeTransport((uri, body, timeout) {
        return Completer<PhotoAnalysisHttpResponse>().future;
      });
      final analyzer = HybridPhotoAnalyzer(
        api: PhotoAnalysisApi(
          baseUrl: 'http://localhost:8000',
          transport: transport,
          timeout: const Duration(milliseconds: 5),
        ),
      );

      final result = await analyzer.analyze(
        _stats(),
        requestId: 'frame-1',
        frameSeq: 1,
        sessionId: 'session-1',
        adviceEpoch: 0,
      );

      expect(result.source, PhotoAnalysisSource.onDevice);
      expect(transport.calls, 1);
    });
  });
}

ImageStats _stats() => ImageStats(
  width: 640,
  height: 480,
  brightness: .30,
  contrast: .50,
  sharpness: .80,
  saturation: .50,
  highlightClipping: 0,
  shadowClipping: .08,
  subjectX: .50,
  subjectY: .50,
  colorCast: .02,
);

Map<String, Object?> _validResponse() => {
  'overallScore': 80,
  'compositionScore': 81,
  'lightingScore': 79,
  'clarityScore': 82,
  'colorScore': 78,
  'steps': <Object?>[
    {
      'title': 'Brighten the frame',
      'instruction': 'Raise exposure by 0.3 stops.',
      'priority': 'high',
      'overlay': 'exposure',
    },
    {
      'title': 'Lock focus',
      'instruction': 'Tap the subject and hold steady.',
      'priority': 'medium',
      'overlay': 'focus',
    },
    {
      'title': 'Protect highlights',
      'instruction': 'Keep the brightest detail below clipping.',
      'priority': 'low',
      'overlay': 'none',
    },
  ],
};

typedef _Handler =
    Future<PhotoAnalysisHttpResponse> Function(
      Uri uri,
      String body,
      Duration timeout,
    );

final class _FakeTransport implements PhotoAnalysisTransport {
  _FakeTransport(this.handler);

  final _Handler handler;
  int calls = 0;

  @override
  Future<PhotoAnalysisHttpResponse> postJson(
    Uri uri, {
    required String body,
    required Duration timeout,
  }) {
    calls++;
    return handler(uri, body, timeout);
  }
}
