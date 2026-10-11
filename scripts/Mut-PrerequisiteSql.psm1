# This module only observes the two reviewed SQL instances and builds a plan.
# It never changes registry ACLs, services, databases or installer state.
Set-StrictMode -Version 2.0

$script:SqlSetupHash='A9697B2403FCEF33B3B780343561B4FFE7569464AB709924ED00163CD910A671'
$script:SqlSids=@{
    MUT3='S-1-5-80-2329205841-2183319202-1762315884-1906354531-1149104739'
    CAESARCOMPDB='S-1-5-80-1730965570-1020681421-1004574069-504458456-3145505875'
}

function Get-SqlFactValue($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}
function Get-SqlConfigValue([string]$Text,[string]$Name) {
    $match=[regex]::Match($Text,'(?im)^[ \t]*'+[regex]::Escape($Name)+'[ \t]*=[ \t]*"?([^"\r\n]+)"?[ \t\r]*$')
    if($match.Success){return $match.Groups[1].Value.Trim()}
    return $null
}
function Test-SqlLinkedPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $true}
        }
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if($parent -eq $current){break}
        $current=$parent
    }
    return $false
}
function Read-SqlRegistryFacts([string]$Instance) {
    $records=@();$protocol=@();$root='SOFTWARE\Microsoft\Microsoft SQL Server\'+$Instance+'\MSSQLServer\SuperSocketNetLib'
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try{
            $mapping=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL')
            try{$mapped=if($mapping){$mapping.GetValue($Instance)}else{$null}}finally{if($mapping){$mapping.Dispose()}}
            $key=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.'+$Instance+'\Setup')
            try{
                $values=[ordered]@{}
                if($key){foreach($name in @('SQLPath','SQLBinRoot','SQLDataRoot','Version','PatchLevel','Edition')){$values[$name]=$key.GetValue($name)}}
                $records += [pscustomobject]@{View=$view.ToString();Mapping=$mapped;Exists=[bool]$key;Values=$values}
            }finally{if($key){$key.Dispose()}}
            foreach($path in @($root,($root+'\Tcp'),($root+'\Np'))){
                $key=$base.OpenSubKey($path)
                try{
                    $deny=$false;$grant=$false
                    if($key){
                        $rules=@($key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq $script:SqlSids[$Instance]})
                        $deny=@($rules | Where-Object {$_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny}).Count -gt 0
                        $grant=@($rules | Where-Object {
                            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                            (([int]$_.RegistryRights -band 131103) -eq 131103) -and
                            (($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0) -and
                            $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None
                        }).Count -gt 0
                    }
                    $protocol += [pscustomobject]@{View=$view.ToString();Path=$path;Exists=[bool]$key;Deny=$deny;Grant=$grant}
                }finally{if($key){$key.Dispose()}}
            }
        }finally{$base.Dispose()}
    }
    return [pscustomobject]@{Identity=$records;Protocol=$protocol}
}
function Read-SqlBinaryFacts([string]$Path) {
    $linked=Test-SqlLinkedPath $Path
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{Exists=$false;Linked=$linked}}
    if($linked){return [pscustomobject]@{Exists=$true;Linked=$true}}
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop;$version=$file.VersionInfo
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $machine=0
    try{
        $reader=New-Object IO.BinaryReader($stream)
        if($stream.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5A4D){
            $stream.Position=0x3C;$offset=$reader.ReadInt32()
            if($offset -ge 64 -and $offset -le ($stream.Length-6)){
                $stream.Position=$offset
                if($reader.ReadUInt32() -eq 0x4550){$machine=$reader.ReadUInt16()}
            }
        }
    }finally{$stream.Dispose()}
    return [pscustomobject]@{Exists=$true;Linked=$false;ProductVersion=$version.ProductVersion;CompanyName=$version.CompanyName;FileMajorPart=$version.FileMajorPart;FileMinorPart=$version.FileMinorPart;FileBuildPart=$version.FileBuildPart;FilePrivatePart=$version.FilePrivatePart;Machine=$machine}
}
function Read-SqlInstallEvidence([string]$Instance,[string]$Release) {
    $logRoot='C:\Program Files (x86)\Microsoft SQL Server\120\Setup Bootstrap\Log'
    if(!(Test-Path -LiteralPath $logRoot -PathType Container)){return $null}
    if(Test-SqlLinkedPath $logRoot){throw 'SQL Setup log root contains a reparse point.'}
    foreach($folder in @(Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction Stop | Where-Object {$_.Name -match '^\d{8}_\d{6}$'} | Sort-Object Name -Descending)){
        $configPath=Join-Path $folder.FullName 'ConfigurationFile.ini'
        if(Test-SqlLinkedPath $folder.FullName){throw 'SQL Setup log folder contains a reparse point.'}
        if(!(Test-Path -LiteralPath $configPath -PathType Leaf)){continue}
        if(Test-SqlLinkedPath $configPath){throw 'SQL Setup configuration contains a reparse point.'}
        $config=Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
        if((Get-SqlConfigValue $config 'INSTANCENAME') -ine $Instance){continue}
        $detailPath=Join-Path $folder.FullName 'Detail.txt'
        if(!(Test-Path -LiteralPath $detailPath -PathType Leaf) -or (Test-SqlLinkedPath $detailPath)){throw 'Latest target SQL Setup detail is missing or linked.'}
        $detail=Get-Content -LiteralPath $detailPath -Raw -ErrorAction Stop
        $folders=if($Instance -eq 'MUT3'){@('MUT3DIAG_V')}else{@('NEWDBIN_V','NEWDBIN0_V')}
        $sourceRecords=@()
        foreach($name in $folders){
            $package='C:\MUT-Install\'+$Release+'\INSTALL\'+$name+'\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935'
            $source=$package+'\x86\setup\';$setup=$package+'\SETUP.EXE'
            if($detail.IndexOf($source,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
            $linked=(Test-SqlLinkedPath $setup) -or (Test-SqlLinkedPath $source)
            $hash=if(!$linked -and (Test-Path -LiteralPath $setup -PathType Leaf)){(Get-FileHash -LiteralPath $setup -Algorithm SHA256 -ErrorAction Stop).Hash}else{$null}
            $sourceRecords += [pscustomobject]@{Source=$source;SetupPath=$setup;Linked=$linked;Hash=$hash}
        }
        return [pscustomobject]@{Folder=$folder.FullName;ConfigurationText=$config;DetailText=$detail;Sources=$sourceRecords}
    }
    return $null
}

function Get-MutPrerequisiteSqlFacts {
    [CmdletBinding()]
    param([ValidateSet('SEW25091','SEW26061-00')][string]$Release='SEW26061-00')
    if(![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess){throw 'Use a 64-bit process on Windows x64 to collect SQL facts.'}
    $active=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(MUT3INSTALL|MUT3UNINSTALL|MT3NNSTLL|Mut3Check|setup|setup100|scenarioengine|en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935)\.exe$' -or
        ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -match '(?i)\b(?:MUT3_Install|UNINST|NEW|DEL_SE)\.bat\b')
    } | ForEach-Object {[pscustomobject]@{Id=$_.ProcessId;Name=$_.Name}})
    $instances=@()
    foreach($instance in @('MUT3','CAESARCOMPDB')){
        $errors=New-Object 'Collections.Generic.List[string]'
        $service=$null;$registry=$null;$binary=$null;$setupLog=$null;$engineLog=$null
        try{
            $found=@(Get-CimInstance Win32_Service -Filter ('Name="MSSQL$'+$instance+'"') -ErrorAction Stop)
            if($found.Count -gt 1){throw 'Multiple services match a reviewed instance.'}
            if($found.Count){
                $account=New-Object Security.Principal.NTAccount('NT SERVICE',('MSSQL$'+$instance))
                $sid=$account.Translate([Security.Principal.SecurityIdentifier]).Value
                $service=[pscustomobject]@{Name=$found[0].Name;State=$found[0].State;StartName=$found[0].StartName;PathName=$found[0].PathName;Sid=$sid}
            }
            $registry=Read-SqlRegistryFacts $instance
            if($service){
                $instanceRoot='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$instance+'\MSSQL'
                $binary=Read-SqlBinaryFacts ($instanceRoot+'\Binn\sqlservr.exe')
                if($service.State -ne 'Running'){
                    $setupLog=Read-SqlInstallEvidence $instance $Release
                    $logPath=$instanceRoot+'\Log\ERRORLOG';$linked=Test-SqlLinkedPath $logPath
                    $exists=Test-Path -LiteralPath $logPath -PathType Leaf
                    $text=if($exists -and !$linked){Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop}else{$null}
                    $engineLog=[pscustomobject]@{Path=$logPath;Exists=$exists;Linked=$linked;Text=$text}
                }
            }
        }catch{$errors.Add($_.Exception.Message)}
        $instances += [pscustomobject]@{Instance=$instance;Errors=$errors.ToArray();Service=$service;Registry=$registry;Binary=$binary;SetupLog=$setupLog;EngineLog=$engineLog}
    }
    return [pscustomobject]@{SchemaVersion=1;Release=$Release;CollectedUtc=[datetime]::UtcNow.ToString('o');ActiveInstallers=$active;Instances=$instances}
}

