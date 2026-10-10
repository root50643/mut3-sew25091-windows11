[CmdletBinding()]
param([string]$ResultPath, [switch]$CoreOnly)

# These tests use temporary fixtures and injected effects only. They never run
# the installer, prerequisite repair, SQL cleanup, registry writes, or reboot.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run these tests with Windows PowerShell 5.1.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'scripts\Mut-OneClick.Core.psm1'
$mainPath = Join-Path $projectRoot 'scripts\Install-Mut.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mut-oneclick-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:caseNumber = 0

function Assert-True($Actual, [string]$Message = 'Expected true.') {
    if (-not $Actual) { throw $Message }
}
function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    if ($Expected -cne $Actual) {
        throw ('Expected [{0}], actual [{1}]. {2}' -f $Expected, $Actual, $Message)
    }
}
function Assert-Throws([scriptblock]$Action, [string]$Message = 'Expected an exception.') {
    $didThrow = $false
    try { & $Action | Out-Null } catch { $didThrow = $true }
    Assert-True $didThrow $Message
}
function Assert-ReviewError([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception }
    Assert-True ($null -ne $failure) 'Expected a controlled review error.'
    Assert-Equal 2 $failure.Data['MutExitCode']
    Assert-True ($failure.Message -match $Pattern) ('Unexpected review reason: ' + $failure.Message)
}
function Invoke-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}
function New-CaseFolder {
    $script:caseNumber++
    $path = Join-Path $testRoot ('case-{0:000}' -f $script:caseNumber)
    $null = New-Item -ItemType Directory -Path $path
    return $path
}
function New-TestArchive([string]$Path, [object[]]$Entries) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($entryData in $Entries) {
            $entry = $zip.CreateEntry([string]$entryData.Name)
            if ($entryData.Name.EndsWith('/')) { continue }
            $entryStream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$entryData.Text)
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally { $entryStream.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function New-TestFacts([hashtable]$Changes = @{}) {
    $facts = [ordered]@{
        BusyOwned = $false; BusyUnknown = $false; PendingReboot = $false
        Healthy = $false; Unknown = $false; ValidPartial = $false
        RecognizedFailed = $false; Clean = $false
        BootUtc = '2026-10-10T01:00:00.0000000Z'
    }
    foreach ($key in $Changes.Keys) { $facts[$key] = $Changes[$key] }
    return [pscustomobject]$facts
}
function New-LogText([string]$Result, [string]$Time = '2026/10/10 09:59:22') {
    return "--------------`r`n$Time`r`nOS = Windows 10. 64Bit`r`nMUT-3 Ver = PRG23061-03`r`n`r`n$Result`r`n"
}
function Write-Fixture([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}
function Invoke-InventoryFixture([object[]]$Processes) {
    function Get-CimInstance {
        [CmdletBinding()] param([string]$ClassName)
        Assert-Equal 'Win32_Process' $ClassName
        return $Processes
    }
    return @(Get-MutInstallerProcesses)
}
function Invoke-AutoFixture([ValidateSet('Healthy','SameBoot','LaterBoot','OwnedBusy','UnknownBusy','PendingRestart','InstallingUnknown','UnknownRegistry','LegacyFiles','NativeRegistry','WrongClassic','MissingRequired')][string]$Scenario) {
    $script:RunRoot = New-CaseFolder
    $script:StatePath = Join-Path $script:RunRoot 'state.json'
    $script:MediaHash = '1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03'
    $state = [pscustomobject]@{
        SchemaVersion = 1; Machine = $env:COMPUTERNAME; MediaHash = $script:MediaHash
        Phase = 'Completed'; BootUtc = '2026-10-09T02:00:00Z'; ResumePhase = 'AfterInstall'
        UpdatedUtc = '2026-10-09T02:00:00Z'; InstallStartedUtc = '2026-10-09T01:00:00Z'
        InstallCompletedUtc = '2026-10-09T01:59:00Z'; LogBefore = $null; Coordinator = $null; UninstallStartedUtc = ''
        ApplicationConfirmation = [pscustomobject]@{ Classic = $true; SE = $true }
    }
    if ($Scenario -in @('SameBoot','LaterBoot')) { $state.Phase = 'AwaitingReboot' }
    if ($Scenario -eq 'SameBoot') { $state.BootUtc = '2026-10-10T02:00:00Z' }
    if ($Scenario -in @('OwnedBusy','InstallingUnknown')) { $state.Phase = 'Installing' }
    if ($Scenario -eq 'MissingRequired') { $state.PSObject.Properties.Remove('InstallCompletedUtc') }
    Write-MutState -Path $script:StatePath -State $state
    $effects = New-Object 'System.Collections.Generic.List[string]'
    function Get-MutBootUtc { return '2026-10-10T02:00:00Z' }
    function Get-MutInstallerProcesses {
        if ($Scenario -eq 'UnknownBusy') { return [pscustomobject]@{ Name = 'setup.exe'; CreationDate = [datetime]'2026-10-10T01:00:00Z' } }
        if ($Scenario -eq 'OwnedBusy') { return [pscustomobject]@{ Name = 'setup.exe'; CreationDate = [datetime]'2026-10-10T01:00:00Z'; ExecutablePath = 'C:\MUT-Install\SEW25091\INSTALL\setup.exe' } }
        if ($Scenario -eq 'InstallingUnknown') { return [pscustomobject]@{ Name = 'setup.exe'; CreationDate = [datetime]'2026-10-10T01:00:00Z'; ExecutablePath = 'C:\Temp\unknown\setup.exe' } }
        return @()
    }
    function Test-MutPendingRestart { return ($Scenario -eq 'PendingRestart') }
    function Get-Service {
        [CmdletBinding()] param([string[]]$Name)
        if ($Scenario -in @('UnknownRegistry','LegacyFiles','NativeRegistry','WrongClassic')) { return @() }
        return @([pscustomobject]@{ Name = 'MSSQL$MUT3'; Status = 'Running' }, [pscustomobject]@{ Name = 'MSSQL$CAESARCOMPDB'; Status = 'Running' })
    }
    function Test-Path {
        [CmdletBinding()] param([string]$LiteralPath, [string]$PathType)
        if ($LiteralPath.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) { return (Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath) }
        if ($Scenario -eq 'LegacyFiles' -and $LiteralPath -eq (Join-Path $env:ProgramFiles 'MUT3')) { return $true }
        if ($Scenario -eq 'NativeRegistry' -and $LiteralPath -eq 'HKLM:\SOFTWARE\MMC\Mut3') { return $true }
        return $false
    }
    function Get-ItemProperty {
        [CmdletBinding()] param([string]$LiteralPath)
        if ($Scenario -eq 'WrongClassic') { return [pscustomobject]@{ TYPE = 'PRG00000-00' } }
        return $null
    }
    function Get-MutTargetRegistryRemnants {
        if ($Scenario -eq 'UnknownRegistry') { return [pscustomobject]@{ Instance = 'MUT3'; View = 'Registry32' } }
        return @()
    }
    function Test-MutInstalledFiles { return $true }
    function Invoke-MutSqlCheck {
        $effects.Add('verify')
        return [pscustomobject]@{ Passed = $true; Findings = @(); InstLog = [pscustomobject]@{ LastWriteUtc = '2026-10-10T01:00:00Z' } }
    }
    function Save-MutCheckpoint([string]$Phase) { $effects.Add('state:' + $Phase); $script:State.Phase = $Phase }
    function Show-MutNotice { param($Text, $Kind, [switch]$Confirm) }
    function Request-MutRestart { param($ResumePhase, $Reason); $effects.Add('restart:' + $ResumePhase); return 3010 }
    function Wait-MutOriginalInstallation { $effects.Add('monitor'); return 2 }
    function Prepare-MutMedia { throw 'Unexpected preparation/source dependency on a protected route.' }
    function Invoke-MutFailedCleanup { throw 'Unexpected SQL or original-installer cleanup.' }
    function Invoke-MutPrerequisiteStage { throw 'Unexpected prerequisite mutation.' }
    function Start-MutChild { throw 'Unexpected child process.' }
    function Invoke-MutApplicationConfirmation { throw 'Unexpected repeated application confirmation.' }
    $code = Invoke-MutAuto
    return [pscustomobject]@{ Code = $code; Effects = @($effects.ToArray()) }
}

try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Import-Module $corePath -Force -DisableNameChecking

    Invoke-Case 'PowerShell syntax: all published PS1 and PSM1 files' {
        foreach ($source in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors)
            Assert-Equal 0 @($errors).Count $source.Name
        }
    }
    if (-not $CoreOnly) {
        Invoke-Case 'Published helper manifest matches exact bytes' {
            $manifestPath = Join-Path $projectRoot 'scripts\oneclick-helper-hashes.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True (@($manifest.PSObject.Properties).Count -gt 0) 'Manifest must not be empty.'
            foreach ($entry in $manifest.PSObject.Properties) {
                Assert-True ($entry.Name -match '^[A-Za-z0-9.-]+\.(ps1|psm1|cmd)$') 'Unexpected helper path.'
                Assert-Equal $entry.Value (Get-FileHash -LiteralPath (Join-Path $projectRoot ('scripts\' + $entry.Name)) -Algorithm SHA256).Hash $entry.Name
            }
        }
    }

    # Extract only effect-injected function definitions. No top-level statement
    # from Install-Mut.ps1 is executed, even if its LibraryOnly guard regresses.
    if (-not $CoreOnly) {
    $tokens = $null; $errors = $null
    $mainAst = [Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw 'The main script cannot be parsed.' }
    foreach ($functionName in @('Invoke-MutConfirmedCleanup', 'Resolve-MutElevationResult', 'Invoke-MutDispatch', 'Get-MutMonitorDecision', 'Invoke-MutDownload', 'Invoke-MutAuto', 'Stop-MutReview', 'Assert-MutSingleInstance', 'Test-MutClassicIdentity', 'Test-MutRecoveredCompletion', 'Get-MutInstallerProcesses')) {
        $foundFunction = $mainAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        if (-not $foundFunction) { throw ('Missing effect-injected function: ' + $functionName) }
        . ([scriptblock]::Create($foundFunction.Extent.Text))
    }
    $prerequisiteAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\Mut-Prerequisites.psm1'), [ref]$tokens, [ref]$errors)
    $nativeStreamParser = $prerequisiteAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-MutLoaderNativeStream' }, $true)
    if (-not $nativeStreamParser) { throw 'Missing native loader stream parser.' }
    . ([scriptblock]::Create($nativeStreamParser.Extent.Text))
    $removalAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\Remove-FailedMutSqlInstances.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($functionName in @('Assert-ReviewedEngineLogText','Assert-NoUsableDatabaseEvidence')) {
        $foundFunction = $removalAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        if (-not $foundFunction) { throw ('Missing removal preflight guard: ' + $functionName) }
        . ([scriptblock]::Create($foundFunction.Extent.Text))
    }
    $reviewedEngineFailure = "Microsoft SQL Server 2014 - 12.0.4100.1 (Intel X86)`r`nTDSSNIClient initialization failed with error 0x5, status code 0x90. Reason: Unable to configure MDAC-compatibility protocol list in registry. Access is denied.`r`n"

    Invoke-Case 'SQL cleanup preflight recognizes reviewed engine failure only' {
        Assert-ReviewedEngineLogText -text $reviewedEngineFailure -instance 'MUT3'
        Assert-Throws { Assert-ReviewedEngineLogText -text ($reviewedEngineFailure.Replace('12.0.4100.1', '12.0.5000.0')) -instance 'MUT3' }
        Assert-Throws { Assert-ReviewedEngineLogText -text ($reviewedEngineFailure.Replace('0x90', '0x91')) -instance 'MUT3' }
    }
    Invoke-Case 'SQL cleanup preflight refuses a server that reached ready state' {
        Assert-Throws { Assert-ReviewedEngineLogText -text ($reviewedEngineFailure + 'SQL Server is now ready for client connections.') -instance 'MUT3' }
    }
    Invoke-Case 'SQL cleanup preflight refuses user database startup evidence' {
        Assert-Throws { Assert-ReviewedEngineLogText -text ($reviewedEngineFailure + "Starting up database 'MUTMCB'.") -instance 'MUT3' }
        Assert-ReviewedEngineLogText -text ($reviewedEngineFailure + "Starting up database 'master'.") -instance 'MUT3'
    }
    Invoke-Case 'SQL cleanup preflight refuses non-default database files and preserves them' {
        $instanceRoot = New-CaseFolder
        $null = New-Item -ItemType Directory -Path (Join-Path $instanceRoot 'Log'),(Join-Path $instanceRoot 'DATA')
        Write-Fixture (Join-Path $instanceRoot 'Log\ERRORLOG') $reviewedEngineFailure
        $data = Join-Path $instanceRoot 'DATA\customer.mdf'
        Write-Fixture $data 'fixture customer data must remain'
        $before = (Get-FileHash -LiteralPath $data).Hash
        Assert-Throws { Assert-NoUsableDatabaseEvidence -instanceRoot $instanceRoot -instance 'MUT3' }
        Assert-Equal $before (Get-FileHash -LiteralPath $data).Hash
    }
    Invoke-Case 'SQL cleanup preflight refuses missing current engine evidence' {
        $instanceRoot = New-CaseFolder
        Assert-Throws { Assert-NoUsableDatabaseEvidence -instanceRoot $instanceRoot -instance 'MUT3' }
    }
    Invoke-Case 'SQL cleanup preflight accepts a system-only failed-install fixture without changes' {
        $instanceRoot = New-CaseFolder
        $null = New-Item -ItemType Directory -Path (Join-Path $instanceRoot 'Log'),(Join-Path $instanceRoot 'DATA')
        Write-Fixture (Join-Path $instanceRoot 'Log\ERRORLOG') $reviewedEngineFailure
        $data = Join-Path $instanceRoot 'DATA\master.mdf'
        Write-Fixture $data 'fixture system data'
        $before = (Get-FileHash -LiteralPath $data).Hash
        Assert-NoUsableDatabaseEvidence -instanceRoot $instanceRoot -instance 'MUT3'
        Assert-Equal $before (Get-FileHash -LiteralPath $data).Hash
    }

    Invoke-Case 'Traditional Chinese CP950 known reg.exe success output is accepted' {
        $bytes = [Text.Encoding]::GetEncoding(950).GetBytes("操作順利完成。`r`n操作順利完成。`r`n")
        Assert-True (Read-MutLoaderNativeStream -Bytes $bytes).Passed
    }
    Invoke-Case 'English known reg.exe success output is accepted' {
        $bytes = [Text.Encoding]::UTF8.GetBytes("The operation completed successfully.`r`nThe operation completed successfully.`r`n")
        Assert-True (Read-MutLoaderNativeStream -Bytes $bytes).Passed
    }
    Invoke-Case 'Loader success text followed by actual error is rejected' {
        $bytes = [Text.Encoding]::UTF8.GetBytes("The operation completed successfully.`r`nERROR: Access is denied.`r`n")
        Assert-True (-not (Read-MutLoaderNativeStream -Bytes $bytes).Passed)
    }
    Invoke-Case 'Unknown native loader output is not silently accepted' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('unrecognized output')
        Assert-True (-not (Read-MutLoaderNativeStream -Bytes $bytes).Passed)
    }

    Invoke-Case 'Check dispatch never calls the Auto adapter' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        $result = Invoke-MutDispatch -Mode Check -CheckAction { $effects.Add('check'); return 0 } -AutoAction { throw 'Auto was called in Check mode.' }
        Assert-Equal 0 $result
        Assert-Equal 'check' ($effects -join ',')
    }
    Invoke-Case 'Auto dispatch selects only Auto adapter' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        $result = Invoke-MutDispatch -Mode Auto -CheckAction { throw 'Check was called in Auto mode.' } -AutoAction { $effects.Add('auto'); return 2 }
        Assert-Equal 2 $result
        Assert-Equal 'auto' ($effects -join ',')
    }
    Invoke-Case 'UAC cancellation preserves exit code 1223' {
        Assert-Equal 1223 (Resolve-MutElevationResult -NativeErrorCode 1223)
        Assert-Equal 1 (Resolve-MutElevationResult -NativeErrorCode 5)
    }
    Invoke-Case 'Process inventory includes reviewed helper PowerShell but excludes unrelated PowerShell' {
        $processes = @()
        $number = 100
        foreach ($name in @('Repair-MutPrerequisites','Remove-FailedMutSqlInstances','Start-MutInstallWithSqlAcl','Repair-MutSqlLegacyAcl','loadGAC','unrelated-script')) {
            $number++
            $processes += [pscustomobject]@{
                Name = 'powershell.exe'; ProcessId = $number; ParentProcessId = 99
                CreationDate = [datetime]'2026-10-10T01:00:00Z'
                ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                CommandLine = 'powershell.exe -NoProfile -File "C:\測試 空白\' + $name + '.ps1"'
            }
        }
        $found = @(Invoke-InventoryFixture -Processes $processes)
        Assert-Equal 5 $found.Count
        Assert-True ($found.ProcessId -notcontains 106) 'Unrelated PowerShell should not block installation.'
    }
    Invoke-Case 'Process inventory includes temporary-path Setup and driver installers' {
        $processes = @(
            [pscustomobject]@{ Name = 'setup.exe'; ProcessId = 201; ParentProcessId = 99; CreationDate = [datetime]'2026-10-10T01:00:00Z'; ExecutablePath = 'C:\Temp\random\setup.exe'; CommandLine = 'setup.exe' },
            [pscustomobject]@{ Name = 'DPInst.exe'; ProcessId = 202; ParentProcessId = 99; CreationDate = [datetime]'2026-10-10T01:00:00Z'; ExecutablePath = 'C:\Temp\random\DPInst.exe'; CommandLine = 'DPInst.exe' },
            [pscustomobject]@{ Name = 'notepad.exe'; ProcessId = 203; ParentProcessId = 99; CreationDate = [datetime]'2026-10-10T01:00:00Z'; ExecutablePath = 'C:\Windows\notepad.exe'; CommandLine = 'notepad.exe' }
        )
        $found = @(Invoke-InventoryFixture -Processes $processes)
        Assert-Equal 2 $found.Count
        Assert-Equal '201,202' ($found.ProcessId -join ',')
    }
    Invoke-Case 'Duplicate session stops before dispatch or installation effects' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        Assert-ReviewError {
            Assert-MutSingleInstance -TryAcquire { $effects.Add('lock'); return $false }
            $effects.Add('dispatch')
        } '另一個'
        Assert-Equal 'lock' ($effects -join ',')
    }
    Invoke-Case 'Acquired session lock allows dispatch exactly once' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        Assert-MutSingleInstance -TryAcquire { $effects.Add('lock'); return $true }
        $effects.Add('dispatch')
        Assert-Equal 'lock,dispatch' ($effects -join ',')
    }
    Invoke-Case 'Classic current final block and registry agree on reviewed version' {
        Assert-True (Test-MutClassicIdentity -LastBlock "MUT-3 Ver = PRG23061-03`r`n問題なし" -RegistryType 'PRG23061-03')
    }
    Invoke-Case 'Classic registry mismatch is rejected despite matching log' {
        Assert-True (-not (Test-MutClassicIdentity -LastBlock "MUT-3 Ver = PRG23061-03`r`n問題なし" -RegistryType 'PRG99999-00'))
    }
    Invoke-Case 'Historical matching classic version does not override mismatched latest block' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        Write-Fixture $path ((New-LogText '問題なし') + "--------------`r`nMUT-3 Ver = PRG99999-00`r`n問題なし`r`n")
        $evidence = Get-MutInstLogEvidence -Path $path
        Assert-True ($evidence.Content -match 'PRG23061-03')
        Assert-True (-not (Test-MutClassicIdentity -LastBlock $evidence.LastBlock -RegistryType 'PRG23061-03'))
    }
    Invoke-Case 'Recovered completion requires all independent acceptance conditions' {
        Assert-True (Test-MutRecoveredCompletion -FreshLog $true -SqlReady $true -Busy $false -RebootAfterLog $true)
        Assert-True (-not (Test-MutRecoveredCompletion -FreshLog $false -SqlReady $true -Busy $false -RebootAfterLog $true))
        Assert-True (-not (Test-MutRecoveredCompletion -FreshLog $true -SqlReady $false -Busy $false -RebootAfterLog $true))
        Assert-True (-not (Test-MutRecoveredCompletion -FreshLog $true -SqlReady $true -Busy $true -RebootAfterLog $true))
        Assert-True (-not (Test-MutRecoveredCompletion -FreshLog $true -SqlReady $true -Busy $false -RebootAfterLog $false))
    }
    Invoke-Case 'Declined cleanup executes no uninstall or SQL helper' {
        $result = Invoke-MutConfirmedCleanup -Confirm { return $false } -Uninstall { throw 'Uninstall executed.' } -Remove { throw 'SQL cleanup executed.' }
        Assert-Equal 1223 $result
    }
    Invoke-Case 'Original uninstall failure prevents SQL cleanup' {
        $result = Invoke-MutConfirmedCleanup -Confirm { return $true } -Uninstall { return 1 } -Remove { throw 'SQL cleanup executed after failure.' }
        Assert-Equal 1 $result
    }
    Invoke-Case 'Original uninstall restart prevents SQL cleanup until restart' {
        $result = Invoke-MutConfirmedCleanup -Confirm { return $true } -Uninstall { return 3010 } -Remove { throw 'SQL cleanup executed before restart.' }
        Assert-Equal 3010 $result
    }
    Invoke-Case 'Confirmed cleanup preserves order and result' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        $result = Invoke-MutConfirmedCleanup -Confirm { $effects.Add('confirm'); return $true } -Uninstall { $effects.Add('uninstall'); return 0 } -Remove { $effects.Add('remove'); return 3010 }
        Assert-Equal 'confirm,uninstall,remove' ($effects -join ',')
        Assert-Equal 3010 $result
    }
    Invoke-Case 'SQL success alone cannot complete the original install' {
        Assert-Equal 'Waiting' (Get-MutMonitorDecision -FreshLog $false -SqlReady $true -Busy $false -IdleSeconds 10 -ElapsedSeconds 900)
    }
    Invoke-Case 'Fresh final log while vendor remains active cannot complete' {
        Assert-Equal 'Waiting' (Get-MutMonitorDecision -FreshLog $true -SqlReady $true -Busy $true -IdleSeconds 10 -ElapsedSeconds 900)
    }
    Invoke-Case 'Nine idle seconds are not yet completion' {
        Assert-Equal 'Waiting' (Get-MutMonitorDecision -FreshLog $true -SqlReady $true -Busy $false -IdleSeconds 9 -ElapsedSeconds 900)
    }
    Invoke-Case 'Fresh successful log and SQL with ten stable idle seconds complete' {
        Assert-Equal 'Complete' (Get-MutMonitorDecision -FreshLog $true -SqlReady $true -Busy $false -IdleSeconds 10 -ElapsedSeconds 900)
    }
    Invoke-Case 'Full-install deadline stops waiting without success' {
        Assert-Equal 'TimedOut' (Get-MutMonitorDecision -FreshLog $false -SqlReady $true -Busy $true -IdleSeconds 0 -ElapsedSeconds 5400)
    }
    Invoke-Case 'Deadline is not bypassed by a late success sample' {
        Assert-Equal 'TimedOut' (Get-MutMonitorDecision -FreshLog $true -SqlReady $true -Busy $false -IdleSeconds 10 -ElapsedSeconds 5401)
    }
    Invoke-Case 'Download failure never invokes verification or execution' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        Assert-Throws { Invoke-MutDownload -Download { $effects.Add('download'); throw 'Simulated network error.' } -Verify { $effects.Add('verify'); return $true } }
        Assert-Equal 'download' ($effects -join ',')
    }
    Invoke-Case 'Downloaded wrong hash fails before any further action' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        Assert-Throws { Invoke-MutDownload -Download { $effects.Add('download') } -Verify { $effects.Add('verify'); return $false } }
        Assert-Equal 'download,verify' ($effects -join ',')
    }
    Invoke-Case 'Successful download is always verified after download' {
        $effects = New-Object 'System.Collections.Generic.List[string]'
        $null = Invoke-MutDownload -Download { $effects.Add('download') } -Verify { $effects.Add('verify'); return $true }
        Assert-Equal 'download,verify' ($effects -join ',')
    }
    Invoke-Case 'Actual Auto orchestration verifies healthy machine without requiring ZIP or calling mutations' {
        $result = Invoke-AutoFixture -Scenario Healthy
        Assert-Equal 0 $result.Code
        Assert-Equal 'verify,state:Completed' ($result.Effects -join ',')
    }
    Invoke-Case 'Actual Auto with the same boot requests restart without preparation' {
        $result = Invoke-AutoFixture -Scenario SameBoot
        Assert-Equal 3010 $result.Code
        Assert-Equal 'restart:AfterInstall' ($result.Effects -join ',')
    }
    Invoke-Case 'Actual Auto after a later boot verifies and never repeats installation' {
        $result = Invoke-AutoFixture -Scenario LaterBoot
        Assert-Equal 0 $result.Code
        Assert-Equal 'state:AfterInstall,verify,state:Completed' ($result.Effects -join ',')
    }
    Invoke-Case 'Actual Auto reconnects an existing installation to monitor only' {
        $result = Invoke-AutoFixture -Scenario OwnedBusy
        Assert-Equal 2 $result.Code
        Assert-Equal 'monitor' ($result.Effects -join ',')
    }
    Invoke-Case 'Actual Auto refuses unknown active installer without launching helpers' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario UnknownBusy } '正在執行'
    }
    Invoke-Case 'Actual Auto sees pending restart before preparing sources' {
        $result = Invoke-AutoFixture -Scenario PendingRestart
        Assert-Equal 3010 $result.Code
        Assert-Equal 'restart:Completed' ($result.Effects -join ',')
    }
    Invoke-Case 'Actual Auto resume rejects a newer unrelated setup process' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario InstallingUnknown } '來源不明'
    }
    Invoke-Case 'Actual Auto blocks service-less SQL registry residue before media preparation' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario UnknownRegistry } '登錄殘留'
    }
    Invoke-Case 'Actual Auto protects legacy Program Files MUT3 directory' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario LegacyFiles } '舊版資料目錄'
    }
    Invoke-Case 'Actual Auto protects unknown native MMC registration' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario NativeRegistry } '原生登錄'
    }
    Invoke-Case 'Actual Auto protects a different classic version before media preparation' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario WrongClassic } '其他傳統版'
    }
    Invoke-Case 'Actual Auto rejects partial JSON state before verification or installation effects' {
        Assert-ReviewError { Invoke-AutoFixture -Scenario MissingRequired } '缺少欄位 InstallCompletedUtc'
    }
    }

    Invoke-Case 'Healthy machine goes to Verify, never Cleanup or PrepareInstall' {
        Assert-Equal 'Verify' (Get-MutNextAction -Facts (New-TestFacts @{ Healthy = $true }) -State $null)
    }
    Invoke-Case 'Owned running installer resumes Monitor' {
        Assert-Equal 'Monitor' (Get-MutNextAction -Facts (New-TestFacts @{ BusyOwned = $true }) -State $null)
    }
    Invoke-Case 'Unknown running installer requires Review' {
        Assert-Equal 'Review' (Get-MutNextAction -Facts (New-TestFacts @{ BusyUnknown = $true }) -State $null)
    }
    Invoke-Case 'Unknown installer is not ignored when an owned installer also runs' {
        Assert-Equal 'Review' (Get-MutNextAction -Facts (New-TestFacts @{ BusyOwned = $true; BusyUnknown = $true }) -State $null)
    }
    Invoke-Case 'Pending Windows restart stops preparation' {
        Assert-Equal 'Reboot' (Get-MutNextAction -Facts (New-TestFacts @{ PendingReboot = $true; Clean = $true }) -State $null)
    }
    Invoke-Case 'AwaitingReboot with same actual boot stays Reboot' {
        $state = [pscustomobject]@{ SchemaVersion = 1; Phase = 'AwaitingReboot'; BootUtc = '2026-10-10T01:00:00.0000000Z' }
        Assert-Equal 'Reboot' (Get-MutNextAction -Facts (New-TestFacts @{ Clean = $true }) -State $state)
    }
    Invoke-Case 'A real later boot allows clean preparation' {
        $state = [pscustomobject]@{ SchemaVersion = 1; Phase = 'AwaitingReboot'; BootUtc = '2026-10-09T01:00:00.0000000Z' }
        Assert-Equal 'PrepareInstall' (Get-MutNextAction -Facts (New-TestFacts @{ Clean = $true }) -State $state)
    }
    Invoke-Case 'An older boot is not accepted as the requested restart' {
        Assert-True (-not (Test-MutRebootOccurred -PreviousBootUtc '2026-10-10T01:00:00Z' -CurrentBootUtc '2026-10-09T01:00:00Z'))
    }
    Invoke-Case 'Invalid boot timestamp is not accepted as a restart' {
        Assert-True (-not (Test-MutRebootOccurred -PreviousBootUtc 'invalid' -CurrentBootUtc '2026-10-10T01:00:00Z'))
    }
    Invoke-Case 'A later boot on healthy installation verifies without reinstalling' {
        $state = [pscustomobject]@{ SchemaVersion = 1; Phase = 'AwaitingReboot'; BootUtc = '2026-10-09T01:00:00.0000000Z' }
        Assert-Equal 'Verify' (Get-MutNextAction -Facts (New-TestFacts @{ Healthy = $true }) -State $state)
    }
    Invoke-Case 'Unknown residues are never selected for cleanup' {
        Assert-Equal 'Review' (Get-MutNextAction -Facts (New-TestFacts @{ Unknown = $true }) -State $null)
    }
    Invoke-Case 'Valid partial installation is not selected for cleanup' {
        Assert-Equal 'Review' (Get-MutNextAction -Facts (New-TestFacts @{ ValidPartial = $true }) -State $null)
    }
    Invoke-Case 'Only recognized failed installation selects Cleanup' {
        Assert-Equal 'Cleanup' (Get-MutNextAction -Facts (New-TestFacts @{ RecognizedFailed = $true }) -State $null)
    }
    Invoke-Case 'No classified facts defaults to Review' {
        Assert-Equal 'Review' (Get-MutNextAction -Facts (New-TestFacts) -State $null)
    }

    Invoke-Case 'Missing state is not treated as corrupt state' {
        Assert-True ($null -eq (Read-MutState -Path (Join-Path (New-CaseFolder) 'missing.json')))
    }
    Invoke-Case 'Atomic state can be read and replaced in a Unicode path' {
        $folder = Join-Path (New-CaseFolder) '中文 空白'
        $null = New-Item -ItemType Directory -Path $folder
        $path = Join-Path $folder 'state.json'
        Write-MutState -Path $path -State ([pscustomobject]@{ SchemaVersion = 1; Phase = 'Preparing'; Marker = 'first' })
        Assert-Equal 'first' (Read-MutState -Path $path).Marker
        Write-MutState -Path $path -State ([pscustomobject]@{ SchemaVersion = 1; Phase = 'AwaitingReboot'; Marker = 'second' })
        Assert-Equal 'second' (Read-MutState -Path $path).Marker
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $folder -File).Count
    }
    Invoke-Case 'Malformed state is rejected and preserved' {
        $path = Join-Path (New-CaseFolder) 'state.json'
        Write-Fixture $path '{not valid json'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        Assert-Throws { Read-MutState -Path $path }
        Assert-Equal $hash (Get-FileHash -LiteralPath $path).Hash
    }
    Invoke-Case 'Unsupported state schema is rejected' {
        $path = Join-Path (New-CaseFolder) 'state.json'
        Write-Fixture $path '{"SchemaVersion":99,"Phase":"Preparing"}'
        Assert-Throws { Read-MutState -Path $path }
    }
    Invoke-Case 'State missing phase is rejected' {
        $path = Join-Path (New-CaseFolder) 'state.json'
        Write-Fixture $path '{"SchemaVersion":1}'
        Assert-Throws { Read-MutState -Path $path }
    }
    Invoke-Case 'State with invalid boot timestamp is rejected' {
        $path = Join-Path (New-CaseFolder) 'state.json'
        Write-Fixture $path '{"SchemaVersion":1,"Phase":"AwaitingReboot","BootUtc":"invalid"}'
        Assert-Throws { Read-MutState -Path $path }
    }
    Invoke-Case 'Invalid new state does not replace valid state' {
        $path = Join-Path (New-CaseFolder) 'state.json'
        Write-MutState -Path $path -State ([pscustomobject]@{ SchemaVersion = 1; Phase = 'Preparing' })
        $before = (Get-FileHash -LiteralPath $path).Hash
        Assert-Throws { Write-MutState -Path $path -State ([pscustomobject]@{ SchemaVersion = 99; Phase = 'Preparing' }) }
        Assert-Equal $before (Get-FileHash -LiteralPath $path).Hash
    }

    Invoke-Case 'Missing InstLog does not pass installation' {
        $before = Get-MutInstLogEvidence -Path (Join-Path (New-CaseFolder) 'missing.log')
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After $before -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }
    Invoke-Case 'Unchanged old successful InstLog cannot pass a new run' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        Write-Fixture $path (New-LogText '問題なし')
        $before = Get-MutInstLogEvidence -Path $path
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After $before -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }
    Invoke-Case 'Fresh successful final block passes' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path (New-LogText '問題なし')
        Assert-True (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1)))
    }
    Invoke-Case 'New success appended to prior failed block passes' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $old = New-LogText 'Database failed'
        Write-Fixture $path $old
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path ($old + (New-LogText '問題なし' '2026/10/10 10:59:22'))
        Assert-True (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1)))
    }
    Invoke-Case 'Success followed by a failed last block fails' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $old = New-LogText '問題なし'
        Write-Fixture $path $old
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path ($old + (New-LogText 'Instance does not exist.' '2026/10/10 10:59:22'))
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }
    Invoke-Case 'A non-final success phrase is not sufficient' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path (New-LogText "問題なし`r`nError after final check")
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }
    Invoke-Case 'Touched old successful last block cannot pass by hash change elsewhere' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $old = New-LogText '問題なし'
        Write-Fixture $path $old
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path ('unrelated prefix' + "`r`n" + $old)
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }
    Invoke-Case 'Changed log with last-write timestamp older than run fails' {
        $path = Join-Path (New-CaseFolder) 'InstLog.txt'
        $before = Get-MutInstLogEvidence -Path $path
        Write-Fixture $path (New-LogText '問題なし')
        [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddHours(-1))
        Assert-True (-not (Test-MutFreshInstallLog -Before $before -After (Get-MutInstLogEvidence -Path $path) -StartedUtc ([datetime]::UtcNow.AddMinutes(-1))))
    }

    Invoke-Case 'Missing ZIP fails without extraction' {
        $folder = New-CaseFolder
        Assert-Throws { Get-MutZipManifest -ArchivePath (Join-Path $folder 'missing.zip') -ExpectedHash ('A' * 64) }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $folder -Force).Count
    }
    Invoke-Case 'ZIP hash mismatch rejects package' {
        $folder = New-CaseFolder
        $path = Join-Path $folder 'package.zip'
        $null = New-TestArchive $path @(@{ Name = 'SEW25091/readme.txt'; Text = 'fixture' })
        Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash ('A' * 64) }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $folder 'SEW25091')))
    }
    Invoke-Case 'Unicode paths and exact contents round-trip; repeated verification is idempotent' {
        $folder = Join-Path (New-CaseFolder) '中文 與 空白'
        $null = New-Item -ItemType Directory -Path $folder
        $path = Join-Path $folder '來源.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/子資料夾/說明.txt'; Text = 'fixture 中文' }, @{ Name = 'SEW25091/empty/'; Text = '' })
        $target = Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash $hash
        Assert-Equal 'fixture 中文' ([IO.File]::ReadAllText((Join-Path $target '子資料夾\說明.txt')))
        Assert-Equal $target (Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash $hash)
    }
    Invoke-Case 'Relative ZIP traversal is rejected before extraction' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/../escape.txt'; Text = 'invalid' })
        Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash $hash }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $folder 'escape.txt')))
    }
    Invoke-Case 'Absolute ZIP path is rejected' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'C:/escape.txt'; Text = 'invalid' })
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash }
    }
    Invoke-Case 'Mixed top-level package roots are rejected' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/readme.txt'; Text = 'one' }, @{ Name = 'ps2DLC/readme.txt'; Text = 'two' })
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash }
    }
    Invoke-Case 'Reserved Windows device path is rejected' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/CON.txt'; Text = 'invalid' })
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash }
    }
    Invoke-Case 'Alternate data stream ZIP path is rejected' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/file.txt:other'; Text = 'invalid' })
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash }
    }
    Invoke-Case 'Case-insensitive ZIP duplicate is rejected' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/readme.txt'; Text = 'first' }, @{ Name = 'SEW25091/README.TXT'; Text = 'second' })
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash }
    }
    Invoke-Case 'Unknown existing file is preserved and extraction refuses the tree' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/readme.txt'; Text = 'fixture' })
        $target = Join-Path $folder 'SEW25091'; $null = New-Item -ItemType Directory -Path $target
        $unknown = Join-Path $target 'user-file.txt'; Write-Fixture $unknown 'keep me'
        $before = (Get-FileHash -LiteralPath $unknown).Hash
        Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash $hash }
        Assert-Equal $before (Get-FileHash -LiteralPath $unknown).Hash
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'readme.txt')))
    }
    Invoke-Case 'Different existing package file is not overwritten' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'SEW25091/readme.txt'; Text = 'fixture' })
        $target = Join-Path $folder 'SEW25091'; $null = New-Item -ItemType Directory -Path $target
        $existing = Join-Path $target 'readme.txt'; Write-Fixture $existing 'different existing content'
        $before = (Get-FileHash -LiteralPath $existing).Hash
        Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -DestinationParent $folder -ExpectedHash $hash }
        Assert-Equal $before (Get-FileHash -LiteralPath $existing).Hash
    }
    Invoke-Case 'Microsoft package root is supported' {
        $folder = New-CaseFolder; $path = Join-Path $folder 'package.zip'
        $hash = New-TestArchive $path @(@{ Name = 'ps2DLC/loadGAC.ps1'; Text = '# fixture, never executed' })
        Assert-Equal 'ps2DLC' (Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash).RootName
    }
} finally {
    # Delete only this test-created GUID directory, using PowerShell end-to-end.
    $absolute = [IO.Path]::GetFullPath($testRoot)
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($absolute) -notmatch '^mut-oneclick-tests-[a-f0-9]{32}$') {
        throw 'Refusing test cleanup outside the expected temporary directory.'
    }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}

$failed = @($script:results | Where-Object { -not $_.Passed })
$summary = [pscustomobject]@{
    CompletedUtc = [datetime]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Total = $script:results.Count; Passed = $script:results.Count - $failed.Count; Failed = $failed.Count
    Scope = 'Temporary fixture tests only; no installer, registry mutation, SQL removal, download or reboot executed.'
    Cases = $script:results.ToArray()
}
if ($ResultPath) { $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8 }
Write-Host ('Results: {0} passed, {1} failed, {2} total.' -f $summary.Passed, $summary.Failed, $summary.Total)
if ($failed.Count) { exit 1 }
exit 0
