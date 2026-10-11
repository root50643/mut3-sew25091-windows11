[CmdletBinding()]
param()
# Isolated state-machine tests. Every clock, file, process, SQL and UI effect is
# injected; this file never starts a real installer or touches installed data.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Use Windows PowerShell 5.1.'}
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Mut-Upgrade.Workflow.psm1') -Force
$script:results=New-Object 'System.Collections.Generic.List[object]'
$oldHash='1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03'
$newHash='A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8'
function Assert-True($Value,[string]$Message='Expected true'){if(!$Value){throw $Message}}
function Assert-Equal($Expected,$Actual){if($Expected -cne $Actual){throw ('Expected [{0}], got [{1}]' -f $Expected,$Actual)}}
function Case([string]$Name,[scriptblock]$Action){
    try{&$Action;$script:results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error='' });Write-Host ('PASS '+$Name)}
    catch{$script:results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function New-Fixture {
    $f=[pscustomobject]@{State=$null;Existing=[pscustomobject]@{Phase='Completed'};Now=[datetime]::Parse('2026-10-11T01:00:00Z').ToUniversalTime();Boot='2026-10-11T00:00:00.0000000Z';Pending=$false;Idle=$true;Confirmed=$true;Healthy=$true;SourceValid=$true;OldStateValid=$true;ArchiveValid=$true;BackupValid=$true;SqlValid=$true;Uninstalled=$true;ChildStatus='Ended';EndChildAfterSleep=$false;SummaryStatus='Complete';Hash=('A'*64);HashChanges=$false;ReadFails=$false;Effects=(New-Object 'System.Collections.Generic.List[string]');Operations=$null}
    $f.Operations=@{
        Read={param($Path) if($f.ReadFails){throw 'invalid JSON'};return $f.State}.GetNewClosure()
        Save={param($State) $f.State=$State|ConvertTo-Json -Depth 12|ConvertFrom-Json;$f.Effects.Add('save:'+$State.Phase)}.GetNewClosure()
        Now={return $f.Now}.GetNewClosure()
        Boot={return $f.Boot}.GetNewClosure()
        Pending={return $f.Pending}.GetNewClosure()
        Idle={return $f.Idle}.GetNewClosure()
        ValidateOldState={param($State) $f.Effects.Add('oldstate');if(!$f.OldStateValid){throw 'old state not completed'}}.GetNewClosure()
        VerifyOld={$f.Effects.Add('verifyold');if(!$f.Healthy){throw 'source not healthy'}}.GetNewClosure()
        PrepareTarget={$f.Effects.Add('targetmedia')}.GetNewClosure()
        PrepareOld={$f.Effects.Add('oldmedia')}.GetNewClosure()
        Confirm={$f.Effects.Add('confirm');return $f.Confirmed}.GetNewClosure()
        ArchiveState={param($Old) $f.Effects.Add('archive');return [pscustomobject]@{Path=$(if($Old){'fixture-old-state'}else{''});Hash=$(if($Old){'B'*64}else{''})}}.GetNewClosure()
        AssertStateArchive={param($State) $f.Effects.Add('assertarchive');if(!$f.ArchiveValid){throw 'old state changed'}}.GetNewClosure()
        StartBackup={$f.Effects.Add('backup');return [pscustomobject]@{Pid=42;CreatedUtc=$f.Now.ToString('o');Output='fixture.out';Error='fixture.err'}}.GetNewClosure()
        BackupStatus={param($Child) $f.Effects.Add('childstatus');return $f.ChildStatus}.GetNewClosure()
        ReadBackupSummary={param($Child) $f.Effects.Add('summary');return [pscustomobject]@{Status=$f.SummaryStatus;Manifest='fixture-manifest'}}.GetNewClosure()
        Hash={param($Path) $f.Effects.Add('hash');if($f.HashChanges){$f.Hash='C'*64};return $f.Hash}.GetNewClosure()
        AssertBackup={param($Path,$VerifySource) $f.Effects.Add('assertbackup:'+$VerifySource);if(!$f.BackupValid){throw 'backup corrupt'};if($VerifySource -and !$f.SourceValid){throw 'source changed'};return [pscustomobject]@{Status='Complete'}}.GetNewClosure()
        StartUninstall={$f.Effects.Add('uninstall')}.GetNewClosure()
        Uninstalled={return $f.Uninstalled}.GetNewClosure()
        AssertSql={param($Manifest) $f.Effects.Add('sql');if(!$f.SqlValid){throw 'unknown SQL identity'}}.GetNewClosure()
        Sleep={param($Seconds) $f.Now=$f.Now.AddSeconds($Seconds);if($f.EndChildAfterSleep){$f.ChildStatus='Ended'}}.GetNewClosure()
        Notice={param($Text) $f.Effects.Add('notice')}.GetNewClosure()
    }
    return $f
}
function Invoke-Fixture($F){return (Invoke-MutHealthyUpgrade -StatePath 'fixture-state' -ExistingState $F.Existing -SourceHash $oldHash -TargetHash $newHash -Machine 'FIXTURE' -Operations $F.Operations)}
function Assert-Review($F){
    $caught=$null
    try{$null=Invoke-Fixture $F}catch{$caught=$_.Exception}
    Assert-True ($null -ne $caught) 'Expected a controlled review error'
    Assert-Equal 2 $caught.Data['MutExitCode']
}
function Count-Effect($F,[string]$Name){return @($F.Effects|Where-Object {$_ -ceq $Name}).Count}
function Make-BackupReady($F){$F.Pending=$true;$result=Invoke-Fixture $F;Assert-Equal 3010 $result.ExitCode;Assert-Equal 'BackupReady' $F.State.Phase;$F.Effects.Clear()}
function Advance-Boot($F){$F.Now=$F.Now.AddHours(1);$F.Boot=$F.Now.ToString('o');$F.Now=$F.Now.AddMinutes(1);$F.Pending=$false}

Case 'Cancelled confirmation writes no progress and launches nothing' {
    $f=New-Fixture;$f.Confirmed=$false;$r=Invoke-Fixture $f
    Assert-Equal 1223 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'archive');Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall');Assert-True (!$f.State)
}
Case 'Unhealthy source never starts a backup' {$f=New-Fixture;$f.Healthy=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup');Assert-True (!$f.State)}
Case 'Incomplete old state is rejected before backup or metadata writes' {$f=New-Fixture;$f.OldStateValid=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'archive');Assert-True (!$f.State)}
Case 'Fresh reviewed upgrade backs up then uninstalls and requires reboot' {
    $f=New-Fixture;$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 'AwaitingReboot' $f.State.Phase
    Assert-Equal 1 (Count-Effect $f 'backup');Assert-Equal 1 (Count-Effect $f 'uninstall')
    Assert-True ($f.Effects.IndexOf('backup') -lt $f.Effects.IndexOf('uninstall'))
    Assert-Equal ('A'*64) $f.State.BackupManifestSha256
    Assert-True ($f.Now -ge [datetime]::Parse('2026-10-11T01:00:10Z').ToUniversalTime()) 'Uninstall observation did not stay idle for ten seconds'
}
Case 'Healthy live old install without previous state does not invent confirmations' {
    $f=New-Fixture;$f.Existing=$null;$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-True (!$f.State.HadOriginalState);Assert-Equal '' $f.State.OriginalStateArchive
}
Case 'Failed backup summary never uninstalls' {$f=New-Fixture;$f.SummaryStatus='Failed';Assert-Review $f;Assert-Equal 'ReviewRequired' $f.State.Phase;Assert-Equal 0 (Count-Effect $f 'uninstall')}
Case 'Corrupt backup never uninstalls' {$f=New-Fixture;$f.BackupValid=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')}
Case 'Changed source during backup stops before uninstall' {$f=New-Fixture;$f.SourceValid=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')}
Case 'Pending reboot allows backup but preserves BackupReady without uninstall' {
    $f=New-Fixture;Make-BackupReady $f
    Assert-True (!!$f.State.PreUninstallRebootBootUtc);Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Cleared reboot flag without actual reboot still cannot uninstall' {
    $f=New-Fixture;Make-BackupReady $f;$f.Pending=$false;$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Actual pre-uninstall reboot resumes verified backup and uninstalls once' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 'AwaitingReboot' $f.State.Phase;Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 1 (Count-Effect $f 'uninstall')
}
Case 'BackupReady with a running application cannot start UNINST or a second backup' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$f.Idle=$false;Assert-Review $f
    Assert-Equal 0 (Count-Effect $f 'uninstall');Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 'ReviewRequired' $f.State.Phase
}
Case 'New pending flag after pre-uninstall reboot still requires another real boot' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$f.Pending=$true;$null=Invoke-Fixture $f;$f.Pending=$false;$f.Effects.Clear();$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Same boot cannot progress to target installation' {
    $f=New-Fixture;$null=Invoke-Fixture $f;$f.Effects.Clear();$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'sql');Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Reboot plus preserved SQL validation permits target state handoff' {
    $f=New-Fixture;$null=Invoke-Fixture $f;$f.Effects.Clear();Advance-Boot $f;$r=Invoke-Fixture $f
    Assert-Equal 0 $r.ExitCode;Assert-True $r.ReadyForInstall;Assert-Equal 'ReadyForInstall' $f.State.Phase
    Assert-Equal 1 (Count-Effect $f 'sql');Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall');Assert-Equal ('A'*64) $r.BackupManifestSha256
    Assert-Equal 0 (Count-Effect $f 'assertbackup:True')
}
Case 'New pending flag after uninstall reboot cannot be cleared without a new boot' {
    $f=New-Fixture;$null=Invoke-Fixture $f;Advance-Boot $f;$f.Pending=$true;$null=Invoke-Fixture $f;$f.Pending=$false;$f.Effects.Clear();$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'sql')
}
Case 'Manifest change during initial verification never uninstalls' {
    $f=New-Fixture
    $f.Operations.AssertBackup={param($Path,$VerifySource) $f.Hash='C'*64;return [pscustomobject]@{Status='Complete'}}.GetNewClosure()
    Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Unknown or missing preserved SQL blocks target handoff' {
    $f=New-Fixture;$null=Invoke-Fixture $f;Advance-Boot $f;$f.SqlValid=$false;Assert-Review $f;Assert-Equal 'ReviewRequired' $f.State.Phase
}
Case 'Old state changed after backup prevents uninstall' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$f.ArchiveValid=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Pinned manifest change after backup prevents uninstall' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$f.Hash='C'*64;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Pinned manifest change after reboot prevents target handoff' {
    $f=New-Fixture;$null=Invoke-Fixture $f;Advance-Boot $f;$f.Hash='C'*64;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'sql')
}
Case 'BackupReady source modification requires review, not a fresh backup' {
    $f=New-Fixture;Make-BackupReady $f;Advance-Boot $f;$f.SourceValid=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Live backup on resume is monitored without a second launch' {
    $f=New-Fixture;Make-BackupReady $f;$f.State.Phase='BackingUp';$f.ChildStatus='Alive';$f.EndChildAfterSleep=$true
    $r=Invoke-Fixture $f;Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'backup');Assert-True ((Count-Effect $f 'childstatus') -ge 2)
}
Case 'Missing backup identity requires review without replay' {$f=New-Fixture;Make-BackupReady $f;$f.State.Phase='BackingUp';$f.State.BackupChild=$null;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup')}
Case 'Reused PID or unknown backup identity requires review' {$f=New-Fixture;Make-BackupReady $f;$f.State.Phase='BackingUp';$f.ChildStatus='Unknown';Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup')}
Case 'Backup timeout preserves process and stops' {$f=New-Fixture;Make-BackupReady $f;$f.State.Phase='BackingUp';$f.ChildStatus='Alive';$f.Now=$f.Now.AddHours(1);Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup')}
Case 'Uninstalling checkpoint never replays UNINST' {
    $f=New-Fixture;$null=Invoke-Fixture $f;$f.State.Phase='Uninstalling';$f.Effects.Clear();$r=Invoke-Fixture $f
    Assert-Equal 3010 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'uninstall');Assert-Equal 0 (Count-Effect $f 'backup')
}
Case 'Uninstall leftovers stop with no SQL cleanup' {$f=New-Fixture;$f.Uninstalled=$false;Assert-Review $f;Assert-Equal 'ReviewRequired' $f.State.Phase;Assert-Equal 0 (Count-Effect $f 'sql')}
Case 'Uninstall timed out with busy process does not replay or kill' {
    $f=New-Fixture;$null=Invoke-Fixture $f;$f.State.Phase='Uninstalling';$f.Effects.Clear();$f.Now=$f.Now.AddHours(1);$f.Idle=$false;Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'uninstall')
}
Case 'Completed uninstall can reconcile after timeout and a later reboot' {
    $f=New-Fixture;$null=Invoke-Fixture $f;$f.State.Phase='Uninstalling';$f.Effects.Clear();Advance-Boot $f;$r=Invoke-Fixture $f
    Assert-Equal 0 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'uninstall');Assert-True $r.ReadyForInstall
}
Case 'ReadyForInstall resumes without backup or uninstall' {
    $f=New-Fixture;$null=Invoke-Fixture $f;Advance-Boot $f;$null=Invoke-Fixture $f;$f.Effects.Clear();$r=Invoke-Fixture $f
    Assert-Equal 0 $r.ExitCode;Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall')
}
foreach($damage in @('ForeignMachine','ForeignHash','MissingField','UnknownPhase','WrongSchema')){
    Case ('Untrusted checkpoint remains byte-equivalent: '+$damage) {
        $f=New-Fixture;Make-BackupReady $f
        switch($damage){ForeignMachine{$f.State.Machine='OTHER'}ForeignHash{$f.State.TargetMediaHash='C'*64}MissingField{$f.State.PSObject.Properties.Remove('BackupManifestSha256')}UnknownPhase{$f.State.Phase='Random'}WrongSchema{$f.State.SchemaVersion=2}}
        $before=$f.State|ConvertTo-Json -Depth 12;Assert-Review $f;Assert-Equal $before ($f.State|ConvertTo-Json -Depth 12);Assert-Equal 0 @($f.Effects|Where-Object {$_ -like 'save:*'}).Count
    }
}
Case 'Damaged JSON does not create or rewrite a checkpoint' {$f=New-Fixture;$f.ReadFails=$true;Assert-Review $f;Assert-True (!$f.State);Assert-Equal 0 @($f.Effects|Where-Object {$_ -like 'save:*'}).Count}
Case 'ReviewRequired does not repeat backup or uninstall' {$f=New-Fixture;$f.SummaryStatus='Failed';Assert-Review $f;$f.Effects.Clear();Assert-Review $f;Assert-Equal 0 (Count-Effect $f 'backup');Assert-Equal 0 (Count-Effect $f 'uninstall')}
$failed=@($script:results|Where-Object {!$_.Passed})
[ordered]@{Total=$script:results.Count;Passed=$script:results.Count-$failed.Count;Failed=$failed.Count;Failures=$failed}|ConvertTo-Json -Depth 4
if($failed.Count){exit 1}
exit 0
