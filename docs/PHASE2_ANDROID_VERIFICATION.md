# Phase 2 Android 검증

브랜치: `phase2-analysis`. 공통 기준 커밋: `11d7030`. Android API 24 이상을 대상으로 합니다.

## 구현

- `MainActivity`가 `PoseBridge`를 등록하고 엔진 종료 시 해제합니다.
- 직렬 작업 큐에서 프레임을 추출하고 MediaPipe Full/Lite 또는 ML Kit Accurate를 실행합니다.
- MediaPipe Tasks Vision 1.0.0, ML Kit Accurate 18.0.0-beta5, ExifInterface 1.4.2를 고정했습니다.
- MediaPipe는 CPU, 최대 4명 후보, VIDEO/IMAGE 모드를 사용합니다. ML Kit는 SDK 기본 하드웨어 설정과 STREAM/SINGLE_IMAGE 모드를 사용하므로 모델 실행 시간은 동일 하드웨어 조건의 순수 비교가 아닙니다.
- 사진은 EXIF 회전/뒤집기를 적용합니다. 영상은 회전된 디코더 프레임을 기준으로 합니다.
- 긴 변은 960픽셀 이하로 분석합니다. API 27 이상에서는 축소된 영상 프레임을 직접 요청하며 API 24~26에서는 원본 프레임을 받은 뒤 즉시 축소·해제합니다.
- 앱 전용 `files/analysis/`에 JSON을 저장합니다. Picker 임시 영상의 영구 보관은 구현하지 않았습니다.

## 통과한 검증

- `flutter analyze`: No issues found.
- 공통 단위/위젯 테스트 30개 통과.
- Android 디버그 APK 빌드 성공.
- emulator-5554 / Android API 36에서 실제 네이티브 통합 테스트 3개 통과: 사진·영상/90도 회전/반복 세션/준비 중 취소, 사용자 클라이밍 영상 모델 비교·JSON 저장, 실제 영상 위 관절 표시·대상 선택·12초 탐색.
- `flutter drive` 화면 캡처 테스트 통과. `build/phase2-screenshots/phase2-overlay.png`를 열어 영상과 관절이 같은 영역에 표시되는 것을 확인했습니다. 캡처와 사용자 영상은 빌드 폴더에만 있으며 커밋하지 않습니다.

## 사용자 영상 1개 비교

약 27.4초·1280×720 영상에서 200ms 간격으로 138개 프레임을 분석했습니다. 아래는 두 번째 통과 실행 결과입니다. 각 모델의 첫 번째 사용 가능한 후보를 선택한 자동 테스트이므로 실제 동일 인물 정답을 수동으로 지정한 정확도 측정이 아닙니다.

| 모델 | 사람 감지 프레임 | 추적 상태가 tracked인 프레임 | 평균 모델 실행 | 전체 분석 |
|---|---:|---:|---:|---:|
| MediaPipe Full | 104/138 | 100/138 | 34.6ms | 23.9초 |
| MediaPipe Lite | 99/138 | 66/138 | 28.9ms | 22.6초 |
| ML Kit Accurate | 133/138 | 40/138 | 16.1ms | 21.3초 |

감지율은 관절 정확도를 뜻하지 않고 `tracked`도 인물 식별 정답을 보장하지 않습니다. ML Kit는 한 사람만 반환하므로 다른 사람으로 전환될 수 있으며 앱은 위치 연결이 의심스러우면 끊김으로 남깁니다. 기본값은 MediaPipe Full을 유지하지만 최종 모델 선정은 여러 클라이밍 영상에서 관절 위치·실제 대상 전환·가림 복구를 확인한 뒤 합니다. 에뮬레이터 수치는 실기기 성능을 대표하지 않습니다.

## 실행

프로젝트 루트의 PowerShell에서:

```powershell
.\scripts\android_phase2.ps1 -Action build
.\scripts\android_phase2.ps1 -Action run -DeviceId emulator-5554
.\scripts\android_phase2.ps1 -Action integration -DeviceId emulator-5554
```

개인 영상으로 비교하려면 PC 파일 경로를 지정합니다.

```powershell
.\scripts\android_phase2.ps1 -Action integration -DeviceId emulator-5554 -LocalVideoPath 'D:\videos\climb.mp4'
.\scripts\android_phase2.ps1 -Action visual -DeviceId emulator-5554 -LocalVideoPath 'D:\videos\climb.mp4'
```

개인 영상은 `build/phase2-fixtures/`에 복사해 테스트 빌드에만 임시로 포함하고, 스크립트가 `pubspec.yaml`을 복구합니다. 일반 앱을 실행하려면 이후 `-Action build` 또는 `-Action run`으로 다시 빌드합니다. `flutter test -d`는 테스트 앱을 종료하면서 제거할 수 있으므로 개발 앱을 다시 설치해야 할 수 있습니다. 기기 내부의 읽을 수 있는 영상이 있으면 `-VideoPath`로도 지정할 수 있습니다.

앱에서 파일 선택 → 클라이머 분석 → 분석 시작 → 사람 선택 → 재생/탐색·보정 비교 → 분석 결과 저장 순으로 사용합니다.

## 남은 확인

- 실제 Android 기기에서 발열·메모리·긴 영상 처리 속도.
- 여러 클라이밍 영상의 등진 자세, 가림, 다른 사람 교차, 낙하와 빠른 이동.
- 다양한 회전·뒤집기 사진과 지원 코덱. 90도 MP4 회전은 자동 검증했습니다.
- BorderCam과 같은 영상·조건의 비교. 기존 앱보다 정확하다고 아직 판정하지 않습니다.
- iOS는 `phase2-ios`에서 별도 구현·검증합니다.
