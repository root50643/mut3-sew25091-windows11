# Pure decisions, evidence parsing, and guarded media/state I/O for Windows PowerShell 5.1.
# Importing this module does not create files or change the machine.
Set-StrictMode -Version 2.0

function Get-MutProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-MutFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).ProviderPath $Path
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-MutNoReparsePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $cursor = Get-MutFullPath $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a junction, symbolic link, or other reparse point: $cursor"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor.TrimEnd('\','/'))
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-MutStreamSha256 {
    param([Parameter(Mandatory=$true)][System.IO.Stream]$Stream)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-','') }
    finally { $algorithm.Dispose() }
}

function Get-MutFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return Get-MutStreamSha256 $stream }
    finally { $stream.Dispose() }
}

function Get-MutZipManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedHash,
        [string]$ExpectedRoot
    )
    $allowedRoots = @('SEW25091','SEW26061-00','ps2DLC')
    if ($PSBoundParameters.ContainsKey('ExpectedRoot') -and $ExpectedRoot -cnotin $allowedRoots) {
        throw "Unsupported expected archive root: $ExpectedRoot"
    }
    $fullArchive = Get-MutFullPath $ArchivePath
    Assert-MutNoReparsePath $fullArchive
    if (-not (Test-Path -LiteralPath $fullArchive -PathType Leaf)) { throw "Archive is missing: $fullArchive" }
    $archiveHash = Get-MutFileSha256 $fullArchive
    if ($archiveHash -ne $ExpectedHash) { throw "Archive SHA-256 mismatch: $fullArchive; expected $ExpectedHash; actual $archiveHash" }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($fullArchive)
    try {
        $files = New-Object 'System.Collections.Generic.List[object]'
        $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $fileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $rootName = $null
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if (-not $name -or $name.StartsWith('/') -or $name.Contains('//') -or $name.Contains(':')) {
                throw "Unsafe ZIP entry: $($entry.FullName)"
            }
            $isDirectory = $name.EndsWith('/')
            $name = $name.TrimEnd('/')
            $parts = @($name.Split('/'))
            foreach ($part in $parts) {
                if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or
                    $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
                    throw "Unsafe Windows ZIP path: $($entry.FullName)"
                }
            }
            if ($parts[0] -cnotin $allowedRoots) { throw "Unexpected archive root: $($parts[0])" }
            if ($PSBoundParameters.ContainsKey('ExpectedRoot') -and $parts[0] -cne $ExpectedRoot) {
                throw "Archive root mismatch: expected $ExpectedRoot; actual $($parts[0])"
            }
            if ($null -eq $rootName) { $rootName = $parts[0] }
            if ($rootName -cne $parts[0]) { throw 'ZIP has more than one top-level directory.' }
            if (-not $seen.Add($name)) { throw "Duplicate ZIP path (case-insensitive): $name" }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000 -or (($entry.ExternalAttributes -band 0x400) -ne 0)) {
                throw "ZIP contains a link/reparse entry: $name"
            }
            if ($parts.Count -eq 1) {
                if (-not $isDirectory) { throw 'ZIP top-level item must be a directory.' }
                continue
            }
            $relative = [string]::Join('/', $parts[1..($parts.Count - 1)])
            for ($index = 1; $index -lt $parts.Count - 1; $index++) {
                [void]$directories.Add([string]::Join('/', $parts[1..$index]))
            }
            if ($isDirectory) { [void]$directories.Add($relative); continue }
            [void]$fileNames.Add($relative)
            $entryStream = $entry.Open()
            try { $entryHash = Get-MutStreamSha256 $entryStream }
            finally { $entryStream.Dispose() }
            $files.Add([pscustomobject]@{
                ArchiveEntry = $entry.FullName; RelativePath = $relative
                Length = [long]$entry.Length; Sha256 = $entryHash
            })
        }
        if (-not $rootName -or $files.Count -eq 0) { throw 'ZIP has no installable files.' }
        foreach ($directory in $directories) {
            if ($fileNames.Contains($directory)) { throw "ZIP file/directory collision: $directory" }
        }
        return [pscustomobject]@{
            ArchivePath = $fullArchive; ArchiveSha256 = $archiveHash; RootName = $rootName
            Files = @($files.ToArray()); Directories = @($directories | Sort-Object)
        }
    } finally { $archive.Dispose() }
}

