import 'dart:convert';
import 'dart:io';

import 'package:crux_cam/app/app.dart';
import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/features/media/application/media_controller.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/image_fixture.dart';
import 'fixtures/video_fixture.dart';

/// 선택할 파일만 테스트에서 정해 줍니다. 파일 정보 읽기, 영상 표시·재생·해제는
/// 실제 앱 서비스와 기기의 영상 플레이어를 사용하여 검사합니다.
class _FixtureService extends LocalMediaService {
  _FixtureService(this.paths);
  final List<String?> paths;
  int _index = 0;

  @override
  Future<MediaSource?> pickMedia() async {
    final path = paths[_index++];
    return path == null ? null : describeFile(XFile(path));
  }

  @override
  Future<MediaSource?> recoverLostMedia() async => null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native video playback, replacement, cancellation and image preview',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('crux_native_');
      final first = File('${directory.path}/first.mp4');
      final second = File('${directory.path}/second.mp4');
      final bytes = base64Decode(videoFixtureBase64);
      await first.writeAsBytes(bytes);
      await second.writeAsBytes(bytes);
      final image = await writeImageFixture(directory);
      final service = _FixtureService([
        first.path,
        null,
        second.path,
        image.path,
      ]);
      final container = ProviderContainer(
        overrides: [mediaServiceProvider.overrideWithValue(service)],
      );
      final app = UncontrolledProviderScope(
        container: container,
        child: const CruxCamApp(),
      );
      try {
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();

        Future<void> select() async {
          await tester.ensureVisible(find.byKey(const Key('select-media')));
          await tester.tap(find.byKey(const Key('select-media')));
          // 기기의 영상 준비가 끝날 때까지 화면을 갱신하며 기다립니다.
          for (var i = 0; i < 160; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (!container.read(mediaControllerProvider).isLoading) break;
          }
          final state = container.read(mediaControllerProvider);
          expect(state.isLoading, isFalse);
          expect(state.error, isNull);
        }

        await select();
        final player = container.read(mediaControllerProvider).videoController!;
        expect(player.value.size, const Size(96, 64));
        expect(player.value.duration.inSeconds, 2);
        await tester.ensureVisible(find.byKey(const Key('toggle-playback')));
        await tester.tap(find.byKey(const Key('toggle-playback')));
        await tester.pump(const Duration(milliseconds: 600));
        expect(player.value.isPlaying, isTrue);
        expect(player.value.position, greaterThan(Duration.zero));
        await tester.tap(find.byKey(const Key('toggle-playback')));
        await tester.pump();
        expect(player.value.isPlaying, isFalse);

        await select(); // 선택을 취소해도 기존 플레이어가 유지되는지 확인합니다.
        expect(
          container.read(mediaControllerProvider).videoController,
          same(player),
        );
        await select();
        expect(
          container.read(mediaControllerProvider).info!.source.name,
          'second.mp4',
        );
        expect(
          container.read(mediaControllerProvider).videoController,
          isNot(same(player)),
        );
        await select();
        expect(container.read(mediaControllerProvider).videoController, isNull);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('128 × 96'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        container.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
