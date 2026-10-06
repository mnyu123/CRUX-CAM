import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  // 기기에서 테스트 앱이 제거되기 전에 화면 캡처를 PC의 빌드 폴더로 가져옵니다.
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final directory = Directory('build/phase2-screenshots');
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
