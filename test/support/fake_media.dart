import 'dart:async';

import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const videoSource = MediaSource(
  path: '/cache/climb.mp4',
  name: 'climb.mp4',
  sizeBytes: 2097152,
  type: MediaType.video,
);
const imageSource = MediaSource(
  path: '/cache/climb.png',
  name: 'climb.png',
  sizeBytes: 1024,
  type: MediaType.image,
);

class FakeMediaService implements MediaService {
  MediaSource? next;
  MediaSource? recovered;
  Object? error;
  Completer<MediaSource?>? selection;
  int pickCount = 0;
  int recoveryCount = 0;
  int playersCreated = 0;

  @override
  Future<MediaSource?> pickMedia() async {
    pickCount++;
    if (error != null) throw error!;
    return selection == null ? next : selection!.future;
  }

  @override
  Future<MediaSource?> recoverLostMedia() async {
    recoveryCount++;
    return recovered;
  }

  @override
  Future<Size> readImageSize(MediaSource source) async =>
      const Size(1080, 1920);

  @override
  VideoPlayerController createVideoController(MediaSource source) {
    playersCreated++;
    return VideoPlayerController.networkUrl(
      Uri.parse('https://test.invalid/${source.name}'),
    );
  }
}

/// 기기 대신 정해진 응답을 보내어 실제 VideoPlayerController의 동작을 검사합니다.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> events = {};
  final List<int> disposed = [];
  final Set<int> playing = {};
  final Map<int, Duration> positions = {};
  bool failNext = false;
  bool initializeAutomatically = true;
  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = ++_nextId;
    final stream = StreamController<VideoEvent>();
    events[id] = stream;
    if (failNext) {
      failNext = false;
      stream.addError(
        PlatformException(code: 'VideoError', message: 'Invalid video'),
      );
    } else if (initializeAutomatically) {
      initializePlayer(id);
    }
    return id;
  }

  void initializePlayer(int id) => events[id]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 102),
      size: const Size(1920, 1080),
    ),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    playing.remove(playerId);
    await events[playerId]!.close();
  }

  @override
  Future<void> play(int playerId) async => playing.add(playerId);
  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      positions[playerId] = position;
  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black);
}
