enum MediaType { video, image }

/// 시스템 선택 화면이 반환한 파일 정보를 앱에서 쓰기 쉽게 정리한 모델입니다.
/// [path]는 앱이 읽을 수 있는 경로이며, 갤러리 원본 대신 임시 복사본일 수 있습니다.
class MediaSource {
  const MediaSource({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.type,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final MediaType type;
}

/// 해상도와 재생시간 같은 파일 정보만 보관합니다.
/// 영상 플레이어는 별도로 생성·해제해야 하므로 MediaController에서 관리합니다.
class MediaInfo {
  const MediaInfo({
    required this.source,
    required this.width,
    required this.height,
    this.duration,
  });

  final MediaSource source;
  final int width;
  final int height;
  final Duration? duration;
}
