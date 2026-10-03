import 'dart:io';

import 'package:crux_cam/app/app.dart';
import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/features/media/application/media_controller.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_media.dart';
import 'support/image_fixture.dart';

void main() {
  late FakeMediaService service;
  late FakeVideoPlatform platform;
  late Directory directory;
  late MediaSource photo;

  setUp(() async {
    service = FakeMediaService();
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    directory = await Directory.systemTemp.createTemp('crux_widget_');
    photo = await writeImageFixture(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaServiceProvider.overrideWithValue(service)],
        child: const CruxCamApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'initial screen selects video and displays controls and metadata',
    (tester) async {
      service.next = videoSource;
      await start(tester);
      expect(find.text('영상 / 사진 선택'), findsOneWidget);
      await tester.tap(find.byKey(const Key('select-media')));
      await tester.pumpAndSettle();
      expect(find.text('climb.mp4'), findsOneWidget);
      expect(find.text('1920 × 1080'), findsOneWidget);
      expect(find.text('01:42'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.byTooltip('재생'), findsOneWidget);
      final debugContainer = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('select-media'))),
      );
      expect(debugContainer.read(mediaControllerProvider).error, isNull);
      expect(debugContainer.read(mediaControllerProvider).isLoading, isFalse);
      await tester.ensureVisible(find.byKey(const Key('toggle-playback')));
      await tester.tap(find.byKey(const Key('toggle-playback')));
      await tester.pump();
      expect(find.byTooltip('일시정지'), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-playback')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('재생'), findsOneWidget);
      expect(find.text('분석 시작 · 준비 중'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposed, [1]);
    },
  );

  testWidgets(
    'photo preview, cancellation, and narrow screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      service.next = photo;
      await start(tester);
      await tester.ensureVisible(find.byKey(const Key('select-media')));
      await tester.tap(find.byKey(const Key('select-media')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('toggle-playback')), findsNothing);
      service.next = null;
      await tester.ensureVisible(find.byKey(const Key('select-media')));
      await tester.tap(find.byKey(const Key('select-media')));
      await tester.pumpAndSettle();
      expect(find.text(photo.name), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'covered route pauses video; removing media screen releases player',
    (tester) async {
      service.next = videoSource;
      await start(tester);
      await tester.tap(find.byKey(const Key('select-media')));
      await tester.pumpAndSettle();
      final context = tester.element(find.byKey(const Key('select-media')));
      final container = ProviderScope.containerOf(context);
      final controller = container.read(mediaControllerProvider.notifier);
      await controller.togglePlayback();
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Next screen')),
      );
      Navigator.of(context).push(route);
      await tester.pumpAndSettle();
      expect(platform.playing, isEmpty);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(platform.playing, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposed, [1]);
    },
  );
}
