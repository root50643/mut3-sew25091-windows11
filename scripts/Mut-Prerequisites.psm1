# Read-only verification of the reviewed Microsoft ps2DLC workaround.
# The caller must first validate the official ZIP hash and the extracted tree.
Set-StrictMode -Version 2.0

function Get-MutPrerequisiteProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-MutPrerequisiteHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Read-MutLoaderNativeStream {
    param([byte[]]$Bytes)
    # reg.exe may send successful status lines to the redirected native error stream.
    # Accept only exact reviewed Traditional Chinese / English sentences, never broad "success" matching.
    $known = @('操作順利完成。', 'The operation completed successfully.')
    $decodings = New-Object 'System.Collections.Generic.List[object]'
    foreach ($encoding in @((New-Object Text.UTF8Encoding($false, $true)), [Text.Encoding]::GetEncoding(950))) {
        try { $decodings.Add([pscustomobject]@{ Encoding = $encoding.WebName; Text = $encoding.GetString($Bytes).TrimStart([char]0xFEFF) }) }
        catch { }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $decodings.Add([pscustomobject]@{ Encoding = 'utf-16'; Text = [Text.Encoding]::Unicode.GetString($Bytes).TrimStart([char]0xFEFF) })
    }
    foreach ($decoding in $decodings) {
        $lines = @($decoding.Text -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $unknown = @($lines | Where-Object { $known -cnotcontains $_ })
        if ($unknown.Count -eq 0 -and ($lines.Count -eq 0 -or $lines.Count -eq 2)) {
            return [pscustomobject]@{ Passed = $true; Encoding = $decoding.Encoding; Text = $decoding.Text; UnknownLines = @() }
        }
    }
    $first = $decodings | Select-Object -First 1
    return [pscustomobject]@{
        Passed = $false; Encoding = $(if ($first) { $first.Encoding } else { 'unknown' })
        Text = $(if ($first) { $first.Text } else { [BitConverter]::ToString($Bytes) })
        UnknownLines = @($(if ($first) { $first.Text } else { 'Undecodable native loader output.' }))
    }
}

function Test-MutPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$RepairLogRoot
    )
    $findings = New-Object 'System.Collections.Generic.List[string]'
    $sources = New-Object 'System.Collections.Generic.List[object]'
    $assemblies = New-Object 'System.Collections.Generic.List[object]'
    $loaders = New-Object 'System.Collections.Generic.List[object]'
    $registryResults = New-Object 'System.Collections.Generic.List[object]'
    $policyResults = New-Object 'System.Collections.Generic.List[object]'
    $wrapperExit = $null
    $featureState = $null
    $locale = $null
    $markerValid = $false
    $expectedGroups = 0
    if ($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
        $findings.Add('Run this verifier in 64-bit Windows PowerShell 5.1; no system changes were made.')
    }
    try {
        $exitPath = Join-Path $RepairLogRoot 'exit-code.txt'
        if (-not (Test-Path -LiteralPath $exitPath -PathType Leaf)) { throw 'Repair exit-code.txt is missing.' }
        $exitText = [IO.File]::ReadAllText($exitPath).Trim()
        if ($exitText -notmatch '^\d+$') { throw 'Repair exit-code.txt is incomplete or invalid.' }
        $wrapperExit = [int]$exitText
        if ($wrapperExit -ne 0) { $findings.Add('Repair wrapper did not finish successfully; exit code ' + $wrapperExit + '.') }
    } catch { $findings.Add('Repair result: ' + $_.Exception.Message) }
    try {
        $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='NetFx3'" -ErrorAction Stop
        if ($null -ne $feature) { $featureState = [int]$feature.InstallState }
        if ($featureState -ne 1) { $findings.Add('NetFx3 is not reported as installed by Win32_OptionalFeature.') }
    } catch { $findings.Add('NetFx3 query failed: ' + $_.Exception.Message) }
    try { $locale = (Get-WinSystemLocale -ErrorAction Stop).Name }
    catch { $findings.Add('System locale query failed: ' + $_.Exception.Message) }

    foreach ($hostName in @('System32','SysWOW64')) {
        try {
            $outPath = Join-Path $RepairLogRoot ($hostName + '-loader-output.txt')
            $errPath = Join-Path $RepairLogRoot ($hostName + '-loader-errors.txt')
            if (-not (Test-Path -LiteralPath $outPath -PathType Leaf) -or -not (Test-Path -LiteralPath $errPath -PathType Leaf)) {
                throw 'One or both loader output files are missing.'
            }
            $outText = [IO.File]::ReadAllText($outPath)
            $native = Read-MutLoaderNativeStream -Bytes ([IO.File]::ReadAllBytes($errPath))
            $expectedArch = if ($hostName -eq 'System32') { 'AMD64' } else { 'x86' }
            $passed = $native.Passed -and $outText -match '(?m)^Registry import succeeded\.\s*$' -and
                $outText -match ('(?m)^System architecture is set to: ' + $expectedArch + '\s*$') -and
                $outText -match ('(?m)^System locale is set to: ' + [regex]::Escape([string]$locale) + '\s*$') -and
                $outText -notmatch '(?im)\b(error|failed|exception|cannot)\b|access\s+is\s+denied'
            $loaders.Add([pscustomobject]@{
                Host = $hostName; Passed = [bool]$passed; OutputPath = $outPath; ErrorPath = $errPath
                NativeStreamOnlyKnownSuccess = $native.Passed; ErrorEncoding = $native.Encoding
                UnknownErrorLines = @($native.UnknownLines)
            })
            if (-not $passed) { $findings.Add($hostName + ' loader output needs review; unknown native output is not treated as success.') }
        } catch {
            $loaders.Add([pscustomobject]@{ Host = $hostName; Passed = $false; Error = $_.Exception.Message })
            $findings.Add($hostName + ' loader verification failed: ' + $_.Exception.Message)
        }
    }

    # The reviewed archive contains 9 core + 7 locale DLLs per architecture.
    # 32 official sources group into 17 identities: 15 MSIL, one AMD64, one x86.
    foreach ($arch in @('AMD64','x86')) {
        foreach ($kind in @('Binaries','ResourceBinaries')) {
            try {
                $folder = Join-Path $PackageRoot ($kind + '\' + $arch)
                $expectedCount = 9
                if ($kind -eq 'ResourceBinaries') {
                    if (-not $locale) { throw 'A system locale is required for the resource inventory.' }
                    $folder = Join-Path $folder $locale
                    $expectedCount = 7
                }
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw ('Required official source directory is missing: ' + $folder) }
                $dlls = @(Get-ChildItem -LiteralPath $folder -Filter '*.dll' -File -ErrorAction Stop)
                if ($dlls.Count -ne $expectedCount) { throw ('Expected ' + $expectedCount + ' DLLs, found ' + $dlls.Count + ': ' + $folder) }
                foreach ($dll in $dlls) {
                    $identity = [Reflection.AssemblyName]::GetAssemblyName($dll.FullName)
                    $architecture = $identity.ProcessorArchitecture.ToString()
                    if ($architecture -notin @('MSIL','Amd64','X86')) { throw ('Unsupported assembly architecture: ' + $dll.FullName) }
                    $sources.Add([pscustomobject]@{
                        SourceArch = $arch; Kind = $kind; Path = $dll.FullName; Assembly = $identity.FullName
                        Name = $identity.Name; ProcessorArchitecture = $architecture
                        FileHash = (Get-MutPrerequisiteHash $dll.FullName)
                        GacIdentity = ($identity.FullName + ', ProcessorArchitecture=' + $architecture)
                    })
                }
            } catch { $findings.Add('Official assembly inventory failed: ' + $_.Exception.Message) }
        }
    }
    $groups = @($sources.ToArray() | Group-Object GacIdentity)
    $expectedGroups = $groups.Count
    if ($sources.Count -ne 32 -or $groups.Count -ne 17) {
        $findings.Add('The reviewed package must yield exactly 32 sources and 17 GAC identities for the selected locale.')
    }
    foreach ($group in $groups) {
        try {
            $representative = $group.Group[0]
            $gacFolder = switch ($representative.ProcessorArchitecture) { 'MSIL' { 'GAC_MSIL' }; 'Amd64' { 'GAC_64' }; 'X86' { 'GAC_32' } }
            $assemblyRoot = Join-Path $env:SystemRoot ('assembly\' + $gacFolder + '\' + $representative.Name)
            $matches = New-Object 'System.Collections.Generic.List[object]'
            $allowedHashes = @($group.Group | ForEach-Object { $_.FileHash })
            if ([IO.Directory]::Exists($assemblyRoot)) {
                foreach ($versionDirectory in [IO.Directory]::GetDirectories($assemblyRoot)) {
                    $candidate = Join-Path $versionDirectory ([IO.Path]::GetFileName($representative.Path))
                    if (-not [IO.File]::Exists($candidate)) { continue }
                    $hash = Get-MutPrerequisiteHash $candidate
                    if ($allowedHashes -notcontains $hash) { continue }
                    $identity = [Reflection.AssemblyName]::GetAssemblyName($candidate)
                    if ($identity.FullName -ceq $representative.Assembly -and $identity.ProcessorArchitecture.ToString() -eq $representative.ProcessorArchitecture) {
                        $matches.Add([pscustomobject]@{ Path = $candidate; Assembly = $identity.FullName; FileHash = $hash })
                    }
                }
            }
            $passed = $matches.Count -gt 0
            $assemblies.Add([pscustomobject]@{
                GacIdentity = $group.Name; Passed = [bool]$passed; Matches = @($matches.ToArray())
                OfficialVariants = @($group.Group | Select-Object SourceArch,Path,FileHash)
            })
            if (-not $passed) { $findings.Add('GAC does not contain a matching official assembly: ' + $group.Name) }
        } catch {
            $assemblies.Add([pscustomobject]@{ GacIdentity = $group.Name; Passed = $false; Error = $_.Exception.Message })
            $findings.Add('GAC inspection failed: ' + $_.Exception.Message)
        }
    }

    # These are the exact values in the unmodified official .reg file, not inferred host version claims.
    $expectedEngine = [ordered]@{
        ApplicationBase = 'C:\Windows\System32\WindowsPowerShell\v1.0'
        ConsoleHostAssemblyName = 'Microsoft.PowerShell.ConsoleHost, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35, ProcessorArchitecture=msil'
        ConsoleHostModuleName = 'C:\Windows\System32\WindowsPowerShell\v1.0\Microsoft.PowerShell.ConsoleHost.dll'
        PowerShellVersion = '2.0'; PSCompatibleVersion = '1.0, 2.0'; RuntimeVersion = 'v2.0.50727'
    }
    foreach ($viewName in @('Registry64','Registry32')) {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::$viewName)
            try {
                $install = $base.OpenSubKey('SOFTWARE\Microsoft\PowerShell\1')
                try { $installValue = if ($install) { $install.GetValue('Install') } else { $null } }
                finally { if ($install) { $install.Dispose() } }
                $engine = $base.OpenSubKey('SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine')
                $values = @()
                try {
                    foreach ($name in $expectedEngine.Keys) {
                        $actual = if ($engine) { $engine.GetValue($name) } else { $null }
                        $values += [pscustomobject]@{ Name = $name; Expected = $expectedEngine[$name]; Actual = $actual; Passed = ($actual -ceq $expectedEngine[$name]) }
                    }
                } finally { if ($engine) { $engine.Dispose() } }
                $passed = $installValue -eq 1 -and @($values | Where-Object { -not $_.Passed }).Count -eq 0
                $registryResults.Add([pscustomobject]@{ View = $viewName; Passed = [bool]$passed; Install = $installValue; Values = @($values) })
                if (-not $passed) { $findings.Add($viewName + ' official PowerShell registry values are incomplete or different.') }
            } finally { $base.Dispose() }
        } catch { $findings.Add($viewName + ' registry inspection failed: ' + $_.Exception.Message) }
    }

    try {
        $snapshotPath = Join-Path $RepairLogRoot 'policy-values-before.json'
        $parsedSnapshots = [IO.File]::ReadAllText($snapshotPath) | ConvertFrom-Json -ErrorAction Stop
        $snapshots = @($parsedSnapshots)
        if ($snapshots.Count -ne 4) { throw 'Expected exactly four original ExecutionPolicy snapshots.' }
        foreach ($viewName in @('Registry64','Registry32')) {
            foreach ($shellName in @('Microsoft.PowerShell','ScriptedDiagnostics')) {
                $keyPath = 'SOFTWARE\Microsoft\PowerShell\1\ShellIds\' + $shellName
                $match = @($snapshots | Where-Object { (Get-MutPrerequisiteProperty $_ 'view') -eq $viewName -and (Get-MutPrerequisiteProperty $_ 'key') -eq $keyPath })
                if ($match.Count -ne 1) { throw ('Missing or duplicated policy snapshot: ' + $viewName + ' / ' + $keyPath) }
                $snapshot = $match[0]
                $expectedExists = Get-MutPrerequisiteProperty $snapshot 'exists'
                if ($expectedExists -isnot [bool]) { throw 'A policy snapshot has an invalid exists field.' }
                $expectedValue = Get-MutPrerequisiteProperty $snapshot 'value'
                $expectedKind = Get-MutPrerequisiteProperty $snapshot 'kind'
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::$viewName)
                try {
                    $key = $base.OpenSubKey($keyPath)
                    try {
                        $exists = $null -ne $key -and $key.GetValueNames() -contains 'ExecutionPolicy'
                        $actual = if ($exists) { $key.GetValue('ExecutionPolicy') } else { $null }
                        $kind = if ($exists) { $key.GetValueKind('ExecutionPolicy').ToString() } else { $null }
                        $passed = $exists -eq $expectedExists -and ((-not $exists) -or ($actual -ceq $expectedValue -and $kind -eq $expectedKind))
                        $policyResults.Add([pscustomobject]@{
                            View = $viewName; Key = $keyPath; Passed = [bool]$passed
                            ExpectedExists = $expectedExists; ActualExists = $exists
                            ExpectedValue = $expectedValue; ActualValue = $actual; ExpectedKind = $expectedKind; ActualKind = $kind
                        })
                        if (-not $passed) { $findings.Add('ExecutionPolicy was not restored: ' + $viewName + ' / ' + $keyPath) }
                    } finally { if ($key) { $key.Dispose() } }
                } finally { $base.Dispose() }
            }
        }
        $markerPath = Join-Path $RepairLogRoot 'policy-restore-result.txt'
        $markerValid = [IO.File]::Exists($markerPath) -and [IO.File]::ReadAllText($markerPath).Trim() -ceq 'Original ExecutionPolicy values restored in both registry views.'
        if (-not $markerValid) { $findings.Add('The reviewed policy restoration marker is missing or does not match.') }
    } catch { $findings.Add('ExecutionPolicy verification failed: ' + $_.Exception.Message) }

    return [pscustomobject]@{
        Passed = [bool]($findings.Count -eq 0)
        Findings = @($findings.ToArray()); PackageRoot = $PackageRoot; RepairLogRoot = $RepairLogRoot
        CheckedUtc = [datetime]::UtcNow.ToString('o'); WrapperExitCode = $wrapperExit
        NetFx3InstallState = $featureState; SystemLocale = $locale
        SourceCount = $sources.Count; ExpectedAssemblies = $expectedGroups
        VerifiedAssemblies = @($assemblies.ToArray() | Where-Object { $_.Passed }).Count
        Sources = @($sources.ToArray()); Assemblies = @($assemblies.ToArray())
        LoaderResults = @($loaders.ToArray()); RegistryResults = @($registryResults.ToArray())
        PolicyResults = @($policyResults.ToArray()); PolicyRestoreMarker = [bool]$markerValid
        Scope = 'Read-only prerequisite files, registry and restoration evidence. Registry version 2.0 is not proof of a running PowerShell 2.0 engine.'
    }
}

Export-ModuleMember -Function Test-MutPrerequisites
