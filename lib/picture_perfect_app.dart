import 'package:flutter/material.dart';

import 'analysis/photo_analysis_api.dart';
import 'studio_page.dart';
import 'theme/app_theme.dart';

class PicturePerfectApp extends StatelessWidget {
  const PicturePerfectApp({super.key, this.analysisApi});

  final PhotoAnalysisApi? analysisApi;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picture Perfect',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: StudioPage(analysisApi: analysisApi),
    );
  }
}
