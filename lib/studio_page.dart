import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analysis/picture_analysis.dart';
import 'analysis/pixel_profiler.dart';
import 'capture/web_capture_stub.dart'
    if (dart.library.html) 'capture/web_capture.dart';
import 'demo_image_factory.dart';
import 'theme/app_theme.dart';
import 'widgets/brand_header.dart';
import 'widgets/viewfinder_overlay.dart';

enum _StudioStage { welcome, camera, analyzing, results }

class StudioPage extends StatefulWidget {
  const StudioPage({super.key, this.analysisApi});

  final PhotoAnalysisApi? analysisApi;

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  static const _maxUploadBytes = 18 * 1024 * 1024;
  static const _analysisLabels = [
    'Reading the light…',
    'Checking composition…',
    'Measuring clarity…',
    'Building your shot plan…',
  ];

  late final WebCameraController _camera;
  late final Future<Uint8List> _demoImage;
  late final HybridPhotoAnalyzer _hybridAnalyzer;
  late final String _analysisSessionId;

  _StudioStage _stage = _StudioStage.welcome;
  Uint8List? _photoBytes;
  String _photoName = '';
  PhotoAnalysis? _analysis;
  PhotoAnalysisSource _analysisSource = PhotoAnalysisSource.onDevice;
  String? _modelRevision;
  OverlayType _activeOverlay = OverlayType.none;
  int? _selectedStep;
  bool _showGrid = true;
  bool _guidedRetake = false;
  bool _liveAnalysisBusy = false;
  String _liveLight = 'Position your shot, then hold steady.';
  IconData _liveIcon = Icons.center_focus_strong_rounded;
  Color _liveColor = AppColors.blue;
  int _analysisLabelIndex = 0;
  Timer? _analysisTicker;
  Timer? _liveTicker;
  int _analysisRequestToken = 0;
  int _frameSequence = 0;
  int _adviceEpoch = 0;

  @override
  void initState() {
    super.initState();
    _camera = WebCameraController(initialFacing: WebCameraFacing.back);
    _demoImage = DemoImageFactory.create();
    _hybridAnalyzer = HybridPhotoAnalyzer(
      api: widget.analysisApi ?? PhotoAnalysisApi.fromEnvironment(),
    );
    _analysisSessionId =
        'session-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  }

  @override
  void dispose() {
    _analysisTicker?.cancel();
    _liveTicker?.cancel();
    _camera.dispose();
    super.dispose();
  }

  Future<void> _openCamera({bool guided = false}) async {
    _analysisTicker?.cancel();
    setState(() {
      _guidedRetake = guided;
      _stage = _StudioStage.camera;
      _liveLight = 'Starting Live Assist…';
      _liveIcon = Icons.auto_awesome_rounded;
      _liveColor = AppColors.blue;
    });
    try {
      await _camera.startCamera();
      if (!mounted) {
        return;
      }
      setState(() {
        _liveLight = 'Light and framing checks are active.';
        _liveIcon = Icons.check_circle_outline_rounded;
        _liveColor = AppColors.accent;
      });
      _startLiveAssist();
    } on WebCaptureException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      setState(() {});
    }
  }

