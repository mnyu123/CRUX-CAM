import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/media/media_service.dart';
import '../../../core/media/playback_scrubber.dart';
import '../models/media_info.dart';

final mediaControllerProvider =
    NotifierProvider.autoDispose<MediaController, MediaState>(
      MediaController.new,
    );

class MediaState {
  const MediaState({
    this.info,
    this.videoController,
    this.isLoading = false,
    this.error,
  });

  final MediaInfo? info;
  final VideoPlayerController? videoController;
  final bool isLoading;
  final String? error;
}

class MediaController extends Notifier<MediaState> {
  final Set<VideoPlayerController> _ownedPlayers = {};
  bool _recoveryAttempted = false;
  bool _playbackBusy = false;
  bool _foreground = true;
  int _generation = 0;

  @override
  MediaState build() {
    // 이 화면이 소유한 플레이어를 추적하여 준비 도중 종료해도 빠짐없이 해제합니다.
    ref.onDispose(() {
      _generation++;
      for (final player in _ownedPlayers.toList()) {
        unawaited(_release(player));
      }
    });
    return const MediaState();
  }

  Future<void> recoverLostMedia() async {
    if (_recoveryAttempted || state.isLoading) return;
    _recoveryAttempted = true;
    await _select(recover: true);
  }

  Future<void> selectMedia() => _select(recover: false);

  Future<void> _select({required bool recover}) async {
    if (state.isLoading) return;
    final service = ref.read(mediaServiceProvider);
    final previous = state;
    final generation = ++_generation;
    // 선택을 기다리는 사이 화면이 종료되면, 늦게 도착한 결과로 상태를 바꾸지 않습니다.
    bool active() => ref.mounted && generation == _generation;
    state = MediaState(
      info: previous.info,
      videoController: previous.videoController,
      isLoading: true,
    );
    VideoPlayerController? candidate;
    try {
      await _pause(previous.videoController);
      if (!active()) return;
      final source = recover
          ? await service.recoverLostMedia()
          : await service.pickMedia();
      if (!active()) return;
      if (source == null) {
        // 선택 화면에서 취소한 경우에는 기존 파일과 미리보기를 그대로 유지합니다.
        state = MediaState(
          info: previous.info,
          videoController: previous.videoController,
          error: state.error ?? previous.error,
        );
        return;
      }

      late final MediaInfo info;
      if (source.type == MediaType.video) {
        candidate = service.createVideoController(source);
        _ownedPlayers.add(candidate);
        await candidate.initialize().timeout(const Duration(seconds: 30));
        if (!active()) return;
        final value = candidate.value;
        if (value.hasError ||
            value.size.width <= 0 ||
            value.size.height <= 0 ||
            value.duration <= Duration.zero) {
          throw const MediaException('영상 정보를 읽을 수 없습니다. 다른 영상을 선택해주세요.');
        }
        info = MediaInfo(
          source: source,
          width: value.size.width.round(),
          height: value.size.height.round(),
          duration: value.duration,
        );
      } else {
        final size = await service.readImageSize(source);
        if (!active()) return;
        if (size.width <= 0 || size.height <= 0) {
          throw const MediaException('사진 정보를 읽을 수 없습니다.');
        }
        info = MediaInfo(
          source: source,
          width: size.width.round(),
          height: size.height.round(),
        );
      }

      candidate?.addListener(_onVideoChanged);
      // 새 파일 준비가 성공한 뒤 교체해야 실패해도 기존 영상을 다시 볼 수 있습니다.
      state = MediaState(info: info, videoController: candidate);
      candidate = null; // 새 플레이어를 현재 화면에 넘겼으므로 실패 정리 대상에서 제외합니다.
      if (previous.videoController != null) {
        await _release(previous.videoController!);
      }
    } catch (error) {
      if (active()) {
        state = MediaState(
          info: previous.info,
          videoController: previous.videoController,
          error: _errorMessage(error),
        );
      }
    } finally {
      if (candidate != null) await _release(candidate);
    }
  }

  void _onVideoChanged() {
    if (!ref.mounted) return;
    final player = state.videoController;
    if (player != null && player.value.hasError && state.error == null) {
      state = MediaState(
        info: state.info,
        videoController: player,
        isLoading: state.isLoading,
        error: '이 영상을 재생할 수 없습니다. 다른 파일을 선택해주세요.',
      );
    }
  }

