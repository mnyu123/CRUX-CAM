import 'dart:async';

import 'package:crux_cam/core/pose/pose_service.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:crux_cam/features/media/models/media_info.dart';

PoseBody bodyAt(double x, {double y = 0.5, double confidence = 0.95}) =>
    PoseBody(
      List.generate(
        33,
        (i) => PosePoint(
          x + (i.isEven ? -0.04 : 0.04),
          y + (i - 16) * 0.01,
          0,
          confidence,
        ),
      ),
    );

PoseFrame poseFrame(int time, List<PoseBody> bodies) =>
    PoseFrame(timeMs: time, bodies: bodies, inferenceMs: 10);

class FakePoseService implements PoseService {
  FakePoseService({required this.directory});
  final String directory;
  final List<String> closed = [];
  int durationMs = 1000;
  Object? openError;
  Completer<PoseFrame>? pendingFrame;
  int calls = 0;
  PoseRegion? region;

  /// 시점별로 다른 감지 결과가 필요할 때 지정합니다. null을 돌려주면 기본 결과를 씁니다.
  List<PoseBody>? Function(int timeMs)? onFrame;
  @override
  Future<List<PoseEngine>> engines() async => [
    PoseEngine.mediaPipeFull,
    PoseEngine.mediaPipeLite,
  ];
  @override
  Future<PoseSession> open(
    String id,
    MediaSource source,
    PoseEngine engine, {
    PoseRegion? region,
  }) async {
    this.region = region;
    if (openError != null) throw openError!;
    return PoseSession(
      id: id,
      width: 640,
      height: 480,
      durationMs: source.type == MediaType.image ? 0 : durationMs,
      storageDirectory: directory,
    );
  }

  @override
  Future<PoseFrame> frame(String id, int timeMs, {bool preview = false}) async {
    calls++;
    if (pendingFrame != null) return pendingFrame!.future;
    final custom = onFrame?.call(timeMs);
    if (custom != null) return poseFrame(timeMs, custom);
    return poseFrame(timeMs, [
      bodyAt((region == null ? 0.3 : 0.7) + timeMs * 0.0001),
    ]);
  }

  /// 다시 찾기 요청 기록과, 요청마다 돌려줄 결과입니다. 기본은 아무도 찾지 못한 결과입니다.
  final List<({int timeMs, PoseRegion region})> refines = [];
  FutureOr<List<PoseBody>> Function(int timeMs, PoseRegion region)? onRefine;

  @override
  Future<List<PoseBody>> refine(
    String id,
    int timeMs,
    PoseRegion region,
  ) async {
    refines.add((timeMs: timeMs, region: region));
    return await onRefine?.call(timeMs, region) ?? const [];
  }

  @override
  Future<void> close(String id) async => closed.add(id);
}
