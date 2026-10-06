import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pose/analysis_store.dart';
import '../../../core/pose/pose_service.dart';
import '../../../core/tracking/subject_tracker.dart';
import '../../../core/tracking/person_catalog.dart';
import '../../media/models/media_info.dart';
import '../models/pose_models.dart';

final analysisControllerProvider =
    NotifierProvider.autoDispose<AnalysisController, AnalysisState>(
      AnalysisController.new,
    );

enum AnalysisPhase {
  idle,
  preparing,
  analyzing,
  tracking,
  cancelling,
  ready,
  cancelled,
  failed,
}

class AnalysisState {
  const AnalysisState({
    this.phase = AnalysisPhase.idle,
    this.engines = const [],
    this.completed = 0,
    this.total = 0,
    this.result,
    this.error,
    this.saving = false,
    this.savedPath,
  });
  final AnalysisPhase phase;
  final List<PoseEngine> engines;
  final int completed;
  final int total;
  final AnalysisResult? result;
  final String? error;
  final bool saving;
  final String? savedPath;
  bool get busy => [
    AnalysisPhase.preparing,
    AnalysisPhase.analyzing,
    AnalysisPhase.tracking,
    AnalysisPhase.cancelling,
  ].contains(phase);
}

class AnalysisController extends Notifier<AnalysisState> {
  int _generation = 0;
  String? _sessionId;
  bool _cancelled = false;
  bool _loadingEngines = false;
  static int _nextSession = 0;

  @override
  AnalysisState build() {
    final service = ref.read(poseServiceProvider);
    ref.onDispose(() {
      _generation++;
      _cancelled = true;
      final id = _sessionId;
      if (id != null) unawaited(service.close(id).catchError((Object _) {}));
    });
    return const AnalysisState();
  }

  Future<void> loadEngines() async {
    if (_loadingEngines || state.engines.isNotEmpty) return;
    _loadingEngines = true;
    try {
      final engines = await ref.read(poseServiceProvider).engines();
      if (!ref.mounted) return;
      state = AnalysisState(
        engines: engines,
        error: engines.isEmpty ? '이 기기에서 사용할 분석 모델이 없습니다.' : null,
      );
    } catch (error) {
      if (ref.mounted) state = AnalysisState(error: _message(error));
    } finally {
      _loadingEngines = false;
    }
  }

  Future<void> analyze(
    MediaInfo info,
    PoseEngine engine,
    int fps, {
    PoseRegion? region,
  }) async {
    if (state.busy || state.saving || !state.engines.contains(engine)) return;
    final previous = region == null ? null : state.result;
    if (region != null && previous == null) return;
    if (previous != null) engine = previous.engine;
    final service = ref.read(poseServiceProvider);
    final engines = state.engines;
    final generation = ++_generation;
    final id = '${DateTime.now().microsecondsSinceEpoch}_${++_nextSession}';
    _sessionId = id;
    _cancelled = false;
    final timer = Stopwatch()..start();
    bool active() => ref.mounted && generation == _generation;
    state = AnalysisState(
      phase: AnalysisPhase.preparing,
      engines: engines,
      result: previous,
    );
    AnalysisResult? result;
    Object? failure;
    try {
      final session = await service
          .open(id, info.source, engine, region: region)
          .timeout(const Duration(seconds: 60));
      if (!active() || _cancelled) return;
      if (session.width <= 0 ||
          session.height <= 0 ||
          (info.source.type == MediaType.video && session.durationMs <= 0)) {
        throw const FormatException('분석할 미디어 정보를 읽을 수 없습니다.');
      }
      if (session.durationMs > 10 * 60 * 1000) {
        throw const FormatException('현재는 10분 이하 영상 분석을 지원합니다. 짧은 영상을 선택해주세요.');
      }
      // 분석 결과가 무한히 늘지 않도록 6,000개 이하로 제한합니다.
      // 설정값보다 간격이 늘어난 경우 실제 간격을 결과 화면과 저장 파일에 남깁니다.
      final interval =
          previous?.intervalMs ??
          math.max(
            (1000 / fps.clamp(1, 10)).round(),
            (session.durationMs / 6000).ceil(),
          );
      final total = info.source.type == MediaType.image
          ? 1
          : (session.durationMs / interval).ceil();
      final frames = <PoseFrame>[];
      for (var i = 0; i < total; i++) {
        if (!active() || _cancelled) return;
        state = AnalysisState(
          phase: AnalysisPhase.analyzing,
          engines: engines,
          completed: i,
          total: total,
          result: previous,
        );
        final frame = await service
            .frame(
              id,
              i * interval,
              preview: info.source.type == MediaType.image,
            )
            .timeout(const Duration(seconds: 30));
        if (!active() || _cancelled) return;
        if (frame.timeMs != i * interval) {
          throw const FormatException('프레임 시간이 일치하지 않습니다.');
        }
        frames.add(frame);
      }
      if (previous != null &&
          !frames.any((f) => f.bodies.any((b) => b.usable))) {
        throw const FormatException(
          '지정한 영역에서 사람을 감지하지 못했습니다. 영역을 넓히거나 다른 모델로 전체 분석해주세요.',
        );
      }
      final catalogued = await compute(_catalogFrames, (
        previous?.frames,
        frames,
      ));
      if (!active() || _cancelled) return;
      result = AnalysisResult(
        session: session,
        engine: engine,
        intervalMs: interval,
        frames: catalogued,
        regions: [...?previous?.regions, ?region],
        elapsedMs: (previous?.elapsedMs ?? 0) + timer.elapsedMilliseconds,
      );
    } catch (error) {
      failure = error;
    } finally {
      // 취소·실패·화면 종료도 모두 같은 해제 경로를 거쳐 다음 분석과 겹치지 않게 합니다.
      try {
        await service.close(id).timeout(const Duration(seconds: 30));
      } catch (error) {
        failure ??= error;
      }
      if (_sessionId == id) _sessionId = null;
      if (active()) {
        if (_cancelled) {
          state = AnalysisState(
            phase: AnalysisPhase.cancelled,
            engines: engines,
            result: previous,
          );
        } else if (failure != null) {
          state = AnalysisState(
            phase: AnalysisPhase.failed,
            engines: engines,
            error: _message(failure),
            result: previous,
          );
        } else if (result != null) {
          state = AnalysisState(
            phase: AnalysisPhase.ready,
            engines: engines,
            completed: result.frames.length,
            total: result.frames.length,
            result: result,
          );
        }
      }
    }
  }

