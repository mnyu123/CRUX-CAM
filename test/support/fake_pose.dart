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
    return poseFrame(timeMs, [
      bodyAt((region == null ? 0.3 : 0.7) + timeMs * 0.0001),
    ]);
  }

  @override
  Future<void> close(String id) async => closed.add(id);
}