function Get-MutContainedPath {
    param([string]$Root, [string]$RelativePath)
    $fullRoot = (Get-MutFullPath $Root).TrimEnd('\','/')
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $fullRoot $RelativePath.Replace('/','\')))
    if (-not $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its allowed root: $fullPath"
    }
    return $fullPath
}

function Assert-MutExtractedTree {
    param([string]$Target, $Manifest)
    Assert-MutNoReparsePath $Target
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw "Expected directory is missing: $Target" }
    $expectedFiles = @{}
    foreach ($entry in $Manifest.Files) { $expectedFiles[$entry.RelativePath] = $entry }
    $expectedDirectories = @{}
    foreach ($entry in $Manifest.Directories) { $expectedDirectories[$entry] = $true }
    $fullRoot = (Get-MutFullPath $Target).TrimEnd('\','/')
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($fullRoot)
    $found = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($path in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Extracted tree contains a reparse point: $path" }
            $relative = $path.Substring($fullRoot.Length + 1).Replace('\','/')
            if ($item.PSIsContainer) {
                if (-not $expectedDirectories.ContainsKey($relative)) { throw "Unknown existing directory; nothing overwritten: $path" }
                $pending.Push($path)
                continue
            }
            if (-not $expectedFiles.ContainsKey($relative)) { throw "Unknown existing file; nothing overwritten: $path" }
            $expected = $expectedFiles[$relative]
            if ($item.Length -ne $expected.Length -or (Get-MutFileSha256 $path) -ne $expected.Sha256) {
                throw "Existing file differs from verified archive; nothing overwritten: $path"
            }
            $found++
        }
    }
    if ($found -ne $Manifest.Files.Count) { throw "Existing extraction is incomplete; nothing overwritten: $Target" }
    foreach ($relative in $Manifest.Directories) {
        if (-not (Test-Path -LiteralPath (Get-MutContainedPath $Target $relative) -PathType Container)) {
            throw "Existing extraction is missing directory: $relative"
        }
    }
}

function Expand-MutVerifiedArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$DestinationParent,
        [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedHash,
        [string]$ExpectedRoot
    )
    $manifestArguments = @{ ArchivePath = $ArchivePath; ExpectedHash = $ExpectedHash }
    if ($PSBoundParameters.ContainsKey('ExpectedRoot')) { $manifestArguments.ExpectedRoot = $ExpectedRoot }
    $manifest = Get-MutZipManifest @manifestArguments
    $parent = Get-MutFullPath $DestinationParent
    Assert-MutNoReparsePath $parent
    $target = Get-MutContainedPath $parent $manifest.RootName
    if (Test-Path -LiteralPath $target) {
        Assert-MutExtractedTree -Target $target -Manifest $manifest
        return $target
    }
    [void][System.IO.Directory]::CreateDirectory($parent)
    $stage = Get-MutContainedPath $parent ('.' + $manifest.RootName + '.stage.' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($stage)
    try {
        # Lock the source against replacement throughout extraction and recheck its hash.
        $source = [System.IO.File]::Open($manifest.ArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            if ((Get-MutStreamSha256 $source) -ne $ExpectedHash) { throw 'Archive changed after verification.' }
            $source.Position = 0
            $archive = New-Object System.IO.Compression.ZipArchive($source, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                foreach ($relative in $manifest.Directories) {
                    [void][System.IO.Directory]::CreateDirectory((Get-MutContainedPath $stage $relative))
                }
                foreach ($file in $manifest.Files) {
                    $destination = Get-MutContainedPath $stage $file.RelativePath
                    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
                    $inputStream = $archive.GetEntry($file.ArchiveEntry).Open()
                    try {
                        $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        try { $inputStream.CopyTo($outputStream) }
                        finally { $outputStream.Dispose() }
                    } finally { $inputStream.Dispose() }
                }
            } finally { $archive.Dispose() }
        } finally { $source.Dispose() }
        Assert-MutExtractedTree -Target $stage -Manifest $manifest
        Assert-MutNoReparsePath $parent
        if (Test-Path -LiteralPath $target) { throw "Destination appeared during extraction; refusing to overwrite: $target" }
        [System.IO.Directory]::Move($stage, $target)
        return $target
    } finally {
        if (Test-Path -LiteralPath $stage) {
            # Only the random directory created by this invocation may be removed.
            $checkedStage = Get-MutContainedPath $parent ([System.IO.Path]::GetFileName($stage))
            if ($checkedStage -ne $stage) { throw 'Stage cleanup path did not match its allowed location.' }
            Assert-MutNoReparsePath $stage
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
        }
    }
}

function Get-MutInstLogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $result = [ordered]@{ Exists = $false; Hash = $null; Length = 0L; LastWriteUtc = $null; Content = ''; LastBlock = ''; LastLine = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }
    # Read bytes once so Content and Hash describe the same snapshot while an installer writes.
    $bytes = [System.IO.File]::ReadAllBytes((Get-MutFullPath $Path))
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $content = $encoding.GetString($bytes).TrimStart([char]0xFEFF)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','') }
    finally { $algorithm.Dispose() }
    $boundaries = [regex]::Matches($content, '(?m)^[ \t]*-{4,}[ \t]*\r?$')
    $block = ''
    if ($boundaries.Count -gt 0) {
        $last = $boundaries[$boundaries.Count - 1]
        $block = $content.Substring($last.Index + $last.Length).Trim()
    }
    $nonempty = @($block -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $result.Exists = $true; $result.Hash = $hash; $result.Length = [long]$bytes.LongLength
    $result.LastWriteUtc = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc.ToString('o')
    $result.Content = $content; $result.LastBlock = $block
    if ($nonempty.Count -gt 0) { $result.LastLine = $nonempty[$nonempty.Count - 1] }
    return [pscustomobject]$result
}

function Test-MutFreshInstallLog {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Before, [Parameter(Mandatory=$true)]$After,
        [Parameter(Mandatory=$true)][datetime]$StartedUtc)
    if (-not (Get-MutProperty $After 'Exists' $false)) { return $false }
    if ((Get-MutProperty $After 'LastLine' '') -cne '問題なし') { return $false }
    $lastWrite = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-MutProperty $After 'LastWriteUtc' ''), [ref]$lastWrite)) { return $false }
    if ($lastWrite.ToUniversalTime() -lt $StartedUtc.ToUniversalTime()) { return $false }
    $newContent = [string](Get-MutProperty $After 'Content' '')
    if (-not [regex]::IsMatch($newContent, '(?m)^[ \t]*-{4,}[ \t]*\r?$')) { return $false }
    if (-not (Get-MutProperty $Before 'Exists' $false)) { return $true }
    if ((Get-MutProperty $Before 'Hash' '') -eq (Get-MutProperty $After 'Hash' '')) { return $false }
    if ((Get-MutProperty $Before 'LastBlock' '') -ceq (Get-MutProperty $After 'LastBlock' '')) { return $false }
    $oldContent = [string](Get-MutProperty $Before 'Content' '')
    if ($newContent.StartsWith($oldContent, [System.StringComparison]::Ordinal)) {
        # Merely appending text to an old result cannot turn the old block into new evidence.
        $appended = $newContent.Substring($oldContent.Length)
        if (-not [regex]::IsMatch($appended, '(?m)^[ \t]*-{4,}[ \t]*\r?$')) { return $false }
    }
    return $true
}

