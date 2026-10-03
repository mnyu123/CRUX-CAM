# Phase 1 검증 기록

확인일: 2026-10-03.

## 실행한 검증

| 항목 | 결과 |
| --- | --- |
| Flutter / Dart | Flutter 3.47.5 Stable / Dart 3.13.4 확인 |
| 패키지 해결 | 성공. pubspec.lock에 설치 버전 기록 |
| flutter analyze --no-pub | No issues found |
| flutter test | 17개 통과 |
| Android 디버그 APK | 빌드 성공 |
| Pixel 9 / API 36 에뮬레이터 | 최초 시작 실패. 후속 대화에서 실행 중인 emulator-5554 / API 36 연결 확인 |
| 실제 Android Picker / 디코더 / 오디오 | 실행 검증 대기 |
| iOS 기기 실행 | Windows 환경에서 미검증 |

APK: `build/app/outputs/flutter-apk/app-debug.apk`.

## 자동 테스트의 범위

- 실제 VideoPlayerController에 가짜 플랫폼 API를 연결해 메타데이터, 재생·일시정지, 탐색, 끝난 영상 재생, 백그라운드 정지 확인.
- 영상 4회 교체 후 사진으로 변경할 때 기존 플레이어가 한 번씩 해제되는지 확인.
- 선택 취소와 새 영상 디코딩 실패 시 기존 미디어가 유지되는지 확인. 새 선택 실패 후에도 기존 정상 영상은 재생 가능.
- 접근 거부 메시지, 재시도, 동시 Picker 실행 차단, 종료 후 늦게 도착한 결과 무시 확인.
- Android 유실된 Picker 결과를 한 번 복구하는 컨트롤러 흐름 확인.
- 초기화 중 종료와 정상 종료 시 리소스 해제 확인.
- 실제 PNG 파일의 크기·해상도·시그니처 판별, 손상·빈 파일·미지원 파일·없는 파일 처리 확인.
- 화면의 영상·사진 표시, 정보 표시, 다른 화면 진입 시 정지, 작은 화면과 큰 글씨 레이아웃 확인.

이 테스트는 Android 시스템 Picker나 실제 하드웨어 디코더 검증을 대신하지 않는다.

## 기기 통합 테스트

`integration_test/media_preview_test.dart`는 Picker 결과만 정해진 테스트 파일로 공급한다. 나머지는 실제 LocalMediaService와 기기의 video_player 플러그인을 사용한다. 테스트 앱 내부에 2초 H.264 영상과 PNG를 생성하므로 별도 다운로드나 저장소 권한이 필요 없다. 테스트 영상은 제품 앱에는 포함되지 않는다.

기기를 연결한 뒤 프로젝트 루트에서:

```powershell
flutter devices
.\scripts\android_phase1.ps1 -Action integration -DeviceId emulator-5554
```

`emulator-5554`는 예시이며 실제 Android DeviceId로 대체한다. 테스트는 아직 기기에서 실행되지 않았다.

## 수동 완료 체크리스트

- [ ] Pixel 9 / API 36에서 앱 실행.
- [ ] 영상 / 사진 선택 → 실제 시스템 Picker에서 동영상 선택.
- [ ] 최초 프레임이 보이고 화면 비율이 유지됨.
- [ ] 재생·일시정지·탐색·끝난 영상 다시 재생 가능.
- [ ] 원본 오디오 포함 영상의 소리가 재생되고 정지 시 멈춤.
- [ ] 파일명·파일 크기·재생시간·해상도·읽을 수 있는 로컬 경로 확인.
- [ ] 다른 동영상으로 반복 변경 후 오류·오디오 중첩 없음.
- [ ] 사진 선택 후 미리보기·해상도·파일 크기 확인.
- [ ] Picker 취소 시 기존 선택 유지.
- [ ] 앱을 백그라운드로 보냈을 때 재생 정지.
- [ ] 가로 방향·세로 방향 영상, 회전 메타데이터가 있는 영상 확인.
- [ ] 큰 영상·지원되지 않는 코덱·손상 파일의 오류 처리 확인.
- [ ] 기기 설정의 사진 접근 제한/거부 상황 확인(플랫폼에 따라 Picker 접근 방식이 다름).
- [ ] 필요하면 Android 개발자 옵션의 활동 유지 안 함으로 Picker 결과 복구 확인.

