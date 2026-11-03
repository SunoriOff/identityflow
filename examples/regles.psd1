# IdentityFlow — règles d'attribution (exemple pour « Exemple SA »)
# Clés de service, de poste et de contrat : casse et accents indifférents.
@{
    Organisation  = @{
        Company        = 'Exemple SA'
        UpnSuffix      = 'exemple.fr'
        LoginFormat    = '{prenom}.{nom}'     # jetons : {prenom} {nom} {p} {matricule}
        LoginMaxLength = 20
        UsersOU        = 'OU=Utilisateurs,DC=exemple,DC=local'
        LeaversOU      = 'OU=Departs,DC=exemple,DC=local'
        JoinerLeadDays = 7                    # comptes créés une semaine avant l'arrivée
        RetentionDays  = 90                   # suppression 90 jours après le départ
        PasswordLength = 16
    }

    # Groupes dont IdentityFlow a la charge : seuls ceux-là sont retirés lors d'une mobilité.
    # Un groupe ajouté à la main hors de ces motifs n'est jamais touché.
    ManagedGroups = @('GG-*', 'LIC-*')

    # Pour tout le monde
    CommonGroups  = @('GG-Tous')

    # Par service : OU (relative à UsersOU), groupes, licence Microsoft 365 (groupe de licence)
    Services      = @{
        'Direction'           = @{ OU = 'OU=Direction'; Groups = @('GG-Direction'); License = 'LIC-M365-E3' }
        'Informatique'        = @{ OU = 'OU=Informatique'; Groups = @('GG-DSI'); License = 'LIC-M365-E3' }
        'Ressources humaines' = @{ OU = 'OU=RH'; Groups = @('GG-RH', 'GG-Partage-RH'); License = 'LIC-M365-E3' }
        'Comptabilité'        = @{ OU = 'OU=Finance'; Groups = @('GG-Compta', 'GG-Partage-Finance'); License = 'LIC-M365-E3' }
        'Commercial'          = @{ OU = 'OU=Commercial'; Groups = @('GG-Commerciaux', 'GG-CRM'); License = 'LIC-M365-BusinessPremium' }
        'Logistique'          = @{ OU = 'OU=Logistique'; Groups = @('GG-Logistique'); License = 'LIC-M365-F3' }
    }

    # Droits supplémentaires selon le poste
    Postes        = @{
        'Administrateur systèmes'  = @{ Groups = @('GG-Admins-Serveurs', 'GG-VPN') }
        'Administratrice systèmes' = @{ Groups = @('GG-Admins-Serveurs', 'GG-VPN') }
        'Responsable informatique' = @{ Groups = @('GG-Admins-Serveurs', 'GG-VPN') }
        'Chargé de clientèle'      = @{ Groups = @('GG-VPN') }
    }

    # Selon le contrat : groupes, licence, date de fin obligatoire (expiration du compte)
    Contrats      = @{
        'CDI'        = @{ }
        'CDD'        = @{ RequireEndDate = $true }
        'Alternance' = @{ RequireEndDate = $true; Groups = @('GG-Alternants') }
        'Stage'      = @{ RequireEndDate = $true; Groups = @('GG-Stagiaires'); License = 'LIC-M365-F3' }
        'Intérim'    = @{ RequireEndDate = $true; License = 'LIC-M365-F3' }
    }

    Arrivee       = @{
        Checklist = @(
            'Préparer le poste de travail et le téléphone'
            'Remettre le mot de passe temporaire en main propre'
        )
    }

    Depart        = @{
        HideFromAddressList = $true
        Checklist           = @(
            'Récupérer le matériel (poste, badge, téléphone)'
            'Convertir la boîte aux lettres en boîte partagée et en donner l''accès au manager'
            'Transférer les fichiers OneDrive au manager'
        )
    }
}