function Get-SqlIdentityProblem($Fact,[string]$Instance) {
    $service=Get-SqlFactValue $Fact 'Service';$registry=Get-SqlFactValue $Fact 'Registry';$binary=Get-SqlFactValue $Fact 'Binary'
    $root='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL'
    if((Get-SqlFactValue $service 'Name') -cne ('MSSQL$'+$Instance) -or
        ((Get-SqlFactValue $service 'StartName') -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or
        (Get-SqlFactValue $service 'PathName') -ine ('"'+$root+'\Binn\sqlservr.exe" -s'+$Instance) -or
        (Get-SqlFactValue $service 'Sid') -cne $script:SqlSids[$Instance]){return 'UnknownServiceIdentity'}
    $identity=@(Get-SqlFactValue $registry 'Identity');$wow=@($identity | Where-Object {(Get-SqlFactValue $_ 'View') -eq 'Registry32'});$native=@($identity | Where-Object {(Get-SqlFactValue $_ 'View') -eq 'Registry64'})
    if($wow.Count -ne 1 -or $native.Count -ne 1 -or $identity.Count -ne 2){return 'IncompleteRegistryIdentity'}
    $values=Get-SqlFactValue $wow[0] 'Values'
    if(!(Get-SqlFactValue $wow[0] 'Exists') -or (Get-SqlFactValue $wow[0] 'Mapping') -ine ('MSSQL12.'+$Instance) -or
        (Get-SqlFactValue $native[0] 'Exists') -or (Get-SqlFactValue $native[0] 'Mapping') -or
        (Get-SqlFactValue $values 'SQLPath') -ine $root -or (Get-SqlFactValue $values 'SQLBinRoot') -ine ($root+'\Binn') -or
        (Get-SqlFactValue $values 'SQLDataRoot') -ine $root -or (Get-SqlFactValue $values 'Version') -cne '12.1.4100.1' -or
        (Get-SqlFactValue $values 'PatchLevel') -cne '12.1.4100.1' -or (Get-SqlFactValue $values 'Edition') -cne 'Express Edition'){return 'UnknownRegistryIdentity'}
    if((Get-SqlFactValue $binary 'Exists') -cne $true -or (Get-SqlFactValue $binary 'Linked') -cne $false -or
        (Get-SqlFactValue $binary 'ProductVersion') -cne '12.0.4100.1' -or (Get-SqlFactValue $binary 'CompanyName') -cne 'Microsoft Corporation' -or
        (Get-SqlFactValue $binary 'FileMajorPart') -ne 2014 -or (Get-SqlFactValue $binary 'FileMinorPart') -ne 120 -or
        (Get-SqlFactValue $binary 'FileBuildPart') -ne 4100 -or (Get-SqlFactValue $binary 'FilePrivatePart') -ne 1 -or
        (Get-SqlFactValue $binary 'Machine') -ne 0x014C){return 'UnknownBinaryIdentity'}
    return $null
}
function Get-SqlRepairProblem($Fact,[string]$Instance,[string]$Release) {
    $setup=Get-SqlFactValue $Fact 'SetupLog';$config=[string](Get-SqlFactValue $setup 'ConfigurationText');$detail=[string](Get-SqlFactValue $setup 'DetailText')
    if((Get-SqlConfigValue $config 'INSTANCENAME') -ine $Instance -or (Get-SqlConfigValue $config 'ACTION') -ine 'Install' -or
        (Get-SqlConfigValue $config 'FEATURES') -ine 'SQLENGINE' -or ((Get-SqlConfigValue $config 'SQLSVCACCOUNT') -replace '\s','') -ine 'NTAUTHORITY\NETWORKSERVICE' -or
        $detail -notmatch '(?i)Feature\s*=\s*SQL_Engine_Core_Inst_sql_engine_core_inst_Cpu32\b'){return 'UnknownSetupScope'}
    $sourceOkay=$false
    $folders=if($Instance -eq 'MUT3'){@('MUT3DIAG_V')}else{@('NEWDBIN_V','NEWDBIN0_V')}
    foreach($source in @(Get-SqlFactValue $setup 'Sources')){
        foreach($folder in $folders){
            $package='C:\MUT-Install\'+$Release+'\INSTALL\'+$folder+'\en_sql_server_2014_express_with_service_pack_1_x86_x64_6673935'
            if((Get-SqlFactValue $source 'Source') -ine ($package+'\x86\setup\') -or
                (Get-SqlFactValue $source 'SetupPath') -ine ($package+'\SETUP.EXE')){continue}
            if((Get-SqlFactValue $source 'Linked') -ceq $false -and (Get-SqlFactValue $source 'Hash') -ceq $script:SqlSetupHash -and
                $detail.IndexOf(($package+'\x86\setup\'),[StringComparison]::OrdinalIgnoreCase) -ge 0){$sourceOkay=$true}
        }
    }
    if(!$sourceOkay){return 'UnknownSetupSource'}
    $log=Get-SqlFactValue $Fact 'EngineLog';$text=[string](Get-SqlFactValue $log 'Text')
    $expectedLog='C:\Program Files (x86)\Microsoft SQL Server\MSSQL12.'+$Instance+'\MSSQL\Log\ERRORLOG'
    if((Get-SqlFactValue $log 'Exists') -cne $true -or (Get-SqlFactValue $log 'Linked') -cne $false -or (Get-SqlFactValue $log 'Path') -ine $expectedLog -or
        $text -notmatch '(?im)Microsoft SQL Server 2014\s*-\s*12\.0\.4100\.1\s*\(Intel X86\)' -or
        $text -notmatch '(?i)TDSSNIClient initialization failed with error 0x5, status code 0x90\. Reason: Unable to configure MDAC-compatibility protocol list in registry\. Access is denied\.'){return 'CurrentMdacEvidenceMissing'}
    if($text -match '(?i)SQL Server is now ready for client connections'){return 'CurrentLogShowsWorkingEngine'}
    foreach($match in [regex]::Matches($text,"(?im)Starting up database '([^']+)'")){
        if($match.Groups[1].Value -notin @('master','model','msdb','tempdb','mssqlsystemresource')){return 'CurrentLogShowsUserDatabase'}
    }
    $protocol=@(Get-SqlFactValue (Get-SqlFactValue $Fact 'Registry') 'Protocol')
    $root='SOFTWARE\Microsoft\Microsoft SQL Server\'+$Instance+'\MSSQLServer\SuperSocketNetLib'
    if($protocol.Count -ne 6){return 'IncompleteProtocolKeys'}
    $allNativeGranted=$true
    foreach($path in @($root,($root+'\Tcp'),($root+'\Np'))){
        $native=@($protocol | Where-Object {(Get-SqlFactValue $_ 'Path') -ceq $path -and (Get-SqlFactValue $_ 'View') -eq 'Registry64'})
        $reference=@($protocol | Where-Object {(Get-SqlFactValue $_ 'Path') -ceq $path -and (Get-SqlFactValue $_ 'View') -eq 'Registry32'})
        if($native.Count -ne 1 -or $reference.Count -ne 1 -or (Get-SqlFactValue $native[0] 'Exists') -cne $true -or (Get-SqlFactValue $reference[0] 'Exists') -cne $true){return 'ProtocolKeyMissing'}
        if((Get-SqlFactValue $native[0] 'Deny') -cne $false -or (Get-SqlFactValue $reference[0] 'Deny') -cne $false){return 'ServiceDenyAce'}
        if((Get-SqlFactValue $reference[0] 'Grant') -cne $true){return 'ReferenceGrantMissing'}
        if(!(Get-SqlFactValue $native[0] 'Grant')){$allNativeGranted=$false}
    }
    if($allNativeGranted){return 'NativeGrantAlreadyPresent'}
    return $null
}

function Get-MutPrerequisiteSqlPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Facts)
    $items=@();$factsInstances=@(Get-SqlFactValue $Facts 'Instances');$active=@(Get-SqlFactValue $Facts 'ActiveInstallers');$release=[string](Get-SqlFactValue $Facts 'Release')
    foreach($instance in @('MUT3','CAESARCOMPDB')){
        $matches=@($factsInstances | Where-Object {(Get-SqlFactValue $_ 'Instance') -ceq $instance})
        $action='Review';$reason='InvalidFacts';$evidence=@()
        if((Get-SqlFactValue $Facts 'SchemaVersion') -eq 1 -and $release -in @('SEW25091','SEW26061-00') -and $matches.Count -eq 1 -and $factsInstances.Count -eq 2){
            $fact=$matches[0];$service=Get-SqlFactValue $fact 'Service';$errors=@(Get-SqlFactValue $fact 'Errors')
            if($errors.Count){$reason='CollectionError';$evidence=$errors}
            elseif(!$service){
                $registry=Get-SqlFactValue $fact 'Registry';$identity=@(Get-SqlFactValue $registry 'Identity');$protocol=@(Get-SqlFactValue $registry 'Protocol')
                if($identity.Count -ne 2 -or $protocol.Count -ne 6){$reason='IncompleteRegistryIdentity'}
                elseif(@($identity | Where-Object {(Get-SqlFactValue $_ 'Exists') -or (Get-SqlFactValue $_ 'Mapping')}).Count -or
                    @($protocol | Where-Object {Get-SqlFactValue $_ 'Exists'}).Count){$reason='RegistryRemnantsWithoutService'}
                else{$action='Skip';$reason='NotInstalled'}
            }else{
                $reason=Get-SqlIdentityProblem $fact $instance
                if(!$reason){
                    if((Get-SqlFactValue $service 'State') -ceq 'Running'){$action='Skip';$reason='HealthyRunning'}
                    elseif((Get-SqlFactValue $service 'State') -cne 'Stopped'){$reason='UnstableServiceState'}
                    else{
                        $reason=Get-SqlRepairProblem $fact $instance $release
                        if(!$reason){$action='Repair';$reason='ReviewedMdacAclFailure';$evidence=@((Get-SqlFactValue (Get-SqlFactValue $fact 'SetupLog') 'Folder'),(Get-SqlFactValue (Get-SqlFactValue $fact 'EngineLog') 'Path'))}
                    }
                }
            }
        }
        if($active.Count){$action='Review';$reason='ActiveInstaller'}
        $items += [pscustomobject]@{Instance=$instance;Action=$action;Reason=$reason;Evidence=$evidence}
    }
    return [pscustomobject]@{Items=$items;RepairInstances=@($items | Where-Object {$_.Action -eq 'Repair'} | ForEach-Object {$_.Instance});ReviewRequired=(@($items | Where-Object {$_.Action -eq 'Review'}).Count -gt 0);ActiveInstallers=$active}
}

Export-ModuleMember -Function Get-MutPrerequisiteSqlFacts,Get-MutPrerequisiteSqlPlan
