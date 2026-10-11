# Reviewed media identities only. Importing this module has no system effects.
Set-StrictMode -Version 2.0

function Get-MutMediaProfile {
    [CmdletBinding()]
    param([ValidateSet('SEW25091','SEW26061-00')][string]$Release = 'SEW26061-00')
    if ($Release -ieq 'SEW25091') {
        return [pscustomobject]@{
            Release = 'SEW25091'
            ArchiveFileName = 'SEW25091.zip'
            ArchiveRoot = 'SEW25091'
            MediaHash = '1B1740A1834B0AF447A17BFFB2A220671728FBC9C8CB851C5F01859912427D03'
            ClassicVersion = 'PRG23061-03'
            SeVersion = 'SEW25091-00'
            SqlVersion = '12.0.4100.1'
        }
    }
    return [pscustomobject]@{
        Release = 'SEW26061-00'
        ArchiveFileName = 'SEW26061-00.zip'
        ArchiveRoot = 'SEW26061-00'
        MediaHash = 'A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8'
        ClassicVersion = 'PRG23061-03'
        SeVersion = 'SEW26061-00'
        SqlVersion = '12.0.4100.1'
    }
}

Export-ModuleMember -Function Get-MutMediaProfile
