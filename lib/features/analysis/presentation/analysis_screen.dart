import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/media/media_service.dart';
import '../../../core/media/playback_scrubber.dart';
import '../../media/models/media_info.dart';
import '../../crop/presentation/crop_screen.dart';
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
  bool _cropOpen = false;
  bool _drawingRegion = false;
  Offset? _regionStart;
  Rect? _regionRect;
  String? _regionError;
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
    final player = _player;
    if (player == null) return;
    try {
      // 연속 탐색이 겹치면 소리가 깨질 수 있어 마지막 위치만 차례로 보냅니다.
      await PlaybackScrubber.of(player).seek(Duration(milliseconds: ms));
    } catch (_) {
      if (mounted) setState(() => _playerError = '이 시점으로 이동하지 못했습니다.');
    }
  }

  Future<void> _scrubStart() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      await PlaybackScrubber.of(player).start();
    } catch (_) {}
  }

  Future<void> _scrubEnd() async {
    final player = _player;
    if (player == null) return;
    try {
      await PlaybackScrubber.of(player).end(
        canResume: () =>
            mounted &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
    } catch (_) {
      if (mounted) setState(() => _playerError = '재생 상태를 바꾸지 못했습니다.');
    }
  }

  Future<void> _start(PoseEngine engine) async {
    await _pause();
    if (!mounted) return;
    setState(() {
      _drawingRegion = false;
      _regionRect = null;
      _regionError = null;
    });
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
    if (!mounted) return;
    setState(() {});
    _guideSelection(result);
  }

  /// 분석이 끝났지만 크롭할 사람을 고르지 않은 경우, 다음에 할 일을 짧게 알려줍니다.
  void _guideSelection(AnalysisResult result) {
    if (result.selectedPersonId != null) return;
    _notify(
      result.detectedCount == 0
          ? '사람을 찾지 못했어요. 다른 모델로 다시 분석하거나 놓친 사람 영역을 추가해주세요.'
          : '분석이 끝났어요. 영상 아래 "사람 번호"를 눌러 크롭할 클라이머를 선택해주세요.',
    );
  }

  void _notify(String message) {
    // 같은 안내가 연달아 쌓이지 않도록 이전 알림을 닫고 새로 보여줍니다.
    // 넓은 화면에서는 영상이 왼쪽에 있으므로 알림을 오른쪽 설정 영역 위에만 띄워 재생 버튼을 가리지 않습니다.
    final width = MediaQuery.sizeOf(context).width;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: width >= 700
              ? EdgeInsets.fromLTRB(width * 3 / 5 + 8, 0, 8, 8)
              : null,
        ),
      );
  }

  Future<void> _openCrop(AnalysisResult result) async {
    if (_cropOpen || result.trackedCount == 0) return;
    _cropOpen = true;
    try {
      await _pause();
      if (!mounted) return;
      // 분석 화면의 재생을 정지한 뒤 크롭 화면이 별도의 재생기를 소유합니다.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CropScreen(
            info: widget.info,
            analysis: result,
            initialTimeMs: _player?.value.position.inMilliseconds ?? 0,
          ),
        ),
      );
    } finally {
      _cropOpen = false;
    }
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
    // 영상과 사람 선택은 함께 고정하고, 분석 설정·결과만 별도로 스크롤합니다.
    final settings = SingleChildScrollView(
      key: const Key('analysis-settings'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.busy) ...[
            LinearProgressIndicator(
              value: state.total > 0 ? state.completed / state.total : null,
            ),
            const SizedBox(height: 8),
            Text(switch (state.phase) {
              AnalysisPhase.preparing => '모델과 영상을 준비하고 있습니다…',
              AnalysisPhase.cancelling => '분석을 취소하고 자원을 정리하고 있습니다…',
              AnalysisPhase.tracking => '선택한 클라이머의 움직임을 연결하고 있습니다…',
              AnalysisPhase.refining =>
                '놓친 구간을 확대해 다시 찾고 있습니다… (${state.completed}개 확인)',
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
              decoration: InputDecoration(
                labelText: '분석 모델',
                helperText: engine.description,
                helperMaxLines: 3,
                suffixIcon: Tooltip(
                  key: const Key('pose-model-help'),
                  message: engine.description,
                  triggerMode: TooltipTriggerMode.tap,
                  child: const Icon(Icons.info_outline),
                ),
              ),
              items: state.engines
                  .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                  .toList(),
              onChanged: state.busy || state.saving
                  ? null
                  : (e) {
                      if (e != null) setState(() => _engine = e);
                    },
            ),
            if (engine == PoseEngine.mlKitAccurate)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'ML Kit는 한 번에 한 사람만 인식합니다. 여러 사람은 MediaPipe로 분석하거나, 놓친 사람의 영역을 추가 분석해주세요.',
                ),
              ),
            if (widget.info.source.type == MediaType.video) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _fps,
                decoration: const InputDecoration(labelText: '초당 분석 프레임'),
                items: [2, 5, 10]
                    .map((v) => DropdownMenuItem(value: v, child: Text('$v개')))
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
            if (result.regions.isNotEmpty)
              Text('추가 분석 영역 ${result.regions.length}개'),
            if (_drawingRegion)
              const Text(
                '다른 사람은 제외하고 클라이머의 몸과 영상 중 이동 경로를 포함해주세요. 지정한 고정 영역을 영상 전체에서 추가 분석하므로 영역 밖으로 나가면 감지하지 못할 수 있습니다.',
              ),
            const Text(
              '번호는 위치와 움직임으로 연결합니다. 겹침에서는 구분을 보류하고 긴 가림 뒤에는 새 번호가 생길 수 있으니 대상을 확인해주세요.',
            ),
            if (result.selectedPersonId == null && !_drawingRegion) ...[
              const SizedBox(height: 12),
              Card(
                key: const Key('select-person-hint'),
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app, color: scheme.onSecondaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '다음 단계: 영상 아래의 "사람 1" 같은 번호 중 클라이머를 눌러 선택하면 크롭 미리보기로 넘어갈 수 있어요.',
                          style: TextStyle(color: scheme.onSecondaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 선택 전에도 버튼 자리를 보여 주고, 누르면 왜 넘어갈 수 없는지 알려줍니다.
              FilledButton.tonalIcon(
                key: const Key('crop-needs-person'),
                onPressed: state.busy || state.saving
                    ? null
                    : () => _notify(
                        result.detectedCount == 0
                            ? '감지된 사람이 없어 크롭할 수 없어요. 다른 모델로 다시 분석하거나 놓친 사람 영역을 추가해주세요.'
                            : '먼저 영상 아래의 사람 번호를 눌러 크롭할 클라이머를 선택해주세요.',
                      ),
                icon: const Icon(Icons.crop),
                label: const Text('크롭 미리보기 (사람 선택 필요)'),
              ),
            ],
            if (tracked != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('open-crop'),
                onPressed:
                    state.busy || state.saving || result.trackedCount == 0
                    ? null
                    : () => unawaited(_openCrop(result)),
                icon: const Icon(Icons.crop),
                label: const Text('크롭 미리보기'),
              ),
              const SizedBox(height: 12),
              Text(switch (tracked.status) {
                TrackStatus.tracked => '대상 추적 중',
                TrackStatus.lost => '대상을 놓쳤습니다. 몸통이 보이는 시점에서 다시 선택해주세요.',
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
                    : () => unawaited(_analysis.save(widget.info.source.name)),
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
            '현재는 10분 이하의 영상과 사진을 분석하고 크롭을 미리봅니다. 영상 내보내기는 다음 단계에서 제공됩니다.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('클라이머 분석')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide = constraints.maxWidth >= 700;
            final panelLimit = constraints.maxHeight * (sideBySide ? 1 : .72);
            // 작은 화면에서도 선택 버튼과 재생바가 보이도록 영상 높이를 먼저 줄입니다.
            // 큰 글씨 등으로 공간이 부족하면 영상 패널 안에서만 스크롤할 수 있습니다.
            final overhead = result == null
                ? 100.0
                : _drawingRegion
                ? 270.0
                : 180.0;
            final previewHeight = (panelLimit - overhead).clamp(64.0, 440.0);
            final panel = SingleChildScrollView(
              key: const Key('analysis-media-panel'),
              child: _mediaPanel(
                state,
                result,
                frame,
                target,
                position,
                previewHeight,
              ),
            );
            if (sideBySide) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: panel),
                      const VerticalDivider(width: 1),
                      Expanded(flex: 2, child: settings),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: panelLimit),
                  child: panel,
                ),
                const Divider(height: 1),
                Expanded(child: settings),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _mediaPanel(
    AnalysisState state,
    AnalysisResult? result,
    PoseFrame? frame,
    PoseBody? target,
    int position,
    double previewHeight,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = state.busy || state.saving;
    // 모델의 반환 순서가 바뀌어도 같은 번호 버튼이 같은 자리에 있게 합니다.
    final candidates = frame == null
        ? <int>[]
        : [
            for (var i = 0; i < frame.bodies.length; i++)
              if (frame.bodies[i].usable) i,
          ];
    candidates.sort(
      (a, b) => (frame!.personIdAt(a) ?? 0x7fffffff).compareTo(
        frame.personIdAt(b) ?? 0x7fffffff,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.info.source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          _preview(result, frame, target, disabled, previewHeight),
          if (result != null && frame != null) ...[
            const SizedBox(height: 8),
            if (result.selectedPersonId == null)
              Row(
                key: const Key('select-person-title'),
                children: [
                  Icon(Icons.touch_app, size: 18, color: scheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '클라이머 번호를 눌러 선택하세요',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: scheme.primary),
                    ),
                  ),
                ],
              )
            else
              Text(
                '추적 대상: 사람 ${result.selectedPersonId} (다시 누르면 해제)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            Row(
              children: [
                // 후보가 많아도 줄이 늘어나 영상을 가리지 않도록 가로로 넘깁니다.
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('person-selector'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (!frame.bodies.any((b) => b.usable))
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('이 시점에는 감지된 사람이 없습니다.'),
                          ),
                        for (final i in candidates)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar:
                                  frame.personIdAt(i) != null &&
                                      frame.personIdAt(i) ==
                                          result.selectedPersonId
                                  ? const Icon(Icons.check, size: 18)
                                  : null,
                              label: Text(
                                frame.personIdAt(i) == null
                                    ? '구분 중'
                                    : '사람 ${frame.personIdAt(i)}',
                              ),
                              tooltip:
                                  frame.personIdAt(i) != null &&
                                      frame.personIdAt(i) ==
                                          result.selectedPersonId
                                  ? '다시 누르면 선택 해제'
                                  : null,
                              backgroundColor:
                                  frame.personIdAt(i) != null &&
                                      frame.personIdAt(i) ==
                                          result.selectedPersonId
                                  ? scheme.primaryContainer
                                  : null,
                              onPressed:
                                  disabled ||
                                      _drawingRegion ||
                                      frame.personIdAt(i) == null
                                  ? null
                                  : () {
                                      unawaited(_pause());
                                      // 이미 선택한 사람을 다시 누르면 선택을 해제합니다.
                                      if (frame.personIdAt(i) ==
                                          result.selectedPersonId) {
                                        _analysis.clearTarget();
                                        return;
                                      }
                                      unawaited(
                                        _analysis.selectTarget(
                                          result.indexAt(position),
                                          i,
                                        ),
                                      );
                                    },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (!_drawingRegion)
                  IconButton.outlined(
                    key: const Key('add-person-region'),
                    tooltip: '놓친 사람 영역 추가 분석',
                    onPressed: disabled
                        ? null
                        : () async {
                            await _pause();
                            if (!mounted) return;
                            setState(() {
                              _drawingRegion = true;
                              _regionRect = null;
                              _regionError = null;
                            });
                          },
                    icon: const Icon(Icons.person_add_alt_1),
                  ),
              ],
            ),
            if (_drawingRegion) ...[
              Text(
                '영상에서 드래그해 몸과 이동 경로를 포함해주세요.',
                maxLines: 2,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('confirm-person-region'),
                      onPressed: disabled || _regionRect == null
                          ? null
                          : () => unawaited(_confirmRegion(result)),
                      child: const Text('이 영역 추가 분석'),
                    ),
                  ),
                  TextButton(
                    onPressed: disabled
                        ? null
                        : () => setState(() {
                            _drawingRegion = false;
                            _regionRect = null;
                            _regionError = null;
                          }),
                    child: const Text('취소'),
                  ),
                ],
              ),
            ],
            if (_regionError != null)
              Text(_regionError!, style: TextStyle(color: scheme.error)),
          ],
          if (_player?.value.isInitialized == true)
            Row(
              children: [
                IconButton.filledTonal(
                  key: const Key('analysis-play'),
                  onPressed:
                      state.busy || _drawingRegion || _playerError != null
                      ? null
                      : () => unawaited(_toggle()),
                  tooltip: _player!.value.isPlaying ? '일시정지' : '재생',
                  icon: Icon(
                    _player!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                Expanded(
                  child: Slider(
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
                    // 누르거나 끄는 동안에는 잠시 멈췄다가, 손을 떼면 원래 재생 상태로 되돌립니다.
                    onChangeStart: state.busy || _drawingRegion
                        ? null
                        : (_) => unawaited(_scrubStart()),
                    onChanged: state.busy || _drawingRegion
                        ? null
                        : (v) => unawaited(_seek(v.round())),
                    onChangeEnd: state.busy || _drawingRegion
                        ? null
                        : (_) => unawaited(_scrubEnd()),
                  ),
                ),
                Text(
                  '${formatDuration(_player!.value.position)} / ${formatDuration(_player!.value.duration)}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _confirmRegion(AnalysisResult result) async {
    try {
      final rect = _regionRect!;
      final region = PoseRegion(rect.left, rect.top, rect.right, rect.bottom);
      setState(() {
        _drawingRegion = false;
        _regionError = null;
      });
      await _analysis.analyze(widget.info, result.engine, _fps, region: region);
      if (!mounted) return;
      setState(() => _regionRect = null);
      // 추가 분석이 성공하면 번호가 다시 정리되어 대상을 다시 골라야 합니다.
      final next = ref.read(analysisControllerProvider);
      if (next.result != null && next.result != result && next.error == null) {
        _guideSelection(next.result!);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _regionError = error.message);
    }
  }

  Widget _preview(
    AnalysisResult? result,
    PoseFrame? frame,
    PoseBody? target,
    bool disabled,
    double maxPreviewHeight,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = result == null
        ? widget.info.width / widget.info.height
        : result.session.width / result.session.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth / ratio).clamp(
          64.0,
          maxPreviewHeight,
        );
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
              // 화면의 검은 여백을 빼고 실제 영상 표시 영역에서만 좌표를 계산합니다.
              onPanStart: !_drawingRegion || disabled
                  ? null
                  : (details) {
                      _regionStart = Offset(
                        (details.localPosition.dx / width).clamp(0, 1),
                        (details.localPosition.dy / displayHeight).clamp(0, 1),
                      );
                      setState(() => _regionRect = null);
                    },
              onPanUpdate: !_drawingRegion || disabled
                  ? null
                  : (details) {
                      if (_regionStart == null) return;
                      final end = Offset(
                        (details.localPosition.dx / width).clamp(0, 1),
                        (details.localPosition.dy / displayHeight).clamp(0, 1),
                      );
                      setState(
                        () => _regionRect = Rect.fromPoints(_regionStart!, end),
                      );
                    },
              onTapUp:
                  disabled || _drawingRegion || frame == null || result == null
                  ? null
                  : (details) {
                      final x = details.localPosition.dx / width;
                      final y = details.localPosition.dy / displayHeight;
                      final choices = <({int index, double distance})>[];
                      for (var i = 0; i < frame.bodies.length; i++) {
                        final body = frame.bodies[i];
                        if (!body.usable || frame.personIdAt(i) == null) {
                          continue;
                        }
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
                          personIds: frame.personIds,
                        ),
                      ),
                    if (_regionRect != null)
                      Positioned.fromRect(
                        rect: Rect.fromLTRB(
                          _regionRect!.left * width,
                          _regionRect!.top * displayHeight,
                          _regionRect!.right * width,
                          _regionRect!.bottom * displayHeight,
                        ),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: .15),
                              border: Border.all(
                                color: scheme.primary,
                                width: 2,
                              ),
                            ),
                          ),
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
