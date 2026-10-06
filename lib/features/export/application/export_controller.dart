import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crop/models/crop_models.dart';
import '../models/export_models.dart';

final exportServiceProvider = Provider<ExportService>((ref) => ExportService());

class ExportService {
  static const channel = MethodChannel('crux_cam/export');
  Future<void> start(Map<String, Object?> request) =>
      channel.invokeMethod<void>('start', request);
  Future<Map<Object?, Object?>> status(String id) async =>
      (await channel.invokeMapMethod<Object?, Object?>('status', {'id': id}))!;
  Future<void> cancel(String id) =>
      channel.invokeMethod<void>('cancel', {'id': id});
  Future<void> release(String id) =>
      channel.invokeMethod<void>('release', {'id': id});
  Future<String?> save(String path) =>
      channel.invokeMethod<String>('save', {'path': path});
}

class ExportController extends ChangeNotifier {
  ExportController(this.service);
  final ExportService service;
  ExportStage stage = ExportStage.idle;
  double? progress;
  ExportOutput? output;
  String? error, savedLocation;
  bool saving = false, _disposed = false, _cancelled = false;
  String? _id;
  bool get busy => stage == ExportStage.rendering || saving;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(
    String path,
    CropTimeline timeline,
    ExportSettings settings,
  ) async {
    if (busy || _disposed) return;
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    _id = id;
    _cancelled = false;
    stage = ExportStage.rendering;
    progress = null;
    output = null;
    error = null;
    savedLocation = null;
    _changed();
    try {
      await service.start(exportRequest(id, path, timeline, settings));
      // 준비 중에 취소해도 뒤늦게 시작된 네이티브 작업을 반드시 정리합니다.
      if (_cancelled || _disposed) {
        await service.cancel(id);
        return;
      }
      while (!_cancelled && !_disposed) {
        final status = await service.status(id);
        if (_cancelled || _disposed) break;
        switch (status['state']) {
          case 'completed':
            output = ExportOutput.fromMap(status);
            stage = ExportStage.completed;
            progress = 1;
            _changed();
            return;
          case 'failed':
            throw PlatformException(
              code: 'export_failed',
              message: status['error'] as String?,
            );
          case 'cancelled':
            stage = ExportStage.cancelled;
            _changed();
            return;
          default:
            progress = (status['progress'] as num?)?.toDouble().clamp(0, 1);
            _changed();
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      if (!_cancelled && !_disposed) {
        stage = ExportStage.failed;
        error = e is PlatformException
            ? e.message ?? '영상 내보내기에 실패했습니다.'
            : '내보내기를 시작하지 못했습니다.';
        _changed();
      }
    } finally {
      try {
        await service.release(id);
      } catch (_) {}
      if (_id == id) _id = null;
      if (_cancelled && !_disposed) {
        stage = ExportStage.cancelled;
        _changed();
      }
    }
  }

  Future<void> cancel() async {
    if (stage != ExportStage.rendering) return;
    _cancelled = true;
    // 실제 인코더가 멈추기 전에는 새 작업을 받지 않습니다.
    final id = _id;
    if (id != null) {
      try {
        await service.cancel(id);
      } catch (_) {}
    }
  }

  Future<void> save() async {
    final current = output;
    if (current == null || busy || _disposed || savedLocation != null) return;
    saving = true;
    error = null;
    _changed();
    try {
      savedLocation = await service.save(current.path);
      if (savedLocation == null) error = '저장을 취소했습니다. 내보낸 영상은 앱에 보관되어 있습니다.';
    } catch (e) {
      error = e is PlatformException
          ? e.message
          : '갤러리에 저장하지 못했습니다. 다시 저장할 수 있습니다.';
    } finally {
      saving = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
    super.dispose();
  }
}
