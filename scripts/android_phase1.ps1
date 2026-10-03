param(
    [ValidateSet('build', 'run', 'integration')]
    [string]$Action = 'build',
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$javaTemp = Join-Path $projectRoot 'build\jtmp'
New-Item -ItemType Directory -Path $javaTemp -Force | Out-Null
$previousJavaOptions = $env:JAVA_TOOL_OPTIONS

# Windows/JDK 25에서 임시 소켓 경로가 길면 연결 오류가 나므로 짧은 경로를 씁니다.
# 이 스크립트로 실행하는 프로그램에만 적용하고 종료 시 원래 환경 변수를 복구합니다.
$env:JAVA_TOOL_OPTIONS = '-Djava.io.tmpdir="' + $javaTemp + '" -Djdk.net.unixdomain.tmpdir="' + $javaTemp + '"'
Push-Location -LiteralPath $projectRoot
try {
    if ($Action -ne 'build' -and [string]::IsNullOrWhiteSpace($DeviceId)) {
        throw 'flutter devices에서 Android DeviceId를 확인하고 -DeviceId로 지정해주세요.'
    }
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 실패' }

    switch ($Action) {
        'build' { & flutter build apk --debug --no-pub }
        'run' { & flutter run -d $DeviceId --no-pub }
        'integration' { & flutter test integration_test/media_preview_test.dart -d $DeviceId --no-pub }
    }
    if ($LASTEXITCODE -ne 0) { throw "Flutter $Action 실패 (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
    $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
}
