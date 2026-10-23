param([Parameter(Mandatory)][string]$Exe,[Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Profile)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases') { throw 'Disposable public runner required.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FrameCapture {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
}
'@
$process = Start-Process -FilePath $Exe -WorkingDirectory $Directory -PassThru
try {
    $root = [Windows.Automation.AutomationElement]::RootElement
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $button = $null
    for ($attempt=0;$attempt -lt 40;$attempt++) {
        if ($process.HasExited) { throw 'Previous ordinary app exited before frame capture.' }
        $owned = $root.FindAll([Windows.Automation.TreeScope]::Children,$condition)
        foreach ($element in $owned) {
            $button = $element.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Fixture site'))
            if ($button) { break }
        }
        if ($button) { break }; Start-Sleep -Milliseconds 250
    }
    if (!$button) { throw 'Previous ordinary site action was not found.' }
    $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 5
    $drawer = $root.FindAll([Windows.Automation.TreeScope]::Children,$condition) | Where-Object { $_.Current.Name -ceq 'Drape — сайт' } | Select-Object -First 1
    if (!$drawer) { throw 'Previous real drawer was not found.' }
    $handle = [IntPtr]$drawer.Current.NativeWindowHandle
    $rect = New-Object FrameCapture+Rect
    if (![FrameCapture]::GetWindowRect($handle,[ref]$rect)) { throw 'Previous drawer rectangle unavailable.' }
    $bitmap = New-Object Drawing.Bitmap ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    try { if (![FrameCapture]::PrintWindow($handle,$dc,2)) { throw 'Previous frame capture failed.' } }
    finally { $graphics.ReleaseHdc($dc);$graphics.Dispose() }
    try { $bitmap.Save((Join-Path $Profile 'main-frame-before-drawer.png'),[Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
    'Captured actual previous installed drawer from a synthetic site profile, before candidate installation.' | Write-Host
} finally {
    if (!$process.HasExited) {
        $exit = Start-Process -FilePath $Exe -WorkingDirectory $Directory -ArgumentList '--exit' -PassThru -Wait
        if (!$process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force;throw 'Previous synthetic capture app did not exit cleanly.' }
    }
}
