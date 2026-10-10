[CmdletBinding()]
param([switch]$InspectOnly)
$ErrorActionPreference='Stop'
$taskRoot='C:\MUT-Install'
$mediaRoot=Join-Path $taskRoot 'SEW25091'
$sqlLogRoot='C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log'
$runRoot=Join-Path $taskRoot ('sql-instance-removal-logs\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$statusPath=Join-Path $taskRoot 'sql-instance-removal-status.json'
$exitCode=1
$targets=[ordered]@{MUT3=[ordered]@{state='pending'};CAESARCOMPDB=[ordered]@{state='pending'}}
$mediaFolders=@{MUT3='MUT3DIAG_V';CAESARCOMPDB='NEWDBIN_V'}
$package='en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935'
$setupHash='A9697B2403FCEF33B3B780343561B4FFE7569464AB709924ED00163CD910A671'

function Write-Status([string]$stage,[string]$message) {
    [ordered]@{stage=$stage;message=$message;time=(Get-Date).ToString('o');exitCode=$exitCode;logs=$runRoot;targets=$targets} |
        ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Read-SqlField([string]$text,[string]$name) {
    $match=[regex]::Match($text,'(?im)^[ \t]*'+[regex]::Escape($name)+'[ \t]*[=:][ \t]*"?([^"\r\n]+)')
    if($match.Success){return $match.Groups[1].Value.Trim()}
    return $null
}
function Test-PendingRestart {
    foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if(Test-Path -LiteralPath $path){return $true}
    }
    $session=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    return @($session.PendingFileRenameOperations | Where-Object {![string]::IsNullOrEmpty($_)}).Count -gt 0
}
function Assert-InstallersIdle {
    $busy=@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(MUT3INSTALL|MUT3UNINSTALL|MT3NNSTLL|Mut3Check|MUT3_SE|MUT3_Launcher)\.exe$' -or
        ($_.Name -match '^(setup|setup100|scenarioengine|en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935)\.exe$' -and (!$_.ExecutablePath -or $_.ExecutablePath -match '(?i)\\SEW25091\\|\\Microsoft SQL Server\\|en_sql_server_2014')) -or
        ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -match '(?i)\\(UNINST|DEL_SE)\.bat\b')
    })
    if($busy.Count){throw 'A MUT or SQL installer is still active. No process was stopped.'}
}
function Get-TargetRegistry([string]$instance) {
    $result=@()
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try {
            $mapping=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL')
            try {$mapped=if($mapping){$mapping.GetValue($instance)}else{$null}}finally{if($mapping){$mapping.Dispose()}}
            $path='SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.'+$instance+'\Setup'
            $key=$base.OpenSubKey($path)
            try {
                $values=[ordered]@{}
                if($key){foreach($name in @('SQLPath','SQLBinRoot','SQLDataRoot','Version','PatchLevel','Edition','FeatureList')){$values[$name]=$key.GetValue($name)}}
                $sddl=if($key){$key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)}else{$null}
                $result += [pscustomobject]@{view=$view.ToString();instance=$instance;mapping=$mapped;setupKey=$path;exists=[bool]$key;values=$values;accessSddl=$sddl}
            }finally{if($key){$key.Dispose()}}
        }finally{$base.Dispose()}
    }
    return $result
}
function Get-SqlInventory {
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        $uninstall=$base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        try {
            foreach($name in $uninstall.GetSubKeyNames()) {
                $key=$uninstall.OpenSubKey($name)
                try {
                    $display=$key.GetValue('DisplayName')
                    if($display -match '(?i)SQL Server|SQL Native Client|ODBC Driver.*SQL') {
                        [pscustomobject]@{view=$view.ToString();key=$name;name=$display;version=$key.GetValue('DisplayVersion');publisher=$key.GetValue('Publisher')}
                    }
                }finally{if($key){$key.Dispose()}}
            }
        }finally{if($uninstall){$uninstall.Dispose()};$base.Dispose()}
    }
}
function Get-LogRecord($folder) {
    $configPath=Join-Path $folder.FullName 'ConfigurationFile.ini'
    $config=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw}else{''}
    $summary=(@(Get-ChildItem -LiteralPath $folder.FullName -Filter 'Summary*.txt' -File | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw})) -join "`n"
    [pscustomobject]@{folder=$folder.FullName;name=$folder.Name;createdUtc=$folder.CreationTimeUtc;metadata=($config+"`n"+$summary);summary=$summary}
}
function Get-LatestTargetLog([string]$instance) {
    foreach($folder in @(Get-ChildItem -LiteralPath $sqlLogRoot -Directory | Where-Object {$_.Name -match '^\d{8}_\d{6}$'} | Sort-Object Name -Descending)) {
        $record=Get-LogRecord $folder
        if((Read-SqlField $record.metadata 'INSTANCENAME') -ieq $instance){return $record}
    }
    return $null
}
function Assert-ReviewedFailure($record,[string]$instance) {
    if(!$record -or (Read-SqlField $record.metadata 'ACTION') -ine 'Install' -or (Read-SqlField $record.metadata 'FEATURES') -ine 'SQLENGINE' -or ((Read-SqlField $record.metadata 'SQLSVCACCOUNT') -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE') {throw ($instance+' latest SQL setup is not the reviewed failed installation.')}
    if($record.summary -notmatch '(?im)^[ \t]*Final result:[ \t]*Failed\b' -or $record.summary -notmatch '(?i)uninstall this feature') {throw ($instance+' latest SQL summary does not require removal of a failed feature.')}
    $detail=Get-Content -LiteralPath (Join-Path $record.folder 'Detail.txt') -Raw
    $allowed=@((Join-Path $mediaRoot ('INSTALL\'+$mediaFolders[$instance]+'\'+$package+'\x86\setup\')))
    if($instance -eq 'CAESARCOMPDB'){$allowed += Join-Path $mediaRoot ('INSTALL\NEWDBIN0_V\'+$package+'\x86\setup\')}
    if(!@($allowed | Where-Object {$detail.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0}).Count -or $detail -notmatch '(?i)Feature\s*=\s*SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32\b') {throw ($instance+' failed installation source or architecture differs from the reviewed media.')}
    $engineErrors=(@(Get-ChildItem -LiteralPath $record.folder -Filter 'SQLServer_ERRORLOG_*.txt' -File | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw})) -join "`n"
    if($engineErrors -notmatch '(?i)Microsoft SQL Server 2014[^\r\n]*\(Intel X86\)' -or $engineErrors -notmatch '(?i)TDSSNIClient initialization failed with error 0x5, status code 0x90\. Reason: Unable to configure MDAC-compatibility protocol list in registry\. Access is denied\.') {throw ($instance+' last failure is not the reviewed MDAC registry error.')}
}
function Assert-TargetService($service,[string]$instance,$registry) {
    $expectedRoot='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$instance+'\MSSQL'
    $expectedCommand='"'+$expectedRoot+'\Binn\sqlservr.exe" -s'+$instance
    if($service.State -ne 'Stopped' -or ($service.StartName -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or $service.PathName -ine $expectedCommand) {throw ($instance+' service state, account, or executable differs from the reviewed failed instance.')}
    $native=@($registry | Where-Object {$_.view -eq 'Registry64'})
    $wow=@($registry | Where-Object {$_.view -eq 'Registry32'})
    if($wow.Count -ne 1 -or $native.Count -ne 1){throw ($instance+' registry inspection did not cover exactly both views.')}
    $reg32=$wow[0]
    if($reg32.mapping -ine ('MSSQL12.'+$instance) -or !$reg32.exists -or $reg32.values.SQLPath -ine $expectedRoot -or $reg32.values.SQLBinRoot -ine ($expectedRoot+'\Binn') -or $reg32.values.SQLDataRoot -ine $expectedRoot) {throw ($instance+' registry identity or installation paths differ from the reviewed failed instance.')}
    if(@($registry | Where-Object {$_.mapping -and $_.mapping -ine ('MSSQL12.'+$instance)}).Count){throw ($instance+' has an unexpected registry mapping.')}
    # Setup's servicing version differs from the running engine ProductVersion.
    # Both failed-run evidence and the reviewed media use these exact values.
    if($reg32.values.Version -cne '12.1.4100.1' -or $reg32.values.PatchLevel -cne '12.1.4100.1' -or $reg32.values.Edition -cne 'Express Edition') {
        throw ($instance+' installed SQL version, patch level, or edition differs from the reviewed failure; an old setup log cannot authorize removal.')
    }
    if($native[0].exists -or $native[0].mapping){throw ($instance+' has a native SQL Setup identity that was absent from the reviewed x86 failure.')}
    Assert-ReviewedSqlBinary ($expectedRoot+'\Binn\sqlservr.exe') $instance
    Assert-NoUsableDatabaseEvidence $expectedRoot $instance
}
function Assert-ReviewedSqlBinary([string]$path,[string]$instance) {
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    $version=$file.VersionInfo
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $version.ProductVersion -cne '12.0.4100.1' -or $version.CompanyName -cne 'Microsoft Corporation' -or
        $version.FileMajorPart -ne 2014 -or $version.FileMinorPart -ne 120 -or $version.FileBuildPart -ne 4100 -or $version.FilePrivatePart -ne 1) {
        throw ($instance+' installed sqlservr.exe is not the reviewed SQL Server 2014 SP1 binary version.')
    }
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $reader=New-Object IO.BinaryReader($stream)
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D){throw ($instance+' sqlservr.exe has no valid DOS executable header.')}
        $stream.Position=0x3C
        $offset=$reader.ReadInt32()
        if($offset -lt 64 -or $offset -gt ($stream.Length-6)){throw ($instance+' sqlservr.exe has an invalid PE offset.')}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x014C){throw ($instance+' installed sqlservr.exe is not an x86 PE executable.')}
    } finally {$stream.Dispose()}
}
function Assert-ReviewedEngineLogText([string]$text,[string]$instance) {
    if($text -notmatch '(?im)Microsoft SQL Server 2014\s*-\s*12\.0\.4100\.1\s*\(Intel X86\)' -or
        $text -notmatch '(?i)TDSSNIClient initialization failed with error 0x5, status code 0x90\. Reason: Unable to configure MDAC-compatibility protocol list in registry\. Access is denied\.') {
        throw ($instance+' current engine ERRORLOG does not identify the reviewed SQL version and MDAC failure.')
    }
    if($text -match '(?i)SQL Server is now ready for client connections') {
        throw ($instance+' current engine ERRORLOG records a working server. Preserve it and its databases for manual review.')
    }
    foreach($match in [regex]::Matches($text,"(?im)Starting up database '([^']+)'")) {
        if($match.Groups[1].Value -notin @('master','model','msdb','tempdb','mssqlsystemresource')) {
            throw ($instance+' engine ERRORLOG records a user database. No automatic cleanup is allowed.')
        }
    }
}
function Assert-NoUsableDatabaseEvidence([string]$instanceRoot,[string]$instance) {
    # A stopped service and an old failed Setup summary do not prove that data is disposable.
    # Inspect the current engine log and local SQL data files before vendor uninstall or SQL cleanup.
    $logPath=Join-Path $instanceRoot 'Log\ERRORLOG'
    if(!(Test-Path -LiteralPath $logPath -PathType Leaf)){throw ($instance+' current engine ERRORLOG is missing; database safety cannot be established.')}
    Assert-ReviewedEngineLogText (Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop) $instance
    $dataPath=Join-Path $instanceRoot 'DATA'
    if(!(Test-Path -LiteralPath $dataPath -PathType Container)){throw ($instance+' canonical DATA directory is missing; manual review is required.')}
    $systemFiles=@('master.mdf','mastlog.ldf','model.mdf','modellog.ldf','MSDBData.mdf','MSDBLog.ldf','tempdb.mdf','templog.ldf')
    foreach($entry in @(Get-ChildItem -LiteralPath $dataPath -Force -ErrorAction Stop)) {
        if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $entry.PSIsContainer) {
            throw ($instance+' DATA contains an unexpected directory or link; manual review is required.')
        }
        if($entry.Extension -in @('.mdf','.ndf','.ldf') -and $entry.Name -notin $systemFiles) {
            throw ($instance+' DATA contains a non-default database file. Back up and review the instance; no automatic cleanup is allowed.')
        }
    }
}
function Test-UninstallPassed($record,[string]$instance,[datetime]$startedUtc,[string[]]$oldFolders) {
    return ($record -and $record.createdUtc -ge $startedUtc -and $record.folder -notin $oldFolders -and
        (Read-SqlField $record.metadata 'ACTION') -ieq 'Uninstall' -and (Read-SqlField $record.metadata 'INSTANCENAME') -ieq $instance -and
        (Read-SqlField $record.metadata 'FEATURES') -ieq 'SQLENGINE' -and $record.summary -match '(?im)^[ \t]*Final result:[ \t]*Passed\b')
}

try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or ![Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Elevated 64-bit Windows PowerShell 5.1 is required.'}
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    if(Test-PendingRestart){$exitCode=3010;throw 'A Windows restart is pending. Restart manually before removal; no pending operations were changed.'}
    Assert-InstallersIdle
    if(!$InspectOnly) {
        if(Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00'){throw 'Complete the original MUT uninstallation first.'}
        foreach($path in @('C:\MUTSW','C:\MUTSW_SE')){if(Test-Path -LiteralPath $path){throw ('Original MUT data remains at '+$path+'. Complete the original uninstallation first.')}}
    }
    $plan=@()
    foreach($instance in $targets.Keys) {
        $service=Get-CimInstance Win32_Service -Filter ("Name='MSSQL`$"+$instance+"'")
        $registry=@(Get-TargetRegistry $instance)
        if(!$service) {
            if(@($registry | Where-Object {$_.mapping -or $_.exists}).Count){throw ($instance+' has registry remnants without its service; manual review is required.')}
            $targets[$instance].state='already-absent';continue
        }
        Assert-TargetService $service $instance $registry
        $failed=Get-LatestTargetLog $instance
        Assert-ReviewedFailure $failed $instance
        $setup=Join-Path $mediaRoot ('INSTALL\'+$mediaFolders[$instance]+'\'+$package+'\SETUP.EXE')
        if((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -ne $setupHash -or (Get-Item -LiteralPath $setup).VersionInfo.ProductVersion -ne '12.0.4100.1'){throw 'The SQL setup executable differs from the reviewed original media.'}
        $arguments='/Q /ACTION=Uninstall /FEATURES=SQLENGINE /INSTANCENAME='+$instance
        $plan += [pscustomobject]@{instance=$instance;setup=$setup;arguments=$arguments;failedSetupLog=$failed.folder;service=[ordered]@{name=$service.Name;state=$service.State;account=$service.StartName;path=$service.PathName};registry=$registry}
        $targets[$instance].state='verified-failed-instance'
    }
    # Allowlisted metadata only: no Setup PID/product keys, configuration secrets, or database contents.
    [ordered]@{created=(Get-Date).ToString('o');scope='Only SQLENGINE for the two reviewed failed instances. This inventory is not a restorable engine/database backup.';plan=$plan;sqlProductInventory=@(Get-SqlInventory)} | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $runRoot 'before-safe-inventory.json') -Encoding UTF8
    if($InspectOnly) {
        $exitCode=0
        Write-Status 'inspection-passed-no-changes' 'Read-only failure inspection passed. No uninstall, service or registry change was performed.'
        exit 0
    }
    foreach($item in $plan) {
        $instance=$item.instance
        Assert-InstallersIdle
        if(Test-PendingRestart){$exitCode=3010;throw 'A restart is now pending. Restart manually before continuing; the next instance was not touched.'}
        $service=Get-CimInstance Win32_Service -Filter ("Name='MSSQL`$"+$instance+"'")
        if(!$service){throw ($instance+' service changed after preflight.')}
        Assert-TargetService $service $instance @(Get-TargetRegistry $instance)
        $oldFolders=@(Get-ChildItem -LiteralPath $sqlLogRoot -Directory | ForEach-Object {$_.FullName})
        $startedUtc=[datetime]::UtcNow
        $deadline=$startedUtc.AddMinutes(15)
        $targets[$instance].state='removing-with-original-sql-setup'
        Write-Status 'removing-failed-instance' ('Running the original SQL Setup for '+$instance+'; only SQLENGINE was requested.')
        $process=Start-Process -FilePath $item.setup -ArgumentList $item.arguments -WorkingDirectory (Split-Path -Parent $item.setup) -WindowStyle Hidden -PassThru
        $null=$process.Handle
        [ordered]@{instance=$instance;source=$item.setup;arguments=$item.arguments;startedUtc=$startedUtc.ToString('o');deadlineUtc=$deadline.ToString('o');pid=$process.Id} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot ($instance+'-launch.json')) -Encoding UTF8
        while(!$process.HasExited -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Seconds 2;$process.Refresh()}
        if(!$process.HasExited){$targets[$instance].state='timed-out-process-left-running';throw ($instance+' setup exceeded 15 minutes. No process was terminated; inspect SQL Setup before taking another action.')}
        $process.WaitForExit();$process.Refresh()
        $result=$process.ExitCode
        $targets[$instance].setupExitCode=$result
        $latest=Get-LatestTargetLog $instance
        $targets[$instance].resultLog=if($latest){$latest.folder}else{$null}
        $remaining=Get-CimInstance Win32_Service -Filter ("Name='MSSQL`$"+$instance+"'")
        $targets[$instance].serviceAbsent=(!$remaining)
        $targets[$instance].summaryPassed=(Test-UninstallPassed $latest $instance $startedUtc $oldFolders)
        if($result -eq 3010 -or (Test-PendingRestart)){$exitCode=3010;$targets[$instance].state='restart-required';throw ($instance+' removal requires a manual restart. No next instance or installation was started.')}
        if($result -ne 0 -or !$targets[$instance].summaryPassed -or $remaining){throw ($instance+' removal did not verify successfully. Review its SQL Summary; no further instance was touched.')}
        $afterRegistry=@(Get-TargetRegistry $instance)
        $afterRegistry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot ($instance+'-after-registry-inventory.json')) -Encoding UTF8
        if(@($afterRegistry | Where-Object {$_.mapping}).Count){throw ($instance+' still has an instance-name registry mapping after Setup. No mapping was deleted; review is required.')}
        $targets[$instance].state='removed-and-verified'
    }
    @(Get-SqlInventory) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runRoot 'after-sql-product-inventory.json') -Encoding UTF8
    $exitCode=0
    Write-Status 'failed-instances-absent' 'Both reviewed SQL instances are absent. No shared feature removal was requested; SQL Setup may manage SQL Browser when the final instance is removed.'
} catch {
    if($exitCode -ne 3010){$exitCode=1}
    try{Write-Status $(if($exitCode -eq 3010){'restart-required'}else{'stopped-review-required'}) $_.Exception.Message}catch{Write-Output 'Could not write removal status.'}
    Write-Output ('STOPPED: '+$_.Exception.Message)
} finally {
    if(Test-Path -LiteralPath $runRoot){$exitCode | Set-Content -LiteralPath (Join-Path $runRoot 'exit-code.txt') -Encoding ASCII}
}
exit $exitCode
