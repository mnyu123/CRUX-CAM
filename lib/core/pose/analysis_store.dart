import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/analysis/models/pose_models.dart';

final analysisStoreProvider = Provider<AnalysisStore>((ref) => AnalysisStore());

class AnalysisStore {
  Future<String> save(AnalysisResult result, String sourceName) async {
    final directory = Directory(result.session.storageDirectory);
    await directory.create(recursive: true);
    final path =
        '${directory.path}/pose_${DateTime.now().microsecondsSinceEpoch}.json';
    final temporary = File('$path.partial');
    try {
      // 긴 영상의 JSON 변환은 별도 실행 공간에서 처리하여 화면이 멈추지 않게 합니다.
      final data = await compute(jsonEncode, result.toJson(sourceName));
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(path);
      return path;
    } catch (_) {
      // 저장 중 실패한 파일을 완성된 분석 결과로 오인하지 않도록 지웁니다.
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
