import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

Future<String> saveJsonAtomic(
  String directoryPath,
  String prefix,
  Map<String, dynamic> value,
) async {
  final directory = Directory(directoryPath);
  await directory.create(recursive: true);
  final path =
      '${directory.path}/${prefix}_${DateTime.now().microsecondsSinceEpoch}.json';
  final temporary = File('$path.partial');
  try {
    // 긴 영상의 좌표 변환은 별도 실행 공간에서 하고, 완성된 파일만 저장 목록에 남깁니다.
    final data = await compute(jsonEncode, value);
    await temporary.writeAsString(data, flush: true);
    await temporary.rename(path);
    return path;
  } catch (_) {
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}