## 이 PC에서 확인한 실행 환경 문제

에뮬레이터 `CRUX-PHONE`의 설정은 Pixel 9 / API 36이다. Emulator 37.1.11은 시작 시 기존 HAXM이 지원되지 않는다고 보고했고, `emulator -accel-check`는 Android Emulator hypervisor driver가 설치되어 있지 않다고 보고했다. 소프트웨어 가속 옵션으로도 시작하지 못했다.

Android 공식 문서는 Windows Hypervisor Platform(WHPX)을 권장한다. Windows 기능 활성화·드라이버 설치·재부팅은 수행하지 않았다. 설정 방법은 [Android 공식 가속 환경 문서](https://developer.android.com/studio/run/emulator-acceleration#vm-windows-whpx)를 참고한다. 또는 USB 디버깅을 허용한 실제 Android 기기로 검증할 수 있다.

빌드 과정에서는 JDK 25의 긴 임시 UNIX 소켓 경로 때문에 `Unable to establish loopback connection` / `Invalid argument: connect`가 발생했다. 짧은 프로젝트 내부 임시 경로를 지정하자 해결되어, `scripts/android_phase1.ps1`에 해당 실행 옵션을 넣었다. 전역 Java/Flutter 설정을 바꾸지 않는다.

또한 C:의 Pub 캐시와 D:의 프로젝트 간 경로 변환이 Kotlin incremental compilation에서 실패했다. `android/gradle.properties`의 `kotlin.incremental=false`로 해결했다. 이 설정은 Kotlin 증분 컴파일을 끄므로 해당 부분의 재빌드 시간이 늘 수 있다.

후속 사용자 확인: 재생·일시정지·탐색, 반복 영상 선택, 사진/영상 전환, 취소 유지·백그라운드 정지, 파일 크기·해상도 표시의 수동 검증 5개를 모두 통과했습니다. Phase 1은 aedcc0c로 커밋했고 이 상태를 Phase 2 기준으로 삼습니다. 위의 추가 환경·오류 시나리오와 iOS 실행 항목은 사용자 확인 없이 통과 처리하지 않습니다.

## 가상 기기에 동영상 전달하기

에뮬레이터 화면에 파일을 드래그하면 `/sdcard/Download/`에 들어간다. 파일이 존재해도 미디어 목록 등록이 끝나지 않으면 CRUX-CAM의 시스템 선택 화면에 나타나지 않을 수 있다. [Android 공식 안내](https://developer.android.com/studio/run/emulator-install-add-files)

이번 후속 확인에서는 실제 동영상의 MediaStore `is_pending`이 1(전송 중)이었고 크기·재생시간이 비어 있었다. 해당 등록 행을 0(완료)으로 갱신하고 재스캔하자 크기와 재생시간·해상도가 정상 등록됐다. 선택 화면을 닫고 다시 열어 확인한다.

새 파일을 PC에서 직접 전달할 때는 PowerShell에서 다음처럼 실행할 수 있다. PC 파일 경로를 실제 영상으로 바꾸고, 가상 기기의 목적 파일명은 기존 파일과 겹치지 않게 지정한다.

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb -s emulator-5554 push "D:\videos\climb.mp4" /sdcard/Movies/climb.mp4
& $adb -s emulator-5554 shell content call --uri content://media --method scan_file --arg /storage/emulated/0/Movies/climb.mp4
```

`scan_file` 명령은 이 API 36 에뮬레이터에서 확인한 개발용 미디어 재스캔 방법이며 앱 코드에서 사용하는 공개 API가 아니다. 파일 전송 뒤에도 문제가 있으면 `content query --uri content://media/external/video/media --projection _id:_display_name:is_pending:_size:duration`으로 등록 상태를 확인한다. 문제 영상의 행 ID를 확인하기 전에 다른 항목의 전송 상태를 임의로 변경하지 않는다.
