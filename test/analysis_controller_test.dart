import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_cam/core/pose/pose_service.dart';
import 'package:crux_cam/features/analysis/application/analysis_controller.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_media.dart';
import 'support/fake_pose.dart';

const info = MediaInfo(
  source: videoSource,
  width: 640,
  height: 480,
  duration: Duration(seconds: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FakePoseService service;
  late ProviderContainer container;
  late AnalysisController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('crux_analysis_');
    service = FakePoseService(directory: directory.path);
    container = ProviderContainer(
      overrides: [poseServiceProvider.overrideWithValue(service)],
    );
    container.listen(analysisControllerProvider, (_, _) {});
    controller = container.read(analysisControllerProvider.notifier);
    await controller.loadEngines();
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });
  test('프레임을 시간순으로 분석하고 대상 좌표와 원본 결과를 저장한다', () async {
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    expect(
      container.read(analysisControllerProvider).phase,
      AnalysisPhase.ready,
    );
    expect(service.calls, 5);
    expect(service.closed, hasLength(1));
    await controller.selectTarget(0, 0);
    await controller.save(info.source.name);
    final state = container.read(analysisControllerProvider);
    expect(state.error, isNull);
    final data = jsonDecode(
      await File(state.savedPath!).readAsString(),
    ) as Map<String, dynamic>;
    expect(data['schemaVersion'], 2);
    expect(data['coordinateSpace'], 'upright_normalized');
    expect(data['frames'], hasLength(5));
    expect((data['frames'] as List).first['target']['status'], 'tracked');
    expect(
      await directory.list().where((f) => f.path.endsWith('.partial')).length,
      0,
    );
  });
  test('영역 추가 분석 후 두 사람 중 두 번째 사람만 선택하고 번호를 저장한다', () async {
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    await controller.analyze(
      info,
      PoseEngine.mediaPipeFull,
      2,
      region: PoseRegion(.5, 0, 1, 1),
    );
    final result = container.read(analysisControllerProvider).result!;
    expect(result.intervalMs, 200);
    expect(result.frames.first.personIds, [1, 2]);
    expect(result.regions, hasLength(1));
    await controller.selectTarget(0, 1);
    await controller.save(info.source.name);
    final selected = container.read(analysisControllerProvider);
    expect(selected.result!.selectedPersonId, 2);
    expect(selected.result!.trackedCount, 5);
    expect(selected.result!.tracked.every((f) => f.raw!.center.x > .6), isTrue);
    final data = jsonDecode(await File(selected.savedPath!).readAsString());
    expect(data['selectedPersonId'], 2);
    expect(data['frames'][0]['personIds'], [1, 2]);
    expect(data['analysisRegions'], [
      [.5, 0, 1.0, 1.0],
    ]);
  });
  test('영역 추가 분석 취소와 준비 실패는 기존 선택과 분석을 보존한다', () async {
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    await controller.selectTarget(0, 0);
    final original = container.read(analysisControllerProvider).result!;
    service.pendingFrame = Completer<PoseFrame>();
    final job = controller.analyze(
      info,
      PoseEngine.mediaPipeFull,
      5,
      region: PoseRegion(.5, 0, 1, 1),
    );
    await Future<void>.delayed(Duration.zero);
    controller.cancel();
    service.pendingFrame!.complete(poseFrame(0, [bodyAt(.7)]));
    await job;
    expect(container.read(analysisControllerProvider).result, same(original));
    service.pendingFrame = null;
    service.openError = PlatformException(code: 'test', message: '영역 분석 실패');
    await controller.analyze(
      info,
      PoseEngine.mediaPipeFull,
      5,
      region: PoseRegion(.5, 0, 1, 1),
    );
    expect(container.read(analysisControllerProvider).result, same(original));
  });
  test('분석 도중 취소하면 늦게 도착한 결과를 버리고 다시 시작할 수 있다', () async {
    service.pendingFrame = Completer<PoseFrame>();
    final job = controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    await Future<void>.delayed(Duration.zero);
    controller.cancel();
    expect(
      container.read(analysisControllerProvider).phase,
      AnalysisPhase.cancelling,
    );
    service.pendingFrame!.complete(poseFrame(0, [bodyAt(0.4)]));
    await job;
    expect(
      container.read(analysisControllerProvider).phase,
      AnalysisPhase.cancelled,
    );
    expect(container.read(analysisControllerProvider).result, isNull);
    service.pendingFrame = null;
    await controller.analyze(info, PoseEngine.mediaPipeLite, 2);
    expect(
      container.read(analysisControllerProvider).result!.engine,
      PoseEngine.mediaPipeLite,
    );
  });
  test('준비 실패도 세션을 해제하고 오류를 표시한다', () async {
    service.openError = PlatformException(
      code: 'decode',
      message: '영상이 손상되었습니다.',
    );
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    expect(service.closed, hasLength(1));
    expect(container.read(analysisControllerProvider).error, '영상이 손상되었습니다.');
  });
  test('관절 연결 계산을 취소하면 새 대상 결과를 적용하지 않는다', () async {
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    final selection = controller.selectTarget(0, 0);
    expect(
      container.read(analysisControllerProvider).phase,
      AnalysisPhase.tracking,
    );
    controller.cancel();
    await selection;
    expect(container.read(analysisControllerProvider).result!.tracked, isEmpty);
    expect(container.read(analysisControllerProvider).busy, isFalse);
  });
  test('종료된 화면은 대기 중이던 분석 결과로 상태를 갱신하지 않는다', () async {
    service.pendingFrame = Completer<PoseFrame>();
    final job = controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    service.pendingFrame!.complete(poseFrame(0, []));
    await expectLater(job, completes);
    expect(service.closed, isNotEmpty);
  });
  test('사진은 한 프레임만 분석하며 10분 초과 영상은 모델 실행 전에 차단한다', () async {
    await controller.analyze(
      const MediaInfo(source: imageSource, width: 640, height: 480),
      PoseEngine.mediaPipeFull,
      5,
    );
    expect(service.calls, 1);
    service.durationMs = 600001;
    await controller.analyze(info, PoseEngine.mediaPipeFull, 5);
    expect(
      container.read(analysisControllerProvider).phase,
      AnalysisPhase.failed,
    );
    expect(service.calls, 1);
  });
}
