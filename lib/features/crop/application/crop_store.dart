import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/json_store.dart';
import '../models/crop_models.dart';

final cropStoreProvider = Provider<CropStore>((ref) => CropStore());

class CropStore {
  Future<String> save(
    CropTimeline timeline,
    String directory,
    String sourceName,
  ) => saveJsonAtomic(directory, 'crop', timeline.toJson(sourceName));
}
