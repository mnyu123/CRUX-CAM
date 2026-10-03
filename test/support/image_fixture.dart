import 'dart:io';
import 'dart:ui' as ui;

import 'package:crux_cam/features/media/models/media_info.dart';

Future<MediaSource> writeImageFixture(Directory directory) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 128, 96),
    ui.Paint()..color = const ui.Color(0xFF8CBF55),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(128, 96);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${directory.path}/climb.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    return MediaSource(
      path: file.path,
      name: 'climb.png',
      sizeBytes: await file.length(),
      type: MediaType.image,
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}
