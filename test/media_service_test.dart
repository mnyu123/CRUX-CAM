import 'dart:io';

import 'package:crux_cam/core/media/media_service.dart';
import 'package:crux_cam/features/media/models/media_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'support/image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalMediaService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('crux_service_');
    service = LocalMediaService();
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'real PNG metadata and signature recognition without an extension',
    () async {
      final source = await writeImageFixture(directory);
      final described = await service.describeFile(
        XFile(source.path, name: 'no_extension'),
      );
      expect(described.type, MediaType.image);
      expect(described.sizeBytes, source.sizeBytes);
      final size = await service.readImageSize(described);
      expect(size.width, 128);
      expect(size.height, 96);
    },
  );

  test('video extension is recognized without loading full file', () async {
    final file = File('${directory.path}/video.MP4');
    await file.writeAsBytes(List.filled(100, 0));
    expect(
      (await service.describeFile(XFile(file.path))).type,
      MediaType.video,
    );
  });

  test('empty, non-media and missing files are rejected', () async {
    final file = File('${directory.path}/empty.mp4');
    await file.writeAsBytes([]);
    await expectLater(
      service.describeFile(XFile(file.path)),
      throwsA(isA<MediaException>()),
    );
    final text = File('${directory.path}/notes.txt');
    await text.writeAsString('climb notes');
    await expectLater(
      service.describeFile(XFile(text.path)),
      throwsA(isA<MediaException>()),
    );
    await expectLater(
      service.describeFile(XFile('${directory.path}/missing.mp4')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('corrupt image fails during metadata probing', () async {
    final file = File('${directory.path}/broken.png');
    await file.writeAsBytes([1, 2, 3, 4]);
    final source = await service.describeFile(XFile(file.path));
    await expectLater(service.readImageSize(source), throwsA(anything));
  });
}
