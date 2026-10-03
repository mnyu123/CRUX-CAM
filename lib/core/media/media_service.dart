import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:video_player/video_player.dart';

import '../../features/media/models/media_info.dart';

final mediaServiceProvider = Provider<MediaService>(
  (ref) => LocalMediaService(),
);

class MediaException implements Exception {
  const MediaException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract class MediaService {
  Future<MediaSource?> pickMedia();
  Future<MediaSource?> recoverLostMedia();
  Future<ui.Size> readImageSize(MediaSource source);
  VideoPlayerController createVideoController(MediaSource source);
}

class LocalMediaService implements MediaService {
  LocalMediaService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<MediaSource?> pickMedia() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const MediaException('미디어 미리보기는 Android와 iOS에서 지원합니다.');
    }
    // 사용자가 선택한 파일만 읽으면 되므로 추가 사진 정보는 요청하지 않습니다.
    // 나중에 분석할 원본의 화질을 유지하도록 선택 단계에서 축소·압축하지 않습니다.
    final file = await _picker.pickMedia(requestFullMetadata: false);
    return file == null ? null : describeFile(file);
  }

  @override
  Future<MediaSource?> recoverLostMedia() async {
    if (!Platform.isAndroid) return null;
    final result = await _picker.retrieveLostData();
    // Android가 파일 선택 도중 앱을 종료했다면, 재시작 시 선택 결과를 복구합니다.
    if (result.exception != null) throw result.exception!;
    final files = result.files;
    if (files == null || files.isEmpty) return null;
    return describeFile(files.first);
  }

  /// 파일의 앞부분과 확장자로 동영상인지 사진인지 판단합니다.
  /// 큰 영상을 통째로 메모리에 읽지 않고 최대 64바이트만 확인합니다.
  Future<MediaSource> describeFile(XFile file) async {
    final size = await file.length();
    if (size <= 0) throw const MediaException('비어 있는 파일입니다. 다른 파일을 선택해주세요.');
    final header = await file
        .openRead(0, size < 64 ? size : 64)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    final mime =
        lookupMimeType(file.name, headerBytes: header) ?? file.mimeType;
    final type = switch (mime) {
      final String value when value.startsWith('video/') => MediaType.video,
      final String value when value.startsWith('image/') => MediaType.image,
      _ => throw const MediaException('지원하는 동영상 또는 사진 파일을 선택해주세요.'),
    };
    return MediaSource(
      path: file.path,
      name: file.name,
      sizeBytes: size,
      type: type,
    );
  }

  @override
  Future<ui.Size> readImageSize(MediaSource source) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
    ui.ImageDescriptor? descriptor;
    try {
      // 해상도만 확인하므로 큰 사진을 전체 크기로 화면에 펼칠 필요가 없습니다.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  @override
  VideoPlayerController createVideoController(MediaSource source) {
    return VideoPlayerController.file(
      File(source.path),
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
    );
  }
}
