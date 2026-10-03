import 'package:flutter/material.dart';

import '../features/media/presentation/media_screen.dart';

final mediaRouteObserver = RouteObserver<PageRoute<dynamic>>();

abstract final class AppRoutes {
  static const media = '/';

  // 분석·편집·내보내기 화면을 구현하면 여기에 이동 경로를 추가합니다.
  static final Map<String, WidgetBuilder> routes = {
    media: (_) => const MediaScreen(),
  };
}
