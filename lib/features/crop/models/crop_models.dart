import 'dart:math' as math;

enum CropRatio {
  original('원본 비율', null),
  portrait('9:16', 9 / 16),
  landscape('16:9', 16 / 9),
  fourFive('4:5', 4 / 5),
  threeFour('3:4', 3 / 4),
  square('1:1', 1);

  const CropRatio(this.label, this.aspect);
  final String label;
  final double? aspect;
}

class CropOptions {
  const CropOptions({
    this.ratio = CropRatio.portrait,
    this.zoom = 1,
    this.smooth = true,
    this.offsetX = 0,
    this.offsetY = 0,
  });
  final CropRatio ratio;
  final double zoom;
  final bool smooth;
  // 자동 추적 위치에서 화면 전체 크기를 기준으로 더 이동할 거리입니다.
  final double offsetX, offsetY;
  // 별도 실행 공간에서 돌아온 설정도 내용이 같으면 같은 설정으로 판단합니다.
  @override
  bool operator ==(Object other) =>
      other is CropOptions &&
      ratio == other.ratio &&
      zoom == other.zoom &&
      smooth == other.smooth &&
      offsetX == other.offsetX &&
      offsetY == other.offsetY;
  @override
  int get hashCode => Object.hash(ratio, zoom, smooth, offsetX, offsetY);
  CropOptions copyWith({
    CropRatio? ratio,
    double? zoom,
    bool? smooth,
    double? offsetX,
    double? offsetY,
  }) => CropOptions(
    ratio: ratio ?? this.ratio,
    zoom: zoom ?? this.zoom,
    smooth: smooth ?? this.smooth,
    offsetX: offsetX ?? this.offsetX,
    offsetY: offsetY ?? this.offsetY,
  );
  Map<String, dynamic> toJson() => {
    'ratio': ratio.name,
    'zoom': zoom,
    'smooth': smooth,
    'offsetX': offsetX,
    'offsetY': offsetY,
  };
}

/// 영상 전체를 0~1로 본 크롭 영역입니다. 분석용 추가 영역과 별도로 사용합니다.
class CropRect {
  const CropRect(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;
  List<double> toJson() => [left, top, width, height];
  CropRect interpolate(CropRect next, double t) => CropRect(
    left + (next.left - left) * t,
    top + (next.top - top) * t,
    width + (next.width - width) * t,
    height + (next.height - height) * t,
  );
}

/// following: 찾은 위치를 따라감, bridged: 잠시 놓친 구간을 앞뒤 위치로 이음,
/// held: 오래 놓쳐 마지막 영역 유지, waiting: 처음 찾기 전 넓은 영역 표시.
enum CropStatus { following, bridged, held, waiting }

class CropFrame {
  const CropFrame({
    required this.timeMs,
    required this.rect,
    required this.status,
  });
  final int timeMs;
  final CropRect rect;
  final CropStatus status;
  Map<String, dynamic> toJson() => {
    'timeMs': timeMs,
    'rect': rect.toJson(),
    'status': status.name,
  };
}

class CropTimeline {
  const CropTimeline({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.personId,
    required this.engine,
    required this.options,
    required this.frames,
  });
  final int width, height, durationMs;
  final int? personId;
  final String engine;
  final CropOptions options;
  final List<CropFrame> frames;
  double get sourceAspect => width / height;
  double get outputAspect => options.ratio.aspect ?? sourceAspect;

  CropFrame at(int timeMs) {
    final time = timeMs.clamp(0, math.max(0, durationMs)).toInt();
    var low = 0, high = frames.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (frames[middle].timeMs <= time) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final a = frames[low];
    if (low == frames.length - 1) return a;
    final b = frames[low + 1];
    // 크롭 경로는 놓친 구간까지 미리 계산되어 있으므로 상태와 관계없이 프레임 사이를 잇습니다.
    // 유지 구간은 앞뒤 영역이 같아 움직이지 않습니다. 내보내기도 같은 방식으로 계산합니다.
    final fraction = ((time - a.timeMs) / (b.timeMs - a.timeMs)).clamp(
      0.0,
      1.0,
    );
    return CropFrame(
      timeMs: time,
      rect: a.rect.interpolate(b.rect, fraction),
      status: a.status,
    );
  }

  Map<String, dynamic> toJson(String sourceName) => {
    'schemaVersion': 1,
    'kind': 'crop_timeline',
    'sourceName': sourceName,
    'coordinateSpace': 'upright_normalized',
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'personId': personId,
    'engine': engine,
    'options': options.toJson(),
    'outputAspect': outputAspect,
    'frames': frames.map((f) => f.toJson()).toList(),
  };
}
