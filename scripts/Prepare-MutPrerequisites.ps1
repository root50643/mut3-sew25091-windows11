[CmdletBinding()]
param(
    [ValidateSet('Prepare','Check')][string]$Mode='Prepare',
    [ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW26061-00',
    [switch]$NoUI,
    [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
$script:TaskRoot='C:\MUT-Install'
$script:NativePS=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:ArchiveHash='D9812E7BE1F72FF49D73F3179E207AA0000852D9D0EFD92455AD376FAD5D9B7C'
$script:RunRoot=$null;$script:Stage='啟動檢查';$script:Report=$null

# Injectable workflow intentionally has no application install, uninstall,
# backup, SQL-engine installation or service-start operation.
function Invoke-MutPreparationWorkflow {
    param([ValidateSet('Prepare','Check')][string]$Mode,[Parameter(Mandatory=$true)][hashtable]$Operations)
    $result=[ordered]@{ExitCode=1;Prerequisites=$null;SqlPlan=$null;RepairedInstances=@()}
    if(& $Operations.Busy){throw '已有安裝或修復正在執行，請先完成原視窗。'}
    if($Mode -eq 'Prepare' -and (& $Operations.PendingRestart)){$result.ExitCode=3010;return [pscustomobject]$result}
    if($Mode -eq 'Prepare'){& $Operations.PrepareSource | Out-Null}
    $result.Prerequisites=& $Operations.Verify
    if($Mode -eq 'Prepare' -and !$result.Prerequisites.Passed){
        $repair=& $Operations.Repair
        if($repair.ExitCode -eq 3010){$result.ExitCode=3010;return [pscustomobject]$result}
        if($repair.ExitCode -ne 0){throw ('前置元件修復退出碼 '+$repair.ExitCode+'。'+$repair.Error)}
        $result.Prerequisites=& $Operations.VerifyFresh $repair
        if(!$result.Prerequisites.Passed){throw ('載入器已結束，但元件核驗失敗：'+($result.Prerequisites.Findings -join '；'))}
    }
    $result.SqlPlan=& $Operations.SqlPlan
    if($Mode -eq 'Prepare' -and $result.Prerequisites.Passed -and !$result.SqlPlan.ReviewRequired){
        foreach($instance in @($result.SqlPlan.RepairInstances)){
            $current=& $Operations.SqlPlan
            $reviewItems=@($current.Items | Where-Object {$_.Action -eq 'Review'})
            $blocking=@($reviewItems | Where-Object {$_.Instance -notin $result.RepairedInstances -or $_.Reason -cne 'NativeGrantAlreadyPresent'})
            if(($current.ReviewRequired -and (!$reviewItems.Count -or $blocking.Count)) -or $instance -notin @($current.RepairInstances)){throw 'SQL 狀態已變更，已停止權限修復。'}
            $repair=& $Operations.RepairSql $instance
            if($repair.ExitCode -ne 0 -or !$repair.Verified){throw ('SQL 權限修復未通過：'+$instance+'。'+$repair.Error)}
            $result.RepairedInstances+= $instance
        }
    }
    $result.ExitCode=if(!$result.Prerequisites.Passed -or $result.SqlPlan.ReviewRequired -or ($Mode -eq 'Check' -and @($result.SqlPlan.RepairInstances).Count)){2}elseif($result.RepairedInstances.Count){3010}else{0}
    return [pscustomobject]$result
}
function Write-MutPreparationJson {
    param($Value,[string]$Path)
    Assert-MutPreparationWorkPath $Path
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($true)));Move-Item -LiteralPath $temp -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
}
function Assert-MutPreparationWorkPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if($full -ine 'C:\MUT-Install' -and !$full.StartsWith('C:\MUT-Install\',[StringComparison]::OrdinalIgnoreCase)){throw '工作路徑超出預期目錄。'}
    while($full){
        if(Test-Path -LiteralPath $full){if(((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('工作路徑包含連結，已停止：'+$full)}}
        $parent=[IO.Path]::GetDirectoryName($full.TrimEnd('\'));if(!$parent -or $parent -eq $full){break};$full=$parent
    }
}
function Show-MutPreparationNotice {
    param([string]$Text,[string]$Kind='Information')
    Write-Host $Text
    if($script:RunRoot){Add-Content -LiteralPath (Join-Path $script:RunRoot 'events.log') -Value ((Get-Date -Format o)+' ['+$script:Stage+'] '+$Text) -Encoding UTF8}
    if(!$NoUI){Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($Text,'M.U.T. 前置元件準備',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::$Kind)}
}
function Assert-MutPreparationHelpers {
    $pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'oneclick-helper-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($name in @('Prepare-MutPrerequisites.ps1','Mut-OneClick.Core.psm1','Mut-Prerequisites.psm1','Mut-PrerequisiteSql.psm1','Repair-MutPrerequisites.ps1','Repair-MutSqlLegacyAcl.ps1')){
        $pin=$pins.PSObject.Properties[$name]
        if(!$pin -or $pin.Value -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -cne $pin.Value){throw ('程式檔案校驗失敗：'+$name+'。請重新下載完整專案。')}
    }
}
function Get-MutPreparationBusy {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and (
            $_.Name -match '^(MUT3Check|MUT3INSTALL|MUT3UNINSTALL|MT3NSTLL|MT3NNSTLL|setup|setup100|scenarioengine|DPInst|msiexec|en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935)\.exe$' -or
            ($_.Name -ieq 'powershell.exe' -and $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\(Repair-MutPrerequisites|Repair-MutSqlLegacyAcl|Start-MutInstallWithSqlAcl|Backup-MutUpgrade|loadGAC)\.ps1(?:"|\s|$)')
        )
    } | Select-Object Name,ProcessId,CreationDate)
}
function Test-MutPreparationPending {
    foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')){if(Test-Path -LiteralPath $path){return $true}}
    if(@((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations | Where-Object {$_}).Count){return $true}
    $path=Join-Path $script:TaskRoot 'prerequisite-state.json'
    if(Test-Path -LiteralPath $path){
        $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($state.SchemaVersion -ne 1 -or $state.Machine -cne $env:COMPUTERNAME -or $state.Phase -notin @('AwaitingReboot','Ready','ReviewRequired')){throw '前置元件進度檔無法辨識，請保留日誌供檢查。'}
        if($state.Phase -eq 'AwaitingReboot' -and (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() -le [datetime]::Parse($state.BootUtc).ToUniversalTime()){return $true}
    }
    return $false
}
function Prepare-MutMicrosoftSource {
    $script:Stage='核對 Microsoft 補充元件'
    $target=Join-Path $script:TaskRoot 'ps2DLC.zip'
    if(!(Test-Path -LiteralPath $target)){
        $local=Join-Path (Split-Path -Parent $PSScriptRoot) 'ps2DLC.zip'
        if(!(Test-Path -LiteralPath $local)){throw '缺少 ps2DLC.zip。請重新下載完整專案，保留此檔案原樣。'}
        if((Get-FileHash -LiteralPath $local).Hash -cne $script:ArchiveHash){throw 'ps2DLC.zip 雜湊不符，已停止，沒有執行其中的檔案。'}
        Copy-Item -LiteralPath $local -Destination $target
    }
    $null=Expand-MutVerifiedArchive -ArchivePath $target -DestinationParent (Join-Path $script:TaskRoot 'ps2DLC') -ExpectedHash $script:ArchiveHash -ExpectedRoot 'ps2DLC'
    $locale=(Get-WinSystemLocale).Name
    foreach($arch in @('AMD64','x86')){
        if(!(Test-Path -LiteralPath (Join-Path $script:TaskRoot ('ps2DLC\ps2DLC\ResourceBinaries\'+$arch+'\'+$locale)) -PathType Container)){throw ('Microsoft 套件不包含目前系統語系：'+$locale+' / '+$arch+'。')}
    }
}
function Get-MutPreparationEvidence {
    param([string]$RepairLogRoot)
    $archive=Join-Path $script:TaskRoot 'ps2DLC.zip'
    if(!(Test-Path -LiteralPath $archive)){return [pscustomobject]@{Passed=$false;Findings=@('尚無已核對的 Microsoft 補充元件來源。')}}
    $manifest=Get-MutZipManifest -ArchivePath $archive -ExpectedHash $script:ArchiveHash -ExpectedRoot 'ps2DLC'
    & (Get-Module Mut-OneClick.Core) {param($Target,$Manifest) Assert-MutExtractedTree -Target $Target -Manifest $Manifest} (Join-Path $script:TaskRoot 'ps2DLC\ps2DLC') $manifest
    if(!$RepairLogRoot){
        $path=Join-Path $script:TaskRoot 'repair-status.json'
        if(Test-Path -LiteralPath $path){$status=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json;$RepairLogRoot=[string]$status.logs}
    }
    if(!$RepairLogRoot){return [pscustomobject]@{Passed=$false;Findings=@('尚無已核對的元件修復紀錄。')}}
    $resolved=[IO.Path]::GetFullPath($RepairLogRoot)
    if(!$resolved.StartsWith('C:\MUT-Install\repair-logs\',[StringComparison]::OrdinalIgnoreCase)){throw '元件紀錄路徑不在預期工作目錄。'}
    return Test-MutPrerequisites -PackageRoot (Join-Path $script:TaskRoot 'ps2DLC\ps2DLC') -RepairLogRoot $resolved
}
function Start-MutPreparationChild {
    param([string]$Name,[string]$Arguments='')
    Assert-MutPreparationHelpers
    if(@(Get-MutPreparationBusy).Count){throw '發現其他安裝程序，已停止啟動元件修復。'}
    $prefix=Join-Path $script:RunRoot ($Name+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $started=[datetime]::UtcNow
    $p=Start-Process -FilePath $script:NativePS -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot $Name)+'" '+$Arguments) -WindowStyle Hidden -PassThru -RedirectStandardOutput ($prefix+'.out.txt') -RedirectStandardError ($prefix+'.err.txt')
    $null=$p.Handle
    if(!$p.WaitForExit(1200000)){throw ('元件修復超過 20 分鐘。程序保留，請先檢查日誌，不要重開另一份：'+$prefix)}
    $p.WaitForExit()
    $p.Refresh();return [pscustomobject]@{ExitCode=$p.ExitCode;StartedUtc=$started.ToString('o');Error=[IO.File]::ReadAllText($prefix+'.err.txt')}
}
function Invoke-MutPreparationRepair {
    $script:Stage='安裝缺少的前置元件'
    Write-Host '正在準備 .NET Framework 與 Microsoft 補充元件，請等候。完成後由您手動安裝 M.U.T. 主程式。'
    return Start-MutPreparationChild -Name 'Repair-MutPrerequisites.ps1' -Arguments ('-Release '+$Release)
}
function Get-MutPreparationFreshEvidence {
    param($Repair)
    $status=Get-Content -LiteralPath (Join-Path $script:TaskRoot 'repair-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if([datetime]::Parse($status.time).ToUniversalTime() -lt [datetime]::Parse($Repair.StartedUtc).ToUniversalTime()){throw '修復紀錄不是本輪新增，不能將舊紀錄當成成功。'}
    return Get-MutPreparationEvidence -RepairLogRoot $status.logs
}
function Invoke-MutPreparationSqlRepair {
    param([ValidateSet('MUT3','CAESARCOMPDB')][string]$Instance)
    $script:Stage='限定 SQL 權限修復：'+$Instance
    $repair=Start-MutPreparationChild -Name 'Repair-MutSqlLegacyAcl.ps1' -Arguments ('-Instance '+$Instance)
    $verified=$false
    if($repair.ExitCode -eq 0){
        $status=Get-Content -LiteralPath (Join-Path $script:TaskRoot ('sql-acl-repair-status-'+$Instance+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        $verified=$status.stage -ceq 'applied-review-required' -and [datetime]::Parse($status.time).ToUniversalTime() -ge [datetime]::Parse($repair.StartedUtc).ToUniversalTime()
    }
    return [pscustomobject]@{ExitCode=$repair.ExitCode;Verified=$verified;Error=$repair.Error}
}
if($LibraryOnly){return}
$code=1;$mutex=$null;$locked=$false;$rawError=$null
try {
    if($NoUI -and $Mode -ne 'Check'){throw '-NoUI 僅可搭配唯讀 -Mode Check。'}
    if(![Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw '請雙擊 Install-Prerequisites.cmd，使用 Windows 內建 64 位元 PowerShell 5.1。'}
    $os=Get-CimInstance Win32_OperatingSystem
    if([int]$os.BuildNumber -lt 22000 -or $os.ProductType -ne 1 -or $env:SystemRoot -ine 'C:\Windows'){throw '此入口適用安裝於 C:\Windows 的 Windows 11 x64 用戶端。'}
    $architectures=@(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Architecture -Unique)
    if(!$architectures.Count -or @($architectures | Where-Object {$_ -ne 9}).Count){throw '此入口只適用 x64 電腦。'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        try{
            $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode '+$Mode+' -Release '+$Release
            if($NoUI){$arguments+=' -NoUI'};$style=if($NoUI){'Hidden'}else{'Normal'}
            $elevated=Start-Process -FilePath $script:NativePS -ArgumentList $arguments -Verb RunAs -WindowStyle $style -PassThru
            $null=$elevated.Handle;$elevated.WaitForExit();$elevated.Refresh();exit $elevated.ExitCode
        }catch{
            $native=$_.Exception.NativeErrorCode;if(!$native -and $_.Exception.InnerException){$native=$_.Exception.InnerException.NativeErrorCode}
            $code=if($native -eq 1223){1223}else{1};Show-MutPreparationNotice ('管理員授權未完成，尚未準備元件。原始訊息：'+$_.Exception.Message) -Kind Warning;exit $code
        }
    }
    $mutex=New-Object Threading.Mutex($false,'Global\MUT-SEW25091-OneClick')
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(!$locked){throw '已有另一個安裝助手正在執行，請回到原視窗。'}
    $candidate=Join-Path $script:TaskRoot ('prerequisite-logs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    foreach($path in @($candidate,(Join-Path $script:TaskRoot 'repair-logs'),(Join-Path $script:TaskRoot 'sql-acl-repair-logs'),(Join-Path $script:TaskRoot 'prerequisite-state.json'))){Assert-MutPreparationWorkPath $path}
    $null=New-Item -ItemType Directory -Path $candidate -Force;$script:RunRoot=$candidate
    Assert-MutPreparationHelpers
    Import-Module (Join-Path $PSScriptRoot 'Mut-OneClick.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Mut-Prerequisites.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Mut-PrerequisiteSql.psm1') -Force
    $operations=@{
        Busy={return (@(Get-MutPreparationBusy).Count -gt 0)};PendingRestart={return Test-MutPreparationPending};PrepareSource={Prepare-MutMicrosoftSource};Verify={Get-MutPreparationEvidence};Repair={Invoke-MutPreparationRepair};VerifyFresh={param($Repair) Get-MutPreparationFreshEvidence $Repair}
        SqlPlan={$script:Stage='SQL 相依狀態檢查';$facts=Get-MutPrerequisiteSqlFacts -Release $Release;Write-MutPreparationJson $facts (Join-Path $script:RunRoot 'sql-facts.json');Get-MutPrerequisiteSqlPlan -Facts $facts}
        RepairSql={param($Instance) Invoke-MutPreparationSqlRepair $Instance}
    }
    $script:Report=Invoke-MutPreparationWorkflow -Mode $Mode -Operations $operations;$code=$script:Report.ExitCode
    Write-MutPreparationJson $script:Report (Join-Path $script:RunRoot 'report.json')
    if($Mode -eq 'Prepare'){$phase=switch($code){0{'Ready'}3010{'AwaitingReboot'}default{'ReviewRequired'}};Write-MutPreparationJson ([ordered]@{SchemaVersion=1;Machine=$env:COMPUTERNAME;Phase=$phase;BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');UpdatedUtc=[datetime]::UtcNow.ToString('o');LogDirectory=$script:RunRoot}) (Join-Path $script:TaskRoot 'prerequisite-state.json')}
    if($code -eq 3010){Show-MutPreparationNotice '前置元件需要重新啟動。請儲存工作後重新啟動 Windows，再雙擊 Install-Prerequisites.cmd。'}
    elseif($code -eq 2){
        $details=@($script:Report.Prerequisites.Findings)
        foreach($item in @($script:Report.SqlPlan.Items | Where-Object {$_.Action -eq 'Review'})){$details+=($item.Instance+'：SQL 來源、服務或失敗紀錄未符合限定修復條件（'+$item.Reason+'），需要人工檢查。')}
        Show-MutPreparationNotice ('元件或 SQL 狀態仍需人工確認，請先處理下列項目：'+"`r`n"+($details -join "`r`n")+"`r`n詳細紀錄："+$script:RunRoot) -Kind Warning
    }
    elseif($Mode -eq 'Check'){Show-MutPreparationNotice ('前置元件唯讀檢查通過。詳細紀錄：'+$script:RunRoot)}
    else{Show-MutPreparationNotice ('前置元件準備完成。請自行完整解壓原廠 '+$Release+'.zip，以管理員身分執行 MUT3_Install.bat。此結果表示前置元件已核驗，不代表 M.U.T. 主程式安裝完成。'+$(if(@($script:Report.RepairedInstances).Count){"`r`nSQL 權限已修復；請重新啟動 Windows，再依原廠程序重新嘗試安裝。"}else{''})+"`r`n詳細紀錄："+$script:RunRoot)}
}catch{
    $code=1;$rawError=[ordered]@{Message=$_.Exception.Message;HResult=('0x{0:X8}' -f $_.Exception.HResult)}
    if($script:RunRoot){$_ | Out-String | Set-Content -LiteralPath (Join-Path $script:RunRoot 'failure.txt') -Encoding UTF8}
    Show-MutPreparationNotice ("階段："+$script:Stage+"`r`n前置元件尚未通過。原始錯誤："+$rawError.Message+"`r`n退出碼：1；例外代碼："+$rawError.HResult+"`r`n建議操作：先處理上述原因，保留日誌；請勿同時執行原廠安裝器與此腳本。"+"`r`n日誌："+$script:RunRoot) -Kind Error
}finally{
    if($script:RunRoot){Write-MutPreparationJson ([ordered]@{SchemaVersion=1;Mode=$Mode;Release=$Release;ExitCode=$code;FinishedUtc=[datetime]::UtcNow.ToString('o');Stage=$script:Stage;LogDirectory=$script:RunRoot;Error=$rawError;Scope='Prerequisites only; vendor installation and removal are manual.'}) (Join-Path $script:RunRoot 'result.json')}
    if($locked -and $mutex){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
exit $code
