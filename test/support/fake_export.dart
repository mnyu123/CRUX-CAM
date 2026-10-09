import 'dart:async';

import 'package:crux_cam/features/export/application/export_controller.dart';

class FakeExportService extends ExportService {
  Completer<void>? opening;
  Map<String, Object?>? request;
  @override
  Future<void> start(Map<String, Object?> request) async {
    this.request = request;
    await opening?.future;
  }

  @override
  Future<Map<Object?, Object?>> status(String id) async => {
    'state': 'completed',
    'path': '/unused/export.mp4',
    'width': 720,
    'height': 960,
    'sizeBytes': 40000,
    'durationMs': 1000,
    'hasAudio': true,
  };
  @override
  Future<void> release(String id) async {}
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<String?> save(String path) async => 'gallery:export';
}
