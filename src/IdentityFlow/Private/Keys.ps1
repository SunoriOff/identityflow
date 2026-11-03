function ConvertTo-IFKey {
    <# Clé de comparaison : sans accent, minuscules, espaces réduits. « Ressources  Humaines » = « ressources humaines ». #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return ((Remove-IFDiacritic -Text $Text.Trim()).ToLowerInvariant() -replace '\s+', ' ')
}

function Find-IFRuleEntry {
    <# Cherche une entrée de règle sans tenir compte de la casse ni des accents. #>
    [CmdletBinding()]
    param([hashtable] $Table, [string] $Name)
    if (-not $Table -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    $want = ConvertTo-IFKey $Name
    foreach ($k in $Table.Keys) {
        if ((ConvertTo-IFKey $k) -eq $want) {
            return [pscustomobject]@{ Name = [string]$k; Value = $Table[$k] }
        }
    }
    return $null
}

function Test-IFManagedGroup {
    <# Un groupe est « géré » s'il correspond à un des motifs ManagedGroups : seuls ceux-là sont retirés lors d'une mobilité. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Group, [string[]] $Patterns)
    foreach ($p in $Patterns) { if ($Group -like $p) { return $true } }
    return $false
}
