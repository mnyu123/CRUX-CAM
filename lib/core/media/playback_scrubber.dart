import 'package:video_player/video_player.dart';

/// 재생 바를 연속으로 누르거나 끌 때 탐색 요청이 한꺼번에 쌓이지 않게 정리합니다.
///
/// 재생 중에 탐색 요청이 짧은 간격으로 여러 번 겹치면 재생기가 소리 버퍼를
/// 계속 비웠다가 다시 채우면서 소리가 끊기거나 깨질 수 있습니다.
/// 그래서 다음 두 가지를 처리합니다.
/// 1. 조작을 시작하면 잠시 멈추고, 조작이 끝나면 원래 재생 중이었을 때만 다시 재생합니다.
/// 2. 탐색은 한 번에 하나만 보내고, 기다리는 동안 들어온 요청은 마지막 위치만 남깁니다.
///
/// video_player 패키지에 같은 이름의 VideoScrubber 위젯이 있어 이름이 겹치지 않게 했습니다.
class PlaybackScrubber {
  // 비공개 필드도 호출하는 쪽에서는 isPlaying:, pause: 처럼 밑줄 없는 이름으로 넘깁니다.
  PlaybackScrubber({
    required this._isPlaying,
    required this._pause,
    required this._play,
    required this._seekTo,
  });

  // 재생기마다 하나의 정리 객체를 함께 쓰도록 재생기에 붙여 둡니다.
  // 재생기가 해제되어 사라지면 이 객체도 함께 정리됩니다.
  static final Expando<PlaybackScrubber> _byPlayer = Expando(
    'PlaybackScrubber',
  );

  /// 같은 재생기에는 항상 같은 정리 객체를 돌려줍니다.
  static PlaybackScrubber of(VideoPlayerController player) =>
      _byPlayer[player] ??= PlaybackScrubber(
        isPlaying: () => player.value.isPlaying,
        pause: player.pause,
        play: player.play,
        seekTo: player.seekTo,
      );

  final bool Function() _isPlaying;
  final Future<void> Function() _pause;
  final Future<void> Function() _play;
  final Future<void> Function(Duration position) _seekTo;

  Duration? _pending;
  Future<void>? _running;
  bool _scrubbing = false;
  bool _resumeAfter = false;

  /// 지금 재생 바를 조작하는 중인지 알려줍니다.
  bool get scrubbing => _scrubbing;

  /// 재생 바 조작 시작. 재생 중이었다면 멈추고 끝난 뒤 다시 재생할 수 있게 기억합니다.
  Future<void> start() async {
    if (_scrubbing) return;
    _scrubbing = true;
    if (_isPlaying()) {
      _resumeAfter = true;
      await _pause();
    }
  }

  /// 탐색 요청. 이미 탐색 중이면 마지막 위치만 보관했다가 이어서 한 번만 보냅니다.
  /// 반환된 Future는 가장 마지막으로 요청한 위치의 탐색이 끝나면 완료됩니다.
  Future<void> seek(Duration position) {
    _pending = position;
    return _running ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_pending != null) {
        final next = _pending!;
        _pending = null;
        await _seekTo(next);
      }
    } catch (_) {
      // 실패한 뒤 오래된 위치로 다시 이동하지 않도록 남은 요청을 버립니다.
      _pending = null;
      rethrow;
    } finally {
      _running = null;
    }
  }

  /// 재생 바 조작 끝. 마지막 탐색을 마친 뒤, 조작 전에 재생 중이었다면 다시 재생합니다.
  /// [canResume]이 false이면(화면이 가려졌거나 앱이 백그라운드인 경우) 다시 재생하지 않습니다.
  Future<void> end({bool Function()? canResume}) async {
    if (!_scrubbing) return;
    _scrubbing = false;
    try {
      await _running;
    } catch (_) {
      // 탐색 실패 안내는 seek를 호출한 화면에서 이미 처리합니다.
    }
    // 기다리는 사이 새 조작이 시작됐다면 그 조작이 끝날 때 다시 재생합니다.
    if (_scrubbing) return;
    final resume = _resumeAfter;
    _resumeAfter = false;
    if (resume && (canResume?.call() ?? true)) await _play();
  }
}
