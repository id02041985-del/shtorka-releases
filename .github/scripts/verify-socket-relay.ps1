# Binary-only disposable review. Contains no Drape implementation or private source.
$ErrorActionPreference='Stop'
if($env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows'){
    throw 'Disposable public Windows required'
}
$request=$env:DRAPE_SOCKET_REQUEST|ConvertFrom-Json
if($request.nonce -cnotmatch '^[a-f0-9]{32}$' -or $request.source -cnotmatch '^[a-f0-9]{40}$' -or
    $request.tag -cnotmatch '^socket-relay-review-[a-f0-9]{12}-\d+-\d+$' -or
    $request.bundleSha -cnotmatch '^[a-f0-9]{64}$' -or $request.librarySha -cnotmatch '^[a-f0-9]{64}$' -or
    $request.bundleBytes -lt 1000000 -or $request.bundleBytes -gt 600000000){throw 'Invalid review request'}
$work=Join-Path $env:RUNNER_TEMP ('socket-relay-'+$request.nonce)
if(Test-Path -LiteralPath $work){throw 'Fresh fixture required'}
$null=New-Item -ItemType Directory -Path $work
$api='https://api.github.com/repos/id02041985-del/shtorka-releases'
$headers=@{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/vnd.github+json'}
$draft=Invoke-RestMethod "$api/releases/tags/$($request.tag)" -Headers $headers
$asset=@($draft.assets|Where-Object name -CEQ 'socket-relay-fixture.zip')
if(!$draft.draft -or $draft.tag_name -cne $request.tag -or $asset.Count -ne 1 -or
    $asset[0].size -ne $request.bundleBytes -or $asset[0].digest -cne ('sha256:'+$request.bundleSha)){throw 'Exact unpublished binary asset required'}
$zip=Join-Path $work 'fixture.zip'
Invoke-WebRequest "$api/releases/assets/$($asset[0].id)" -Headers @{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/octet-stream'} -OutFile $zip -ConnectionTimeoutSeconds 30 -OperationTimeoutSeconds 600
if((Get-Item -LiteralPath $zip).Length -ne $request.bundleBytes -or (Get-FileHash -LiteralPath $zip).Hash -ine $request.bundleSha){throw 'Binary archive differs from request'}
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'bundle')
$bundle=Join-Path $work 'bundle';$payload=Join-Path $bundle 'payload';$fixture=Join-Path $bundle 'fixture'
if(@(Get-ChildItem -LiteralPath $bundle -Recurse -File|Where-Object {$_.Extension -in @('.cs','.ps1','.c','.pdb') -or $_.Name -match '^(settings|Cookies|Login Data|History)'}).Count){throw 'Source or user state in binary bundle'}
$library=Join-Path $fixture 'Drape.SocketRelay.dll'
$receipt=Get-Content -LiteralPath (Join-Path $bundle 'build-receipt.json') -Raw|ConvertFrom-Json
if((Get-FileHash -LiteralPath $library).Hash -ine $request.librarySha -or $receipt.sha256 -cne $request.librarySha -or $receipt.distributionAllowed){throw 'Native binary identity differs'}
# No fixture, native library or installed vendor app inherits an API token.
foreach($name in @('GITHUB_TOKEN','GH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN','ACTIONS_ID_TOKEN_REQUEST_URL')){
    Remove-Item ('Env:'+ $name) -ErrorAction SilentlyContinue
}
$headers=$null
function Run-Checked([string]$File,[string[]]$Arguments,[int]$Timeout=90){
    $out=Join-Path $work ([guid]::NewGuid().ToString('N')+'.txt');$err=$out+'.err'
    $options=@{FilePath=$File;ArgumentList=$Arguments;PassThru=$true;WindowStyle='Hidden';RedirectStandardOutput=$out;RedirectStandardError=$err}
    if($File -ieq (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe')){
        $options.Environment=@{PSModulePath=(Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules')}
    }
    $process=Start-Process @options
    if(!$process.WaitForExit($Timeout*1000)){throw 'Bounded fixture timed out'}
    $text=Get-Content -LiteralPath $out,$err -Raw -ErrorAction SilentlyContinue|Out-String
    if($text.Length -gt 100000){throw 'Oversize fixture log'}
    if($text){Write-Host $text}
    if($process.ExitCode -ne 0){throw ('Fixture failed: '+[IO.Path]::GetFileName($File)+' exit '+$process.ExitCode)}
}
$exe=Join-Path $fixture 'SocketRelay.Tests.exe'
$rule='Drape.SocketFixture.'+$request.nonce
if(@(Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue).Count){throw 'Never replace existing firewall rules'}
'{"matchingRulesBefore":0}'|Set-Content -LiteralPath (Join-Path $work 'firewall-before.json')
try{
    $ranges=@('0.0.0.0-127.0.0.0','127.0.0.2-255.255.255.255','::-::','::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
    $null=New-NetFirewallRule -Name $rule -DisplayName $rule -Program $exe -Direction Outbound -Action Block -Enabled True -Profile Any -RemoteAddress $ranges
    Run-Checked $exe @('--denied-fixture')
    Run-Checked $exe @(('"'+$library+'"'))
}finally{
    Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue|Remove-NetFirewallRule
}
if(@(Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue).Count){throw 'Fixture firewall cleanup failed'}
$ps5=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
Run-Checked $ps5 @('-NoProfile','-NonInteractive','-File',('"'+(Join-Path $PSScriptRoot 'prepare-chatgpt-fixture.ps1')+'"')) 600
$report=Join-Path $work 'signed-gui-report.json'
$ci=@{GITHUB_REPOSITORY='id02041985-del/shtorka-releases';RUNNER_ENVIRONMENT='github-hosted';RUNNER_OS='Windows'};$ciBefore=@{}
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class SocketFixtureEnvironmentNotice{[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr SendMessageTimeout(IntPtr window,uint message,UIntPtr first,string text,uint flags,uint timeout,out UIntPtr result);}'
try{
    foreach($key in $ci.Keys){$ciBefore[$key]=[Environment]::GetEnvironmentVariable($key,'User');[Environment]::SetEnvironmentVariable($key,$ci[$key],'User')}
    $sent=[UIntPtr]::Zero;$null=[SocketFixtureEnvironmentNotice]::SendMessageTimeout([IntPtr]65535,26,[UIntPtr]::Zero,'Environment',2,2000,[ref]$sent)
    $env:DRAPE_SOCKET_RELAY_REVIEW='1'
    Run-Checked (Join-Path $payload 'Drape.NativeColdFixture.exe') @(('"'+$report+'"')) 300
}finally{
    foreach($key in $ciBefore.Keys){[Environment]::SetEnvironmentVariable($key,$ciBefore[$key],'User')}
    $sent=[UIntPtr]::Zero;$null=[SocketFixtureEnvironmentNotice]::SendMessageTimeout([IntPtr]65535,26,[UIntPtr]::Zero,'Environment',2,2000,[ref]$sent)
    if(Test-Path -LiteralPath $report){Get-Content -LiteralPath $report -Raw|Write-Host}
}
$gui=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
if(!$gui.passed -or !$gui.processLocalSocketRelayReady -or !$gui.signedGuiStarted -or $gui.directExternalTcp -ne 0 -or $gui.authenticatedAccountUsed){throw 'Actual signed GUI compatibility evidence missing'}
$proof=[ordered]@{passed=$true;nonce=$request.nonce;source=$request.source;bundleSha256=$request.bundleSha;
    librarySha256=$request.librarySha;firewallDenialTested=$true;signedGuiModuleTested=$true;
    authenticatedPeerTested=$false;distributionAllowed=$false}
Write-Host ('SOCKET_RELAY_PROOF '+($proof|ConvertTo-Json -Compress))
