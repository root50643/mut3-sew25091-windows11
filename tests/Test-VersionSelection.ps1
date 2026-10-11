[CmdletBinding()]
param()

# Evaluate selected pure/function bodies with injected effects. Never invoke the
# main script, elevation, installation, cleanup, registry writes, or real children.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run these tests with Windows PowerShell 5.1.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'scripts\Mut-MediaProfiles.psm1') -Force
$tokens = $null; $errors = $null
$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\Install-Mut.ps1'), [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw 'Install-Mut.ps1 has syntax errors.' }
foreach ($name in @('Prepare-MutMedia','Start-MutChild','Invoke-MutAuto','Stop-MutReview','Invoke-MutApplicationConfirmation','Get-MutOfficialArchive','Test-MutUpgradeRequested','New-MutSelectedState','Test-MutCoordinatorCompletion','Invoke-MutUpgradeEntry','Get-MutUpgradeBlockingProcesses','Test-MutUpgradeIdle','Start-MutReviewedUpgradeUninstall')) {
    $definition = $mainAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    if (-not $definition) { throw ('Missing function: ' + $name) }
    # AST-created script blocks have no source file, so restore only their
    # original script-directory constant; the function logic stays unchanged.
    $helperRootLiteral = "'" + (Join-Path $projectRoot 'scripts').Replace("'", "''") + "'"
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', $helperRootLiteral)))
}
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:TaskRoot = 'C:\MUT-Install'
$script:RepoRoot = 'C:\fixture repo'
$script:NativePS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script:RunRoot = 'C:\fixture logs'
$script:StatePath = 'C:\fixture state.json'
$script:PsArchiveHash = 'D9812E7BE1F72FF49D73F3179E207AA0000852D9D0EFD92455AD376FAD5D9B7C'

