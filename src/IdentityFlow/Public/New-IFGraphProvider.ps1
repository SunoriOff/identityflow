function New-IFGraphProvider {
    <#
    .SYNOPSIS
        Connecteur Entra ID (Microsoft Graph PowerShell), pour les comptes « cloud only ».

    .DESCRIPTION
        À utiliser après Connect-MgGraph avec les autorisations User.ReadWrite.All,
        GroupMember.ReadWrite.All et User.RevokeSessions.All (application ou délégué).
        Entra ID n'a pas d'OU : les déplacements sont ignorés. Les licences sont
        attribuées par groupe, comme pour Active Directory. Au départ, les sessions
        ouvertes sont révoquées (jetons d'actualisation invalidés).

    .PARAMETER UsageLocation
        Pays d'utilisation, requis par Microsoft 365 pour attribuer une licence.

    .EXAMPLE
        Connect-MgGraph -Scopes User.ReadWrite.All, GroupMember.ReadWrite.All, User.RevokeSessions.All
        $entra = New-IFGraphProvider
    #>
    [CmdletBinding()]
    param([ValidatePattern('^[A-Z]{2}$')][string] $UsageLocation = 'FR')

    if (-not (Get-Command -Name Get-MgUser -ErrorAction SilentlyContinue)) {
        Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions -ErrorAction Stop
    }

    $p = [pscustomobject]@{
        PSTypeName          = 'IdentityFlow.Provider'
        Name                = 'Entra ID (Microsoft Graph)'
        SupportsOU          = $false
        SupportsHideFromGal = $false
        SupportsRevoke      = $true
        UsageLocation       = $UsageLocation
        GroupIds            = @{}
        Select              = @('id', 'userPrincipalName', 'mail', 'mailNickname', 'displayName', 'givenName', 'surname',
            'employeeId', 'jobTitle', 'department', 'officeLocation', 'companyName', 'accountEnabled')
    }

    $p | Add-Member ScriptMethod GroupId {
        param([string] $name)
        if (-not $this.GroupIds.ContainsKey($name)) {
            $safe = $name.Replace("'", "''")
            $g = @(Get-MgGroup -Filter "displayName eq '$safe'" -Property id, displayName)
            if ($g.Count -ne 1) { throw "Groupe introuvable ou ambigu dans Entra ID : $name" }
            $this.GroupIds[$name] = $g[0].Id
        }
        return $this.GroupIds[$name]
    }
    $p | Add-Member ScriptMethod Raw {
        param([string] $login)
        $safe = $login.Replace("'", "''")
        $u = @(Get-MgUser -Filter "mailNickname eq '$safe'" -Property $this.Select)
        if ($u.Count -eq 0) { throw "Compte introuvable : $login" }
        return $u[0]
    }
    $p | Add-Member ScriptMethod ToUser {
        param($g)
        if ($null -eq $g) { return $null }
        $groups = @(Get-MgUserMemberOf -UserId $g.Id -All | ForEach-Object {
                if ($_.AdditionalProperties -and $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group') {
                    $_.AdditionalProperties['displayName']
                }
            })
        $managerLogin = $null
        try {
            $m = Get-MgUserManager -UserId $g.Id -ErrorAction Stop
            if ($m -and $m.AdditionalProperties) { $managerLogin = $m.AdditionalProperties['mailNickname'] }
        }
        catch { $managerLogin = $null }
        [pscustomobject]@{
            Login                 = $g.MailNickname
            Upn                   = $g.UserPrincipalName
            Mail                  = $g.Mail
            DisplayName           = $g.DisplayName
            GivenName             = $g.GivenName
            Surname               = $g.Surname
            EmployeeId            = $g.EmployeeId
            Title                 = $g.JobTitle
            Department            = $g.Department
            Office                = $g.OfficeLocation
            Company               = $g.CompanyName
            OU                    = $null
            Enabled               = [bool]$g.AccountEnabled
            ManagerLogin          = $managerLogin
            Groups                = @($groups | Sort-Object)
            Description           = $null
            AccountExpires        = $null
            HiddenFromAddressList = $false
        }
    }
    $p | Add-Member ScriptMethod FindByEmployeeId {
        param([string] $id)
        $safe = $id.Replace("'", "''")
        $found = @(Get-MgUser -Filter "employeeId eq '$safe'" -ConsistencyLevel eventual -CountVariable n -Property $this.Select)
        if ($found.Count -gt 1) { throw "Matricule $id porté par plusieurs comptes Entra ID." }
        if ($found.Count -eq 0) { return $null }
        return $this.ToUser($found[0])
    }
    $p | Add-Member ScriptMethod GetUser {
        param([string] $login)
        $safe = $login.Replace("'", "''")
        $u = @(Get-MgUser -Filter "mailNickname eq '$safe'" -Property $this.Select)
        if ($u.Count -eq 0) { return $null }
        return $this.ToUser($u[0])
    }
    $p | Add-Member ScriptMethod LoginExists {
        param([string] $login)
        $safe = $login.Replace("'", "''")
        $u = @(Get-MgUser -Filter "mailNickname eq '$safe' or startswith(userPrincipalName,'$safe@')" -Property id)
        return ($u.Count -gt 0)
    }
    $p | Add-Member ScriptMethod NewUser {
        param([hashtable] $d, [securestring] $password)
        $plain = [System.Net.NetworkCredential]::new('', $password).Password
        try {
            $body = @{
                accountEnabled    = $true
                displayName       = $d.DisplayName
                mailNickname      = $d.Login
                userPrincipalName = $d.Upn
                givenName         = $d.GivenName
                surname           = $d.Surname
                employeeId        = $d.EmployeeId
                usageLocation     = $this.UsageLocation
                passwordProfile   = @{ password = $plain; forceChangePasswordNextSignIn = $true }
            }
            foreach ($pair in @(@('Title', 'jobTitle'), @('Department', 'department'), @('Office', 'officeLocation'), @('Company', 'companyName'))) {
                if ($d[$pair[0]]) { $body[$pair[1]] = $d[$pair[0]] }
            }
            New-MgUser -BodyParameter $body -ErrorAction Stop | Out-Null
        }
        finally { $plain = $null }
    }
    $p | Add-Member ScriptMethod SetAttribute {
        param([string] $login, [string] $name, $value)
        $map = @{ Title = 'jobTitle'; Department = 'department'; Office = 'officeLocation'; Company = 'companyName'; DisplayName = 'displayName' }
        if (-not $map.ContainsKey($name)) { return }  # Description, expiration, masquage : sans équivalent Graph
        $id = $this.Raw($login).Id
        Update-MgUser -UserId $id -BodyParameter @{ $map[$name] = $value } -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod MoveUser { param([string] $login, [string] $ou) }
    $p | Add-Member ScriptMethod AddToGroup {
        param([string] $login, [string] $group)
        New-MgGroupMember -GroupId $this.GroupId($group) -DirectoryObjectId $this.Raw($login).Id -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod RemoveFromGroup {
        param([string] $login, [string] $group)
        Remove-MgGroupMemberDirectoryObjectByRef -GroupId $this.GroupId($group) -DirectoryObjectId $this.Raw($login).Id -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod SetManager {
        param([string] $login, [string] $managerLogin)
        $id = $this.Raw($login).Id
        if ($managerLogin) {
            $mid = $this.Raw($managerLogin).Id
            Set-MgUserManagerByRef -UserId $id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$mid" } -ErrorAction Stop
        }
        else { Remove-MgUserManagerByRef -UserId $id -ErrorAction Stop }
    }
    $p | Add-Member ScriptMethod SetEnabled {
        param([string] $login, [bool] $enabled)
        Update-MgUser -UserId $this.Raw($login).Id -AccountEnabled:$enabled -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod ResetPassword {
        param([string] $login, [securestring] $password, [bool] $mustChange)
        $plain = [System.Net.NetworkCredential]::new('', $password).Password
        try {
            Update-MgUser -UserId $this.Raw($login).Id -PasswordProfile @{ password = $plain; forceChangePasswordNextSignIn = $mustChange } -ErrorAction Stop
        }
        finally { $plain = $null }
    }
    $p | Add-Member ScriptMethod RevokeSessions {
        param([string] $login)
        Revoke-MgUserSignInSession -UserId $this.Raw($login).Id -ErrorAction Stop | Out-Null
    }
    $p | Add-Member ScriptMethod RemoveUser {
        param([string] $login)
        Remove-MgUser -UserId $this.Raw($login).Id -ErrorAction Stop
    }
    $p | Add-Member ScriptMethod GetUsersInOU {
        param([string] $ou)
        throw "La purge n'est pas prise en charge dans Entra ID : un compte supprimé y reste 30 jours dans la corbeille."
    }
    $p | Add-Member ScriptMethod Save { }
    return $p
}
