import 'dart:math' as math;
import 'dart:typed_data';

enum PoseEngine {
  mediaPipeFull('mediapipe_full', 'MediaPipe Full'),
  mediaPipeLite('mediapipe_lite', 'MediaPipe Lite'),
  mlKitAccurate('mlkit_accurate', 'ML Kit Accurate');

  const PoseEngine(this.id, this.label);
  final String id;
  final String label;
}

class PosePoint {
  const PosePoint(this.x, this.y, this.z, this.confidence);
  final double x;
  final double y;
  final double z;
  final double confidence;

  bool get reliable => confidence >= 0.35 && x.isFinite && y.isFinite;
  List<double> toJson() => [x, y, z, confidence];
  factory PosePoint.fromList(List<dynamic> values) => PosePoint(
    (values[0] as num).toDouble(),
    (values[1] as num).toDouble(),
    (values[2] as num).toDouble(),
    (values[3] as num).toDouble().clamp(0, 1),
  );
}

/// 모든 플랫폼은 화면 회전을 적용한 이미지 기준의 0~1 좌표를 반환합니다.
/// 원본 픽셀 수와 화면의 검은 여백이 달라도 같은 분석 결과를 사용할 수 있습니다.
class PoseBody {
  PoseBody(List<PosePoint> points) : points = List.unmodifiable(points) {
    if (points.length != 33 ||
        points.any(
          (p) =>
              !p.x.isFinite ||
              !p.y.isFinite ||
              !p.z.isFinite ||
              !p.confidence.isFinite,
        )) {
      throw const FormatException('관절 좌표 형식이 올바르지 않습니다.');
    }
  }
  final List<PosePoint> points;

  List<PosePoint> get visible => points.where((p) => p.reliable).toList();
  bool get usable =>
      visible.length >= 6 &&
      [11, 12, 23, 24].where((i) => points[i].reliable).length >= 2;
  double get confidence => visible.isEmpty
      ? 0
      : visible.fold<double>(0, (v, p) => v + p.confidence) / visible.length;

  ({double x, double y}) get center {
    final torso = [
      11,
      12,
      23,
      24,
    ].map((i) => points[i]).where((p) => p.reliable).toList();
    final candidates = torso.isEmpty ? visible : torso;
    if (candidates.isEmpty) return (x: 0.5, y: 0.5);
    return (
      x: candidates.fold<double>(0, (v, p) => v + p.x) / candidates.length,
      y: candidates.fold<double>(0, (v, p) => v + p.y) / candidates.length,
    );
  }

  ({double left, double top, double right, double bottom}) get bounds {
    final candidates = visible;
    if (candidates.isEmpty) return (left: 0, top: 0, right: 0, bottom: 0);
    return (
      left: candidates.map((p) => p.x).reduce(math.min),
      top: candidates.map((p) => p.y).reduce(math.min),
      right: candidates.map((p) => p.x).reduce(math.max),
      bottom: candidates.map((p) => p.y).reduce(math.max),
    );
  }

  double get span {
    final b = bounds;
    return math.max(b.right - b.left, b.bottom - b.top).clamp(0.05, 2);
  }

  List<List<double>> toJson() => points.map((p) => p.toJson()).toList();
  factory PoseBody.fromList(List<dynamic> values) => PoseBody(
    values.map((p) => PosePoint.fromList(p as List<dynamic>)).toList(),
  );
}

class PoseFrame {
  const PoseFrame({
    required this.timeMs,
    required this.bodies,
    required this.inferenceMs,
    this.preview,
  });
  final int timeMs;
  final List<PoseBody> bodies;
  final double inferenceMs;
  final Uint8List? preview;
  factory PoseFrame.fromMap(Map<dynamic, dynamic> data) => PoseFrame(
    timeMs: (data['timeMs'] as num).toInt(),
    bodies: List.unmodifiable(
      (data['poses'] as List<dynamic>).map(
        (p) => PoseBody.fromList(p as List<dynamic>),
      ),
    ),
    inferenceMs: (data['inferenceMs'] as num).toDouble(),
    preview: data['preview'] as Uint8List?,
  );
}

class PoseSession {
  const PoseSession({
    required this.id,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.storageDirectory,
  });
  final String id;
  final int width;
  final int height;
  final int durationMs;
  final String storageDirectory;
}

enum TrackStatus { tracked, lost, ambiguous }

class TrackedFrame {
  const TrackedFrame({
    required this.timeMs,
    required this.status,
    this.raw,
    this.corrected,
  });
  final int timeMs;
  final TrackStatus status;
  final PoseBody? raw;
  final PoseBody? corrected;
  Map<String, dynamic> toJson() => {
    'timeMs': timeMs,
    'status': status.name,
    'raw': raw?.toJson(),
    'corrected': corrected?.toJson(),
  };
}

class AnalysisResult {
  const AnalysisResult({
    required this.session,
    required this.engine,
    required this.intervalMs,
    required this.frames,
    required this.elapsedMs,
    this.tracked = const [],
    this.anchorMs,
    this.anchorIndex,
  });
  final PoseSession session;
  final PoseEngine engine;
  final int intervalMs;
  final List<PoseFrame> frames;
  final List<TrackedFrame> tracked;
  final int elapsedMs;
  final int? anchorMs;
  final int? anchorIndex;
  double get meanInferenceMs => frames.isEmpty
      ? 0
      : frames.fold<double>(0, (v, f) => v + f.inferenceMs) / frames.length;
  int get detectedCount =>
      frames.where((f) => f.bodies.any((b) => b.usable)).length;
  int get trackedCount =>
      tracked.where((f) => f.status == TrackStatus.tracked).length;

  AnalysisResult withTracking(List<TrackedFrame> value, int time, int index) =>
      AnalysisResult(
        session: session,
        engine: engine,
        intervalMs: intervalMs,
        frames: frames,
        elapsedMs: elapsedMs,
        tracked: value,
        anchorMs: time,
        anchorIndex: index,
      );

  int indexAt(int timeMs) {
    // 시간을 탐색할 때 전체 결과를 매번 순회하지 않고 이진 탐색으로 찾습니다.
    var low = 0;
    var high = frames.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (frames[middle].timeMs < timeMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0 &&
        (frames[low - 1].timeMs - timeMs).abs() <
            (frames[low].timeMs - timeMs).abs()) {
      return low - 1;
    }
    return low;
  }

  Map<String, dynamic> toJson(String fileName) => {
    'schemaVersion': 1,
    'sourceName': fileName,
    'engine': engine.id,
    'width': session.width,
    'height': session.height,
    'durationMs': session.durationMs,
    'intervalMs': intervalMs,
    'coordinateSpace': 'upright_normalized',
    'elapsedMs': elapsedMs,
    'meanInferenceMs': meanInferenceMs,
    'anchorMs': anchorMs,
    'anchorIndex': anchorIndex,
    'frames': [
      for (var i = 0; i < frames.length; i++)
        {
          'timeMs': frames[i].timeMs,
          'inferenceMs': frames[i].inferenceMs,
          'candidates': frames[i].bodies.map((p) => p.toJson()).toList(),
          if (tracked.isNotEmpty) 'target': tracked[i].toJson(),
        },
    ],
  };
}
