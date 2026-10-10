[CmdletBinding()]
param(
    [ValidateSet('MUT3','CAESARCOMPDB')][string]$Instance='MUT3',
    [switch]$Restore,
    [string]$BackupPath
)
$ErrorActionPreference = 'Stop'
$taskRoot = 'C:\MUT-Install'
$Instance=$Instance.ToUpperInvariant()
$logRoot = Join-Path $taskRoot ('sql-acl-repair-logs\' + $Instance + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$statusPath = Join-Path $taskRoot ('sql-acl-repair-status-' + $Instance + '.json')
$serviceName = 'MSSQL$' + $Instance
$serviceSids = @{
    MUT3='S-1-5-80-2329205841-2183319202-1762315884-1906354531-1149104739'
    CAESARCOMPDB='S-1-5-80-1730965570-1020681421-1004574069-504458456-3145505875'
}
$expectedSid = $serviceSids[$Instance]
$rootKey = 'SOFTWARE\Microsoft\Microsoft SQL Server\' + $Instance + '\MSSQLServer\SuperSocketNetLib'
$keyPaths = @($rootKey, ($rootKey+'\Tcp'), ($rootKey+'\Np'))
$section = [Security.AccessControl.AccessControlSections]::Access
$rights = [Security.AccessControl.RegistryRights]::ReadKey -bor [Security.AccessControl.RegistryRights]::WriteKey
$bases = @(); $keys = @(); $record = $null; $recordPath = $null; $exitCode = 1; $mutated = $false
function Save-Json($value, [string]$path) {
    $value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}
function Save-Status([string]$stage, [string]$message) {
    Save-Json ([ordered]@{stage=$stage; instance=$Instance; serviceName=$serviceName; message=$message; time=(Get-Date).ToString('o'); logs=$logRoot; backup=$recordPath; exitCode=$exitCode}) $statusPath
}
function Read-Dacl($key) { $key.GetAccessControl($section).GetSecurityDescriptorSddlForm($section) }
function Read-Owner($key) { $key.GetAccessControl([Security.AccessControl.AccessControlSections]::Owner).GetOwner([Security.Principal.SecurityIdentifier]).Value }
function Get-ServiceRules($acl) { @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq $expectedSid}) }
function Assert-ReferenceGrant($key) {
    $rules = @(Get-ServiceRules ($key.GetAccessControl($section)))
    if (@($rules | Where-Object {$_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny}).Count) { throw 'The 32-bit reference contains a service SID deny ACE.' }
    $grant = @($rules | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        (([int]$_.RegistryRights -band [int]$rights) -eq [int]$rights) -and
        (($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0) -and
        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None
    })
    if (!$grant.Count) { throw 'The matching 32-bit key does not grant inheritable ReadKey/WriteKey to the expected service SID.' }
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or ![Environment]::Is64BitProcess) { throw 'Run this helper in elevated 64-bit Windows PowerShell.' }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
    if ($Restore -and !$BackupPath) { throw '-Restore requires -BackupPath.' }
    if (!$Restore -and $BackupPath) { throw '-BackupPath is accepted only with -Restore.' }
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $service = Get-CimInstance Win32_Service | Where-Object {$_.Name -eq $serviceName}
    if (!$service -or ($service.StartName -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE') { throw ('The expected '+$Instance+' service with NETWORK SERVICE account was not found.') }
    $account = New-Object Security.Principal.NTAccount('NT SERVICE', $serviceName)
    $sid = $account.Translate([Security.Principal.SecurityIdentifier])
    if ($sid.Value -ne $expectedSid) { throw 'The service SID does not match the selected reviewed instance.' }
    $base64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $base32 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    $bases = @($base64,$base32)
    foreach ($path in $keyPaths) {
        $key = $base64.OpenSubKey($path,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,([Security.AccessControl.RegistryRights]::ReadKey -bor [Security.AccessControl.RegistryRights]::ChangePermissions))
        if (!$key) { throw ('The existing native key was not found: '+$path) }
        $keys += $key
        if (!$Restore) {
            if (@(Get-ServiceRules ($key.GetAccessControl($section)) | Where-Object {$_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny}).Count) { throw 'A native key contains a service SID deny ACE; no ACL changes were attempted.' }
            $reference = $base32.OpenSubKey($path)
            if (!$reference) { throw ('The 32-bit reference key was not found: '+$path) }
            try { Assert-ReferenceGrant $reference } finally { $reference.Dispose() }
        }
    }
    if ($Restore) {
        $recordPath = (Resolve-Path -LiteralPath $BackupPath).Path
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($record.schemaVersion -ne 1 -or $record.machine -ine $env:COMPUTERNAME -or $record.view -ne 'Registry64' -or $record.serviceName -cne $serviceName -or $record.serviceSid -ne $expectedSid -or @($record.keys).Count -ne 3) { throw 'The backup does not identify this machine, instance and reviewed three-key scope.' }
        for ($i=0;$i -lt 3;$i++) {
            $entry=$record.keys[$i]
            if ($entry.path -cne $keyPaths[$i] -or !$entry.originalDaclSddl -or !$entry.patchedDaclSddl) { throw 'The backup scope or DACL is invalid.' }
            if ((Read-Dacl $keys[$i]) -cne $entry.patchedDaclSddl) { throw ('Restore refused: the current DACL has changed: '+$entry.path) }
            if ((Read-Owner $keys[$i]) -cne $entry.ownerSid) { throw 'Restore refused: a key owner has changed.' }
        }
        for ($i=0;$i -lt 3;$i++) {
            $acl = $keys[$i].GetAccessControl($section)
            $acl.SetSecurityDescriptorSddlForm($record.keys[$i].originalDaclSddl,$section)
            $keys[$i].SetAccessControl($acl)
        }
        for ($i=0;$i -lt 3;$i++) {
            if ((Read-Dacl $keys[$i]) -cne $record.keys[$i].originalDaclSddl -or (Read-Owner $keys[$i]) -cne $record.keys[$i].ownerSid) { throw 'Restoration verification failed; inspect the saved backup.' }
        }
        $exitCode=0
        Save-Status 'restored' 'The original DACLs were restored. Registry values, service account and service state were not changed.'
    } else {
        $recordPath=Join-Path $logRoot 'acl-backup.json'
        $entries=@()
        for ($i=0;$i -lt 3;$i++) { $entries += [pscustomobject]@{path=$keyPaths[$i]; ownerSid=(Read-Owner $keys[$i]); originalDaclSddl=(Read-Dacl $keys[$i]); patchedDaclSddl=$null} }
        $record=[pscustomobject]@{schemaVersion=1; machine=$env:COMPUTERNAME; instance=$Instance; view='Registry64'; serviceName=$serviceName; serviceSid=$expectedSid; created=(Get-Date).ToString('o'); state='prepared'; keys=$entries}
        Save-Json $record $recordPath
        & (Join-Path $env:SystemRoot 'System32\reg.exe') export ('HKLM\'+$rootKey) (Join-Path $logRoot 'legacy-native-before.reg') /y | Out-File (Join-Path $logRoot 'export-result.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Registry value export failed; no ACL changes were attempted.' }
        foreach ($key in $keys) {
            $acl=$key.GetAccessControl($section)
            if (@(Get-ServiceRules $acl | Where-Object {$_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny}).Count) { throw 'The native key contains a service SID deny ACE; refusing to change it.' }
            $rule=New-Object Security.AccessControl.RegistryAccessRule($sid,$rights,[Security.AccessControl.InheritanceFlags]::ContainerInherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
            $mutated=$true
            $key.SetAccessControl($acl)
        }
        for ($i=0;$i -lt 3;$i++) {
            $record.keys[$i].patchedDaclSddl=Read-Dacl $keys[$i]
            if ((Read-Owner $keys[$i]) -cne $record.keys[$i].ownerSid) { throw 'A key owner changed unexpectedly.' }
            Assert-ReferenceGrant $keys[$i]
        }
        $record.state='applied'
        Save-Json $record $recordPath
        $exitCode=0
        Save-Status 'applied-review-required' ('Added only '+$Instance+' service ReadKey/WriteKey ACEs to the three native legacy protocol keys. SQL was not started.')
    }
} catch {
    $failure=$_.Exception.Message
    if ($mutated -and $record -and !$Restore) {
        try {
            for ($i=0;$i -lt $keys.Count;$i++) { $record.keys[$i].patchedDaclSddl=Read-Dacl $keys[$i] }
            $record.state='partial-failure'
            Save-Json $record $recordPath
        } catch { $failure += ' Could not record the resulting DACLs; manual backup review is required.' }
    }
    $exitCode=1
    try { Save-Status 'failed' $failure } catch { Write-Error $failure -ErrorAction Continue }
    Write-Output ('FAILED: '+$failure)
} finally {
    foreach($key in $keys) { $key.Dispose() }
    foreach($base in $bases) { $base.Dispose() }
    if(Test-Path -LiteralPath $logRoot) { $exitCode | Set-Content -LiteralPath (Join-Path $logRoot 'exit-code.txt') -Encoding ASCII }
}
exit $exitCode
