[CmdletBinding()]
param(
    [ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW25091',
    [string]$UpgradeManifest,
    [string]$UpgradeManifestHash
)
$ErrorActionPreference='Stop'
$taskRoot='C:\MUT-Install'
$mediaRoot=Join-Path $taskRoot $Release
$entryPath=Join-Path $mediaRoot 'MUT3_Install.bat'
$repairPath=Join-Path $PSScriptRoot 'Repair-MutSqlLegacyAcl.ps1'
$sqlLogRoot='C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log'
$runRoot=Join-Path $taskRoot ('sql-acl-coordinator-logs\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$statusPath=Join-Path $taskRoot 'sql-acl-coordinator-status.json'
$exitCode=1
$preservedSql=$false
$targets=@{
    MUT3=[pscustomobject]@{log=$null; attempted=$false; patched=$false; patchedUtc=$null; completed=$false}
    CAESARCOMPDB=[pscustomobject]@{log=$null; attempted=$false; patched=$false; patchedUtc=$null; completed=$false}
}
$approvedMedia=@{
    MUT3=@((Join-Path $mediaRoot 'INSTALL\MUT3DIAG_V\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935\x86\setup\'))
    CAESARCOMPDB=@((Join-Path $mediaRoot 'INSTALL\NEWDBIN_V\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935\x86\setup\'),(Join-Path $mediaRoot 'INSTALL\NEWDBIN0_V\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935\x86\setup\'))
}
function Write-Status([string]$stage,[string]$message) {
    [ordered]@{stage=$stage; message=$message; time=(Get-Date).ToString('o'); logs=$runRoot; exitCode=$exitCode; targets=$targets} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Read-Setting([string]$text,[string]$name) {
    $match=[regex]::Match($text,'(?im)^\s*'+[regex]::Escape($name)+'\s*=\s*"?([^"\r\n]+)"?\s*$')
    if($match.Success){return $match.Groups[1].Value.Trim()}
    return $null
}
function Test-NewLogFolder($folder,[datetime]$launchUtc,[string[]]$oldFolders) {
    return ($folder.Name -match '^\d{8}_\d{6}$' -and $folder.CreationTimeUtc -ge $launchUtc -and $folder.FullName -notin $oldFolders)
}
function Get-ReviewedInstance([string]$config,[string]$detail) {
    $instance=Read-Setting $config 'INSTANCENAME'
    if($instance -notin @('MUT3','CAESARCOMPDB')){return $null}
    $instance=$instance.ToUpperInvariant()
    if(!(Read-Setting $config 'ACTION') -or !(Read-Setting $config 'FEATURES') -or !(Read-Setting $config 'SQLSVCACCOUNT')){return $null}
    if((Read-Setting $config 'ACTION') -ne 'Install' -or (Read-Setting $config 'FEATURES') -ne 'SQLENGINE' -or ((Read-Setting $config 'SQLSVCACCOUNT') -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE'){throw 'A new target SQL configuration differs from the reviewed installation.'}
    $sourceMatches=@($approvedMedia[$instance] | Where-Object {$detail.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0})
    if(!$sourceMatches.Count -or $detail -notmatch '(?i)Feature\s*=\s*SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32\b'){return $null}
    return $instance
}
function Test-AclReady([string]$instance) {
    $sidMap=@{MUT3='S-1-5-80-2329205841-2183319202-1762315884-1906354531-1149104739';CAESARCOMPDB='S-1-5-80-1730965570-1020681421-1004574069-504458456-3145505875'}
    $base32=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    $base64=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        $root='SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer\SuperSocketNetLib'
        foreach($path in @($root,($root+'\Tcp'),($root+'\Np'))) {
            $ref=$base32.OpenSubKey($path); $native=$base64.OpenSubKey($path)
            try {
                if(!$ref -or !$native){return $false}
                $rules=@($ref.GetAccessControl([Security.AccessControl.AccessControlSections]::Access).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq $sidMap[$instance]})
                if(@($rules | Where-Object {$_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny}).Count){throw 'The reference DACL includes a target service deny ACE.'}
                $grant=@($rules | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and (([int]$_.RegistryRights -band 131103) -eq 131103) -and (($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0) -and $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None })
                if(!$grant.Count){return $false}
            } finally {if($ref){$ref.Dispose()};if($native){$native.Dispose()}}
        }
        return $true
    } finally {$base32.Dispose();$base64.Dispose()}
}
function Find-NewMdacError([string]$folder,[datetime]$launchUtc) {
    foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter 'SQLServer_ERRORLOG_*.txt' -File)) {
        if($file.CreationTimeUtc -lt $launchUtc){continue}
        $errorText=Get-Content -LiteralPath $file.FullName -Raw
        if($errorText -notmatch '(?i)Microsoft SQL Server 2014[^\r\n]*\(Intel X86\)'){continue}
        foreach($line in ($errorText -split '\r?\n')) {
            if($line -notmatch '(?i)TDSSNIClient initialization failed with error 0x5, status code 0x90\. Reason: Unable to configure MDAC-compatibility protocol list in registry\. Access is denied\.'){continue}
            if($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,7})\s') {
                $eventTime=[datetime]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal)
                if($eventTime.ToUniversalTime() -ge $launchUtc){return $file.FullName}
            }
        }
    }
    return $null
}
function Test-PreservedSqlReady {
    # A reused engine needs fresh live evidence. Full application completion is
    # still decided by the parent using this run's vendor log and a later reboot.
    foreach($instance in @('MUT3','CAESARCOMPDB')){
        $service=Get-Service -Name ('MSSQL$'+$instance) -ErrorAction SilentlyContinue
        if(!$service -or $service.Status -ne 'Running'){return $false}
        $connection=New-Object Data.SqlClient.SqlConnection('Data Source=lpc:.\'+$instance+';Initial Catalog=master;Integrated Security=True;Connect Timeout=3;Pooling=False')
        try{
            $connection.Open()
            $command=$connection.CreateCommand();$command.CommandTimeout=5
            try{
                $command.CommandText="SELECT CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion'))"
                if([string]$command.ExecuteScalar() -cne '12.0.4100.1'){throw 'Preserved SQL version changed.'}
            }finally{$command.Dispose()}
        }catch [Data.SqlClient.SqlException]{return $false}
        finally{$connection.Dispose()}
    }
    return $true
}
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or ![Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Elevated 64-bit Windows PowerShell 5.1 is required.'}
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $expectedHashes=@{
        'MUT3_Install.bat'='F4032FD6668F4BDF0E303D9E136E8433730AD41EFA62C0F1D1F0FD08A30C623C'
        'Mut3Check.exe'='D5992A062AB03318F00B7948D7CE9467ADD3B8BE2435543C1CCF009D9C47FBA1'
        'BAT\NEW.BAT'='15081C5EF1EBBB1E795E6103DEFC7E294B66AC7DE0AD36ED5BCC4A24299BC5E1'
    }
    if($Release -eq 'SEW26061-00'){
        $expectedHashes['MUT3_Install.bat']='D1CCC586AF4378EA8183E7BEFA453334015B36423DC437733D22395625759467'
        $expectedHashes['BAT\NEW.BAT']='686C76EC251A58C4EC766FD401F16EE650944A35AA5450C7B3CAA15E946E11E8'
    }
    foreach($relative in $expectedHashes.Keys){if((Get-FileHash -LiteralPath (Join-Path $mediaRoot $relative) -Algorithm SHA256).Hash -ne $expectedHashes[$relative]){throw 'The original installation entry files differ from the reviewed media.'}}
    if((Get-FileHash -LiteralPath $repairPath -Algorithm SHA256).Hash -ne '043153444536CDDABFC9ABA3DFEE0113A71146C38D2B8D277BD609313314B1E6'){throw 'The scoped repair helper differs from the reviewed version.'}
    $services=@(Get-CimInstance Win32_Service | Where-Object {$_.Name -in @('MSSQL$MUT3','MSSQL$CAESARCOMPDB')})
    if($UpgradeManifest){
        if($Release -ne 'SEW26061-00'){throw 'A backed-up upgrade is only reviewed for SEW26061-00.'}
        if($UpgradeManifestHash -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath $UpgradeManifest -Algorithm SHA256).Hash -cne $UpgradeManifestHash){throw 'The upgrade backup manifest changed or its recorded hash is missing.'}
        Import-Module (Join-Path $PSScriptRoot 'Mut-Upgrade.psm1') -Force
        $backup=Assert-MutUpgradeBackup -ManifestPath $UpgradeManifest
        if($services.Count){
            if($services.Count -ne 2){throw 'Only one preserved SQL engine exists. Review before installation.'}
            $identity=Assert-MutPreservedSqlIdentity -Manifest $backup
            $identity | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'preserved-sql-before.json') -Encoding UTF8
            $preservedSql=$true
        }
    }elseif($UpgradeManifestHash -or $services.Count){throw 'Target SQL services or a backup hash exist without a verified upgrade backup. No installation was launched.'}
    if(Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00'){throw 'The original entry would select an update path; complete the original uninstallation first.'}
    foreach($path in @('C:\MUTSW','C:\MUTSW_SE')){if(Test-Path -LiteralPath $path){throw ('Existing MUT data remains at '+$path+'. Review it before a new installation.')}}
    $busy=@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(MUT3INSTALL|MUT3UNINSTALL|MT3NNSTLL|Mut3Check|MUT3_SE|MUT3_Launcher)\.exe$' -or
        ($_.Name -match '^(setup|en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935)\.exe$' -and (!$_.ExecutablePath -or $_.ExecutablePath -match '(?i)\\(?:SEW25091|SEW26061-00)\\|\\Microsoft SQL Server\\|en_sql_server_2014'))
    })
    if($busy.Count){throw 'A MUT or SQL installation process remains active; no installation was launched.'}
    foreach($pendingKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if(Test-Path -LiteralPath $pendingKey){throw 'Windows reports a pending restart. Restart manually before running this helper; no restart flags were changed.'}
    }
    $sessionManager=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if(@($sessionManager.PendingFileRenameOperations | Where-Object {![string]::IsNullOrEmpty($_)}).Count){throw 'Pending file replacements require a manual restart before this installation. No pending operations were changed.'}
    $netfx=Get-CimInstance Win32_OptionalFeature -Filter "Name='NetFx3'"
    if(!$netfx -or $netfx.InstallState -ne 1){throw '.NET Framework 3.5 is not enabled. Complete the prerequisite repair before this installation.'}
    $oldFolders=@(Get-ChildItem -LiteralPath $sqlLogRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
    $launchUtc=[datetime]::UtcNow
    $deadline=$launchUtc.AddMinutes(45)
    Write-Status 'launching-original-installer' 'Launching the unchanged original entry; region selection and original installer dialogs remain interactive.'
    $launcher=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /s /c ""'+$entryPath+'""') -WorkingDirectory $mediaRoot -WindowStyle Hidden -PassThru
    [ordered]@{launchUtc=$launchUtc.ToString('o'); deadlineUtc=$deadline.ToString('o'); entry=$entryPath; launcherPid=$launcher.Id} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot 'launch.json') -Encoding UTF8
    while([datetime]::UtcNow -lt $deadline) {
        if($preservedSql -and (Test-PreservedSqlReady)){
            foreach($instance in $targets.Keys){$targets[$instance].completed=$true}
            $exitCode=0
            Write-Status 'sql-engines-reused' 'Both backed-up SQL engines passed fresh live checks. This does not indicate completion of the original MUT installation.'
            break
        }
        $folders=@(Get-ChildItem -LiteralPath $sqlLogRoot -Directory -ErrorAction SilentlyContinue | Where-Object {Test-NewLogFolder $_ $launchUtc $oldFolders})
        foreach($folder in $folders) {
            $configPath=Join-Path $folder.FullName 'ConfigurationFile.ini';$detailPath=Join-Path $folder.FullName 'Detail.txt'
            if(!(Test-Path -LiteralPath $configPath) -or !(Test-Path -LiteralPath $detailPath)){continue}
            $config=Get-Content -LiteralPath $configPath -Raw
            $detail=Get-Content -LiteralPath $detailPath -Raw
            $instance=Get-ReviewedInstance $config $detail
            if(!$instance){continue}
            $state=$targets[$instance]
            if($state.log -and $state.log -ne $folder.FullName){throw ('An unexpected repeated SQL setup appeared for '+$instance+'. No second repair will be attempted.')}
            $state.log=$folder.FullName
            $summaries=@(Get-ChildItem -LiteralPath $folder.FullName -Filter 'Summary*.txt' -File)
            $summary=($summaries | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw}) -join "`n"
            if($summary -match '(?im)^[ \t]*Final result:[ \t]*(Failed|Cancelled|Canceled)\b'){throw ($instance+' SQL setup ended unsuccessfully; review its final summary. The coordinator will not terminate the original installer.')}
            if($state.patchedUtc -and (Find-NewMdacError $folder.FullName $state.patchedUtc)){throw ($instance+' produced the same MDAC 0x5/0x90 error after the one permitted repair. The watcher stopped without terminating the installer.')}
            if($summary -match '(?im)^\s*Final result:\s*Passed\s*$') {
                $running=Get-Service -Name ('MSSQL$'+$instance) -ErrorAction SilentlyContinue
                if($running -and $running.Status -eq 'Running'){$state.completed=$true}
            }
            if(!$state.attempted -and !$state.completed -and $detail -match 'Leaving Function NLRegSSetting\.SetShilohSecurityDescriptors\.') {
                $errorLog=Find-NewMdacError $folder.FullName $launchUtc
                if($errorLog -and (Test-AclReady $instance)) {
                    $state.attempted=$true
                    [ordered]@{instance=$instance; observed=(Get-Date).ToString('o'); sourceLog=$folder.FullName; engineErrorLog=$errorLog; reason='Current-run MDAC protocol list error 0x5/0x90 after original ACL setup; corresponding 32-bit grants verified.'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot ($instance+'-repair-trigger.json')) -Encoding UTF8
                    Write-Status 'repairing-scoped-acl' ('Applying the single permitted ACL repair for '+$instance+'.')
                    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $repairArguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$repairPath+'" -Instance '+$instance
                    $repair=Start-Process -FilePath $hostPath -ArgumentList $repairArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot ($instance+'-helper-output.txt')) -RedirectStandardError (Join-Path $runRoot ($instance+'-helper-errors.txt'))
                    $null=$repair.Handle
                    $waitMs=[int][Math]::Max(1,[Math]::Min(60000,($deadline-[datetime]::UtcNow).TotalMilliseconds))
                    if(!$repair.WaitForExit($waitMs)){throw 'The scoped helper exceeded its 60-second or overall observation limit. No process was terminated; inspect its status.'}
                    $repair.Refresh()
                    if($repair.ExitCode -ne 0){throw ($instance+' scoped ACL repair failed; inspect its per-instance status and backup.')}
                    $state.patched=$true
                    $state.patchedUtc=[datetime]::UtcNow
                }
            }
        }
        if($targets.MUT3.completed -and $targets.CAESARCOMPDB.completed){$exitCode=0;Write-Status 'sql-engines-completed' 'Both current-run SQL setups passed and both services are running. The original MUT installer may still be completing other components.';break}
        Write-Status 'watching-current-installation' 'Watching only the two reviewed SQL instances; no service control or process termination is performed.'
        Start-Sleep -Seconds 2
    }
    if($exitCode -ne 0){throw 'The 45-minute observation limit expired before both SQL engines completed. The watcher stopped without terminating the installer.'}
} catch {
    $exitCode=1
    try{Write-Status 'stopped-review-required' $_.Exception.Message}catch{Write-Output 'Could not write coordinator status.'}
    Write-Output ('STOPPED: '+$_.Exception.Message)
} finally {
    if(Test-Path -LiteralPath $runRoot){$exitCode | Set-Content -LiteralPath (Join-Path $runRoot 'exit-code.txt') -Encoding ASCII}
}
exit $exitCode
