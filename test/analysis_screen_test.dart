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
  testWidgets('미디어에서 분석으로 이동하고 대상을 선택하며 화면 종료 시 재생기를 해제한다', (tester) async {
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
      await tester.pumpAndSettle();
      expect(
        container.read(analysisControllerProvider).result!.frames,
        hasLength(5),
      );
      await tester.ensureVisible(find.text('사람 1'));
      await tester.tap(find.text('사람 1'));
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
