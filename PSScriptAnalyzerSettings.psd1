@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Les fonctions New-IF*Provider et New-IFPassword créent des objets en mémoire,
        # elles ne modifient aucun système : -WhatIf n'aurait pas de sens.
        'PSUseShouldProcessForStateChangingFunctions'
        # « Rules » désigne un fichier de règles : le pluriel est voulu.
        'PSUseSingularNouns'
        # Le script de démonstration affiche en couleurs pour la lisibilité.
        'PSAvoidUsingWriteHost'
    )
}
