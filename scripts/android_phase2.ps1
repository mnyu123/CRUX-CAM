param(
    [ValidateSet('build', 'run', 'integration', 'visual')]
    [string]$Action = 'build',
    [string]$DeviceId,
    [string]$VideoPath,
    [string]$LocalVideoPath,
    [ValidateSet('pose', 'export')]
    [string]$Suite = 'pose'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$javaTemp = Join-Path $projectRoot 'build\jtmp'
New-Item -ItemType Directory -Path $javaTemp -Force | Out-Null
$previousJavaOptions = $env:JAVA_TOOL_OPTIONS
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$pubspecBackup = $null
# 긴 Windows 임시 경로에서 발생하는 JDK 소켓 오류를 피하고 원래 설정은 복구합니다.
$env:JAVA_TOOL_OPTIONS = '-Djava.io.tmpdir="' + $javaTemp + '" -Djdk.net.unixdomain.tmpdir="' + $javaTemp + '"'
Push-Location -LiteralPath $projectRoot
try {
    if (-not [string]::IsNullOrWhiteSpace($LocalVideoPath)) {
        if ($Suite -eq 'export') { throw 'export 테스트는 합성 영상을 사용하므로 LocalVideoPath를 받지 않습니다.' }
        if ($Action -notin @('integration', 'visual')) { throw 'LocalVideoPath는 integration 또는 visual에서만 사용합니다.' }
        $sourceVideo = (Resolve-Path -LiteralPath $LocalVideoPath).Path
        $fixturePath = Join-Path $projectRoot 'build\phase2-fixtures\climbing.mp4'
        New-Item -ItemType Directory -Path (Split-Path $fixturePath) -Force | Out-Null
        if ($sourceVideo -ne $fixturePath) { Copy-Item -LiteralPath $sourceVideo -Destination $fixturePath -Force }
        # 개인 영상은 테스트 빌드에만 임시로 포함하고 pubspec은 실행 후 정확히 복구합니다.
        $pubspecBackup = [IO.File]::ReadAllBytes($pubspecPath)
        $spec = [IO.File]::ReadAllText($pubspecPath)
        $spec += "`n    - build/phase2-fixtures/climbing.mp4`n"
        [IO.File]::WriteAllText($pubspecPath, $spec, [Text.UTF8Encoding]::new($false))
    }
    if ($Action -ne 'build' -and [string]::IsNullOrWhiteSpace($DeviceId)) {
        throw 'flutter devices에서 확인한 DeviceId를 지정해주세요.'
    }
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 실패' }
    switch ($Action) {
        'build' { & flutter build apk --debug --no-pub }
        'run' { & flutter run -d $DeviceId --no-pub }
        { $_ -in @('integration', 'visual') } {
            $testTarget = if ($Suite -eq 'export') { 'integration_test/export_test.dart' } else { 'integration_test/pose_analysis_test.dart' }
            $testArgs = if ($Action -eq 'visual') {
                @('drive', '--driver=test_driver/pose_driver.dart', "--target=$testTarget", '-d', $DeviceId, '--no-pub', '--dart-define=CRUX_TEST_UI_ONLY=true')
            } else {
                @('test', $testTarget, '-d', $DeviceId, '--no-pub')
            }
            # 경로는 PC 경로가 아니라 테스트 앱이 읽을 수 있는 기기 내부 파일 경로입니다.
            if (-not [string]::IsNullOrWhiteSpace($VideoPath)) {
                $testArgs += '--dart-define=CRUX_TEST_VIDEO_PATH=' + $VideoPath
            }
            if (-not [string]::IsNullOrWhiteSpace($LocalVideoPath)) {
                $testArgs += '--dart-define=CRUX_TEST_VIDEO_ASSET=build/phase2-fixtures/climbing.mp4'
            }
            & flutter @testArgs
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "Flutter $Action 실패 (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
    $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
    if ($null -ne $pubspecBackup) { [IO.File]::WriteAllBytes($pubspecPath, $pubspecBackup) }
}
