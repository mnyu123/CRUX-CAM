# CRUX-CAM

클라이밍 영상·사진을 입력하고 미리보는 Flutter 모바일 앱. 현재 Phase 1 — Media MVP 구현 단계이며, 실제 기기 검증이 남아 있습니다.

## 구현한 기능

- 시스템 Picker에서 동영상 또는 사진 한 개 선택.
- 원본 비율을 유지한 영상 미리보기, 재생·일시정지·탐색·끝난 영상 재생.
- 사진 미리보기와 이미지 해상도 확인.
- 파일명, 읽을 수 있는 로컬 경로, 파일 크기, 해상도, 영상 길이 표시.
- 재선택 성공 후 기존 플레이어 해제. 취소·실패 시 기존 미디어 유지.
- 로딩·오류 처리, 중복 선택 차단, Android 유실된 Picker 결과 복구.
- 백그라운드·다른 화면 진입 시 재생 정지, 화면 종료 시 자동 리소스 해제.

분석 시작 버튼은 다음 단계 안내용으로 비활성화되어 있습니다. FPS·관절 분석·추적·자동 크롭·인코딩·내보내기는 후속 범위입니다.

## 구조와 변경 이유

| 파일 / 디렉터리 | 역할 |
| --- | --- |
| lib/main.dart | Flutter 초기화와 ProviderScope. 기본 카운터 제거 |
| lib/app/app.dart | 앱 테마·시작 화면·RouteObserver |
| lib/app/routes.dart | 실제 미디어 화면 경로, 이후 기능 경로 추가 지점 |
| lib/features/media/models/media_info.dart | 파일·유형·메타데이터. 재생 컨트롤러와 분리 |
| lib/features/media/application/media_controller.dart | 선택·상태·재생 동작·플레이어 소유권과 해제 |
| lib/features/media/presentation/media_screen.dart | 한국어 UI, 미리보기와 앱/화면 생명주기 전달 |
| lib/features/media/presentation/media_formatters.dart | 시간·파일 크기 표시 |
| lib/core/media/media_service.dart | Picker, 파일 유형/이미지 메타데이터, 로컬 영상 플레이어 생성 |
| pubspec.yaml / pubspec.lock | 최소 의존성과 재현 가능한 설치 버전 |
| android/app/src/main/AndroidManifest.xml | 표시 이름 CRUX-CAM |
| ios/Runner/Info.plist | 사진 라이브러리 사용 목적 설명 |
| android/gradle.properties / android/.gitignore | Windows 드라이브 간 Kotlin 캐시 오류 회피, 생성 캐시 제외 |
| test/ | 컨트롤러·서비스·위젯 테스트 |
| integration_test/ | 실제 모바일 디코더와 로컬 파일 테스트 |
| scripts/android_phase1.ps1 | Windows Java 임시 경로 문제를 회피하는 빌드·실행 도구 |

호출 흐름은 `MediaScreen → MediaController → MediaService`입니다. 사진 파일을 화면에 렌더링하는 부분 외에 선택·메타데이터 처리는 서비스가 담당합니다. 플레이어는 Application 계층에서 관리합니다.

## 의존성·권한·플랫폼

Flutter 3.47.5 / Dart 3.13.4에서 image_picker 1.2.3, video_player 2.14.1, flutter_riverpod 3.4.3, mime 2.1.0을 설치·검증했습니다. 테스트에는 Flutter SDK의 integration_test와 video_player_platform_interface를 사용합니다.

Android API 33 이상에서는 시스템 Photo Picker가 선택한 미디어 접근을 제공합니다. 광범위한 저장소 권한을 요청하지 않습니다. iOS에는 NSPhotoLibraryUsageDescription을 추가했고, 추가 사진 메타데이터를 요청하지 않도록 Picker를 구성했습니다. [image_picker 공식 문서](https://pub.dev/packages/image_picker)

지원 대상은 Android / iOS입니다. Windows·Web 실행은 Phase 1 지원 대상이 아닙니다. 로컬 경로는 Picker가 제공하는 앱 접근 가능한 파일/복사본이며 갤러리 원본 경로나 영구 보관 경로를 의미하지 않습니다. 원본 파일을 편집하거나 삭제하지 않습니다. 영상 재생 가능 코덱은 기기의 플레이어 지원 범위를 따릅니다. [video_player 공식 문서](https://pub.dev/packages/video_player)

## 실행과 검증

프로젝트 루트에서:

```powershell
flutter pub get
flutter analyze
flutter test
.\scripts\android_phase1.ps1 -Action build
```

Android 에뮬레이터 또는 실제 기기를 준비한 뒤:

```powershell
flutter emulators --launch CRUX-PHONE
flutter devices
.\scripts\android_phase1.ps1 -Action run -DeviceId emulator-5554
.\scripts\android_phase1.ps1 -Action integration -DeviceId emulator-5554
```

DeviceId는 `flutter devices`에 표시되는 실제 ID로 바꿉니다. 위 스크립트는 프로세스에만 Java 임시 경로 옵션을 적용하고 기존 설정을 복구합니다. APK 출력은 `build/app/outputs/flutter-apk/app-debug.apk`입니다.

2026-10-03 기준 정적 분석과 자동 테스트 17개, Android 디버그 APK 빌드가 통과했습니다. 최초 에뮬레이터 시작은 가속 환경 문제로 실패했으나, 후속 대화에서 실행 중인 emulator-5554 연결과 드래그한 영상의 갤러리 등록 복구를 확인했습니다. 앱의 실제 재생·통합 테스트 검증은 남아 있습니다. 상세 기록·파일 전달 방법·수동 완료 조건은 [Phase 1 검증 기록](docs/PHASE1_VERIFICATION.md), 전체 목표는 [프로젝트 문맥](PROJECT_CONTEXT.md)을 참고합니다.
