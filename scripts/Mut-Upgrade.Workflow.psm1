# Stateful upgrade orchestration. All system effects are injected by the entry
# script; importing this module does not inspect or change the computer.
Set-StrictMode -Version 2

function ConvertTo-MutWorkflowUtc([string]$Value) {
    $parsed=[datetime]::MinValue
    if(!$Value.EndsWith('Z') -or ![datetime]::TryParse($Value,[ref]$parsed)){throw 'Invalid UTC time in upgrade checkpoint.'}
    return $parsed.ToUniversalTime()
}
function Assert-MutUpgradeCheckpoint {
    param($State,[string]$SourceHash,[string]$TargetHash,[string]$Machine)
    foreach($field in @('SchemaVersion','Machine','SourceMediaHash','TargetMediaHash','Phase','BootUtc','StartedUtc','UpdatedUtc','BackupManifest','BackupManifestSha256','BackupChild','BackupStartedUtc','UninstallStartedUtc','OriginalStateArchive','OriginalStateSha256','HadOriginalState','PreUninstallRebootBootUtc','LastError')){
        if($State.PSObject.Properties.Name -notcontains $field){throw ('Upgrade checkpoint lacks '+$field+'.')}
    }
    if($State.SchemaVersion -ne 1 -or $State.Machine -cne $Machine -or $State.SourceMediaHash -cne $SourceHash -or $State.TargetMediaHash -cne $TargetHash){throw 'Upgrade checkpoint belongs to another machine or release.'}
    if($State.Phase -notin @('Checking','BackingUp','BackupReady','Uninstalling','AwaitingReboot','ReadyForInstall','ReviewRequired')){throw 'Unknown upgrade checkpoint phase.'}
    foreach($field in @('BootUtc','StartedUtc','UpdatedUtc')){$null=ConvertTo-MutWorkflowUtc $State.$field}
    foreach($field in @('BackupStartedUtc','UninstallStartedUtc','PreUninstallRebootBootUtc')){if($State.$field){$null=ConvertTo-MutWorkflowUtc $State.$field}}
    if($State.HadOriginalState -isnot [bool]){throw 'Invalid original-state presence flag.'}
    if($State.HadOriginalState -and (!$State.OriginalStateArchive -or $State.OriginalStateSha256 -cnotmatch '^[A-F0-9]{64}$')){throw 'Original state archive is not pinned.'}
    if(!$State.HadOriginalState -and ($State.OriginalStateArchive -or $State.OriginalStateSha256)){throw 'Unexpected original state archive.'}
    if($State.Phase -in @('BackupReady','Uninstalling','AwaitingReboot','ReadyForInstall') -and (!$State.BackupManifest -or $State.BackupManifestSha256 -cnotmatch '^[A-F0-9]{64}$')){throw 'Completed backup manifest is not pinned.'}
    if($State.Phase -in @('Uninstalling','AwaitingReboot','ReadyForInstall') -and !$State.UninstallStartedUtc){throw 'Upgrade uninstall start is missing.'}
    if($State.Phase -eq 'BackingUp' -and !$State.BackupStartedUtc){throw 'Backup start is missing.'}
}
function Save-MutUpgradeWorkflow {
    param($State,[hashtable]$Operations,[string]$Phase)
    $State.Phase=$Phase
    $State.UpdatedUtc=(& $Operations.Now).ToString('o')
    & $Operations.Save $State | Out-Null
}
function Assert-MutPinnedUpgradeBackup {
    param($State,[hashtable]$Operations,[bool]$VerifySource=$false)
    $hash=& $Operations.Hash $State.BackupManifest
    if($hash -cne $State.BackupManifestSha256){throw '備份 manifest 雜湊已變更；沒有繼續卸載或安裝。請保留現場與備份。'}
    $manifest=& $Operations.AssertBackup $State.BackupManifest $VerifySource
    if((& $Operations.Hash $State.BackupManifest) -cne $State.BackupManifestSha256){throw '核驗期間備份 manifest 已改變，請保留現場。'}
    return $manifest
}
function Invoke-MutHealthyUpgrade {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StatePath,$ExistingState,
          [Parameter(Mandatory=$true)][string]$SourceHash,[Parameter(Mandatory=$true)][string]$TargetHash,
          [string]$Machine=$env:COMPUTERNAME,[Parameter(Mandatory=$true)][hashtable]$Operations)
    foreach($name in @('Read','Save','Now','Boot','Pending','Idle','ValidateOldState','VerifyOld','PrepareTarget','PrepareOld','Confirm','ArchiveState','AssertStateArchive','StartBackup','BackupStatus','ReadBackupSummary','Hash','AssertBackup','StartUninstall','Uninstalled','AssertSql','Sleep','Notice')){
        if(!$Operations.ContainsKey($name) -or $Operations[$name] -isnot [scriptblock]){throw ('Missing upgrade operation: '+$name)}
    }
    $state=$null
    $trustedState=$false
    try{
        $state=& $Operations.Read $StatePath
        if($state){
            Assert-MutUpgradeCheckpoint $state $SourceHash $TargetHash $Machine
            $trustedState=$state.Phase -ne 'ReviewRequired'
            if($state.Phase -eq 'ReviewRequired'){throw ('升級流程先前已停止，請先排查而不要重放卸載。原始訊息：'+$state.LastError)}
            & $Operations.AssertStateArchive $state | Out-Null
        }else{
            if($ExistingState){& $Operations.ValidateOldState $ExistingState | Out-Null}
            if(!(& $Operations.Idle)){throw '有其他安裝或備份程序正在執行，沒有開始升級。'}
            & $Operations.VerifyOld | Out-Null
            & $Operations.PrepareTarget | Out-Null
            & $Operations.PrepareOld | Out-Null
            if(!(& $Operations.Confirm)){return [pscustomobject]@{ExitCode=1223;ReadyForInstall=$false;BackupManifest='';BackupManifestSha256=''}}
            $archive=& $Operations.ArchiveState $ExistingState
            $now=(& $Operations.Now).ToString('o')
            $state=[pscustomobject]@{SchemaVersion=1;Machine=$Machine;SourceMediaHash=$SourceHash;TargetMediaHash=$TargetHash;Phase='Checking';BootUtc=(& $Operations.Boot);StartedUtc=$now;UpdatedUtc=$now;BackupManifest='';BackupManifestSha256='';BackupChild=$null;BackupStartedUtc='';UninstallStartedUtc='';OriginalStateArchive=$archive.Path;OriginalStateSha256=$archive.Hash;HadOriginalState=[bool]$ExistingState;PreUninstallRebootBootUtc='';LastError=''}
            $trustedState=$true
            Save-MutUpgradeWorkflow $state $Operations 'Checking'
        }
        if($state.Phase -eq 'Checking'){
            if(!(& $Operations.Idle)){throw '有其他安裝或備份程序正在執行，沒有重啟備份。'}
            & $Operations.VerifyOld | Out-Null
            & $Operations.PrepareTarget | Out-Null
            & $Operations.PrepareOld | Out-Null
            $state.BackupStartedUtc=(& $Operations.Now).ToString('o')
            # Persist before spawn: an interruption in this gap requires review,
            # never a blind second backup or uninstall.
            Save-MutUpgradeWorkflow $state $Operations 'BackingUp'
            $state.BackupChild=& $Operations.StartBackup
            Save-MutUpgradeWorkflow $state $Operations 'BackingUp'
        }
        if($state.Phase -eq 'BackingUp'){
            if(!$state.BackupChild){throw '備份啟動身分未保存，無法確認是否仍在執行；沒有再啟動第二份。'}
            $deadline=(ConvertTo-MutWorkflowUtc $state.BackupStartedUtc).AddMinutes(45)
            while($true){
                $status=& $Operations.BackupStatus $state.BackupChild
                if($status -eq 'Ended'){break}
                if($status -ne 'Alive'){throw '備份程序身分不明，沒有重啟或終止程序。'}
                if((& $Operations.Now) -ge $deadline){throw '備份超過 45 分鐘，程序仍保留，請檢查備份日誌。'}
                & $Operations.Sleep 2 | Out-Null
            }
            $summary=& $Operations.ReadBackupSummary $state.BackupChild
            if(!$summary -or $summary.Status -cne 'Complete' -or !$summary.Manifest){throw '備份未產生完整成功報告；沒有解除安裝。'}
            $hashBefore=& $Operations.Hash ([string]$summary.Manifest)
            $null=& $Operations.AssertBackup ([string]$summary.Manifest) $true
            $hashAfter=& $Operations.Hash ([string]$summary.Manifest)
            if($hashBefore -cne $hashAfter){throw '核驗期間備份 manifest 改變，沒有解除安裝。'}
            $state.BackupManifest=[string]$summary.Manifest
            $state.BackupManifestSha256=[string]$hashAfter
            Save-MutUpgradeWorkflow $state $Operations 'BackupReady'
        }
        if($state.Phase -eq 'BackupReady'){
            $null=Assert-MutPinnedUpgradeBackup $state $Operations $true
            & $Operations.AssertStateArchive $state | Out-Null
            $boot=ConvertTo-MutWorkflowUtc (& $Operations.Boot)
            $pending=& $Operations.Pending
            if($pending -or ($state.PreUninstallRebootBootUtc -and $boot -le (ConvertTo-MutWorkflowUtc $state.PreUninstallRebootBootUtc))){
                if($pending){$state.PreUninstallRebootBootUtc=(& $Operations.Boot)}
                Save-MutUpgradeWorkflow $state $Operations 'BackupReady'
                & $Operations.Notice '備份已完成，但 Windows 尚有待重啟操作。請儲存工作並重新啟動，再執行同一入口；尚未解除安裝。' | Out-Null
                return [pscustomobject]@{ExitCode=3010;ReadyForInstall=$false;BackupManifest=$state.BackupManifest;BackupManifestSha256=$state.BackupManifestSha256}
            }
            if(!(& $Operations.Idle)){throw '有其他安裝或備份程序正在執行，沒有開始卸載。'}
            & $Operations.PrepareOld | Out-Null
            $state.BootUtc=(& $Operations.Boot)
            $state.UninstallStartedUtc=(& $Operations.Now).ToString('o')
            Save-MutUpgradeWorkflow $state $Operations 'Uninstalling'
            & $Operations.StartUninstall | Out-Null
        }
        if($state.Phase -eq 'Uninstalling'){
            # A saved Uninstalling phase only observes; it never launches UNINST
            # again. Allow reconciliation after an already completed reboot.
            $deadline=(ConvertTo-MutWorkflowUtc $state.UninstallStartedUtc).AddMinutes(45)
            if((& $Operations.Now) -ge $deadline){
                if((ConvertTo-MutWorkflowUtc (& $Operations.Boot)) -le (ConvertTo-MutWorkflowUtc $state.UninstallStartedUtc) -or !(& $Operations.Idle) -or !(& $Operations.Uninstalled)){throw '原廠卸載已超過 45 分鐘且無完成證據；沒有再啟動或終止程序。'}
                $deadline=(& $Operations.Now).AddSeconds(30)
            }
            $idleSince=$null
            while((& $Operations.Now) -lt $deadline){
                if(& $Operations.Idle){
                    if(!$idleSince){$idleSince=& $Operations.Now}
                    if(((& $Operations.Now)-$idleSince).TotalSeconds -ge 10){
                        if(!(& $Operations.Uninstalled)){throw '原廠卸載取消或仍有應用程式殘留；沒有刪除資料或清理健康 SQL。'}
                        Save-MutUpgradeWorkflow $state $Operations 'AwaitingReboot'
                        break
                    }
                }else{$idleSince=$null}
                & $Operations.Sleep 2 | Out-Null
            }
            if($state.Phase -eq 'Uninstalling'){throw '原廠卸載監控超過 45 分鐘，程序仍保留；請檢查原廠畫面。'}
        }
        if($state.Phase -in @('AwaitingReboot','ReadyForInstall')){
            $null=Assert-MutPinnedUpgradeBackup $state $Operations $false
            $boot=ConvertTo-MutWorkflowUtc (& $Operations.Boot)
            $pending=& $Operations.Pending
            if($boot -le (ConvertTo-MutWorkflowUtc $state.BootUtc) -or $boot -le (ConvertTo-MutWorkflowUtc $state.UninstallStartedUtc) -or $pending){
                if($pending){$state.BootUtc=(& $Operations.Boot);Save-MutUpgradeWorkflow $state $Operations 'AwaitingReboot'}
                & $Operations.Notice '原廠解除安裝已完成。請儲存工作並重新啟動 Windows，再執行同一入口；會保留已備份且身分核對的兩個 SQL 引擎。' | Out-Null
                return [pscustomobject]@{ExitCode=3010;ReadyForInstall=$false;BackupManifest=$state.BackupManifest;BackupManifestSha256=$state.BackupManifestSha256}
            }
            if(!(& $Operations.Idle) -or !(& $Operations.Uninstalled)){throw '重啟後仍有安裝程序或應用程式殘留，沒有開始新版安裝。'}
            & $Operations.AssertStateArchive $state | Out-Null
            $manifest=Assert-MutPinnedUpgradeBackup $state $Operations $false
            & $Operations.AssertSql $manifest | Out-Null
            Save-MutUpgradeWorkflow $state $Operations 'ReadyForInstall'
            return [pscustomobject]@{ExitCode=0;ReadyForInstall=$true;BackupManifest=$state.BackupManifest;BackupManifestSha256=$state.BackupManifestSha256}
        }
        throw '升級流程沒有可安全接續的階段。'
    }catch{
        $message=$_.Exception.Message
        if($trustedState){
            try{$state.LastError=$message;Save-MutUpgradeWorkflow $state $Operations 'ReviewRequired'}catch{ }
        }
        $errorObject=New-Object System.Exception($message)
        $errorObject.Data['MutExitCode']=2
        throw $errorObject
    }
}
Export-ModuleMember -Function Invoke-MutHealthyUpgrade
