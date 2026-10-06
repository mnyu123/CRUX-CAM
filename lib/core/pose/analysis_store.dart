import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/analysis/models/pose_models.dart';
import '../storage/json_store.dart';

final analysisStoreProvider = Provider<AnalysisStore>((ref) => AnalysisStore());

class AnalysisStore {
  Future<String> save(AnalysisResult result, String sourceName) =>
      saveJsonAtomic(
        result.session.storageDirectory,
        'pose',
        result.toJson(sourceName),
      );
}
