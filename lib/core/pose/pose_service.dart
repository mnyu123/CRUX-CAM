import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/analysis/models/pose_models.dart';
import '../../features/media/models/media_info.dart';

final poseServiceProvider = Provider<PoseService>((ref) => NativePoseService());

abstract class PoseService {
  Future<List<PoseEngine>> engines();
  Future<PoseSession> open(
    String id,
    MediaSource source,
    PoseEngine engine, {
    PoseRegion? region,
  });
  Future<PoseFrame> frame(String id, int timeMs, {bool preview = false});
  Future<void> close(String id);
}

/// 프레임 이미지를 Dart로 계속 복사하지 않고, OS 안에서 추출과 인식을 끝냅니다.
/// 화면에는 관절 좌표와 사진 미리보기만 전달하여 큰 영상의 메모리 사용을 줄입니다.
class NativePoseService implements PoseService {
  static const channel = MethodChannel('crux_cam/pose');

  @override
  Future<List<PoseEngine>> engines() async {
    final ids = await channel.invokeListMethod<String>('engines') ?? [];
    return PoseEngine.values
        .where((engine) => ids.contains(engine.id))
        .toList();
  }

  @override
  Future<PoseSession> open(
    String id,
    MediaSource source,
    PoseEngine engine, {
    PoseRegion? region,
  }) async {
    final data = await channel.invokeMapMethod<String, dynamic>('open', {
      'id': id,
      'path': source.path,
      'type': source.type.name,
      'engine': engine.id,
      if (region != null) 'region': region.toJson(),
    });
    if (data == null) throw const FormatException('분석 준비 결과가 없습니다.');
    return PoseSession(
      id: id,
      width: (data['width'] as num).toInt(),
      height: (data['height'] as num).toInt(),
      durationMs: (data['durationMs'] as num).toInt(),
      storageDirectory: data['storageDirectory'] as String,
    );
  }

  @override
  Future<PoseFrame> frame(String id, int timeMs, {bool preview = false}) async {
    final data = await channel.invokeMapMethod<String, dynamic>('frame', {
      'id': id,
      'timeMs': timeMs,
      'preview': preview,
    });
    if (data == null) throw const FormatException('프레임 분석 결과가 없습니다.');
    return PoseFrame.fromMap(data);
  }

  @override
  Future<void> close(String id) =>
      channel.invokeMethod<void>('close', {'id': id});
}
