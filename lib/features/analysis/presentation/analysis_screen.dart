import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/media/media_service.dart';
import '../../media/models/media_info.dart';
import '../../media/presentation/media_formatters.dart';
import '../application/analysis_controller.dart';
import '../models/pose_models.dart';
import 'pose_overlay.dart';

class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key, required this.info});
  final MediaInfo info;
  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen>
    with WidgetsBindingObserver {
  late final AnalysisController _analysis;
  VideoPlayerController? _player;
  PoseEngine _engine = PoseEngine.mediaPipeFull;
  int _fps = 5;
  bool _corrected = true;
  bool _playbackBusy = false;
  String? _playerError;
  final Map<PoseEngine, String> _comparisons = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _analysis = ref.read(analysisControllerProvider.notifier);
    Future.microtask(() async {
      if (!mounted) return;
      await _analysis.loadEngines();
      if (mounted && widget.info.source.type == MediaType.video) {
        await _preparePlayer();
      }
    });
  }

  Future<void> _preparePlayer() async {
    final player = ref
        .read(mediaServiceProvider)
        .createVideoController(widget.info.source);
    _player = player;
    player.addListener(_playerChanged);
    try {
      await player.initialize().timeout(const Duration(seconds: 30));
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        setState(() => _playerError = '영상을 재생하지 못했습니다. 뒤로 가서 파일을 다시 선택해주세요.');
      }
    }
  }

  void _playerChanged() {
    if (mounted) {
      setState(() {
        if (_player?.value.hasError == true) {
          _playerError = '영상 재생 중 오류가 발생했습니다.';
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_pause());
      // 백그라운드에서는 OS가 분석을 중단할 수 있으므로 명시적으로 취소합니다.
      _analysis.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final player = _player;
    player?.removeListener(_playerChanged);
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (_) {}
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null || !player.value.isInitialized || _playbackBusy) return;
    _playbackBusy = true;
    try {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        if (player.value.position >= player.value.duration) {
          await player.seekTo(Duration.zero);
        }
        if (mounted &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          await player.play();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _playerError = '재생 상태를 바꾸지 못했습니다.');
    } finally {
      _playbackBusy = false;
    }
  }

  Future<void> _seek(int ms) async {
    try {
      await _player?.seekTo(Duration(milliseconds: ms));
    } catch (_) {
      if (mounted) setState(() => _playerError = '이 시점으로 이동하지 못했습니다.');
    }
  }

  Future<void> _start(PoseEngine engine) async {
    await _pause();
    if (!mounted) return;
    await _analysis.analyze(widget.info, engine, _fps);
    if (!mounted) return;
    final result = ref.read(analysisControllerProvider).result;
    if (result == null) return;
    _comparisons[engine] =
        '${result.detectedCount}/${result.frames.length}개 프레임에서 사람 감지 · '
        '평균 인식 ${result.meanInferenceMs.toStringAsFixed(0)}ms · 전체 ${(result.elapsedMs / 1000).toStringAsFixed(1)}초';
    final first = result.frames.indexWhere(
      (f) => f.bodies.any((b) => b.usable),
    );
    if (first >= 0) await _seek(result.frames[first].timeMs);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(analysisControllerProvider);
    final result = state.result;
    final engine = state.engines.contains(_engine)
        ? _engine
        : state.engines.firstOrNull;
    final position = _player?.value.position.inMilliseconds ?? 0;
    final index = result == null ? 0 : result.indexAt(position);
    final frame = result?.frames[index];
    final tracked = result == null || result.tracked.isEmpty
        ? null
        : result.tracked[index];
    final target = _corrected ? tracked?.corrected : tracked?.raw;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('클라이머 분석')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.info.source.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  _preview(result, frame, target, state.busy || state.saving),
                  if (_player?.value.isInitialized == true) ...[
                    Row(
                      children: [
                        IconButton.filledTonal(
                          key: const Key('analysis-play'),
                          onPressed: state.busy || _playerError != null
                              ? null
                              : () => unawaited(_toggle()),
                          tooltip: _player!.value.isPlaying ? '일시정지' : '재생',
                          icon: Icon(
                            _player!.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${formatDuration(_player!.value.position)} / ${formatDuration(_player!.value.duration)}',
                        ),
                      ],
                    ),
                    Slider(
                      key: const Key('analysis-seek'),
                      max: math.max(
                        1,
                        _player!.value.duration.inMilliseconds.toDouble(),
                      ),
                      value: position.toDouble().clamp(
                        0,
                        math.max(
                          1,
                          _player!.value.duration.inMilliseconds.toDouble(),
                        ),
                      ),
                      onChanged: state.busy
                          ? null
                          : (v) => unawaited(_seek(v.round())),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (state.busy) ...[
                    LinearProgressIndicator(
                      value: state.total > 0
                          ? state.completed / state.total
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(switch (state.phase) {
                      AnalysisPhase.preparing => '모델과 영상을 준비하고 있습니다…',
                      AnalysisPhase.cancelling => '분석을 취소하고 자원을 정리하고 있습니다…',
                      AnalysisPhase.tracking => '선택한 클라이머의 움직임을 연결하고 있습니다…',
                      _ => '${state.completed} / ${state.total} 프레임 분석 중',
                    }),
                    TextButton(
                      onPressed: state.phase == AnalysisPhase.cancelling
                          ? null
                          : _analysis.cancel,
                      child: const Text('분석 취소'),
                    ),
                  ],
                  if (state.phase == AnalysisPhase.cancelled)
                    const Text('분석을 취소했습니다. 다시 시작할 수 있습니다.'),
                  if (state.error != null || _playerError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        state.error ?? _playerError!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (state.engines.isEmpty)
                    TextButton(
                      onPressed: () => unawaited(_analysis.loadEngines()),
                      child: const Text('분석 기능 다시 확인'),
                    ),
                  if (engine != null) ...[
                    DropdownButtonFormField<PoseEngine>(
                      initialValue: engine,
                      decoration: const InputDecoration(labelText: '분석 모델'),
                      items: state.engines
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text(e.label),
                            ),
                          )
                          .toList(),
                      onChanged: state.busy || state.saving
                          ? null
                          : (e) {
                              if (e != null) setState(() => _engine = e);
                            },
                    ),
                    if (widget.info.source.type == MediaType.video) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _fps,
                        decoration: const InputDecoration(
                          labelText: '초당 분석 프레임',
                        ),
                        items: [2, 5, 10]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('$v개'),
                              ),
                            )
                            .toList(),
                        onChanged: state.busy || state.saving
                            ? null
                            : (v) {
                                if (v != null) setState(() => _fps = v);
                              },
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const Key('run-analysis'),
                      onPressed: state.busy || state.saving
                          ? null
                          : () => unawaited(_start(engine)),
                      icon: const Icon(Icons.accessibility_new),
                      label: Text(result == null ? '분석 시작' : '이 모델로 다시 분석'),
                    ),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      result.tracked.isEmpty
                          ? '추적할 클라이머를 선택해주세요.'
                          : '추적 대상이 선택되었습니다.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('시간을 이동한 뒤 화면의 사람 또는 아래 번호를 눌러 선택할 수 있습니다.'),
                    const SizedBox(height: 8),
                    if (frame!.bodies.any((b) => b.usable))
                      Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < frame.bodies.length; i++)
                            if (frame.bodies[i].usable)
                              ActionChip(
                                label: Text('사람 ${i + 1}'),
                                onPressed: state.saving || state.busy
                                    ? null
                                    : () {
                                        unawaited(_pause());
                                        unawaited(
                                          _analysis.selectTarget(index, i),
                                        );
                                      },
                              ),
                        ],
                      )
                    else
                      const Text('이 시점에는 사람을 감지하지 못했습니다. 다른 시점으로 이동해주세요.'),
                    if (tracked != null) ...[
                      const SizedBox(height: 12),
                      Text(switch (tracked.status) {
                        TrackStatus.tracked => '대상 추적 중',
                        TrackStatus.lost =>
                          '대상을 놓쳤습니다. 몸통이 보이는 시점에서 다시 선택해주세요.',
                        TrackStatus.ambiguous => '사람이 겹쳐 대상을 구분하기 어렵습니다.',
                      }),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('관절 튐 보정'),
                        subtitle: const Text('끄면 선택한 사람의 원래 인식 좌표를 표시합니다.'),
                        value: _corrected,
                        onChanged: (v) => setState(() => _corrected = v),
                      ),
                      Text(
                        '추적 성공 ${result.trackedCount}/${result.frames.length} 프레임 · '
                        '분석 간격 ${result.intervalMs}ms',
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        key: const Key('save-analysis'),
                        onPressed: state.saving || state.busy
                            ? null
                            : () => unawaited(
                                _analysis.save(widget.info.source.name),
                              ),
                        icon: const Icon(Icons.save_outlined),
                        label: Text(state.saving ? '저장 중…' : '분석 결과 저장'),
                      ),
                      if (state.savedPath != null)
                        const Text('분석 결과를 앱 내부에 저장했습니다. 원본은 변경하지 않았습니다.'),
                    ],
                  ],
                  if (_comparisons.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      '이번 파일의 모델별 결과',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final entry in _comparisons.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('${entry.key.label}\n${entry.value}'),
                      ),
                    const Text('감지율은 관절 정확도를 뜻하지 않습니다. 같은 분석 간격으로 비교해주세요.'),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    '현재는 10분 이하의 영상과 사진을 분석합니다. 크롭과 영상 내보내기는 다음 단계에서 제공됩니다.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(
    AnalysisResult? result,
    PoseFrame? frame,
    PoseBody? target,
    bool disabled,
  ) {
    final ratio = result == null
        ? widget.info.width / widget.info.height
        : result.session.width / result.session.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth / ratio).clamp(200.0, 440.0);
        final width = math.min(constraints.maxWidth, height * ratio);
        final displayHeight = width / ratio;
        return Container(
          height: height,
          color: Colors.black,
          alignment: Alignment.center,
          child: SizedBox(
            width: width,
            height: displayHeight,
            child: GestureDetector(
              key: const Key('pose-preview'),
              onTapUp: disabled || frame == null || result == null
                  ? null
                  : (details) {
                      final x = details.localPosition.dx / width;
                      final y = details.localPosition.dy / displayHeight;
                      final choices = <({int index, double distance})>[];
                      for (var i = 0; i < frame.bodies.length; i++) {
                        final body = frame.bodies[i];
                        if (!body.usable) continue;
                        final b = body.bounds;
                        if (x < b.left - 0.03 ||
                            x > b.right + 0.03 ||
                            y < b.top - 0.03 ||
                            y > b.bottom + 0.03) {
                          continue;
                        }
                        final c = body.center;
                        choices.add((
                          index: i,
                          distance:
                              math.pow(x - c.x, 2).toDouble() +
                              math.pow(y - c.y, 2).toDouble(),
                        ));
                      }
                      choices.sort((a, b) => a.distance.compareTo(b.distance));
                      if (choices.isNotEmpty) {
                        unawaited(_pause());
                        unawaited(
                          _analysis.selectTarget(
                            result.indexAt(
                              _player?.value.position.inMilliseconds ?? 0,
                            ),
                            choices.first.index,
                          ),
                        );
                      }
                    },
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.info.source.type == MediaType.image)
                      if (frame?.preview != null)
                        Image.memory(frame!.preview!, fit: BoxFit.fill)
                      else
                        Image.file(
                          File(widget.info.source.path),
                          fit: BoxFit.contain,
                          cacheWidth: 1280,
                        )
                    else if (_player?.value.isInitialized == true)
                      VideoPlayer(_player!),
                    if (frame != null)
                      CustomPaint(
                        painter: PoseOverlay(
                          bodies: frame.bodies,
                          target: target,
                          showCandidates: result!.tracked.isEmpty,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
