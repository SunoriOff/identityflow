function New-IFADProvider {
    <#
    .SYNOPSIS
        Connecteur Active Directory (module ActiveDirectory des outils RSAT).

    .DESCRIPTION
        Les licences Microsoft 365 sont attribuées par groupe (licences basées sur les
        groupes, synchronisés par Entra Connect) : IdentityFlow n'a donc besoin que de
        l'annuaire local. Droits nécessaires : création et modification des comptes
        dans les OU gérées, et gestion des membres des groupes listés dans les règles.

    .PARAMETER Server
        Contrôleur de domaine à utiliser (recommandé : toujours le même, pour éviter
        les délais de réplication entre deux étapes).

    .PARAMETER ExchangeAttributes
        Le schéma contient les attributs Exchange (msExchHideFromAddressLists) :
        les départs sont alors masqués de la liste d'adresses.

    .EXAMPLE
        $ad = New-IFADProvider -Server dc01.exemple.local -ExchangeAttributes
    #>
    [CmdletBinding()]
    param(
        [string] $Server,
        [pscredential] $Credential,
        [switch] $ExchangeAttributes
    )

    if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        Import-Module ActiveDirectory -ErrorAction Stop
    }

    $common = @{}
    if ($Server) { $common.Server = $Server }
    if ($Credential) { $common.Credential = $Credential }

    $props = @('EmployeeID', 'Title', 'Department', 'Office', 'Company', 'DisplayName', 'GivenName', 'Surname',
        'Description', 'AccountExpirationDate', 'Manager', 'MemberOf', 'mail', 'UserPrincipalName', 'Enabled')
    if ($ExchangeAttributes) { $props += 'msExchHideFromAddressLists' }

    $p = [pscustomobject]@{
        PSTypeName          = 'IdentityFlow.Provider'
        Name                = 'Active Directory' + $(if ($Server) { " ($Server)" } else { '' })
        SupportsOU          = $true
        SupportsHideFromGal = [bool]$ExchangeAttributes
        SupportsRevoke      = $false
        Common              = $common
        Properties          = $props
    }

    $p | Add-Member ScriptMethod ToUser {
        param($ad)
        if ($null -eq $ad) { return $null }
        $c = $this.Common
        $managerLogin = $null
        if ($ad.Manager) { $managerLogin = (Get-ADUser -Identity $ad.Manager @c).SamAccountName }
        $groups = foreach ($dn in @($ad.MemberOf)) {
            if ($dn -match '^CN=((?:\\,|[^,])+),') { $Matches[1] -replace '\\,', ',' }
        }
        $hidden = $false
        if ($ad.PSObject.Properties['msExchHideFromAddressLists']) { $hidden = [bool]$ad.msExchHideFromAddressLists }
        [pscustomobject]@{
            Login                 = $ad.SamAccountName
            Upn                   = $ad.UserPrincipalName
            Mail                  = $ad.mail
            DisplayName           = $ad.DisplayName
            GivenName             = $ad.GivenName
            Surname               = $ad.Surname
            EmployeeId            = $ad.EmployeeID
            Title                 = $ad.Title
            Department            = $ad.Department
            Office                = $ad.Office
            Company               = $ad.Company
            OU                    = ($ad.DistinguishedName -replace '^CN=(?:\\,|[^,])+,', '')
            Enabled               = [bool]$ad.Enabled
            ManagerLogin          = $managerLogin
            Groups                = @($groups | Sort-Object)
            Description           = $ad.Description
            AccountExpires        = $ad.AccountExpirationDate
            HiddenFromAddressList = $hidden
        }
    }
    $p | Add-Member ScriptMethod FindByEmployeeId {
        param([string] $id)
        $c = $this.Common
        $safe = $id.Replace("'", "''")
        $found = @(Get-ADUser -Filter "EmployeeID -eq '$safe'" -Properties $this.Properties @c)
        if ($found.Count -gt 1) { throw "Matricule $id porté par $($found.Count) comptes : $(($found.SamAccountName) -join ', ')" }
        if ($found.Count -eq 0) { return $null }
        return $this.ToUser($found[0])
    }
    $p | Add-Member ScriptMethod GetUser {
        param([string] $login)
        $c = $this.Common
        $safe = $login.Replace("'", "''")
        $u = Get-ADUser -Filter "SamAccountName -eq '$safe'" -Properties $this.Properties @c
        return $this.ToUser($u)
    }
    $p | Add-Member ScriptMethod LoginExists {
        param([string] $login)
        $c = $this.Common
        $safe = $login.Replace("'", "''")
        $hit = Get-ADObject -Filter "SamAccountName -eq '$safe' -or UserPrincipalName -like '$safe@*' -or proxyAddresses -like 'smtp:$safe@*'" @c
        return ($null -ne $hit)
    }
    $p | Add-Member ScriptMethod NewUser {
        param([hashtable] $d, [securestring] $password)
        $c = $this.Common
        $params = @{
            Name                  = $d.DisplayName
            SamAccountName        = $d.Login
            UserPrincipalName     = $d.Upn
            EmailAddress          = $d.Mail
            GivenName             = $d.GivenName
            Surname               = $d.Surname
            DisplayName           = $d.DisplayName
            EmployeeID            = $d.EmployeeId
            Path                  = $d.OU
            AccountPassword       = $password
            ChangePasswordAtLogon = $true
            Enabled               = $true
        }
        foreach ($k in @('Title', 'Department', 'Office', 'Company')) { if ($d[$k]) { $params[$k] = $d[$k] } }
        if ($d.AccountExpires) { $params.AccountExpirationDate = [datetime]$d.AccountExpires }
        try {
            New-ADUser @params @c -ErrorAction Stop
        }
        catch {
            # Homonyme dans la même OU : le CN doit être unique, on le précise avec l'identifiant.
            if ($_.Exception.GetType().Name -ne 'ADIdentityAlreadyExistsException') { throw }
            $params.Name = '{0} ({1})' -f $d.DisplayName, $d.Login
            New-ADUser @params @c -ErrorAction Stop
        }
    }
    $p | Add-Member ScriptMethod SetAttribute {
        param([string] $login, [string] $name, $value)
        $c = $this.Common
        switch ($name) {
            'AccountExpires' {
                if ($value) { Set-ADAccountExpiration -Identity $login -DateTime ([datetime]$value) @c -ErrorAction Stop }
                else { Clear-ADAccountExpiration -Identity $login @c -ErrorAction Stop }
            }
            'HiddenFromAddressList' {
                Set-ADUser -Identity $login -Replace @{ msExchHideFromAddressLists = [bool]$value } @c -ErrorAction Stop
            }
            default {
                if ([string]::IsNullOrEmpty([string]$value)) { Set-ADUser -Identity $login -Clear $name @c -ErrorAction Stop }
                else {
                    $set = @{ $name = $value }
                    Set-ADUser -Identity $login @set @c -ErrorAction Stop
                }
            }
        }
    }
    $p | Add-Member ScriptMethod MoveUser {
        param([string] $login, [string] $ou)
        $c = $this.Common
        $dn = (Get-ADUser -Identity $login @c).DistinguishedName
        Move-ADObject -Identity $dn -TargetPath $ou @c -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod AddToGroup {
        param([string] $login, [string] $group)
        $c = $this.Common
        Add-ADGroupMember -Identity $group -Members $login @c -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod RemoveFromGroup {
        param([string] $login, [string] $group)
        $c = $this.Common
        Remove-ADGroupMember -Identity $group -Members $login -Confirm:$false @c -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod SetManager {
        param([string] $login, [string] $managerLogin)
        $c = $this.Common
        if ($managerLogin) { Set-ADUser -Identity $login -Manager $managerLogin @c -ErrorAction Stop }
        else { Set-ADUser -Identity $login -Clear manager @c -ErrorAction Stop }
    }
    $p | Add-Member ScriptMethod SetEnabled {
        param([string] $login, [bool] $enabled)
        $c = $this.Common
        if ($enabled) { Enable-ADAccount -Identity $login @c -ErrorAction Stop }
        else { Disable-ADAccount -Identity $login @c -ErrorAction Stop }
    }
    $p | Add-Member ScriptMethod ResetPassword {
        param([string] $login, [securestring] $password, [bool] $mustChange)
        $c = $this.Common
        Set-ADAccountPassword -Identity $login -Reset -NewPassword $password @c -ErrorAction Stop
        Set-ADUser -Identity $login -ChangePasswordAtLogon $mustChange @c -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod RevokeSessions { param([string] $login) }
    $p | Add-Member ScriptMethod RemoveUser {
        param([string] $login)
        $c = $this.Common
        Remove-ADUser -Identity $login -Confirm:$false @c -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod GetUsersInOU {
        param([string] $ou)
        $c = $this.Common
        foreach ($u in @(Get-ADUser -Filter * -SearchBase $ou -SearchScope OneLevel -Properties $this.Properties @c)) {
            $this.ToUser($u)
        }
    }
    $p | Add-Member ScriptMethod Save { }
    return $p
}
