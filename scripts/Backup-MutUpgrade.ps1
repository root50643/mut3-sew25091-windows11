#requires -Version 5.1
<#
.SYNOPSIS
Preserves the reviewed PRG23061-03 / SEW25091-00 installation before removal.
.DESCRIPTION
Run in elevated, native Windows PowerShell 5.1 after closing both MUT programs.
-InspectOnly performs all identity/inventory checks without creating files or SQL backups.
The normal mode never uninstalls, restores, deletes backups, or changes SQL services.
SQL BACKUP writes backup history in msdb; COPY_ONLY does not reset the differential base.
Only a manifest whose Status is Complete authorizes treating this backup as finished.
VERIFYONLY is a readability/checksum check, not an actual restore or DBCC integrity test.
#>
[CmdletBinding()]
param([switch]$InspectOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RunRoot = $null
$script:Manifest = $null
$script:Stage = 'Preflight'
$script:SourceRoots = @('C:\MUTSW', 'C:\MUTSW_SE')
$script:BackupParent = 'C:\MUT-Install\upgrade-backups'
$script:Utf8 = New-Object Text.UTF8Encoding($true)
$script:ExpectedDatabases = @{
    MUT3 = @('MUTDAG','MUTIDEB','MUTIDEC','MUTIDECNB','MUTIDECNC','MUTIDECNE',
        'MUTIDECNF','MUTIDECNG','MUTIDECNH','MUTIDECNI','MUTIDECNJ','MUTIDECNK',
        'MUTIDECNL','MUTIDECNN','MUTIDECNR','MUTIDECNS','MUTIDECNT','MUTIDECNV',
        'MUTIDECNW','MUTIDECNY','MUTIDEE','MUTIDEF','MUTIDEG','MUTIDEH','MUTIDEI',
        'MUTIDEJ','MUTIDEK','MUTIDEL','MUTIDEN','MUTIDER','MUTIDES','MUTIDET',
        'MUTIDEV','MUTIDEW','MUTIDEY','MUTMCB','MUTMCN','MUTNSAD','MUTOEMS',
        'MUTPRO','MUTPROCN','MUTSYS')
    CAESARCOMPDB = @('CAESARCOMPDB2', 'CFFDB')
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$AllowMissing)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(3).Contains(':')) {
        throw ('Only ordinary local drive paths are accepted: ' + $Path)
    }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse point refused: ' + $current)
            }
        } elseif (!$AllowMissing) {
            throw ('Required path is missing: ' + $current)
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if (!$parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $full
}

function Assert-MutIdle {
    $busy = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and (
            $_.Name -match '^(MUT3Check|MUT3INSTALL|MUT3UNINSTALL|MT3NSTLL|MT3NNSTLL|MUT3_SE|MUT3_Launcher|iexplore|setup|setup100|scenarioengine|DPInst)\.exe$' -or
            ($_.ExecutablePath -and $_.ExecutablePath -match '(?i)^C:\\MUTSW(?:_SE)?\\') -or
            ($_.Name -in @('wscript.exe','cscript.exe') -and $_.CommandLine -match '(?i)MUTSW|MUT3|SEW\d+') -or
            ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -match '(?i)\\(UNINST|DEL_SE|MUT3_Install)\.bat\b') -or
            ($_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\(Remove-FailedMutSqlInstances|Start-MutInstallWithSqlAcl|Repair-MutSqlLegacyAcl|Repair-MutPrerequisites|loadGAC)\.ps1(?:"|\s|$)')
        )
    } | Select-Object Name, ProcessId)
    if ($busy.Count) {
        throw ('Close MUT, Internet Explorer, and installer/repair processes first. Nothing was stopped: ' +
            (($busy | ForEach-Object { $_.Name + ' (PID ' + $_.ProcessId + ')' }) -join ', '))
    }
}

