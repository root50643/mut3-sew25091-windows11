[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1.'}
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Start-MutInstallWithSqlAcl.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join '; ')}
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PreservedSqlReady'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$script:versions=@{};$script:states=@{};$script:connections=0
function Get-Service {param([string]$Name,$ErrorAction) if($script:states.ContainsKey($Name)){[pscustomobject]@{Status=$script:states[$Name]}}}
function New-Object {
    param([string]$TypeName,[string]$ArgumentList)
    if($TypeName -ne 'Data.SqlClient.SqlConnection'){throw 'Unexpected system operation in test.'}
    $script:connections++
    $instance=if($ArgumentList -match 'lpc:\.\\([^;]+);'){$Matches[1]}else{throw 'Unexpected connection source.'}
    $connection=[pscustomobject]@{Instance=$instance}
    $connection | Add-Member ScriptMethod Open {}
    $connection | Add-Member ScriptMethod Dispose {}
    $connection | Add-Member ScriptMethod CreateCommand {
        $command=[pscustomobject]@{Instance=$this.Instance;CommandTimeout=0;CommandText=''}
        $command | Add-Member ScriptMethod ExecuteScalar {return $script:versions[$this.Instance]}
        $command | Add-Member ScriptMethod Dispose {}
        return $command
    }
    return $connection
}
function Assert([bool]$Value,[string]$Label){if(!$Value){throw $Label};Write-Host ('PASS '+$Label)}
$script:states=@{'MSSQL$MUT3'='Running';'MSSQL$CAESARCOMPDB'='Running'}
$script:versions=@{MUT3='12.0.4100.1';CAESARCOMPDB='12.0.4100.1'}
Assert (Test-PreservedSqlReady) 'Both known engines require fresh live queries'
Assert ($script:connections -eq 2) 'Both instances queried'
$script:states['MSSQL$MUT3']='Stopped';$script:connections=0
Assert (!(Test-PreservedSqlReady)) 'Stopped engine is not ready'
Assert ($script:connections -eq 0) 'No connection attempted to stopped engine'
$script:states.Remove('MSSQL$MUT3')
Assert (!(Test-PreservedSqlReady)) 'Missing engine is not ready'
$script:states['MSSQL$MUT3']='Running';$script:versions['CAESARCOMPDB']='13.0.1.0'
$thrown=$false
try{Test-PreservedSqlReady | Out-Null}catch{$thrown=$true}
Assert $thrown 'Unknown SQL version stops the watcher'
Write-Host '6 preserved SQL isolation checks passed; no real service or SQL operations were called.'
