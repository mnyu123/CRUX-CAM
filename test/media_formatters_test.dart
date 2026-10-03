import 'package:crux_cam/features/media/presentation/media_formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('duration supports short and hour-long videos', () {
    expect(formatDuration(Duration.zero), '00:00');
    expect(formatDuration(const Duration(seconds: 102)), '01:42');
    expect(
      formatDuration(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '02:03:04',
    );
  });
  test('file sizes cover bytes through 4K-sized video files', () {
    expect(formatFileSize(0), '0 B');
    expect(formatFileSize(1024), '1.0 KB');
    expect(formatFileSize(542 * 1024 * 1024), '542.0 MB');
    expect(formatFileSize(5 * 1024 * 1024 * 1024), '5.0 GB');
  });
}
