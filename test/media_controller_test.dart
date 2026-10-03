import 'dart:async';

import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/features/media/application/media_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeMediaService service;
  late FakeVideoPlatform platform;
  late ProviderContainer container;
  late MediaController controller;

  setUp(() {
    service = FakeMediaService();
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    container = ProviderContainer(
      overrides: [mediaServiceProvider.overrideWithValue(service)],
    );
    container.listen(mediaControllerProvider, (_, _) {});
    controller = container.read(mediaControllerProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('video metadata, playback, seek and background pause', () async {
    service.next = videoSource;
    await controller.selectMedia();
    final state = container.read(mediaControllerProvider);
    expect(state.info!.width, 1920);
    expect(state.info!.height, 1080);
    expect(state.info!.duration, const Duration(seconds: 102));
    await controller.togglePlayback();
    expect(state.videoController!.value.isPlaying, isTrue);
    await controller.seekTo(const Duration(seconds: 10));
    expect(state.videoController!.value.position, const Duration(seconds: 10));
    controller.setForeground(false);
    await Future<void>.delayed(Duration.zero);
    expect(state.videoController!.value.isPlaying, isFalse);
    await controller.togglePlayback();
    expect(platform.playing, isEmpty);
    controller.setForeground(true);
    await controller.seekTo(state.info!.duration!);
    await controller.togglePlayback();
    expect(state.videoController!.value.position, Duration.zero);
    await controller.togglePlayback();
  });

  test(
    'replacement releases each old player and image has no video resource',
    () async {
      service.next = videoSource;
      for (var i = 0; i < 4; i++) {
        await controller.selectMedia();
      }
      expect(platform.disposed, [1, 2, 3]);
      service.next = imageSource;
      await controller.selectMedia();
      final state = container.read(mediaControllerProvider);
      expect(state.info!.width, 1080);
      expect(state.info!.duration, isNull);
      expect(state.videoController, isNull);
      expect(platform.disposed, [1, 2, 3, 4]);
    },
  );

  test(
    'cancel preserves old selection; decode failure releases candidate only',
    () async {
      service.next = videoSource;
      await controller.selectMedia();
      final old = container.read(mediaControllerProvider).videoController;
      service.next = null;
      await controller.selectMedia();
      expect(
        container.read(mediaControllerProvider).videoController,
        same(old),
      );
      expect(platform.disposed, isEmpty);
      service.next = videoSource;
      platform.failNext = true;
      await controller.selectMedia();
      expect(container.read(mediaControllerProvider).error, isNotNull);
      expect(
        container.read(mediaControllerProvider).videoController,
        same(old),
      );
      expect(platform.disposed, [2]);
      await controller.togglePlayback();
      expect(old!.value.isPlaying, isTrue);
      await controller.togglePlayback();
      await controller.selectMedia();
      expect(container.read(mediaControllerProvider).error, isNull);
      expect(platform.disposed, [2, 1]);
    },
  );

  test('permission rejection is visible and next selection recovers', () async {
    service.error = PlatformException(code: 'photo_access_denied');
    await controller.selectMedia();
    expect(container.read(mediaControllerProvider).error, contains('권한'));
    expect(container.read(mediaControllerProvider).isLoading, isFalse);
    service.error = null;
    service.next = imageSource;
    await controller.selectMedia();
    expect(container.read(mediaControllerProvider).error, isNull);
  });

  test(
    'picker cannot overlap; late result after disposal creates no player',
    () async {
      service.selection = Completer();
      final pending = controller.selectMedia();
      await Future<void>.delayed(Duration.zero);
      await controller.selectMedia();
      expect(service.pickCount, 1);
      container.dispose();
      service.selection!.complete(videoSource);
      await pending;
      expect(service.playersCreated, 0);
    },
  );

  test('lost picker result is restored once', () async {
    service.recovered = videoSource;
    await controller.recoverLostMedia();
    await controller.recoverLostMedia();
    expect(service.recoveryCount, 1);
    expect(container.read(mediaControllerProvider).info!.source, videoSource);
  });

  test('provider teardown disposes active player exactly once', () async {
    service.next = videoSource;
    await controller.selectMedia();
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposed, [1]);
  });

  testWidgets(
    'teardown during initialization releases native player and ignores timeout',
    (tester) async {
      service.next = videoSource;
      platform.initializeAutomatically = false;
      final pending = controller.selectMedia();
      await tester.pump();
      expect(service.playersCreated, 1);
      container.dispose();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposed, [1]);
      await tester.pump(const Duration(seconds: 31));
      await pending;
      expect(platform.disposed, [1]);
    },
  );
}