function Assert-MutStateSchema {
    param($State)
    if ($null -eq $State -or $State -is [array] -or (Get-MutProperty $State 'SchemaVersion' 0) -ne 1) {
        throw 'Unknown or damaged state schema. Preserve the state file for diagnosis.'
    }
    $phase = [string](Get-MutProperty $State 'Phase' '')
    if ($phase -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') { throw 'State has an invalid or missing Phase.' }
    foreach ($name in @('BootUtc','RebootBootUtc','StartedUtc')) {
        $value = Get-MutProperty $State $name $null
        if ($null -ne $value -and [string]$value -ne '') {
            $parsed = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$value, [ref]$parsed)) { throw "State has an invalid timestamp: $name" }
        }
    }
}

function Read-MutState {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = Get-MutFullPath $Path
    Assert-MutNoReparsePath $fullPath
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 4194304) { throw 'State file is not a supported regular JSON file.' }
    try { $state = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "State file could not be parsed; preserve it for diagnosis: $fullPath. $($_.Exception.Message)" }
    Assert-MutStateSchema $state
    return $state
}

function Write-MutState {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$State)
    Assert-MutStateSchema $State
    $fullPath = Get-MutFullPath $Path
    Assert-MutNoReparsePath $fullPath
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    [void][System.IO.Directory]::CreateDirectory($parent)
    $temporary = $fullPath + '.tmp.' + [guid]::NewGuid().ToString('N')
    try {
        $json = $State | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($true)))
        # Replace is atomic and preserves the old state if the operation fails.
        if (Test-Path -LiteralPath $fullPath) { [System.IO.File]::Replace($temporary, $fullPath, [NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $fullPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
    }
}

function Test-MutRebootOccurred {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$PreviousBootUtc, [Parameter(Mandatory=$true)]$CurrentBootUtc)
    $previous = [datetime]::MinValue; $current = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$PreviousBootUtc, [ref]$previous) -or
        -not [datetime]::TryParse([string]$CurrentBootUtc, [ref]$current)) { return $false }
    return ($current.ToUniversalTime() -gt $previous.ToUniversalTime())
}

function Get-MutNextAction {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Facts, $State = $null)
    # Ambiguous processes take priority even when one known child also remains alive.
    if (Get-MutProperty $Facts 'BusyUnknown' $false) { return 'Review' }
    if (Get-MutProperty $Facts 'BusyOwned' $false) { return 'Monitor' }
    if (Get-MutProperty $Facts 'PendingReboot' $false) { return 'Reboot' }
    if ((Get-MutProperty $State 'Phase' '') -eq 'AwaitingReboot') {
        $previous = Get-MutProperty $State 'RebootBootUtc' (Get-MutProperty $State 'BootUtc' '')
        if (-not (Test-MutRebootOccurred -PreviousBootUtc $previous -CurrentBootUtc (Get-MutProperty $Facts 'BootUtc' ''))) { return 'Reboot' }
    }
    if (Get-MutProperty $Facts 'Healthy' $false) { return 'Verify' }
    if ((Get-MutProperty $Facts 'Unknown' $false) -or (Get-MutProperty $Facts 'ValidPartial' $false)) { return 'Review' }
    if (Get-MutProperty $Facts 'RecognizedFailed' $false) { return 'Cleanup' }
    if (Get-MutProperty $Facts 'Clean' $false) { return 'PrepareInstall' }
    return 'Review'
}

Export-ModuleMember -Function Get-MutZipManifest, Expand-MutVerifiedArchive, Get-MutInstLogEvidence, Test-MutFreshInstallLog, Read-MutState, Write-MutState, Test-MutRebootOccurred, Get-MutNextAction
