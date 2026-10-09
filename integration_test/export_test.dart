import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crux_cam/core/pose/pose_service.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:crux_cam/features/crop/models/crop_models.dart';
import 'package:crux_cam/features/export/application/export_controller.dart';
import 'package:crux_cam/features/export/models/export_models.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:crux_cam/features/crop/presentation/crop_screen.dart';
import 'package:crux_cam/features/export/presentation/export_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

import 'fixtures/export_fixture.dart';

Uint8List _rotate(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  void visit(int start, int end) {
    for (var offset = start; offset + 8 <= end;) {
      final size = data.getUint32(offset);
      if (size < 8 || offset + size > end) break;
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'moov' || type == 'trak') visit(offset + 8, offset + size);
      if (type == 'tkhd' && data.getUint32(offset + 84) > 0) {
        final values = [0, 65536, 0, -65536, 0, 0, 0, 0, 1073741824];
        for (var i = 0; i < values.length; i++) {
          data.setInt32(offset + 48 + i * 4, values[i]);
        }
      }
      offset += size;
    }
  }

  visit(0, bytes.length);
  return bytes;
}

CropTimeline _timeline(int w, int h, CropRatio ratio, List<CropRect> rects) =>
    CropTimeline(
      width: w,
      height: h,
      durationMs: 4000,
      personId: 1,
      engine: 'test',
      options: CropOptions(ratio: ratio),
      frames: [
        for (var i = 0; i < rects.length; i++)
          CropFrame(
            timeMs: i * 1000,
            rect: rects[i],
            status: CropStatus.following,
          ),
      ],
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final service = ExportService();
  final pose = NativePoseService();
  testWidgets('실제 크롭 화면의 진행률·저장·결과 화면 복귀와 접근성 트리', (tester) async {
    final old = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint('CRUX_EXPORT_UI_ERROR ${details.exception}\n${details.stack}');
      old?.call(details);
    };
    addTearDown(() => FlutterError.onError = old);
    final directory = await Directory.systemTemp.createTemp('crux_export_ui_');
    final file = File('${directory.path}/video.mp4');
    await file.writeAsBytes(base64Decode(exportFixtureBase64));
    final source = MediaSource(
      path: file.path,
      name: 'video.mp4',
      sizeBytes: await file.length(),
      type: MediaType.video,
    );
    final body = PoseBody(
      List.generate(
        33,
        (i) => PosePoint(.2 + (i % 3) * .1, .2 + (i % 4) * .1, 0, 1),
      ),
    );
    final analysis = AnalysisResult(
      session: PoseSession(
        id: 'export-ui',
        width: 320,
        height: 240,
        durationMs: 4000,
        storageDirectory: directory.path,
      ),
      engine: PoseEngine.mediaPipeFull,
      intervalMs: 1000,
      elapsedMs: 0,
      selectedPersonId: 1,
      frames: [
        for (var i = 0; i < 4; i++)
          PoseFrame(timeMs: i * 1000, bodies: [body], inferenceMs: 0),
      ],
      tracked: [
        for (var i = 0; i < 4; i++)
          TrackedFrame(
            timeMs: i * 1000,
            status: TrackStatus.tracked,
            raw: body,
            corrected: body,
          ),
      ],
    );
    try {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: CropScreen(
              info: MediaInfo(
                source: source,
                width: 320,
                height: 240,
                duration: const Duration(seconds: 4),
              ),
              analysis: analysis,
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 200 && find.byType(VideoPlayer).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('phase3-controller');
      expect(tester.takeException(), isNull, reason: '크롭 화면 진입');
      await tester.ensureVisible(find.byKey(const Key('crop-ratio')));
      await tester.tap(find.byKey(const Key('crop-ratio')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3:4').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '비율 메뉴 전환');
      await tester.ensureVisible(find.byKey(const Key('export-video')));
      await tester.tap(find.byKey(const Key('export-video')));
      for (var i = 0; i < 1200 && find.text('저장 완료').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('저장 완료'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '변환 완료');
      await tester.ensureVisible(find.byKey(const Key('preview-export')));
      await tester.tap(find.byKey(const Key('preview-export')));
      for (
        var i = 0;
        i < 200 && find.byType(VideoProgressIndicator).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '결과 재생 화면');
      Navigator.of(tester.element(find.byType(ExportPreview))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '크롭 화면 복귀');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
  testWidgets('실제 MP4 인코딩의 3:4·동적 크롭·회전·소리·재생·갤러리 저장', (tester) async {
    final directory = await Directory.systemTemp.createTemp('crux_export_');
    final input = File('${directory.path}/input.mp4');
    final rotated = File('${directory.path}/rotated.mp4');
    await input.writeAsBytes(base64Decode(exportFixtureBase64));
    await rotated.writeAsBytes(_rotate(base64Decode(exportFixtureBase64)));
    final tests = [
      (
        input,
        _timeline(320, 240, CropRatio.threeFour, [
          const CropRect(0, 0, .375, 2 / 3),
        ]),
        true,
        [0],
        [
          [255, 0, 0],
        ],
      ),
      (
        input,
        _timeline(320, 240, CropRatio.landscape, [
          // 16:9 영역으로 네 사분면을 차례로 이동합니다.
          const CropRect(0, 0, .5, .375), const CropRect(.5, 0, .5, .375),
          const CropRect(.5, .625, .5, .375), const CropRect(0, .625, .5, .375),
        ]),
        false,
        [0, 1000, 2000, 3000],
        [
          [255, 0, 0],
          [0, 255, 0],
          [255, 255, 0],
          [0, 0, 255],
        ],
      ),
      (
        rotated,
        _timeline(240, 320, CropRatio.threeFour, [
          const CropRect(.5, 0, .5, .5),
        ]),
        true,
        [0],
        [
          [255, 0, 0],
        ],
      ),
    ];
    try {
      var index = 0;
      for (final test in tests) {
        final controller = ExportController(service);
        try {
          await controller
              .start(test.$1.path, test.$2, ExportSettings(keepAudio: test.$3))
              .timeout(const Duration(minutes: 2));
          expect(
            controller.stage,
            ExportStage.completed,
            reason: controller.error,
          );
          final output = controller.output!;
          expect(output.path.endsWith('.mp4'), true);
          expect(
            output.width / output.height,
            closeTo(test.$2.outputAspect, .015),
          );
          expect(output.width * output.height, greaterThan(0));
          expect(output.sizeBytes, greaterThan(1000));
          expect(output.durationMs, closeTo(4000, 200));
          expect(output.hasAudio, test.$3);
          final player = VideoPlayerController.file(File(output.path));
          try {
            await player.initialize();
            expect(
              player.value.aspectRatio,
              closeTo(test.$2.outputAspect, .015),
            );
            await player.play();
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await player.pause();
            expect(player.value.position, greaterThan(Duration.zero));
          } finally {
            await player.dispose();
          }
          final id = 'export_preview_${index++}';
          try {
            await pose.open(
              id,
              MediaSource(
                path: output.path,
                name: 'result.mp4',
                sizeBytes: output.sizeBytes,
                type: MediaType.video,
              ),
              PoseEngine.mediaPipeLite,
            );
            for (var i = 0; i < test.$4.length; i++) {
              final frame = await pose.frame(id, test.$4[i], preview: true);
              final codec = await ui.instantiateImageCodec(frame.preview!);
              final image = (await codec.getNextFrame()).image;
              final rgba = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final pixel =
                  ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
              final actual = [
                for (var j = 0; j < 3; j++) rgba!.getUint8(pixel + j),
              ];
              for (var j = 0; j < 3; j++) {
                expect(
                  actual[j],
                  closeTo(test.$5[i][j], 35),
                  reason: '시각 ${test.$4[i]}ms의 실제 크롭 색상 $actual',
                );
              }
              image.dispose();
              codec.dispose();
            }
          } finally {
            await pose.close(id);
          }
          if (index == 1) {
            await controller.save();
            expect(
              controller.savedLocation,
              isNotNull,
              reason: controller.error,
            );
          }
          binding.reportData ??= {};
          binding.reportData!['export_$index'] = {
            'width': output.width,
            'height': output.height,
            'durationMs': output.durationMs,
            'hasAudio': output.hasAudio,
            'bytes': output.sizeBytes,
          };
        } finally {
          controller.dispose();
        }
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('준비 중 취소 후 다시 MP4를 만들 수 있다', (tester) async {
    final directory = await Directory.systemTemp.createTemp(
      'crux_export_cancel_',
    );
    final input = File('${directory.path}/input.mp4');
    await input.writeAsBytes(base64Decode(exportFixtureBase64));
    final timeline = _timeline(320, 240, CropRatio.square, [
      const CropRect(0, 0, .5, 2 / 3),
    ]);
    final controller = ExportController(service);
    try {
      final task = controller.start(
        input.path,
        timeline,
        const ExportSettings(),
      );
      await controller.cancel();
      await task;
      expect(controller.stage, ExportStage.cancelled);
      await controller
          .start(input.path, timeline, const ExportSettings())
          .timeout(const Duration(minutes: 2));
      expect(controller.stage, ExportStage.completed, reason: controller.error);
      expect(controller.output!.width, controller.output!.height);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
}