  void _startLiveAssist() {
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(milliseconds: 2400), (_) async {
      if (!mounted || _stage != _StudioStage.camera || !_camera.isStreaming) {
        return;
      }
      if (_liveAnalysisBusy) return;
      _liveAnalysisBusy = true;
      try {
        final bytes = await _camera.capturePngBytes();
        final profile = await PixelProfiler.analyze(bytes);
        if (!mounted || _stage != _StudioStage.camera) return;
        setState(() {
          if (profile.meanLuminance < .34) {
            _liveLight = 'Scene is dark — turn toward a window or lamp.';
            _liveIcon = Icons.wb_sunny_outlined;
            _liveColor = AppColors.amber;
          } else if (profile.meanLuminance > .72 ||
              profile.highlightsClipped > .12) {
            _liveLight =
                'Highlights are bright — angle away from direct light.';
            _liveIcon = Icons.flare_rounded;
            _liveColor = AppColors.amber;
          } else if (profile.sharpness < .30) {
            _liveLight = 'Hold steady and tap your subject to focus.';
            _liveIcon = Icons.center_focus_weak_rounded;
            _liveColor = AppColors.blue;
          } else {
            _liveLight = 'Light looks balanced. Ready when you are.';
            _liveIcon = Icons.check_circle_outline_rounded;
            _liveColor = AppColors.accent;
          }
        });
      } catch (_) {
        // Live Assist is supplemental. A single dropped frame should not
        // interrupt the camera or surface a noisy error to the user.
      } finally {
        _liveAnalysisBusy = false;
      }
    });
  }

  void _closeCamera() {
    _liveTicker?.cancel();
    _camera.stopCamera();
    setState(() => _stage = _StudioStage.welcome);
  }

  Future<void> _switchCamera() async {
    try {
      await _camera.switchCamera();
    } on WebCaptureException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  Future<void> _capturePhoto() async {
    if (!_camera.isStreaming) return;
    try {
      final frame = await _camera.captureFrame();
      _liveTicker?.cancel();
      _camera.stopCamera();
      await _analyze(frame.bytes, frame.name);
    } on WebCaptureException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await pickImageFromBrowser(maxBytes: _maxUploadBytes);
      if (picked == null) return;
      await _analyze(picked.bytes, picked.name);
    } on WebCaptureException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) {
        _showMessage(
          'That file could not be opened. Try a JPG, PNG, or WebP image.',
        );
      }
    }
  }

  Future<void> _tryDemo() async {
    final bytes = await _demoImage;
    if (!mounted) return;
    await _analyze(bytes, 'mountain-light-demo.png');
  }

  Future<void> _analyze(Uint8List bytes, String name) async {
    final requestToken = ++_analysisRequestToken;
    final frameSequence = ++_frameSequence;
    final adviceEpoch = _adviceEpoch++;
    final requestId =
        'frame-$frameSequence-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _camera.stopCamera();
    _liveTicker?.cancel();
    _analysisTicker?.cancel();
    setState(() {
      _photoBytes = bytes;
      _photoName = name;
      _analysis = null;
      _analysisSource = PhotoAnalysisSource.onDevice;
      _modelRevision = null;
      _activeOverlay = OverlayType.none;
      _selectedStep = null;
      _analysisLabelIndex = 0;
      _stage = _StudioStage.analyzing;
    });

    _analysisTicker = Timer.periodic(const Duration(milliseconds: 390), (_) {
      if (!mounted || _stage != _StudioStage.analyzing) return;
      setState(() {
        _analysisLabelIndex = (_analysisLabelIndex + 1).clamp(
          0,
          _analysisLabels.length - 1,
        );
      });
    });

    try {
      final minimumSpinner = Future<void>.delayed(
        const Duration(milliseconds: 1250),
      );
      final profile = await PixelProfiler.analyze(bytes);
      final stats = ImageStats(
        width: profile.width,
        height: profile.height,
        brightness: profile.meanLuminance,
        contrast: profile.contrast,
        sharpness: profile.sharpness,
        saturation: profile.saturation,
        highlightClipping: profile.highlightsClipped,
        shadowClipping: profile.shadowsClipped,
        subjectX: profile.subjectX,
        subjectY: profile.subjectY,
        colorCast: profile.warmth.abs(),
        // Noise-versus-texture and horizon detection need calibrated models.
        // Their safe unknown defaults (0 and null) avoid invented corrections.
      );
      final analysisFuture = _hybridAnalyzer.analyze(
        stats,
        requestId: requestId,
        frameSeq: frameSequence,
        sessionId: _analysisSessionId,
        adviceEpoch: adviceEpoch,
      );
      await minimumSpinner;
      final resolved = await analysisFuture;
      _analysisTicker?.cancel();
      if (!mounted || requestToken != _analysisRequestToken) return;
      setState(() {
        _analysis = resolved.analysis;
        _analysisSource = resolved.source;
        _modelRevision = resolved.modelRevision;
        _stage = _StudioStage.results;
      });
    } catch (error, stackTrace) {
      debugPrint('Picture Perfect could not analyze "$name": $error');
      debugPrintStack(stackTrace: stackTrace);
      _analysisTicker?.cancel();
      if (!mounted || requestToken != _analysisRequestToken) return;
      setState(() => _stage = _StudioStage.welcome);
      _showMessage(
        error is FormatException
            ? 'That image contains data this browser cannot decode. Try a JPG, PNG, or WebP file.'
            : 'This browser could not analyze the image. Refresh once and try again.',
      );
    }
  }

  void _goHome() {
    _analysisRequestToken++;
    _liveTicker?.cancel();
    _analysisTicker?.cancel();
    _camera.stopCamera();
    setState(() {
      _stage = _StudioStage.welcome;
      _activeOverlay = OverlayType.none;
      _selectedStep = null;
      _guidedRetake = false;
    });
  }

  Future<void> _copyShotPlan() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final plan = [
      'PICTURE PERFECT SHOT PLAN',
      'Score: ${analysis.overallScore}/100',
      '',
      for (var index = 0; index < analysis.steps.length; index++)
        '${index + 1}. ${analysis.steps[index].title}\n${analysis.steps[index].instruction}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: plan));
    if (mounted) _showMessage('Shot plan copied.');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (_stage) {
      _StudioStage.welcome => _WelcomeView(
        demoImage: _demoImage,
        onOpenCamera: _openCamera,
        onPickPhoto: _pickPhoto,
        onTryDemo: _tryDemo,
        onLogoTap: _goHome,
      ),
      _StudioStage.camera => _CameraView(
        controller: _camera,
        showGrid: _showGrid,
        liveMessage: _liveLight,
        liveIcon: _liveIcon,
        liveColor: _liveColor,
        guidedSteps: _guidedRetake ? _analysis?.steps : null,
        onClose: _closeCamera,
        onCapture: _capturePhoto,
        onSwitchCamera: _switchCamera,
        onUpload: _pickPhoto,
        onToggleGrid: () => setState(() => _showGrid = !_showGrid),
      ),
      _StudioStage.analyzing => _AnalyzingView(
        photoBytes: _photoBytes!,
        label: _analysisLabels[_analysisLabelIndex],
        onCancel: _goHome,
      ),
      _StudioStage.results => _ResultsView(
        photoBytes: _photoBytes!,
        photoName: _photoName,
        analysis: _analysis!,
        analysisSource: _analysisSource,
        modelRevision: _modelRevision,
        activeOverlay: _activeOverlay,
        selectedStep: _selectedStep,
        onLogoTap: _goHome,
        onSelectStep: (index) {
          final step = _analysis!.steps[index];
          setState(() {
            if (_selectedStep == index) {
              _selectedStep = null;
              _activeOverlay = OverlayType.none;
            } else {
              _selectedStep = index;
              _activeOverlay = step.overlay;
            }
          });
        },
        onRetake: () => _openCamera(guided: true),
        onAnalyzeAnother: _pickPhoto,
        onCopy: _copyShotPlan,
      ),
    };

    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: KeyedSubtree(key: ValueKey(_stage), child: content),
        ),
      ),
    );
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView({
    required this.demoImage,
    required this.onOpenCamera,
    required this.onPickPhoto,
    required this.onTryDemo,
    required this.onLogoTap,
  });

  final Future<Uint8List> demoImage;
  final VoidCallback onOpenCamera;
  final VoidCallback onPickPhoto;
  final VoidCallback onTryDemo;
  final VoidCallback onLogoTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppHeader(onLogoTap: onLogoTap),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1260),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 920;
                    final copy = _WelcomeCopy(
                      onOpenCamera: onOpenCamera,
                      onPickPhoto: onPickPhoto,
                      onTryDemo: onTryDemo,
                    );
                    final preview = _HeroPreview(
                      demoImage: demoImage,
                      onTryDemo: onTryDemo,
                    );
                    return Column(
                      children: [
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(flex: 10, child: copy),
                              const SizedBox(width: 68),
                              Expanded(flex: 11, child: preview),
                            ],
                          )
                        else ...[
                          copy,
                          const SizedBox(height: 42),
                          preview,
                        ],
                        const SizedBox(height: 64),
                        const _HowItWorks(),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WelcomeCopy extends StatelessWidget {
  const _WelcomeCopy({
    required this.onOpenCamera,
    required this.onPickPhoto,
    required this.onTryDemo,
  });

  final VoidCallback onOpenCamera;
  final VoidCallback onPickPhoto;
  final VoidCallback onTryDemo;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Eyebrow(
          icon: Icons.auto_awesome_rounded,
          label: 'Your privacy-first photo coach',
        ),
        const SizedBox(height: 24),
        Text(
          'Take the shot\nyou meant to take.',
          style: compact
              ? Theme.of(
                  context,
                ).textTheme.displayMedium?.copyWith(fontSize: 44)
              : Theme.of(context).textTheme.displayLarge,
        ),
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            'Capture or upload a photo. Picture Perfect reads the light, clarity, and composition, then gives you an exact step-by-step shot plan.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 30),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: onOpenCamera,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Open camera'),
            ),
            OutlinedButton.icon(
              onPressed: onPickPhoto,
              icon: const Icon(Icons.upload_rounded),
              label: const Text('Upload a photo'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            TextButton.icon(
              onPressed: onTryDemo,
              style: TextButton.styleFrom(foregroundColor: AppColors.text),
              icon: const Icon(Icons.play_circle_outline_rounded, size: 19),
              label: const Text('Try a sample shot'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'No account needed',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroPreview extends StatelessWidget {
  const _HeroPreview({required this.demoImage, required this.onTryDemo});

  final Future<Uint8List> demoImage;
  final VoidCallback onTryDemo;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: .012,
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppColors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 44,
              offset: Offset(0, 20),
            ),
          ],
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(21),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List>(
                      future: demoImage,
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const ColoredBox(
                            color: AppColors.surfaceLight,
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                          semanticLabel:
                              'Mountain lake sample photograph at sunset',
                        );
                      },
                    ),
                    const ViewfinderGrid(),
                    Positioned(
                      left: 14,
                      top: 14,
                      child: _MiniBadge(
                        icon: Icons.bolt_rounded,
                        label: 'LIVE ASSIST',
                        color: AppColors.accent,
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 14,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background.withValues(alpha: .86),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              color: AppColors.accent,
                              size: 20,
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Light is balanced · framing looks strong',
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 13, 6, 4),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      'Real guidance. Your photo stays on this device.',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onTryDemo,
                    child: const Text('Analyze this'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    const items = [
      (
        Icons.add_a_photo_outlined,
        '01',
        'Capture',
        'Use Live Assist or choose a photo you already have.',
      ),
      (
        Icons.analytics_outlined,
        '02',
        'Understand',
        'We measure light, balance, color, and visible detail locally.',
      ),
      (
        Icons.checklist_rounded,
        '03',
        'Perfect it',
        'Follow three clear changes, then retake with coaching pinned.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 760;
        final cards = [for (final item in items) _ProcessCard(item: item)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A better photo in three moves',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 20),
            if (stacked)
              ...cards.expand((card) => [card, const SizedBox(height: 12)])
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children:
                    cards
                        .expand(
                          (card) => [
                            Expanded(child: card),
                            const SizedBox(width: 14),
                          ],
                        )
                        .toList()
                      ..removeLast(),
              ),
          ],
        );
      },
    );
  }
}

