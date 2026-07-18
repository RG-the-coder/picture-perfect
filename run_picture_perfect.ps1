[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$WebPort = 8765,

    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8000,

    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$backendProcess = $null
$backendLogOut = $null
$backendLogError = $null
$startedBackend = $false
$ownedBuildRoot = $null
$ownedBuildLink = $null
$launcherMutex = $null
$mutexAcquired = $false
$locationPushed = $false
$appDataChanged = $false
$originalAppData = [Environment]::GetEnvironmentVariable(
    'APPDATA',
    [EnvironmentVariableTarget]::Process
)
$hadOriginalAppData = $null -ne $originalAppData
$backendOrigin = "http://localhost:$WebPort"
$backendBaseUrl = "http://localhost:$BackendPort"
$healthUrl = "http://127.0.0.1:$BackendPort/healthz"
$wslDistribution = 'Ubuntu-24.04'
$flashPython = '/root/.local/share/uv/tools/freesolo-flash/bin/python3'

function Get-PicturePerfectBackendHealth {
    try {
        return Invoke-RestMethod -Uri $healthUrl -TimeoutSec 1
    }
    catch {
        return $null
    }
}

function Test-LocalTcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $connect.Wait(300)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Assert-CompatibleBackend {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Health,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedService,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedApiVersion,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedSchemaVersion,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedModelRevision
    )

    if (
        $Health.status -ne 'ok' -or
        $Health.service -ne $ExpectedService -or
        [int]$Health.apiVersion -ne $ExpectedApiVersion -or
        [int]$Health.schemaVersion -ne $ExpectedSchemaVersion -or
        $Health.inputModality -ne 'structured-measurements'
    ) {
        throw "Port $BackendPort is serving an incompatible or stale backend. Stop that process and run this launcher again."
    }
    if ($Health.freesoloConfigured -ne $true) {
        throw "Port $BackendPort has Picture Perfect running without the trained model configured. Stop that process and run this launcher again."
    }
    if (-not [string]::Equals(
        [string]$Health.modelRevision,
        $ExpectedModelRevision,
        [StringComparison]::Ordinal
    )) {
        throw "Port $BackendPort is using a different model revision. Stop that process and run this launcher again."
    }
    if (@($Health.allowedOrigins) -notcontains $backendOrigin) {
        throw "Port $BackendPort does not allow the Flutter origin $backendOrigin. Stop that process and run this launcher again."
    }
    $knownStartupStatuses = @(
        'not-probed',
        'unavailable',
        'responded-rejected',
        'validated'
    )
    if ($knownStartupStatuses -notcontains $Health.startupModelStatus) {
        throw "Port $BackendPort returned an invalid model warm-up status. Stop that process and run this launcher again."
    }
}

