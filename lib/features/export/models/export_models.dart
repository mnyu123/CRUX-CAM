import '../../crop/models/crop_models.dart';

enum ExportQuality {
  standard('기본 · 짧은 변 최대 720px', 720, 6000000),
  high('높음 · 짧은 변 최대 1080px', 1080, 12000000);

  const ExportQuality(this.label, this.shortSide, this.bitrate);
  final String label;
  final int shortSide, bitrate;
}

class ExportSettings {
  const ExportSettings({
    this.quality = ExportQuality.standard,
    this.keepAudio = true,
  });
  final ExportQuality quality;
  final bool keepAudio;

  Map<String, Object> toJson() => {
    'shortSide': quality.shortSide,
    'bitrate': quality.bitrate,
    'keepAudio': keepAudio,
    'container': 'mp4',
    'codec': 'h264',
  };
}

enum ExportStage { idle, rendering, completed, cancelled, failed }

class ExportOutput {
  const ExportOutput({
    required this.path,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.durationMs,
    required this.hasAudio,
  });
  factory ExportOutput.fromMap(Map<Object?, Object?> map) => ExportOutput(
    path: map['path'] as String,
    width: (map['width'] as num).toInt(),
    height: (map['height'] as num).toInt(),
    sizeBytes: (map['sizeBytes'] as num).toInt(),
    durationMs: (map['durationMs'] as num).toInt(),
    hasAudio: map['hasAudio'] == true,
  );
  final String path;
  final int width, height, sizeBytes, durationMs;
  final bool hasAudio;
}

/// 미리보기에서 확정한 좌표만 보내므로 내보내기 때 인물 분석을 다시 하지 않습니다.
Map<String, Object?> exportRequest(
  String id,
  String path,
  CropTimeline timeline,
  ExportSettings settings,
) {
  if (timeline.frames.isEmpty ||
      timeline.durationMs <= 0 ||
      timeline.frames.length > 6000) {
    throw const FormatException('내보낼 크롭 경로가 없습니다.');
  }
  var lastTime = -1;
  for (final frame in timeline.frames) {
    final r = frame.rect;
    if (frame.timeMs <= lastTime ||
        frame.timeMs < 0 ||
        frame.timeMs > timeline.durationMs ||
        ![r.left, r.top, r.width, r.height].every((v) => v.isFinite) ||
        r.left < 0 ||
        r.top < 0 ||
        r.width <= 0 ||
        r.height <= 0 ||
        r.left + r.width > 1.000001 ||
        r.top + r.height > 1.000001) {
      throw const FormatException('크롭 경로가 올바르지 않습니다. 다시 계산해주세요.');
    }
    lastTime = frame.timeMs;
  }
  return {
    'id': id,
    'path': path,
    'timeline': timeline.toJson(''),
    'settings': settings.toJson(),
  };
}