function Assert-True($Actual, [string]$Message = 'Expected true.') { if (-not $Actual) { throw $Message } }
function Assert-Equal($Expected, $Actual) { if ($Expected -cne $Actual) { throw ('Expected [{0}], actual [{1}].' -f $Expected, $Actual) } }
function Invoke-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=$null})
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}
function Select-FixtureProfile([string]$SelectedRelease) {
    $script:Profile = Get-MutMediaProfile -Release $SelectedRelease
    $script:MediaHash = $script:Profile.MediaHash
}
function Invoke-MediaFixture {
    $captured = New-Object 'System.Collections.Generic.List[object]'
    function Test-Path { param([string]$LiteralPath) return $true }
    function Write-MutEvent { param([string]$Text) }
    function Expand-MutVerifiedArchive {
        param([string]$ArchivePath,[string]$DestinationParent,[string]$ExpectedHash,[string]$ExpectedRoot)
        $captured.Add([pscustomobject]@{ArchivePath=$ArchivePath;DestinationParent=$DestinationParent;ExpectedHash=$ExpectedHash;ExpectedRoot=$ExpectedRoot})
    }
    Prepare-MutMedia
    return $captured[0]
}
function Invoke-ChildFixture([string]$Name) {
    $captured = New-Object 'System.Collections.Generic.List[object]'
    function Assert-MutHelpers { }
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
        $captured.Add([pscustomobject]@{Path=$FilePath;Arguments=$ArgumentList})
        return [pscustomobject]@{Handle=0;Id=424242}
    }
    function Get-CimInstance { param($ClassName,$Filter) return [pscustomobject]@{CreationDate=[datetime]'2026-10-11T01:00:00Z'} }
    $null = Start-MutChild -Name $Name -Arguments '-Phase Manual'
    return $captured[0]
}
function Invoke-ConfirmationFixture {
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $script:State = [pscustomobject]@{ApplicationConfirmation=$null;Phase='AwaitingApplicationConfirmation'}
    function Show-MutNotice { param([string]$Text,$Kind,[switch]$Confirm) $messages.Add($Text); if ($Confirm) { return $true } }
    function Save-MutCheckpoint { param([string]$Phase) $script:State.Phase=$Phase }
    $code = Invoke-MutApplicationConfirmation -Verification $null
    return [pscustomobject]@{Code=$code;Messages=@($messages);State=$script:State}
}
function Invoke-MismatchedStateFixture([string]$Phase,[switch]$OtherMachine) {
    $old = Get-MutMediaProfile -Release 'SEW25091'
    function Read-MutState {
        param([string]$Path)
        return [pscustomobject]@{Machine=$(if($OtherMachine){'OTHER-FIXTURE-MACHINE'}else{$env:COMPUTERNAME});MediaHash=$old.MediaHash;Phase=$Phase}
    }
    function Get-MutBootUtc { throw 'Unexpected system work after mismatched state.' }
    function Test-MutUpgradeRequested { return $false }
    $failure = $null
    try { Invoke-MutAuto | Out-Null } catch { $failure=$_.Exception }
    Assert-True ($null -ne $failure) 'Mismatched state must be rejected.'
    Assert-Equal 2 $failure.Data['MutExitCode']
    return $failure.Message
}
function Invoke-PreservedFixture([string]$Scenario='Ready') {
    Select-FixtureProfile SEW26061-00
    function Get-MutBootUtc {return '2026-10-11T03:00:00.0000000Z'}
    $saved=New-MutSelectedState
    $saved.UpgradeManifest='C:\MUT-Install\upgrade-backups\fixture\manifest.json'
    $saved.UpgradeManifestSha256='D'*64
    $effects=New-Object 'System.Collections.Generic.List[string]'
    function Read-MutState {param($Path) return $saved}
    function Test-MutUpgradeRequested {return $false}
    function Assert-MutSelectedUpgradeBackup {$effects.Add('pinned-backup');if($Scenario -eq 'BadBackup'){Stop-MutReview 'bad backup'};return [pscustomobject]@{Status='Complete'}}
    function Get-MutInstallerProcesses {return @()}
    function Test-MutPendingRestart {return $false}
    function Get-Service {
        [CmdletBinding()]param($Name)
        $count=if($Scenario -eq 'OneSql'){1}else{2}
        @([pscustomobject]@{Name='MSSQL$MUT3';Status='Stopped'},[pscustomobject]@{Name='MSSQL$CAESARCOMPDB';Status='Stopped'}) | Select-Object -First $count
    }
    function Test-Path {param($LiteralPath) return ($Scenario -eq 'Leftovers' -and $LiteralPath -ceq 'C:\MUTSW')}
    function Get-ItemProperty {[CmdletBinding()]param($LiteralPath) return $null}
    function Get-MutTargetRegistryRemnants {return @()}
    function Prepare-MutMedia {$effects.Add('prepare')}
    function Assert-MutPreservedSqlIdentity {param($Manifest) $effects.Add('sql');if($Scenario -eq 'UnknownSql'){Stop-MutReview 'unknown SQL'}}
    function Invoke-MutFailedCleanup {throw 'Health upgrade must never clean SQL'}
    function Invoke-MutPrerequisiteStage {$effects.Add('prereq');return 0}
    function Show-MutNotice {param($Text) }
    function Get-MutInstLogEvidence {param($Path) return [pscustomobject]@{Exists=$false}}
    function Save-MutCheckpoint {param($Phase) $script:State.Phase=$Phase;$effects.Add('save:'+$Phase)}
    function Start-MutChild {param($Name,$Arguments) $effects.Add('child:'+$Name);$effects.Add('args:'+$Arguments);return [pscustomobject]@{Pid=100;CreatedUtc='fixture'}}
    function Wait-MutOriginalInstallation {$effects.Add('monitor');return 3010}
    $failure=$null;$code=$null
    try{$code=Invoke-MutAuto}catch{$failure=$_.Exception}
    return [pscustomobject]@{Code=$code;Error=$failure;Effects=@($effects);State=$script:State}
}
function Invoke-UpgradeProcessFixture([object[]]$Processes,[object[]]$Installers=@()) {
    function Get-MutInstallerProcesses {return $Installers}
    function Get-CimInstance {[CmdletBinding()]param($ClassName) return $Processes}
    return @(Get-MutUpgradeBlockingProcesses)
}