function Get-SafeTree {
    param([string]$Root)
    $null = Assert-NoReparsePath $Root
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    while ($pending.Count) {
        $directory = $pending.Pop()
        $null = Assert-NoReparsePath $directory
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse point refused: ' + $item.FullName)
            }
            if (!$item.FullName.StartsWith($Root.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A source enumeration escaped its fixed root.'
            }
            $entries.Add([pscustomobject]@{
                Path = $item.FullName
                RelativePath = $item.FullName.Substring($Root.Length).TrimStart('\')
                Directory = [bool]$item.PSIsContainer
                Length = $(if ($item.PSIsContainer) { 0L } else { [long]$item.Length })
                LastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
                Attributes = [int]$item.Attributes
            })
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    return @($entries.ToArray() | Sort-Object RelativePath)
}

function Open-MutSqlConnection {
    param([ValidateSet('MUT3','CAESARCOMPDB')][string]$Instance)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = 'lpc:.\' + $Instance
    $builder['Initial Catalog'] = 'master'
    $builder['Integrated Security'] = $true
    $builder['Connect Timeout'] = 10
    $builder['Pooling'] = $false
    $builder['Application Name'] = 'MUT reviewed upgrade backup'
    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    try { $connection.Open(); return $connection } catch { $connection.Dispose(); throw }
}

function Read-SqlTable {
    param($Connection, [string]$Text)
    $command = $Connection.CreateCommand()
    try {
        $command.CommandTimeout = 30
        $command.CommandText = $Text
        $table = New-Object Data.DataTable
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $table.Rows) {
            $values = [ordered]@{}
            foreach ($column in $table.Columns) {
                $values[$column.ColumnName] = $(if ($row.IsNull($column)) { $null } else { $row[$column] })
            }
            $rows.Add([pscustomobject]$values)
        }
        return $rows.ToArray()
    } finally { $command.Dispose() }
}

function Read-SetupField {
    param([string]$Text, [string]$Name)
    $match = [regex]::Match($Text, '(?im)^[ \t]*'+[regex]::Escape($Name)+'[ \t]*[=:][ \t]*"?([^"\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

function Assert-ReviewedSqlSource {
    param([string]$Instance)
    $root = 'C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log'
    $null = Assert-NoReparsePath $root
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
        $_.Name -match '^\d{8}_\d{6}$'
    } | Sort-Object Name -Descending)) {
        $null = Assert-NoReparsePath $folder.FullName
        $summaries = @(Get-ChildItem -LiteralPath $folder.FullName -Filter 'Summary*.txt' -File)
        $text = ($summaries | ForEach-Object {
            $null = Assert-NoReparsePath $_.FullName
            [IO.File]::ReadAllText($_.FullName)
        }) -join "`n"
        if ((Read-SetupField $text 'INSTANCENAME') -ine $Instance) { continue }
        if ((Read-SetupField $text 'ACTION') -ine 'Install' -or
            (Read-SetupField $text 'FEATURES') -ine 'SQLENGINE' -or
            ((Read-SetupField $text 'SQLSVCACCOUNT') -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or
            $text -notmatch '(?im)^\s*Final result:\s*Passed\s*$') {
            throw ($Instance + ' latest setup evidence is not the reviewed successful SQL installation.')
        }
        $detailPath = Join-Path $folder.FullName 'Detail.txt'
        $null = Assert-NoReparsePath $detailPath
        $detail = [IO.File]::ReadAllText($detailPath)
        $folders = $(if ($Instance -eq 'MUT3') { @('MUT3DIAG_V') } else { @('NEWDBIN_V','NEWDBIN0_V') })
        $package = 'en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935'
        $matched = @($folders | Where-Object {
            $detail.IndexOf(('C:\MUT-Install\SEW25091\INSTALL\'+$_+'\'+$package+'\x86\setup\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if (!$matched.Count -or $detail -notmatch '(?i)Feature\s*=\s*SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32\b') {
            throw ($Instance + ' SQL setup source or architecture is not the reviewed SEW25091 media.')
        }
        return [pscustomobject]@{ Directory=$folder.FullName; Action='Install'; Result='Passed'; Media='SEW25091'; Architecture='x86' }
    }
    throw ($Instance + ' has no reviewed successful installation source evidence.')
}

function Get-ExpectedSqlPath {
    param([string]$Instance, [string]$Database, [string]$Type)
    if ($Type -notin @('ROWS','LOG')) { throw 'FILESTREAM or unknown SQL file types are outside the reviewed scope.' }
    if ($Database -in @('master','model','msdb','tempdb')) {
        $names = @{master=@('master.mdf','mastlog.ldf');model=@('model.mdf','modellog.ldf');msdb=@('MSDBData.mdf','MSDBLog.ldf');tempdb=@('tempdb.mdf','templog.ldf')}
        return ('C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL\DATA\'+$names[$Database][$(if ($Type -eq 'ROWS') { 0 } else { 1 })])
    }
    if ($Database -notin $script:ExpectedDatabases[$Instance]) { throw ('Unknown database refused: '+$Instance+'/'+$Database) }
    $suffix = $(if ($Type -eq 'ROWS') { '_data.mdf' } else { '_log.ldf' })
    if ($Instance -eq 'CAESARCOMPDB') { return ('C:\MUTSW\MUT3\CAESARCOMPDB\'+$Database+$suffix) }
    if ($Database -eq 'MUTMCB') { return ('C:\MUTSW\MUT3\CANBUSDB\'+$Database+$suffix) }
    $subdirectory = $(if ($Database -match '^MUTIDECN' -or $Database -in @('MUTMCN','MUTPROCN')) { 'CANDB' } else { 'DIAGDB' })
    $suffix = $(if ($Type -eq 'ROWS') { '.MDF' } else { '_LOG.LDF' })
    return ('C:\MUTSW\MUT3\'+$subdirectory+'\'+$Database+$suffix)
}

function Get-ReviewedInstance {
    param([string]$Instance)
    $expectedRoot = 'C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL'
    $service = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -eq ('MSSQL$'+$Instance) })
    if ($service.Count -ne 1 -or $service[0].State -ne 'Running' -or $service[0].StartMode -ne 'Auto' -or
        ($service[0].StartName -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or
        $service[0].PathName -ine ('"'+$expectedRoot+'\Binn\sqlservr.exe" -s'+$Instance)) {
        throw ($Instance + ' service path, account, state, or start mode differs from the reviewed installation.')
    }
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        $mapping = $null; $setup = $null
        try {
            $mapping = $base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL')
            $setup = $base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.'+$Instance+'\Setup')
            $mapped = $(if ($mapping) { $mapping.GetValue($Instance) } else { $null })
            if ($view -eq [Microsoft.Win32.RegistryView]::Registry64) {
                if ($setup -or $mapped) { throw ($Instance+' has an unexpected native registry identity.') }
            } elseif (!$setup -or $mapped -ine ('MSSQL12.'+$Instance) -or
                $setup.GetValue('SQLPath') -ine $expectedRoot -or $setup.GetValue('SQLBinRoot') -ine ($expectedRoot+'\Binn') -or
                $setup.GetValue('SQLDataRoot') -ine $expectedRoot -or $setup.GetValue('Version') -cne '12.1.4100.1' -or
                $setup.GetValue('PatchLevel') -cne '12.1.4100.1' -or $setup.GetValue('Edition') -cne 'Express Edition') {
                throw ($Instance+' registry version, edition, mapping, or paths differ from the reviewed x86 installation.')
            }
        } finally { if ($mapping) {$mapping.Dispose()}; if ($setup) {$setup.Dispose()}; $base.Dispose() }
    }
    $exe = Join-Path $expectedRoot 'Binn\sqlservr.exe'
    $null = Assert-NoReparsePath $exe
    $version = (Get-Item -LiteralPath $exe).VersionInfo
    if ($version.ProductVersion -cne '12.0.4100.1' -or $version.CompanyName -cne 'Microsoft Corporation') {
        throw ($Instance+' SQL engine binary is not the reviewed Microsoft SQL Server 2014 SP1 version.')
    }
    $source = Assert-ReviewedSqlSource $Instance
    $backupDirectory = Join-Path $expectedRoot 'Backup'
    $null = Assert-NoReparsePath $backupDirectory
    $connection = Open-MutSqlConnection $Instance
    try {
        $server = @(Read-SqlTable $connection "SELECT CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')) AS InstanceName, CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS ProductVersion, CONVERT(nvarchar(128),SERVERPROPERTY('ProductLevel')) AS ProductLevel, CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) AS Edition, CONVERT(nvarchar(4000),@@VERSION) AS VersionText, IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin;")
        if ($server.Count -ne 1 -or $server[0].InstanceName -cne $Instance -or $server[0].ProductVersion -cne '12.0.4100.1' -or
            $server[0].ProductLevel -cne 'SP1' -or $server[0].Edition -notmatch '^Express Edition' -or
            $server[0].VersionText -notmatch 'Intel X86' -or $server[0].IsSysadmin -ne 1) {
            throw ($Instance+' connected server identity/version/permissions differ from the reviewed instance.')
        }
        $databases = @(Read-SqlTable $connection 'SELECT name, database_id, state_desc, user_access_desc, is_read_only, HAS_DBACCESS(name) AS HasAccess FROM sys.databases ORDER BY name;')
        $expected = @('master','model','msdb','tempdb') + $script:ExpectedDatabases[$Instance]
        if ($databases.Count -ne $expected.Count -or @(Compare-Object ($expected | Sort-Object) ($databases.name | Sort-Object)).Count) {
            throw ($Instance+' database list differs from the reviewed installation; unknown or missing databases are refused.')
        }
        if (@($databases | Where-Object { $_.state_desc -ne 'ONLINE' -or $_.user_access_desc -ne 'MULTI_USER' -or $_.HasAccess -ne 1 }).Count) {
            throw ($Instance+' contains a database that is not ONLINE, accessible, and MULTI_USER.')
        }
        $files = @(Read-SqlTable $connection 'SELECT DB_NAME(database_id) AS DatabaseName, database_id, file_id, type_desc, physical_name, CONVERT(bigint,size)*8192 AS Bytes FROM sys.master_files ORDER BY database_id,file_id;')
        if ($files.Count -ne 2*$expected.Count) { throw ($Instance+' has an unexpected SQL file count.') }
        foreach ($database in $expected) {
            $dbFiles = @($files | Where-Object { $_.DatabaseName -ceq $database })
            if ($dbFiles.Count -ne 2 -or @($dbFiles | Where-Object {$_.type_desc -eq 'ROWS'}).Count -ne 1 -or
                @($dbFiles | Where-Object {$_.type_desc -eq 'LOG'}).Count -ne 1) { throw ('Unexpected file layout: '+$Instance+'/'+$database) }
            foreach ($file in $dbFiles) {
                if ($file.physical_name -ine (Get-ExpectedSqlPath $Instance $database $file.type_desc)) { throw ('Unknown SQL file path: '+$file.physical_name) }
                $null = Assert-NoReparsePath $file.physical_name
            }
        }
        return [pscustomobject]@{Instance=$Instance;Service=($service[0] | Select-Object Name,State,StartMode,StartName,PathName);Server=$server[0];SetupSource=$source;BackupDirectory=$backupDirectory;Databases=$databases;Files=$files}
    } finally { $connection.Dispose() }
}

function Get-Preflight {
    Assert-MutIdle
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000 -or
        @(Get-CimInstance Win32_Processor | Where-Object {$_.Architecture -ne 9}).Count) { throw 'This helper supports only Windows 11 x64.' }
    foreach ($root in $script:SourceRoots) { $null = Assert-NoReparsePath $root }
    $null = Assert-NoReparsePath $script:BackupParent -AllowMissing
    $classic = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\MMC\Mut3\MUT\APP\00'
    if ($classic.TYPE -cne 'PRG23061-03') { throw 'Only installed classic version PRG23061-03 can be backed up by this helper.' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $null = Assert-NoReparsePath 'C:\MUTSW_SE\MUT3_SE\System\Version.xml'
    $reader = [Xml.XmlReader]::Create('C:\MUTSW_SE\MUT3_SE\System\Version.xml',$settings)
    try { $xml = New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.Load($reader) } finally { $reader.Dispose() }
    if ([string]$xml.VERSION_DEFINE.VERSION -cne 'SEW25091-00') { throw 'Only installed SEW25091-00 can be backed up by this helper.' }
    $instances = @((Get-ReviewedInstance 'MUT3'), (Get-ReviewedInstance 'CAESARCOMPDB'))
    $knownSqlFiles = @($instances | ForEach-Object {$_.Files} | Where-Object {$_.database_id -gt 4} | ForEach-Object {$_.physical_name})
    $trees = @($script:SourceRoots | ForEach-Object {[pscustomobject]@{Root=$_;Entries=@(Get-SafeTree $_)}})
    $foundSqlFiles = @($trees | ForEach-Object {$_.Entries} | Where-Object {!$_.Directory -and [IO.Path]::GetExtension($_.Path) -in @('.mdf','.ndf','.ldf')} | ForEach-Object {$_.Path})
    if (@(Compare-Object ($knownSqlFiles | Sort-Object) ($foundSqlFiles | Sort-Object)).Count) { throw 'A source tree contains unknown database files or is missing a reviewed SQL file.' }
    $fileBytes = [long](($trees | ForEach-Object {$_.Entries} | Where-Object {!$_.Directory} | Measure-Object Length -Sum).Sum)
    $sqlBytes = [long](($instances | ForEach-Object {$_.Files} | Where-Object {$_.database_id -gt 4} | Measure-Object Bytes -Sum).Sum)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($disk.FreeSpace -lt ($fileBytes+4*$sqlBytes+1GB)) { throw 'Insufficient C: free space for both SQL staging backups and the verified private copy.' }
    Assert-MutIdle
    return [pscustomobject]@{
        Machine=$env:COMPUTERNAME;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Windows=($os | Select-Object Caption,Version,BuildNumber,LastBootUpTime)
        PowerShellVersion=$PSVersionTable.PSVersion.ToString();ClassicVersion='PRG23061-03';SeVersion='SEW25091-00'
        Instances=$instances;Trees=$trees;SourceBytes=$fileBytes;SqlAllocatedBytes=$sqlBytes;FreeBytes=[long]$disk.FreeSpace
    }
}

function Save-BackupManifest {
    $script:Manifest.Stage = $script:Stage
    $script:Manifest.UpdatedUtc = [datetime]::UtcNow.ToString('o')
    $path = Join-Path $script:RunRoot 'manifest.json'
    $temporary = Join-Path $script:RunRoot ('manifest-'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($temporary,($script:Manifest | ConvertTo-Json -Depth 12),$script:Utf8)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary,$path,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$path) }
}

function Copy-VerifiedFile {
    param([string]$Source, [string]$Destination)
    $null = Assert-NoReparsePath $Source
    $null = Assert-NoReparsePath $Destination -AllowMissing
    $parent = Split-Path -Parent $Destination
    [void][IO.Directory]::CreateDirectory($parent)
    $inputStream = [IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $outputStream = $null
    try {
        $outputStream = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
        $outputStream.Dispose(); $outputStream=$null
        $inputStream.Position=0
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $sourceHash=[BitConverter]::ToString($sha.ComputeHash($inputStream)).Replace('-','') } finally {$sha.Dispose()}
        $destinationHash=(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($sourceHash -cne $destinationHash -or (Get-Item -LiteralPath $Destination).Length -ne $inputStream.Length) { throw ('Copy verification failed: '+$Source) }
        $sourceItem=Get-Item -LiteralPath $Source -Force
        [IO.File]::SetLastWriteTimeUtc($Destination,$sourceItem.LastWriteTimeUtc)
        return [pscustomobject]@{Source=$Source;Backup=$Destination;Length=$inputStream.Length;Sha256=$sourceHash;SourceLastWriteUtc=$sourceItem.LastWriteTimeUtc.ToString('o');SourceAttributes=[int]$sourceItem.Attributes}
    } finally {if($outputStream){$outputStream.Dispose()};$inputStream.Dispose()}
}

function Invoke-DatabaseBackup {
    param($Instance, [string]$Database, [string]$RunId)
    Assert-MutIdle
    if ($Database -notin $script:ExpectedDatabases[$Instance.Instance]) {throw 'Refusing an unreviewed database identifier.'}
    $stagePath=Join-Path $Instance.BackupDirectory ('MUTUpgrade-'+$RunId+'-'+$Database+'.bak')
    $null=Assert-NoReparsePath $stagePath -AllowMissing
    if(Test-Path -LiteralPath $stagePath){throw 'The unique SQL backup filename already exists.'}
    $connection=Open-MutSqlConnection $Instance.Instance
    try {
        $command=$connection.CreateCommand()
        try {
            $command.CommandTimeout=900
            $command.CommandText='BACKUP DATABASE ['+$Database.Replace(']',']]')+'] TO DISK=@path WITH COPY_ONLY, CHECKSUM, NO_COMPRESSION, STOP_ON_ERROR;'
            [void]$command.Parameters.Add('@path',[Data.SqlDbType]::NVarChar,4000)
            $command.Parameters['@path'].Value=$stagePath
            [void]$command.ExecuteNonQuery()
            $command.CommandText='RESTORE VERIFYONLY FROM DISK=@path WITH CHECKSUM, STOP_ON_ERROR;'
            [void]$command.ExecuteNonQuery()
            $command.CommandText='RESTORE HEADERONLY FROM DISK=@path;'
            $table=New-Object Data.DataTable
            $reader=$command.ExecuteReader()
            try{$table.Load($reader)}finally{$reader.Dispose()}
            if($table.Rows.Count -ne 1 -or $table.Rows[0].DatabaseName -cne $Database -or
                $table.Rows[0].BackupType -ne 1 -or !$table.Rows[0].IsCopyOnly -or !$table.Rows[0].HasBackupChecksums){throw 'SQL backup header verification failed.'}
        } finally {$command.Dispose()}
    } finally {$connection.Dispose()}
    $copy=Copy-VerifiedFile $stagePath (Join-Path $script:RunRoot ('sql\'+$Instance.Instance+'\'+$Database+'.bak'))
    return [pscustomobject]@{Instance=$Instance.Instance;Database=$Database;Verified=$true;CopyOnly=$true;Checksums=$true;StagingPreserved=$true;File=$copy}
}

function Save-MetadataFiles {
    $records=New-Object 'System.Collections.Generic.List[object]'
    foreach($path in @('C:\MUTSW\InstLog.txt','C:\MUT-Install\oneclick-state.json')) {
        if(Test-Path -LiteralPath $path){$records.Add((Copy-VerifiedFile $path (Join-Path $script:RunRoot ('metadata\'+[IO.Path]::GetFileName($path)))))}
        elseif($path -like '*InstLog.txt'){throw 'The original installation log is missing.'}
    }
    $desktop=[Environment]::GetFolderPath('CommonDesktopDirectory')
    foreach($name in @('M.U.T.-3.lnk','M.U.T.-3_SE.lnk')) {
        $records.Add((Copy-VerifiedFile (Join-Path $desktop $name) (Join-Path $script:RunRoot ('metadata\desktop\'+$name))))
    }
    $exports=@(
        @{Key='HKLM\SOFTWARE\WOW6432Node\MMC';Provider='HKLM:\SOFTWARE\WOW6432Node\MMC';Name='MMC-HKLM-32.reg';Required=$true},
        @{Key='HKLM\SOFTWARE\MMC';Provider='HKLM:\SOFTWARE\MMC';Name='MMC-HKLM-64.reg';Required=$false},
        @{Key='HKCU\SOFTWARE\MMC';Provider='HKCU:\SOFTWARE\MMC';Name='MMC-HKCU.reg';Required=$false}
    )
    foreach($export in $exports){
        if(Test-Path -LiteralPath $export.Provider){
            $path=Join-Path $script:RunRoot ('metadata\'+$export.Name)
            & (Join-Path $env:SystemRoot 'System32\reg.exe') export $export.Key $path /y | Out-Null
            if($LASTEXITCODE -ne 0){throw ('Registry export failed: '+$export.Key)}
            $records.Add([pscustomobject]@{RegistryKey=$export.Key;Backup=$path;Length=(Get-Item -LiteralPath $path).Length;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash})
        }elseif($export.Required){throw ('Required registry key is missing: '+$export.Key)}
    }
    return $records.ToArray()
}

$mutex=$null; $acquired=$false; $exitCode=1
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1 -or ![Environment]::Is64BitProcess){throw 'Use native 64-bit Windows PowerShell 5.1.'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as administrator. This helper does not request UAC itself.'}
    $mutex=New-Object Threading.Mutex($false,'Global\MUT-ReviewedUpgradeBackup')
    try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(!$acquired){throw 'Another upgrade backup is active.'}
    $preflight=Get-Preflight
    if($InspectOnly){
        [pscustomobject]@{Status='InspectionPassed';ClassicVersion=$preflight.ClassicVersion;SeVersion=$preflight.SeVersion;UserDatabaseCount=44;SourceRoots=$script:SourceRoots;SourceBytes=$preflight.SourceBytes;SqlAllocatedBytes=$preflight.SqlAllocatedBytes;FreeBytes=$preflight.FreeBytes;FilesWritten=$false;SqlBackupsCreated=$false} | ConvertTo-Json -Depth 4
        $exitCode=0
    }else{
        $runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')
        $script:RunRoot=Join-Path $script:BackupParent $runId
        $null=Assert-NoReparsePath $script:RunRoot -AllowMissing
        if(Test-Path -LiteralPath $script:RunRoot){throw 'The unique private backup directory already exists.'}
        [void][IO.Directory]::CreateDirectory($script:RunRoot)
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){
            $identity=New-Object Security.Principal.SecurityIdentifier($sid)
            $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $script:RunRoot -AclObject $acl
        $script:Manifest=[ordered]@{SchemaVersion=1;Status='Incomplete';StartedUtc=[datetime]::UtcNow.ToString('o');UpdatedUtc=$null;CompletedUtc=$null;Stage=$script:Stage;RunId=$runId;BackupRoot=$script:RunRoot;Machine=$preflight.Machine;UserSid=$preflight.UserSid;Windows=$preflight.Windows;PowerShellVersion=$preflight.PowerShellVersion;ClassicVersion=$preflight.ClassicVersion;SeVersion=$preflight.SeVersion;Instances=$preflight.Instances;SqlBackups=@();Files=@();Directories=@();Metadata=@();ExcludedDatabaseFiles=@();Error=$null;Limitations=@('No actual database restore or DBCC integrity test was performed.','This preserves application files and 44 user databases, not a complete Windows image or SQL system database backup.','SQL backup staging files are intentionally retained.','No files are automatically restored into a newer application version.')}
        Save-BackupManifest
        $script:Stage='SQL backup and verification'
        foreach($instance in $preflight.Instances){
            foreach($database in $script:ExpectedDatabases[$instance.Instance]){
                Write-Host ('Backing up '+$instance.Instance+'/'+$database)
                $script:Manifest.SqlBackups+=Invoke-DatabaseBackup $instance $database $runId
                Save-BackupManifest
            }
        }
        $script:Stage='File backup and SHA-256 comparison'
        $fileRecords=New-Object 'System.Collections.Generic.List[object]'
        $directoryRecords=New-Object 'System.Collections.Generic.List[object]'
        $excluded=New-Object 'System.Collections.Generic.List[string]'
        foreach($tree in $preflight.Trees){
            Assert-MutIdle
            $destinationRoot=Join-Path $script:RunRoot ('files\'+[IO.Path]::GetFileName($tree.Root))
            [void][IO.Directory]::CreateDirectory($destinationRoot)
            foreach($entry in $tree.Entries){
                $destination=Join-Path $destinationRoot $entry.RelativePath
                if($entry.Directory){[void][IO.Directory]::CreateDirectory($destination);$directoryRecords.Add([pscustomobject]@{Source=$entry.Path;Backup=$destination});continue}
                if([IO.Path]::GetExtension($entry.Path) -in @('.mdf','.ndf','.ldf')){$excluded.Add($entry.Path);continue}
                $fileRecords.Add((Copy-VerifiedFile $entry.Path $destination))
            }
        }
        $script:Manifest.Files=$fileRecords.ToArray()
        $script:Manifest.Directories=$directoryRecords.ToArray()
        $script:Manifest.ExcludedDatabaseFiles=$excluded.ToArray()
        Save-BackupManifest
        $script:Stage='Metadata backup'
        $script:Manifest.Metadata=@(Save-MetadataFiles)
        Save-BackupManifest
        $script:Stage='Final source stability and backup verification'
        Assert-MutIdle
        foreach($tree in $preflight.Trees){
            $current=@(Get-SafeTree $tree.Root)
            $before=@($tree.Entries | ForEach-Object {$_.RelativePath+'|'+$_.Directory})
            $after=@($current | ForEach-Object {$_.RelativePath+'|'+$_.Directory})
            if(@(Compare-Object $before $after).Count){throw ('Source tree changed during backup: '+$tree.Root)}
        }
        foreach($file in $script:Manifest.Files){
            $null=Assert-NoReparsePath $file.Source
            if((Get-FileHash -LiteralPath $file.Source -Algorithm SHA256).Hash -cne $file.Sha256 -or
                (Get-FileHash -LiteralPath $file.Backup -Algorithm SHA256).Hash -cne $file.Sha256){throw ('Source or backup changed during backup: '+$file.Source)}
        }
        foreach($instance in $preflight.Instances){
            $current=Get-ReviewedInstance $instance.Instance
            if(@(Compare-Object ($instance.Files.physical_name | Sort-Object) ($current.Files.physical_name | Sort-Object)).Count){throw 'SQL file mapping changed during backup.'}
        }
        if($script:Manifest.SqlBackups.Count -ne 44 -or @($script:Manifest.SqlBackups | Where-Object {!$_.Verified}).Count){throw 'Not all 44 SQL backups passed verification.'}
        foreach($backup in $script:Manifest.SqlBackups){
            if((Get-FileHash -LiteralPath $backup.File.Backup -Algorithm SHA256).Hash -cne $backup.File.Sha256){throw 'A copied SQL backup changed after verification.'}
        }
        foreach($metadata in $script:Manifest.Metadata){
            if((Get-FileHash -LiteralPath $metadata.Backup -Algorithm SHA256).Hash -cne $metadata.Sha256){throw 'A metadata backup changed after verification.'}
        }
        Assert-MutIdle
        $script:Stage='Complete'
        $script:Manifest.Status='Complete'
        $script:Manifest.CompletedUtc=[datetime]::UtcNow.ToString('o')
        Save-BackupManifest
        [pscustomobject]@{Status='Complete';BackupRoot=$script:RunRoot;Manifest=(Join-Path $script:RunRoot 'manifest.json');VerifiedUserDatabases=44;VerifiedFiles=$fileRecords.Count;SqlStagingBackupsRetained=$true} | ConvertTo-Json -Depth 4
        $exitCode=0
    }
}catch{
    $message=$_.Exception.Message
    if($script:Manifest){
        $script:Manifest.Status='Incomplete'
        $script:Manifest.Error=$message
        try{Save-BackupManifest}catch{Write-Warning ('Could not save the incomplete manifest: '+$_.Exception.Message)}
    }
    [pscustomobject]@{Status='Failed';Stage=$script:Stage;Message=$message;BackupRoot=$script:RunRoot;ExistingFilesPreserved=$true} | ConvertTo-Json -Depth 4
    $exitCode=1
}finally{
    if($acquired -and $mutex){$mutex.ReleaseMutex()}
    if($mutex){$mutex.Dispose()}
}
exit $exitCode
