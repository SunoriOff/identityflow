function Remove-IFDiacritic {
    <#
    .SYNOPSIS
        Retire les accents : « Hélène Çakır » devient « Helene Cakir ».
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $decomposed = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    # Ligatures et lettres sans décomposition
    $out = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    $pairs = @(@('œ', 'oe'), @('Œ', 'OE'), @('æ', 'ae'), @('Æ', 'AE'), @('ß', 'ss'), @('ø', 'o'), @('Ø', 'O'),
        @('ł', 'l'), @('Ł', 'L'), @('đ', 'd'), @('Đ', 'D'), @('ı', 'i'))
    foreach ($pair in $pairs) { $out = $out.Replace($pair[0], $pair[1]) }
    return $out
}

function ConvertTo-IFNamePart {
    <#
    .SYNOPSIS
        Prépare un prénom ou un nom pour un identifiant : minuscules, sans accent,
        sans espace ni apostrophe ; les traits d'union sont conservés.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $t = (Remove-IFDiacritic -Text $Text.Trim()).ToLowerInvariant()
    $t = $t -replace "[\s'’`´]+", ''
    $t = $t -replace '[^a-z0-9-]', ''
    $t = $t -replace '-{2,}', '-'
    return $t.Trim('-')
}

function ConvertTo-IFHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][object] $Text)
    if ($null -eq $Text) { return '' }
    # Seuls les caractères spéciaux HTML sont échappés : les accents restent lisibles dans la source.
    return ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Format-IFFirstName {
    <# « jean-PIERRE » → « Jean-Pierre », « marie claire » → « Marie Claire ». #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $FirstName)
    $ti = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR').TextInfo
    return (($FirstName.Trim() -split '-' | ForEach-Object { $ti.ToTitleCase($_.ToLowerInvariant()) }) -join '-')
}

function Format-IFDisplayName {
    <# « Jean-Pierre DUPONT » : prénom avec casse corrigée, nom en capitales. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $FirstName, [AllowEmptyString()][string] $LastName)
    return ('{0} {1}' -f (Format-IFFirstName $FirstName), $LastName.Trim().ToUpperInvariant()).Trim()
}

function ConvertTo-IFDate {
    [CmdletBinding()]
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $formats = [string[]]@('yyyy-MM-dd', 'dd/MM/yyyy', 'd/M/yyyy', 'yyyy-MM-ddTHH:mm:ss')
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text.Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d.Date
    }
    return $null
}
