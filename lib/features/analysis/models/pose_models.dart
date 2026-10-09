import 'dart:math' as math;
import 'dart:typed_data';

enum PoseEngine {
  mediaPipeFull('mediapipe_full', 'MediaPipe Full'),
  mediaPipeLite('mediapipe_lite', 'MediaPipe Lite'),
  mlKitAccurate('mlkit_accurate', 'ML Kit Accurate');

  const PoseEngine(this.id, this.label);
  final String id;
  final String label;
  String get description => switch (this) {
    mediaPipeFull => '관절을 자세히 확인할 때 쓰는 기본 모델이에요. 여러 사람을 함께 찾을 수 있어요.',
    mediaPipeLite => '가볍고 빠르게 분석할 때 좋아요. 작은 사람이나 가려진 관절은 놓칠 수 있어요.',
    mlKitAccurate => '한 사람의 관절을 정밀하게 분석하는 비교 모델이에요. 여러 명은 추가 영역 분석을 이용해주세요.',
  };
}

/// 원본 전체 화면 기준의 분석 영역입니다. 실제 영상 크롭과는 별개입니다.
class PoseRegion {
  PoseRegion(this.left, this.top, this.right, this.bottom) {
    if ([left, top, right, bottom].any((v) => !v.isFinite || v < 0 || v > 1) ||
        right - left < .05 ||
        bottom - top < .05) {
      throw const FormatException('사람의 몸이 포함되도록 조금 더 넓게 영역을 지정해주세요.');
    }
  }
  final double left, top, right, bottom;
  List<double> toJson() => [left, top, right, bottom];
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
  PoseBody(List<PosePoint> points, {List<double>? appearance})
    : points = List.unmodifiable(points),
      appearance =
          appearance != null &&
              appearance.length == 96 &&
              appearance.every((v) => v.isFinite && v >= 0) &&
              appearance.fold<double>(0, (a, b) => a + b) > 0
          ? List.unmodifiable(appearance)
          : null {
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
  // 옷 색 분포를 번호 연결의 보조 정보로만 씁니다. 얼굴 식별 정보는 아닙니다.
  final List<double>? appearance;

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

  /// 두 모델이 같은 사람을 각각 찾은 결과인지 판단합니다.
  /// 일부만 겹친 잘못된 보조 결과도 기존 사람 옆의 새 후보로 만들지 않도록 넉넉하게 같다고 봅니다.
  bool overlaps(PoseBody other) {
    if (!usable || !other.usable) return false;
    final a = center, b = other.center;
    final distance = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
    if (distance < math.max(.08, math.min(span, other.span) * .5)) return true;
    final x = bounds, y = other.bounds;
    final intersection =
        math.max(0.0, math.min(x.right, y.right) - math.max(x.left, y.left)) *
        math.max(0.0, math.min(x.bottom, y.bottom) - math.max(x.top, y.top));
    final union =
        (x.right - x.left) * (x.bottom - x.top) +
        (y.right - y.left) * (y.bottom - y.top) -
        intersection;
    return union > 0 && intersection / union > .2;
  }

  List<List<double>> toJson() => points.map((p) => p.toJson()).toList();
  factory PoseBody.fromList(
    List<dynamic> values, {
    List<dynamic>? appearance,
  }) => PoseBody(
    values.map((p) => PosePoint.fromList(p as List<dynamic>)).toList(),
    appearance: appearance?.map((v) => (v as num).toDouble()).toList(),
  );
}

class PoseFrame {
  const PoseFrame({
    required this.timeMs,
    required this.bodies,
    required this.inferenceMs,
    this.preview,
    this.personIds = const [],
  });
  final int timeMs;
  final List<PoseBody> bodies;
  final double inferenceMs;
  final Uint8List? preview;
  final List<int?> personIds;
  int? personIdAt(int index) =>
      index < personIds.length ? personIds[index] : null;
  factory PoseFrame.fromMap(Map<dynamic, dynamic> data) {
    final bodies = parseBodies(data['poses'], data['appearances']);
    // 보조 모델 결과는 기본 모델이 찾지 못한 사람일 때만 후보로 더합니다.
    // 이미 찾은 사람과 겹치면 버려서 같은 사람이 두 번 잡히지 않게 합니다.
    for (final extra in parseBodies(
      data['assistPoses'],
      data['assistAppearances'],
    )) {
      if (extra.usable && !bodies.any((b) => b.overlaps(extra))) {
        bodies.add(extra);
      }
    }
    return PoseFrame(
      timeMs: (data['timeMs'] as num).toInt(),
      bodies: List.unmodifiable(bodies),
      inferenceMs: (data['inferenceMs'] as num).toDouble(),
      preview: data['preview'] as Uint8List?,
    );
  }

  /// OS가 보낸 관절 목록과 옷 색 목록을 몸 단위로 묶습니다.
  static List<PoseBody> parseBodies(Object? poses, Object? appearances) {
    final list = poses as List<dynamic>? ?? const [];
    final colors = appearances as List<dynamic>?;
    return [
      for (var i = 0; i < list.length; i++)
        PoseBody.fromList(
          list[i] as List<dynamic>,
          appearance: colors != null && i < colors.length
              ? colors[i] as List<dynamic>?
              : null,
        ),
    ];
  }
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
    this.selectedPersonId,
    this.regions = const [],
  });
  final PoseSession session;
  final PoseEngine engine;
  final int intervalMs;
  final List<PoseFrame> frames;
  final List<TrackedFrame> tracked;
  final int elapsedMs;
  final int? anchorMs;
  final int? anchorIndex;
  final int? selectedPersonId;
  final List<PoseRegion> regions;
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
        selectedPersonId: frames[indexAt(time)].personIdAt(index),
        regions: regions,
      );

  /// 사람 선택을 해제한 결과. 감지 후보·번호·추가 분석 영역은 유지합니다.
  AnalysisResult withoutTracking() => AnalysisResult(
    session: session,
    engine: engine,
    intervalMs: intervalMs,
    frames: frames,
    elapsedMs: elapsedMs,
    regions: regions,
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
    'schemaVersion': 2,
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
    'selectedPersonId': selectedPersonId,
    'analysisRegions': regions.map((r) => r.toJson()).toList(),
    'frames': [
      for (var i = 0; i < frames.length; i++)
        {
          'timeMs': frames[i].timeMs,
          'inferenceMs': frames[i].inferenceMs,
          'candidates': frames[i].bodies.map((p) => p.toJson()).toList(),
          'personIds': frames[i].personIds,
          'appearances': frames[i].bodies.map((b) => b.appearance).toList(),
          if (tracked.isNotEmpty) 'target': tracked[i].toJson(),
        },
    ],
  };
}
