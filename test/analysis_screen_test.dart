import 'dart:io';

import 'package:crux_cam/app/app.dart';
import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/core/pose/pose_service.dart';
import 'package:crux_cam/features/analysis/application/analysis_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_media.dart';
import 'support/fake_pose.dart';

void main() {
  testWidgets('설정을 스크롤해도 영상과 사람 선택이 함께 보이고 대상 변경·화면 종료가 정상 동작한다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('crux_analysis_ui_'),
    ))!;
    final media = FakeMediaService()..next = videoSource;
    final pose = FakePoseService(directory: directory.path);
    final platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final container = ProviderContainer(
      overrides: [
        mediaServiceProvider.overrideWithValue(media),
        poseServiceProvider.overrideWithValue(pose),
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
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('open-analysis')));
      await tester.tap(find.byKey(const Key('open-analysis')));
      await tester.pumpAndSettle();
      expect(find.text('클라이머 분석'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('run-analysis')));
      await tester.tap(find.byKey(const Key('run-analysis')));
      await tester.pump();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && container.read(analysisControllerProvider).busy;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(
        container.read(analysisControllerProvider).result!.frames,
        hasLength(5),
      );
      expect(find.text('사람 1').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('pose-preview')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('사람 1'));
      await tester.tap(find.text('사람 1'));
      await tester.pump();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && container.read(analysisControllerProvider).busy;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('대상 추적 중'), findsOneWidget);
      expect(find.byKey(const Key('save-analysis')), findsOneWidget);
      final previewBeforeScroll = tester.getRect(
        find.byKey(const Key('pose-preview')),
      );
      await tester.ensureVisible(find.byKey(const Key('save-analysis')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('pose-preview'))),
        previewBeforeScroll,
      );
      expect(find.text('사람 1').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('analysis-play')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('analysis-seek')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('add-person-region')));
      await tester.tap(find.byKey(const Key('add-person-region')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('pose-preview')));
      final preview = tester.getRect(find.byKey(const Key('pose-preview')));
      final gesture = await tester.startGesture(
        preview.topLeft + Offset(preview.width * .5, preview.height * .05),
      );
      await gesture.moveBy(Offset(preview.width * .08, preview.height * .08));
      await gesture.moveBy(Offset(preview.width * .37, preview.height * .82));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('confirm-person-region')),
      );
      await tester.tap(find.byKey(const Key('confirm-person-region')));
      await tester.pump();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && container.read(analysisControllerProvider).busy;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(pose.region, isNotNull);
      expect(find.text('사람 1'), findsOneWidget);
      expect(find.text('사람 2'), findsOneWidget);
      expect(
        tester.getRect(find.text('사람 1')).left,
        lessThan(tester.getRect(find.text('사람 2')).left),
      );
      await tester.ensureVisible(find.text('사람 2'));
      await tester.tap(find.text('사람 2'));
      await tester.pump();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && container.read(analysisControllerProvider).busy;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(
        container.read(analysisControllerProvider).result!.selectedPersonId,
        2,
      );
      // 낮은 세로 화면과 가로 화면에서도 선택 버튼이 영상과 함께 보이는지 확인합니다.
      for (final size in [const Size(390, 600), const Size(844, 390)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(find.text('사람 1').hitTestable(), findsOneWidget);
        expect(find.text('사람 2').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const Key('pose-preview')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('analysis-play')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('analysis-seek')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      Navigator.of(tester.element(find.text('클라이머 분석'))).pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposed, contains(2));
      expect(platform.disposed, isNot(contains(1)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      container.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
