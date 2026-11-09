<#
.SYNOPSIS
    Crée des utilisateurs à partir d'un fichier CSV. Colonnes attendues : Prenom;Nom;Service;Login
.DESCRIPTION
    Lit un fichier CSV (séparateur ";", encodage UTF-8) et crée un compte Active Directory
    par ligne, dans l'OU correspondant au Service, sous OU=UTILISATEURS,OU=ENTREPRISE.
    L'OU doit déjà exister : le script ne la crée pas.

    Pour chaque utilisateur :
    - le nom complet est "Prenom Nom" ;
    - le Login devient le SamAccountName (20 caractères maximum, sans caractère interdit)
      et le préfixe de l'UPN (login@<domaine DNS>) ;
    - le compte est activé, avec un mot de passe temporaire saisi au lancement du script
      (demandé de façon masquée) que l'utilisateur doit changer à sa première connexion.

    Traitement des lignes :
    - un compte dont le SamAccountName existe déjà est ignoré (le script peut donc être relancé
      sans risque) ;
    - une ligne invalide (champ vide, login trop long ou avec caractère interdit, OU introuvable,
      UPN déjà utilisé) ou un échec de création est comptée comme une erreur ; le traitement
      continue avec la ligne suivante.

    Chaque action est journalisée dans C:\AD-Lab\Logs\New-ADUsersFromCsv.log. À la fin, un
    récapitulatif donne le nombre de comptes créés, ignorés et en erreur.
    Code de sortie : 0 si aucune erreur, 1 sinon (ou si le script est interrompu avant le
    traitement : CSV introuvable, colonnes manquantes, annuaire injoignable, mot de passe vide).
.PARAMETER CheminCSV
    Chemin du fichier CSV contenant les utilisateurs à créer, par défaut C:\AD-Lab\Data\utilisateurs.csv.
.PARAMETER Simulation
    Aucune modification n'est faite dans l'AD (équivalent -WhatIf).
.EXAMPLE
    .\New-ADUsersFromCsv.ps1 -CheminCSV "C:\Data\users.csv" -Simulation
#>

#Requires -Modules ActiveDirectory


param(
    [string]$CheminCSV,
    [switch]$Simulation
)

New-Variable -Name DnRacine -Value "OU=UTILISATEURS,OU=ENTREPRISE,DC=julien,DC=local" -Option ReadOnly -Force


$RepertoireLog = "C:\AD-Lab\Logs\"
$FichierLog = "New-ADUsersFromCsv.log"
$CheminLog = Join-Path -Path $RepertoireLog -ChildPath $FichierLog
$NumLigne = 1
$NbUtilisateursCrees      = 0
$NbUtilisateursIgnores    = 0
$NbErreurs                = 0
if ($Simulation) { $Mode = "SIMULATION" } else { $Mode = "RÉEL" }
if ([string]::IsNullOrWhiteSpace($CheminCSV)){
    $CheminCSV = "C:\AD-Lab\Data\utilisateurs.csv"
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERREUR")][string]$Niveau = "INFO",
        [switch]$AfficherTerminal #Mieux qu'un [bool] car on le nomme lors de l'appel de la fonction
    )

    $Horodatage = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Ligne = "$Horodatage [$Niveau] $Message"

    Add-Content -Path $CheminLog -Value $Ligne -Encoding utf8
    
    if ($Niveau -eq "WARN"){
        Write-Host $Ligne -ForegroundColor Yellow
    }
    elseif ($Niveau -eq "ERREUR"){
        Write-Host $Ligne -ForegroundColor Red
    }
    elseif ($AfficherTerminal){
        Write-Host $Ligne
    }
    
}

if (-not (Test-Path $RepertoireLog)) {
    $null = New-Item $RepertoireLog -ItemType Directory
    Write-Log "Le dossier $RepertoireLog n'existe pas, il a été créé" "WARN"
}

if (-not (Test-Path $CheminCSV)) {
    Write-Log "Le fichier $CheminCSV n'existe pas ! Opération annulée" "ERREUR"
    exit 1
}

# On teste si le module AD est installé ET si le domaine est joignable
try {
    $Domaine = Get-ADDomain -ErrorAction Stop
}
catch {
    Write-Log "Impossible de joindre l'annuaire AD : $($_.Exception.Message)" "ERREUR"
    exit 1
}

# ---------------------------  Import du CSV --------------------------------------- 
$Utilisateurs = @(Import-Csv -Path $CheminCSV -Delimiter ";" -Encoding UTF8)
# @() Force le résultat à être un tableau

# ------------------- Vérification du tableau du CSV -------------------------------

$TotalLignes = $Utilisateurs.Count

if ($TotalLignes -eq 0) {
    Write-Log "Le fichier CSV est vide, rien à traiter" "WARN"
    exit 0
}

$ProprietesRequises = @("Prenom", "Nom", "Service", "Login")
$ProprietesDuCsv    = $Utilisateurs[0].PSObject.Properties.Name
$ProprietesAbsentes = @($ProprietesRequises | Where-Object { $_ -notin $ProprietesDuCsv })