  Future<void> togglePlayback() async {
    final player = state.videoController;
    if (state.isLoading ||
        player == null ||
        player.value.hasError ||
        !player.value.isInitialized ||
        _playbackBusy ||
        !_foreground) {
      return;
    }
    _playbackBusy = true;
    try {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        if (player.value.position >= player.value.duration) {
          await player.seekTo(Duration.zero);
        }
        if (!ref.mounted ||
            state.isLoading ||
            state.videoController != player ||
            !_foreground) {
          return;
        }
        await player.play();
        // 재생 요청을 기다리는 동안 앱이 가려졌거나 파일이 바뀌었다면 다시 멈춥니다.
        if (!ref.mounted ||
            state.isLoading ||
            state.videoController != player ||
            !_foreground) {
          await _pause(player);
        }
      }
    } catch (error) {
      if (ref.mounted && state.videoController == player) {
        state = MediaState(
          info: state.info,
          videoController: player,
          isLoading: state.isLoading,
          error: _errorMessage(error),
        );
      }
    } finally {
      _playbackBusy = false;
    }
  }

  Future<void> seekTo(Duration position) async {
    final player = state.videoController;
    if (state.isLoading ||
        player == null ||
        player.value.hasError ||
        !player.value.isInitialized) {
      return;
    }
    try {
      // 연속 탐색이 겹치면 소리가 깨질 수 있어 마지막 위치만 차례로 보냅니다.
      await PlaybackScrubber.of(player).seek(position);
    } catch (error) {
      if (ref.mounted && state.videoController == player) {
        state = MediaState(
          info: state.info,
          videoController: player,
          isLoading: state.isLoading,
          error: _errorMessage(error),
        );
      }
    }
  }

  /// 재생 바 조작 시작. 재생 중이었다면 조작하는 동안 잠시 멈춥니다.
  Future<void> beginScrub() async {
    final player = state.videoController;
    if (state.isLoading ||
        player == null ||
        player.value.hasError ||
        !player.value.isInitialized) {
      return;
    }
    try {
      await PlaybackScrubber.of(player).start();
    } catch (_) {
      // 멈추지 못해도 탐색 자체는 계속할 수 있습니다.
    }
  }

  /// 재생 바 조작 끝. 화면이 보이고 같은 파일일 때만 원래대로 다시 재생합니다.
  Future<void> endScrub() async {
    final player = state.videoController;
    if (player == null) return;
    try {
      await PlaybackScrubber.of(player).end(
        canResume: () =>
            ref.mounted &&
            !state.isLoading &&
            state.videoController == player &&
            _foreground,
      );
    } catch (error) {
      if (ref.mounted && state.videoController == player) {
        state = MediaState(
          info: state.info,
          videoController: player,
          isLoading: state.isLoading,
          error: _errorMessage(error),
        );
      }
    }
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) unawaited(_pause(state.videoController));
  }

  Future<void> _pause(VideoPlayerController? player) async {
    if (player == null || !player.value.isInitialized) return;
    try {
      await player.pause();
    } catch (_) {
      // 화면 종료와 일시정지가 겹치면 플레이어가 이미 해제 중일 수 있습니다.
    }
  }

  Future<void> _release(VideoPlayerController player) async {
    if (!_ownedPlayers.remove(player)) return;
    player.removeListener(_onVideoChanged);
    try {
      await player.dispose();
    } catch (error) {
      // 해제 오류 때문에 파일 선택·재생 실패의 원래 안내가 바뀌지 않게 합니다.
      debugPrint('Video player cleanup failed: $error');
    }
  }

  String _errorMessage(Object error) {
    if (error is MediaException) return error.message;
    if (error is PlatformException) {
      if (error.code.contains('access_denied') ||
          error.code.contains('permission')) {
        return '미디어 접근이 허용되지 않았습니다. 기기 설정에서 사진 접근 권한을 확인해주세요.';
      }
      return '미디어를 열 수 없습니다. 다른 파일을 선택해주세요.';
    }
    if (error is TimeoutException) return '영상 준비 시간이 초과되었습니다. 다시 선택해주세요.';
    if (error is FileSystemException) return '파일에 접근할 수 없습니다. 파일을 다시 선택해주세요.';
    return '파일을 읽을 수 없습니다. 지원하는 동영상 또는 사진을 선택해주세요.';
  }
}
