import 'dart:typed_data';
import 'dart:ui' as ui;

/// Creates a small, original demo frame entirely on-device.
///
/// It keeps the initial app download self-contained and gives visitors a way to
/// explore the analysis flow without granting permissions or choosing a file.
abstract final class DemoImageFactory {
  static Future<Uint8List> create() async {
    const size = ui.Size(1200, 900);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final sky = ui.Paint()
      ..shader = ui.Gradient.linear(
        const ui.Offset(0, 0),
        const ui.Offset(0, 650),
        const [
          ui.Color(0xFF183956),
          ui.Color(0xFF7C9BA2),
          ui.Color(0xFFE6B37E),
        ],
        const [0, .58, 1],
      );
    canvas.drawRect(ui.Offset.zero & size, sky);

    final glow = ui.Paint()
      ..shader = ui.Gradient.radial(const ui.Offset(850, 255), 260, const [
        ui.Color(0xAAFFD69D),
        ui.Color(0x00FFD69D),
      ]);
    canvas.drawCircle(const ui.Offset(850, 255), 260, glow);
    canvas.drawCircle(
      const ui.Offset(850, 255),
      72,
      ui.Paint()..color = const ui.Color(0xFFFFDDA9),
    );

    final backMountain = ui.Path()
      ..moveTo(0, 520)
      ..lineTo(210, 330)
      ..lineTo(390, 475)
      ..lineTo(570, 285)
      ..lineTo(785, 520)
      ..close();
    canvas.drawPath(
      backMountain,
      ui.Paint()..color = const ui.Color(0xFF415E63),
    );

    final frontMountain = ui.Path()
      ..moveTo(0, 555)
      ..lineTo(260, 430)
      ..lineTo(450, 600)
      ..lineTo(710, 395)
      ..lineTo(970, 590)
      ..lineTo(1200, 455)
      ..lineTo(1200, 740)
      ..lineTo(0, 740)
      ..close();
    canvas.drawPath(
      frontMountain,
      ui.Paint()..color = const ui.Color(0xFF263F42),
    );

    final water = ui.Paint()
      ..shader = ui.Gradient.linear(
        const ui.Offset(0, 610),
        const ui.Offset(0, 900),
        const [ui.Color(0xFF365963), ui.Color(0xFF132D35)],
      );
    canvas.drawRect(const ui.Rect.fromLTWH(0, 610, 1200, 290), water);
    for (var index = 0; index < 13; index++) {
      final y = 640.0 + index * 19;
      final opacity = 100 - index * 5;
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(700 + index * 7, y, 300 - index * 14, 4),
          const ui.Radius.circular(4),
        ),
        ui.Paint()
          ..color = ui.Color.fromARGB(opacity.clamp(20, 100), 255, 207, 146),
      );
    }

    final shoreline = ui.Path()
      ..moveTo(0, 735)
      ..quadraticBezierTo(300, 680, 610, 780)
      ..quadraticBezierTo(900, 850, 1200, 790)
      ..lineTo(1200, 900)
      ..lineTo(0, 900)
      ..close();
    canvas.drawPath(shoreline, ui.Paint()..color = const ui.Color(0xFF0B1A19));

    // A small hiker gives the analysis engine an off-center visual anchor.
    canvas.drawCircle(
      const ui.Offset(385, 610),
      27,
      ui.Paint()..color = const ui.Color(0xFF111B1A),
    );
    final person = ui.Path()
      ..moveTo(355, 646)
      ..quadraticBezierTo(385, 626, 416, 649)
      ..lineTo(430, 761)
      ..lineTo(397, 761)
      ..lineTo(385, 690)
      ..lineTo(371, 761)
      ..lineTo(336, 761)
      ..close();
    canvas.drawPath(person, ui.Paint()..color = const ui.Color(0xFF111B1A));
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(340, 650, 62, 78),
        const ui.Radius.circular(18),
      ),
      ui.Paint()..color = const ui.Color(0xFFBD5E3E),
    );

    final vignette = ui.Paint()
      ..shader = ui.Gradient.radial(
        const ui.Offset(600, 430),
        760,
        const [ui.Color(0x00000000), ui.Color(0x66000000)],
        const [.55, 1],
      );
    canvas.drawRect(ui.Offset.zero & size, vignette);

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    picture.dispose();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Could not encode the demo image.');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}
