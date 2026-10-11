#requires -Version 5.1
[CmdletBinding()]
param([string]$ResultPath)
# Isolated tests: virtual backup trees and metadata only, no SQL/service/system mutations.
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Run with Windows PowerShell 5.1.'}
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Mut-Upgrade.psm1') -Force
$module=Get-Module Mut-Upgrade
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value){if(!$Value){throw 'Expected true.'}}
function Assert-Throws([scriptblock]$Action){$thrown=$false;try{& $Action|Out-Null}catch{$thrown=$true};if(!$thrown){throw 'Expected guard rejection.'}}
function Case([string]$Name,[scriptblock]$Action){try{& $Action;$results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=$null});Write-Host ('PASS '+$Name)}catch{$results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$oldHash='1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03'
$newHash='A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8'
function New-State {
    return [pscustomobject]@{SchemaVersion=1;Machine=$env:COMPUTERNAME;MediaHash=$oldHash;Phase='Completed';BootUtc='2026-01-01T00:00:00.0000000Z';ResumePhase='';UpdatedUtc='2026-01-01T00:01:00.0000000Z';InstallStartedUtc='';InstallCompletedUtc='';LogBefore=$null;Coordinator=$null;UninstallStartedUtc='';ApplicationConfirmation=[pscustomobject]@{Classic=$true;SE=$true;ConfirmedUtc='2026-01-01T00:01:00.0000000Z';Source='User confirmation';VCITested=$false}}
}
Case 'Completed old state migrates without mutating it' {$s=New-State;$r=Get-MutUpgradeStateDecision $s $newHash $oldHash;Assert-True ($r.Action -eq 'MigrateCompleted' -and $s.MediaHash -eq $oldHash -and $s.Phase -eq 'Completed')}
Case 'Target state resumes' {$s=New-State;$s.MediaHash=$newHash;$s.Phase='Installing';Assert-True ((Get-MutUpgradeStateDecision $s $newHash $oldHash).Action -eq 'ResumeTarget')}
Case 'Incomplete old state refuses migration' {$s=New-State;$s.Phase='Installing';Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Foreign machine refuses migration' {$s=New-State;$s.Machine='OTHER';Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Unknown hash refuses migration' {$s=New-State;$s.MediaHash='F'*64;Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Missing state field refuses migration' {$s=New-State;$s.PSObject.Properties.Remove('Coordinator');Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Old state requires both application confirmations' {$s=New-State;$s.ApplicationConfirmation.SE=$false;Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Target hash cannot be supplied for an unreviewed release' {Assert-Throws {Get-MutUpgradeStateDecision (New-State) ('A'*64) $oldHash}}
Case 'Reboot state requires a resume phase' {$s=New-State;$s.MediaHash=$newHash;$s.Phase='AwaitingReboot';Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Unknown target phase is rejected' {$s=New-State;$s.MediaHash=$newHash;$s.Phase='DeleteEverything';Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}
Case 'Invalid state UTC is rejected' {$s=New-State;$s.BootUtc='yesterday';Assert-Throws {Get-MutUpgradeStateDecision $s $newHash $oldHash}}

# A fully simulated file provider is private to this imported module instance.
# Canonical-path, no-reparse, inventory, metadata and SHA comparison code remains real.
& $module {
    function script:Test-Path {param($LiteralPath) return $script:FixtureNodes.ContainsKey([string]$LiteralPath)}
    function script:Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction) if(!$script:FixtureNodes.ContainsKey([string]$LiteralPath)){throw 'Mock path missing.'};return $script:FixtureNodes[[string]$LiteralPath]}
    function script:Get-Content {param($LiteralPath,[switch]$Raw,$Encoding,$ErrorAction) return ($script:FixtureManifest|ConvertTo-Json -Depth 20)}
    function script:Get-FileHash {param($LiteralPath,$Algorithm,$ErrorAction) return [pscustomobject]@{Hash=$script:FixtureNodes[[string]$LiteralPath].Hash}}
    function script:Get-ChildItem {param($LiteralPath,[switch]$Force,$ErrorAction) return @($script:FixtureNodes.Values|Where-Object {[IO.Path]::GetDirectoryName($_.FullName) -ieq [string]$LiteralPath})}
    function script:Add-FixtureNode([string]$Path,[bool]$Directory){
        if(!$script:FixtureNodes.ContainsKey($Path)){$script:FixtureNodes[$Path]=[pscustomobject]@{FullName=$Path;PSIsContainer=$Directory;Length=1L;Hash=('A'*64);Attributes=$(if($Directory){16}else{0})}}
        $p=[IO.Path]::GetDirectoryName($Path);if($p -and $p -ne $Path){Add-FixtureNode $p $true}
    }
    function script:New-FixtureFile([string]$Source,[string]$Backup){
        Add-FixtureNode $Source $false;Add-FixtureNode $Backup $false
        return [pscustomobject]@{Source=$Source;Backup=$Backup;Length=1L;Sha256=('A'*64);SourceLastWriteUtc='2026-01-01T00:00:00.0000000Z';SourceAttributes=0}
    }
    function script:Reset-Fixture {
        $script:FixtureNodes=@{}
        $run='20260101-000000-0123456789abcdef0123456789abcdef';$root='C:\MUT-Install\upgrade-backups\'+$run
        $script:FixturePath=$root+'\manifest.json';Add-FixtureNode $script:FixturePath $false
        $names=Get-MutUpgradeDatabaseNames;$instances=@();$sql=@();$excluded=@()
        foreach($name in @('MUT3','CAESARCOMPDB')){
            $engine='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$name+'\MSSQL';$dbs=@();$files=@();$id=0
            foreach($db in (@('master','tempdb','model','msdb')+$names[$name])){
                $id++;$dbs+=[pscustomobject]@{name=$db;database_id=$id;state_desc='ONLINE';user_access_desc='MULTI_USER';HasAccess=1;is_read_only=$false}
                $fileId=0;foreach($type in @('ROWS','LOG')){
                    $fileId++;$path=Get-MutUpgradeSqlPath $name $db $type;Add-FixtureNode $path $false
                    $files+=[pscustomobject]@{DatabaseName=$db;database_id=$id;file_id=$fileId;type_desc=$type;physical_name=$path;Bytes=8192L}
                    if($db -in $names[$name]){$excluded+=$path}
                }
                if($db -in $names[$name]){$sql+=[pscustomobject]@{Instance=$name;Database=$db;Verified=$true;CopyOnly=$true;Checksums=$true;StagingPreserved=$true;File=(New-FixtureFile ($engine+'\Backup\MUTUpgrade-'+$run+'-'+$db+'.bak') ($root+'\sql\'+$name+'\'+$db+'.bak'))}}
            }
            $instances+=[pscustomobject]@{Instance=$name;Service=[pscustomobject]@{Name=('MSSQL$'+$name);State='Running';StartMode='Auto';StartName='NT AUTHORITY\NETWORK SERVICE';PathName=('"'+$engine+'\Binn\sqlservr.exe" -s'+$name)};Server=[pscustomobject]@{InstanceName=$name;ProductVersion='12.0.4100.1';ProductLevel='SP1';Edition='Express Edition';VersionText='Intel X86';IsSysadmin=1};SetupSource=[pscustomobject]@{Directory='C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log\20260101_000000';Action='Install';Result='Passed';Media='SEW25091';Architecture='x86'};BackupDirectory=($engine+'\Backup');Databases=$dbs;Files=$files}
        }
        $files=@();foreach($source in @('C:\MUTSW\InstLog.txt','C:\MUTSW\MUT3\MENU\SCRIPT\start.js','C:\MUTSW_SE\MUT3_SE\System\Version.xml','C:\MUTSW_SE\MUT3_SE\System\Common\MUT3_SE.exe')){$files+=New-FixtureFile $source ($root+'\files\'+$source.Substring(3))}
        $dirs=@();foreach($source in @($script:FixtureNodes.Keys|Where-Object {$_ -match '^C:\\(?:MUTSW|MUTSW_SE)\\' -and $script:FixtureNodes[$_].PSIsContainer})){
            $dest=$root+'\files\'+$source.Substring(3);Add-FixtureNode $dest $true;$dirs+=[pscustomobject]@{Source=$source;Backup=$dest}
        }
        $metadata=@();foreach($name in @('InstLog.txt','desktop\M.U.T.-3.lnk','desktop\M.U.T.-3_SE.lnk')){
            $src=$(if($name -eq 'InstLog.txt'){'C:\MUTSW\InstLog.txt'}else{'C:\Users\Public\Desktop\'+[IO.Path]::GetFileName($name)})
            $metadata+=New-FixtureFile $src ($root+'\metadata\'+$name)
        }
        $reg=$root+'\metadata\MMC-HKLM-32.reg';Add-FixtureNode $reg $false;$metadata+=[pscustomobject]@{RegistryKey='HKLM\SOFTWARE\WOW6432Node\MMC';Backup=$reg;Length=1L;Sha256=('A'*64)}
        $script:FixtureManifest=[pscustomobject]@{SchemaVersion=1;Status='Complete';Stage='Complete';RunId=$run;BackupRoot=$root;Machine=$env:COMPUTERNAME;ClassicVersion='PRG23061-03';SeVersion='SEW25091-00';StartedUtc='2026-01-01T00:00:00.0000000Z';CompletedUtc='2026-01-01T00:01:00.0000000Z';UpdatedUtc='2026-01-01T00:01:00.0000000Z';Instances=$instances;SqlBackups=$sql;Files=$files;Directories=$dirs;Metadata=$metadata;ExcludedDatabaseFiles=$excluded;Error=$null}
    }
}
function Backup-Case([string]$Name,[scriptblock]$Mutation,[bool]$Reject=$true,[bool]$VerifySource=$false){
    Case $Name {
        & $module {Reset-Fixture}
        & $module $Mutation
        $action={& $module {param($verify) Assert-MutUpgradeBackup $script:FixturePath -VerifySource:$verify} $VerifySource}
        if($Reject){Assert-Throws $action}else{$m=& $action;Assert-True ($m.Status -eq 'Complete' -and @($m.SqlBackups).Count -eq 44)}
    }
}
Backup-Case 'Complete backup and exact source tree pass' {} $false $true
Backup-Case 'Backup still validates when sources were uninstalled' {@($script:FixtureNodes.Keys|Where-Object {$_ -match '^C:\\MUTSW(?:_SE)?(?:\\|$)'})|ForEach-Object {$script:FixtureNodes.Remove($_)}} $false
Backup-Case 'Incomplete backup is rejected' {$script:FixtureManifest.Status='Incomplete'}
Backup-Case 'Foreign-machine backup is rejected' {$script:FixtureManifest.Machine='OTHER'}
Backup-Case 'Wrong old SE version is rejected' {$script:FixtureManifest.SeVersion='SEW26061-00'}
Backup-Case 'Missing SQL backup is rejected' {$script:FixtureManifest.SqlBackups=@($script:FixtureManifest.SqlBackups|Select-Object -Skip 1)}
Backup-Case 'Duplicate database backup is rejected' {$script:FixtureManifest.SqlBackups[1]=$script:FixtureManifest.SqlBackups[0]}
Backup-Case 'False SQL verification is rejected' {$script:FixtureManifest.SqlBackups[0].Verified=$false}
Backup-Case 'String true is rejected as evidence' {$script:FixtureManifest.SqlBackups[0].Verified='true'}
Backup-Case 'Wrong SQL physical path is rejected' {$script:FixtureManifest.Instances[0].Files[8].physical_name='C:\OTHER\test.mdf'}
Backup-Case 'Missing excluded database file is rejected' {$script:FixtureManifest.ExcludedDatabaseFiles=@($script:FixtureManifest.ExcludedDatabaseFiles|Select-Object -Skip 1)}
Backup-Case 'Empty application file list is rejected' {$script:FixtureManifest.Files=@()}
Backup-Case 'Empty directory list is rejected' {$script:FixtureManifest.Directories=@()}
Backup-Case 'Omitted application file cannot match disk tree' {$script:FixtureManifest.Files=@($script:FixtureManifest.Files|Select-Object -Skip 1)}
Backup-Case 'Modified BAK SHA is rejected' {$script:FixtureNodes[$script:FixtureManifest.SqlBackups[0].File.Backup].Hash='B'*64}
Backup-Case 'Modified application SHA is rejected' {$script:FixtureNodes[$script:FixtureManifest.Files[0].Backup].Hash='B'*64}
Backup-Case 'Modified metadata SHA is rejected' {$script:FixtureNodes[$script:FixtureManifest.Metadata[0].Backup].Hash='B'*64}
Backup-Case 'Missing mandatory metadata is rejected' {$script:FixtureManifest.Metadata=@($script:FixtureManifest.Metadata|Select-Object -Skip 1)}
Backup-Case 'Unlisted file on backup disk is rejected' {Add-FixtureNode ($script:FixtureManifest.BackupRoot+'\unknown.txt') $false}
Backup-Case 'Reparse point on backup root is rejected' {$script:FixtureNodes[$script:FixtureManifest.BackupRoot].Attributes=1040}
Backup-Case 'Reparse point on backup file is rejected' {$script:FixtureNodes[$script:FixtureManifest.Files[0].Backup].Attributes=1024}
Backup-Case 'Path traversal is rejected' {$script:FixtureManifest.Files[0].Source='C:\MUTSW\..\OTHER\test.txt'}
Backup-Case 'Alternate data stream is rejected' {$script:FixtureManifest.Files[0].Source='C:\MUTSW\InstLog.txt:evil'}
Backup-Case 'Backup redirected outside fixed root is rejected' {$script:FixtureManifest.Files[0].Backup='C:\OTHER\InstLog.txt'}
Backup-Case 'Source content change blocks uninstall' {$script:FixtureNodes[$script:FixtureManifest.Files[0].Source].Hash='B'*64} $true $true
Backup-Case 'New source file blocks uninstall' {Add-FixtureNode 'C:\MUTSW_SE\new-user-data.txt' $false} $true $true
Backup-Case 'New source directory blocks uninstall' {Add-FixtureNode 'C:\MUTSW_SE\new-user-dir' $true} $true $true
Backup-Case 'Missing source file blocks uninstall' {$script:FixtureNodes.Remove($script:FixtureManifest.Files[0].Source)} $true $true
Backup-Case 'Foreign SQL service in manifest is rejected' {$script:FixtureManifest.Instances[0].Service.StartName='LocalSystem'}
Backup-Case 'Future backup timestamp is rejected' {$script:FixtureManifest.UpdatedUtc=[datetime]::UtcNow.AddDays(1).ToString('o')}
Backup-Case 'Empty SQL backup is rejected' {$script:FixtureManifest.SqlBackups[0].File.Length=0}
Backup-Case 'False COPY_ONLY is rejected' {$script:FixtureManifest.SqlBackups[0].CopyOnly=$false}
Backup-Case 'SQL database identifiers cannot share one ID' {$script:FixtureManifest.Instances[0].Databases[5].database_id=$script:FixtureManifest.Instances[0].Databases[4].database_id}
Backup-Case 'SQL system database IDs cannot be relabelled' {$script:FixtureManifest.Instances[0].Databases[0].database_id=999}
Backup-Case 'Run directory identity mismatch is rejected' {$script:FixtureManifest.RunId='20260102-000000-0123456789abcdef0123456789abcdef'}
Backup-Case 'Missing backup content is rejected' {$script:FixtureNodes.Remove($script:FixtureManifest.SqlBackups[0].File.Backup)}
Backup-Case 'Unknown backup directory is rejected' {Add-FixtureNode ($script:FixtureManifest.BackupRoot+'\extra-dir') $true}
Backup-Case 'Duplicate application record is rejected' {$script:FixtureManifest.Files+=@($script:FixtureManifest.Files[0])}
Backup-Case 'Wrong registry export source is rejected' {$script:FixtureManifest.Metadata[3].RegistryKey='HKLM\SOFTWARE\OTHER'}

function Sql-Case([string]$Name,[scriptblock]$Mutation,[bool]$Reject=$true){Case $Name {
    & $module {
        Reset-Fixture;$script:SqlService=$script:FixtureManifest.Instances[0].Service
        $root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.MUT3\MSSQL'
        $script:SqlRegistry=@([pscustomobject]@{View='Registry32';Mapping='MSSQL12.MUT3';Exists=$true;Values=@{SQLPath=$root;SQLBinRoot=($root+'\Binn');SQLDataRoot=$root;Version='12.1.4100.1';PatchLevel='12.1.4100.1';Edition='Express Edition'}},[pscustomobject]@{View='Registry64';Mapping=$null;Exists=$false;Values=@{}})
    }
    & $module $Mutation
    $action={& $module {Assert-MutUpgradeSqlFacts $script:SqlService $script:SqlRegistry 'MUT3'}}
    if($Reject){Assert-Throws $action}else{& $action}
}}
Sql-Case 'Reviewed running SQL identity passes' {} $false
Sql-Case 'Reviewed stopped SQL identity passes without starting it' {$script:SqlService.State='Stopped'} $false
Sql-Case 'Start-pending SQL is rejected' {$script:SqlService.State='Start Pending'}
Sql-Case 'SQL account change is rejected' {$script:SqlService.StartName='LocalSystem'}
Sql-Case 'SQL service command change is rejected' {$script:SqlService.PathName='C:\other.exe'}
Sql-Case 'SQL engine registry version change is rejected' {$script:SqlRegistry[0].Values.Version='13.0.1.0'}
Sql-Case 'Native SQL registry identity is rejected' {$script:SqlRegistry[1].Exists=$true}
Sql-Case 'Disabled SQL startup is rejected' {$script:SqlService.StartMode='Disabled'}
Sql-Case 'Missing SQL registry view is rejected' {$script:SqlRegistry=@($script:SqlRegistry[0])}
function Rows-Case([string]$Name,[scriptblock]$Mutation,[bool]$Reject=$true){Case $Name {
    & $module {Reset-Fixture;$script:LiveRows=@($script:FixtureManifest.Instances[0].Files)}
    & $module $Mutation
    $action={& $module {Assert-MutUpgradeLiveSqlRows $script:LiveRows 'MUT3'}}
    if($Reject){Assert-Throws $action}else{& $action}
}}
Rows-Case 'All reviewed live SQL file paths pass' {} $false
Rows-Case 'System-only SQL after vendor uninstall passes' {$script:LiveRows=@($script:LiveRows|Where-Object {$_.database_id -le 4})} $false
Rows-Case 'Empty live SQL file list is rejected' {$script:LiveRows=@()}
Rows-Case 'Unknown live database is rejected' {$script:LiveRows[8].DatabaseName='OTHER'}
Rows-Case 'Unknown live physical path is rejected' {$script:LiveRows[8].physical_name='C:\OTHER\x.mdf'}
Rows-Case 'Missing live system database is rejected' {$script:LiveRows=@($script:LiveRows|Where-Object {$_.DatabaseName -ne 'master'})}
Rows-Case 'Incomplete live file pair is rejected' {$script:LiveRows=@($script:LiveRows|Select-Object -Skip 1)}
Rows-Case 'Duplicate live database file is rejected' {$script:LiveRows+=@($script:LiveRows[0])}
Rows-Case 'FILESTREAM is rejected' {$script:LiveRows[8].type_desc='FILESTREAM'}
Remove-Module Mut-Upgrade -Force
$failed=@($results|Where-Object {!$_.Passed}).Count
$report=[pscustomobject]@{Total=$results.Count;Passed=($results.Count-$failed);Failed=$failed;Scope='Isolated read-only guard tests with virtual filesystem and SQL metadata; no live install or restore.';Results=$results.ToArray()}
if($ResultPath){$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ResultPath -Encoding UTF8}
$report|Select-Object Total,Passed,Failed|Format-Table
if($failed){exit 1}
exit 0
