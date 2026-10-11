#requires -Version 5.1
[CmdletBinding()]
param([string]$ResultPath)

# Isolated workflow/adapter tests. Never load the repair helper, run the vendor
# installer, touch the registry, start services, or request elevation.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1.'}
$project=Split-Path -Parent $PSScriptRoot
$frontend=Join-Path $project 'scripts\Prepare-MutPrerequisites.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($frontend,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw ($parseErrors.Message -join '; ')}
. $frontend -LibraryOnly
$script:cases=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message='Expected true.'){if(!$Value){throw $Message}}
function Assert-Equal($Expected,$Actual){if($Expected -cne $Actual){throw ('Expected ['+$Expected+'], actual ['+$Actual+'].')}}
function Assert-Throws([scriptblock]$Action){$errorSeen=$false;try{& $Action|Out-Null}catch{$errorSeen=$true};Assert-True $errorSeen 'Expected rejection.'}
function Case([string]$Name,[scriptblock]$Action){
    try{& $Action;$script:cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=$null});Write-Host ('PASS '+$Name)}
    catch{$script:cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function Invoke-Fixture([string]$SelectedMode='Prepare',[hashtable]$Changes=@{}){
    $fixture=@{
        Busy=$false;Pending=$false;ExistingPass=$true;FreshPass=$true
        SourceFailure=$false;VerifyFailure=$false;RepairFailure=$false;FreshFailure=$false
        RepairExit=0;SqlReview=$false;SqlInstances=@();SqlPlans=0
        SqlRecheckReview=$false;SqlDisappear=$false;SqlRepairExit=0;SqlVerified=$true;SqlRepairFailure=$false
        AfterFirstReviewReason='';AfterFirstReviewInstance='MUT3';SqlApplied=@()
    }
    foreach($key in $Changes.Keys){$fixture[$key]=$Changes[$key]}
    $calls=New-Object 'System.Collections.Generic.List[string]'
    $ops=@{
        Busy={$calls.Add('busy');return $fixture.Busy}
        PendingRestart={$calls.Add('pending');return $fixture.Pending}
        PrepareSource={$calls.Add('source');if($fixture.SourceFailure){throw 'Source hash or extraction mismatch.'}}
        Verify={$calls.Add('verify');if($fixture.VerifyFailure){throw 'Unreadable evidence.'};return [pscustomobject]@{Passed=$fixture.ExistingPass;Findings=@('fixture old result')}}
        Repair={$calls.Add('repair');if($fixture.RepairFailure){throw 'Child launch failed.'};return [pscustomobject]@{ExitCode=$fixture.RepairExit;StartedUtc='2026-10-11T14:00:00Z';Error='fixture repair error'}}
        VerifyFresh={param($Repair) $calls.Add('verify-fresh');Assert-Equal '2026-10-11T14:00:00Z' $Repair.StartedUtc;if($fixture.FreshFailure){throw 'Stale repair status.'};return [pscustomobject]@{Passed=$fixture.FreshPass;Findings=@('fixture fresh result')}}
        SqlPlan={
            $fixture.SqlPlans++;$calls.Add('sql-plan')
            $review=$fixture.SqlReview;$instances=@($fixture.SqlInstances);$items=@()
            if($fixture.SqlPlans -gt 1){if($fixture.SqlRecheckReview){$review=$true};if($fixture.SqlDisappear){$instances=@()}}
            if($fixture.SqlApplied.Count -and $fixture.AfterFirstReviewReason){
                $review=$true;$instances=@($instances|Where-Object {$_ -notin $fixture.SqlApplied})
                $items=@([pscustomobject]@{Instance=$fixture.AfterFirstReviewInstance;Action='Review';Reason=$fixture.AfterFirstReviewReason})
            }
            return [pscustomobject]@{ReviewRequired=$review;RepairInstances=$instances;Items=$items}
        }
        RepairSql={param($Instance) $calls.Add('sql-repair:'+$Instance);if($fixture.SqlRepairFailure){throw 'SQL repair launch failed.'};$fixture.SqlApplied+= $Instance;return [pscustomobject]@{ExitCode=$fixture.SqlRepairExit;Verified=$fixture.SqlVerified;Error='fixture SQL error'}}
    }
    $result=$null;$failure=$null
    try{$result=Invoke-MutPreparationWorkflow -Mode $SelectedMode -Operations $ops}catch{$failure=$_.Exception}
    return [pscustomobject]@{Result=$result;Error=$failure;Calls=@($calls.ToArray())}
}
function Assert-NoError($Run){Assert-True ($null -eq $Run.Error) $(if($Run.Error){$Run.Error.Message}else{''})}
function Assert-NoCalls($Run,[string[]]$Forbidden){foreach($name in $Forbidden){Assert-True ($name -notin $Run.Calls) ('Unexpected effect: '+$name)}}

Case 'Library-only loading did not create a run directory or collect a report' {
    Assert-True (!$script:RunRoot);Assert-True (!$script:Report)
}
Case 'Healthy prerequisites skip repair and succeed without an application source operation' {
    $r=Invoke-Fixture;Assert-NoError $r;Assert-Equal 0 $r.Result.ExitCode
    Assert-Equal 'busy,pending,source,verify,sql-plan' ($r.Calls -join ',')
    Assert-Equal 0 @($r.Result.RepairedInstances).Count
}
Case 'Missing prerequisites repair once then verify fresh evidence before SQL planning' {
    $r=Invoke-Fixture -Changes @{ExistingPass=$false};Assert-NoError $r;Assert-Equal 0 $r.Result.ExitCode
    Assert-Equal 'busy,pending,source,verify,repair,verify-fresh,sql-plan' ($r.Calls -join ',')
}
Case 'Check is read-only even with a pending-reboot fixture' {
    $r=Invoke-Fixture Check @{Pending=$true};Assert-NoError $r;Assert-Equal 0 $r.Result.ExitCode
    Assert-Equal 'busy,verify,sql-plan' ($r.Calls -join ',')
}
Case 'Check reports missing prerequisites and never runs repair' {
    $r=Invoke-Fixture Check @{ExistingPass=$false};Assert-NoError $r;Assert-Equal 2 $r.Result.ExitCode
    Assert-NoCalls $r @('source','repair','verify-fresh')
}
Case 'Check reports a required SQL ACL repair without performing it' {
    $r=Invoke-Fixture Check @{SqlInstances=@('MUT3')};Assert-NoError $r;Assert-Equal 2 $r.Result.ExitCode
    Assert-NoCalls $r @('sql-repair:MUT3','repair','source')
}
Case 'Check reports unknown SQL and does not repair prerequisites or SQL' {
    $r=Invoke-Fixture Check @{SqlReview=$true;SqlInstances=@('MUT3')};Assert-NoError $r;Assert-Equal 2 $r.Result.ExitCode
    Assert-NoCalls $r @('sql-repair:MUT3','repair','source')
}
foreach($selectedMode in @('Prepare','Check')){
    Case ($selectedMode+' busy gate stops before source or evidence') {
        $r=Invoke-Fixture $selectedMode @{Busy=$true};Assert-True ($null -ne $r.Error)
        Assert-Equal 'busy' ($r.Calls -join ',')
    }
}
Case 'Pending reboot exits 3010 before copying or extracting sources' {
    $r=Invoke-Fixture -Changes @{Pending=$true};Assert-NoError $r;Assert-Equal 3010 $r.Result.ExitCode
    Assert-Equal 'busy,pending' ($r.Calls -join ',')
}
Case 'NetFx3 repair requesting reboot stops without post-repair verification or SQL work' {
    $r=Invoke-Fixture -Changes @{ExistingPass=$false;RepairExit=3010};Assert-NoError $r;Assert-Equal 3010 $r.Result.ExitCode
    Assert-Equal 1 @($r.Calls|Where-Object {$_ -ceq 'source'}).Count
    Assert-Equal 1 @($r.Calls|Where-Object {$_ -ceq 'repair'}).Count
    Assert-NoCalls $r @('verify-fresh','sql-plan')
}
foreach($badExit in @(1,2,1223)){
    Case ('Repair exit '+$badExit+' cannot fall back to old success evidence') {
        $r=Invoke-Fixture -Changes @{ExistingPass=$false;RepairExit=$badExit};Assert-True ($null -ne $r.Error)
        Assert-NoCalls $r @('verify-fresh','sql-plan')
        Assert-Equal 1 @($r.Calls|Where-Object {$_ -ceq 'verify'}).Count
    }
}
Case 'Source mismatch stops before any prerequisite mutation' {
    $r=Invoke-Fixture -Changes @{SourceFailure=$true};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('verify','repair','verify-fresh','sql-plan')
}
Case 'Unreadable existing evidence stops instead of assuming missing components' {
    $r=Invoke-Fixture -Changes @{VerifyFailure=$true};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('repair','verify-fresh','sql-plan')
}
Case 'Child launch error is not converted into success' {
    $r=Invoke-Fixture -Changes @{ExistingPass=$false;RepairFailure=$true};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('verify-fresh','sql-plan')
}
Case 'Zero child exit with failed GAC or policy verification remains failure' {
    $r=Invoke-Fixture -Changes @{ExistingPass=$false;FreshPass=$false};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('sql-plan')
}
Case 'Stale fresh-result rejection stops SQL planning' {
    $r=Invoke-Fixture -Changes @{ExistingPass=$false;FreshFailure=$true};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('sql-plan')
}
Case 'Unknown SQL returns review and does not apply any planned ACL repair' {
    $r=Invoke-Fixture -Changes @{SqlReview=$true;SqlInstances=@('MUT3')};Assert-NoError $r;Assert-Equal 2 $r.Result.ExitCode
    Assert-NoCalls $r @('sql-repair:MUT3')
}
Case 'A reviewed SQL ACL repair requires a fresh plan and records only that instance' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3')};Assert-NoError $r;Assert-Equal 3010 $r.Result.ExitCode
    Assert-Equal 'busy,pending,source,verify,sql-plan,sql-plan,sql-repair:MUT3' ($r.Calls -join ',')
    Assert-Equal 'MUT3' ($r.Result.RepairedInstances -join ',')
}
Case 'Two reviewed repairs are applied once each with independent state rechecks' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3','CAESARCOMPDB')};Assert-NoError $r;Assert-Equal 3010 $r.Result.ExitCode
    Assert-Equal 3 @($r.Calls|Where-Object {$_ -ceq 'sql-plan'}).Count
    Assert-Equal 'MUT3,CAESARCOMPDB' ($r.Result.RepairedInstances -join ',')
}
Case 'Second repair tolerates only a verified-this-run first instance with its now-present native grant' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3','CAESARCOMPDB');AfterFirstReviewReason='NativeGrantAlreadyPresent'}
    Assert-NoError $r;Assert-Equal 3010 $r.Result.ExitCode
    Assert-Equal 'MUT3,CAESARCOMPDB' ($r.Result.RepairedInstances -join ',')
}
Case 'An unknown post-repair review reason stops the second repair' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3','CAESARCOMPDB');AfterFirstReviewReason='ServiceAccountChanged'}
    Assert-True ($null -ne $r.Error);Assert-NoCalls $r @('sql-repair:CAESARCOMPDB')
}
Case 'A now-present grant on an instance not repaired this run does not allow a review bypass' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3','CAESARCOMPDB');AfterFirstReviewReason='NativeGrantAlreadyPresent';AfterFirstReviewInstance='CAESARCOMPDB'}
    Assert-True ($null -ne $r.Error);Assert-NoCalls $r @('sql-repair:CAESARCOMPDB')
}
foreach($race in @('SqlRecheckReview','SqlDisappear')){
    Case ($race+' stops before SQL mutation') {
        $changes=@{SqlInstances=@('MUT3')};$changes[$race]=$true
        $r=Invoke-Fixture -Changes $changes;Assert-True ($null -ne $r.Error)
        Assert-NoCalls $r @('sql-repair:MUT3')
    }
}
Case 'SQL repair nonzero exit stops before the next instance' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3','CAESARCOMPDB');SqlRepairExit=1};Assert-True ($null -ne $r.Error)
    Assert-NoCalls $r @('sql-repair:CAESARCOMPDB')
}
Case 'SQL repair zero exit without fresh verified result remains failure' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3');SqlVerified=$false};Assert-True ($null -ne $r.Error)
}
Case 'SQL repair exception propagates and is not retried' {
    $r=Invoke-Fixture -Changes @{SqlInstances=@('MUT3');SqlRepairFailure=$true};Assert-True ($null -ne $r.Error)
    Assert-Equal 1 @($r.Calls|Where-Object {$_ -ceq 'sql-repair:MUT3'}).Count
}
Case 'Unsupported workflow mode is rejected before any effect' {
    Assert-Throws {Invoke-MutPreparationWorkflow -Mode Install -Operations @{}}
}

