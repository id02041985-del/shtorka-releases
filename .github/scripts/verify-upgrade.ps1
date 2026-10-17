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
    $release = Get-Release $version
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
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -LiteralPath $runKey -Name 'Shtorka' -Value ('"' + $exe + '"')
Remove-ItemProperty -LiteralPath $runKey -Name 'Drape' -ErrorAction SilentlyContinue
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Disposable runner has no user desktop path.' }
New-Item -ItemType Directory -Path $desktop -Force | Out-Null
$oldShortcut = Join-Path $desktop 'Шторка.lnk'
$newShortcut = Join-Path $desktop 'Drape.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($oldShortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $appDir
$link.Save()
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
"Installed upgrade $OldVersion -> $NewVersion passed on public GitHub-hosted Windows runner. Candidate SHA256: $($new.Sha256). Source: $SourceSha" |
    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

