import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crux_cam/core/pose/pose_service.dart';
import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/app/app.dart';
import 'package:crux_cam/features/analysis/application/analysis_controller.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

import 'fixtures/video_fixture.dart';

class _ClimbingMediaService extends LocalMediaService {
  _ClimbingMediaService(this.source);
  final MediaSource source;
  @override
  Future<MediaSource?> pickMedia() async => source;
  @override
  Future<MediaSource?> recoverLostMedia() async => null;
}

/// 테스트용 MP4의 표시 회전만 바꿉니다. 영상 픽셀이나 압축 데이터는 변경하지 않습니다.
Uint8List rotatedFixture() {
  final bytes = base64Decode(videoFixtureBase64);
  final data = ByteData.sublistView(bytes);
  void visit(int start, int end) {
    for (var offset = start; offset + 8 <= end;) {
      final size = data.getUint32(offset);
      if (size < 8 || offset + size > end) break;
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'moov' || type == 'trak') visit(offset + 8, offset + size);
      if (type == 'tkhd') {
        final matrix = offset + 48;
        final values = [0, 65536, 0, -65536, 0, 0, 0, 0, 1073741824];
        for (var i = 0; i < values.length; i++) {
          data.setInt32(matrix + i * 4, values[i]);
        }
      }
      offset += size;
    }
  }

  visit(0, bytes.length);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final service = NativePoseService();
  var counter = 0;
  const uiOnly = bool.fromEnvironment('CRUX_TEST_UI_ONLY');
  String newId() =>
      'integration_${DateTime.now().microsecondsSinceEpoch}_${counter++}';

  if (!uiOnly) {
    testWidgets('실제 모델의 사진·영상 처리, 회전 좌표, 반복 세션 해제', (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'crux_pose_native_',
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 640, 480),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(640, 480);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final photo = File('${directory.path}/blank.png');
      await photo.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      final clip = File('${directory.path}/video.mp4');
      await clip.writeAsBytes(base64Decode(videoFixtureBase64));
      final rotated = File('${directory.path}/rotated.mp4');
      await rotated.writeAsBytes(rotatedFixture());
      final engines = await service.engines();
      expect(engines, contains(PoseEngine.mediaPipeFull));
      try {
        for (final engine in engines) {
          for (final file in [photo, clip, rotated]) {
            final id = newId();
            final type = file == photo ? MediaType.image : MediaType.video;
            try {
              final session = await service.open(
                id,
                MediaSource(
                  path: file.path,
                  name: file.uri.pathSegments.last,
                  sizeBytes: await file.length(),
                  type: type,
                ),
                engine,
              );
              if (file == rotated) {
                expect(session.width / session.height, closeTo(64 / 96, 0.01));
              }
              if (file == clip) {
                expect(session.width / session.height, closeTo(96 / 64, 0.01));
              }
              final frame = await service.frame(id, 0, preview: true);
              expect(frame.timeMs, 0);
              expect(frame.preview, isNotEmpty);
              expect(frame.inferenceMs, greaterThanOrEqualTo(0));
              if (file == photo) expect(frame.bodies, isEmpty);
              if (type == MediaType.video) {
                final second = await service.frame(id, 200);
                expect(second.timeMs, 200);
              }
            } finally {
              await service.close(id);
              await service.close(id);
            }
          }
        }
        // 준비와 취소가 동시에 발생해도 다음 분석을 열 수 있어야 합니다.
        final id = newId();
        final opening = service.open(
          id,
          MediaSource(
            path: clip.path,
            name: 'video.mp4',
            sizeBytes: await clip.length(),
            type: MediaType.video,
          ),
          engines.first,
        );
        final checkedOpening = opening.then<void>(
          (_) {},
          onError: (Object _) {},
        );
        await service.close(id);
        await checkedOpening;
        final next = newId();
        await service.open(
          next,
          MediaSource(
            path: photo.path,
            name: 'blank.png',
            sizeBytes: await photo.length(),
            type: MediaType.image,
          ),
          engines.first,
        );
        await service.close(next);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }

  var climbingPath = const String.fromEnvironment('CRUX_TEST_VIDEO_PATH');
  const climbingAsset = String.fromEnvironment('CRUX_TEST_VIDEO_ASSET');
  Directory? climbingDirectory;
  if (climbingAsset.isNotEmpty) {
    setUpAll(() async {
      climbingDirectory = await Directory.systemTemp.createTemp(
        'crux_climbing_fixture_',
      );
      final data = await rootBundle.load(climbingAsset);
      final file = File('${climbingDirectory!.path}/climbing.mp4');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      climbingPath = file.path;
    });
    tearDownAll(() async => climbingDirectory?.delete(recursive: true));
  }
  if (climbingPath.isNotEmpty || climbingAsset.isNotEmpty) {
    if (!uiOnly) {
      testWidgets('사용자 클라이밍 영상의 모델 비교와 추적 결과 저장', (tester) async {
        final file = File(climbingPath);
        expect(await file.exists(), isTrue);
        final source = MediaSource(
          path: file.path,
          name: 'climbing_sample.mp4',
          sizeBytes: await file.length(),
          type: MediaType.video,
        );
        final container = ProviderContainer();
        container.listen(analysisControllerProvider, (_, _) {});
        final controller = container.read(analysisControllerProvider.notifier);
        final summaries = <Map<String, dynamic>>[];
        try {
          await controller.loadEngines();
          for (final engine
              in container.read(analysisControllerProvider).engines) {
            await controller.analyze(
              MediaInfo(source: source, width: 1280, height: 720),
              engine,
              5,
            );
            final state = container.read(analysisControllerProvider);
            expect(state.error, isNull);
            final result = state.result!;
            expect(result.detectedCount, greaterThan(0));
            final anchor = result.frames.indexWhere(
              (f) => f.bodies.any((b) => b.usable),
            );
            final body = result.frames[anchor].bodies.indexWhere(
              (b) => b.usable,
            );
            await controller.selectTarget(anchor, body);
            await controller.save(source.name);
            final saved = container.read(analysisControllerProvider);
            expect(saved.error, isNull);
            expect(await File(saved.savedPath!).exists(), isTrue);
            summaries.add({
              'engine': engine.id,
              'frames': result.frames.length,
              'detected': result.detectedCount,
              'tracked': saved.result!.trackedCount,
              'meanInferenceMs': result.meanInferenceMs,
              'elapsedMs': result.elapsedMs,
              'savedPath': saved.savedPath,
            });
          }
          debugPrint('CRUX_POSE_BENCHMARK=${jsonEncode(summaries)}');
        } finally {
          container.dispose();
        }
      });
    }
    if (!uiOnly) {
      testWidgets('지정 영역의 실제 모델 좌표를 원본 화면으로 돌려주고 여러 후보를 합친다', (tester) async {
        final file = File(climbingPath);
        final source = MediaSource(
          path: file.path,
          name: 'climbing_sample.mp4',
          sizeBytes: await file.length(),
          type: MediaType.video,
        );
        final engines = await service.engines();
        final reports = <Map<String, dynamic>>[];
        for (final engine in engines) {
          final baselineId = newId();
          final baseline = await service.open(baselineId, source, engine);
          await service.close(baselineId);
          for (final region in [
            PoseRegion(0, 0, .65, 1),
            PoseRegion(.35, 0, 1, 1),
          ]) {
            final id = newId();
            try {
              final session = await service.open(
                id,
                source,
                engine,
                region: region,
              );
              expect(
                session.width / session.height,
                closeTo(baseline.width / baseline.height, .01),
              );
              for (final time in [3000, 6000, 12000]) {
                final frame = await service.frame(id, time, preview: true);
                expect(frame.preview, isNotEmpty);
                final codec = await ui.instantiateImageCodec(frame.preview!);
                final decoded = await codec.getNextFrame();
                expect(decoded.image.width, session.width);
                expect(decoded.image.height, session.height);
                decoded.image.dispose();
                codec.dispose();
                for (final body in frame.bodies.where((b) => b.usable)) {
                  expect(
                    body.center.x,
                    inInclusiveRange(region.left - .05, region.right + .05),
                  );
                  expect(body.center.y, inInclusiveRange(-.05, 1.05));
                }
                reports.add({
                  'engine': engine.id,
                  'region': region.toJson(),
                  'timeMs': time,
                  'centers': frame.bodies
                      .where((b) => b.usable)
                      .map((b) => [b.center.x, b.center.y])
                      .toList(),
                });
              }
            } finally {
              await service.close(id);
            }
          }
        }
        expect(reports.any((r) => (r['centers'] as List).isNotEmpty), isTrue);
        debugPrint('CRUX_REGION_CHECK=${jsonEncode(reports)}');
      });
    }
    testWidgets('실제 영상 위 관절 표시와 대상 선택 화면', (tester) async {
      final file = File(climbingPath);
      final source = MediaSource(
        path: file.path,
        name: 'climbing_sample.mp4',
        sizeBytes: await file.length(),
        type: MediaType.video,
      );
      final container = ProviderContainer(
        overrides: [
          mediaServiceProvider.overrideWithValue(_ClimbingMediaService(source)),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const CruxCamApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('select-media')));
        for (
          var i = 0;
          i < 100 && find.byKey(const Key('open-analysis')).evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.ensureVisible(find.byKey(const Key('open-analysis')));
        await tester.tap(find.byKey(const Key('open-analysis')));
        await tester.pumpAndSettle();
        // 실제 디코더의 초기화를 기다린 뒤 모델을 실행합니다.
        for (
          var i = 0;
          i < 100 && find.byKey(const Key('analysis-play')).evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.ensureVisible(find.byKey(const Key('run-analysis')));
        await tester.tap(find.byKey(const Key('run-analysis')));
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          final state = container.read(analysisControllerProvider);
          if (!state.busy) break;
        }
        final initial = container.read(analysisControllerProvider);
        expect(initial.error, isNull);
        expect(initial.result, isNotNull);
        await container
            .read(analysisControllerProvider.notifier)
            .analyze(
              MediaInfo(source: source, width: 720, height: 1280),
              PoseEngine.mediaPipeFull,
              5,
              region: PoseRegion(0, 0, .65, 1),
            );
        final state = container.read(analysisControllerProvider);
        expect(state.error, isNull);
        expect(
          state.result!.frames.any(
            (f) => f.personIds.whereType<int>().length >= 2,
          ),
          isTrue,
        );
        debugPrint(
          'CRUX_MULTIPLE_PEOPLE=${jsonEncode([
            for (final f in state.result!.frames)
              if (f.personIds.whereType<int>().length >= 2) {
                  'timeMs': f.timeMs,
                  'ids': f.personIds,
                  'centers': f.bodies.map((b) => [b.center.x, b.center.y]).toList(),
                },
          ])}',
        );
        final player = tester
            .widget<VideoPlayer>(find.byType(VideoPlayer).last)
            .controller;
        final result = state.result!;
        final anchor = result.frames.indexWhere(
          (f) => f.bodies.any((b) => b.usable),
        );
        final candidate = result.frames[anchor].bodies.indexWhere(
          (b) => b.usable,
        );
        await player.seekTo(
          Duration(milliseconds: result.frames[anchor].timeMs),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.text('사람 ${result.frames[anchor].personIdAt(candidate)}'),
        );
        await tester.tap(
          find.text('사람 ${result.frames[anchor].personIdAt(candidate)}'),
        );
        for (
          var i = 0;
          i < 300 && container.read(analysisControllerProvider).busy;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(
          container.read(analysisControllerProvider).result!.tracked,
          isNotEmpty,
        );
        final multiple = result.frames.indexWhere(
          (f) => f.personIds.whereType<int>().length >= 2,
        );
        await player.seekTo(
          Duration(milliseconds: result.frames[multiple].timeMs),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('pose-preview')));
        await tester.pumpAndSettle();
        final binding = IntegrationTestWidgetsFlutterBinding.instance;
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        await binding.takeScreenshot('phase2-overlay');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        container.dispose();
      }
    });
  }
}
