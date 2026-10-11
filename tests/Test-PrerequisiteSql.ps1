[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1.'}
$modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Mut-PrerequisiteSql.psm1'
Import-Module $modulePath -Force
$script:count=0
function Assert([bool]$Value,[string]$Label){if(!$Value){throw $Label};$script:count++;Write-Host ('PASS '+$Label)}
function New-ReviewedFact([string]$Instance) {
    $sid=@{MUT3='S-1-5-80-2329205841-2183319202-1762315884-1906354531-1149104739';CAESARCOMPDB='S-1-5-80-1730965570-1020681421-1004574069-504458456-3145505875'}
    $root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL'
    $protocolRoot='SOFTWARE\Microsoft\Microsoft SQL Server\'+$Instance+'\MSSQLServer\SuperSocketNetLib'
    $protocol=@()
    foreach($view in @('Registry32','Registry64')){foreach($path in @($protocolRoot,($protocolRoot+'\Tcp'),($protocolRoot+'\Np'))){$protocol += [pscustomobject]@{View=$view;Path=$path;Exists=$true;Deny=$false;Grant=($view -eq 'Registry32')}}}
    $folder=if($Instance -eq 'MUT3'){'MUT3DIAG_V'}else{'NEWDBIN_V'}
    $package='C:\MUT-Install\SEW26061-00\INSTALL\'+$folder+'\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935'
    return [pscustomobject]@{
        Instance=$Instance;Errors=@()
        Service=[pscustomobject]@{Name=('MSSQL$'+$Instance);State='Stopped';StartName='NT AUTHORITY\NETWORK SERVICE';PathName=('"'+$root+'\Binn\sqlservr.exe" -s'+$Instance);Sid=$sid[$Instance]}
        Registry=[pscustomobject]@{
            Identity=@(
                [pscustomobject]@{View='Registry32';Mapping=('MSSQL12.'+$Instance);Exists=$true;Values=[pscustomobject]@{SQLPath=$root;SQLBinRoot=($root+'\Binn');SQLDataRoot=$root;Version='12.1.4100.1';PatchLevel='12.1.4100.1';Edition='Express Edition'}},
                [pscustomobject]@{View='Registry64';Mapping=$null;Exists=$false;Values=[pscustomobject]@{}}
            );Protocol=$protocol
        }
        Binary=[pscustomobject]@{Exists=$true;Linked=$false;ProductVersion='12.0.4100.1';CompanyName='Microsoft Corporation';FileMajorPart=2014;FileMinorPart=120;FileBuildPart=4100;FilePrivatePart=1;Machine=0x014C}
        SetupLog=[pscustomobject]@{Folder='C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log\20261011_230000';ConfigurationText=("INSTANCENAME=`""+$Instance+"`"`r`nACTION=`"Install`"`r`nFEATURES=SQLENGINE`r`nSQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`"`r`n");DetailText=($package+'\x86\setup\' + "`r`nFeature = SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32`r`n");Sources=@([pscustomobject]@{Source=($package+'\x86\setup\');SetupPath=($package+'\SETUP.EXE');Linked=$false;Hash='A9697B2403FCEF33B3B780343561B4FFE7569464AB709924ED00163CD910A671'})}
        EngineLog=[pscustomobject]@{Path=($root+'\Log\ERRORLOG');Exists=$true;Linked=$false;Text="Microsoft SQL Server 2014 - 12.0.4100.1 (Intel X86)`r`nTDSSNIClient initialization failed with error 0x5, status code 0x90. Reason: Unable to configure MDAC-compatibility protocol list in registry. Access is denied.`r`n"}
    }
}
function New-Facts {return [pscustomobject]@{SchemaVersion=1;Release='SEW26061-00';CollectedUtc=[datetime]::UtcNow.ToString('o');ActiveInstallers=@();Instances=@((New-ReviewedFact MUT3),(New-ReviewedFact CAESARCOMPDB))}}
function Assert-Review([scriptblock]$Change,[string]$Label) {
    $facts=New-Facts
    & $Change $facts
    $plan=Get-MutPrerequisiteSqlPlan -Facts $facts
    Assert ($plan.Items[0].Action -eq 'Review' -and $plan.ReviewRequired) $Label
}
$facts=New-Facts;$plan=Get-MutPrerequisiteSqlPlan -Facts $facts
Assert ($plan.RepairInstances.Count -eq 2 -and !$plan.ReviewRequired) 'Only both fully reviewed stopped MDAC failures authorize repairs'
Assert ($plan.Items[0].Evidence.Count -eq 2) 'Repair plan retains setup and current ERRORLOG evidence'
$facts=New-Facts;foreach($fact in $facts.Instances){$fact.Service.State='Running';$fact.SetupLog=$null;$fact.EngineLog=$null}
$plan=Get-MutPrerequisiteSqlPlan -Facts $facts
Assert ($plan.RepairInstances.Count -eq 0 -and !$plan.ReviewRequired -and $plan.Items[0].Reason -eq 'HealthyRunning') 'Healthy running reviewed engines are skipped without failure logs'
Assert-Review {param($f) $f.Instances[0].Service.State='Start Pending'} 'Transitional service state cannot authorize repair'
Assert-Review {param($f) $f.Instances[0].Service.StartName='LocalSystem'} 'Different service account stops repair'
Assert-Review {param($f) $f.Instances[0].Service.Name='MSSQL$OTHER'} 'Other service name stops repair'
Assert-Review {param($f) $f.Instances[0].Service.PathName='C:\malicious\sqlservr.exe'} 'Unexpected SQL service executable path stops repair'
Assert-Review {param($f) $f.Instances[0].Service.Sid='S-1-5-18'} 'Unexpected service SID stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Mapping='MSSQL13.MUT3'} 'Unknown instance mapping stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.Version='13.0.1.0'} 'Different servicing version stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.PatchLevel='12.1.4100.2'} 'Different SQL patch level stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.Edition='Developer Edition'} 'Different SQL edition stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.SQLPath='D:\SQL'} 'Different instance root stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.SQLBinRoot='D:\SQL\Binn'} 'Different binary registry root stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[0].Values.SQLDataRoot='D:\SQL'} 'Different data registry root stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[1].Exists=$true} 'Native Setup identity is not accepted as reviewed x86 installation'
Assert-Review {param($f) $f.Instances[0].Registry.Identity[1].Mapping='MSSQL12.MUT3'} 'Unexpected native mapping stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Identity=@($f.Instances[0].Registry.Identity[0])} 'Missing registry view stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.Exists=$false} 'Missing engine executable stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.Linked=$true} 'Linked engine binary or ancestor stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.Linked=$null} 'Unknown engine link status stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.ProductVersion='12.0.5000.0'} 'Different engine product version stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.CompanyName='Other'} 'Unrecognized engine publisher stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.FileMajorPart=2016} 'Different executable version stops repair'
Assert-Review {param($f) $f.Instances[0].Binary.Machine=0x8664} 'x64 engine cannot enter x86 ACL repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.ConfigurationText=$f.Instances[0].SetupLog.ConfigurationText.Replace('Install','Uninstall')} 'Latest uninstall configuration cannot authorize repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.ConfigurationText=$f.Instances[0].SetupLog.ConfigurationText.Replace('SQLENGINE','SQLENGINE,REPLICATION')} 'Additional setup feature scope stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.ConfigurationText=$f.Instances[0].SetupLog.ConfigurationText.Replace('NETWORK SERVICE','SYSTEM')} 'Different setup account stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.ConfigurationText=$f.Instances[0].SetupLog.ConfigurationText.Replace('MUT3','OTHER')} 'Another setup instance stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.DetailText=$f.Instances[0].SetupLog.DetailText.Replace('Cpu32','Cpu64')} 'Different source architecture stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.Sources[0].Hash=('0'*64)} 'Changed SQL setup executable stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.Sources[0].Linked=$true} 'Linked source media stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.Sources[0].Linked=$null} 'Unknown source link status stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.Sources[0].Source='C:\Other\x86\setup\'} 'Unknown installation source stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.Sources[0].SetupPath='C:\Other\SETUP.EXE'} 'Unmatched original Setup source path stops repair'
Assert-Review {param($f) $f.Instances[0].SetupLog.DetailText='Feature = SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32'} 'Source must be present in current matched Setup detail'
Assert-Review {param($f) $f.Instances[0].SetupLog=$null} 'Missing source log stops repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Path='C:\Archived\ERRORLOG'} 'Only current canonical ERRORLOG can authorize repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Linked=$true} 'Linked current ERRORLOG stops repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Linked=$null} 'Unknown ERRORLOG link status stops repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Exists=$false} 'Missing current ERRORLOG stops repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Text='Access is denied.'} 'Generic access denied text is insufficient'
Assert-Review {param($f) $f.Instances[0].EngineLog.Text=$f.Instances[0].EngineLog.Text.Replace('0x90','0x80')} 'Different MDAC status code stops repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Text=$f.Instances[0].EngineLog.Text.Replace('12.0.4100.1','12.0.5000.0')} 'Current engine log version must match reviewed binary'
Assert-Review {param($f) $f.Instances[0].EngineLog.Text += 'SQL Server is now ready for client connections'} 'Working engine evidence prevents historical failure from authorizing repair'
Assert-Review {param($f) $f.Instances[0].EngineLog.Text += "Starting up database 'MUTMCB'"} 'User database startup evidence requires manual review'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[0].Grant=$false} 'Missing inheritable reference service grant stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[0].Deny=$true} 'Reference deny ACE stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[3].Deny=$true} 'Native deny ACE stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[3].Deny=$null} 'Unknown ACL deny status stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[3].Exists=$false} 'Missing native protocol key stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol[0].Exists=$false} 'Missing reference protocol key stops repair'
Assert-Review {param($f) $f.Instances[0].Registry.Protocol=$f.Instances[0].Registry.Protocol[0..4]} 'All three keys in both views are required'
Assert-Review {param($f) foreach($p in $f.Instances[0].Registry.Protocol){$p.Grant=$true}} 'Already granted native keys with MDAC failure require another diagnosis'
Assert-Review {param($f) $f.Instances[0].Errors=@('Access denied while collecting registry')} 'Incomplete read access stops repair'
Assert-Review {param($f) $f.ActiveInstallers=@([pscustomobject]@{Id=123;Name='setup.exe'})} 'Active vendor or SQL installer stops all ACL repairs'
Assert-Review {param($f) $f.SchemaVersion=9} 'Unknown facts schema stops repair'
Assert-Review {param($f) $f.Release='SEW99999'} 'Unreviewed media release stops repair'
Assert-Review {param($f) $f.Instances=@($f.Instances[0],$f.Instances[0])} 'Duplicate instance inventory stops repair'
Assert-Review {param($f) $f.Instances[0].Service.State='Running';$f.Instances[0].Binary.ProductVersion='16.0.1.0'} 'Unknown running engine is not classified healthy'
$facts=New-Facts
foreach($fact in $facts.Instances){$fact.Service=$null;foreach($r in $fact.Registry.Identity){$r.Exists=$false;$r.Mapping=$null};foreach($p in $fact.Registry.Protocol){$p.Exists=$false}}
$plan=Get-MutPrerequisiteSqlPlan -Facts $facts
Assert (!$plan.ReviewRequired -and $plan.RepairInstances.Count -eq 0 -and $plan.Items[0].Reason -eq 'NotInstalled') 'Completely absent engines require no SQL installation or repair'
$facts.Instances[0].Registry.Protocol[0].Exists=$true
$plan=Get-MutPrerequisiteSqlPlan -Facts $facts
Assert ($plan.Items[0].Action -eq 'Review' -and $plan.Items[0].Reason -eq 'RegistryRemnantsWithoutService') 'Registry remnants without a service are preserved for review'
$facts=New-Facts;$facts.Instances[1].Service.State='Running'
$plan=Get-MutPrerequisiteSqlPlan -Facts $facts
Assert ($plan.RepairInstances.Count -eq 1 -and $plan.RepairInstances[0] -eq 'MUT3' -and $plan.Items[1].Reason -eq 'HealthyRunning') 'Repair plan scopes only the stopped failed target and leaves healthy peer alone'
$before=$facts | ConvertTo-Json -Depth 12 -Compress
Get-MutPrerequisiteSqlPlan -Facts $facts | Out-Null
Assert (($facts | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'Planning does not alter input inventory'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Planner and collector parse in native PowerShell 5.1'
$forbidden=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(Start-Process|Stop-Process|Start-Service|Stop-Service|Set-Service|Set-Acl|Set-ItemProperty|Remove-Item|New-Item|Invoke-Expression)$'},$true))
Assert ($forbidden.Count -eq 0) 'Collector exposes no mutation, process launch or service action commands'
Write-Host ($script:count.ToString()+' prerequisite SQL planning checks passed; no real system collector or mutation was invoked.')
