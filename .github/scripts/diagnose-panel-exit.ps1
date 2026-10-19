param([Parameter(Mandatory)][Diagnostics.Process]$Panel, [Parameter(Mandatory)][string]$ExpectedExe)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases') {
    throw 'Panel diagnostics require the disposable public Windows runner.'
}
if ($Panel.HasExited -or $Panel.Path -ine $ExpectedExe) { return }
$folder = Join-Path $env:RUNNER_TEMP ('panel-stack-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$reader = $null
try {
    # Official Microsoft NuGet package, version/source/authors inspected separately.
    # Use its net8 DLL directly with the existing image runtime, not a global install.
    $package = Join-Path $folder 'dotnet-stack.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://api.nuget.org/v3-flatcontainer/dotnet-stack/10.0.750501/dotnet-stack.10.0.750501.nupkg' -OutFile $package -TimeoutSec 60
    if ((Get-Item $package).Length -ne 6025361 -or
        (Get-FileHash $package -Algorithm SHA256).Hash -ine 'cd35f399fe023f1793b528590a4d723a1f2f1d9b25696386d926a697bd24c0ca') {
        throw 'Stack diagnostic package checksum mismatch.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($package, $folder)
    $tool = Join-Path $folder 'tools/net8.0/any/dotnet-stack.dll'
    $out = Join-Path $folder 'private-stack.txt'
    $err = Join-Path $folder 'private-tool-error.txt'
    if ($Panel.HasExited) { return }
    $reader = Start-Process -FilePath (Get-Command dotnet -ErrorAction Stop).Source -ArgumentList @(('"'+$tool+'"'),'report','--process-id',[string]$Panel.Id) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    if (!$reader.WaitForExit(30000) -or $reader.ExitCode -ne 0) { throw 'Bounded stack diagnostic unavailable.' }
    # Output fixed categories only. Never print raw frames, source paths,
    # command lines, memory/dumps, window contents or tool stderr.
    $categories = [ordered]@{
        'Shtorka\.Ui\.(Error|Ask)' = 'APP_DIALOG'
        'System\.Windows\.MessageBox\.' = 'WPF_MESSAGEBOX'
        'Shtorka\.RailWindow.*OpenPinnedProgram' = 'APP_PIN_OPEN'
        'Shtorka\.RailWindow.*Exit' = 'APP_EXIT'
        'Shtorka\.ProgramOverlayHost' = 'APP_WINDOW_BROKER'
        'Shtorka\.ProgramLauncher.*Focus' = 'APP_PROGRAM_FOCUS'
        'System\.Windows\.Threading\.Dispatcher.*PushFrame' = 'WPF_FRAME'
        'System\.Windows\.Application.*Run' = 'WPF_APP_RUN'
        'Shtorka\.App\.RunApp' = 'APP_RUN'
        'Shtorka\.App\.Main' = 'APP_MAIN'
        'System\.Windows\.Forms.*RunMessageLoop' = 'WINFORMS_FRAME'
        'System\.Windows\.Automation|UIAutomation' = 'UIA'
        'CoreWebView2.*(Close|Dispose)' = 'WEBVIEW_DISPOSE'
        'Marshal.*ReleaseComObject' = 'COM_RELEASE'
        'WaitHandle|Monitor\.Wait|Task.*Wait|CoWait|InternalDoComWait' = 'MANAGED_OR_COM_WAIT'
    }
    $seen = @{}; $lines = 0
    foreach ($line in [IO.File]::ReadLines($out)) {
        if ($line -cmatch '^Thread \((0x[0-9a-fA-F]+)\)') {
            if ($lines -ge 200) { break }
            Write-Host ('Panel managed thread ' + [Convert]::ToInt64($matches[1].Substring(2),16)); $lines++
            $seen = @{}
        }
        foreach ($pattern in $categories.Keys) {
            $category = $categories[$pattern]
            if ($line -match $pattern -and !$seen.ContainsKey($category) -and $lines -lt 200) {
                Write-Host ('Panel managed frame category ' + $category); $lines++; $seen[$category] = $true
            }
        }
    }
    Write-Host 'Panel managed wait classification completed; raw data is not published.'
} catch { Write-Host 'Panel managed wait classification unavailable; original failed exit gate is retained.' }
finally {
    if ($reader -and !$reader.HasExited) { Stop-Process -Id $reader.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
