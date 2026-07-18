[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$ErrorActionPreference = 'Stop'
$launcherMutex = $null
$mutexAcquired = $false
$locationPushed = $false
$originalAppData = [Environment]::GetEnvironmentVariable(
    'APPDATA',
    [EnvironmentVariableTarget]::Process
)
$hadOriginalAppData = $null -ne $originalAppData
$exitCode = 1
$workingRoot = $PSScriptRoot

try {
    if ($null -eq $FlutterArguments -or $FlutterArguments.Count -eq 0) {
        throw 'Supply a Flutter command, for example: .\flutter_safe.cmd test'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; cannot create the OneDrive-safe Flutter cache.'
    }

    $launcherMutex = [System.Threading.Mutex]::new(
        $false,
        'Local\PicturePerfectLauncher'
    )
    try {
        $mutexAcquired = $launcherMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexAcquired = $true
    }
    if (-not $mutexAcquired) {
        throw 'Another Picture Perfect launcher or Flutter command is already running.'
    }

    $localBuildRoot = Join-Path $env:LOCALAPPDATA 'PicturePerfect\flutter_build'
    New-Item -ItemType Directory -Path $localBuildRoot -Force | Out-Null
    $writeProbe = Join-Path $localBuildRoot ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($writeProbe, 'ok', [Text.Encoding]::ASCII)
    }
    finally {
        if ([IO.File]::Exists($writeProbe)) {
            [IO.File]::Delete($writeProbe)
        }
    }

    $projectBuildLink = Join-Path $PSScriptRoot '.picture_perfect_build'
    if (Test-Path -LiteralPath $projectBuildLink) {
        $buildLink = Get-Item -LiteralPath $projectBuildLink -Force
        $linkTarget = @($buildLink.Target) | Select-Object -First 1
        if (
            $buildLink.LinkType -ne 'Junction' -or
            [string]::IsNullOrWhiteSpace($linkTarget) -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath($linkTarget),
                [IO.Path]::GetFullPath($localBuildRoot),
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "$projectBuildLink exists but is not the expected build-cache junction. Move it aside and try again."
        }
    }
    else {
        New-Item `
            -ItemType Junction `
            -Path $projectBuildLink `
            -Target $localBuildRoot | Out-Null
    }

    $privateFlutterConfig = Join-Path $env:LOCALAPPDATA 'PicturePerfect\flutter_config'
    New-Item -ItemType Directory -Path $privateFlutterConfig -Force | Out-Null
    $env:APPDATA = $privateFlutterConfig
    & flutter config --enable-web '--build-dir=.picture_perfect_build' | Out-Null
    $configExitCode = $LASTEXITCODE
    if ($configExitCode -ne 0) {
        throw 'Could not configure the isolated OneDrive-safe Flutter build cache.'
    }

    # Flutter 3.44 hard-codes build/unit_test_assets for `flutter test` and
    # ignores its configured build directory. Run tests from a synchronized
    # local mirror so that path never touches OneDrive.
    if ($FlutterArguments[0] -eq 'test') {
        $testMirrorRoot = Join-Path $env:LOCALAPPDATA 'PicturePerfect\test_workspace'
        $expectedMirrorRoot = [IO.Path]::GetFullPath(
            (Join-Path $env:LOCALAPPDATA 'PicturePerfect')
        ).TrimEnd('\') + '\'
        $resolvedMirrorRoot = [IO.Path]::GetFullPath($testMirrorRoot)
        if (-not $resolvedMirrorRoot.StartsWith(
            $expectedMirrorRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'The local Flutter test mirror resolved outside PicturePerfect.'
        }
        New-Item -ItemType Directory -Path $resolvedMirrorRoot -Force | Out-Null
        & robocopy `
            $PSScriptRoot `
            $resolvedMirrorRoot `
            /MIR `
            /XJ `
            /R:2 `
            /W:1 `
            /NFL `
            /NDL `
            /NJH `
            /NJS `
            /NP `
            /XD .git .dart_tool build .picture_perfect_build `
            /XF '*.log' | Out-Null
        $robocopyExitCode = $LASTEXITCODE
        if ($robocopyExitCode -ge 8) {
            throw "Could not synchronize the local Flutter test mirror (robocopy exit $robocopyExitCode)."
        }
        $workingRoot = $resolvedMirrorRoot
    }

    Push-Location $workingRoot
    $locationPushed = $true
    & flutter @FlutterArguments
    $exitCode = $LASTEXITCODE
}
finally {
    if ($locationPushed) {
        try {
            Pop-Location
        }
        catch {
            Write-Warning "Could not restore the Flutter wrapper directory: $($_.Exception.Message)"
        }
    }
    try {
        if ($hadOriginalAppData) {
            $env:APPDATA = $originalAppData
        }
        else {
            Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Warning "Could not restore the Flutter wrapper APPDATA value: $($_.Exception.Message)"
    }
    if ($mutexAcquired -and $null -ne $launcherMutex) {
        try {
            $launcherMutex.ReleaseMutex()
        }
        catch {
            Write-Warning "Could not release the Picture Perfect Flutter lock: $($_.Exception.Message)"
        }
    }
    if ($null -ne $launcherMutex) {
        $launcherMutex.Dispose()
    }
}

exit $exitCode
