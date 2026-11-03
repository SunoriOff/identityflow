function Resolve-IFUniqueLogin {
    <#
    .SYNOPSIS
        Rend un identifiant unique : jean.dupont, puis jean.dupont2, jean.dupont3…
        en tenant compte de l'annuaire ET des identifiants déjà attribués dans le lot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $BaseLogin,
        [Parameter(Mandatory)] $Provider,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $Reserved,
        [int] $MaxLength = 20
    )
    for ($i = 1; $i -lt 100; $i++) {
        $suffix = if ($i -eq 1) { '' } else { [string]$i }
        $stem = $BaseLogin
        if (($stem.Length + $suffix.Length) -gt $MaxLength) {
            $stem = $stem.Substring(0, $MaxLength - $suffix.Length).TrimEnd('.', '-')
        }
        $candidate = $stem + $suffix
        if (-not $Reserved.Contains($candidate) -and -not $Provider.LoginExists($candidate)) {
            [void]$Reserved.Add($candidate)
            return $candidate
        }
    }
    throw "Aucun identifiant libre à partir de « $BaseLogin »."
}
