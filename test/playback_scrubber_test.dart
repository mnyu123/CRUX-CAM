import 'dart:async';

import 'package:crux_cam/core/media/playback_scrubber.dart';
import 'package:flutter_test/flutter_test.dart';

/// 실제 재생기 대신 호출 순서와 탐색 위치만 기록하는 가짜 재생기입니다.
class _FakePlayer {
  bool playing = false;
  final log = <String>[];
  final seeks = <Duration>[];
  Completer<void>? pendingSeek;
  bool failSeek = false;

  late final scrubber = PlaybackScrubber(
    isPlaying: () => playing,
    pause: () async {
      playing = false;
      log.add('pause');
    },
    play: () async {
      playing = true;
      log.add('play');
    },
    seekTo: (position) async {
      seeks.add(position);
      log.add('seek ${position.inMilliseconds}');
      final wait = pendingSeek;
      if (wait != null) await wait.future;
      if (failSeek) throw StateError('seek failed');
    },
  );
}

void main() {
  test('탐색 중에 들어온 여러 요청은 마지막 위치 하나만 이어서 보낸다', () async {
    final player = _FakePlayer()..pendingSeek = Completer<void>();
    final first = player.scrubber.seek(const Duration(seconds: 1));
    final second = player.scrubber.seek(const Duration(seconds: 2));
    final third = player.scrubber.seek(const Duration(seconds: 3));
    final last = player.scrubber.seek(const Duration(seconds: 4));
    expect(player.seeks, [const Duration(seconds: 1)]);
    player.pendingSeek!.complete();
    player.pendingSeek = null;
    await Future.wait([first, second, third, last]);
    // 2초·3초 요청은 건너뛰고 첫 요청 뒤에 마지막 4초만 보냅니다.
    expect(player.seeks, [
      const Duration(seconds: 1),
      const Duration(seconds: 4),
    ]);
  });

  test('재생 중에 재생 바를 조작하면 멈췄다가 끝난 뒤 다시 재생한다', () async {
    final player = _FakePlayer()..playing = true;
    await player.scrubber.start();
    expect(player.playing, isFalse);
    await player.scrubber.seek(const Duration(seconds: 5));
    await player.scrubber.seek(const Duration(seconds: 6));
    await player.scrubber.end();
    expect(player.log, ['pause', 'seek 5000', 'seek 6000', 'play']);
    expect(player.playing, isTrue);
  });

  test('멈춘 상태에서 조작하면 끝난 뒤에도 재생하지 않는다', () async {
    final player = _FakePlayer();
    await player.scrubber.start();
    await player.scrubber.seek(const Duration(seconds: 2));
    await player.scrubber.end();
    expect(player.log, ['seek 2000']);
    expect(player.playing, isFalse);
  });

  test('화면이 가려져 다시 재생할 수 없으면 재생하지 않는다', () async {
    final player = _FakePlayer()..playing = true;
    await player.scrubber.start();
    await player.scrubber.seek(const Duration(seconds: 2));
    await player.scrubber.end(canResume: () => false);
    expect(player.playing, isFalse);
    // 다음 조작에 이전 재생 기억이 남지 않아야 합니다.
    await player.scrubber.start();
    await player.scrubber.end();
    expect(player.playing, isFalse);
  });

  test('마지막 탐색이 끝난 뒤에 재생을 다시 시작한다', () async {
    final player = _FakePlayer()
      ..playing = true
      ..pendingSeek = Completer<void>();
    await player.scrubber.start();
    unawaited(player.scrubber.seek(const Duration(seconds: 3)));
    final ended = player.scrubber.end();
    await Future<void>.delayed(Duration.zero);
    expect(player.log, ['pause', 'seek 3000']);
    player.pendingSeek!.complete();
    await ended;
    expect(player.log, ['pause', 'seek 3000', 'play']);
  });

  test('탐색이 실패하면 남은 요청을 버리고 다음 요청은 정상 처리한다', () async {
    final player = _FakePlayer()
      ..failSeek = true
      ..pendingSeek = Completer<void>();
    final first = player.scrubber.seek(const Duration(seconds: 1));
    final stale = player.scrubber.seek(const Duration(seconds: 2));
    player.pendingSeek!.complete();
    player.pendingSeek = null;
    await expectLater(first, throwsStateError);
    await expectLater(stale, throwsStateError);
    expect(player.seeks, [const Duration(seconds: 1)]);
    player.failSeek = false;
    await player.scrubber.seek(const Duration(seconds: 7));
    expect(player.seeks.last, const Duration(seconds: 7));
  });
}
