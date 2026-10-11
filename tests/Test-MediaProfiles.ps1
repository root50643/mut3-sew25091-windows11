[CmdletBinding()]
param()

# Temporary ZIP fixtures only. No vendor content, installer, SQL, or registry is executed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run these tests with Windows PowerShell 5.1.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'scripts\Mut-OneClick.Core.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mut-media-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:caseNumber = 0

function Assert-True($Actual, [string]$Message = 'Expected true.') {
    if (-not $Actual) { throw $Message }
}
function Assert-Equal($Expected, $Actual) {
    if ($Expected -cne $Actual) { throw ('Expected [{0}], actual [{1}].' -f $Expected, $Actual) }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception }
    Assert-True ($null -ne $failure) 'Expected rejection.'
    Assert-True ($failure.Message -match $Pattern) ('Unexpected error: ' + $failure.Message)
}
function Invoke-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}
function New-CaseFolder {
    $script:caseNumber++
    $folder = Join-Path $testRoot ('case-{0:000}' -f $script:caseNumber)
    $null = New-Item -ItemType Directory -Path $folder
    return $folder
}
function New-TestArchive([string]$Path, [string[]]$Entries) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            $entryStream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes('fixture data; never execute')
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally { $entryStream.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

try {
    $roots = @('SEW25091','SEW26061-00','ps2DLC')
    foreach ($root in $roots) {
        Invoke-Case ($root + ' exact profile manifest and extraction') {
            $folder = New-CaseFolder
            $path = Join-Path $folder 'media.zip'
            $hash = New-TestArchive $path @($root + '/readme.txt')
            $manifest = Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $root
            Assert-Equal $root $manifest.RootName
            Assert-Equal $hash $manifest.ArchiveSha256
            $destination = Join-Path $folder 'output'
            $target = Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $root -DestinationParent $destination
            Assert-Equal (Join-Path $destination $root) $target
            Assert-Equal 'fixture data; never execute' ([IO.File]::ReadAllText((Join-Path $target 'readme.txt')))
            Assert-Equal $target (Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $root -DestinationParent $destination)
        }
        Invoke-Case ($root + ' remains compatible when ExpectedRoot is omitted') {
            $folder = New-CaseFolder
            $path = Join-Path $folder 'media.zip'
            $hash = New-TestArchive $path @($root + '/readme.txt')
            Assert-Equal $root (Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash).RootName
            Assert-Equal (Join-Path $folder $root) (Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -DestinationParent $folder)
        }
        Invoke-Case ($root + ' matching root never bypasses hash validation') {
            $folder = New-CaseFolder
            $path = Join-Path $folder 'media.zip'
            $hash = New-TestArchive $path @($root + '/readme.txt')
            $wrongHash = if ($hash -eq ('A' * 64)) { 'B' * 64 } else { 'A' * 64 }
            $destination = Join-Path $folder 'output'
            Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $wrongHash -ExpectedRoot $root } 'SHA-256 mismatch'
            Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $wrongHash -ExpectedRoot $root -DestinationParent $destination } 'SHA-256 mismatch'
            Assert-True (-not (Test-Path -LiteralPath $destination)) 'Hash failure must not create extraction output.'
        }
        foreach ($otherRoot in @($roots | Where-Object { $_ -cne $root })) {
            Invoke-Case ($root + ' cannot satisfy expected root ' + $otherRoot) {
                $folder = New-CaseFolder
                $path = Join-Path $folder 'media.zip'
                $hash = New-TestArchive $path @($root + '/readme.txt')
                $destination = Join-Path $folder 'output'
                Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $otherRoot } 'Archive root mismatch'
                Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $otherRoot -DestinationParent $destination } 'Archive root mismatch'
                Assert-True (-not (Test-Path -LiteralPath $destination)) 'Root mismatch must not create extraction output.'
            }
        }
    }
    foreach ($unsupported in @('SEW99999','SEW26061','sew26061-00','SEW26061-00/child','')) {
        Invoke-Case ('Unsupported expected root rejected: [' + $unsupported + ']') {
            $folder = New-CaseFolder
            $path = Join-Path $folder 'media.zip'
            $hash = New-TestArchive $path @('SEW26061-00/readme.txt')
            $destination = Join-Path $folder 'output'
            Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $unsupported } 'Unsupported expected archive root'
            Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -ExpectedRoot $unsupported -DestinationParent $destination } 'Unsupported expected archive root'
            Assert-True (-not (Test-Path -LiteralPath $destination))
        }
    }
    foreach ($unsupportedArchiveRoot in @('SEW99999','SEW26061','sew26061-00')) {
        Invoke-Case ('Unknown archive root rejected without profile: ' + $unsupportedArchiveRoot) {
            $folder = New-CaseFolder
            $path = Join-Path $folder 'media.zip'
            $hash = New-TestArchive $path @($unsupportedArchiveRoot + '/readme.txt')
            Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash } 'Unexpected archive root'
        }
    }
    Invoke-Case 'Mixed reviewed media roots are rejected' {
        $folder = New-CaseFolder
        $path = Join-Path $folder 'media.zip'
        $hash = New-TestArchive $path @('SEW25091/readme.txt','SEW26061-00/readme.txt')
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash } 'more than one top-level'
        Assert-Throws { Get-MutZipManifest -ArchivePath $path -ExpectedHash $hash -ExpectedRoot 'SEW26061-00' } 'Archive root mismatch'
    }
    Invoke-Case 'New media profile retains traversal rejection' {
        $folder = New-CaseFolder
        $path = Join-Path $folder 'media.zip'
        $hash = New-TestArchive $path @('SEW26061-00/../escape.txt')
        $destination = Join-Path $folder 'output'
        Assert-Throws { Expand-MutVerifiedArchive -ArchivePath $path -ExpectedHash $hash -ExpectedRoot 'SEW26061-00' -DestinationParent $destination } 'Unsafe Windows ZIP path'
        Assert-True (-not (Test-Path -LiteralPath $destination))
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $folder 'escape.txt')))
    }
} finally {
    # Only remove this invocation's verified GUID directory within the temporary directory.
    $absolute = [IO.Path]::GetFullPath($testRoot)
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($absolute) -notmatch '^mut-media-tests-[a-f0-9]{32}$') {
        throw 'Refusing test cleanup outside the expected temporary directory.'
    }
    if (Test-Path -LiteralPath $absolute) {
        if (((Get-Item -LiteralPath $absolute -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing cleanup of a replaced test directory.'
        }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
$failed = @($script:results | Where-Object { -not $_.Passed })
[ordered]@{ Total = $script:results.Count; Passed = $script:results.Count - $failed.Count; Failed = $failed.Count; Failures = @($failed) } | ConvertTo-Json -Depth 4
if ($failed.Count) { exit 1 }
exit 0
