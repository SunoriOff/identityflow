#Requires -Version 5.1
Set-StrictMode -Version 3.0

$script:ModuleRoot = $PSScriptRoot

foreach ($folder in @('Private', 'Public')) {
    $path = [System.IO.Path]::Combine($PSScriptRoot, $folder)
    Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, 'Public')) -Filter '*.ps1').BaseName
