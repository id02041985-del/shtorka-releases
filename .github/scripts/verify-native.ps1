# Generic binary-only acceptance runner. This file contains no application
# source, credential, account, office endpoint or source-repository access.
$ErrorActionPreference='Stop'
if($env:GITHUB_REPOSITORY -cne 'id02041985-del/shtorka-releases' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows'){
    throw 'Disposable public Windows runner required'
}
$request=$env:DRAPE_NATIVE_REQUEST|ConvertFrom-Json
if($request.nonce -notmatch '^[a-f0-9]{32}$' -or $request.source -notmatch '^[a-f0-9]{40}$' -or
   $request.tag -cnotmatch '^native-review-[a-f0-9]{12}-\d+$' -or
   $request.setupSha -notmatch '^[a-f0-9]{64}$' -or $request.bundleSha -notmatch '^[a-f0-9]{64}$' -or
   $request.componentSha -notmatch '^[a-f0-9]{64}$' -or $request.setupBytes -lt 1000000 -or $request.bundleBytes -lt 1000000){throw 'Invalid review request'}
$work=Join-Path $env:RUNNER_TEMP ('drape-native-'+$request.nonce)
if(Test-Path -LiteralPath $work){throw 'Fresh native fixture required'}
$null=New-Item -ItemType Directory -Path $work
$api='https://api.github.com/repos/id02041985-del/shtorka-releases'
$headers=@{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/vnd.github+json'}
$releases=Invoke-RestMethod "$api/releases?per_page=100" -Headers $headers
$draft=@($releases|Where-Object tag_name -CEQ $request.tag)
if($draft.Count -ne 1 -or !$draft[0].draft -or $draft[0].id -le 0){throw 'Unique unpublished review draft required'}
function Download-Draft([string]$Name,[long]$Bytes,[string]$Hash){
    $asset=@($draft[0].assets|Where-Object name -CEQ $Name)
    if($asset.Count -ne 1 -or $asset[0].size -ne $Bytes -or $asset[0].digest -cne ('sha256:'+$Hash)){throw 'Review asset metadata mismatch'}
    $path=Join-Path $work $Name
    Invoke-WebRequest "$api/releases/assets/$($asset[0].id)" -Headers @{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/octet-stream'} -OutFile $path -ConnectionTimeoutSeconds 30 -OperationTimeoutSeconds 600
    if((Get-Item -LiteralPath $path).Length -ne $Bytes -or (Get-FileHash -LiteralPath $path).Hash -ine $Hash){throw 'Review asset bytes mismatch'}
    return $path
}
$setup=Download-Draft 'Shtorka-0.12.33-Setup-x64.exe' ([long]$request.setupBytes) $request.setupSha
$bundle=Download-Draft 'native-fixture.zip' ([long]$request.bundleBytes) $request.bundleSha
$oldRelease=Invoke-RestMethod "$api/releases/tags/v0.12.32"
$oldAsset=@($oldRelease.assets|Where-Object name -CEQ 'Shtorka-0.12.32-Setup-x64.exe')
if($oldRelease.draft -or $oldAsset.Count -ne 1 -or $oldAsset[0].digest -notmatch '^sha256:[a-f0-9]{64}$'){throw 'Issued previous installer required'}
$oldPublic=Join-Path $work 'Shtorka-0.12.32-Setup-x64.exe'
Invoke-WebRequest $oldAsset[0].browser_download_url -OutFile $oldPublic -ConnectionTimeoutSeconds 30 -OperationTimeoutSeconds 600
if((Get-Item -LiteralPath $oldPublic).Length -ne $oldAsset[0].size -or (Get-FileHash -LiteralPath $oldPublic).Hash -ine $oldAsset[0].digest.Substring(7)){throw 'Previous public installer changed'}
Expand-Archive -LiteralPath $bundle -DestinationPath (Join-Path $work 'bundle')
$payload=Join-Path $work 'bundle/payload'
$fixture=Join-Path $work 'bundle/fixture/Shtorka.Office.exe'
$oldPrivate=Join-Path $work 'bundle/old/Shtorka-0.11.7-Setup-x64.exe'
$componentSetup=Join-Path $payload 'OfficeComponentSetup.exe'
if((Get-FileHash -LiteralPath $componentSetup).Hash -ine $request.componentSha -or
   (Get-Item -LiteralPath $oldPrivate).Length -ne 76647012 -or
   (Get-FileHash -LiteralPath $oldPrivate).Hash -ine '361a736c42abc20a9d267fa25ce383123adc59bc5f811e8cae064c01319714c6'){
    throw 'Pinned component or actual legacy fixture changed'
}
if(@(Get-ChildItem -LiteralPath (Join-Path $work 'bundle') -File -Recurse|Where-Object {$_.Extension -in @('.cs','.ps1','.pdb') -or $_.Name -match '^(settings|Cookies|Login Data|History)'}).Count){throw 'Source, debug or user state in binary fixture'}
# Downloading is over. No installed or compiled binary receives an API token.
Remove-Item Env:GITHUB_TOKEN -ErrorAction Stop
foreach($name in @('GH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN','ACTIONS_ID_TOKEN_REQUEST_URL')){
    Remove-Item ('Env:'+ $name) -ErrorAction SilentlyContinue
}
$headers=$null
function Run-Checked([string]$File,[string[]]$Arguments,[int]$Timeout=180){
    if(!(Test-Path -LiteralPath $File -PathType Leaf)){throw ('Required disposable binary missing: '+[IO.Path]::GetFileName($File))}
    $log=Join-Path $work ([guid]::NewGuid().ToString('N')+'.out.txt')
    $err=$log+'.err.txt'
    $process=Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err
    if(!$process.WaitForExit($Timeout*1000)){throw 'Bounded disposable binary timed out'}
    $output=Get-Content -LiteralPath $log,$err -Raw -ErrorAction SilentlyContinue|Out-String
    if($output -match 'fixture-opaque-password|fixture-secret-should-not-be-logged'){throw 'Synthetic secret emitted by fixture'}
    if($output.Length -gt 200000){throw 'Oversize fixture log'}
    if($output){Write-Output $output}
    if($process.ExitCode -ne 0){throw ('Disposable binary failed: '+[IO.Path]::GetFileName($File)+' exit '+$process.ExitCode)}
}
function Find-InstalledApp([string]$Version){
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A0685854-23AD-4E53-94CE-83EE616048BE}_is1'
    $registration=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $directory=[IO.Path]::GetFullPath($registration.InstallLocation.TrimEnd('\'))
    $path=Join-Path $directory 'Shtorka.exe'
    if(!(Test-Path -LiteralPath $path -PathType Leaf) -or
       [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion -notlike ($Version+'*')){throw 'Actual installed app registration/version mismatch'}
    return $path
}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$component=Join-Path $env:ProgramFiles ('ShtorkaOffice/'+$sid)
$installArgs=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOOFFICECOMPONENT=1','/TASKS=""')
# First verify the current issued native15 -> candidate16 path.
Run-Checked $oldPublic $installArgs
$app=Find-InstalledApp '0.12.32'
Run-Checked $app @('--install-office-component')
if([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $component 'Shtorka.Office.exe')).ProductVersion -notlike '0.12.15*'){throw 'Actual previous native15 was not installed'}
Run-Checked $setup ($installArgs+@('/UPDATE=1'))
$app=Find-InstalledApp '0.12.33'
Run-Checked $app @('--install-office-component')
if([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $component 'Shtorka.Office.exe')).ProductVersion -notlike '0.12.16*'){throw 'Native16 upgrade was not installed'}
Run-Checked (Join-Path $component 'Shtorka.Office.exe') @('--self-test')
Run-Checked $app @('--verify-office-helper-ipc')
$nativeIdentity=@{helperSha256=(Get-FileHash -LiteralPath (Join-Path $component 'Shtorka.Office.exe')).Hash.ToLowerInvariant();
    brokerSha256=(Get-FileHash -LiteralPath (Join-Path $component 'Shtorka.Obyezd.Service.exe')).Hash.ToLowerInvariant();
    manifestSha256=(Get-FileHash -LiteralPath (Join-Path $component 'runtime-manifest.json')).Hash.ToLowerInvariant()}
$coldPassed=$false
if($request.coldStart -eq $true){
    $ps5=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    Run-Checked $ps5 @('-NoProfile','-NonInteractive','-File',('"'+(Join-Path $PSScriptRoot 'prepare-chatgpt-fixture.ps1')+'"')) 600
    foreach($name in @('Drape.NativeColdFixture.exe','Drape.NativeColdFixture.dll','Drape.NativeColdFixture.deps.json','Drape.NativeColdFixture.runtimeconfig.json')){
        [IO.File]::Copy((Join-Path $work ('bundle/cold-fixture/'+$name)),(Join-Path $payload $name),$false)
    }
    $coldReport=Join-Path $work 'native-cold-report.json'
    try{Run-Checked (Join-Path $payload 'Drape.NativeColdFixture.exe') @(('"'+$coldReport+'"')) 300}
    finally{if(Test-Path -LiteralPath $coldReport){Get-Content -LiteralPath $coldReport -Raw|Write-Output}}
    $cold=Get-Content -LiteralPath $coldReport -Raw|ConvertFrom-Json
    if(!$cold.passed -or !$cold.cacheInitiallyEmpty -or !$cold.preparedBeforeActivation -or !$cold.signedGuiStarted -or
       !$cold.exactPreparedNativeCoreStarted -or $cold.loopbackConnectRequests -lt 1 -or $cold.directExternalTcp -ne 0 -or
       $cold.authenticatedAccountUsed -or $cold.remoteOfficeTested){throw 'Actual protected cold desktop activation did not pass'}
    $coldPassed=$true
}
$appDir=Split-Path -Parent $app
Run-Checked (Join-Path $appDir 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
# The compiled production regression fixture requires the actual previous
# private0.11.7 component, then drives exact owned kernel and recovery cases.
Run-Checked $oldPrivate $installArgs
$app=Find-InstalledApp '0.11.7'
Run-Checked $app @('--install-office-component')
if([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $component 'Shtorka.Office.exe')).ProductVersion -notlike '0.11.7*'){throw 'Actual legacy helper required'}
Run-Checked $fixture @('--app',('"'+(Join-Path $payload 'Shtorka.exe')+'"'),'--installer',('"'+$setup+'"')) 300
$proof=[ordered]@{schema=1;passed=$true;nonce=$request.nonce;source=$request.source;version='0.12.33';nativeVersion='0.12.16';
    installerSha256=$request.setupSha;componentSha256=$request.componentSha;bundleSha256=$request.bundleSha;
    helperSha256=$nativeIdentity.helperSha256;brokerSha256=$nativeIdentity.brokerSha256;manifestSha256=$nativeIdentity.manifestSha256;
    currentNativeUpgradeTested=$true;legacyOwnedRecoveryTested=$true;coldDesktopActivationTested=$coldPassed;userAccountUsed=$false;liveOfficeAccountTested=$false;
    runner=$env:RUNNER_ENVIRONMENT;publicFeedChanged=$false;distributionAllowed=$false}
$json=$proof|ConvertTo-Json -Compress
Write-Output ('NATIVE_REVIEW_PROOF '+$json)
$json|Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8