Invoke-Case 'Profile and main entry both default to reviewed SEW26061-00' {
    Assert-Equal 'SEW26061-00' (Get-MutMediaProfile).Release
    $releaseParameter = @($mainAst.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'Release'})
    Assert-Equal 1 $releaseParameter.Count
    Assert-Equal 'SEW26061-00' $releaseParameter[0].DefaultValue.Value
    $validate = @($releaseParameter[0].Attributes | Where-Object {$_.TypeName.Name -eq 'ValidateSet'})
    Assert-Equal 'SEW25091,SEW26061-00' (($validate[0].PositionalArguments | ForEach-Object {$_.Value}) -join ',')
}
Invoke-Case 'Reviewed profiles preserve distinct exact hashes and expected versions' {
    $old=Get-MutMediaProfile -Release 'SEW25091'; $new=Get-MutMediaProfile -Release 'SEW26061-00'
    Assert-Equal '1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03' $old.MediaHash
    Assert-Equal 'A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8' $new.MediaHash
    Assert-Equal 'SEW25091-00' $old.SeVersion
    Assert-Equal 'SEW26061-00' $new.SeVersion
    Assert-True ($old.MediaHash -cne $new.MediaHash)
}
Invoke-Case 'Unsupported release is rejected rather than treated as latest' {
    $failure=$null
    try { Get-MutMediaProfile -Release 'SEW99999' | Out-Null } catch { $failure=$_ }
    Assert-True ($null -ne $failure)
}
Invoke-Case 'Profile requests return independent objects' {
    $changed=Get-MutMediaProfile; $changed.MediaHash='modified fixture'
    Assert-Equal 'A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8' (Get-MutMediaProfile).MediaHash
}
foreach ($selectedRelease in @('SEW25091','SEW26061-00')) {
    Select-FixtureProfile $selectedRelease
    Invoke-Case ($selectedRelease+' preparation binds filename, SHA and expected ZIP root') {
        $captured=Invoke-MediaFixture
        Assert-Equal (Join-Path $script:RepoRoot ($selectedRelease+'.zip')) $captured.ArchivePath
        Assert-Equal $selectedRelease $captured.ExpectedRoot
        Assert-Equal $script:Profile.MediaHash $captured.ExpectedHash
        Assert-Equal $script:TaskRoot $captured.DestinationParent
        Assert-Equal 'PRG23061-03' $script:Profile.ClassicVersion
        Assert-Equal '12.0.4100.1' $script:Profile.SqlVersion
    }
    foreach ($helper in @('Verify-MutSqlInstallation.ps1','Repair-MutPrerequisites.ps1','Remove-FailedMutSqlInstances.ps1','Start-MutInstallWithSqlAcl.ps1')) {
        Invoke-Case ($selectedRelease+' reaches child '+$helper) {
            $captured=Invoke-ChildFixture $helper
            Assert-True ($captured.Arguments.Contains(' -Release '+$selectedRelease+' ')) 'Child lost selected release.'
            Assert-True ($captured.Arguments.Contains(' -Phase Manual')) 'Existing child arguments were dropped.'
            Assert-Equal $script:NativePS $captured.Path
        }
    }
    Invoke-Case ($selectedRelease+' survives UAC argument forwarding in Check mode') {
        $Mode='Check'; $Release=$selectedRelease
        $assignment=$mainAst.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$arguments' -and $node.Right.Extent.Text -match '\$PSCommandPath'}, $true)
        Assert-True ($null -ne $assignment)
        . ([scriptblock]::Create($assignment.Extent.Text))
        Assert-True ($arguments.Contains(' -Mode Check -Release '+$selectedRelease))
    }
    Invoke-Case ($selectedRelease+' confirmation prompts and records the selected version') {
        $result=Invoke-ConfirmationFixture
        Assert-Equal 0 $result.Code
        Assert-Equal 'Completed' $result.State.Phase
        Assert-Equal $selectedRelease $result.State.ApplicationConfirmation.Release
        Assert-Equal $script:Profile.SeVersion $result.State.ApplicationConfirmation.SeVersion
        Assert-True (($result.Messages -join '|').Contains($script:Profile.SeVersion))
        Assert-True $result.State.ApplicationConfirmation.Classic
        Assert-True $result.State.ApplicationConfirmation.SE
    }
}
Invoke-Case 'Official prerequisite archive always binds ps2DLC root' {
    $captured=New-Object 'System.Collections.Generic.List[object]'
    function Test-Path { param([string]$LiteralPath) return $true }
    function Expand-MutVerifiedArchive {
        param([string]$ArchivePath,[string]$DestinationParent,[string]$ExpectedHash,[string]$ExpectedRoot)
        $captured.Add([pscustomobject]@{ExpectedHash=$ExpectedHash;ExpectedRoot=$ExpectedRoot})
    }
    Get-MutOfficialArchive
    Assert-Equal 'ps2DLC' $captured[0].ExpectedRoot
    Assert-Equal $script:PsArchiveHash $captured[0].ExpectedHash
}
Select-FixtureProfile 'SEW26061-00'
Invoke-Case 'Old Completed state without an approved upgrade route remains rejected' { $null=Invoke-MismatchedStateFixture -Phase Completed }
Invoke-Case 'Old incomplete state cannot resume under a new media hash' { $null=Invoke-MismatchedStateFixture -Phase Installing }
Invoke-Case 'Other-machine state cannot be reused' { $null=Invoke-MismatchedStateFixture -Phase Completed -OtherMachine }
Invoke-Case 'Both releases retain the original cross-version mutex name' {
    Assert-True ($mainAst.Extent.Text.Contains("'Global\MUT-SEW25091-OneClick'"))
    Assert-True (-not $mainAst.Extent.Text.Contains("'Global\MUT-SEW26061-00-OneClick'"))
}
Invoke-Case 'Backup child does not receive unsupported Release parameter' {
    $captured=Invoke-ChildFixture 'Backup-MutUpgrade.ps1'
    Assert-True (-not $captured.Arguments.Contains(' -Release '))
}
Invoke-Case 'Known old state requests upgrade while selected target state never does' {
    Select-FixtureProfile SEW26061-00
    $script:State=[pscustomobject]@{MediaHash=(Get-MutMediaProfile SEW25091).MediaHash;Phase='Completed'}
    Assert-True (Test-MutUpgradeRequested)
    $script:State.MediaHash=$script:MediaHash
    Assert-True (!(Test-MutUpgradeRequested))
}
Invoke-Case 'Stateless reviewed old installation requests upgrade' {
    Select-FixtureProfile SEW26061-00;$script:State=$null
    function Test-Path {param($LiteralPath) return $false}
    function Get-MutInstalledSeVersion {return 'SEW25091-00'}
    Assert-True (Test-MutUpgradeRequested)
}
Invoke-Case 'Unknown installed SE never becomes a recognized healthy upgrade' {
    Select-FixtureProfile SEW26061-00;$script:State=$null
    function Test-Path {param($LiteralPath) return $false}
    function Get-MutInstalledSeVersion {return 'UNKNOWN'}
    Assert-True (!(Test-MutUpgradeRequested))
}
Invoke-Case 'Legacy release does not dispatch a healthy upgrade' {
    Select-FixtureProfile SEW25091;$script:State=$null
    Assert-True (!(Test-MutUpgradeRequested))
}
Invoke-Case 'Auto returns upgrade reboot before any target-state preparation' {
    Select-FixtureProfile SEW26061-00
    function Read-MutState {param($Path) return [pscustomobject]@{Machine=$env:COMPUTERNAME;MediaHash=(Get-MutMediaProfile SEW25091).MediaHash}}
    function Test-MutUpgradeRequested {return $true}
    function Invoke-MutUpgradeEntry {return [pscustomobject]@{ExitCode=3010;ReadyForInstall=$false}}
    function Get-MutBootUtc {throw 'Target work ran before upgrade reboot'}
    Assert-Equal 3010 (Invoke-MutAuto)
}
Invoke-Case 'Fresh target state resets application and installation evidence' {
    Select-FixtureProfile SEW26061-00
    function Get-MutBootUtc {return '2026-10-11T03:00:00.0000000Z'}
    $state=New-MutSelectedState
    Assert-Equal 'Checking' $state.Phase;Assert-Equal $script:MediaHash $state.MediaHash
    Assert-True (!$state.ApplicationConfirmation);Assert-True (!$state.LogBefore);Assert-Equal '' $state.InstallStartedUtc
}
Invoke-Case 'Old uninstall media is independently verified in a fresh exact tree' {
    Select-FixtureProfile SEW26061-00;$script:State=$null
    $captured=New-Object 'System.Collections.Generic.List[object]'
    function Test-Path {param($LiteralPath) return $true}
    function Expand-MutVerifiedArchive {param($ArchivePath,$DestinationParent,$ExpectedHash,$ExpectedRoot) $captured.Add([pscustomobject]@{Archive=$ArchivePath;Destination=$DestinationParent;Hash=$ExpectedHash;Root=$ExpectedRoot})}
    function Invoke-MutHealthyUpgrade {param($StatePath,$ExistingState,$SourceHash,$TargetHash,$Operations) & $Operations.PrepareOld;return [pscustomobject]@{ExitCode=1223;ReadyForInstall=$false}}
    $null=Invoke-MutUpgradeEntry
    Assert-Equal 1 $captured.Count;Assert-Equal (Join-Path $script:TaskRoot 'upgrade-uninstall-media') $captured[0].Destination
    Assert-Equal 'SEW25091' $captured[0].Root;Assert-Equal (Get-MutMediaProfile SEW25091).MediaHash $captured[0].Hash
}
Invoke-Case 'Preserved healthy SQL reaches coordinator with pinned manifest and no cleanup' {
    $r=Invoke-PreservedFixture
    Assert-True (!$r.Error) $(if($r.Error){$r.Error.Message}else{''})
    Assert-Equal 3010 $r.Code;Assert-Equal 'Installing' $r.State.Phase
    Assert-True ($r.Effects -contains 'sql');Assert-True ($r.Effects -contains 'monitor')
    Assert-True (($r.Effects -join '|').Contains('-UpgradeManifest "'+$r.State.UpgradeManifest+'" -UpgradeManifestHash '+('D'*64)))
}
foreach($scenario in @('Leftovers','OneSql','UnknownSql','BadBackup')){
    Invoke-Case ('Preserved upgrade refuses '+$scenario+' before coordinator or cleanup') {
        $r=Invoke-PreservedFixture $scenario
        Assert-True ($null -ne $r.Error);Assert-Equal 2 $r.Error.Data['MutExitCode']
        Assert-True (-not ($r.Effects -contains 'child:Start-MutInstallWithSqlAcl.ps1'))
        Assert-True (-not ($r.Effects -contains 'prereq'))
    }
}
Invoke-Case 'SQL reused status only passes for pinned upgrade state and current run' {
    $start=[datetime]::Parse('2026-10-11T03:00:00Z').ToUniversalTime()
    $status=[pscustomobject]@{stage='sql-engines-reused';time=$start.ToString('o')}
    $script:State=[pscustomobject]@{Phase='Installing'}
    Assert-True (!(Test-MutCoordinatorCompletion $status $start))
    $script:State | Add-Member UpgradeManifest 'fixture'
    $script:State | Add-Member UpgradeManifestSha256 ('D'*64)
    Assert-True (Test-MutCoordinatorCompletion $status $start)
    $status.time=$start.AddSeconds(-1).ToString('o')
    Assert-True (!(Test-MutCoordinatorCompletion $status $start))
    $status.time=$start.ToString('o');$script:State.UpgradeManifestSha256='invalid'
    Assert-True (!(Test-MutCoordinatorCompletion $status $start))
}
foreach($processName in @('MUT3_SE.exe','MUT3_Launcher.exe','iexplore.exe','wscript.exe','cscript.exe')){
    Invoke-Case ('Upgrade blocks '+$processName+' even when executable path and command line are unavailable') {
        $process=[pscustomobject]@{Name=$processName;ProcessId=401;ExecutablePath=$null;CommandLine=$null}
        Assert-Equal 1 @(Invoke-UpgradeProcessFixture @($process)).Count
    }
}
Invoke-Case 'Upgrade conservatively blocks an apparently unrelated Script Host and IE COM host' {
    $processes=@([pscustomobject]@{Name='wscript.exe';ProcessId=401;ExecutablePath='C:\Windows\System32\wscript.exe';CommandLine='wscript.exe relative.js'},[pscustomobject]@{Name='iexplore.exe';ProcessId=402;ExecutablePath='C:\Program Files\Internet Explorer\iexplore.exe';CommandLine='iexplore.exe -Embedding'})
    Assert-Equal 2 @(Invoke-UpgradeProcessFixture $processes).Count
}
Invoke-Case 'Upgrade blocks renamed executables inside either canonical MUT root' {
    $processes=@([pscustomobject]@{Name='unknown.exe';ProcessId=401;ExecutablePath='C:\MUTSW\MUT3\tool.exe';CommandLine=$null},[pscustomobject]@{Name='unknown.exe';ProcessId=402;ExecutablePath='C:\MUTSW_SE\MUT3_SE\tool.exe';CommandLine=$null})
    Assert-Equal 2 @(Invoke-UpgradeProcessFixture $processes).Count
}
Invoke-Case 'Upgrade blocks generic hosts with MUT source in command line' {
    $process=[pscustomobject]@{Name='mshta.exe';ProcessId=401;ExecutablePath='C:\Windows\System32\mshta.exe';CommandLine='mshta.exe "C:\MUTSW\MUT3\index.hta"'}
    Assert-Equal 1 @(Invoke-UpgradeProcessFixture @($process)).Count
}
Invoke-Case 'Upgrade excludes unrelated processes and similarly prefixed directories' {
    $processes=@([pscustomobject]@{Name='notepad.exe';ProcessId=401;ExecutablePath='C:\Windows\System32\notepad.exe';CommandLine='notepad.exe'},[pscustomobject]@{Name='unknown.exe';ProcessId=402;ExecutablePath='C:\MUTSW_other\tool.exe';CommandLine='"C:\MUTSW_backup\tool.exe"'})
    Assert-Equal 0 @(Invoke-UpgradeProcessFixture $processes).Count
}
Invoke-Case 'Upgrade retains installer blockers and deduplicates the same process' {
    $process=[pscustomobject]@{Name='wscript.exe';ProcessId=401;ExecutablePath='C:\Windows\System32\wscript.exe';CommandLine='UNINST.vbs'}
    Assert-Equal 1 @(Invoke-UpgradeProcessFixture @($process) @($process)).Count
}
Invoke-Case 'Upgrade adapter Idle uses application-aware inventory' {
    Select-FixtureProfile SEW26061-00;$script:State=$null
    function Get-MutInstallerProcesses {return @()}
    function Get-CimInstance {[CmdletBinding()]param($ClassName) return [pscustomobject]@{Name='MUT3_SE.exe';ProcessId=401;ExecutablePath=$null;CommandLine=$null}}
    function Invoke-MutHealthyUpgrade {param($StatePath,$ExistingState,$SourceHash,$TargetHash,$Operations) Assert-True (!(& $Operations.Idle));return [pscustomobject]@{ExitCode=2;ReadyForInstall=$false}}
    Assert-Equal 2 (Invoke-MutUpgradeEntry).ExitCode
}
Invoke-Case 'Uninstall rechecks processes after prompt and never starts when an app opens during it' {
    $effects=New-Object 'System.Collections.Generic.List[string]'
    $fixture=[pscustomobject]@{AfterPrompt=$false}
    function Show-MutNotice {param($Text) $fixture.AfterPrompt=$true;$effects.Add('notice')}
    function Get-MutInstallerProcesses {return @()}
    function Get-CimInstance {
        [CmdletBinding()]param($ClassName)
        Assert-True $fixture.AfterPrompt 'Process recheck ran before the prompt'
        $effects.Add('recheck');return [pscustomobject]@{Name='MUT3_SE.exe';ProcessId=401;ExecutablePath=$null;CommandLine=$null}
    }
    function Start-Process {throw 'Uninstall must not be started'}
    $caught=$null;try{Start-MutReviewedUpgradeUninstall}catch{$caught=$_.Exception}
    Assert-True ($null -ne $caught);Assert-Equal 2 $caught.Data['MutExitCode'];Assert-Equal 'notice,recheck' ($effects -join ',')
}
Invoke-Case 'Uninstall starts once only after prompt and final idle recheck' {
    $effects=New-Object 'System.Collections.Generic.List[string]'
    function Show-MutNotice {param($Text) $effects.Add('notice')}
    function Get-MutInstallerProcesses {return @()}
    function Get-CimInstance {[CmdletBinding()]param($ClassName) $effects.Add('recheck');return @()}
    function Start-Process {param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru) $effects.Add('start');Assert-True ($ArgumentList.Contains('upgrade-uninstall-media\SEW25091\UNINSTALLER\UNINST.BAT'));Assert-Equal 'Hidden' $WindowStyle}
    Start-MutReviewedUpgradeUninstall
    Assert-Equal 'notice,recheck,start' ($effects -join ',')
}
$failed=@($script:results | Where-Object {-not $_.Passed})
[ordered]@{Total=$script:results.Count;Passed=$script:results.Count-$failed.Count;Failed=$failed.Count;Failures=@($failed)}|ConvertTo-Json -Depth 4
if ($failed.Count) { exit 1 }
exit 0
