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
function Get-Release([string]$version) {
    $headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
    Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/v$version" -Headers $headers -TimeoutSec 60
}
function Get-Installer([string]$version,[bool]$requirePublished,[string]$path) {
    if ($requirePublished) {
        $release = Get-Release $version
    } else {
        $draftJson = & gh release view "v$version" --repo $repo --json databaseId,isDraft,tagName
        if ($LASTEXITCODE -ne 0) { throw 'Candidate draft could not be resolved.' }
        $draftInfo = $draftJson | ConvertFrom-Json
        if (!$draftInfo.isDraft -or $draftInfo.tagName -cne "v$version" -or $draftInfo.databaseId -le 0) { throw 'Candidate draft identity mismatch.' }
        $headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/$($draftInfo.databaseId)" -Headers $headers -TimeoutSec 60
    }
    if ($release.tag_name -cne "v$version" -or ($requirePublished -and $release.draft)) { throw 'Unexpected release identity or draft status.' }
    $name = "Shtorka-$version-Setup-x64.exe"
    $asset = @($release.assets | Where-Object name -CEQ $name)
    if ($asset.Count -ne 1 -or $asset[0].size -le 1000000 -or $asset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Installer asset metadata is missing.' }
    if ($release.draft) {
        if ($Mode -ne 'candidate') { throw 'Draft only allowed for candidate check.' }
        if (!(Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI unavailable.' }
        & gh release download "v$version" --repo $repo --pattern $name --dir $work
        if ($LASTEXITCODE -ne 0) { throw 'Draft installer download failed.' }
        Move-Item -LiteralPath (Join-Path $work $name) -Destination $path -Force
    } else {
        Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $path -TimeoutSec 600
    }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $path).Length -ne $asset[0].size -or $sha -cne $asset[0].digest.Substring(7).ToLowerInvariant()) { throw 'Downloaded installer differs from release asset.' }
    return @{ Version=$version; Sha256=$sha; Bytes=[long]$asset[0].size; Draft=[bool]$release.draft }
}
$oldPath = Join-Path $work 'old.exe'
$newPath = Join-Path $work 'new.exe'
$old = Get-Installer $OldVersion $true $oldPath
$new = Get-Installer $NewVersion ($Mode -eq 'rehearsal') $newPath
if ($Mode -eq 'candidate') {
    if (!$new.Draft -or $ExpectedNewSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        $new.Sha256 -cne $ExpectedNewSha256.ToLowerInvariant() -or $new.Bytes -ne $ExpectedNewBytes -or
        $SourceSha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Candidate dispatch and draft asset mismatch.' }
}
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
function Verify-InstalledRail([string]$argument,[string]$reportName,[int]$expectedChecks,[int]$maximumChecks = $expectedChecks) {
    $report = Join-Path $profile $reportName
    $process = Start-Process -FilePath $exe -ArgumentList @($argument,'--data-dir',('"'+$profile+'"')) -PassThru
    try {
        if (!$process.WaitForExit(60000)) { throw "Installed application startup timed out: $argument" }
        if ($process.ExitCode -ne 0) { throw "Installed application exited with code $($process.ExitCode): $argument" }
        if (!(Test-Path -LiteralPath $report)) { throw "Installed application did not complete $argument" }
        # ConvertFrom-Json can return the root JSON array as one pipeline item
        # on Windows PowerShell. Assign first, then enumerate its elements.
        $results = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $report -Raw)
        if ($results -isnot [array]) { $results = @($results) }
        $failed = @($results | Where-Object { $_.pass -ne $true })
        if ($results.Count -lt $expectedChecks -or $results.Count -gt $maximumChecks -or $failed.Count -ne 0) {
            $reason = if ($failed.Count -ne 0) { [string]$failed[0].name } else { "Expected $expectedChecks..$maximumChecks checks, got $($results.Count)" }
            if ($reason -ceq 'Exception') {
                $passed = @($results | Where-Object { $_.pass -eq $true })
                $last = if ($passed.Count -gt 0) { [string]$passed[-1].name } else { 'no completed check' }
                $detail = [string]$failed[0].detail
                $detail = $detail -replace '(?i)[a-z]:\\[^\s;]+', '[path]' -replace '(?i)https?://\S+', '[url]'
                $detail = $detail -replace '(?i)(Bearer|Authorization|Token)\S*', '[redacted]' -replace '[\r\n]', ' '
                if ($detail.Length -gt 100) { $detail = $detail.Substring(0, 100) }
                $reason = "Exception after $last ($($results.Count) results): $detail"
            }
            throw "Installed rail startup or glyph check failed: $argument; $reason"
        }
    } finally {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Get-DisposableHostCrashState([string]$installedExe) {
    $fixture = $null
    $hostProcess = $null
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('drape-host-probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $journal = Join-Path $folder 'window.json'
    $ready = Join-Path $folder 'attached.ready'
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DrapeHostProbe {
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
}
'@
        $fixture = Start-Process -FilePath $installedExe -ArgumentList '--program-test-window' -PassThru
        $window = [IntPtr]::Zero
        for ($i = 0; $i -lt 100 -and $window -eq [IntPtr]::Zero -and !$fixture.HasExited; $i++) {
            Start-Sleep -Milliseconds 100
            $fixture.Refresh()
            $window = $fixture.MainWindowHandle
        }
        if ($window -eq [IntPtr]::Zero) { return 'fixture_window_missing' }
        $arguments = @('--program-holder-crash', [string]$window.ToInt64(), ('"' + $journal + '"'), ('"' + $ready + '"'))
        $hostProcess = Start-Process -FilePath $installedExe -ArgumentList $arguments -PassThru
        for ($i = 0; $i -lt 100 -and !(Test-Path -LiteralPath $ready) -and !$hostProcess.HasExited; $i++) {
            Start-Sleep -Milliseconds 100
        }
        if (!(Test-Path -LiteralPath $ready)) { return 'host_attach_failed' }
        $hostWindow = [DrapeHostProbe]::GetParent($window)
        Stop-Process -Id $hostProcess.Id -Force
        $null = $hostProcess.WaitForExit(10000)
        Start-Sleep -Milliseconds 300
        $alive = [DrapeHostProbe]::IsWindow($window)
        $after = if ($alive) { [DrapeHostProbe]::GetParent($window) } else { [IntPtr]::Zero }
        $parentKind = if (!$alive) { 'no_target' } elseif ($after -eq [IntPtr]::Zero) { 'none' }
            elseif ($after -eq [DrapeHostProbe]::GetDesktopWindow()) { 'desktop' }
            elseif ($after -eq $hostWindow) { 'old_host' } else { 'other' }
        return "targetAlive=$alive;processAlive=$(!$fixture.HasExited);parent=$parentKind;hostWindowAlive=$([DrapeHostProbe]::IsWindow($hostWindow));journalExists=$(Test-Path -LiteralPath $journal)"
    } catch {
        return ('probe_error=' + $_.Exception.GetType().Name)
    } finally {
        if ($hostProcess -and !$hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
        if ($fixture -and !$fixture.HasExited) { Stop-Process -Id $fixture.Id -Force -ErrorAction SilentlyContinue }
    }
}
Verify-InstalledRail '--verify-utility-startup' 'utility-startup.json' 13
Verify-InstalledRail '--verify-utility-startup-restart' 'utility-startup-restart.json' 8
try { Verify-InstalledRail '--verify-program-operations' 'program-operations.json' 20 21 }
catch {
    $state = Get-DisposableHostCrashState $exe
    Write-Host ('::error title=Disposable host crash state::' + $state)
    throw
}
if (Test-Path -LiteralPath (Join-Path $profile 'error.log')) { throw 'Installed application logged a startup error.' }
"Installed upgrade $OldVersion -> $NewVersion passed on public GitHub-hosted Windows runner. Candidate SHA256: $($new.Sha256). Source: $SourceSha" |
    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

