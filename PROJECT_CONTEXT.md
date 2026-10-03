# CRUX-CAM 프로젝트 메모

최종 확인: 2026-10-03. 아래 구현 상태는 해당 날짜의 소스 확인 결과이며, 작업을 재개할 때 현재 파일과 대조한다.

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

- 사용자는 코드 주석을 쉽게 이해할 수 있는 한국어로 작성하라고 요청했다. 직접 작성하는 주석은 한국어를 기본으로 하고, 복잡한 처리의 이유를 설명한다.
- 과도한 Clean Architecture 대신 Feature + Layer 혼합 구조.
- 호출 방향: MediaScreen → MediaController → MediaService.
- 구현 파일: lib/app/app.dart, lib/app/routes.dart, lib/features/media/presentation/media_screen.dart, lib/features/media/application/media_controller.dart, lib/features/media/models/media_info.dart, lib/core/media/media_service.dart.
- 상태관리는 flutter_riverpod의 auto-dispose NotifierProvider를 사용한다.
- 미디어 모델에는 파일 정보·유형·메타데이터를 두고 VideoPlayerController는 UI/Application 계층에서 관리한다.
- Picker의 File/URI 처리는 MediaService에서 감싸 Android 전용 절대 경로에 과도하게 의존하지 않는다.
- 설치한 앱 패키지: image_picker 1.2.3, video_player 2.14.1, flutter_riverpod 3.4.3, mime 2.1.0. 실제 해결 버전은 pubspec.lock에 기록되어 있다. path_provider는 현 단계에 불필요하여 추가하지 않았다.
- 향후 analysis/editor/export 및 pose/tracking/smoothing/reframing/video로 확장하되 빈 파일을 미리 대량 생성하지 않는다.

## 환경 및 확인된 소스 상태

- 실제 프로젝트 루트: D:\CRUX-CAM_flutter\crux_cam.
- 확인한 환경: Windows, Flutter 3.47.5 Stable, Dart 3.13.4, Android API 36. 에뮬레이터 CRUX-PHONE 설정은 Pixel 9 / API 36이다.
- VS Code가 주 IDE이며 Android Studio는 SDK·에뮬레이터·Kotlin 확인용이다.
- android/local.properties의 Flutter 경로: D:\flutter\flutter_windows_3.47.5-stable.
- lib/main.dart: ProviderScope → CruxCamApp. 기본 카운터 예제를 제거했다.
- pubspec.yaml: name crux_cam, version 1.0.0+1, Dart SDK 조건 ^3.13.4. 미디어·상태관리 패키지를 추가하고 사용하지 않는 cupertino_icons를 제거했다.
- MediaService는 시스템 Picker의 XFile을 앱이 읽을 수 있는 로컬 경로·이름·크기·유형으로 감싼다. Picker 반환 파일은 임시 복사본일 수 있으며 영구 저장을 구현하지 않았다.
- MediaController가 메타데이터·로딩·오류·재생 리소스를 관리한다. 선택 성공 후 교체, 취소/실패 시 기존 미디어 유지, 중복 실행 차단, 초기화 제한 시간 30초, 화면 종료 시 해제를 구현했다.
- 미디어 화면은 영상·사진 미리보기, 영상 재생/일시정지/탐색, 파일 정보, 로딩·오류를 표시한다. 앱 백그라운드 또는 다른 경로 진입 시 정지한다. 분석 시작 버튼은 준비 중으로 비활성화했다.
- Android의 유실된 Picker 결과 복구를 앱 화면 초기화에서 실행한다. Android Photo Picker를 사용하므로 광범위한 저장소 권한을 추가하지 않았다. iOS에는 NSPhotoLibraryUsageDescription을 추가했다.
- test/의 자동 테스트 17개가 통과했고 flutter analyze에서 No issues found를 확인했다. 네이티브 API를 가짜로 대체한 테스트와 실제 PNG 파일 메타데이터 테스트를 포함한다.
- integration_test/media_preview_test.dart는 Picker 결과만 테스트 파일로 공급하고 실제 기기 디코더로 재생·교체·사진 전환을 검증하도록 작성했다. 실제 기기에서 아직 실행하지 않았다.
- Android applicationId/namespace: com.cruxcam.crux_cam. MainActivity는 기본 FlutterActivity.
- iOS는 기본 Runner와 사진 라이브러리 설명 설정이며, Windows 환경이므로 iOS 실행은 미검증이다.
- Android 디버그 APK 빌드 성공: build/app/outputs/flutter-apk/app-debug.apk.
- Java 25의 긴 임시 UNIX 소켓 경로로 빌드가 실패했으나 프로젝트 내부 짧은 임시 경로 지정으로 해결했다. scripts/android_phase1.ps1은 해당 옵션을 실행 프로세스에만 적용하고 원래 환경 변수를 복구한다. build/run/integration 명령을 지원한다.
- C: Pub 캐시와 D: 프로젝트 사이의 Kotlin 증분 캐시 경로 오류를 android/gradle.properties의 kotlin.incremental=false로 해결했다.
- 에뮬레이터 37.1.11은 기존 HAXM 지원 중단 오류로 시작 실패했다. accel-check는 Android Emulator hypervisor driver 미설치를 보고했다. 소프트웨어 옵션으로도 실패하여 실제 Android 기기의 Picker/디코더/오디오 검증은 남아 있다. 시스템 기능·드라이버 설치·재부팅은 하지 않았다.
- 후속 확인: 사용자가 가상 기기를 실행하여 emulator-5554 / API 36 연결을 확인했다. 앞선 가속 오류는 이전 실행 시의 기록이며 현재 기기는 실행 중이다. 앱 설치도 확인했으나 실행 중인 사용자 앱을 테스트용 앱으로 바꾸지는 않았다.
- 드래그한 동영상이 /sdcard/Download에 존재했지만 MediaStore에서 is_pending=1이고 크기·재생시간이 비어 있어 선택 목록에서 숨겨지는 상태였다. 해당 파일의 미디어 등록 행만 is_pending=0으로 갱신하고 scan_file을 요청했다. 이후 파일 크기 3,642,252바이트, 재생시간 27,417ms, 해상도 1280×720을 확인했다. 영상 파일 내용은 변경하지 않았다. 재발 시 원본 파일 전송과 갤러리 등록 완료 여부를 함께 확인한다.
- 2026-10-03 기준 Git 저장소가 존재한다. 도구 실행 계정의 소유권 경고는 명령별 git -c safe.directory=D:/CRUX-CAM_flutter/crux_cam으로 읽었으며 전역 설정을 변경하지 않았다. 커밋·푸시는 하지 않았다.
- 변경 파일 이유·실행 방법은 README.md, 상세 검증 결과와 수동 완료 항목은 docs/PHASE1_VERIFICATION.md에 기록했다.
- 관절 분석·추적·크롭·인코딩·내보내기는 후속 단계다. Phase 1 전체 완료 판정은 실제 기기 검증 이후에 한다.

## 마지막 요청과 작업 범위

2026-10-01에 초기 소스 확인과 메모 저장을 수행했다. 2026-10-03에 사용자가 Phase 1 설계대로 개발을 시작하고 꼼꼼히 작성하라고 지시하여 구현·자동 테스트·APK 빌드까지 진행했다. 다음 확인은 실행 가능한 Android 기기에서 통합 테스트와 시스템 Picker를 포함한 수동 검증이다. 이 메모 자체를 Phase 2 착수 지시로 간주하지 않는다.
