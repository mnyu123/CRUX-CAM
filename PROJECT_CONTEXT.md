# CRUX-CAM 프로젝트 메모

최종 확인: 2026-10-01. 아래 구현 상태는 해당 날짜의 소스 확인 결과이며, 작업을 재개할 때 현재 파일과 대조한다.

## 프로젝트 목표

- Android / iOS를 지원하는 Flutter 기반 클라이밍 영상 자동 분석·편집 앱.
- 사용자가 접근을 허용한 동영상 또는 사진을 입력받는다.
- 사람과 배경을 구분하고 클라이머의 관절을 가시화·분석한다.
- 클라이머 한 명을 추적 대상으로 고정하고 다른 사람으로 대상이 바뀌지 않게 한다.
- 움직임에 따라 크롭·확대·화면 비율을 조절하고 원하는 형식으로 내보낸다.
- 모티브는 BorderCam. 사용자가 느끼는 기존 앱의 인식률 문제를 개선하는 것이 핵심이다.
- 서버 없이 가능한 한 기기 내부에서 분석·변환한다. 외부 AI 사용은 비용과 인식 안정성을 검토한 뒤 결정한다.

## 최종 처리 흐름과 출력

미디어 선택 → 사람/Pose 분석 → Subject Lock → Pose Tracking → Pose Smoothing → Auto Reframing → Crop Timeline → 원본 기반 최종 Rendering → MP4 Export.

- 목표 비율: Original, 16:9, 9:16, 4:5, 3:4, 1:1.
- 자동 크롭의 확대 정도를 사용자가 조절할 수 있어야 한다.
- 기본 컨테이너: MP4. 코덱 후보: H.264/AVC, H.265/HEVC.
- 관절 좌표·추적 보정과 영상 화질 처리를 구분한다. 원본 기반 최종 렌더링으로 불필요한 중간 화질 손실을 줄이는 방향이다.
- 관절 인식 라이브러리 활용, 외부 AI 판단, 자체 인식 개발 중 어떤 방식을 쓸지는 미확정이다. 대상 전환과 좌표 튐을 줄이는 안정성이 중요하다.

## 현재 단계: Phase 1 — Media MVP

AI 도입 전에 안정적인 로컬 미디어 입력과 미리보기를 구현·검증한다.

1. 동영상·사진 선택과 유형 판별.
2. 영상 미리보기, 재생·일시정지, 재생시간 표시.
3. 사진 미리보기.
4. 파일명, 경로 또는 URI, 파일 크기, 가로·세로 해상도, 영상 길이 표시.
5. FPS는 간단히 얻을 수 있을 때만 포함하며 복잡한 네이티브 처리나 FFmpeg가 필요하면 후속으로 미룬다.
6. 파일 재선택, 화면 이탈, 종료 시 VideoPlayerController 등 리소스를 정상 해제한다.
7. 분석 시작 버튼이나 향후 이동 구조는 둘 수 있지만 실제 분석은 실행하지 않는다.

완료 기준은 Android Pixel 9 / API 36 에뮬레이터에서 위 흐름이 동작하고 반복 파일 교체 시 리소스 오류가 없는 것이다.

Phase 1 제외: MediaPipe, ML Kit Pose, 사람·관절 인식, 추적, 보정, 자동 크롭, Crop Timeline, Media3, FFmpeg, 인코딩, 4K 내보내기 및 별도 Kotlin/Swift 영상 처리.

## 구현 방향

- 과도한 Clean Architecture 대신 Feature + Layer 혼합 구조.
- 호출 방향: MediaScreen → MediaController → MediaService.
- 권장 파일: lib/app/app.dart, lib/app/routes.dart, lib/features/media/presentation/media_screen.dart, lib/features/media/application/media_controller.dart, lib/features/media/models/media_info.dart, lib/core/media/media_service.dart.
- 상태관리는 flutter_riverpod을 사용할 예정.
- 미디어 모델에는 파일 정보·유형·메타데이터를 두고 VideoPlayerController는 UI/Application 계층에서 관리한다.
- Picker의 File/URI 처리는 MediaService에서 감싸 Android 전용 절대 경로에 과도하게 의존하지 않는다.
- 패키지 후보는 file_picker 또는 image_picker, video_player, flutter_riverpod, 필요한 경우 path_provider. 실제 선정과 버전 호환성 확인은 구현 시 수행한다.
- 향후 analysis/editor/export 및 pose/tracking/smoothing/reframing/video로 확장하되 빈 파일을 미리 대량 생성하지 않는다.

## 환경 및 확인된 소스 상태

- 실제 프로젝트 루트: D:\CRUX-CAM_flutter\crux_cam.
- 사용자 제공 환경: Windows, Flutter 3.47.5 Stable, Android Studio Quail 4, Android SDK/API 36, Pixel 9/API 36 에뮬레이터. doctor/devices 확인 완료라고 전달받았으며 이번 소스 검토에서는 재검증하지 않았다.
- VS Code가 주 IDE이며 Android Studio는 SDK·에뮬레이터·Kotlin 확인용이다.
- android/local.properties의 Flutter 경로: D:\flutter\flutter_windows_3.47.5-stable.
- lib/main.dart: MyApp → MyHomePage의 Flutter 기본 카운터 예제.
- pubspec.yaml: name crux_cam, version 1.0.0+1, Dart SDK 조건 ^3.13.4. 앱 의존성은 Flutter와 cupertino_icons뿐이다.
- test/widget_test.dart: 기본 카운터 증가 테스트.
- Android applicationId/namespace: com.cruxcam.crux_cam. MainActivity는 기본 FlutterActivity.
- iOS는 기본 Runner 구성. 미디어 관련 커스텀 구현 없음.
- app/features/core 구조, 미디어 선택·미리보기, 분석·크롭·내보내기는 아직 구현되지 않았다.
- 현재 프로젝트 경로에서 git status 실행 시 Git 저장소가 아니라고 확인되었다.
- 빌드·테스트·에뮬레이터 실행 검증은 이번 검토에서 수행하지 않았다.

## 마지막 요청과 작업 범위

사용자는 첨부 문서와 초기 소스 파악을 요청했고, 이어 해당 내용을 메모리에 저장해 달라고 요청했다. 첨부 문서에는 Phase 1 구현 요청문이 있지만 이번 대화에서는 사전 파악과 메모 저장까지만 수행했다. 앱 소스는 변경하지 않았다. 이 메모 자체를 새로운 구현 착수 지시로 간주하지 않는다.
