# Phase 3 Android 검증 — 2026-10-06

- Flutter 3.47.5 / Dart 3.13.4, Android API 36 emulator-5554.
- `flutter analyze`: No issues found. 공통 테스트 54개 통과.
- Media3 Transformer/effect 1.9.2와 기존 재생 SDK 버전 일치. APK 디버그 빌드 성공.
- `integration_test/export_test.dart`: 네이티브 3개 테스트 통과. 직접 만든 4초 합성 영상으로 3:4, 이동 크롭, 회전, 소리 유지/제거, 실제 결과 재생, 갤러리 저장, 준비 중 취소 뒤 재시도, 진행·결과 화면 복귀·접근성 트리를 확인.
- Windows 재실행: `.\scripts\android_phase2.ps1 -Action integration -Suite export -DeviceId emulator-5554`. 화면 캡처도 필요하면 Action을 visual로 바꿈. 기존 pose 테스트는 기본 Suite로 유지.
- 실제 출력 크기는 240×320(3:4), 426×240(16:9 짝수 반올림), 회전 입력 240×320. 길이 4초 유지. H.264 확인 후 완료 처리. 색상 사분면의 중앙 픽셀을 비교해 시간별 크롭 위치와 회전 방향 검증.
- 개인 27.417초 영상으로 `scripts/android_phase2.ps1 -Action visual` 검증 통과. Full 분석·추가 영역·사람 선택·3:4 크롭·MP4·갤러리 저장·결과 12초 재생·화면 복귀, Lite 번호 유지 확인.
- 결과는 720×960 / 약 19.9MB / 소리 포함. 캡처: build/phase2-screenshots/phase3-export-complete.png, phase3-export-playback.png. 개인 영상은 Git에 포함하지 않음.
- 초기 실제 화면 테스트에서 잠금 전환 중 접근성 트리 오류를 발견하고 컨트롤 노드 연결을 수정. 후속 실제 영상 검증과 접근성 포함 화면 테스트 통과. 오류를 무시하거나 접근성을 끄지 않음.
- 테스트용 개인 영상은 pubspec에 임시로만 포함하고 복구. 마지막 일반 APK에는 개인 fixture가 없음을 확인하고 다시 설치.

미검증: Android 7~9 실제 저장창, 실기기별 인코더·공간 부족·HDR·가변 프레임·다중 오디오. iOS 실제 빌드는 별도 Mac 검증 필요. 기본 출력은 MP4/H.264이며 H.265 선택은 이번 범위에 포함하지 않음.
