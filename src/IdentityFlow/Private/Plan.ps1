$script:AttributeLabels = @{
    Title                 = 'Poste'
    Department            = 'Service'
    Office                = 'Site'
    Company               = 'Société'
    Description           = 'Description'
    AccountExpires        = 'Expiration du compte'
    HiddenFromAddressList = 'Masqué de la liste d''adresses'
}

$script:ActionLabels = @{ Arrivee = 'Arrivée'; Mobilite = 'Mobilité'; Depart = 'Départ' }

function New-IFPlanItem {
    [CmdletBinding()]
    param($Request)
    $name = if ($Request.FirstName -or $Request.LastName) { Format-IFDisplayName $Request.FirstName $Request.LastName } else { '' }
    [pscustomobject]@{
        PSTypeName  = 'IdentityFlow.PlanItem'
        Line        = $Request.Line
        Action      = $Request.Action
        ActionLabel = if ($Request.Action) { $script:ActionLabels[$Request.Action] } else { '?' }
        EmployeeId  = $Request.EmployeeId
        Name        = $name
        Login       = $null
        State       = 'Pending'
        Steps       = New-Object System.Collections.Generic.List[object]
        Checklist   = New-Object System.Collections.Generic.List[string]
        Messages    = New-Object System.Collections.Generic.List[string]
        Errors      = New-Object System.Collections.Generic.List[string]
        Request     = $Request
    }
}

function Add-IFStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][string] $Op,
        [Parameter(Mandatory)][string] $Text,
        [hashtable] $Params = @{}
    )
    $Item.Steps.Add([pscustomobject]@{
            PSTypeName = 'IdentityFlow.Step'
            Op         = $Op
            Text       = $Text
            Params     = $Params
            Outcome    = 'Planned'
            Error      = $null
        })
}

function Format-IFValue {
    param($Value)
    if ($null -eq $Value -or ([string]$Value) -eq '') { return '(vide)' }
    if ($Value -is [datetime]) { return $Value.ToString('dd/MM/yyyy') }
    if ($Value -is [bool]) { if ($Value) { return 'oui' } else { return 'non' } }
    return [string]$Value
}

function Test-IFSameValue {
    param($A, $B)
    if (($null -eq $A -or [string]$A -eq '') -and ($null -eq $B -or [string]$B -eq '')) { return $true }
    if ($A -is [datetime] -or $B -is [datetime]) {
        if ($null -eq $A -or $null -eq $B) { return $false }
        return ([datetime]$A).Date -eq ([datetime]$B).Date
    }
    return [string]$A -ceq [string]$B
}

function Add-IFReconcileStep {
    <#
    .SYNOPSIS
        Compare un compte existant à l'état voulu et ajoute les étapes de mise en conformité.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] $Current,
        [hashtable] $Attributes = @{},
        [string] $OU,
        [string[]] $Groups = @(),
        [string[]] $ManagedPatterns = @(),
        [string[]] $Preserve = @(),
        [string] $Manager = '<inchangé>',
        [Parameter(Mandatory)] $Provider
    )
    $login = $Current.Login
    foreach ($k in @('Title', 'Department', 'Office', 'Company', 'AccountExpires')) {
        if (-not $Attributes.ContainsKey($k)) { continue }
        $old = $Current.$k
        $new = $Attributes[$k]
        if (-not (Test-IFSameValue $old $new)) {
            Add-IFStep -Item $Item -Op 'SetAttribute' -Text ('{0} : {1} → {2}' -f $script:AttributeLabels[$k], (Format-IFValue $old), (Format-IFValue $new)) `
                -Params @{ Login = $login; Name = $k; Old = $old; New = $new }
        }
    }
    if ($OU -and $Provider.SupportsOU -and $Current.OU -ne $OU) {
        Add-IFStep -Item $Item -Op 'Move' -Text "Déplacer vers $OU" -Params @{ Login = $login; From = $Current.OU; To = $OU }
    }
    $have = @($Current.Groups)
    foreach ($g in $Groups) {
        if ($have -notcontains $g) {
            Add-IFStep -Item $Item -Op 'AddGroup' -Text "Ajouter au groupe $g" -Params @{ Login = $login; Group = $g }
        }
    }
    foreach ($g in $have) {
        if ($Groups -contains $g -or $Preserve -contains $g) { continue }
        if (Test-IFManagedGroup -Group $g -Patterns $ManagedPatterns) {
            Add-IFStep -Item $Item -Op 'RemoveGroup' -Text "Retirer du groupe $g" -Params @{ Login = $login; Group = $g }
        }
    }
    if ($Manager -ne '<inchangé>' -and -not (Test-IFSameValue $Current.ManagerLogin $Manager)) {
        Add-IFStep -Item $Item -Op 'SetManager' -Text ('Manager : {0} → {1}' -f (Format-IFValue $Current.ManagerLogin), (Format-IFValue $Manager)) `
            -Params @{ Login = $login; Old = $Current.ManagerLogin; New = $Manager }
    }
}

function Resolve-IFManagerLogin {
    <# Matricule du manager → identifiant, en cherchant d'abord dans les arrivées du lot. #>
    [CmdletBinding()]
    param([string] $ManagerId, [hashtable] $Planned, $Provider, $Item)
    if (-not $ManagerId) { return $null }
    if ($Planned.ContainsKey($ManagerId)) { return $Planned[$ManagerId] }
    $m = $Provider.FindByEmployeeId($ManagerId)
    if (-not $m) {
        $Item.Messages.Add("Manager $ManagerId introuvable : le champ manager n'est pas renseigné.")
        return '<inchangé>'
    }
    if (-not $m.Enabled) { $Item.Messages.Add("Le manager $ManagerId ($($m.Login)) est désactivé.") }
    return $m.Login
}

function Get-IFContractGroup {
    <# Groupes et licences liés aux contrats : conservés lors d'une mobilité (le contrat ne change pas). #>
    param([hashtable] $Rules)
    $out = @()
    foreach ($k in $Rules.Contrats.Keys) {
        $c = $Rules.Contrats[$k]
        if ($c.ContainsKey('Groups')) { $out += $c.Groups }
        if ($c.ContainsKey('License')) { $out += $c.License }
    }
    return $out
}
