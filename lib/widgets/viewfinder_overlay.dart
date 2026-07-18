import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../analysis/picture_analysis.dart';
import '../theme/app_theme.dart';

class ViewfinderGrid extends StatelessWidget {
  const ViewfinderGrid({super.key, this.color = const Color(0x5CFFFFFF)});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: _GridPainter(color), size: Size.infinite),
    );
  }
}

class ResultOverlay extends StatelessWidget {
  const ResultOverlay({super.key, required this.type});

  final OverlayType type;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: switch (type) {
          OverlayType.ruleOfThirds => const ViewfinderGrid(
            key: ValueKey('thirds'),
            color: AppColors.accent,
          ),
          OverlayType.subjectGuide => const _SubjectGuide(
            key: ValueKey('subject'),
          ),
          OverlayType.level => const _LevelGuide(key: ValueKey('level')),
          OverlayType.exposure => const _ExposureGuide(
            key: ValueKey('exposure'),
          ),
          OverlayType.focus => const _FocusGuide(key: ValueKey('focus')),
          OverlayType.colorBalance => const _ColorGuide(key: ValueKey('color')),
          OverlayType.none => const SizedBox.shrink(key: ValueKey('none')),
        },
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final fraction in const [1 / 3, 2 / 3]) {
      canvas.drawLine(
        Offset(size.width * fraction, 0),
        Offset(size.width * fraction, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * fraction),
        Offset(size.width, size.height * fraction),
        paint,
      );
    }
    final cornerPaint = Paint()
      ..color = color.withValues(alpha: .9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const length = 18.0;
    const inset = 14.0;
    final points = [
      (Offset(inset, inset), 0.0),
      (Offset(size.width - inset, inset), math.pi / 2),
      (Offset(size.width - inset, size.height - inset), math.pi),
      (Offset(inset, size.height - inset), math.pi * 1.5),
    ];
    for (final (point, rotation) in points) {
      canvas.save();
      canvas.translate(point.dx, point.dy);
      canvas.rotate(rotation);
      final path = Path()
        ..moveTo(0, length)
        ..lineTo(0, 0)
        ..lineTo(length, 0);
      canvas.drawPath(path, cornerPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SubjectGuide extends StatelessWidget {
  const _SubjectGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: .42,
        heightFactor: .56,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.accent, width: 2),
            color: AppColors.accent.withValues(alpha: .06),
          ),
        ),
      ),
    );
  }
}

class _LevelGuide extends StatelessWidget {
  const _LevelGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        children: [
          Expanded(child: Container(height: 2, color: AppColors.accent)),
          Container(
            width: 44,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.accent),
            ),
            child: const Icon(
              Icons.horizontal_rule_rounded,
              size: 18,
              color: AppColors.accent,
            ),
          ),
          Expanded(child: Container(height: 2, color: AppColors.accent)),
        ],
      ),
    );
  }
}

class _ExposureGuide extends StatelessWidget {
  const _ExposureGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: .12)),
      child: const Center(
        child: Icon(Icons.wb_sunny_outlined, color: AppColors.accent, size: 58),
      ),
    );
  }
}

class _FocusGuide extends StatelessWidget {
  const _FocusGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox.square(
        dimension: 82,
        child: CircularProgressIndicator(
          value: .78,
          strokeWidth: 2,
          color: AppColors.accent,
          backgroundColor: Color(0x55FFFFFF),
        ),
      ),
    );
  }
}

class _ColorGuide extends StatelessWidget {
  const _ColorGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0x557ACBFF), Colors.transparent, Color(0x55FFC86B)],
      ).createShader(bounds),
      blendMode: BlendMode.srcOver,
      child: const ColoredBox(color: Colors.white),
    );
  }
}
