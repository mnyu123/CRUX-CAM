import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/media/media_service.dart';
import '../../../core/reframing/crop_planner.dart';
import '../../analysis/models/pose_models.dart';
import '../../media/models/media_info.dart';
import '../../media/presentation/media_formatters.dart';
import '../application/crop_store.dart';
import '../models/crop_models.dart';
import 'crop_viewport.dart';

class CropScreen extends ConsumerStatefulWidget {
  const CropScreen({
    super.key,
    required this.info,
    required this.analysis,
    this.initialTimeMs = 0,
  });
  final MediaInfo info;
  final AnalysisResult analysis;
  final int initialTimeMs;
  @override
  ConsumerState<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends ConsumerState<CropScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  CropOptions _options = const CropOptions();
  CropTimeline? _timeline;
  Timer? _debounce;
  int _generation = 0;
  bool _planning = true,
      _saving = false,
      _original = false,
      _playbackBusy = false;
  String? _error, _playerError, _savedPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_generate());
    if (widget.info.source.type == MediaType.video) unawaited(_preparePlayer());
  }

  Future<void> _preparePlayer() async {
    final player = ref
        .read(mediaServiceProvider)
        .createVideoController(widget.info.source);
    _player = player;
    player.addListener(_playerChanged);
    try {
      await player.initialize().timeout(const Duration(seconds: 30));
      if (!mounted) return;
      await player.seekTo(
        Duration(
          milliseconds: widget.initialTimeMs.clamp(
            0,
            player.value.duration.inMilliseconds,
          ),
        ),
      );
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        setState(() => _playerError = '영상을 재생하지 못했습니다. 뒤로 가서 파일을 다시 확인해주세요.');
      }
    }
  }

  void _playerChanged() {
    if (!mounted) return;
    setState(() {
      if (_player?.value.hasError == true) _playerError = '영상 재생 중 오류가 발생했습니다.';
    });
  }

  Future<void> _generate() async {
    _debounce?.cancel();
    final generation = ++_generation;
    final options = _options;
    setState(() {
      _planning = true;
      _error = null;
      _savedPath = null;
    });
    try {
      // 긴 영상의 크롭 경로도 화면을 멈추지 않도록 별도로 계산합니다.
      final timeline = await compute(_planCrop, (widget.analysis, options));
      if (!mounted || generation != _generation) return;
      setState(() {
        _timeline = timeline;
        _planning = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _planning = false;
        _error = error is FormatException
            ? error.message
            : '크롭 영역을 계산하지 못했습니다. 다시 시도해주세요.';
      });
    }
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

  Future<void> _save() async {
    final timeline = _timeline;
    if (timeline == null ||
        _planning ||
        _saving ||
        timeline.options != _options) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final path = await ref
          .read(cropStoreProvider)
          .save(
            timeline,
            widget.analysis.session.storageDirectory,
            widget.info.source.name,
          );
      if (mounted) setState(() => _savedPath = path);
    } catch (_) {
      if (mounted) setState(() => _error = '크롭 설정을 저장하지 못했습니다. 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pause());
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final player = _player;
    player?.removeListener(_playerChanged);
    // 화면을 닫아도 늦게 도착한 계산·재생 이벤트가 남지 않도록 소유한 재생기를 해제합니다.
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeline = _timeline;
    final position =
        _player?.value.position.inMilliseconds ?? widget.initialTimeMs;
    final frame = timeline?.at(position);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('크롭 미리보기')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maximumPreview = (constraints.maxHeight * .7 - 130).clamp(
              64.0,
              440.0,
            );
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .7,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '추적 대상: 사람 ${widget.analysis.selectedPersonId ?? '?'}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          if (timeline != null && frame != null)
                            _preview(timeline, frame, maximumPreview)
                          else
                            SizedBox(
                              height: maximumPreview,
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                          const SizedBox(height: 8),
                          SegmentedButton<bool>(
                            key: const Key('crop-preview-mode'),
                            segments: const [
                              ButtonSegment(value: false, label: Text('크롭')),
                              ButtonSegment(
                                value: true,
                                label: Text('원본에서 영역 보기'),
                              ),
                            ],
                            selected: {_original},
                            onSelectionChanged: (value) =>
                                setState(() => _original = value.first),
                          ),
                          if (_player?.value.isInitialized == true)
                            Row(
                              children: [
                                IconButton.filledTonal(
                                  key: const Key('crop-play'),
                                  onPressed: _playerError == null
                                      ? () => unawaited(_toggle())
                                      : null,
                                  tooltip: _player!.value.isPlaying
                                      ? '일시정지'
                                      : '재생',
                                  icon: Icon(
                                    _player!.value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                ),
                                Expanded(
                                  child: Slider(
                                    key: const Key('crop-seek'),
                                    max: math.max(
                                      1,
                                      _player!.value.duration.inMilliseconds
                                          .toDouble(),
                                    ),
                                    value: position.toDouble().clamp(
                                      0,
                                      math.max(
                                        1,
                                        _player!.value.duration.inMilliseconds
                                            .toDouble(),
                                      ),
                                    ),
                                    onChanged: (v) =>
                                        unawaited(_seek(v.round())),
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
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_planning) const LinearProgressIndicator(),
                        if (_error != null || _playerError != null)
                          Text(
                            _error ?? _playerError!,
                            style: TextStyle(color: scheme.error),
                          ),
                        if (_error != null)
                          TextButton(
                            onPressed: _planning
                                ? null
                                : () => unawaited(_generate()),
                            child: const Text('크롭 다시 계산'),
                          ),
                        if (frame != null)
                          Text(switch (frame.status) {
                            CropStatus.following => '선택한 사람을 따라가고 있습니다.',
                            CropStatus.held =>
                              '대상을 놓친 구간입니다. 마지막 크롭 위치를 유지합니다.',
                            CropStatus.waiting => '대상이 감지될 때까지 넓은 영역을 표시합니다.',
                          }),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<CropRatio>(
                          key: const Key('crop-ratio'),
                          initialValue: _options.ratio,
                          decoration: const InputDecoration(labelText: '화면 비율'),
                          items: CropRatio.values
                              .map(
                                (r) => DropdownMenuItem(
                                  value: r,
                                  child: Text(r.label),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (ratio) {
                                  if (ratio == null) return;
                                  setState(
                                    () => _options = _options.copyWith(
                                      ratio: ratio,
                                    ),
                                  );
                                  unawaited(_generate());
                                },
                        ),
                        const SizedBox(height: 16),
                        Text('확대 정도 ${_options.zoom.toStringAsFixed(1)}'),
                        Slider(
                          key: const Key('crop-zoom'),
                          min: 1,
                          max: 2.5,
                          divisions: 15,
                          value: _options.zoom,
                          label: _options.zoom.toStringAsFixed(1),
                          onChanged: _saving
                              ? null
                              : (v) {
                                  setState(() {
                                    _options = _options.copyWith(zoom: v);
                                    _savedPath = null;
                                  });
                                  _debounce?.cancel();
                                  _debounce = Timer(
                                    const Duration(milliseconds: 150),
                                    () => unawaited(_generate()),
                                  );
                                },
                          onChangeEnd: _saving
                              ? null
                              : (_) => unawaited(_generate()),
                        ),
                        const Text(
                          '기본값은 사람 주변에 여유를 둡니다. 값을 높이면 더 가까이 보여줍니다. 넓은 비율이나 큰 확대에서는 몸 일부가 잘릴 수 있어요.',
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('부드럽게 따라가기'),
                          value: _options.smooth,
                          onChanged: _saving
                              ? null
                              : (v) {
                                  setState(
                                    () =>
                                        _options = _options.copyWith(smooth: v),
                                  );
                                  unawaited(_generate());
                                },
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const Key('save-crop'),
                          onPressed:
                              timeline == null ||
                                  _planning ||
                                  _saving ||
                                  timeline.options != _options
                              ? null
                              : () => unawaited(_save()),
                          icon: const Icon(Icons.save_outlined),
                          label: Text(_saving ? '저장 중…' : '크롭 설정 저장'),
                        ),
                        if (_savedPath != null)
                          const Text('크롭 경로와 설정을 앱 내부에 저장했습니다.'),
                        const SizedBox(height: 12),
                        const Text(
                          '지금은 크롭 미리보기와 설정 저장을 제공합니다. 영상 파일 내보내기는 다음 단계에서 추가합니다.',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _preview(
    CropTimeline timeline,
    CropFrame frame,
    double maximumHeight,
  ) {
    final aspect = _original ? timeline.sourceAspect : timeline.outputAspect;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = math.min(maximumHeight, constraints.maxWidth / aspect);
        final width = height * aspect;
        Widget media;
        if (widget.info.source.type == MediaType.image) {
          final preview = widget.analysis.frames.first.preview;
          media = preview == null
              ? Image.file(File(widget.info.source.path), fit: BoxFit.fill)
              : Image.memory(preview, fit: BoxFit.fill);
        } else if (_player?.value.isInitialized == true) {
          media = VideoPlayer(_player!);
        } else {
          media = const Center(child: CircularProgressIndicator());
        }
        return Container(
          height: maximumHeight,
          color: Colors.black,
          alignment: Alignment.center,
          child: SizedBox(
            key: const Key('crop-preview'),
            width: width,
            height: height,
            child: _original
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      media,
                      CustomPaint(painter: CropOverlay(frame.rect)),
                    ],
                  )
                : CropViewport(
                    rect: frame.rect,
                    sourceAspect: timeline.sourceAspect,
                    child: media,
                  ),
          ),
        );
      },
    );
  }
}

CropTimeline _planCrop((AnalysisResult, CropOptions) input) =>
    CropPlanner().plan(input.$1, input.$2);
