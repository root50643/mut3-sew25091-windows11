[CmdletBinding()]
param(
    [ValidateSet('Auto','Check')][string]$Mode='Auto',
    [ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW26061-00',
    [switch]$NoUI,
    [switch]$LibraryOnly
)
if(!$LibraryOnly -and $Mode -eq 'Auto'){
    # Current default prepares dependencies only; vendor installation is manual.
    $prepareArguments=@{Mode='Prepare';Release=$Release}
    if($NoUI){$prepareArguments.NoUI=$true}
    & (Join-Path $PSScriptRoot 'Prepare-MutPrerequisites.ps1') @prepareArguments
    exit $LASTEXITCODE
}
# This script is orchestration only. Original vendor files are never patched.
$ErrorActionPreference='Stop'
$script:TaskRoot='C:\MUT-Install'
$script:RepoRoot=Split-Path -Parent $PSScriptRoot
$script:NativePS=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Profile=$null
$script:MediaHash=$null
$script:PsArchiveHash='D9812E7BE1F72FF49D73F3179E207AA0000852D9D0EFD92455AD376FAD5D9B7C'
$script:StatePath=Join-Path $script:TaskRoot 'oneclick-state.json'
$script:Stage='啟動檢查'
$script:RunRoot=$null
$script:State=$null
$script:Verification=$null
$script:RawError=$null

function Resolve-MutElevationResult { param([int]$NativeErrorCode) if($NativeErrorCode -eq 1223){return 1223};return 1 }
function Assert-MutSingleInstance {
    param([scriptblock]$TryAcquire)
    if(!(& $TryAcquire)){Stop-MutReview '已有另一個安裝助手正在執行，請回到原視窗。'}
}
function Test-MutClassicIdentity {
    param([string]$LastBlock,[string]$RegistryType)
    return ($RegistryType -ceq 'PRG23061-03' -and $LastBlock -match '(?m)^MUT-3 Ver = PRG23061-03\s*$')
}
function Test-MutRecoveredCompletion {
    param([bool]$FreshLog,[bool]$SqlReady,[bool]$Busy,[bool]$RebootAfterLog)
    return ($FreshLog -and $SqlReady -and !$Busy -and $RebootAfterLog)
}
function Get-MutMonitorDecision {
    param([bool]$FreshLog,[bool]$SqlReady,[bool]$Busy,[int]$IdleSeconds,[int]$ElapsedSeconds)
    if($ElapsedSeconds -ge 5400){return 'TimedOut'}
    if($FreshLog -and $SqlReady -and !$Busy -and $IdleSeconds -ge 10){return 'Complete'}
    return 'Waiting'
}
function Invoke-MutDownload {
    param([scriptblock]$Download,[scriptblock]$Verify)
    & $Download | Out-Null
    if(!(& $Verify)){throw 'Microsoft 下載檔案與本次審查雜湊不同；已停止，沒有執行下載內容。'}
}
function Invoke-MutDispatch { param([string]$Mode,[scriptblock]$CheckAction,[scriptblock]$AutoAction) if($Mode -eq 'Check'){return (& $CheckAction)};return (& $AutoAction) }
function Invoke-MutConfirmedCleanup {
    param([scriptblock]$Confirm,[scriptblock]$Uninstall,[scriptblock]$Remove)
    if(!(& $Confirm)){return 1223}
    $result=& $Uninstall
    if($result -ne 0){return $result}
    return (& $Remove)
}
function Write-MutEvent {
    param([string]$Text)
    $line=('{0} [{1}] {2}' -f (Get-Date -Format 's'),$script:Stage,$Text)
    Write-Host $line
    if($script:RunRoot){Add-Content -LiteralPath (Join-Path $script:RunRoot 'events.log') -Value $line -Encoding UTF8}
}
function Show-MutNotice {
    param([string]$Text,[ValidateSet('Information','Warning','Error','Question')][string]$Kind='Information',[switch]$Confirm)
    Write-MutEvent $Text
    if($NoUI){if($Confirm){return $false};return}
    Add-Type -AssemblyName System.Windows.Forms
    $buttons=if($Confirm){[Windows.Forms.MessageBoxButtons]::YesNo}else{[Windows.Forms.MessageBoxButtons]::OK}
    $icon=[Windows.Forms.MessageBoxIcon]::$Kind
    $defaultButton=if($Confirm){[Windows.Forms.MessageBoxDefaultButton]::Button2}else{[Windows.Forms.MessageBoxDefaultButton]::Button1}
    $answer=[Windows.Forms.MessageBox]::Show($Text,'M.U.T.-3 / SE 安裝助手',$buttons,$icon,$defaultButton)
    if($Confirm){return ($answer -eq [Windows.Forms.DialogResult]::Yes)}
}
function Stop-MutReview {
    param([string]$Message,[int]$Code=2)
    $errorObject=New-Object System.Exception($Message)
    $errorObject.Data['MutExitCode']=$Code
    throw $errorObject
}
function Save-MutCheckpoint {
    param([string]$Phase)
    $script:State.Phase=$Phase
    $script:State.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    Write-MutState -Path $script:StatePath -State $script:State
}
function Get-MutBootUtc { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
function Get-MutTargetRegistryRemnants {
    $found=@()
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try{
            foreach($instance in @('MUT3','CAESARCOMPDB')){
                $mapping=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL')
                $setup=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.'+$instance+'\Setup')
                try{if(($mapping -and $mapping.GetValue($instance)) -or $setup){$found+=[pscustomobject]@{Instance=$instance;View=$view.ToString()}}}
                finally{if($mapping){$mapping.Dispose()};if($setup){$setup.Dispose()}}
            }
        }finally{$base.Dispose()}
    }
    return $found
}
function Test-MutPendingRestart {
    foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')){if(Test-Path -LiteralPath $path){return $true}}
    $session=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    return @($session.PendingFileRenameOperations | Where-Object {![string]::IsNullOrEmpty($_)}).Count -gt 0
}
function Get-MutInstallerProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(MUT3Check|MUT3INSTALL|MUT3UNINSTALL|MT3NSTLL|MT3NNSTLL)\.exe$' -or
        $_.Name -match '^(setup|setup100|scenarioengine|DPInst|en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935)\.exe$' -or
        ($_.Name -ieq 'powershell.exe' -and $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\(Repair-MutPrerequisites|Remove-FailedMutSqlInstances|Start-MutInstallWithSqlAcl|Repair-MutSqlLegacyAcl|Backup-MutUpgrade|loadGAC)\.ps1(?:"|\s|$)') -or
        ($_.Name -in @('cmd.exe','wscript.exe','cscript.exe') -and $_.CommandLine -match '(?i)\\(UNINST|DEL_SE|InstCheck|MUT3_Checker|SE)\.(bat|vbs)\b')
    } | Select-Object Name,ProcessId,ParentProcessId,CreationDate,ExecutablePath)
}
function Get-MutUpgradeBlockingProcesses {
    # Upgrade needs a quiescent source tree. Classic MUT may own an IE COM
    # window or a Script Host with no visible MUT path, so these hosts remain
    # blockers even when their command/path is missing or appears unrelated.
    # This stricter inventory is never used for normal installation monitoring.
    $installers=@(Get-MutInstallerProcesses)
    $applications=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ProcessId -ne $PID -and (
            $_.Name -match '^(MUT3_SE|MUT3_Launcher|iexplore|wscript|cscript)\.exe$' -or
            ($_.ExecutablePath -and $_.ExecutablePath -match '(?i)^C:\\MUTSW(?:_SE)?(?:\\|$)') -or
            ($_.CommandLine -and $_.CommandLine -match '(?i)C:[\\/]+MUTSW(?:_SE)?(?:[\\/]|["\s]|$)')
        )
    } | Select-Object Name,ProcessId)
    return @(@($installers)+@($applications) | Sort-Object ProcessId -Unique)
}
function Test-MutUpgradeIdle { return (@(Get-MutUpgradeBlockingProcesses).Count -eq 0) }
function Start-MutReviewedUpgradeUninstall {
    $script:Stage='升級前原廠解除安裝'
    $entry=Join-Path $script:TaskRoot 'upgrade-uninstall-media\SEW25091\UNINSTALLER\UNINST.BAT'
    Show-MutNotice '備份核驗完成。請先關閉兩版 M.U.T.、Internet Explorer 及 Windows Script Host 視窗，再按「確定」啟動原廠舊版解除安裝。接著請在 M.U.T.-III Checker 按「是」。完成後會要求重新開機。'
    # Recheck after the interactive notice: an app may have been opened since
    # BackupReady was inspected or while this prompt was on screen.
    $busy=@(Get-MutUpgradeBlockingProcesses)
    if($busy.Count){
        Stop-MutReview ('仍有應用程式、腳本主機或安裝程序在執行，沒有啟動原廠卸載，也沒有終止任何程序。請先關閉並排查：'+(($busy | ForEach-Object {$_.Name+' (PID '+$_.ProcessId+')'}) -join '、'))
    }
    $null=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /s /c ""'+$entry+'""') -WorkingDirectory (Split-Path -Parent $entry) -WindowStyle Hidden -PassThru
}
function Test-MutChildAlive {
    param($Child)
    if(!$Child){return $false}
    $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$Child.Pid)
    return ($process -and $process.ExecutablePath -ieq $script:NativePS -and $process.CreationDate.ToUniversalTime().ToString('o') -eq $Child.CreatedUtc)
}
function Assert-MutHelpers {
    $manifestPath=Join-Path $PSScriptRoot 'oneclick-helper-hashes.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($item in $manifest.PSObject.Properties){
        if($item.Name -notmatch '^[A-Za-z0-9.-]+\.(ps1|psm1|cmd)$'){throw 'Invalid helper manifest path.'}
        $path=Join-Path $PSScriptRoot $item.Name
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item.Value){throw ('輔助檔案雜湊不符：'+$item.Name+'。請重新取得完整專案，不要移除檢查。')}
    }
}
function Start-MutChild {
    param([string]$Name,[string]$Arguments='', [switch]$Wait)
    # Script names are internal constants, never restored executable paths from JSON.
    Assert-MutHelpers
    $childPath=Join-Path $PSScriptRoot $Name
    $prefix=Join-Path $script:RunRoot ($Name+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $releaseArgument=if($Name -ceq 'Backup-MutUpgrade.ps1'){''}else{' -Release '+$script:Profile.Release}
    $process=Start-Process -FilePath $script:NativePS -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$childPath+'"'+$releaseArgument+' '+$Arguments) -WindowStyle Hidden -PassThru -RedirectStandardOutput ($prefix+'.out.txt') -RedirectStandardError ($prefix+'.err.txt')
    $null=$process.Handle
    $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    $identity=[pscustomobject]@{Pid=$process.Id;CreatedUtc=$(if($cim){$cim.CreationDate.ToUniversalTime().ToString('o')}else{''});Output=$prefix+'.out.txt';Error=$prefix+'.err.txt'}
    if($Wait){
        if(!$process.WaitForExit(2700000)){Stop-MutReview ('輔助程序超過 45 分鐘，程序仍保留。請查看 '+$identity.Output+'，等它結束前不要再次安裝。')}
        $process.WaitForExit();$process.Refresh();return [pscustomobject]@{ExitCode=$process.ExitCode;Identity=$identity}
    }
    return $identity
}
function Invoke-MutSqlCheck {
    $script:Stage='SQL 與安裝結果唯讀驗收'
    $child=Start-MutChild -Name 'Verify-MutSqlInstallation.ps1' -Arguments '-Phase Manual' -Wait
    $lines=@(Get-Content -LiteralPath $child.Identity.Output -Encoding UTF8 | Where-Object {$_ -match '^\{"Status"'})
    if(!$lines.Count){Stop-MutReview ('SQL 驗收沒有產生可解析報告。詳見 '+$child.Identity.Error)}
    $summary=$lines[-1] | ConvertFrom-Json
    $path=[IO.Path]::GetFullPath([string]$summary.ReportPath)
    if(!$path.StartsWith('C:\MUT-Install\verification-logs\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected verification report path.'}
    $report=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $log=Get-MutInstLogEvidence -Path 'C:\MUTSW\InstLog.txt'
    $classicRegistry=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00' -ErrorAction SilentlyContinue
    $classic=Test-MutClassicIdentity -LastBlock $log.LastBlock -RegistryType ([string]$classicRegistry.TYPE)
    $seVersionFile='C:\MUTSW_SE\MUT3_SE\System\Version.xml'
    $seVersion=''
    if(Test-Path -LiteralPath $seVersionFile){
        $settings=New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($seVersionFile,$settings)
        try{$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);$seVersion=[string]$xml.VERSION_DEFINE.VERSION}finally{$reader.Dispose()}
    }
    $shortcuts=@(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('CommonDesktopDirectory')) -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object {$_.BaseName -in @('M.U.T.-3','M.U.T.-3_SE')})
    $sqlExact=@($report.Instances | Where-Object {$_.Service.StartMode -ne 'Auto' -or $_.Sql.Server.ProductVersion -ne $script:Profile.SqlVersion}).Count -eq 0
    $filesReady=Test-MutInstalledFiles
    $shortcutTargetsOk=$shortcuts.Count -eq 2
    $shell=New-Object -ComObject WScript.Shell
    foreach($file in $shortcuts){
        $link=$shell.CreateShortcut($file.FullName)
        $expectedArguments=if($file.BaseName -eq 'M.U.T.-3'){'1'}else{''}
        if($link.TargetPath -ine 'C:\MUTSW_SE\MUT3_SE\Temp\MUT3_Launcher.exe' -or $link.Arguments -cne $expectedArguments){$shortcutTargetsOk=$false}
    }
    $result=[ordered]@{Passed=($child.ExitCode -eq 0 -and $report.Status -eq 'ReadOnlyChecksPassed' -and $log.LastLine -ceq '問題なし' -and $classic -and $seVersion -eq $script:Profile.SeVersion -and $shortcutTargetsOk -and $sqlExact -and $filesReady);Release=$script:Profile.Release;SqlReport=$path;InstLog=$log;ClassicExpectedVersion=$script:Profile.ClassicVersion;SeExpectedVersion=$script:Profile.SeVersion;SeInstalledVersion=$seVersion;ApplicationVersionsRequireUserConfirmation=$true;DesktopShortcutCount=$shortcuts.Count;ShortcutTargetsValid=$shortcutTargetsOk;Findings=@($report.Findings)}
    if(!$classic){$result.Findings+= ('傳統版安裝紀錄不是 '+$script:Profile.ClassicVersion+'。')}
    if($log.LastLine -cne '問題なし'){$result.Findings+= '原廠最後檢查區塊不是「問題なし」。'}
    if($seVersion -ne $script:Profile.SeVersion){$result.Findings+=('SE 版本檔缺少或不是 '+$script:Profile.SeVersion+'。')}
    if(!$sqlExact){$result.Findings+='SQL 版本或自動啟動設定不符合本次驗證。'}
    if(!$filesReady -or !$shortcutTargetsOk){$result.Findings+='必要啟動檔缺少，或原廠桌面捷徑的目標／參數不符。'}
    $script:Verification=[pscustomobject]$result
    return $script:Verification
}
function Request-MutRestart {
    param([string]$ResumePhase,[string]$Reason)
    $script:State.BootUtc=Get-MutBootUtc
    $script:State.ResumePhase=$ResumePhase
    Save-MutCheckpoint 'AwaitingReboot'
    Show-MutNotice ($Reason+"`r`n請儲存工作並重新啟動 Windows，再雙擊同一個 Install-MUT.cmd 接續。助手不會自動重新開機。")
    return 3010
}
function Get-MutOfficialArchive {
    $target=Join-Path $script:TaskRoot 'ps2DLC.zip'
    if(!(Test-Path -LiteralPath $target)){
        $local=Join-Path $script:RepoRoot 'ps2DLC.zip'
        if(Test-Path -LiteralPath $local){
            if((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $script:PsArchiveHash){throw '本地 ps2DLC.zip 雜湊不符。'}
            Copy-Item -LiteralPath $local -Destination $target
        }else{
            $download=Join-Path $script:RunRoot 'ps2DLC.download'
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            Invoke-MutDownload -Download {
                try{Invoke-WebRequest -UseBasicParsing -Uri 'https://download.microsoft.com/download/2b37839b-e146-465a-a78c-c9066609c553/ps2DLC.zip' -OutFile $download -TimeoutSec 180}catch{throw ('Microsoft 補充元件下載失敗。可手動將已核對的 ps2DLC.zip 放在專案根目錄再試。原始錯誤：'+$_.Exception.Message)}
            } -Verify {return ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -eq $script:PsArchiveHash)}
            Move-Item -LiteralPath $download -Destination $target
        }
    }
    $null=Expand-MutVerifiedArchive -ArchivePath $target -DestinationParent (Join-Path $script:TaskRoot 'ps2DLC') -ExpectedHash $script:PsArchiveHash -ExpectedRoot 'ps2DLC'
}
function Prepare-MutMedia {
    $script:Stage='核對與解壓安裝來源'
    $archive=Join-Path $script:RepoRoot $script:Profile.ArchiveFileName
    if(!(Test-Path -LiteralPath $archive)){throw ('找不到 '+$archive+'。請將 '+$script:Profile.ArchiveFileName+' 放在 Install-MUT.cmd 旁，再試一次。')}
    Write-MutEvent '正在完整核對 ZIP 與解壓內容，可能需要幾分鐘。'
    $null=Expand-MutVerifiedArchive -ArchivePath $archive -DestinationParent $script:TaskRoot -ExpectedHash $script:MediaHash -ExpectedRoot $script:Profile.ArchiveRoot
}
function Test-MutInstalledFiles {
    # Known canonical vendor paths; existence is a guard, not a launch acceptance result.
    return ((Test-Path -LiteralPath 'C:\MUTSW\MUT3\MENU\SCRIPT\start.js') -and (Test-Path -LiteralPath 'C:\MUTSW_SE\MUT3_SE\Temp\MUT3_Launcher.exe') -and (Test-Path -LiteralPath 'C:\MUTSW_SE\MUT3_SE\System\Common\MUT3_SE.exe') -and (Test-Path -LiteralPath 'C:\MUTSW_SE\MUT3_SE\System\Version.xml'))
}
function New-MutSelectedState {
    return [pscustomobject]@{SchemaVersion=1;Machine=$env:COMPUTERNAME;Release=$script:Profile.Release;MediaHash=$script:MediaHash;Phase='Checking';BootUtc=(Get-MutBootUtc);ResumePhase='';UpdatedUtc=[datetime]::UtcNow.ToString('o');InstallStartedUtc='';InstallCompletedUtc='';LogBefore=$null;Coordinator=$null;UninstallStartedUtc='';ApplicationConfirmation=$null;UpgradeManifest='';UpgradeManifestSha256=''}
}
function Get-MutInstalledSeVersion {
    $path='C:\MUTSW_SE\MUT3_SE\System\Version.xml'
    if(!(Test-Path -LiteralPath $path)){return ''}
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($path,$settings)
    try{$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);return [string]$xml.VERSION_DEFINE.VERSION}finally{$reader.Dispose()}
}
function Test-MutUpgradeRequested {
    if($script:Profile.Release -cne 'SEW26061-00'){return $false}
    if($script:State -and $script:State.MediaHash -ceq $script:MediaHash){return $false}
    $old=Get-MutMediaProfile -Release 'SEW25091'
    return (($script:State -and $script:State.MediaHash -ceq $old.MediaHash) -or (Test-Path -LiteralPath (Join-Path $script:TaskRoot 'upgrade-state.json')) -or (!$script:State -and (Get-MutInstalledSeVersion) -ceq $old.SeVersion))
}
function Assert-MutUpgradeStateArchive {
    param($Checkpoint)
    if($Checkpoint.HadOriginalState){
        $path=[IO.Path]::GetFullPath([string]$Checkpoint.OriginalStateArchive)
        if($path -notmatch '^C:\\MUT-Install\\oneclick-logs\\\d{8}-\d{6}-[a-f0-9]{8}\\backupmeta\\oneclick-state\.json$'){throw 'Unexpected archived-state path.'}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $Checkpoint.OriginalStateSha256 -or
           (Get-FileHash -LiteralPath $script:StatePath -Algorithm SHA256).Hash -cne $Checkpoint.OriginalStateSha256){throw '舊版完成進度或其備份已變更，沒有繼續升級。'}
    }elseif(Test-Path -LiteralPath $script:StatePath){throw '備份期間出現新的安裝進度，無法安全沿用。'}
}
function Get-MutBackupChildStatus {
    param($Child)
    foreach($field in @('Pid','CreatedUtc','Output','Error')){if($Child.PSObject.Properties.Name -notcontains $field){return 'Unknown'}}
    if($Child.Pid -isnot [int] -or $Child.Pid -le 0 -or !$Child.CreatedUtc){return 'Unknown'}
    foreach($field in @('Output','Error')){
        $path=[IO.Path]::GetFullPath([string]$Child.$field)
        if($path -notmatch '^C:\\MUT-Install\\oneclick-logs\\\d{8}-\d{6}-[a-f0-9]{8}\\Backup-MutUpgrade\.ps1-[a-f0-9]{8}\.(out|err)\.txt$'){return 'Unknown'}
    }
    if(([string]$Child.Output -replace '\.out\.txt$','') -cne ([string]$Child.Error -replace '\.err\.txt$','')){return 'Unknown'}
    $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$Child.Pid)
    if(!$process){return 'Ended'}
    if($process.ExecutablePath -ieq $script:NativePS -and $process.CreationDate.ToUniversalTime().ToString('o') -ceq $Child.CreatedUtc -and
       $process.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\Backup-MutUpgrade\.ps1(?:"|\s|$)'){return 'Alive'}
    return 'Unknown'
}
function Read-MutBackupSummary {
    param($Child)
    if((Get-MutBackupChildStatus $Child) -cne 'Ended'){throw 'Backup output cannot be accepted while child identity is live or unknown.'}
    $text=Get-Content -LiteralPath $Child.Output -Raw -Encoding UTF8
    $blocks=[regex]::Matches($text,'(?m)^\{')
    if(!$blocks.Count){throw ('備份沒有產生 JSON 結果。請查閱 '+$Child.Error)}
    return ($text.Substring($blocks[$blocks.Count-1].Index).Trim() | ConvertFrom-Json)
}
function Assert-MutSelectedUpgradeBackup {
    $path=[string]$script:State.UpgradeManifest
    if($script:State.PSObject.Properties.Name -notcontains 'UpgradeManifestSha256' -or $script:State.UpgradeManifestSha256 -cnotmatch '^[A-F0-9]{64}$'){Stop-MutReview '升級備份 manifest 雜湊缺少，無法繼續新版安裝。'}
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $script:State.UpgradeManifestSha256){Stop-MutReview '升級備份 manifest 已變更，沒有繼續安裝。'}
    $manifest=Assert-MutUpgradeBackup -ManifestPath $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $script:State.UpgradeManifestSha256){Stop-MutReview '核驗期間升級備份 manifest 已改變，沒有繼續安裝。'}
    return $manifest
}
function Invoke-MutUpgradeEntry {
    $script:Stage='健康舊版備份與升級'
    $old=Get-MutMediaProfile -Release 'SEW25091'
    $upgradePath=Join-Path $script:TaskRoot 'upgrade-state.json'
    $operations=@{
        Read={param($Path) Read-MutState -Path $Path}
        Save={param($Checkpoint) Write-MutState -Path (Join-Path $script:TaskRoot 'upgrade-state.json') -State $Checkpoint}
        Now={[datetime]::UtcNow}
        Boot={Get-MutBootUtc}
        Pending={Test-MutPendingRestart}
        Idle={Test-MutUpgradeIdle}
        ValidateOldState={param($OldState) Get-MutUpgradeStateDecision -State $OldState -TargetHash $script:MediaHash -KnownOldHash (Get-MutMediaProfile -Release SEW25091).MediaHash}
        VerifyOld={
            $savedProfile=$script:Profile;$savedHash=$script:MediaHash
            try{
                $script:Profile=Get-MutMediaProfile -Release SEW25091;$script:MediaHash=$script:Profile.MediaHash
                $check=Invoke-MutSqlCheck
                $check | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:RunRoot 'upgrade-source-checks.json') -Encoding UTF8
                if(!$check.Passed){Stop-MutReview ('舊版未通過完整健康驗收，沒有自動升級：'+($check.Findings -join '；'))}
            }finally{$script:Profile=$savedProfile;$script:MediaHash=$savedHash}
        }
        PrepareTarget={Prepare-MutMedia}
        PrepareOld={
            $source=Get-MutMediaProfile -Release SEW25091
            $archive=Join-Path $script:RepoRoot $source.ArchiveFileName
            if(!(Test-Path -LiteralPath $archive)){throw '健康舊版升級需要 SEW25091.zip 供原廠卸載。請將新舊两份原始 ZIP 放在 Install-MUT.cmd 旁。'}
            $null=Expand-MutVerifiedArchive -ArchivePath $archive -DestinationParent (Join-Path $script:TaskRoot 'upgrade-uninstall-media') -ExpectedHash $source.MediaHash -ExpectedRoot $source.ArchiveRoot
        }
        Confirm={Show-MutNotice -Kind Question -Confirm -Text "已確認健康的 SEW25091。接下來先完整備份應用程式及 44 個使用者資料庫，再由原廠 UNINST.BAT 解除舊版、重新啟動後安裝 SEW26061-00。`r`n原廠卸載會移除 C:\MUTSW 與 C:\MUTSW_SE；兩個已核對的健康 SQL 引擎會保留，沒有執行失敗 SQL 清理。`r`n請先關閉兩版 M.U.T. 程式。同意備份並升級嗎？"}
        ArchiveState={param($OldState)
            if(!$OldState){return [pscustomobject]@{Path='';Hash=''}}
            $directory=Join-Path $script:RunRoot 'backupmeta';$null=New-Item -ItemType Directory -Path $directory
            $path=Join-Path $directory 'oneclick-state.json'
            $before=(Get-FileHash -LiteralPath $script:StatePath -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $script:StatePath -Destination $path
            if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $before -or (Get-FileHash -LiteralPath $script:StatePath -Algorithm SHA256).Hash -cne $before){throw 'Original state changed while copying.'}
            return [pscustomobject]@{Path=$path;Hash=$before}
        }
        AssertStateArchive={param($Checkpoint) Assert-MutUpgradeStateArchive $Checkpoint}
        StartBackup={$script:Stage='升級前完整備份';Start-MutChild -Name 'Backup-MutUpgrade.ps1'}
        BackupStatus={param($Child) $script:Stage='監控升級備份';Get-MutBackupChildStatus $Child}
        ReadBackupSummary={param($Child) Read-MutBackupSummary $Child}
        Hash={param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
        AssertBackup={param($Path,$VerifySource) Assert-MutUpgradeBackup -ManifestPath $Path -VerifySource:$VerifySource}
        StartUninstall={Start-MutReviewedUpgradeUninstall}
        Uninstalled={return (!(Test-Path -LiteralPath 'C:\MUTSW') -and !(Test-Path -LiteralPath 'C:\MUTSW_SE') -and !(Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00'))}
        AssertSql={param($Manifest) $script:Stage='核驗升級保留的 SQL 引擎';Assert-MutPreservedSqlIdentity -Manifest $Manifest}
        Sleep={param($Seconds) Start-Sleep -Seconds $Seconds}
        Notice={param($Text) Show-MutNotice $Text}
    }
    $result=Invoke-MutHealthyUpgrade -StatePath $upgradePath -ExistingState $script:State -SourceHash $old.MediaHash -TargetHash $script:MediaHash -Operations $operations
    if($result.ReadyForInstall){
        $script:State=New-MutSelectedState
        $script:State.UpgradeManifest=$result.BackupManifest
        $script:State.UpgradeManifestSha256=$result.BackupManifestSha256
        Save-MutCheckpoint 'Checking'
    }
    return $result
}
function Test-MutCoordinatorCompletion {
    param($Status,[datetime]$StartedUtc)
    if(!$Status -or !$Status.time -or [datetime]::Parse($Status.time).ToUniversalTime() -lt $StartedUtc){return $false}
    if($Status.stage -ceq 'sql-engines-completed'){return $true}
    return ($Status.stage -ceq 'sql-engines-reused' -and $script:State.PSObject.Properties.Name -contains 'UpgradeManifest' -and !!$script:State.UpgradeManifest -and $script:State.PSObject.Properties.Name -contains 'UpgradeManifestSha256' -and $script:State.UpgradeManifestSha256 -cmatch '^[A-F0-9]{64}$')
}
function Invoke-MutPrerequisiteStage {
    $script:Stage='前置元件修復'
    Get-MutOfficialArchive
    Save-MutCheckpoint 'Prerequisites'
    $result=Start-MutChild -Name 'Repair-MutPrerequisites.ps1' -Wait
    if($result.ExitCode -eq 3010){return (Request-MutRestart -ResumePhase 'AfterPrerequisites' -Reason '.NET Framework 前置元件需要重啟。')}
    if($result.ExitCode -ne 0){throw ('前置修復退出碼 '+$result.ExitCode+'。詳見 '+$result.Identity.Error)}
    $status=Get-Content -LiteralPath (Join-Path $script:TaskRoot 'repair-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $verification=Test-MutPrerequisites -PackageRoot (Join-Path $script:TaskRoot 'ps2DLC\ps2DLC') -RepairLogRoot $status.logs
    $verification | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $script:RunRoot 'prerequisites.json') -Encoding UTF8
    if(!$verification.Passed){throw ('前置元件核驗失敗：'+($verification.Findings -join '；'))}
    return 0
}
function Invoke-MutApplicationConfirmation {
    param($Verification)
    $script:Stage='兩版本主畫面確認'
    Show-MutNotice "系統與 SQL 檢查已通過。請從桌面開啟兩個程式。`r`n若傳統版詢問 .js 開啟方式，選 Microsoft Windows Based Script Host，再按「一律／Always」。`r`n接下來只確認主畫面與版本；沒有連接 VCI 的測試不代表實車功能已驗證。"
    $classic=Show-MutNotice -Kind Question -Confirm -Text ('您已看到傳統版 M.U.T.-3 主畫面，底部為 '+$script:Profile.ClassicVersion+' 嗎？尚未確認請選「否」，之後可再執行同一入口。')
    $se=$false
    if($classic){$se=Show-MutNotice -Kind Question -Confirm -Text ('您已看到 M.U.T.-3 SE 主畫面，底部為 '+$script:Profile.SeVersion+' 嗎？')}
    $script:State.ApplicationConfirmation=[pscustomobject]@{Classic=[bool]$classic;SE=[bool]$se;Release=$script:Profile.Release;ClassicVersion=$script:Profile.ClassicVersion;SeVersion=$script:Profile.SeVersion;ConfirmedUtc=[datetime]::UtcNow.ToString('o');Source='User confirmation';VCITested=$false}
    if(!$classic -or !$se){Save-MutCheckpoint 'AwaitingApplicationConfirmation';Show-MutNotice -Kind Warning -Text '系統檢查已通過，但兩程式主畫面尚未全部確認。請依 README 完成開啟方式設定後再試。';return 2}
    Save-MutCheckpoint 'Completed'
    Show-MutNotice ('安裝與驗收完成：系統檢查通過，您已確認傳統版 '+$script:Profile.ClassicVersion+' 與 SE '+$script:Profile.SeVersion+' 主畫面。VCI／實車連線尚未測試。')
    return 0
}
function Wait-MutOriginalInstallation {
    $script:Stage='監控原廠完整安裝'
    if(!$script:State.InstallStartedUtc -or !$script:State.LogBefore){Stop-MutReview '缺少本輪安裝起點，無法安全接續；沒有啟動第二份安裝器。'}
    $started=[datetime]::Parse($script:State.InstallStartedUtc).ToUniversalTime()
    $deadline=$started.AddMinutes(90)
    $recoveredCompletion=$false
    # A later reboot may occur while this helper was closed. Reconcile completed
    # evidence before applying an expired active-observation deadline.
    if([datetime]::UtcNow -ge $deadline){
        $after=Get-MutInstLogEvidence -Path 'C:\MUTSW\InstLog.txt'
        $fresh=Test-MutFreshInstallLog -Before $script:State.LogBefore -After $after -StartedUtc $started
        $statusPath=Join-Path $script:TaskRoot 'sql-acl-coordinator-status.json'
        $status=if(Test-Path -LiteralPath $statusPath){Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
        $sqlPassed=Test-MutCoordinatorCompletion -Status $status -StartedUtc $started
        $rebootAfterLog=$after.Exists -and [datetime]::Parse((Get-MutBootUtc)).ToUniversalTime() -gt [datetime]::Parse($after.LastWriteUtc).ToUniversalTime()
        $recoveredCompletion=Test-MutRecoveredCompletion -FreshLog $fresh -SqlReady $sqlPassed -Busy (@(Get-MutInstallerProcesses).Count -gt 0) -RebootAfterLog $rebootAfterLog
        if(!$recoveredCompletion){Stop-MutReview '先前安裝已超過監控期限，且沒有完整的本輪成功與重啟證據。請查閱日誌；沒有啟動第二份安裝。'}
        $deadline=[datetime]::UtcNow.AddSeconds(30)
    }
    $idleSince=$null
    while([datetime]::UtcNow -lt $deadline){
        $busy=@(Get-MutInstallerProcesses)
        $coordinatorAlive=Test-MutChildAlive $script:State.Coordinator
        $statusPath=Join-Path $script:TaskRoot 'sql-acl-coordinator-status.json'
        $sqlPassed=$false
        if(Test-Path -LiteralPath $statusPath){
            try{$status=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json}catch{$status=$null}
            if($status -and [datetime]::Parse($status.time).ToUniversalTime() -ge $started){
                if($status.stage -eq 'stopped-review-required'){Stop-MutReview ('SQL 監控停止：'+$status.message+'。原廠程序未被終止；請勿另開安裝。')}
                $sqlPassed=Test-MutCoordinatorCompletion -Status $status -StartedUtc $started
            }
        }
        if(!$coordinatorAlive -and !$sqlPassed -and ([datetime]::UtcNow-$started).TotalSeconds -gt 15){Stop-MutReview '本輪 SQL 監控已結束且沒有成功結果。請檢查子程序日誌；原廠安裝器保留，沒有重新啟動。'}
        try{$after=Get-MutInstLogEvidence -Path 'C:\MUTSW\InstLog.txt'}
        catch [System.IO.IOException]{Start-Sleep -Seconds 2;continue}
        catch [System.Text.DecoderFallbackException]{Start-Sleep -Seconds 2;continue}
        $fresh=Test-MutFreshInstallLog -Before $script:State.LogBefore -After $after -StartedUtc $started
        if(!$busy.Count -and !$coordinatorAlive){
            if(!$idleSince){$idleSince=[datetime]::UtcNow}
            if(([datetime]::UtcNow-$idleSince).TotalSeconds -ge 10){
                $decision=Get-MutMonitorDecision -FreshLog $fresh -SqlReady $sqlPassed -Busy $false -IdleSeconds ([int]([datetime]::UtcNow-$idleSince).TotalSeconds) -ElapsedSeconds ([int]([datetime]::UtcNow-$started).TotalSeconds)
                if($decision -eq 'Complete' -or ($recoveredCompletion -and $fresh -and $sqlPassed)){
                    $script:State.InstallCompletedUtc=[datetime]::UtcNow.ToString('o')
                    Save-MutCheckpoint 'InstallationFinished'
                    if([datetime]::Parse((Get-MutBootUtc)).ToUniversalTime() -gt [datetime]::Parse($after.LastWriteUtc).ToUniversalTime()){
                        Save-MutCheckpoint 'AfterInstall'
                        return (Invoke-MutAuto)
                    }
                    return (Request-MutRestart -ResumePhase 'AfterInstall' -Reason '原廠本輪安裝檢查已完成，請重新開機後驗收。')
                }
                Stop-MutReview '安裝程序已結束，但本輪 SQL 或原廠最後檢查未通過。請查看日誌；不會把舊成功紀錄當成本次成功。'
            }
        }else{$idleSince=$null}
        Start-Sleep -Seconds 2
    }
    Stop-MutReview '完整安裝監控已達 90 分鐘。助手已停止等待，原廠安裝器仍保留；請檢查目前畫面與日誌，不要再開第二份。'
}
function Invoke-MutOriginalUninstall {
    param([switch]$Resume)
    $script:Stage='原廠解除安裝'
    $process=$null
    if(!$Resume){
        $script:State.UninstallStartedUtc=[datetime]::UtcNow.ToString('o')
        Save-MutCheckpoint 'Uninstalling'
        $entry=Join-Path (Join-Path $script:TaskRoot $script:Profile.ArchiveRoot) 'UNINSTALLER\UNINST.BAT'
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /s /c ""'+$entry+'""') -WorkingDirectory (Split-Path -Parent $entry) -WindowStyle Hidden -PassThru
    }
    $deadline=[datetime]::Parse($script:State.UninstallStartedUtc).ToUniversalTime().AddMinutes(45)
    $idleSince=$null
    while([datetime]::UtcNow -lt $deadline){
        $busy=@(Get-MutInstallerProcesses)
        if($process){$process.Refresh()}
        if(!$busy.Count -and (!$process -or $process.HasExited)){
            if(!$idleSince){$idleSince=[datetime]::UtcNow}
            if(([datetime]::UtcNow-$idleSince).TotalSeconds -ge 10){
                if((Test-Path -LiteralPath 'C:\MUTSW') -or (Test-Path -LiteralPath 'C:\MUTSW_SE') -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00')){Stop-MutReview '原廠解除安裝取消或仍有殘留。請檢查原廠結果，助手沒有刪除目錄或資料。'}
                return (Request-MutRestart -ResumePhase 'AfterUninstall' -Reason '原廠解除安裝已結束，需要完成這次重新開機。')
            }
        }else{$idleSince=$null}
        Start-Sleep -Seconds 2
    }
    Stop-MutReview '原廠解除安裝超過 45 分鐘。程序未被終止，請先检查目前畫面。'
}
function Invoke-MutFailedCleanup {
    $script:Stage='核對失敗安裝與清理目標'
    # Read-only preflight invokes the exact same strict allowlist used by removal.
    $inspect=Start-MutChild -Name 'Remove-FailedMutSqlInstances.ps1' -Arguments '-InspectOnly' -Wait
    if($inspect.ExitCode -ne 0){Stop-MutReview ('現有安裝不符合已審查的失敗 SQL 清理條件。請先備份並人工排查。詳見 '+$inspect.Identity.Output)}
    $inspection=Get-Content -LiteralPath (Join-Path $script:TaskRoot 'sql-instance-removal-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $targets=@($inspection.targets.PSObject.Properties | Where-Object {$_.Value.state -eq 'verified-failed-instance'} | ForEach-Object {$_.Name})
    if(!$targets.Count){Stop-MutReview '仍有 M.U.T. 資料，但沒有可辨識的失敗 SQL 目標；不自動解除安裝或刪除資料。'}
    $description='已核對的失敗 SQLENGINE：'+($targets -join '、')+"。`r`n將依序啟動原廠 M.U.T. 解除安裝及限定 SQL 清理。C:\MUTSW 與 C:\MUTSW_SE 內的資料可能由原廠移除。`r`n您是否已備份所需資料，並同意清理這些失敗安裝？選「否」不會執行清理。"
    return (Invoke-MutConfirmedCleanup -Confirm {Show-MutNotice -Text $description -Kind Question -Confirm} -Uninstall {
        if((Test-Path -LiteralPath 'C:\MUTSW') -or (Test-Path -LiteralPath 'C:\MUTSW_SE') -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00')){return (Invoke-MutOriginalUninstall)}
        return 0
    } -Remove {
        Save-MutCheckpoint 'RemovingFailedSql'
        $removed=Start-MutChild -Name 'Remove-FailedMutSqlInstances.ps1' -Wait
        if($removed.ExitCode -eq 3010){return (Request-MutRestart -ResumePhase 'AfterSqlCleanup' -Reason 'SQL 清理新增了待重啟的檔案操作。')}
        if($removed.ExitCode -ne 0){throw ('SQL 清理失敗，退出碼 '+$removed.ExitCode+'。詳見 '+$removed.Identity.Output)}
        return 0
    })
}
function Invoke-MutCheckMode {
    $busy=@(Get-MutInstallerProcesses)
    if($busy.Count){Stop-MutReview '有安裝程序正在執行；唯讀檢查不會把中途狀態判定為成功。'}
    $verification=Invoke-MutSqlCheck
    $verification | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:RunRoot 'checks.json') -Encoding UTF8
    if(!$verification.Passed){Stop-MutReview ('唯讀驗收有待處理項目：'+($verification.Findings -join '；'))}
    if(Test-MutPendingRestart){Stop-MutReview 'SQL 與安裝紀錄檢查通過，但 Windows 有待重啟狀態。請儲存工作並重啟後再驗收。' 3010}
    if([datetime]::Parse((Get-MutBootUtc)).ToUniversalTime() -le [datetime]::Parse($verification.InstLog.LastWriteUtc).ToUniversalTime()){Stop-MutReview '尚未確認最後安裝檢查之後的重新開機。請重啟後再次執行唯讀檢查。' 3010}
    Show-MutNotice ('唯讀檢查通過。沒有執行安裝或清理。此結果不代表已重新確認兩程式主畫面或 VCI。'+"`r`nSQL 報告："+$verification.SqlReport)
    return 0
}
function Invoke-MutAuto {
    $script:State=Read-MutState -Path $script:StatePath
    if($script:State -and $script:State.Machine -ne $env:COMPUTERNAME){Stop-MutReview '進度檔屬於其他電腦，無法自動接續。請保留進度檔與日誌並排查。'}
    if(Test-MutUpgradeRequested){
        $upgrade=Invoke-MutUpgradeEntry
        if(!$upgrade.ReadyForInstall){return $upgrade.ExitCode}
    }
    if($script:State -and $script:State.MediaHash -ne $script:MediaHash){
        if($script:State.Phase -eq 'Completed'){Stop-MutReview '偵測到其他版本已完成的安裝紀錄。請先備份既有 M.U.T. 與資料庫，再使用已核對的升級流程；目前不會直接解除安裝，也不會沿用舊版完成狀態。'}
        Stop-MutReview '進度檔屬於其他安裝包且尚未完成，無法切換版本接續。請保留進度檔及日誌，完成或排查原流程後再升級。'
    }
    if(!$script:State){$script:State=New-MutSelectedState}
    foreach($required in @('SchemaVersion','Machine','MediaHash','Phase','BootUtc','ResumePhase','UpdatedUtc','InstallStartedUtc','InstallCompletedUtc','LogBefore','Coordinator','UninstallStartedUtc','ApplicationConfirmation')){
        if($script:State.PSObject.Properties.Name -notcontains $required){Stop-MutReview ('進度檔缺少欄位 '+$required+'；請保留原檔與日誌，不會開始變更。')}
    }
    if($script:State.Phase -notin @('Checking','Installing','InstallReviewRequired','AwaitingReboot','Prerequisites','AfterPrerequisites','Uninstalling','UninstallReviewRequired','AfterUninstall','RemovingFailedSql','AfterSqlCleanup','InstallationFinished','AfterInstall','AwaitingApplicationConfirmation','Completed')){Stop-MutReview '進度檔有未知階段；已停止，請保留進度檔供排查。'}
    $validatedUpgradeManifest=$null
    if($script:State.PSObject.Properties.Name -contains 'UpgradeManifest' -and $script:State.UpgradeManifest){
        if($script:Profile.Release -cne 'SEW26061-00'){Stop-MutReview '升級備份只適用已審查的 SEW26061-00 目標。'}
        $validatedUpgradeManifest=Assert-MutSelectedUpgradeBackup
    }
    $boot=Get-MutBootUtc
    $busy=@(Get-MutInstallerProcesses)
    if($script:State.Phase -eq 'Uninstalling'){
        if($busy.Count -and @($busy | Where-Object {$_.CreationDate.ToUniversalTime() -lt [datetime]::Parse($script:State.UninstallStartedUtc).ToUniversalTime()}).Count){Stop-MutReview '有早於本輪解除安裝的未知程序，無法安全接續。'}
        return (Invoke-MutOriginalUninstall -Resume)
    }
    if($script:State.Phase -eq 'Installing'){
        if($busy.Count -and @($busy | Where-Object {$_.CreationDate.ToUniversalTime() -lt [datetime]::Parse($script:State.InstallStartedUtc).ToUniversalTime()}).Count){Stop-MutReview '發現早於本輪的安裝程序，無法確認歸屬。沒有再啟動安裝器。'}
        $knownCoordinatorPid=0
        if($script:State.Coordinator -and (Test-MutChildAlive $script:State.Coordinator)){$knownCoordinatorPid=[int]$script:State.Coordinator.Pid}
        $unknown=@($busy | Where-Object {
            $knownHelper=$knownCoordinatorPid -gt 0 -and $_.ExecutablePath -ieq $script:NativePS -and ($_.ProcessId -eq $knownCoordinatorPid -or $_.ParentProcessId -eq $knownCoordinatorPid)
            !$knownHelper -and (!$_.ExecutablePath -or ($_.ExecutablePath -notlike ((Join-Path $script:TaskRoot $script:Profile.ArchiveRoot)+'\*') -and $_.ExecutablePath -notlike '*\Microsoft SQL Server\*'))
        })
        if($unknown.Count){Stop-MutReview '接續時發現來源不明或位於暫存目錄的安裝程序，無法確認歸屬。請先完成原視窗；没有啟動第二份。'}
        return (Wait-MutOriginalInstallation)
    }
    if($busy.Count){Stop-MutReview '目前有原廠／SQL 安裝或解除安裝程序正在執行。請先完成現有視窗，不要同時啟動第二份。'}
    if($script:State.Phase -eq 'AwaitingReboot'){
        if([datetime]::Parse($boot) -le [datetime]::Parse($script:State.BootUtc)){return (Request-MutRestart -ResumePhase $script:State.ResumePhase -Reason '尚未偵測到要求之後的重新開機。')}
        Save-MutCheckpoint $script:State.ResumePhase
    }
    if(Test-MutPendingRestart){return (Request-MutRestart -ResumePhase $script:State.Phase -Reason 'Windows 有待完成的重啟操作。')}
    $services=@(Get-Service -Name 'MSSQL$MUT3','MSSQL$CAESARCOMPDB' -ErrorAction SilentlyContinue)
    if($services.Count -eq 2 -and @($services | Where-Object {$_.Status -eq 'Running'}).Count -eq 2 -and (Test-MutInstalledFiles)){
        $verification=Invoke-MutSqlCheck
        $verification | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:RunRoot 'checks.json') -Encoding UTF8
        if(!$verification.Passed){Stop-MutReview ('既有服務正在運作但验收未通過；不會自動解除安裝。'+($verification.Findings -join '；'))}
        $logTime=[datetime]::Parse($verification.InstLog.LastWriteUtc).ToUniversalTime()
        if([datetime]::Parse($boot).ToUniversalTime() -le $logTime){return (Request-MutRestart -ResumePhase 'AfterInstall' -Reason '尚未確認最後安裝檢查之後的重新開機。')}
        if($script:State.ApplicationConfirmation -and $script:State.ApplicationConfirmation.Classic -and $script:State.ApplicationConfirmation.SE){Save-MutCheckpoint 'Completed';Show-MutNotice '既有安裝驗收通過，先前已確認兩個主畫面。沒有重新安裝或清理。';return 0}
        return (Invoke-MutApplicationConfirmation $verification)
    }
    if($script:State.Phase -eq 'AfterInstall'){Stop-MutReview '安裝後重啟驗收未通過，請檢查服務與日誌；不會自動清理剛完成的安裝。'}
    foreach($legacyRoot in @($env:ProgramFiles,${env:ProgramFiles(x86)})){
        if($legacyRoot -and (Test-Path -LiteralPath (Join-Path $legacyRoot 'MUT3'))){Stop-MutReview ('發現舊版資料目錄 '+(Join-Path $legacyRoot 'MUT3')+'。原廠新安裝可能移除此目錄，請先備份並人工排查。')}
    }
    if(Test-Path -LiteralPath 'HKLM:\SOFTWARE\MMC\Mut3'){Stop-MutReview '發現非本次已核對的原生登錄檢視 M.U.T. 設定，請先人工確認既有版本。'}
    $classicRegistry=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00' -ErrorAction SilentlyContinue
    if($classicRegistry -and $classicRegistry.TYPE -cne $script:Profile.ClassicVersion){Stop-MutReview '發現其他傳統版版本，不套用本次限定清理或安裝。'}
    $remnants=@(Get-MutTargetRegistryRemnants)
    foreach($remnant in $remnants){if(!@($services | Where-Object {$_.Name -eq ('MSSQL$'+$remnant.Instance)}).Count){Stop-MutReview ('發現 SQL 登錄殘留但對應服務不存在：'+$remnant.Instance+'。未知殘留需人工排查，沒有修改前置元件或啟動安裝。')}}
    Prepare-MutMedia
    $hasMut=(Test-Path -LiteralPath 'C:\MUTSW') -or (Test-Path -LiteralPath 'C:\MUTSW_SE') -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00')
    $preservedUpgrade=$script:State.PSObject.Properties.Name -contains 'UpgradeManifest' -and !!$script:State.UpgradeManifest
    if($preservedUpgrade){
        if($script:Profile.Release -cne 'SEW26061-00' -or $hasMut -or $services.Count -ne 2){Stop-MutReview '升級接續狀態與卸載後現場不符：必須沒有舊應用程式殘留且保留兩個已備份 SQL 引擎。沒有執行失敗 SQL 清理。'}
        $null=Assert-MutPreservedSqlIdentity -Manifest $validatedUpgradeManifest
    }elseif($hasMut -or $services.Count){$cleanup=Invoke-MutFailedCleanup;if($cleanup -ne 0){return $cleanup}}
    $prereq=Invoke-MutPrerequisiteStage
    if($prereq -ne 0){return $prereq}
    $script:Stage='啟動原廠安裝'
    Show-MutNotice "即將啟動原廠完整安裝。請在 Version Checker 選「是」，地區選 Other 並按 Install。若出現驅動精靈，完成「下一步／完成」。`r`n請保持助手與原廠視窗開啟，其他修復及檢查會自動處理。"
    $script:State.LogBefore=Get-MutInstLogEvidence -Path 'C:\MUTSW\InstLog.txt'
    $script:State.InstallStartedUtc=[datetime]::UtcNow.ToString('o')
    $script:State.BootUtc=Get-MutBootUtc
    $script:State.ApplicationConfirmation=$null
    Save-MutCheckpoint 'Installing'
    $coordinatorArguments=''
    if($preservedUpgrade){$coordinatorArguments='-UpgradeManifest "'+$script:State.UpgradeManifest+'" -UpgradeManifestHash '+$script:State.UpgradeManifestSha256}
    $script:State.Coordinator=Start-MutChild -Name 'Start-MutInstallWithSqlAcl.ps1' -Arguments $coordinatorArguments
    Save-MutCheckpoint 'Installing'
    return (Wait-MutOriginalInstallation)
}

if($LibraryOnly){return}
$code=1
$mutex=$null
$locked=$false
try {
    if($NoUI -and $Mode -ne 'Check'){throw '-NoUI 僅可搭配 -Mode Check，安裝與清理需要互動確認。'}
    if(![Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw '請使用 64 位元 Windows PowerShell 5.1，或雙擊 Install-MUT.cmd。'}
    $os=Get-CimInstance Win32_OperatingSystem
    if([int]$os.BuildNumber -lt 22000 -or $os.ProductType -ne 1){throw '此入口適用 Windows 11 x64 用戶端系統。'}
    $cpuArchitectures=@(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Architecture -Unique)
    if(!$cpuArchitectures.Count -or @($cpuArchitectures | Where-Object {$_ -ne 9}).Count){throw '此入口只接受 x64（AMD64／Intel 64）電腦；ARM64 與 32 位元系統尚未驗證。'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        try{
            $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode '+$Mode+' -Release '+$Release
            if($NoUI){$arguments+=' -NoUI'}
            $windowStyle=if($NoUI){'Hidden'}else{'Normal'}
            $elevated=Start-Process -FilePath $script:NativePS -ArgumentList $arguments -Verb RunAs -PassThru -WindowStyle $windowStyle
            $null=$elevated.Handle;$elevated.WaitForExit();$elevated.Refresh();exit $elevated.ExitCode
        }catch{
            $native=$_.Exception.NativeErrorCode
            if(!$native -and $_.Exception.InnerException){$native=$_.Exception.InnerException.NativeErrorCode}
            $code=Resolve-MutElevationResult -NativeErrorCode $native
            Show-MutNotice -Kind Warning -Text ('管理員授權未完成，沒有開始安裝。原始訊息：'+$_.Exception.Message)
            exit $code
        }
    }
    $mutex=New-Object Threading.Mutex($false,'Global\MUT-SEW25091-OneClick')
    Assert-MutSingleInstance -TryAcquire {try{return $mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{return $true}}
    $locked=$true
    $script:RunRoot=Join-Path $script:TaskRoot ('oneclick-logs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=New-Item -ItemType Directory -Path $script:RunRoot -Force
    Assert-MutHelpers
    Import-Module (Join-Path $PSScriptRoot 'Mut-MediaProfiles.psm1') -Force
    $script:Profile=Get-MutMediaProfile -Release $Release
    $script:MediaHash=$script:Profile.MediaHash
    Import-Module (Join-Path $PSScriptRoot 'Mut-OneClick.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Mut-Prerequisites.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Mut-Upgrade.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Mut-Upgrade.Workflow.psm1') -Force
    $code=Invoke-MutDispatch -Mode $Mode -CheckAction {Invoke-MutCheckMode} -AutoAction {Invoke-MutAuto}
}catch{
    $code=if($_.Exception.Data.Contains('MutExitCode')){[int]$_.Exception.Data['MutExitCode']}else{1}
    $errorText=$_.Exception.Message
    $script:RawError=[pscustomobject]@{Message=$errorText;HResult=('0x{0:X8}' -f $_.Exception.HResult);NativeErrorCode=$_.Exception.NativeErrorCode}
    if($Mode -eq 'Auto' -and $script:State -and $script:State.Phase -in @('Installing','Uninstalling')){
        try{Save-MutCheckpoint $(if($script:State.Phase -eq 'Installing'){'InstallReviewRequired'}else{'UninstallReviewRequired'})}catch{Write-Host '無法更新進度檔；請保留原始日誌。'}
    }
    if($script:RunRoot){$_ | Out-String | Set-Content -LiteralPath (Join-Path $script:RunRoot 'failure.txt') -Encoding UTF8}
    Show-MutNotice -Kind $(if($code -eq 3010){'Information'}elseif($code -eq 2){'Warning'}else{'Error'}) -Text ("階段："+$script:Stage+"`r`n此階段尚未通過；請依下方原始訊息處理，保留日誌供排查。`r`n原始訊息："+$errorText+"`r`n退出碼："+$code+"；例外代碼："+$script:RawError.HResult+"`r`n詳細紀錄："+$script:RunRoot+"`r`n請先處理上述原因，再執行同一入口；不要同時開另一份原廠安裝器。")
}finally{
    [object[]]$finalFindings=@()
    if($script:Verification){$finalFindings=@($script:Verification.Findings)}
    if($script:RunRoot){[ordered]@{SchemaVersion=1;Mode=$Mode;Release=$Release;ExitCode=$code;Status=$(switch($code){0{'ModeChecksPassed'}3010{'AwaitingReboot'}1223{'Cancelled'}2{'ReviewRequired'}default{'Failed'}});Stage=$script:Stage;FinishedUtc=[datetime]::UtcNow.ToString('o');LogDirectory=$script:RunRoot;StatePath=$(if($Mode -eq 'Auto'){$script:StatePath}else{$null});UpgradeStatePath=$(if($Mode -eq 'Auto' -and (Test-Path -LiteralPath (Join-Path $script:TaskRoot 'upgrade-state.json'))){Join-Path $script:TaskRoot 'upgrade-state.json'}else{$null});ChecksReport=$(if(Test-Path -LiteralPath (Join-Path $script:RunRoot 'checks.json')){Join-Path $script:RunRoot 'checks.json'}else{$null});SqlReport=$(if($script:Verification){$script:Verification.SqlReport}else{$null});Findings=$finalFindings;Error=$script:RawError;ApplicationConfirmation=$(if($Mode -eq 'Auto' -and $script:State -and $script:State.MediaHash -ceq $script:MediaHash){$script:State.ApplicationConfirmation}else{$null});VCITested=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:RunRoot 'result.json') -Encoding UTF8}
    if($locked -and $mutex){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
exit $code