class _ProcessCard extends StatelessWidget {
  const _ProcessCard({required this.item});

  final (IconData, String, String, String) item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(item.$1, color: AppColors.accent, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.$3,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      item.$2,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(item.$4, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalyzingView extends StatelessWidget {
  const _AnalyzingView({
    required this.photoBytes,
    required this.label,
    required this.onCancel,
  });

  final Uint8List photoBytes;
  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Image.memory(
            photoBytes,
            fit: BoxFit.cover,
            color: const Color(0x99090C0A),
            colorBlendMode: BlendMode.srcOver,
            semanticLabel: 'Photo being analyzed',
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.background.withValues(alpha: .55),
                  AppColors.background.withValues(alpha: .82),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: Semantics(
            liveRegion: true,
            label: label,
            child: Container(
              width: 430,
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: .96),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.border),
                boxShadow: const [
                  BoxShadow(color: Color(0x88000000), blurRadius: 50),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: AppColors.accentDark,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: AppColors.accent,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Studying your frame',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 9),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      label,
                      key: ValueKey(label),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  const SizedBox(height: 25),
                  const ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(99)),
                    child: LinearProgressIndicator(minHeight: 5),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Your image stays on this device.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraView extends StatelessWidget {
  const _CameraView({
    required this.controller,
    required this.showGrid,
    required this.liveMessage,
    required this.liveIcon,
    required this.liveColor,
    required this.guidedSteps,
    required this.onClose,
    required this.onCapture,
    required this.onSwitchCamera,
    required this.onUpload,
    required this.onToggleGrid,
  });

  final WebCameraController controller;
  final bool showGrid;
  final String liveMessage;
  final IconData liveIcon;
  final Color liveColor;
  final List<CoachingStep>? guidedSteps;
  final VoidCallback onClose;
  final VoidCallback onCapture;
  final VoidCallback onSwitchCamera;
  final VoidCallback onUpload;
  final VoidCallback onToggleGrid;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppHeader(
          onLogoTap: onClose,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (MediaQuery.sizeOf(context).width >= 540)
                const _MiniBadge(
                  icon: Icons.bolt_rounded,
                  label: 'LIVE ASSIST ON',
                  color: AppColors.accent,
                ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onClose,
                tooltip: 'Close camera',
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 880;
                    final preview = _CameraStage(
                      controller: controller,
                      showGrid: showGrid,
                      liveColor: liveColor,
                      onCapture: onCapture,
                      onSwitchCamera: onSwitchCamera,
                      onUpload: onUpload,
                      onToggleGrid: onToggleGrid,
                    );
                    final rail = _CameraCoachingRail(
                      liveMessage: liveMessage,
                      liveIcon: liveIcon,
                      liveColor: liveColor,
                      guidedSteps: guidedSteps,
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: 18),
                          SizedBox(width: 330, child: rail),
                        ],
                      );
                    }
                    return Column(
                      children: [preview, const SizedBox(height: 16), rail],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CameraStage extends StatelessWidget {
  const _CameraStage({
    required this.controller,
    required this.showGrid,
    required this.liveColor,
    required this.onCapture,
    required this.onSwitchCamera,
    required this.onUpload,
    required this.onToggleGrid,
  });

  final WebCameraController controller;
  final bool showGrid;
  final Color liveColor;
  final VoidCallback onCapture;
  final VoidCallback onSwitchCamera;
  final VoidCallback onUpload;
  final VoidCallback onToggleGrid;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: AspectRatio(
          aspectRatio: mobile ? 3 / 4 : 4 / 3,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF050706)),
                  if (controller.status == WebCameraStatus.streaming)
                    WebCameraPreview(controller: controller),
                  if (controller.status == WebCameraStatus.starting)
                    const _CameraLoading(),
                  if (controller.status == WebCameraStatus.error)
                    _CameraError(
                      message:
                          controller.lastError?.message ??
                          'The camera could not start.',
                      onTryAgain: controller.startCamera,
                      onUpload: onUpload,
                    ),
                  if (controller.status == WebCameraStatus.idle)
                    const Center(
                      child: Text(
                        'Camera is off',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    ),
                  if (showGrid &&
                      controller.status == WebCameraStatus.streaming)
                    const ViewfinderGrid(),
                  if (controller.status == WebCameraStatus.streaming) ...[
                    Positioned(
                      top: 13,
                      left: 13,
                      child: _MiniBadge(
                        icon: Icons.circle,
                        label: 'LIVE',
                        color: liveColor,
                      ),
                    ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Row(
                        children: [
                          _CameraIconButton(
                            tooltip: showGrid ? 'Hide grid' : 'Show grid',
                            icon: Icons.grid_3x3_rounded,
                            active: showGrid,
                            onPressed: onToggleGrid,
                          ),
                          const SizedBox(width: 8),
                          _CameraIconButton(
                            tooltip: 'Switch camera',
                            icon: Icons.cameraswitch_outlined,
                            onPressed: onSwitchCamera,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 18,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _CameraIconButton(
                            tooltip: 'Upload instead',
                            icon: Icons.photo_library_outlined,
                            onPressed: onUpload,
                          ),
                          const SizedBox(width: 30),
                          Semantics(
                            button: true,
                            label: 'Take picture',
                            child: InkWell(
                              onTap: onCapture,
                              customBorder: const CircleBorder(),
                              child: Container(
                                width: 78,
                                height: 78,
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.text,
                                    width: 3,
                                  ),
                                  color: AppColors.background.withValues(
                                    alpha: .4,
                                  ),
                                ),
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 30),
                          _CameraIconButton(
                            tooltip: 'Switch camera',
                            icon: Icons.flip_camera_ios_outlined,
                            onPressed: onSwitchCamera,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CameraLoading extends StatelessWidget {
  const _CameraLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 18),
          Text(
            'Waiting for camera permission…',
            style: TextStyle(color: AppColors.text),
          ),
          SizedBox(height: 6),
          Text(
            'Choose Allow in your browser.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({
    required this.message,
    required this.onTryAgain,
    required this.onUpload,
  });

  final String message;
  final VoidCallback onTryAgain;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF2B1715),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.videocam_off_outlined,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Camera unavailable',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 9),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                    onPressed: onTryAgain,
                    child: const Text('Try again'),
                  ),
                  OutlinedButton(
                    onPressed: onUpload,
                    child: const Text('Upload instead'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraIconButton extends StatelessWidget {
  const _CameraIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        backgroundColor: active
            ? AppColors.accent
            : AppColors.background.withValues(alpha: .68),
        foregroundColor: active ? AppColors.background : AppColors.text,
        side: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class _CameraCoachingRail extends StatelessWidget {
  const _CameraCoachingRail({
    required this.liveMessage,
    required this.liveIcon,
    required this.liveColor,
    required this.guidedSteps,
  });

  final String liveMessage;
  final IconData liveIcon;
  final Color liveColor;
  final List<CoachingStep>? guidedSteps;

  @override
  Widget build(BuildContext context) {
    final guided = guidedSteps != null && guidedSteps!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Eyebrow(icon: Icons.bolt_rounded, label: 'Live Assist'),
              const SizedBox(height: 18),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Row(
                  key: ValueKey(liveMessage),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: liveColor.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(liveIcon, color: liveColor, size: 21),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          liveMessage,
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(height: 1.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Text(
                'A lightweight frame check runs every few seconds. Nothing leaves your browser.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                guided ? 'Pinned shot plan' : 'Before you shoot',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 15),
              if (guided)
                for (var index = 0; index < guidedSteps!.length; index++)
                  _PinnedStep(index: index, step: guidedSteps![index])
              else ...[
                const _CameraCheck(
                  icon: Icons.light_mode_outlined,
                  text: 'Face the softest light',
                ),
                const _CameraCheck(
                  icon: Icons.grid_3x3_rounded,
                  text: 'Keep edges distraction-free',
                ),
                const _CameraCheck(
                  icon: Icons.pan_tool_alt_outlined,
                  text: 'Hold still for one beat',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CameraCheck extends StatelessWidget {
  const _CameraCheck({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: AppColors.muted, size: 19),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PinnedStep extends StatelessWidget {
  const _PinnedStep({required this.index, required this.step});

  final int index;
  final CoachingStep step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 27,
            height: 27,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: index == 0 ? AppColors.accent : AppColors.surfaceLight,
              shape: BoxShape.circle,
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: index == 0 ? AppColors.background : AppColors.text,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              step.title,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsView extends StatelessWidget {
  const _ResultsView({
    required this.photoBytes,
    required this.photoName,
    required this.analysis,
    required this.analysisSource,
    required this.modelRevision,
    required this.activeOverlay,
    required this.selectedStep,
    required this.onLogoTap,
    required this.onSelectStep,
    required this.onRetake,
    required this.onAnalyzeAnother,
    required this.onCopy,
  });

  final Uint8List photoBytes;
  final String photoName;
  final PhotoAnalysis analysis;
  final PhotoAnalysisSource analysisSource;
  final String? modelRevision;
  final OverlayType activeOverlay;
  final int? selectedStep;
  final VoidCallback onLogoTap;
  final ValueChanged<int> onSelectStep;
  final VoidCallback onRetake;
  final VoidCallback onAnalyzeAnother;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppHeader(
          onLogoTap: onLogoTap,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (MediaQuery.sizeOf(context).width >= 560)
                const PrivacyPill(compact: true),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Close results',
                onPressed: onLogoTap,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 42),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1260),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 960;
                    final photo = _ResultPhoto(
                      bytes: photoBytes,
                      name: photoName,
                      overlay: activeOverlay,
                      analysisSource: analysisSource,
                      modelRevision: modelRevision,
                    );
                    final report = _ResultReport(
                      analysis: analysis,
                      analysisSource: analysisSource,
                      selectedStep: selectedStep,
                      onSelectStep: onSelectStep,
                      onRetake: onRetake,
                      onAnalyzeAnother: onAnalyzeAnother,
                      onCopy: onCopy,
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 11, child: photo),
                          const SizedBox(width: 22),
                          Expanded(flex: 10, child: report),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [photo, const SizedBox(height: 20), report],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultPhoto extends StatelessWidget {
  const _ResultPhoto({
    required this.bytes,
    required this.name,
    required this.overlay,
    required this.analysisSource,
    required this.modelRevision,
  });

  final Uint8List bytes;
  final String name;
  final OverlayType overlay;
  final PhotoAnalysisSource analysisSource;
  final String? modelRevision;

  @override
  Widget build(BuildContext context) {
    final badge = switch (analysisSource) {
      PhotoAnalysisSource.freesoloValidated => (
        Icons.auto_awesome_rounded,
        'AI-VALIDATED PLAN',
        AppColors.blue,
      ),
      PhotoAnalysisSource.deterministicFallback => (
        Icons.verified_outlined,
        'RULE-VERIFIED PLAN',
        AppColors.accent,
      ),
      PhotoAnalysisSource.onDevice => (
        Icons.memory_rounded,
        'ON-DEVICE FALLBACK',
        AppColors.accent,
      ),
    };
    final provenanceHint = switch (analysisSource) {
      PhotoAnalysisSource.freesoloValidated =>
        'Accepted from ${modelRevision ?? 'the pinned 4B model'}',
      PhotoAnalysisSource.deterministicFallback =>
        'The backend used its deterministic safety policy',
      PhotoAnalysisSource.onDevice =>
        'The local analysis engine was used without a server result',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AppColors.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF050706)),
                  Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: 'Analyzed photograph',
                  ),
                  ResultOverlay(type: overlay),
                  Positioned(
                    left: 13,
                    top: 13,
                    child: Tooltip(
                      message: provenanceHint,
                      child: _MiniBadge(
                        icon: badge.$1,
                        label: badge.$2,
                        color: badge.$3,
                      ),
                    ),
                  ),
                  if (overlay != OverlayType.none)
                    Positioned(
                      left: 13,
                      bottom: 13,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background.withValues(alpha: .84),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.visibility_outlined,
                              color: AppColors.accent,
                              size: 15,
                            ),
                            const SizedBox(width: 7),
                            Text(
                              _overlayLabel(overlay),
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(5, 13, 5, 0),
          child: Row(
            children: [
              const Icon(
                Icons.image_outlined,
                color: AppColors.muted,
                size: 17,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ),
              Text(
                analysisSource == PhotoAnalysisSource.onDevice
                    ? 'Processed locally'
                    : 'Photo pixels stayed local',
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _overlayLabel(OverlayType type) => switch (type) {
    OverlayType.ruleOfThirds => 'Rule-of-thirds guide',
    OverlayType.subjectGuide => 'Subject placement guide',
    OverlayType.level => 'Level guide',
    OverlayType.exposure => 'Exposure preview',
    OverlayType.focus => 'Focus target',
    OverlayType.colorBalance => 'Color balance preview',
    OverlayType.none => '',
  };
}

class _ResultReport extends StatelessWidget {
  const _ResultReport({
    required this.analysis,
    required this.analysisSource,
    required this.selectedStep,
    required this.onSelectStep,
    required this.onRetake,
    required this.onAnalyzeAnother,
    required this.onCopy,
  });

  final PhotoAnalysis analysis;
  final PhotoAnalysisSource analysisSource;
  final int? selectedStep;
  final ValueChanged<int> onSelectStep;
  final VoidCallback onRetake;
  final VoidCallback onAnalyzeAnother;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final privacyNote = switch (analysisSource) {
      PhotoAnalysisSource.freesoloValidated =>
        'Photo pixels stayed on this device. Only numeric measurements were sent to the pinned 4B policy model, and its ranking passed the backend safety check.',
      PhotoAnalysisSource.deterministicFallback =>
        'Photo pixels stayed on this device. The backend rejected or skipped the model ranking and returned its deterministic safety plan.',
      PhotoAnalysisSource.onDevice =>
        'The backend was unavailable or not configured, so this plan was generated by the on-device fallback. Recommendations are guidance, not guarantees.',
    };
    final verdict = switch (analysis.overallScore) {
      >= 88 => 'This frame is already working beautifully.',
      >= 76 => 'A strong shot — a few small changes will refine it.',
      >= 62 => 'Good foundation — these changes will make it intentional.',
      _ => 'The idea is there — let’s rebuild the light and framing.',
    };
    final label = switch (analysis.overallScore) {
      >= 88 => 'Ready to share',
      >= 76 => 'Almost there',
      >= 62 => 'Strong foundation',
      _ => 'Quick retake',
    };
    final metrics = [
      ('Composition', analysis.compositionScore, Icons.grid_3x3_rounded),
      ('Lighting', analysis.lightingScore, Icons.light_mode_outlined),
      ('Clarity', analysis.clarityScore, Icons.center_focus_strong_rounded),
      ('Color', analysis.colorScore, Icons.palette_outlined),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          label:
              'Analysis complete. Score ${analysis.overallScore} out of 100. $label.',
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ScoreRing(score: analysis.overallScore),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label.toUpperCase(),
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        verdict,
                        style: Theme.of(
                          context,
                        ).textTheme.titleLarge?.copyWith(height: 1.28),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 480;
            final width = twoColumns
                ? (constraints.maxWidth - 10) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: width,
                    child: _MetricCard(
                      label: metric.$1,
                      score: metric.$2,
                      icon: metric.$3,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Do these ${analysis.steps.length} things',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 17),
              label: const Text('Copy plan'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < analysis.steps.length; index++) ...[
          _CoachingCard(
            index: index,
            step: analysis.steps[index],
            selected: selectedStep == index,
            onPressed: analysis.steps[index].overlay == OverlayType.none
                ? null
                : () => onSelectStep(index),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onRetake,
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Retake with coaching'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onAnalyzeAnother,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Analyze another photo'),
        ),
        const SizedBox(height: 14),
        Text(
          privacyNote,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.45),
        ),
      ],
    );
  }
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 94,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: score / 100,
            strokeWidth: 8,
            strokeCap: StrokeCap.round,
            color: AppColors.accent,
            backgroundColor: AppColors.surfaceLight,
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$score',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                const Text(
                  '/ 100',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.score,
    required this.icon,
  });

  final String label;
  final int score;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = score >= 75
        ? AppColors.accent
        : score >= 55
        ? AppColors.amber
        : AppColors.danger;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$score',
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: score / 100,
              minHeight: 4,
              color: color,
              backgroundColor: AppColors.surfaceLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachingCard extends StatelessWidget {
  const _CoachingCard({
    required this.index,
    required this.step,
    required this.selected,
    required this.onPressed,
  });

  final int index;
  final CoachingStep step;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: selected ? AppColors.accentDark : AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? AppColors.accent.withValues(alpha: .75)
              : AppColors.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: index == 0 ? AppColors.accent : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: index == 0 ? AppColors.background : AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        step.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _PriorityBadge(priority: step.priority),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  step.instruction,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                if (onPressed != null)
                  TextButton.icon(
                    onPressed: onPressed,
                    style: TextButton.styleFrom(
                      foregroundColor: selected
                          ? AppColors.accent
                          : AppColors.blue,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 42),
                    ),
                    icon: Icon(
                      selected
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                    ),
                    label: Text(selected ? 'Hide guide' : 'Show on photo'),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text(
                      'Apply while retaking',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  const _PriorityBadge({required this.priority});

  final CoachingPriority priority;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (priority) {
      CoachingPriority.urgent => ('FIRST', AppColors.danger),
      CoachingPriority.high => ('HIGH', AppColors.amber),
      CoachingPriority.medium => ('NEXT', AppColors.blue),
      CoachingPriority.low => ('POLISH', AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: .6,
        ),
      ),
    );
  }
}
