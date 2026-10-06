import 'dart:async';

import 'package:crux_cam/features/crop/models/crop_models.dart';
import 'package:crux_cam/features/export/application/export_controller.dart';
import 'package:crux_cam/features/export/models/export_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CropTimeline timeline({List<CropFrame>? frames}) => CropTimeline(
  width: 720,
  height: 1280,
  durationMs: 1000,
  personId: 1,
  engine: 'test',
  options: const CropOptions(ratio: CropRatio.threeFour),
  frames:
      frames ??
      [
        const CropFrame(
          timeMs: 0,
          rect: CropRect(.2, .1, .6, .45),
          status: CropStatus.following,
        ),
      ],
);

class FakeExport extends ExportService {
  Completer<void>? opening;
  Map<String, Object?>? request;
  int cancelled = 0, released = 0, started = 0;
  bool fail = false, denySave = false;
  @override
  Future<void> start(Map<String, Object?> request) async {
    started++;
    this.request = request;
    await opening?.future;
  }

  @override
  Future<Map<Object?, Object?>> status(String id) async => fail
      ? {'state': 'failed', 'error': '인코더가 지원하지 않습니다.'}
      : {
          'state': 'completed',
          'path': '/export/test.mp4',
          'width': 720,
          'height': 960,
          'durationMs': 1000,
          'sizeBytes': 20000,
          'hasAudio': true,
        };
  @override
  Future<void> cancel(String id) async {
    cancelled++;
  }

  @override
  Future<void> release(String id) async {
    released++;
  }

  @override
  Future<String?> save(String path) async {
    if (denySave) {
      throw PlatformException(code: 'permission', message: '사진 저장 권한이 필요합니다.');
    }
    return 'gallery:test';
  }
}

void main() {
  test('기본은 MP4 H.264와 소리 유지이며 미리보기 좌표를 그대로 내보낸다', () async {
    final service = FakeExport();
    final controller = ExportController(service);
    await controller.start('/input.mp4', timeline(), const ExportSettings());
    expect(controller.stage, ExportStage.completed);
    expect(controller.output!.width / controller.output!.height, .75);
    final settings = service.request!['settings'] as Map;
    expect(settings['codec'], 'h264');
    expect(settings['container'], 'mp4');
    expect(settings['keepAudio'], true);
    expect((service.request!['timeline'] as Map)['frames'][0]['rect'], [
      .2,
      .1,
      .6,
      .45,
    ]);
    expect(service.released, 1);
    controller.dispose();
  });
  test('준비 중 취소와 종료는 뒤늦게 시작된 인코더를 정리한다', () async {
    for (final dispose in [false, true]) {
      final service = FakeExport()..opening = Completer<void>();
      final controller = ExportController(service);
      final task = controller.start(
        '/input.mp4',
        timeline(),
        const ExportSettings(),
      );
      await controller.start(
        '/another.mp4',
        timeline(),
        const ExportSettings(),
      );
      expect(service.started, 1);
      if (dispose) {
        controller.dispose();
      } else {
        await controller.cancel();
      }
      service.opening!.complete();
      await task;
      expect(service.cancelled, greaterThanOrEqualTo(1));
      expect(service.released, 1);
      expect(controller.output, isNull);
      if (!dispose) {
        expect(controller.stage, ExportStage.cancelled);
        controller.dispose();
      }
    }
  });
  test('저장 권한 거부 뒤 결과를 유지하고 저장을 재시도할 수 있다', () async {
    final service = FakeExport()..denySave = true;
    final controller = ExportController(service);
    await controller.start('/input.mp4', timeline(), const ExportSettings());
    await controller.save();
    expect(controller.error, contains('권한'));
    expect(controller.output, isNotNull);
    service.denySave = false;
    await controller.save();
    expect(controller.savedLocation, 'gallery:test');
    expect(controller.error, isNull);
    controller.dispose();
  });
  test('인코더 실패 후 설정을 바꿔 다시 내보낼 수 있다', () async {
    final service = FakeExport()..fail = true;
    final controller = ExportController(service);
    await controller.start('/input.mp4', timeline(), const ExportSettings());
    expect(controller.stage, ExportStage.failed);
    expect(controller.error, contains('인코더'));
    service.fail = false;
    await controller.start(
      '/input.mp4',
      timeline(),
      const ExportSettings(keepAudio: false),
    );
    expect(controller.stage, ExportStage.completed);
    expect(service.started, 2);
    expect(service.released, 2);
    controller.dispose();
  });
  test('화면 밖 좌표와 역순 시간은 네이티브 내보내기 전에 차단한다', () {
    expect(
      () => exportRequest(
        '1',
        '/input.mp4',
        timeline(
          frames: [
            const CropFrame(
              timeMs: 0,
              rect: CropRect(.9, 0, .5, 1),
              status: CropStatus.following,
            ),
          ],
        ),
        const ExportSettings(),
      ),
      throwsFormatException,
    );
    expect(
      () => exportRequest(
        '1',
        '/input.mp4',
        timeline(
          frames: [
            const CropFrame(
              timeMs: 200,
              rect: CropRect(0, 0, 1, 1),
              status: CropStatus.following,
            ),
            const CropFrame(
              timeMs: 100,
              rect: CropRect(0, 0, 1, 1),
              status: CropStatus.following,
            ),
          ],
        ),
        const ExportSettings(),
      ),
      throwsFormatException,
    );
  });
}