if ($ProprietesAbsentes.Count -gt 0) {
    Write-Log "Colonne(s) absente(s) du CSV : $($ProprietesAbsentes -join ', '). Colonnes trouvées : $($ProprietesDuCsv -join ', '). Vérifier les noms et le séparateur (;). Script annulé" "ERREUR"
    exit 1
}

Write-Log "[$Mode]Début du traitement, nombre de lignes : $TotalLignes Lancé par $env:USERNAME" "INFO" -AfficherTerminal

$Password = Read-Host "Entrez le mot de passe temporaire " -AsSecureString

if ($Password.Length -eq 0){
    Write-Log "Le mot de passe est vide, script annulé" "ERREUR"
    exit 1
}

foreach ($Utilisateur in $Utilisateurs) {

    $NumLigne++

    if ([String]::IsNullOrWhiteSpace($Utilisateur.Nom) -or
        [String]::IsNullOrWhiteSpace($Utilisateur.Prenom) -or
        [String]::IsNullOrWhiteSpace($Utilisateur.Service) -or
        [String]::IsNullOrWhiteSpace($Utilisateur.Login)) {
        Write-Log "ligne $NumLigne : Il manque des champs à l'utilisateur $Utilisateur, il n'a pas été créé" "ERREUR"
        $NbErreurs++
        continue
    }

    $Utilisateur.Nom = $Utilisateur.Nom.Trim()
    $Utilisateur.Prenom = $Utilisateur.Prenom.Trim()
    $Utilisateur.Service = $Utilisateur.Service.Trim()
    $Utilisateur.Login = $Utilisateur.Login.Trim()
    $DnOU = "OU=$($Utilisateur.Service),$DnRacine"

    if ($Utilisateur.Login.Length -gt 20) {
        Write-Log "ligne $NumLigne : $($Utilisateur.Login) a un Login trop grand (>20 caractères) et ne sera pas créé" "ERREUR"
        $NbErreurs++
        continue
    }
    if ($Utilisateur.Login -match '[\s"/\\\[\]:;|=,+*?<>@'']') {
        Write-Log "ligne $NumLigne : le login $($Utilisateur.Login) contient un caractère interdit, utilisateur non créé" "ERREUR"
        $NbErreurs++
        continue
    }
    if (Get-ADUser -Filter "SamAccountName -eq '$($Utilisateur.Login)'") {
        Write-Log "ligne $NumLigne : $($Utilisateur.Login) existe déjà et ne sera pas créé" "WARN"
        $NbUtilisateursIgnores++
        continue
    }
    
    try {
        $null = Get-ADOrganizationalUnit -Identity $DnOU -ErrorAction Stop
    }
    catch {
        Write-Log "ligne $NumLigne : L'OU $($Utilisateur.Service) n'existe pas, $($Utilisateur.Login) n'a pas été créé" "ERREUR"
        $NbErreurs++
        continue
    }

    $SuffixeUpn = $Domaine.DNSRoot
    $Upn = "$($Utilisateur.Login)@$SuffixeUpn"

    if (Get-ADUser -Filter "UserPrincipalName -eq '$Upn'") {
        Write-Log "ligne $NumLigne : l'UPN $Upn est déjà utilisé, $($Utilisateur.Login) n'a pas été créé" "ERREUR"
        $NbErreurs++
        continue
    }

    $ParametresUtilisateur = @{
        Name                    = "$($Utilisateur.Prenom) $($Utilisateur.Nom)"
        GivenName               = $Utilisateur.Prenom
        Surname                 = $Utilisateur.Nom
        SamAccountName          = $Utilisateur.Login
        UserPrincipalName       = $Upn
        Path                    = $DnOU
        WhatIf                  = $Simulation.IsPresent
        AccountPassword         = $Password
        Enabled                 = $true
        ChangePasswordAtLogon   = $true
        ErrorAction             = "Stop"
    }
    
    try {
        New-ADUser @ParametresUtilisateur

        Write-Log "[$Mode]ligne $NumLigne : Utilisateur créé: $($Utilisateur.Login)"
        $NbUtilisateursCrees++
    }
    catch {
        Write-Log "[$Mode]ligne $NumLigne : Erreur lors de la création de l'utilisateur $($Utilisateur.Login) : $($_.Exception.Message)" "ERREUR"
        $NbErreurs++

    }
}

Write-Log "[$Mode]Opération terminée, $NbUtilisateursCrees utilisateurs créés, $NbUtilisateursIgnores utilisateurs ignorés, $NbErreurs erreurs." "INFO" -AfficherTerminal

if (($NbUtilisateursCrees + $NbUtilisateursIgnores + $NbErreurs) -ne $TotalLignes){
    Write-Log "Le total des erreurs + utilisateurs créés + utilisateurs ignorés est différent du nombre de lignes du fichier CSV" "WARN"
}

if ($NbErreurs -gt 0) {exit 1}
exit 0