try {
    if ($WebPort -eq $BackendPort) {
        throw 'The web and backend ports must be different.'
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
        throw 'Picture Perfect is already starting or running from another launcher. Close that launcher before starting a second copy.'
    }

    if (Test-LocalTcpPort -Port $WebPort) {
        throw "Web port $WebPort is already in use. Close the existing Flutter/browser development session or choose another -WebPort."
    }

    $desktopRoot = Split-Path -Parent $PSScriptRoot
    $backendWindowsPath = Join-Path $desktopRoot 'pictureperfectaibackend'
    if (-not (Test-Path -LiteralPath $backendWindowsPath -PathType Container)) {
        throw "Could not find the backend at $backendWindowsPath"
    }
    $resolvedBackendPath = (Resolve-Path -LiteralPath $backendWindowsPath).Path
    $deploymentPath = Join-Path $resolvedBackendPath 'backend\deployment.json'
    if (-not (Test-Path -LiteralPath $deploymentPath -PathType Leaf)) {
        throw "The pinned deployment manifest is missing: $deploymentPath"
    }
    try {
        $deployment = Get-Content -LiteralPath $deploymentPath -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "The pinned deployment manifest is invalid: $deploymentPath"
    }
    $expectedService = [string]$deployment.service
    $expectedApiVersion = [int]$deployment.apiVersion
    $expectedSchemaVersion = [int]$deployment.schemaVersion
    $expectedModelRevision = [string]$deployment.modelRevision
    $deploymentBaseUrl = [Uri]([string]$deployment.baseUrl)
    if (
        $expectedService -ne 'picture-perfect-analysis' -or
        $expectedApiVersion -ne 1 -or
        $expectedSchemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace($expectedModelRevision) -or
        $deploymentBaseUrl.Scheme -ne 'https'
    ) {
        throw "The pinned deployment manifest is incompatible: $deploymentPath"
    }

    $health = Get-PicturePerfectBackendHealth
    if ($null -ne $health) {
        Assert-CompatibleBackend `
            -Health $health `
            -ExpectedService $expectedService `
            -ExpectedApiVersion $expectedApiVersion `
            -ExpectedSchemaVersion $expectedSchemaVersion `
            -ExpectedModelRevision $expectedModelRevision
        Write-Host "Using the compatible Picture Perfect backend already running on port $BackendPort."
    }
    else {
        if (Test-LocalTcpPort -Port $BackendPort) {
            throw "Backend port $BackendPort is already used by another service. Stop it or choose another -BackendPort."
        }
        if ($resolvedBackendPath -notmatch '^(?<Drive>[A-Za-z]):\\(?<Rest>.+)$') {
            throw "The backend must be on a Windows drive that WSL can mount: $resolvedBackendPath"
        }
        $driveLetter = $Matches.Drive.ToLowerInvariant()
        $relativeWslPath = $Matches.Rest.Replace('\', '/')
        $backendWslPath = "/mnt/$driveLetter/$relativeWslPath"
        if ($backendWslPath -match '\s') {
            throw 'The current WSL launcher requires a backend path without spaces.'
        }

        $distributions = & wsl.exe --list --quiet 2>$null
        $wslListExitCode = $LASTEXITCODE
        $distributionNames = @(
            $distributions | ForEach-Object { ($_ -replace "`0", '').Trim() }
        )
        if (
            $wslListExitCode -ne 0 -or
            $distributionNames -notcontains $wslDistribution
        ) {
            throw "WSL distribution $wslDistribution is unavailable. Start WSL once, then rerun this launcher."
        }

        & wsl.exe -d $wslDistribution -u root -- test -x $flashPython
        $flashCheckExitCode = $LASTEXITCODE
        if ($flashCheckExitCode -ne 0) {
            throw "FreeSolo Flash is missing in $wslDistribution. Install freesolo-flash and run flash login there first."
        }
        & wsl.exe -d $wslDistribution -u root -- test -f "$backendWslPath/backend/run_local_with_flash.py"
        $backendCheckExitCode = $LASTEXITCODE
        if ($backendCheckExitCode -ne 0) {
            throw "WSL cannot read the Picture Perfect backend at $backendWslPath."
        }

        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; launcher logs cannot be created.'
        }
        $logRoot = Join-Path $env:LOCALAPPDATA 'PicturePerfect\logs'
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $logStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backendLogOut = Join-Path $logRoot "backend-$logStamp.out.log"
        $backendLogError = Join-Path $logRoot "backend-$logStamp.err.log"

        $backendArguments = @(
            '-d', $wslDistribution,
            '-u', 'root',
            '--cd', $backendWslPath,
            '--',
            $flashPython,
            'backend/run_local_with_flash.py',
            '--host', '127.0.0.1',
            '--port', "$BackendPort",
            '--allowed-origin', $backendOrigin
        )
        Write-Host 'Starting the trained 4B backend on local-only networking...'
        $backendProcess = Start-Process `
            -FilePath 'wsl.exe' `
            -ArgumentList $backendArguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $backendLogOut `
            -RedirectStandardError $backendLogError `
            -PassThru
        $startedBackend = $true

        $health = $null
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            Start-Sleep -Milliseconds 500
            $backendProcess.Refresh()
            if ($backendProcess.HasExited) {
                throw "The backend exited before becoming ready. Details: $backendLogError"
            }
            $health = Get-PicturePerfectBackendHealth
            if ($null -ne $health) {
                break
            }
        }
        if ($null -eq $health) {
            throw "The backend did not become ready within 45 seconds. Details: $backendLogError"
        }
        Assert-CompatibleBackend `
            -Health $health `
            -ExpectedService $expectedService `
            -ExpectedApiVersion $expectedApiVersion `
            -ExpectedSchemaVersion $expectedSchemaVersion `
            -ExpectedModelRevision $expectedModelRevision
    }

    if ($health.startupModelStatus -eq 'validated') {
        Write-Host 'The pinned trained backend completed a validated warm-up and is ready.'
    }
    elseif ($health.startupModelStatus -eq 'responded-rejected') {
        Write-Host 'The pinned model responded; its non-exact warm-up plan was safely replaced by the canonical fallback.'
    }
    else {
        $logHint = if ($null -ne $backendLogError) {
            " Backend log: $backendLogError"
        }
        else {
            ''
        }
        Write-Warning "The pinned model did not answer its startup warm-up. The app will retry it automatically for every completed photo and use the safe local fallback until FreeSolo is reachable.$logHint"
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; cannot create the OneDrive-safe Flutter cache.'
    }
    $buildToken = "$PID-$([Guid]::NewGuid().ToString('N'))"
    $localBuildRoot = Join-Path `
        $env:LOCALAPPDATA `
        "PicturePerfect\flutter_runs\$buildToken"
    $ownedBuildRoot = $localBuildRoot
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

    $projectBuildName = ".picture_perfect_build_$buildToken"
    $projectBuildLink = Join-Path $PSScriptRoot $projectBuildName
    if (Test-Path -LiteralPath $projectBuildLink) {
        throw "The unique build-cache path already exists: $projectBuildLink"
    }
    New-Item `
        -ItemType Junction `
        -Path $projectBuildLink `
        -Target $localBuildRoot | Out-Null
    $ownedBuildLink = $projectBuildLink

    $privateFlutterConfig = Join-Path $env:LOCALAPPDATA 'PicturePerfect\flutter_config'
    New-Item -ItemType Directory -Path $privateFlutterConfig -Force | Out-Null
    $env:APPDATA = $privateFlutterConfig
    $appDataChanged = $true
    & flutter config --enable-web "--build-dir=$projectBuildName" | Out-Null
    $flutterConfigExitCode = $LASTEXITCODE
    if ($flutterConfigExitCode -ne 0) {
        throw 'Could not configure the isolated OneDrive-safe Flutter build cache.'
    }

    if (Test-LocalTcpPort -Port $WebPort) {
        throw "Web port $WebPort became occupied before Flutter could start. Close the conflicting process and try again."
    }
    Push-Location $PSScriptRoot
    $locationPushed = $true
    if ($VerifyOnly) {
        Write-Host 'Verifying the exact Chrome startup path in headless mode...'
        & flutter run `
            -d chrome `
            --no-resident `
            --web-run-headless `
            --web-port $WebPort `
            "--dart-define=PICTUREPERFECT_API_BASE_URL=$backendBaseUrl"
        $flutterExitCode = $LASTEXITCODE
        if ($flutterExitCode -ne 0) {
            throw "Flutter Chrome verification exited with code $flutterExitCode."
        }
        Write-Host 'Automatic backend, model, shader, and Chrome startup verification passed.'
    }
    else {
        Write-Host 'Starting Picture Perfect in Chrome...'
        & flutter run `
            -d chrome `
            --web-port $WebPort `
            "--dart-define=PICTUREPERFECT_API_BASE_URL=$backendBaseUrl"
        $flutterExitCode = $LASTEXITCODE
        if ($flutterExitCode -ne 0) {
            throw "Flutter exited with code $flutterExitCode."
        }
    }
}
finally {
    if ($locationPushed) {
        try {
            Pop-Location
        }
        catch {
            Write-Warning "Could not restore the launcher working directory: $($_.Exception.Message)"
        }
    }

    if ($appDataChanged) {
        try {
            if ($hadOriginalAppData) {
                $env:APPDATA = $originalAppData
            }
            else {
                Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "Could not restore the process APPDATA value: $($_.Exception.Message)"
        }
    }

    if ($null -ne $ownedBuildLink -or $null -ne $ownedBuildRoot) {
        try {
            $linkRemoved = $true
            if ($null -ne $ownedBuildLink -and (Test-Path -LiteralPath $ownedBuildLink)) {
                $ownedLinkItem = Get-Item -LiteralPath $ownedBuildLink -Force
                $ownedLinkTarget = @($ownedLinkItem.Target) |
                    Select-Object -First 1
                if (
                    $ownedLinkItem.LinkType -ne 'Junction' -or
                    $null -eq $ownedBuildRoot -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath($ownedLinkTarget),
                        [IO.Path]::GetFullPath($ownedBuildRoot),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $linkRemoved = $false
                    Write-Warning "The launcher-owned build link changed unexpectedly and was preserved: $ownedBuildLink"
                }
                else {
                    $ownedLinkAttributes = [IO.File]::GetAttributes(
                        $ownedBuildLink
                    )
                    [IO.File]::SetAttributes(
                        $ownedBuildLink,
                        (
                            $ownedLinkAttributes -band
                            (-bnot [IO.FileAttributes]::ReadOnly)
                        )
                    )
                    [IO.Directory]::Delete($ownedBuildLink, $false)
                }
            }
            if ($linkRemoved -and $null -ne $ownedBuildRoot -and (Test-Path -LiteralPath $ownedBuildRoot)) {
                $runsRoot = [IO.Path]::GetFullPath(
                    (Join-Path $env:LOCALAPPDATA 'PicturePerfect\flutter_runs')
                ).TrimEnd('\') + '\'
                $resolvedOwnedBuildRoot = [IO.Path]::GetFullPath($ownedBuildRoot)
                if (-not $resolvedOwnedBuildRoot.StartsWith(
                    $runsRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    throw 'The launcher-owned build cache resolved outside flutter_runs.'
                }
                Remove-Item `
                    -LiteralPath $resolvedOwnedBuildRoot `
                    -Recurse `
                    -Force
            }
        }
        catch {
            Write-Warning "The unique generated build cache could not be removed and was left in place: $($_.Exception.Message)"
        }
    }

    if ($startedBackend -and $null -ne $backendProcess) {
        try {
            $backendProcess.Refresh()
            if (-not $backendProcess.HasExited) {
                Write-Host 'Stopping the backend started by this launcher...'
                Stop-Process -Id $backendProcess.Id -ErrorAction SilentlyContinue
                Wait-Process `
                    -Id $backendProcess.Id `
                    -Timeout 5 `
                    -ErrorAction SilentlyContinue
            }
            $remainingHealth = Get-PicturePerfectBackendHealth
            for (
                $attempt = 0;
                $attempt -lt 20 -and $null -ne $remainingHealth;
                $attempt++
            ) {
                Start-Sleep -Milliseconds 250
                $remainingHealth = Get-PicturePerfectBackendHealth
            }
            if ($null -ne $remainingHealth) {
                Write-Warning "The backend is still reachable on port $BackendPort. Stop only that backend before launching again."
            }
        }
        catch {
            Write-Warning "Backend cleanup could not be verified: $($_.Exception.Message)"
        }
    }

    if ($mutexAcquired -and $null -ne $launcherMutex) {
        try {
            $launcherMutex.ReleaseMutex()
        }
        catch {
            Write-Warning "Could not release the Picture Perfect launcher lock: $($_.Exception.Message)"
        }
    }
    if ($null -ne $launcherMutex) {
        $launcherMutex.Dispose()
    }
}
