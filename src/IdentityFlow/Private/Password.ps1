function Get-IFRandomInt {
    <# Entier uniforme dans [0, Max[, tiré du générateur cryptographique (sans biais de modulo). #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.RandomNumberGenerator] $Rng,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int] $Max
    )
    $buf = New-Object byte[] 4
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Max)
    do {
        $Rng.GetBytes($buf)
        $n = [System.BitConverter]::ToUInt32($buf, 0)
    } while ($n -ge $limit)
    return [int]($n % [uint32]$Max)
}

function New-IFPassword {
    <#
    .SYNOPSIS
        Mot de passe aléatoire (générateur cryptographique), renvoyé en SecureString.
        Il contient au moins une majuscule, une minuscule, un chiffre et un symbole ;
        les caractères ambigus (0/O, 1/l/I) sont exclus pour faciliter la saisie.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([ValidateRange(12, 128)][int] $Length = 16)

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@_')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($s in $sets) { $chars.Add($s[(Get-IFRandomInt -Rng $rng -Max $s.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(Get-IFRandomInt -Rng $rng -Max $all.Length)]) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-IFRandomInt -Rng $rng -Max ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        $secure = New-Object System.Security.SecureString
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        $rng.Dispose()
    }
}
