import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/export_models.dart';

class ExportPreview extends StatefulWidget {
  const ExportPreview({super.key, required this.output});
  final ExportOutput output;
  @override
  State<ExportPreview> createState() => _ExportPreviewState();
}

class _ExportPreviewState extends State<ExportPreview>
    with WidgetsBindingObserver {
  late final VideoPlayerController _player;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = VideoPlayerController.file(File(widget.output.path))
      ..addListener(_changed);
    unawaited(_prepare());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _prepare() async {
    try {
      await _player.initialize().timeout(const Duration(seconds: 30));
    } catch (_) {
      if (mounted) setState(() => _error = '내보낸 영상을 재생하지 못했습니다.');
    }
  }

  Future<void> _toggle() async {
    try {
      if (_player.value.isPlaying) {
        await _player.pause();
      } else {
        if (_player.value.position >= _player.value.duration) {
          await _player.seekTo(Duration.zero);
        }
        if (mounted &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          await _player.play();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '재생 상태를 바꾸지 못했습니다.');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_player.pause().catchError((_) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_changed);
    // 원본 미리보기와 결과 미리보기의 소리가 겹치지 않도록 각 화면이 자기 재생기를 해제합니다.
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('내보낸 영상')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Text(_error!)
                  : !_player.value.isInitialized
                  ? const CircularProgressIndicator()
                  : AspectRatio(
                      aspectRatio: _player.value.aspectRatio,
                      child: VideoPlayer(_player),
                    ),
            ),
          ),
          if (_player.value.isInitialized)
            VideoProgressIndicator(
              _player,
              allowScrubbing: true,
              padding: const EdgeInsets.all(20),
            ),
          IconButton(
            onPressed: _player.value.isInitialized && _error == null
                ? () => unawaited(_toggle())
                : null,
            icon: Icon(
              _player.value.isPlaying ? Icons.pause : Icons.play_arrow,
            ),
          ),
        ],
      ),
    ),
  );
}
