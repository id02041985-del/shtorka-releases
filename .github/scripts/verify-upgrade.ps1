param(
    [ValidateSet('rehearsal','candidate')][string]$Mode,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$OldVersion,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$NewVersion,
    [string]$ExpectedNewSha256,
    [long]$ExpectedNewBytes,
    [string]$SourceSha
)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases') {
    throw 'Verification requires the public GitHub-hosted Windows runner.'
}
$repo = 'id02041985-del/shtorka-releases'
$work = Join-Path $env:RUNNER_TEMP 'drape-upgrade'
New-Item -ItemType Directory -Path $work -Force | Out-Null
# Retry only read operations. Every completed installer is still checked against
# the exact asset size/digest and candidate dispatch before it can be executed.
function Invoke-ReadRetry([string]$stage, [scriptblock]$read) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return (& $read) }
        catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($_.Exception.Data['NoRetry'] -or $attempt -eq 3 -or ($status -ge 400 -and $status -lt 500 -and $status -notin @(408,429))) {
                throw "$stage failed after $attempt read attempt(s); HTTP status $status. No installer was executed."
            }
            Write-Host "$stage read interrupted (attempt $attempt/3); retrying."
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}
function Get-Release([string]$version, [bool]$draft = $false) {
    $headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($draft) {
        # The tags endpoint returns 404 for unpublished releases. Resolve only
        # this exact draft from the authenticated list, then fetch its exact ID.
        $releases = Invoke-ReadRetry 'Draft release list' {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=100" -Headers $headers -TimeoutSec 60
        }
        $matches = @($releases | Where-Object { $_.tag_name -ceq "v$version" })
        if ($matches.Count -ne 1 -or !$matches[0].draft -or $matches[0].id -le 0) { throw 'Candidate draft identity missing.' }
        $url = "https://api.github.com/repos/$repo/releases/$($matches[0].id)"
    } else { $url = "https://api.github.com/repos/$repo/releases/tags/v$version" }
    Invoke-ReadRetry 'Release metadata' { Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60 }
}
function Get-Installer([string]$version,[bool]$requirePublished,[string]$path) {
    $release = Get-Release $version (!$requirePublished)
    if (!$requirePublished -and (!$release.draft -or $release.id -le 0)) { throw 'Candidate draft identity mismatch.' }
    if ($release.tag_name -cne "v$version" -or ($requirePublished -and $release.draft)) { throw 'Unexpected release identity or draft status.' }
    $name = "Shtorka-$version-Setup-x64.exe"
    $asset = @($release.assets | Where-Object name -CEQ $name)
    if ($asset.Count -ne 1 -or $asset[0].size -le 1000000 -or $asset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Installer asset metadata is missing.' }
    if ($release.draft) {
        if ($Mode -ne 'candidate') { throw 'Draft only allowed for candidate check.' }
        if (!(Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI unavailable.' }
        Invoke-ReadRetry 'Candidate installer download' {
            Remove-Item -LiteralPath (Join-Path $work $name) -Force -ErrorAction SilentlyContinue
            $nativeOutput = & gh release download "v$version" --repo $repo --pattern $name --dir $work --clobber 2>&1
            if ($LASTEXITCODE -ne 0) {
                $failure = [InvalidOperationException]::new('Candidate installer read failed.')
                if (($nativeOutput -join ' ') -match 'HTTP (401|403|404)') { $failure.Data['NoRetry'] = $true }
                throw $failure
            }
        }
        Move-Item -LiteralPath (Join-Path $work $name) -Destination $path -Force
    } else {
        Invoke-ReadRetry 'Published installer download' {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $path -TimeoutSec 600
        }
    }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $path).Length -ne $asset[0].size -or $sha -cne $asset[0].digest.Substring(7).ToLowerInvariant()) { throw 'Downloaded installer differs from release asset.' }
    return @{ Version=$version; Sha256=$sha; Bytes=[long]$asset[0].size; Draft=[bool]$release.draft }
}
function Get-CandidateBridgeCrx([string]$version,[string]$fixtureName = 'Obyezd.crx') {
    if ($fixtureName -cnotin @('Obyezd.crx','Obyezd-next.crx')) { throw 'Unexpected fixture.' }
    $release = Get-Release $version $true
    if ($release.tag_name -cne "v$version" -or !$release.draft -or $release.id -le 0) { throw 'Candidate bridge draft missing.' }
    $asset = @($release.assets | Where-Object name -CEQ $fixtureName)
    if ($asset.Count -ne 1 -or $asset[0].size -le 1000 -or
        $asset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Signed bridge fixture metadata missing.' }
    $path = Join-Path $work $fixtureName
    Invoke-ReadRetry 'Candidate bridge download' {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        $nativeOutput = & gh release download "v$version" --repo $repo --pattern $fixtureName --dir $work --clobber 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failure = [InvalidOperationException]::new('Candidate bridge read failed.')
            if (($nativeOutput -join ' ') -match 'HTTP (401|403|404)') { $failure.Data['NoRetry'] = $true }
            throw $failure
        }
    }
    if (!(Test-Path -LiteralPath $path) -or
        (Get-Item -LiteralPath $path).Length -ne $asset[0].size -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $asset[0].digest.Substring(7)) {
        throw 'Downloaded signed bridge fixture differs from unpublished asset.'
    }
    return $path
}
& (Join-Path $PSScriptRoot 'verify-download-retry.ps1')
$oldPath = Join-Path $work 'old.exe'
$newPath = Join-Path $work 'new.exe'
$old = Get-Installer $OldVersion $true $oldPath
$new = Get-Installer $NewVersion ($Mode -eq 'rehearsal') $newPath
if ($Mode -eq 'candidate') {
    if (!$new.Draft -or $ExpectedNewSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        $new.Sha256 -cne $ExpectedNewSha256.ToLowerInvariant() -or $new.Bytes -ne $ExpectedNewBytes -or
        $SourceSha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Candidate dispatch and draft asset mismatch.' }
}
$drawerRelease = [version]$NewVersion -ge [version]'0.12.22'
$bridgeCrx = if ($Mode -eq 'candidate') { Get-CandidateBridgeCrx $NewVersion } else { $null }
if ($Mode -eq 'candidate' -and [version]$NewVersion -ge [version]'0.12.26') {
    $nextCrx = Get-CandidateBridgeCrx $NewVersion 'Obyezd-next.crx'
}
# All private draft downloads are complete. Neither the ordinary app started
# by the installer nor any foreign desktop fixture may inherit workflow tokens.
foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
if ($drawerRelease) { & (Join-Path $PSScriptRoot 'prepare-chatgpt-fixture.ps1') }
$args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOOFFICECOMPONENT=1','/TASKS=desktopicon')
$process = Start-Process -FilePath $oldPath -ArgumentList $args -PassThru -WindowStyle Hidden
if (!$process.WaitForExit(180000) -or $process.ExitCode -ne 0) { throw 'Previous installer failed.' }
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A0685854-23AD-4E53-94CE-83EE616048BE}_is1'
$registered = Get-ItemProperty -LiteralPath $key
$appDir = $registered.InstallLocation.TrimEnd('\')
$exe = Join-Path $appDir 'Shtorka.exe'
if (!(Test-Path -LiteralPath $exe) -or [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion -notlike "$OldVersion*") { throw 'Previous version was not installed.' }
$profile = Join-Path $env:LOCALAPPDATA 'Shtorka'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$sentinel = Join-Path $profile 'upgrade-sentinel.txt'
[IO.File]::WriteAllText($sentinel, 'disposable upgrade sentinel')
# Keep an ordinary nonempty profile across the installer upgrade, then use it
# for the installed binary's actual rail startup and appearance checks.
$settings = Join-Path $profile 'settings.json'
@{
    Version = 1
    Sites = @(@{ Name='Fixture site'; Url='https://example.com/' })
    Programs = @(@{ Kind='EXE'; Name='Fixture program'; Path=(Join-Path $env:WINDIR 'System32\notepad.exe'); Mode='DIRECT' })
    Appearance = @{ IconSize=20; RailWidth=36; Opacity=1 }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settings -Encoding UTF8
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -LiteralPath $runKey -Name 'Shtorka' -Value ('"' + $exe + '"')
Remove-ItemProperty -LiteralPath $runKey -Name 'Drape' -ErrorAction SilentlyContinue
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Disposable runner has no user desktop path.' }
New-Item -ItemType Directory -Path $desktop -Force | Out-Null
$oldShortcut = Join-Path $desktop 'Шторка.lnk'
$newShortcut = Join-Path $desktop 'Drape.lnk'
$tempShortcut = Join-Path $desktop 'shtorka-test-old.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($tempShortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $appDir
$link.Save()
Move-Item -LiteralPath $tempShortcut -Destination $oldShortcut -Force
if ($Mode -eq 'candidate' -and [version]$NewVersion -ge [version]'0.12.26') {
    & (Join-Path $PSScriptRoot 'capture-frame-before.ps1') -Exe $exe -Directory $appDir -Profile $profile
}
$args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOOFFICECOMPONENT=1','/UPDATE=1','/TASKS=desktopicon')
$process = Start-Process -FilePath $newPath -ArgumentList $args -PassThru -WindowStyle Hidden
if (!$process.WaitForExit(180000) -or $process.ExitCode -ne 0) { throw 'Candidate installer failed.' }
$updated = Get-ItemProperty -LiteralPath $key
if ($updated.DisplayName -cne "Drape $NewVersion" -or $updated.InstallLocation.TrimEnd('\') -ine $appDir) { throw 'Upgrade changed app identity or directory.' }
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
if ($version.ProductVersion -notlike "$NewVersion*" -or $version.ProductName -cne 'Drape') { throw 'Installed candidate version or brand mismatch.' }
if ((Get-Content -LiteralPath $sentinel -Raw) -cne 'disposable upgrade sentinel') { throw 'Application profile changed.' }
if ((Get-ItemProperty -LiteralPath $runKey -Name 'Drape' -ErrorAction SilentlyContinue).Drape -cne ('"' + $exe + '"') -or
    (Get-ItemProperty -LiteralPath $runKey -Name 'Shtorka' -ErrorAction SilentlyContinue)) { throw 'Autostart migration failed.' }
if (Test-Path -LiteralPath $oldShortcut) { throw 'Old shortcut remained.' }
if (!(Test-Path -LiteralPath $newShortcut) -or $shell.CreateShortcut($newShortcut).TargetPath -ine $exe) { throw 'New shortcut missing or misdirected.' }
# /UPDATE=1 starts the ordinary installed app. Prove it stays up with the
# existing profile before closing it in this disposable runner for glyph tests.
$startupDeadline = (Get-Date).AddSeconds(20)
$ordinary = @()
do {
    $ordinary = @(Get-Process Shtorka -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $exe })
    if ($ordinary.Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $startupDeadline)
if ($ordinary.Count -ne 1) { throw 'Ordinary installed application did not start after upgrade.' }
Start-Sleep -Seconds 3
if ($ordinary[0].HasExited -or (Test-Path -LiteralPath (Join-Path $profile 'error.log'))) {
    throw 'Ordinary installed application failed during startup.'
}
$exitRequest = Start-Process -FilePath $exe -ArgumentList '--exit' -PassThru -Wait
if ($exitRequest.ExitCode -ne 0 -or !$ordinary[0].WaitForExit(15000)) { throw 'Disposable ordinary application did not exit cleanly.' }
function Verify-InstalledRail([string]$argument,[string]$reportName,[int]$expectedChecks,[int]$maximumChecks = $expectedChecks,
    [int]$timeoutMs = 60000,[string[]]$requiredChecks = @()) {
    $report = Join-Path $profile $reportName
    # A new process must produce its own proof, especially across stress cycles.
    Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $profile 'program-bounds-observation.json') -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $exe -WorkingDirectory $appDir -ArgumentList @($argument,'--data-dir',('"'+$profile+'"')) -PassThru
    try {
        $deadline = (Get-Date).AddMilliseconds($timeoutMs)
        $cleanupDeadline = $null
        do {
            if ($process.WaitForExit(1000)) { break }
            if ($argument -ceq '--verify-program-overlay' -and (Test-Path -LiteralPath $report)) {
                try {
                    $partial = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
                    if (!$cleanupDeadline -and @($partial | Where-Object name -CEQ 'Program operation checks complete; beginning safe shutdown').Count -gt 0) {
                        $cleanupDeadline = (Get-Date).AddSeconds(30)
                    }
                } catch { } # A concurrently written report is read again next second.
            }
        } while ((Get-Date) -lt $deadline -and (!$cleanupDeadline -or (Get-Date) -lt $cleanupDeadline))
        $completed = $process.HasExited
        if (!(Test-Path -LiteralPath $report) -or (Get-Item -LiteralPath $report).LastWriteTimeUtc -lt $process.StartTime.ToUniversalTime()) {
            throw "Installed application did not produce a fresh report for $argument"
        }
        # ConvertFrom-Json can return the root JSON array as one pipeline item
        # on Windows PowerShell. Assign first, then enumerate its elements.
        $results = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $report -Raw)
        if ($results -isnot [array]) { $results = @($results) }
        $pinObservation = Join-Path $profile 'program-pin-observation.json'
        if ($argument -ceq '--verify-program-overlay' -and (Test-Path -LiteralPath $pinObservation)) {
            $pin = Get-Content -LiteralPath $pinObservation -Raw | ConvertFrom-Json
            $validPinObservation = $pin.pid -eq $process.Id
            foreach ($pinField in @('entryPinned','buttonExists','buttonVisible','storedPin','railVisible','suppressed')) {
                if ($pin.$pinField -isnot [bool]) { $validPinObservation = $false }
            }
            if ($validPinObservation) {
                Write-Host "Native pin observation: entry=$($pin.entryPinned); control=$($pin.buttonExists); visible=$($pin.buttonVisible); saved=$($pin.storedPin); railVisible=$($pin.railVisible); suppressed=$($pin.suppressed)."
            }
        }
        $failed = @($results | Where-Object { $_.pass -ne $true })
        $boundsObservation = Join-Path $profile 'program-bounds-observation.json'
        if ($argument -ceq '--verify-program-overlay' -and (Test-Path -LiteralPath $boundsObservation)) {
            $bounds = Get-Content -LiteralPath $boundsObservation -Raw | ConvertFrom-Json
            $validBounds = $bounds.panelPid -eq $process.Id -and $bounds.fits -is [bool] -and
                $bounds.readTarget -is [bool] -and $bounds.readAnchor -is [bool]
            foreach ($field in @('attempt','requestedWidth','requestedHeight','actualWidth','actualHeight','anchorWidth','anchorHeight','deltaX','deltaY')) {
                if ($bounds.$field -isnot [int] -and $bounds.$field -isnot [long] -or [Math]::Abs([long]$bounds.$field) -gt 100000) { $validBounds = $false }
            }
            if ($validBounds) {
                Write-Host "Last bounded placement observation: attempt=$($bounds.attempt); fits=$($bounds.fits); requested=$($bounds.requestedWidth)x$($bounds.requestedHeight); actual=$($bounds.actualWidth)x$($bounds.actualHeight); currentAnchor=$($bounds.anchorWidth)x$($bounds.anchorHeight); delta=$($bounds.deltaX),$($bounds.deltaY); reads=$($bounds.readTarget),$($bounds.readAnchor)."
            }
        }
        if (!$completed -or $process.ExitCode -ne 0 -or $results.Count -lt $expectedChecks -or $results.Count -gt $maximumChecks -or $failed.Count -ne 0) {
            if (!$completed) {
                # Only this exact synthetic panel PID; bounded enum/numeric fields,
                # never memory dumps, window text, command lines or account data.
                try {
                    $process.Refresh()
                    Write-Host "Panel exit diagnostic: PID $($process.Id), threads $($process.Threads.Count)."
                    foreach ($marker in @($results | Where-Object { $_.name -cmatch '^Panel UI thread ID [0-9]+$' })) {
                        Write-Host ([string]$marker.name)
                    }
                    foreach ($marker in @($results | Where-Object { $_.name -cmatch '^(Warning dialog (starting|completed) category (OTHER|PROGRAM_MONITOR|PIN_OPEN|SETTINGS_SAVE|PROGRAM_LIST)|Unhandled dispatcher error dialog starting|Program list open failed code [A-Z_]{1,40})$' })) {
                        Write-Host ([string]$marker.name)
                    }
                    foreach ($thread in @($process.Threads | Select-Object -First 32)) {
                        $state = [string]$thread.ThreadState
                        $waitReason = if ($state -ceq 'Wait') { [string]$thread.WaitReason } else { 'NotWaiting' }
                        Write-Host "Panel thread $($thread.Id): $state / $waitReason."
                    }
                } catch { Write-Host 'Panel exit thread snapshot unavailable.' }
                & (Join-Path $PSScriptRoot 'diagnose-panel-exit.ps1') -Panel $process -ExpectedExe $exe -ReportPath $report
            }
            $reason = if ($failed.Count -ne 0) { [string]$failed[0].name } else { "Expected $expectedChecks..$maximumChecks checks, got $($results.Count)" }
            if ($reason -ceq 'Exception' -or !$completed) {
                # Cleanup checkpoints follow an exception; report the operation
                # immediately before the FIRST failure rather than masking it.
                $beforeFailure = @()
                foreach ($row in $results) {
                    if ($row.pass -ne $true) { break }
                    $beforeFailure += $row
                }
                $last = if ($beforeFailure.Count -gt 0) { [string]$beforeFailure[-1].name } else { 'no completed check' }
                $code = if ($failed.Count) { [string]$failed[0].reason } else { 'DESKTOP_TIMEOUT' }
                if ($code -cnotmatch '^[A-Z_]{1,40}$') { $code = 'UNCLASSIFIED' }
                $reason = "Stopped after $last ($($results.Count) results): $code"
            }
            throw "Installed rail startup or glyph check failed: $argument; $reason"
        }
        foreach ($required in $requiredChecks) {
            if (@($results | Where-Object { $_.pass -and $_.name -ceq $required }).Count -ne 1) {
                throw "Installed payload proof missing: $required"
            }
        }
        "$argument passed $($results.Count) checks in the final installed payload." |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    } finally {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

Verify-InstalledRail '--verify-utility-startup' 'utility-startup.json' 13
Verify-InstalledRail '--verify-utility-startup-restart' 'utility-startup-restart.json' 8
if ($Mode -eq 'candidate') {
    $env:SHTORKA_OBYEZD_TEST_PACKAGES = Split-Path $bridgeCrx -Parent
    try { Verify-InstalledRail '--verify-obyezd-bridge' 'obyezd-bridge-checks.json' 4 }
    finally { Remove-Item Env:SHTORKA_OBYEZD_TEST_PACKAGES -ErrorAction SilentlyContinue }
}
if ($Mode -eq 'candidate' -and [version]$NewVersion -ge [version]'0.12.26') {
    $env:SHTORKA_OBYEZD_TEST_PACKAGES = Split-Path $bridgeCrx -Parent
    try {
        Verify-InstalledRail '--verify-obyezd-refresh' 'obyezd-refresh.json' 32 32 180000 @(
            'Real Update button installs the newer signed official candidate',
            'Signed extension update preserves account bytes, rules and manual OFF',
            'Actual keyboard input saves a CurrentUser DPAPI account and clears the password field',
            'Production reconnect coordinator retries the saved account after its deadline using only the injected transport',
            'An injected helper authentication error pauses automatic retries even after resume'
        )
        $frame = Get-Content -LiteralPath (Join-Path $profile 'main-frame-drawer-metrics.json') -Raw | ConvertFrom-Json
        Write-Host "Updated actual drawer: left=$($frame.leftDip)DIP; bottom=$($frame.bottomDip)DIP; DPI=$($frame.dpi)."
        foreach ($viewportCase in (Get-Content -LiteralPath (Join-Path $profile 'main-frame-metrics.json') -Raw | ConvertFrom-Json)) {
            Write-Host "Actual client viewport $($viewportCase.state): left=$($viewportCase.leftDip)DIP; bottom=$($viewportCase.bottomDip)DIP; DPI=$($viewportCase.dpi); OS-scale-simulated=$($viewportCase.windowsScaleSimulated)."
        }
        Verify-InstalledRail '--verify-obyezd-refresh-restart' 'obyezd-refresh-restart.json' 5 5 90000
    } finally { Remove-Item Env:SHTORKA_OBYEZD_TEST_PACKAGES -ErrorAction SilentlyContinue }
}
if ($drawerRelease) {
    $cycles = if ([version]$NewVersion -ge [version]'0.12.23') { 3 } else { 1 }
    for ($cycle = 1; $cycle -le $cycles; $cycle++) {
        Verify-InstalledRail '--verify-program-overlay' 'program-overlay.json' 40 100 600000 @(
            'A real click on the ordinary Programs action opens the existing application in the shared drawer',
            'Closing and reopening the drawer preserves the same modal Save dialog',
            'Real input reaches the different-DPI program window in the shared drawer',
            'Transient native bounds rejection settles to the exact current drawer viewport before readiness',
            'Permanent native bounds rejection keeps the exact-fit guard and restores the ordinary window',
            'Destroying the drawer owner restores the ordinary application window with unsaved text',
            'Installed ChatGPT MSIX restores its ordinary window without changing its account or network mode'
        )
        Write-Host "Installed program lifecycle cycle $cycle/$cycles passed with normal panel exit0."
    }
} else {
    Verify-InstalledRail '--verify-program-operations' 'program-operations.json' 12 13
}
if (Test-Path -LiteralPath (Join-Path $profile 'error.log')) { throw 'Installed application logged a startup error.' }
"Installed upgrade $OldVersion -> $NewVersion passed on public GitHub-hosted Windows runner. Candidate SHA256: $($new.Sha256). Source: $SourceSha" |
    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

