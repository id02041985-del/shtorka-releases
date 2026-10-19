# Run with Windows PowerShell 5.1 in the existing disposable upgrade job.
# Exercise the exact retry function without network, credentials or file writes.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'verify-upgrade.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Upgrade verifier PowerShell syntax failed.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ReadRetry' }, $true)
if (!$definition) { throw 'Upgrade read retry function missing.' }
Invoke-Expression $definition.Extent.Text
function Start-Sleep([int]$Seconds) { $script:delay += $Seconds }
$script:attempts = 0; $script:delay = 0
$value = Invoke-ReadRetry 'Synthetic transient' {
    $script:attempts++
    if ($script:attempts -eq 1) { throw 'Synthetic transport interruption' }
    'exact-result'
}
if ($value -cne 'exact-result' -or $script:attempts -ne 2 -or $script:delay -ne 3) { throw 'Transient read retry regression.' }
$script:attempts = 0; $script:delay = 0; $blocked = $false
try {
    Invoke-ReadRetry 'Synthetic permanent' { $script:attempts++; throw 'Synthetic persistent interruption' }
} catch { $blocked = $_.Exception.Message -like 'Synthetic permanent failed after 3*' }
if (!$blocked -or $script:attempts -ne 3 -or $script:delay -ne 9) { throw 'Read retry bound regression.' }
$script:attempts = 0; $script:delay = 0; $blocked = $false
try {
    Invoke-ReadRetry 'Synthetic access denial' {
        $script:attempts++
        $failure = [InvalidOperationException]::new('Synthetic access denial')
        $failure.Data['NoRetry'] = $true
        throw $failure
    }
} catch { $blocked = $_.Exception.Message -like 'Synthetic access denial failed after 1*' }
if (!$blocked -or $script:attempts -ne 1 -or $script:delay -ne 0) { throw 'Denied read must fail without retry.' }
Write-Host 'Upgrade download syntax and 3 bounded read retry checks passed; no network or installer actions.'
