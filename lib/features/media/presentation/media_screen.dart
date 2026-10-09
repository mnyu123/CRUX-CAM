import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../app/routes.dart';
import '../../analysis/presentation/analysis_screen.dart';
import '../application/media_controller.dart';
import '../models/media_info.dart';
import 'media_formatters.dart';

class MediaScreen extends ConsumerStatefulWidget {
  const MediaScreen({super.key});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen>
    with WidgetsBindingObserver, RouteAware {
  late final MediaController _controller;
  PageRoute<dynamic>? _route;
  bool _covered = false;
  bool _analysisOpen = false;

  Future<void> _openAnalysis(MediaInfo info) async {
    if (_analysisOpen) return;
    setState(() => _analysisOpen = true);
    try {
      // 버튼을 연속으로 눌러도 같은 분석 화면과 플레이어를 여러 개 만들지 않습니다.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AnalysisScreen(info: info)),
      );
    } finally {
      if (mounted) setState(() => _analysisOpen = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(mediaControllerProvider.notifier);
    Future.microtask(() {
      if (mounted) unawaited(_controller.recoverLostMedia());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      mediaRouteObserver.unsubscribe(this);
      _route = route;
      mediaRouteObserver.subscribe(this, route);
    }
  }

  void _updateForeground() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _controller.setForeground(
      !_covered &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _updateForeground();

  @override
  void didPushNext() {
    _covered = true;
    _updateForeground();
  }

  @override
  void didPopNext() {
    _covered = false;
    _updateForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mediaRouteObserver.unsubscribe(this);
    _controller.setForeground(false);
    // 화면이 사라지면 Riverpod이 현재 플레이어와 준비 중인 플레이어를 모두 해제합니다.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaControllerProvider);
    final info = state.info;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CRUX-CAM',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '나의 등반, 한 프레임씩',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    info == null
                        ? '클라이밍 영상 또는 사진을 선택해주세요.'
                        : '선택한 미디어를 확인해주세요.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  if (info == null)
                    _EmptyPreview(isLoading: state.isLoading)
                  else
                    _MediaPreview(
                      info: info,
                      player: state.videoController,
                      enabled: !state.isLoading,
                      controller: _controller,
                    ),
                  if (state.isLoading) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text('미디어를 준비하고 있습니다…', textAlign: TextAlign.center),
                  ],
                  if (state.error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          state.error!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ),
                  ],
                  if (info != null) ...[
                    const SizedBox(height: 20),
                    _MediaDetails(info: info),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('select-media'),
                    onPressed: state.isLoading
                        ? null
                        : () => unawaited(_controller.selectMedia()),
                    icon: const Icon(Icons.video_library_outlined),
                    label: Text(info == null ? '영상 / 사진 선택' : '다른 파일 선택'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '선택한 파일만 접근하며, 원본은 그대로 유지됩니다.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (info != null) ...[
                    const SizedBox(height: 20),
                    OutlinedButton(
                      key: const Key('open-analysis'),
                      onPressed: state.isLoading || _analysisOpen
                          ? null
                          : () => unawaited(_openAnalysis(info)),
                      child: const Text('클라이머 분석'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '관절을 분석하고 추적할 클라이머 한 명을 선택할 수 있습니다.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({required this.isLoading});
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 260,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.landscape_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: 18),
          Text(
            isLoading ? '미디어를 기다리고 있습니다' : '등반의 시작을 담아보세요',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '동영상과 사진을 불러올 수 있어요',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({
    required this.info,
    required this.player,
    required this.enabled,
    required this.controller,
  });
  final MediaInfo info;
  final VideoPlayerController? player;
  final bool enabled;
  final MediaController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth * info.height / info.width).clamp(
          200.0,
          440.0,
        );
        return Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                height: height,
                width: double.infinity,
                color: Colors.black,
                alignment: Alignment.center,
                child: info.source.type == MediaType.image
                    ? Image.file(
                        File(info.source.path),
                        key: ValueKey(info.source.path),
                        fit: BoxFit.contain,
                        cacheWidth: info.width.clamp(1, 1920),
                        errorBuilder: (_, _, _) => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('사진을 표시할 수 없습니다. 다른 파일을 선택해주세요.'),
                        ),
                      )
                    : player == null
                    ? const SizedBox.shrink()
                    : AspectRatio(
                        aspectRatio: player!.value.aspectRatio,
                        child: VideoPlayer(player!),
                      ),
              ),
            ),
            if (player != null)
              _VideoControls(
                player: player!,
                enabled: enabled,
                controller: controller,
              ),
          ],
        );
      },
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({
    required this.player,
    required this.enabled,
    required this.controller,
  });
  final VideoPlayerController player;
  final bool enabled;
  final MediaController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds.toDouble();
        return Column(
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  key: const Key('toggle-playback'),
                  tooltip: value.isPlaying ? '일시정지' : '재생',
                  onPressed: enabled && !value.hasError
                      ? () => unawaited(controller.togglePlayback())
                      : null,
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${formatDuration(value.position)} / ${formatDuration(value.duration)}',
                  ),
                ),
                if (value.isBuffering)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            Slider(
              key: const Key('video-seek'),
              semanticFormatterCallback: (milliseconds) =>
                  formatDuration(Duration(milliseconds: milliseconds.round())),
              min: 0,
              max: total > 0 ? total : 1,
              value: value.position.inMilliseconds.toDouble().clamp(
                0,
                total > 0 ? total : 1,
              ),
              // 누르거나 끄는 동안 잠시 멈췄다가 손을 떼면 원래 재생 상태로 되돌립니다.
              onChangeStart: enabled && total > 0 && !value.hasError
                  ? (_) => unawaited(controller.beginScrub())
                  : null,
              onChanged: enabled && total > 0 && !value.hasError
                  ? (milliseconds) => unawaited(
                      controller.seekTo(
                        Duration(milliseconds: milliseconds.round()),
                      ),
                    )
                  : null,
              onChangeEnd: enabled && total > 0 && !value.hasError
                  ? (_) => unawaited(controller.endScrub())
                  : null,
            ),
          ],
        );
      },
    );
  }
}

class _MediaDetails extends StatelessWidget {
  const _MediaDetails({required this.info});
  final MediaInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.source.type == MediaType.video ? '동영상 정보' : '사진 정보',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          _detail(context, '파일명', info.source.name),
          if (info.duration != null)
            _detail(context, '재생시간', formatDuration(info.duration!)),
          _detail(context, '해상도', '${info.width} × ${info.height}'),
          _detail(context, '파일 크기', formatFileSize(info.source.sizeBytes)),
          const Divider(height: 24),
          Text(
            '파일 경로 · 임시 로컬 파일',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          SelectableText(
            info.source.path,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
