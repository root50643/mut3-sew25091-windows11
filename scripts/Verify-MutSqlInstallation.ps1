# Private evidence helper. Run only after the original installer has finished.
# It queries local SQL metadata using Windows authentication and writes evidence.
# It does not start services, attach databases, change SQL settings, or repair files.
[CmdletBinding()]
param(
    [ValidateSet('BeforeReboot', 'AfterReboot', 'Manual')]
    [string]$Phase = 'Manual',
    [ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW25091'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: the two original SQL configurations grant sysadmin to BUILTIN\ADMINISTRATORS.'
}

$startedAt = [DateTimeOffset]::Now
$evidenceDirectory = Join-Path 'C:\MUT-Install\verification-logs' (
    '{0}-{1}' -f $startedAt.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
)
[void][IO.Directory]::CreateDirectory($evidenceDirectory)
$findings = New-Object 'System.Collections.Generic.List[string]'
$report = [ordered]@{
    SchemaVersion = 1
    Phase = $Phase
    Release = $Release
    StartedAt = $startedAt.ToString('o')
    CompletedAt = $null
    EvidenceDirectory = $evidenceDirectory
    Status = 'Collecting'
    Scope = 'Local SQL metadata, services, file presence, and an unchanged copy of InstLog.txt.'
    Limitations = @(
        'This does not prove application launch, data content completeness, or vehicle/VCI operation.',
        'The Phase label is supplied by the caller; compare LastBootUpTime with prior evidence to verify a reboot.',
        'SQL file presence and ONLINE state do not constitute database integrity testing.',
        'Only the three named required databases below are mandatory; all visible database metadata is recorded.'
    )
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    OS = $null
    ActiveInstallerProcesses = @()
    Instances = @()
    RequiredDatabaseFiles = @()
    InstLog = $null
    Findings = @()
}

function Get-FileEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; Length = $null; LastWriteTimeUtc = $null }
    }
    return [pscustomobject]@{
        Path = $item.FullName
        Exists = $true
        Length = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Read-SqlMetadata {
    param([Parameter(Mandatory = $true)][ValidateSet('MUT3', 'CAESARCOMPDB')][string]$InstanceName)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = 'lpc:.\' + $InstanceName
    $builder['Initial Catalog'] = 'master'
    $builder['Integrated Security'] = $true
    $builder['Connect Timeout'] = 5
    $builder['Pooling'] = $false
    $builder['Application Name'] = 'MUT3 read-only installation verification'
    $builder['ConnectRetryCount'] = 0
    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $command = $null
    $reader = $null
    $metadata = [ordered]@{
        DataSource = $builder['Data Source']
        Authentication = 'Integrated Windows authentication'
        Transport = 'Local shared memory (lpc); no protocol fallback'
        ConnectTimeoutSeconds = 5
        QueryTimeoutSeconds = 30
        QuerySucceeded = $false
        Server = $null
        Databases = @()
        Error = $null
    }
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 30
        # Fixed SELECT-only text; no identifiers or credentials are interpolated.
        $command.CommandText = @'
SELECT CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName')) AS InstanceName,
       CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS ProductVersion,
       CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')) AS ProductLevel,
       CONVERT(nvarchar(256), SERVERPROPERTY('Edition')) AS Edition,
       CONVERT(nvarchar(4000), @@VERSION) AS VersionText,
       IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin;
SELECT name AS DatabaseName, state_desc AS State, user_access_desc AS UserAccess,
       is_read_only AS IsReadOnly, HAS_DBACCESS(name) AS HasAccess,
       compatibility_level AS CompatibilityLevel
FROM sys.databases
ORDER BY name;
'@
        $reader = $command.ExecuteReader()
        if (-not $reader.Read()) { throw 'The server metadata result was empty.' }
        $server = [ordered]@{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $server[$reader.GetName($i)] = $(if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) })
        }
        $metadata.Server = [pscustomobject]$server
        if (-not $reader.NextResult()) { throw 'The database metadata result was absent.' }
        $databases = New-Object 'System.Collections.Generic.List[object]'
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = $(if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) })
            }
            $databases.Add([pscustomobject]$row)
        }
        $metadata.Databases = @($databases.ToArray())
        $metadata.QuerySucceeded = $true
    } catch {
        $metadata.Error = $_.Exception.Message
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
    return [pscustomobject]$metadata
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $report.OS = [pscustomobject]@{
        Caption = $os.Caption
        Version = $os.Version
        BuildNumber = $os.BuildNumber
        LastBootUpTime = $os.LastBootUpTime.ToString('o')
        LastBootUpTimeUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    }

    # Names and executable paths only: command lines may contain vendor credentials.
    $installerProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(MUT3Check|MUT3INSTALL|MUT3UNINSTALL|MT3NSTLL|MT3NNSTLL|MUT3_Install|setup|setup100|scenarioengine|DPInst)\.exe$' -and
        ($_.ExecutablePath -match '^C:\\MUT-Install\\(?:SEW25091|SEW26061-00)\\' -or
         $_.ExecutablePath -like '*\Microsoft SQL Server\*' -or
         $_.Name -match '^(MUT3Check|MUT3INSTALL|MUT3UNINSTALL|MT3NSTLL|MT3NNSTLL)\.exe$')
    } | Select-Object Name, ProcessId, ExecutablePath)
    $report.ActiveInstallerProcesses = $installerProcesses
    if ($installerProcesses.Count -gt 0) {
        $findings.Add('An original MUT/SQL installer process is still present; this is an interim snapshot.')
    }

    $allServices = @(Get-CimInstance Win32_Service)
    $instanceReports = New-Object 'System.Collections.Generic.List[object]'
    foreach ($instanceName in @('MUT3', 'CAESARCOMPDB')) {
        $serviceName = 'MSSQL$' + $instanceName
        $service = @($allServices | Where-Object { $_.Name -eq $serviceName })
        $requiredDatabases = $(if ($instanceName -eq 'MUT3') { @('MUTMCB') } else { @('CAESARCOMPDB2', 'CFFDB') })
        $instanceReport = [ordered]@{
            InstanceName = $instanceName
            RequiredDatabases = @($requiredDatabases)
            Service = $null
            Sql = $null
        }
        if ($service.Count -ne 1) {
            $findings.Add('Required SQL service is missing: ' + $serviceName)
        } else {
            $instanceReport.Service = $service[0] | Select-Object Name, State, StartMode, StartName
            if ($service[0].State -ne 'Running') {
                $findings.Add('SQL service is not running: ' + $serviceName + '; no start was attempted.')
            } else {
                $sql = Read-SqlMetadata -InstanceName $instanceName
                $instanceReport.Sql = $sql
                if (-not $sql.QuerySucceeded) {
                    $findings.Add('Read-only SQL metadata query failed for ' + $instanceName)
                } else {
                    if ($sql.Server.InstanceName -ne $instanceName) {
                        $findings.Add('Connected instance identity does not match ' + $instanceName)
                    }
                    if ($sql.Server.IsSysadmin -ne 1) {
                        $findings.Add('The query login is not sysadmin; complete database visibility is not proven for ' + $instanceName)
                    }
                    foreach ($database in $sql.Databases) {
                        if ($database.State -ne 'ONLINE' -or $database.HasAccess -ne 1) {
                            $findings.Add('Database is not ONLINE or accessible: ' + $instanceName + '/' + $database.DatabaseName)
                        }
                    }
                    foreach ($required in $requiredDatabases) {
                        if (@($sql.Databases | Where-Object { $_.DatabaseName -eq $required }).Count -ne 1) {
                            $findings.Add('Required database is missing from metadata: ' + $instanceName + '/' + $required)
                        }
                    }
                }
            }
        }
        $instanceReports.Add([pscustomobject]$instanceReport)
    }
    $report.Instances = @($instanceReports.ToArray())

    $fileReports = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @(
        'C:\MUTSW\MUT3\CANBUSDB\MUTMCB_data.mdf',
        'C:\MUTSW\MUT3\CANBUSDB\MUTMCB_log.ldf',
        'C:\MUTSW\MUT3\CAESARCOMPDB\CAESARCOMPDB2_data.mdf',
        'C:\MUTSW\MUT3\CAESARCOMPDB\CAESARCOMPDB2_log.ldf',
        'C:\MUTSW\MUT3\CAESARCOMPDB\CFFDB_data.mdf',
        'C:\MUTSW\MUT3\CAESARCOMPDB\CFFDB_log.ldf'
    )) {
        $file = Get-FileEvidence -Path $path
        $fileReports.Add($file)
        if (-not $file.Exists -or $file.Length -le 0) {
            $findings.Add('Required database file is missing or empty: ' + $path)
        }
    }
    $report.RequiredDatabaseFiles = @($fileReports.ToArray())

    $instLogPath = 'C:\MUTSW\InstLog.txt'
    $instLogFile = Get-FileEvidence -Path $instLogPath
    $instLogCopy = $null
    $instLogHash = $null
    if ($instLogFile.Exists) {
        $instLogCopy = Join-Path $evidenceDirectory 'InstLog.txt'
        Copy-Item -LiteralPath $instLogPath -Destination $instLogCopy
        $instLogHash = (Get-FileHash -LiteralPath $instLogCopy -Algorithm SHA256).Hash
    } else {
        $findings.Add('C:\MUTSW\InstLog.txt is absent; original installation completion is not verified.')
    }
    $report.InstLog = [pscustomobject]@{
        File = $instLogFile
        UnchangedCopy = $instLogCopy
        CopySha256 = $instLogHash
        Interpretation = 'Preserved unchanged for human review; file presence is not interpreted as installer success.'
    }
} catch {
    $findings.Add('Evidence collection error: ' + $_.Exception.Message)
} finally {
    $report.CompletedAt = [DateTimeOffset]::Now.ToString('o')
    $report.Findings = @($findings.ToArray())
    $report.Status = $(if ($findings.Count -eq 0) { 'ReadOnlyChecksPassed' } else { 'ReviewRequired' })
    $reportPath = Join-Path $evidenceDirectory 'report.json'
    $json = $report | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($reportPath, $json, (New-Object Text.UTF8Encoding($true)))
    [pscustomobject]@{ Status = $report.Status; ReportPath = $reportPath; FindingCount = $findings.Count } | ConvertTo-Json -Compress
}
if ($findings.Count -gt 0) { exit 2 }
exit 0
