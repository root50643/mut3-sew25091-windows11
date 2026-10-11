[CmdletBinding()]
param([ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW25091')
$ErrorActionPreference = 'Stop'
$taskRoot = 'C:\MUT-Install'
$packageRoot = Join-Path $taskRoot 'ps2DLC\ps2DLC'
$logRoot = Join-Path $taskRoot ('repair-logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$statusPath = Join-Path $taskRoot 'repair-status.json'
function Save-Status([string]$stage, [string]$message) {
    [ordered]@{stage=$stage; message=$message; time=(Get-Date).ToString('o'); logs=$logRoot} |
        ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
$policySnapshots = @()
$policyRestoreRequired = $false
$transcribing = $false
$exitCode = 1
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required.'
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Start this wrapper in 64-bit Windows PowerShell.' }
    Start-Transcript -LiteralPath (Join-Path $logRoot 'repair-transcript.txt') | Out-Null
    $transcribing = $true
    Save-Status 'checking' 'Checking installer state and prerequisite files.'
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -match '^C:\\MUT-Install\\(?:SEW25091|SEW26061-00)\\' -and
        $_.Name -match '^(setup|MUT3INSTALL|MT3NNSTLL|Mut3Check)\.exe$'
    })
    if ($active.Count -gt 0) { throw 'A MUT installer is still running. Close this failed installation before retrying prerequisite repair.' }
    $archiveHash = (Get-FileHash -LiteralPath (Join-Path $taskRoot 'ps2DLC.zip') -Algorithm SHA256).Hash
    if ($archiveHash -ne 'D9812E7BE1F72FF49D73F3179E207AA0000852D9D0EFD92455AD376FAD5D9B7C') {
        throw 'The downloaded Microsoft archive no longer matches the reviewed package.'
    }
    $officialScript = Join-Path $packageRoot 'loadGAC.ps1'
    if (-not (Test-Path -LiteralPath $officialScript)) { throw 'The original Microsoft loadGAC.ps1 is missing.' }
    Get-ComputerInfo -Property WindowsProductName,WindowsVersion,OsVersion,OsBuildNumber | Format-List
    Get-ExecutionPolicy -List | Format-Table -AutoSize
    foreach ($viewName in @('Registry64','Registry32')) {
        $view = [Microsoft.Win32.RegistryView]::$viewName
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try {
            foreach ($shellName in @('Microsoft.PowerShell','ScriptedDiagnostics')) {
                $keyPath = 'SOFTWARE\Microsoft\PowerShell\1\ShellIds\' + $shellName
                $key = $base.OpenSubKey($keyPath)
                try {
                    $exists = $null -ne $key -and $key.GetValueNames() -contains 'ExecutionPolicy'
                    $policySnapshots += [pscustomobject]@{
                        view=$viewName; key=$keyPath; exists=$exists
                        value=$(if($exists){$key.GetValue('ExecutionPolicy')}else{$null})
                        kind=$(if($exists){$key.GetValueKind('ExecutionPolicy').ToString()}else{$null})
                    }
                } finally { if($null -ne $key){$key.Dispose()} }
            }
        } finally { $base.Dispose() }
    }
    $policySnapshots | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logRoot 'policy-values-before.json') -Encoding UTF8
    & reg.exe export 'HKLM\SOFTWARE\Microsoft\PowerShell' (Join-Path $logRoot 'powershell-64-before.reg') /y
    if($LASTEXITCODE -ne 0){throw 'Could not back up native PowerShell registry.'}
    & reg.exe export 'HKLM\SOFTWARE\WOW6432Node\Microsoft\PowerShell' (Join-Path $logRoot 'powershell-32-before.reg') /y
    if($LASTEXITCODE -ne 0){throw 'Could not back up 32-bit PowerShell registry.'}
    $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
    $feature | Format-List FeatureName,State
    if($feature.State -ne 'Enabled') {
        Save-Status 'enabling-netfx3' 'Enabling the Windows .NET Framework 3.5 prerequisite; no automatic restart.'
        $enabled = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart
        $enabled | Format-List
        if($enabled.RestartNeeded) {
            Save-Status 'reboot-required' '.NET Framework 3.5 requires a restart. Restart manually, then run this helper again.'
            $exitCode=3010
            exit 3010
        }
    }
    $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
    if($feature.State -ne 'Enabled'){throw '.NET Framework 3.5 did not reach Enabled state.'}
    Save-Status 'loading-official-components' 'Running the unmodified Microsoft loader in native and 32-bit Windows PowerShell.'
    $policyRestoreRequired = $true
    foreach($arch in @('System32','SysWOW64')) {
        $hostPath=Join-Path $env:SystemRoot ($arch+'\WindowsPowerShell\v1.0\powershell.exe')
        $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$officialScript+'"'
        $process=Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory $packageRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $logRoot ($arch+'-loader-output.txt')) -RedirectStandardError (Join-Path $logRoot ($arch+'-loader-errors.txt'))
        Write-Output ($arch+' loader exit code: '+$process.ExitCode)
        if($process.ExitCode -ne 0){throw ($arch+' official loader returned a failure. See its output logs.')}
    }
    Save-Status 'components-loaded-review-required' 'Official loaders finished. Review loader errors, GAC, registry, and SQL retry before claiming success.'
    $exitCode=0
} catch {
    Write-Output ('FAILED: '+$_.Exception.Message)
    $_ | Format-List * -Force | Out-String | Set-Content -LiteralPath (Join-Path $logRoot 'failure.txt') -Encoding UTF8
    Save-Status 'failed' $_.Exception.Message
    $exitCode=1
} finally {
    if($policyRestoreRequired) {
        try {
            foreach($snapshot in $policySnapshots) {
                $view=[Microsoft.Win32.RegistryView]::$($snapshot.view)
                $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
                try {
                    $key=$base.OpenSubKey($snapshot.key,$true)
                    if($null -eq $key -and $snapshot.exists){$key=$base.CreateSubKey($snapshot.key)}
                    try {
                        if($null -ne $key) {
                            if($snapshot.exists) {
                                $kind=[Microsoft.Win32.RegistryValueKind]::$($snapshot.kind)
                                $key.SetValue('ExecutionPolicy',$snapshot.value,$kind)
                            } else {$key.DeleteValue('ExecutionPolicy',$false)}
                        }
                    } finally {if($null -ne $key){$key.Dispose()}}
                } finally {$base.Dispose()}
            }
            'Original ExecutionPolicy values restored in both registry views.' | Set-Content -LiteralPath (Join-Path $logRoot 'policy-restore-result.txt') -Encoding UTF8
            Get-ExecutionPolicy -List | Format-Table -AutoSize
        } catch {
            Save-Status 'policy-restore-failed' ('Manual review required: '+$_.Exception.Message)
            $exitCode=2
        }
    }
    if($transcribing){Stop-Transcript | Out-Null}
    $exitCode | Set-Content -LiteralPath (Join-Path $logRoot 'exit-code.txt') -Encoding ASCII
}
exit $exitCode