  void cancel() {
    if (!state.busy || _cancelled) return;
    _cancelled = true;
    state = AnalysisState(
      phase: AnalysisPhase.cancelling,
      engines: state.engines,
      completed: state.completed,
      total: state.total,
      result: state.result,
    );
    final id = _sessionId;
    // OS에 즉시 취소 신호를 보내고, 실제 해제가 끝날 때까지 재시작을 막습니다.
    if (id != null) {
      unawaited(
        ref.read(poseServiceProvider).close(id).catchError((Object _) {}),
      );
    }
  }

  Future<void> selectTarget(int frameIndex, int bodyIndex) async {
    final result = state.result;
    if (result == null || state.saving || state.busy) return;
    final engines = state.engines;
    final generation = ++_generation;
    _cancelled = false;
    state = AnalysisState(
      phase: AnalysisPhase.tracking,
      engines: engines,
      result: result,
    );
    try {
      final frame = result.frames[frameIndex];
      // 긴 영상의 대상 선택도 화면을 멈추지 않도록 좌표 계산을 별도로 실행합니다.
      final personId = frame.personIdAt(bodyIndex);
      if (frame.personIds.isNotEmpty && personId == null) {
        throw const FormatException('사람 번호를 구분할 수 있는 시점으로 이동해 선택해주세요.');
      }
      // 번호가 있는 결과에서는 다른 번호의 사람을 추적 후보에서 제외합니다.
      final frames = personId == null
          ? result.frames
          : result.frames
                .map(
                  (f) => PoseFrame(
                    timeMs: f.timeMs,
                    inferenceMs: f.inferenceMs,
                    bodies: [
                      for (var i = 0; i < f.bodies.length; i++)
                        if (f.personIdAt(i) == personId) f.bodies[i],
                    ],
                  ),
                )
                .toList();
      final tracked = await compute(_trackFrames, (
        frames,
        frameIndex,
        personId == null ? bodyIndex : 0,
        personId != null,
      ));
      if (!ref.mounted || generation != _generation) return;
      state = AnalysisState(
        phase: AnalysisPhase.ready,
        engines: engines,
        result: _cancelled
            ? result
            : result.withTracking(tracked, frame.timeMs, bodyIndex),
      );
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = AnalysisState(
        phase: AnalysisPhase.ready,
        engines: engines,
        result: result,
        error: _message(error),
      );
    }
  }

  Future<void> save(String sourceName) async {
    final result = state.result;
    if (result == null ||
        result.tracked.isEmpty ||
        state.saving ||
        state.busy) {
      return;
    }
    final generation = _generation;
    final engines = state.engines;
    state = AnalysisState(
      phase: AnalysisPhase.ready,
      engines: engines,
      result: result,
      saving: true,
    );
    try {
      final path = await ref
          .read(analysisStoreProvider)
          .save(result, sourceName);
      if (ref.mounted && generation == _generation) {
        state = AnalysisState(
          phase: AnalysisPhase.ready,
          engines: engines,
          result: result,
          savedPath: path,
        );
      }
    } catch (error) {
      if (ref.mounted && generation == _generation) {
        state = AnalysisState(
          phase: AnalysisPhase.ready,
          engines: engines,
          result: result,
          error: _message(error),
        );
      }
    }
  }

  String _message(Object error) => switch (error) {
    MissingPluginException() =>
      '이 빌드에는 관절 분석 기능이 연결되지 않았습니다. 해당 OS의 Phase 2 빌드를 설치해주세요.',
    PlatformException(:final message) => message ?? '기기에서 분석을 실행하지 못했습니다.',
    TimeoutException() => '분석 응답이 너무 늦습니다. 짧은 영상이나 가벼운 모델로 다시 시도해주세요.',
    FormatException(:final message) => message,
    _ => '분석 중 오류가 발생했습니다. 파일을 다시 선택해 시도해주세요.',
  };
}

List<TrackedFrame> _trackFrames((List<PoseFrame>, int, int, bool) input) =>
    SubjectTracker().track(
      input.$1,
      input.$2,
      input.$3,
      lockedIdentity: input.$4,
    );

List<PoseFrame> _catalogFrames((List<PoseFrame>?, List<PoseFrame>) input) =>
    input.$1 == null
    ? PersonCatalog().assign(input.$2)
    : PersonCatalog().merge(input.$1!, input.$2);
