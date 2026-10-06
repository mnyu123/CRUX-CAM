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
import '../../export/application/export_controller.dart';
import '../../export/models/export_models.dart';
import '../../export/presentation/export_preview.dart';
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
  late final ExportController _export;
  ExportQuality _quality = ExportQuality.standard;
  bool _keepAudio = true;

  bool get _locked => _saving || _export.busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _export = ExportController(ref.read(exportServiceProvider))
      ..addListener(_exportChanged);
    unawaited(_generate());
    if (widget.info.source.type == MediaType.video) unawaited(_preparePlayer());
  }

  void _exportChanged() {
    if (mounted) setState(() {});
  }

  void _adjust(CropOptions options, {bool immediate = false}) {
    if (_locked) return;
    setState(() {
      _options = options;
      _savedPath = null;
    });
    _debounce?.cancel();
    if (immediate) {
      unawaited(_generate());
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 100),
        () => unawaited(_generate()),
      );
    }
  }

  Future<void> _render() async {
    final timeline = _timeline;
    if (timeline == null ||
        _locked ||
        _planning ||
        timeline.options != _options) {
      return;
    }
    await _pause();
    if (!mounted) return;
    await _export.start(
      widget.info.source.path,
      timeline,
      ExportSettings(quality: _quality, keepAudio: _keepAudio),
    );
    if (mounted && _export.stage == ExportStage.completed) await _export.save();
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
    if (state != AppLifecycleState.resumed) {
      unawaited(_pause());
      // 백그라운드 인코딩은 아직 지원하지 않으므로 불완전한 파일을 남기지 않고 취소합니다.
      unawaited(_export.cancel());
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _export.removeListener(_exportChanged);
    _export.dispose();
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
            final wide = constraints.maxWidth >= 700;
            final maximumPreview =
                ((wide ? constraints.maxHeight : constraints.maxHeight * .7) -
                        275)
                    .clamp(32.0, 440.0);
            return Flex(
              direction: wide ? Axis.horizontal : Axis.vertical,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: wide
                        ? constraints.maxHeight
                        : constraints.maxHeight * .7,
                    maxWidth: wide
                        ? constraints.maxWidth * .5
                        : double.infinity,
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
                          Row(
                            key: ValueKey(('crop-zoom-controls', _locked)),
                            children: [
                              const Icon(Icons.zoom_in, size: 20),
                              Expanded(
                                child: Slider(
                                  key: const Key('crop-zoom'),
                                  min: 1,
                                  max: 2.5,
                                  divisions: 15,
                                  value: _options.zoom,
                                  label: '${_options.zoom.toStringAsFixed(1)}배',
                                  onChanged: _locked
                                      ? null
                                      : (v) =>
                                            _adjust(_options.copyWith(zoom: v)),
                                  onChangeEnd: _locked
                                      ? null
                                      : (_) =>
                                            _adjust(_options, immediate: true),
                                ),
                              ),
                              Text('${_options.zoom.toStringAsFixed(1)}배'),
                              IconButton(
                                key: const Key('crop-reset'),
                                tooltip: '확대·위치 초기화',
                                onPressed: _locked
                                    ? null
                                    : () => _adjust(
                                        _options.copyWith(
                                          zoom: 1,
                                          offsetX: 0,
                                          offsetY: 0,
                                        ),
                                        immediate: true,
                                      ),
                                icon: const Icon(Icons.restart_alt),
                              ),
                            ],
                          ),
                          if (_player?.value.isInitialized == true)
                            Row(
                              key: ValueKey((
                                'crop-play-controls',
                                _export.busy,
                              )),
                              children: [
                                IconButton.filledTonal(
                                  key: const Key('crop-play'),
                                  onPressed:
                                      _playerError == null && !_export.busy
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
                                    onChanged: _export.busy
                                        ? null
                                        : (v) => unawaited(_seek(v.round())),
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
                if (wide)
                  const VerticalDivider(width: 1)
                else
                  const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      // 조작 잠금이 바뀌면 접근성 노드도 새로 연결합니다. 스크롤 위치와 재생기는 유지합니다.
                      key: ValueKey(('crop-settings', _locked)),
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
                          onChanged: _locked
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
                        const Text(
                          '3:4는 세로 비율입니다. 릴스처럼 화면을 길게 채우려면 9:16을 선택하세요.',
                        ),
                        const SizedBox(height: 12),
                        const Text('크롭 위치 조절'),
                        const Text(
                          '원본에서 영역 보기를 켜고 화면을 드래그하거나 아래 슬라이더를 움직이세요. 조절한 위치 차이는 전체 영상에 적용됩니다.',
                        ),
                        _positionSlider(
                          '좌우',
                          'crop-offset-x',
                          _options.offsetX,
                          (v) => _options.copyWith(offsetX: v),
                        ),
                        _positionSlider(
                          '상하',
                          'crop-offset-y',
                          _options.offsetY,
                          (v) => _options.copyWith(offsetY: v),
                        ),
                        const Text(
                          '기본값은 사람 주변에 여유를 둡니다. 값을 높이면 더 가까이 보여줍니다. 넓은 비율이나 큰 확대에서는 몸 일부가 잘릴 수 있어요.',
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('부드럽게 따라가기'),
                          value: _options.smooth,
                          onChanged: _locked
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
                                  _locked ||
                                  timeline.options != _options
                              ? null
                              : () => unawaited(_save()),
                          icon: const Icon(Icons.save_outlined),
                          label: Text(_saving ? '저장 중…' : '크롭 설정 저장'),
                        ),
                        if (_savedPath != null)
                          const Text('크롭 경로와 설정을 앱 내부에 저장했습니다.'),
                        const SizedBox(height: 12),
                        if (widget.info.source.type == MediaType.video)
                          ..._exportControls(timeline),
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

  Widget _positionSlider(
    String title,
    String key,
    double value,
    CropOptions Function(double) options,
  ) => Row(
    children: [
      Text(title),
      Expanded(
        child: Slider(
          key: Key(key),
          min: -.5,
          max: .5,
          value: value,
          label: '${(value * 100).round()}%',
          onChanged: _locked ? null : (v) => _adjust(options(v)),
          onChangeEnd: _locked
              ? null
              : (_) => _adjust(_options, immediate: true),
        ),
      ),
      Text('${(value * 100).round()}%'),
    ],
  );

  List<Widget> _exportControls(CropTimeline? timeline) {
    final output = _export.output;
    return [
      const Divider(),
      const Text('영상 내보내기 · MP4 / H.264'),
      const Text('완료 후 갤러리에 저장합니다. 구형 Android는 저장 위치를 선택합니다.'),
      const Text('원본 영상에서 한 번 인코딩합니다. 확대하면 원본에 없는 세부 정보가 생기지는 않습니다.'),
      DropdownButtonFormField<ExportQuality>(
        key: const Key('export-quality'),
        initialValue: _quality,
        decoration: const InputDecoration(labelText: '출력 화질'),
        items: ExportQuality.values
            .map((q) => DropdownMenuItem(value: q, child: Text(q.label)))
            .toList(),
        onChanged: _export.busy
            ? null
            : (q) {
                if (q != null) setState(() => _quality = q);
              },
      ),
      const Text('작은 원본은 출력 크기를 낮춥니다. 크롭한 영역은 출력 크기에 맞춰 확대될 수 있어요.'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('원본 소리 유지'),
        value: _keepAudio,
        onChanged: _export.busy ? null : (v) => setState(() => _keepAudio = v),
      ),
      FilledButton.icon(
        key: const Key('export-video'),
        onPressed:
            timeline == null ||
                _planning ||
                _locked ||
                timeline.options != _options ||
                _playerError != null
            ? null
            : () => unawaited(_render()),
        icon: const Icon(Icons.movie_outlined),
        label: const Text('MP4 내보내기'),
      ),
      if (_export.stage == ExportStage.rendering) ...[
        LinearProgressIndicator(value: _export.progress),
        Text(
          _export.progress == null
              ? '영상을 준비하고 있습니다…'
              : '내보내는 중 ${(_export.progress! * 100).floor()}%',
        ),
        TextButton(
          key: const Key('cancel-export'),
          onPressed: () => unawaited(_export.cancel()),
          child: const Text('내보내기 취소'),
        ),
        const Text('완료될 때까지 앱을 열어두세요. 화면을 나가거나 앱을 백그라운드로 보내면 취소됩니다.'),
      ],
      if (_export.stage == ExportStage.cancelled)
        const Text('내보내기를 취소했습니다. 다시 시작할 수 있습니다.'),
      if (_export.error != null)
        Text(
          _export.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (output != null) ...[
        Text(
          'MP4 생성 완료 · ${output.width}×${output.height} · ${formatFileSize(output.sizeBytes)} · ${output.hasAudio ? '소리 포함' : '소리 없음'}',
        ),
        OutlinedButton.icon(
          key: const Key('preview-export'),
          onPressed: _export.busy
              ? null
              : () {
                  unawaited(_pause());
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ExportPreview(output: output),
                    ),
                  );
                },
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('내보낸 영상 확인'),
        ),
        FilledButton.icon(
          key: const Key('save-export'),
          onPressed: _export.busy || _export.savedLocation != null
              ? null
              : () => unawaited(_export.save()),
          icon: const Icon(Icons.download),
          label: Text(
            _export.saving
                ? '저장 중…'
                : _export.savedLocation != null
                ? '저장 완료'
                : '갤러리 / 파일에 저장',
          ),
        ),
        Text(
          _export.savedLocation != null
              ? '앱 밖에서도 영상을 사용할 수 있습니다.'
              : '영상은 앱에 보관되어 있습니다. 위 버튼으로 갤러리나 파일에 저장하세요.',
        ),
      ],
    ];
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
                ? GestureDetector(
                    key: const Key('crop-drag'),
                    onPanStart: _locked ? null : (_) => unawaited(_pause()),
                    onPanUpdate: _locked
                        ? null
                        : (details) => _adjust(
                            _options.copyWith(
                              offsetX:
                                  (_options.offsetX + details.delta.dx / width)
                                      .clamp(-.5, .5),
                              offsetY:
                                  (_options.offsetY + details.delta.dy / height)
                                      .clamp(-.5, .5),
                            ),
                          ),
                    onPanEnd: _locked
                        ? null
                        : (_) => _adjust(_options, immediate: true),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        media,
                        CustomPaint(painter: CropOverlay(frame.rect)),
                      ],
                    ),
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
