import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picture_perfect/analysis/pixel_profiler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodes encoded PNG bytes through the browser-safe codec path', () async {
    // A self-contained 1x1 PNG keeps this regression runnable in Chrome,
    // where ImageDescriptor width/height getters are unsupported.
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    final profile = await PixelProfiler.analyze(bytes);

    expect(profile.width, 1);
    expect(profile.height, 1);
    expect(profile.meanLuminance, inInclusiveRange(0, 1));
  });
}
