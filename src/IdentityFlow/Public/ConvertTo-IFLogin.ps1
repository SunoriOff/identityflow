function ConvertTo-IFLogin {
    <#
    .SYNOPSIS
        Calcule l'identifiant (sAMAccountName) d'un collaborateur selon un modèle.

    .DESCRIPTION
        Modèle par défaut : {prenom}.{nom}. Jetons disponibles : {prenom}, {nom},
        {p} (initiale du prénom), {matricule}. Le résultat est sans accent, en minuscules,
        et tronqué à MaxLength caractères (20 pour un sAMAccountName) sans finir par
        un point ni un tiret.

    .EXAMPLE
        ConvertTo-IFLogin -FirstName 'Hélène' -LastName "N'Diaye"
        helene.ndiaye

    .EXAMPLE
        ConvertTo-IFLogin -FirstName 'Jean-Pierre' -LastName 'De La Fontaine' -Format '{p}{nom}'
        jdelafontaine
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $FirstName,
        [Parameter(Mandatory)][string] $LastName,
        [string] $EmployeeId = '',
        [string] $Format = '{prenom}.{nom}',
        [ValidateRange(3, 64)][int] $MaxLength = 20
    )

    $first = ConvertTo-IFNamePart -Text $FirstName
    $last = ConvertTo-IFNamePart -Text $LastName
    if (-not $first -or -not $last) {
        throw "Impossible de construire un identifiant pour « $FirstName $LastName »."
    }
    $login = $Format.Replace('{prenom}', $first).Replace('{nom}', $last).Replace('{p}', $first.Substring(0, 1)).Replace('{matricule}', $EmployeeId.ToLowerInvariant())
    if ($login.Length -gt $MaxLength) { $login = $login.Substring(0, $MaxLength) }
    return $login.TrimEnd('.', '-')
}