Case 'Fresh evidence adapter rejects an old repair-status timestamp before calling verifier' {
    $effects=New-Object 'System.Collections.Generic.List[string]'
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding) return '{"time":"2026-10-11T13:00:00Z","logs":"C:\\MUT-Install\\repair-logs\\20261011-210000"}'}
    function Get-MutPreparationEvidence {param($RepairLogRoot) $effects.Add('verify');throw 'Must not read stale evidence.'}
    Assert-Throws {Get-MutPreparationFreshEvidence ([pscustomobject]@{StartedUtc='2026-10-11T14:00:00Z'})}
    Assert-Equal 0 $effects.Count
}
Case 'Fresh evidence adapter forwards exactly the current run repair log' {
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding) return '{"time":"2026-10-11T14:01:00Z","logs":"C:\\MUT-Install\\repair-logs\\20261011-220000"}'}
    function Get-MutPreparationEvidence {param($RepairLogRoot) Assert-Equal 'C:\MUT-Install\repair-logs\20261011-220000' $RepairLogRoot;return [pscustomobject]@{Passed=$true}}
    Assert-True (Get-MutPreparationFreshEvidence ([pscustomobject]@{StartedUtc='2026-10-11T14:00:00Z'})).Passed
}
Case 'Scoped SQL adapter invokes only the existing ACL helper and selected instance' {
    $captured=New-Object 'System.Collections.Generic.List[string]'
    function Start-MutPreparationChild {param($Name,$Arguments) $captured.Add($Name+'|'+$Arguments);return [pscustomobject]@{ExitCode=0;StartedUtc='2026-10-11T14:00:00Z';Error=''}}
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding) return '{"stage":"applied-review-required","time":"2026-10-11T14:01:00Z"}'}
    $r=Invoke-MutPreparationSqlRepair -Instance CAESARCOMPDB
    Assert-True $r.Verified;Assert-Equal 0 $r.ExitCode
    Assert-Equal 'Repair-MutSqlLegacyAcl.ps1|-Instance CAESARCOMPDB' ($captured -join ',')
}
Case 'Scoped SQL adapter rejects stale success status' {
    function Start-MutPreparationChild {param($Name,$Arguments) return [pscustomobject]@{ExitCode=0;StartedUtc='2026-10-11T14:00:00Z';Error=''}}
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding) return '{"stage":"applied-review-required","time":"2026-10-11T13:00:00Z"}'}
    Assert-True (!(Invoke-MutPreparationSqlRepair MUT3).Verified)
}
Case 'Scoped SQL adapter ignores stale status after a failing helper' {
    function Start-MutPreparationChild {param($Name,$Arguments) return [pscustomobject]@{ExitCode=1;StartedUtc='2026-10-11T14:00:00Z';Error='failure'}}
    function Get-Content {throw 'Must not read status after failed child.'}
    $r=Invoke-MutPreparationSqlRepair MUT3;Assert-True (!$r.Verified);Assert-Equal 1 $r.ExitCode
}
Case 'Scoped SQL adapter rejects arbitrary instance names before child launch' {
    function Start-MutPreparationChild {throw 'No child permitted.'}
    Assert-Throws {Invoke-MutPreparationSqlRepair UnknownInstance}
}
function Invoke-EvidenceFixture([string]$Scenario='Ready'){
    $effects=New-Object 'System.Collections.Generic.List[string]'
    $mockCore=New-Module -ScriptBlock {
        function Assert-MutExtractedTree {param($Target,$Manifest) $Manifest.Calls.Add('tree');if($Target -cne 'C:\MUT-Install\ps2DLC\ps2DLC'){throw 'Incorrect package path.'};if($Manifest.Reject){throw 'Tree mismatch.'}}
    }
    function Test-Path {param($LiteralPath) if($Scenario -eq 'MissingArchive' -and $LiteralPath -like '*ps2DLC.zip'){return $false};if($Scenario -eq 'MissingLogs' -and $LiteralPath -like '*repair-status.json'){return $false};return $true}
    function Get-MutZipManifest {
        param($ArchivePath,$ExpectedHash,$ExpectedRoot)
        $effects.Add('archive');Assert-Equal 'C:\MUT-Install\ps2DLC.zip' $ArchivePath
        Assert-Equal 'D9812E7BE1F72FF49D73F3179E207AA0000852D9D0EFD92455AD376FAD5D9B7C' $ExpectedHash;Assert-Equal 'ps2DLC' $ExpectedRoot
        if($Scenario -eq 'BadArchive'){throw 'Hash mismatch.'};return [pscustomobject]@{Calls=$effects;Reject=($Scenario -eq 'BadTree')}
    }
    function Get-Module {param($Name) Assert-Equal 'Mut-OneClick.Core' $Name;return $mockCore}
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding) return '{"logs":"C:\\MUT-Install\\repair-logs\\20261011-220000"}'}
    function Test-MutPrerequisites {param($PackageRoot,$RepairLogRoot) $effects.Add('prerequisites');Assert-Equal 'C:\MUT-Install\ps2DLC\ps2DLC' $PackageRoot;Assert-Equal 'C:\MUT-Install\repair-logs\20261011-220000' $RepairLogRoot;return [pscustomobject]@{Passed=$true}}
    $result=$null;$failure=$null
    try{$result=Get-MutPreparationEvidence -RepairLogRoot $(if($Scenario -eq 'OutsideLogs'){'C:\Elsewhere\logs'}else{''})}catch{$failure=$_.Exception}
    return [pscustomobject]@{Result=$result;Error=$failure;Calls=@($effects.ToArray())}
}
Case 'Evidence adapter verifies pinned archive and exact tree before current system evidence' {
    $r=Invoke-EvidenceFixture;Assert-NoError $r;Assert-True $r.Result.Passed
    Assert-Equal 'archive,tree,prerequisites' ($r.Calls -join ',')
}
Case 'Missing archive cannot produce a successful Check result' {
    $r=Invoke-EvidenceFixture MissingArchive;Assert-NoError $r;Assert-True (!$r.Result.Passed);Assert-Equal 0 $r.Calls.Count
}
Case 'Verified package without prior repair logs is not accepted as ready' {
    $r=Invoke-EvidenceFixture MissingLogs;Assert-NoError $r;Assert-True (!$r.Result.Passed)
    Assert-Equal 'archive,tree' ($r.Calls -join ',')
}
foreach($badSource in @('BadArchive','BadTree','OutsideLogs')){
    Case ($badSource+' blocks current-system evidence acceptance') {
        $r=Invoke-EvidenceFixture $badSource;Assert-True ($null -ne $r.Error)
        Assert-NoCalls $r @('prerequisites')
    }
}
foreach($busyName in @('MUT3INSTALL.exe','DPInst.exe','msiexec.exe','setup.exe')){
    Case ('Busy inventory blocks '+$busyName) {
        function Get-CimInstance {param($ClassName) return [pscustomobject]@{Name=$busyName;ProcessId=2147483646;CommandLine=$null;CreationDate=[datetime]'2026-10-11'}}
        Assert-Equal 1 @(Get-MutPreparationBusy).Count
    }
}
Case 'Busy inventory blocks official loader running outside the fixed directory' {
    function Get-CimInstance {param($ClassName) return [pscustomobject]@{Name='powershell.exe';ProcessId=2147483646;CommandLine='powershell.exe -File "C:\Elsewhere\loadGAC.ps1"';CreationDate=[datetime]'2026-10-11'}}
    Assert-Equal 1 @(Get-MutPreparationBusy).Count
}
Case 'Busy inventory allows an unrelated process and excludes itself' {
    function Get-CimInstance {param($ClassName) @([pscustomobject]@{Name='notepad.exe';ProcessId=2147483646;CommandLine='notepad.exe';CreationDate=[datetime]'2026-10-11'},[pscustomobject]@{Name='powershell.exe';ProcessId=$PID;CommandLine='powershell.exe -File "C:\Elsewhere\loadGAC.ps1"';CreationDate=[datetime]'2026-10-11'})}
    Assert-Equal 0 @(Get-MutPreparationBusy).Count
}
function Invoke-PendingFixture([string]$Scenario){
    function Test-Path {param($LiteralPath) return ($LiteralPath -like '*prerequisite-state.json' -or ($Scenario -eq 'WindowsPending' -and $LiteralPath -like '*RebootPending'))}
    function Get-ItemProperty {param($LiteralPath) return [pscustomobject]@{PendingFileRenameOperations=@()}}
    function Get-CimInstance {param($ClassName) return [pscustomobject]@{LastBootUpTime=[datetime]::Parse($(if($Scenario -eq 'LaterBoot'){'2026-10-11T15:00:00Z'}else{'2026-10-11T14:00:00Z'})).ToUniversalTime()}}
    function Get-Content {
        param($LiteralPath,[switch]$Raw,$Encoding)
        return ([pscustomobject]@{SchemaVersion=1;Machine=$(if($Scenario -eq 'ForeignMachine'){'OTHER'}else{$env:COMPUTERNAME});Phase=$(if($Scenario -eq 'UnknownPhase'){'Unknown'}elseif($Scenario -eq 'Ready'){'Ready'}else{'AwaitingReboot'});BootUtc='2026-10-11T14:00:00Z'}|ConvertTo-Json)
    }
    return Test-MutPreparationPending
}
Case 'Same actual boot keeps prerequisite continuation at reboot gate' {Assert-True (Invoke-PendingFixture SameBoot)}
Case 'A later actual boot permits prerequisite preparation to resume' {Assert-True (!(Invoke-PendingFixture LaterBoot))}
Case 'Windows pending operations take precedence over saved ready progress' {Assert-True (Invoke-PendingFixture WindowsPending)}
Case 'Ready prerequisite state does not force an unnecessary reboot' {Assert-True (!(Invoke-PendingFixture Ready))}
Case 'Foreign-machine prerequisite progress is rejected' {Assert-Throws {Invoke-PendingFixture ForeignMachine}}
Case 'Unknown prerequisite phase is rejected' {Assert-Throws {Invoke-PendingFixture UnknownPhase}}
Case 'Repair timeout retains child and does not invoke process termination or retry' {
    $calls=New-Object 'System.Collections.Generic.List[string]'
    function Assert-MutPreparationHelpers {}
    function Get-MutPreparationBusy {return @()}
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
        $calls.Add('start');Assert-Equal 'Hidden' $WindowStyle
        $p=[pscustomobject]@{Handle=0;Calls=$calls}
        $p|Add-Member ScriptMethod WaitForExit {param($Milliseconds) $this.Calls.Add('wait');if($Milliseconds -ne 1200000){throw 'Incorrect timeout.'};return $false}
        return $p
    }
    function Stop-Process {throw 'The retained child must not be terminated.'}
    $savedRunRoot=$script:RunRoot;$script:RunRoot='C:\MUT-Install\prerequisite-logs\fixture'
    try{Assert-Throws {Start-MutPreparationChild -Name Repair-MutPrerequisites.ps1}}finally{$script:RunRoot=$savedRunRoot}
    Assert-Equal 'start,wait' ($calls -join ',')
}
Case 'Public launcher uses native PowerShell and selects preparation only' {
    $cmd=Get-Content -LiteralPath (Join-Path $project 'Install-Prerequisites.cmd') -Raw
    Assert-True ($cmd.Contains('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'))
    Assert-True ($cmd.Contains('%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe'))
    Assert-True ($cmd.Contains('Prepare-MutPrerequisites.ps1" -Mode Prepare'))
    Assert-True ($cmd -notmatch '(?i)Install-Mut\.ps1|MUT3_Install\.bat|UNINST\.BAT|Start-MutInstallWithSqlAcl')
}
Case 'Old public CMD is an alias to prerequisite-only entry with propagated exit code' {
    $cmd=Get-Content -LiteralPath (Join-Path $project 'Install-MUT.cmd') -Raw
    Assert-True ($cmd.Contains('call "%~dp0Install-Prerequisites.cmd"'))
    Assert-True ($cmd.Contains('exit /b %ERRORLEVEL%'))
    Assert-True ($cmd -notmatch '(?i)Install-Mut\.ps1|MUT3_Install\.bat|UNINST\.BAT|Start-MutInstallWithSqlAcl')
}
Case 'Legacy Auto PowerShell entry delegates before reaching old installation code' {
    $legacyAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'scripts\Install-Mut.ps1'),[ref]$null,[ref]$null)
    $first=@($legacyAst.EndBlock.Statements)[0]
    Assert-True ($first -is [Management.Automation.Language.IfStatementAst])
    Assert-True ($first.Clauses[0].Item1.Extent.Text.Contains("!`$LibraryOnly -and `$Mode -eq 'Auto'"))
    Assert-True ($first.Extent.Text.Contains("Prepare-MutPrerequisites.ps1"))
    Assert-True ($first.Extent.Text.Contains("Mode='Prepare';Release=`$Release"))
    Assert-True ($first.Extent.Text.Contains('exit $LASTEXITCODE'))
}
Case 'Frontend child call sites are limited to prerequisite and ACL repair helpers' {
    $childCalls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-MutPreparationChild'},$true))
    $names=@($childCalls|ForEach-Object {($_.CommandElements|Where-Object {$_ -is [Management.Automation.Language.StringConstantExpressionAst]}|Select-Object -Skip 1 -First 1).Value}|Sort-Object)
    Assert-Equal 'Repair-MutPrerequisites.ps1,Repair-MutSqlLegacyAcl.ps1' ($names -join ',')
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    foreach($forbidden in @('Start-Service','Stop-Service','Restart-Service','Invoke-MutAuto','Invoke-MutFailedCleanup','Invoke-MutOriginalUninstall','Start-MutReviewedUpgradeUninstall','Invoke-MutHealthyUpgrade')){Assert-True ($forbidden -notin $commands) ('Forbidden command: '+$forbidden)}
}

$failed=@($script:cases|Where-Object {!$_.Passed})
$summary=[ordered]@{Total=$script:cases.Count;Passed=$script:cases.Count-$failed.Count;Failed=$failed.Count;Failures=@($failed);PowerShell=$PSVersionTable.PSVersion.ToString();SystemMutations=$false}
$json=$summary|ConvertTo-Json -Depth 6
if($ResultPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),$json,(New-Object Text.UTF8Encoding($true)))}
$json
if($failed.Count){exit 1};exit 0
