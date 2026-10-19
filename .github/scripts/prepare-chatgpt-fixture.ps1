$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases') {
    throw 'CHATGPT_FIXTURE_REQUIRES_DISPOSABLE_PUBLIC_WINDOWS'
}
if (@(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop).Count -ne 0) {
    throw 'CHATGPT_FIXTURE_ALREADY_PRESENT'
}
$folder = Join-Path $env:RUNNER_TEMP 'official-chatgpt-fixture'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$package = Join-Path $folder 'ChatGPT-x64.msix'
$license = Join-Path $folder 'ChatGPT-License.xml'
# Both URLs are published in OpenAI's Windows deployment documentation.
try {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -OutFile $package -TimeoutSec 600
    Invoke-WebRequest -UseBasicParsing -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' -OutFile $license -TimeoutSec 60
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    throw "CHATGPT_FIXTURE_DOWNLOAD_HTTP_$status"
}
if ((Get-Item $package).Length -lt 1000000 -or (Get-Item $package).Length -gt 1500000000 -or
    (Get-Item $license).Length -gt 1000000) { throw 'CHATGPT_FIXTURE_DOWNLOAD_SIZE' }
$signTool = @(Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1)
if ($signTool.Count -ne 1) { throw 'CHATGPT_FIXTURE_SIGNATURE_TOOL_MISSING' }
& ([string]$signTool[0].FullName) verify /pa /all $package *> $null
if ($LASTEXITCODE -ne 0) { throw 'CHATGPT_FIXTURE_SIGNATURE_INVALID' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($package)
try {
    $manifestEntry = $archive.GetEntry('AppxManifest.xml')
    if (!$manifestEntry -or $manifestEntry.Length -gt 1000000) { throw 'CHATGPT_FIXTURE_MANIFEST_MISSING' }
    $reader = New-Object IO.StreamReader($manifestEntry.Open())
    try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $archive.Dispose() }
if ([string]$manifest.Package.Identity.Name -cne 'OpenAI.Codex' -or
    [string]$manifest.Package.Identity.ProcessorArchitecture -cne 'x64') { throw 'CHATGPT_FIXTURE_IDENTITY_INVALID' }
$os = [version](Get-CimInstance Win32_OperatingSystem).Version
foreach ($family in @($manifest.Package.Dependencies.TargetDeviceFamily)) {
    if ([version]$family.MinVersion -gt $os) { throw "CHATGPT_FIXTURE_OS_TOO_OLD_REQUIRED_$($family.MinVersion)_ACTUAL_$os" }
}
# This VM is discarded after the job. Use the vendor's signed offline package
# and public license; do not generate/import certificates or create an account.
try { Add-AppxProvisionedPackage -Online -PackagePath $package -LicensePath $license -Regions all | Out-Null }
catch { throw ('CHATGPT_FIXTURE_PROVISION_HRESULT_{0:X8}' -f [int]$_.Exception.HResult) }
try { Add-AppxPackage -Path $package -ErrorAction Stop }
catch { throw ('CHATGPT_FIXTURE_REGISTER_HRESULT_{0:X8}' -f [int]$_.Exception.HResult) }
$installed = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop)
if ($installed.Count -ne 1 -or $installed[0].PackageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0' -or
    [string]$installed[0].Version -cne [string]$manifest.Package.Identity.Version) { throw 'CHATGPT_FIXTURE_INSTALLED_IDENTITY_INVALID' }
$start = @(Get-StartApps | Where-Object AppID -CLike 'OpenAI.Codex_2p2nqsd0c76g0!*')
if ($start.Count -ne 1) { throw 'CHATGPT_FIXTURE_AUMID_AMBIGUOUS' }
$env:SHTORKA_CHATGPT_AUMID = [string]$start[0].AppID
$digest = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
"Official Store-signed ChatGPT MSIX installed only in disposable VM. Version $($installed[0].Version); SHA256 $digest. No account login or microphone use." |
    Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
