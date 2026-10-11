#requires -Version 5.1
# Read-only guards for the single reviewed SEW25091 -> SEW26061-00 upgrade.
# No function in this module installs, removes, restores, starts services, or writes state.
Set-StrictMode -Version 2

function Get-MutUpgradeDatabaseNames {
    return @{
        MUT3=@('MUTDAG','MUTIDEB','MUTIDEC','MUTIDECNB','MUTIDECNC','MUTIDECNE','MUTIDECNF','MUTIDECNG','MUTIDECNH','MUTIDECNI','MUTIDECNJ','MUTIDECNK','MUTIDECNL','MUTIDECNN','MUTIDECNR','MUTIDECNS','MUTIDECNT','MUTIDECNV','MUTIDECNW','MUTIDECNY','MUTIDEE','MUTIDEF','MUTIDEG','MUTIDEH','MUTIDEI','MUTIDEJ','MUTIDEK','MUTIDEL','MUTIDEN','MUTIDER','MUTIDES','MUTIDET','MUTIDEV','MUTIDEW','MUTIDEY','MUTMCB','MUTMCN','MUTNSAD','MUTOEMS','MUTPRO','MUTPROCN','MUTSYS')
        CAESARCOMPDB=@('CAESARCOMPDB2','CFFDB')
    }
}
function Assert-MutUpgradeProperties($Value,[string[]]$Names) {
    if($null -eq $Value -or $Value -is [array]){throw 'Required upgrade object is missing or is an array.'}
    foreach($name in $Names){if($Value.PSObject.Properties.Name -notcontains $name){throw ('Required upgrade field is missing: '+$name)}}
}
function Assert-MutUpgradeSet([object[]]$Actual,[object[]]$Expected,[string]$Label) {
    $a=@($Actual | ForEach-Object {[string]$_});$e=@($Expected | ForEach-Object {[string]$_})
    $allowed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $e){if(!$allowed.Add($entry)){throw ($Label+' has duplicate expected entries.')}}
    if($a.Count -ne $e.Count){throw ($Label+' has missing or extra entries.')}
    foreach($entry in $a){if(!$allowed.Contains($entry) -or !$seen.Add($entry)){throw ($Label+' has unknown or duplicate entries.')}}
}
function ConvertTo-MutUpgradeUtc([string]$Value) {
    $parsed=[datetime]::MinValue
    if($Value -notmatch '^\d{4}-\d{2}-\d{2}T.*Z$' -or
        ![datetime]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) {throw 'Invalid UTC timestamp in upgrade evidence.'}
    return $parsed.ToUniversalTime()
}
function Get-MutUpgradeCanonicalPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(3).Contains(':') -or
        $Path -match '[\x00-\x1F*?"<>|/]' -or $Path -match '(?:^|\\)\.{1,2}(?:\\|$)' -or $Path -match '[ .](?:\\|$)') {
        throw ('Unsafe upgrade path refused: '+$Path)
    }
    $full=[IO.Path]::GetFullPath($Path)
    if($full.TrimEnd('\') -ine $Path.TrimEnd('\')){throw 'Upgrade path is not canonical.'}
    return $full.TrimEnd('\')
}
function Assert-MutUpgradePath([string]$Path,[switch]$AllowMissing) {
    $full=Get-MutUpgradeCanonicalPath $Path
    $current=$full
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Reparse point refused: '+$current)}
        }elseif(!$AllowMissing){throw ('Required upgrade path is missing: '+$current)}
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if(!$parent -or $parent -eq $current){break};$current=$parent
    }
    return $full
}
function Get-MutUpgradeTree([string]$Root) {
    $null=Assert-MutUpgradePath $Root
    $queue=New-Object 'System.Collections.Generic.Stack[string]';$queue.Push($Root)
    while($queue.Count){
        foreach($entry in @(Get-ChildItem -LiteralPath $queue.Pop() -Force -ErrorAction Stop)){
            $null=Assert-MutUpgradePath $entry.FullName
            if(!$entry.FullName.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Upgrade tree escaped its root.'}
            [pscustomobject]@{Path=$entry.FullName;Directory=[bool]$entry.PSIsContainer}
            if($entry.PSIsContainer){$queue.Push($entry.FullName)}
        }
    }
}
function Get-MutUpgradeSqlPath([string]$Instance,[string]$Database,[string]$Type) {
    if($Instance -notin @('MUT3','CAESARCOMPDB') -or $Type -notin @('ROWS','LOG')){throw 'Unreviewed SQL instance or file type.'}
    if($Database -in @('master','model','msdb','tempdb')){
        $map=@{master=@('master.mdf','mastlog.ldf');model=@('model.mdf','modellog.ldf');msdb=@('MSDBData.mdf','MSDBLog.ldf');tempdb=@('tempdb.mdf','templog.ldf')}
        return ('C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL\DATA\'+$map[$Database][$(if($Type -eq 'ROWS'){0}else{1})])
    }
    if($Database -notin (Get-MutUpgradeDatabaseNames)[$Instance]){throw 'Unreviewed user database.'}
    $suffix=$(if($Type -eq 'ROWS'){'_data.mdf'}else{'_log.ldf'})
    if($Instance -eq 'CAESARCOMPDB'){return ('C:\MUTSW\MUT3\CAESARCOMPDB\'+$Database+$suffix)}
    if($Database -eq 'MUTMCB'){return ('C:\MUTSW\MUT3\CANBUSDB\'+$Database+$suffix)}
    $folder=$(if($Database -match '^MUTIDECN' -or $Database -in @('MUTMCN','MUTPROCN')){'CANDB'}else{'DIAGDB'})
    return ('C:\MUTSW\MUT3\'+$folder+'\'+$Database+$(if($Type -eq 'ROWS'){'.MDF'}else{'_LOG.LDF'}))
}
function Assert-MutUpgradeManifestIdentity($Manifest) {
    Assert-MutUpgradeProperties $Manifest @('SchemaVersion','Status','Stage','RunId','BackupRoot','Machine','ClassicVersion','SeVersion','StartedUtc','CompletedUtc','UpdatedUtc','Instances','SqlBackups','Files','Directories','Metadata','ExcludedDatabaseFiles','Error')
    if($Manifest.SchemaVersion -ne 1 -or $Manifest.Status -cne 'Complete' -or $Manifest.Stage -cne 'Complete' -or
        $null -ne $Manifest.Error -or $Manifest.Machine -cne $env:COMPUTERNAME -or $Manifest.ClassicVersion -cne 'PRG23061-03' -or
        $Manifest.SeVersion -cne 'SEW25091-00' -or $Manifest.RunId -cnotmatch '^\d{8}-\d{6}-[a-f0-9]{32}$') {throw 'Backup is not a completed, reviewed old installation on this machine.'}
    $expectedRoot='C:\MUT-Install\upgrade-backups\'+$Manifest.RunId
    if((Get-MutUpgradeCanonicalPath $Manifest.BackupRoot) -ine $expectedRoot){throw 'BackupRoot does not match the fixed unique upgrade directory.'}
    $started=ConvertTo-MutUpgradeUtc $Manifest.StartedUtc;$completed=ConvertTo-MutUpgradeUtc $Manifest.CompletedUtc;$updated=ConvertTo-MutUpgradeUtc $Manifest.UpdatedUtc
    if($started -gt $completed -or $completed -gt $updated -or $updated -gt [datetime]::UtcNow.AddMinutes(5)){throw 'Backup timestamps are inconsistent.'}
    Assert-MutUpgradeSet @($Manifest.Instances|ForEach-Object {$_.Instance}) @('MUT3','CAESARCOMPDB') 'SQL instances'
    $names=Get-MutUpgradeDatabaseNames;$userFiles=@()
    foreach($instance in $Manifest.Instances){
        Assert-MutUpgradeProperties $instance @('Instance','Service','Server','SetupSource','BackupDirectory','Databases','Files')
        $name=$instance.Instance;$root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$name+'\MSSQL'
        Assert-MutUpgradeProperties $instance.Service @('Name','State','StartMode','StartName','PathName')
        if($instance.Service.Name -cne ('MSSQL$'+$name) -or $instance.Service.State -cne 'Running' -or $instance.Service.StartMode -cne 'Auto' -or
            ($instance.Service.StartName -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or $instance.Service.PathName -ine ('"'+$root+'\Binn\sqlservr.exe" -s'+$name) -or
            $instance.BackupDirectory -ine ($root+'\Backup')){throw 'Backup SQL service identity differs from the reviewed old installation.'}
        Assert-MutUpgradeProperties $instance.Server @('InstanceName','ProductVersion','ProductLevel','Edition','VersionText','IsSysadmin')
        if($instance.Server.InstanceName -cne $name -or $instance.Server.ProductVersion -cne '12.0.4100.1' -or $instance.Server.ProductLevel -cne 'SP1' -or
            $instance.Server.Edition -notmatch '^Express Edition' -or $instance.Server.VersionText -notmatch 'Intel X86' -or $instance.Server.IsSysadmin -ne 1){throw 'Backup SQL server identity differs from the reviewed engine.'}
        Assert-MutUpgradeProperties $instance.SetupSource @('Directory','Action','Result','Media','Architecture')
        if($instance.SetupSource.Action -cne 'Install' -or $instance.SetupSource.Result -cne 'Passed' -or $instance.SetupSource.Media -cne 'SEW25091' -or
            $instance.SetupSource.Architecture -cne 'x86' -or $instance.SetupSource.Directory -notmatch '^C:\\Program Files \(x86\)\\Microsoft SQL Server\\120\\Setup Bootstrap\\Log\\\d{8}_\d{6}$'){throw 'Backup SQL source evidence differs from the reviewed installer.'}
        $expected=@('master','model','msdb','tempdb')+$names[$name]
        Assert-MutUpgradeSet @($instance.Databases|ForEach-Object {$_.name}) $expected ($name+' database list')
        if(@($instance.Databases.database_id|Sort-Object -Unique).Count -ne $expected.Count){throw 'Backup database IDs are duplicated.'}
        $systemIds=@{master=1;tempdb=2;model=3;msdb=4}
        foreach($db in $instance.Databases){
            Assert-MutUpgradeProperties $db @('name','database_id','state_desc','user_access_desc','HasAccess')
            if($db.state_desc -cne 'ONLINE' -or $db.user_access_desc -cne 'MULTI_USER' -or $db.HasAccess -ne 1 -or
                ($db.name -in $names[$name] -and $db.database_id -le 4) -or
                ($systemIds.ContainsKey($db.name) -and $db.database_id -ne $systemIds[$db.name])){throw 'Backup contains an unhealthy or inconsistent database.'}
        }
        if(@($instance.Files).Count -ne 2*$expected.Count){throw 'Backup SQL file inventory is incomplete.'}
        foreach($db in $expected){
            $files=@($instance.Files|Where-Object {$_.DatabaseName -ceq $db})
            Assert-MutUpgradeSet @($files|ForEach-Object {$_.type_desc}) @('ROWS','LOG') ($name+'/'+$db+' SQL files')
            foreach($file in $files){
                Assert-MutUpgradeProperties $file @('DatabaseName','database_id','file_id','type_desc','physical_name','Bytes')
                if($file.physical_name -ine (Get-MutUpgradeSqlPath $name $db $file.type_desc) -or $file.Bytes -le 0 -or
                    $file.database_id -ne @($instance.Databases|Where-Object {$_.name -ceq $db})[0].database_id){throw 'Backup SQL physical file identity is not reviewed.'}
                if($db -in $names[$name]){$userFiles+=$file.physical_name}
            }
        }
    }
    Assert-MutUpgradeSet @($Manifest.ExcludedDatabaseFiles) $userFiles 'Excluded SQL source files'
    $expectedBackups=@();foreach($name in @('MUT3','CAESARCOMPDB')){foreach($db in $names[$name]){$expectedBackups+=($name+'/'+$db)}}
    Assert-MutUpgradeSet @($Manifest.SqlBackups|ForEach-Object {$_.Instance+'/'+$_.Database}) $expectedBackups '44 SQL backups'
    foreach($backup in $Manifest.SqlBackups){
        Assert-MutUpgradeProperties $backup @('Instance','Database','Verified','CopyOnly','Checksums','StagingPreserved','File')
        foreach($flag in @('Verified','CopyOnly','Checksums','StagingPreserved')){if($backup.$flag -isnot [bool] -or !$backup.$flag){throw ('SQL backup flag is not verified: '+$flag)}}
        if($backup.File.Length -le 0){throw 'An empty SQL backup cannot authorize an upgrade.'}
        $expectedSource='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$backup.Instance+'\MSSQL\Backup\MUTUpgrade-'+$Manifest.RunId+'-'+$backup.Database+'.bak'
        if($backup.File.Source -ine $expectedSource -or $backup.File.Backup -ine ($expectedRoot+'\sql\'+$backup.Instance+'\'+$backup.Database+'.bak')){throw 'SQL backup path does not match the fixed instance and database.'}
    }
}
function Assert-MutUpgradeFileRecord($Record,[switch]$VerifySource) {
    Assert-MutUpgradeProperties $Record @('Backup','Length','Sha256')
    if($Record.Sha256 -cnotmatch '^[A-F0-9]{64}$' -or $Record.Length -isnot [ValueType] -or [long]$Record.Length -lt 0 -or [double]$Record.Length -ne [long]$Record.Length){throw 'Invalid backup size or SHA-256.'}
    $null=Assert-MutUpgradePath $Record.Backup
    $item=Get-Item -LiteralPath $Record.Backup -Force -ErrorAction Stop
    if($item.PSIsContainer -or $item.Length -ne [long]$Record.Length -or (Get-FileHash -LiteralPath $Record.Backup -Algorithm SHA256 -ErrorAction Stop).Hash -cne $Record.Sha256){throw ('Backup content verification failed: '+$Record.Backup)}
    if($VerifySource){
        Assert-MutUpgradeProperties $Record @('Source')
        $null=Assert-MutUpgradePath $Record.Source
        $source=Get-Item -LiteralPath $Record.Source -Force -ErrorAction Stop
        if($source.PSIsContainer -or $source.Length -ne [long]$Record.Length -or (Get-FileHash -LiteralPath $Record.Source -Algorithm SHA256 -ErrorAction Stop).Hash -cne $Record.Sha256){throw ('Source changed after backup: '+$Record.Source)}
    }
}
function Get-MutUpgradeSourceRelative([string]$Source) {
    $full=Get-MutUpgradeCanonicalPath $Source
    if($full -notmatch '^C:\\(MUTSW|MUTSW_SE)\\(.+)$'){throw 'Source is outside the two reviewed application roots.'}
    return ($matches[1]+'\'+$matches[2])
}
function Assert-MutUpgradeBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ManifestPath,[switch]$VerifySource)
    $path=Assert-MutUpgradePath $ManifestPath
    if($path -notmatch '^C:\\MUT-Install\\upgrade-backups\\\d{8}-\d{6}-[a-f0-9]{32}\\manifest\.json$'){throw 'Use manifest.json in its original unique upgrade-backups directory.'}
    $manifest=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    Assert-MutUpgradeManifestIdentity $manifest
    $root=$manifest.BackupRoot
    if($path -ine ($root+'\manifest.json')){throw 'Manifest was moved from its recorded backup directory.'}
    if(!@($manifest.Files).Count -or !@($manifest.Directories).Count){throw 'Application file and directory inventories must not be empty.'}
    # Array += copies all preceding elements on each append in PowerShell 5.1.
    # The reviewed application tree has over 51,000 files, so accumulate once.
    $expectedFiles=New-Object 'System.Collections.Generic.List[string]'
    $expectedFiles.Add($path)
    $expectedDirs=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in @('files','files\MUTSW','files\MUTSW_SE','sql','sql\MUT3','sql\CAESARCOMPDB','metadata','metadata\desktop')){$expectedDirs.Add($root+'\'+$relative)}
    $sourceFiles=New-Object 'System.Collections.Generic.List[string]'
    $sourceDirs=New-Object 'System.Collections.Generic.List[string]'
    foreach($record in $manifest.Files){
        Assert-MutUpgradeProperties $record @('Source','Backup','Length','Sha256','SourceLastWriteUtc','SourceAttributes')
        $rel=Get-MutUpgradeSourceRelative $record.Source
        if($record.Source -match '(?i)\.(mdf|ndf|ldf)$' -or $record.Backup -ine ($root+'\files\'+$rel)){throw 'Application backup path differs or contains a raw database file.'}
        $null=ConvertTo-MutUpgradeUtc $record.SourceLastWriteUtc
        Assert-MutUpgradeFileRecord $record -VerifySource:$VerifySource
        $expectedFiles.Add($record.Backup);$sourceFiles.Add($record.Source)
    }
    foreach($required in @('C:\MUTSW\InstLog.txt','C:\MUTSW\MUT3\MENU\SCRIPT\start.js','C:\MUTSW_SE\MUT3_SE\System\Version.xml','C:\MUTSW_SE\MUT3_SE\System\Common\MUT3_SE.exe')){
        if($required -notin $sourceFiles){throw ('Critical old application file is missing from backup: '+$required)}
    }
    foreach($record in $manifest.Directories){
        Assert-MutUpgradeProperties $record @('Source','Backup');$rel=Get-MutUpgradeSourceRelative $record.Source
        if($record.Backup -ine ($root+'\files\'+$rel)){throw 'Application directory backup mapping differs.'}
        $expectedDirs.Add($record.Backup);$sourceDirs.Add($record.Source)
    }
    foreach($backup in $manifest.SqlBackups){Assert-MutUpgradeFileRecord $backup.File;$expectedFiles.Add($backup.File.Backup)}
    $metadataNames=@();$requiredMetadata=@('InstLog.txt','desktop\M.U.T.-3.lnk','desktop\M.U.T.-3_SE.lnk','MMC-HKLM-32.reg')
    $allowedMetadata=@($requiredMetadata)+@('oneclick-state.json','MMC-HKLM-64.reg','MMC-HKCU.reg')
    foreach($record in $manifest.Metadata){
        Assert-MutUpgradeProperties $record @('Backup','Length','Sha256')
        $prefix=$root+'\metadata\';$full=Get-MutUpgradeCanonicalPath $record.Backup
        if(!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Metadata path is outside its backup directory.'}
        $name=$full.Substring($prefix.Length)
        if($name -notin $allowedMetadata -or $name -in $metadataNames){throw 'Unknown or duplicate backup metadata.'}
        if($name -like '*.reg'){
            Assert-MutUpgradeProperties $record @('RegistryKey')
            $keys=@{'MMC-HKLM-32.reg'='HKLM\SOFTWARE\WOW6432Node\MMC';'MMC-HKLM-64.reg'='HKLM\SOFTWARE\MMC';'MMC-HKCU.reg'='HKCU\SOFTWARE\MMC'}
            if($record.RegistryKey -ine $keys[$name]){throw 'Registry export source differs.'}
        }else{
            Assert-MutUpgradeProperties $record @('Source')
            $sources=@{'InstLog.txt'='C:\MUTSW\InstLog.txt';'oneclick-state.json'='C:\MUT-Install\oneclick-state.json';'desktop\M.U.T.-3.lnk'='C:\Users\Public\Desktop\M.U.T.-3.lnk';'desktop\M.U.T.-3_SE.lnk'='C:\Users\Public\Desktop\M.U.T.-3_SE.lnk'}
            if($record.Source -ine $sources[$name]){throw 'Metadata source differs.'}
        }
        Assert-MutUpgradeFileRecord $record
        $metadataNames+=$name;$expectedFiles.Add($record.Backup)
    }
    if(@($requiredMetadata|Where-Object {$_ -notin $metadataNames}).Count){throw 'Required backup metadata is missing.'}
    $tree=@(Get-MutUpgradeTree $root)
    Assert-MutUpgradeSet @($tree|Where-Object {!$_.Directory}|ForEach-Object {$_.Path}) $expectedFiles.ToArray() 'Backup files on disk'
    Assert-MutUpgradeSet @($tree|Where-Object {$_.Directory}|ForEach-Object {$_.Path}) $expectedDirs.ToArray() 'Backup directories on disk'
    if($VerifySource){
        $live=@(Get-MutUpgradeTree 'C:\MUTSW')+@(Get-MutUpgradeTree 'C:\MUTSW_SE')
        Assert-MutUpgradeSet @($live|Where-Object {!$_.Directory}|ForEach-Object {$_.Path}) @($sourceFiles.ToArray()+$manifest.ExcludedDatabaseFiles) 'Current source files'
        Assert-MutUpgradeSet @($live|Where-Object {$_.Directory}|ForEach-Object {$_.Path}) $sourceDirs.ToArray() 'Current source directories'
    }
    return $manifest
}
function Get-MutUpgradeStateDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][string]$TargetHash,[Parameter(Mandatory=$true)][string]$KnownOldHash,[string]$Machine=$env:COMPUTERNAME)
    $old='1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03';$target='A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8'
    if($KnownOldHash -cne $old -or $TargetHash -cne $target){throw 'Only the reviewed SEW25091 to SEW26061-00 state migration is supported.'}
    Assert-MutUpgradeProperties $State @('SchemaVersion','Machine','MediaHash','Phase','BootUtc','ResumePhase','UpdatedUtc','InstallStartedUtc','InstallCompletedUtc','LogBefore','Coordinator','UninstallStartedUtc','ApplicationConfirmation')
    if($State.SchemaVersion -ne 1 -or $State.Machine -cne $Machine){throw 'State schema or machine does not match.'}
    $null=ConvertTo-MutUpgradeUtc $State.BootUtc;$null=ConvertTo-MutUpgradeUtc $State.UpdatedUtc
    foreach($field in @('InstallStartedUtc','InstallCompletedUtc','UninstallStartedUtc')){if($State.$field){$null=ConvertTo-MutUpgradeUtc $State.$field}}
    $phases=@('Checking','Installing','InstallReviewRequired','AwaitingReboot','Prerequisites','AfterPrerequisites','Uninstalling','UninstallReviewRequired','AfterUninstall','RemovingFailedSql','AfterSqlCleanup','InstallationFinished','AfterInstall','AwaitingApplicationConfirmation','Completed','UpgradePrepared','UpgradeUninstalling','UpgradeUninstallReviewRequired','UpgradeAfterUninstall')
    if($State.Phase -notin $phases -or ($State.ResumePhase -and $State.ResumePhase -notin $phases) -or ($State.Phase -eq 'AwaitingReboot' -and !$State.ResumePhase)){throw 'State has an unknown phase or invalid reboot continuation.'}
    if($State.MediaHash -ceq $target){return [pscustomobject]@{Action='ResumeTarget';PreviousHash=$target;TargetHash=$target;Phase=$State.Phase}}
    if($State.MediaHash -cne $old -or $State.Phase -cne 'Completed'){throw 'Only a completed reviewed old state can migrate; no incomplete installation will be replayed.'}
    Assert-MutUpgradeProperties $State.ApplicationConfirmation @('Classic','SE','ConfirmedUtc','Source','VCITested')
    if($State.ApplicationConfirmation.Classic -isnot [bool] -or !$State.ApplicationConfirmation.Classic -or $State.ApplicationConfirmation.SE -isnot [bool] -or !$State.ApplicationConfirmation.SE){throw 'Old state lacks both application confirmations.'}
    $null=ConvertTo-MutUpgradeUtc $State.ApplicationConfirmation.ConfirmedUtc
    return [pscustomobject]@{Action='MigrateCompleted';PreviousHash=$old;TargetHash=$target;Phase='UpgradePrepared'}
}
function Get-MutUpgradeSqlRegistry([string]$Instance) {
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view);$map=$null;$setup=$null
        try{
            $map=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL');$setup=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.'+$Instance+'\Setup')
            $values=@{};if($setup){foreach($name in @('SQLPath','SQLBinRoot','SQLDataRoot','Version','PatchLevel','Edition')){$values[$name]=$setup.GetValue($name)}}
            [pscustomobject]@{View=$view.ToString();Mapping=$(if($map){$map.GetValue($Instance)}else{$null});Exists=[bool]$setup;Values=$values}
        }finally{if($map){$map.Dispose()};if($setup){$setup.Dispose()};$base.Dispose()}
    }
}
function Assert-MutUpgradeSqlFacts($Service,[object[]]$Registry,[string]$Instance) {
    $root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL'
    if($Instance -notin @('MUT3','CAESARCOMPDB') -or @($Service).Count -ne 1 -or $Service.Name -cne ('MSSQL$'+$Instance) -or
        $Service.State -notin @('Running','Stopped') -or $Service.StartMode -cne 'Auto' -or ($Service.StartName -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or
        $Service.PathName -ine ('"'+$root+'\Binn\sqlservr.exe" -s'+$Instance)){throw 'Preserved SQL service has an unknown identity or transitional state.'}
    Assert-MutUpgradeSet @($Registry|ForEach-Object {$_.View}) @('Registry32','Registry64') 'Preserved SQL registry views'
    $wow=@($Registry|Where-Object {$_.View -eq 'Registry32'})[0];$native=@($Registry|Where-Object {$_.View -eq 'Registry64'})[0]
    if(!$wow.Exists -or $wow.Mapping -ine ('MSSQL12.'+$Instance) -or $wow.Values.SQLPath -ine $root -or $wow.Values.SQLBinRoot -ine ($root+'\Binn') -or
        $wow.Values.SQLDataRoot -ine $root -or $wow.Values.Version -cne '12.1.4100.1' -or $wow.Values.PatchLevel -cne '12.1.4100.1' -or $wow.Values.Edition -cne 'Express Edition' -or
        $native.Exists -or $native.Mapping){throw 'Preserved SQL registry identity differs from the reviewed x86 SP1 engine.'}
}
function Read-MutUpgradeLiveSql([string]$Instance) {
    $connection=New-Object Data.SqlClient.SqlConnection ('Data Source=lpc:.\'+$Instance+';Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Pooling=False;Application Name=MUT upgrade read-only verification')
    try{
        $connection.Open();$cmd=$connection.CreateCommand();$cmd.CommandTimeout=30
        try{
            $cmd.CommandText="SELECT CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')) AS InstanceName, CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS ProductVersion, CONVERT(nvarchar(4000),@@VERSION) AS VersionText; SELECT DB_NAME(database_id) AS DatabaseName,type_desc,physical_name FROM sys.master_files ORDER BY database_id,file_id;"
            $adapter=New-Object Data.SqlClient.SqlDataAdapter $cmd;$data=New-Object Data.DataSet
            try{[void]$adapter.Fill($data)}finally{$adapter.Dispose()}
            if($data.Tables.Count -ne 2 -or $data.Tables[0].Rows.Count -ne 1){throw 'Unexpected live SQL identity result.'}
            $server=$data.Tables[0].Rows[0]
            if($server.InstanceName -cne $Instance -or $server.ProductVersion -cne '12.0.4100.1' -or $server.VersionText -notmatch 'Intel X86'){throw 'Live SQL server version or architecture differs.'}
            foreach($row in $data.Tables[1].Rows){[pscustomobject]@{DatabaseName=[string]$row.DatabaseName;type_desc=[string]$row.type_desc;physical_name=[string]$row.physical_name}}
        }finally{$cmd.Dispose()}
    }finally{$connection.Dispose()}
}
function Assert-MutUpgradeLiveSqlRows([object[]]$Rows,[string]$Instance) {
    if(!$Rows.Count){throw 'Live preserved SQL returned an empty file inventory.'}
    foreach($file in $Rows){
        Assert-MutUpgradeProperties $file @('DatabaseName','type_desc','physical_name')
        if($file.physical_name -ine (Get-MutUpgradeSqlPath $Instance $file.DatabaseName $file.type_desc)){throw 'Live preserved SQL contains an unreviewed database file.'}
    }
    foreach($db in @($Rows.DatabaseName|Sort-Object -Unique)){Assert-MutUpgradeSet @($Rows|Where-Object {$_.DatabaseName -ceq $db}|ForEach-Object {$_.type_desc}) @('ROWS','LOG') 'Live preserved database files'}
    foreach($db in @('master','model','msdb','tempdb')){if($db -notin $Rows.DatabaseName){throw 'Live preserved SQL is missing a system database.'}}
}
function Assert-MutPreservedSqlIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Manifest)
    # Caller must first validate all backup bytes with Assert-MutUpgradeBackup.
    Assert-MutUpgradeManifestIdentity $Manifest
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop)
    foreach($instance in @('MUT3','CAESARCOMPDB')){
        $root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$instance+'\MSSQL'
        $service=@($services|Where-Object {$_.Name -ceq ('MSSQL$'+$instance)})
        if($service.Count -ne 1){throw ('Preserved SQL service is missing: '+$instance)}
        Assert-MutUpgradeSqlFacts $service[0] @(Get-MutUpgradeSqlRegistry $instance) $instance
        $exe=$root+'\Binn\sqlservr.exe';$null=Assert-MutUpgradePath $exe;$version=(Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo
        if($version.ProductVersion -cne '12.0.4100.1' -or $version.CompanyName -cne 'Microsoft Corporation'){throw 'Preserved SQL engine binary version differs.'}
        $stream=[IO.File]::OpenRead($exe)
        try{$reader=New-Object IO.BinaryReader $stream;if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D){throw 'Invalid SQL PE header.'};$stream.Position=60;$offset=$reader.ReadInt32();if($offset -lt 64 -or $offset -gt $stream.Length-6){throw 'Invalid SQL PE offset.'};$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x014C){throw 'Preserved SQL binary is not x86.'}}finally{$stream.Dispose()}
        $expected=@($Manifest.Instances|Where-Object {$_.Instance -ceq $instance})[0]
        $data=@(Get-MutUpgradeTree ($root+'\DATA'))
        if(@($data|Where-Object {$_.Directory}).Count){throw 'Unexpected directory in SQL DATA.'}
        Assert-MutUpgradeSet @($data|ForEach-Object {$_.Path}) @($expected.Files|Where-Object {$_.DatabaseName -in @('master','model','msdb','tempdb')}|ForEach-Object {$_.physical_name}) 'SQL system DATA files'
        if($service[0].State -eq 'Running'){
            $live=@(Read-MutUpgradeLiveSql $instance)
            Assert-MutUpgradeLiveSqlRows $live $instance
        }
        [pscustomobject]@{Instance=$instance;State=$service[0].State;ProductVersion='12.0.4100.1';Preserved=$true;ServiceChanged=$false}
    }
    # Any surviving application MDF/LDF must have been present in the reviewed backup.
    foreach($source in @('C:\MUTSW','C:\MUTSW_SE')){
        if(Test-Path -LiteralPath $source){foreach($file in @(Get-MutUpgradeTree $source|Where-Object {!$_.Directory -and $_.Path -match '(?i)\.(mdf|ndf|ldf)$'})){
            if($file.Path -notin $Manifest.ExcludedDatabaseFiles){throw ('Unknown surviving SQL data file: '+$file.Path)}
        }}
    }
}
Export-ModuleMember -Function Assert-MutUpgradeBackup,Get-MutUpgradeStateDecision,Assert-MutPreservedSqlIdentity
