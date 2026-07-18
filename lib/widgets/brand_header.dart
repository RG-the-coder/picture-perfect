import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Picture Perfect home',
      button: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 36 : 42,
            height: compact ? 36 : 42,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(compact ? 11 : 13),
            ),
            child: Icon(
              Icons.camera_rounded,
              size: compact ? 19 : 22,
              color: AppColors.background,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Picture Perfect',
            style: TextStyle(
              color: AppColors.text,
              fontSize: compact ? 17 : 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -.45,
            ),
          ),
        ],
      ),
    );
  }
}

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.onLogoTap,
    this.trailing,
    this.maxWidth = 1360,
  });

  final VoidCallback onLogoTap;
  final Widget? trailing;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Row(
            children: [
              InkWell(
                onTap: onLogoTap,
                borderRadius: BorderRadius.circular(14),
                child: const BrandLockup(),
              ),
              const Spacer(),
              trailing ?? const PrivacyPill(),
            ],
          ),
        ),
      ),
    );
  }
}

class PrivacyPill extends StatelessWidget {
  const PrivacyPill({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 11 : 14,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 15,
            color: AppColors.accent,
          ),
          const SizedBox(width: 7),
          Text(
            compact ? 'Photos private' : 'Photo pixels stay private',
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class Eyebrow extends StatelessWidget {
  const Eyebrow({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.accent, size: 17),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.25,
          ),
        ),
      ],
    );
  }
}
