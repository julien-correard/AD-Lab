<#
.SYNOPSIS
    Ajoute tous les utilisateurs d'une OU à un groupe de sécurité GG.
.PARAMETER NomOU
    Nom de l'OU (sous OU=UTILISATEURS,OU=ENTREPRISE).
.PARAMETER NomGroupeGG
    Nom du groupe de sécurité cible.
.PARAMETER Simulation
    Aucune modification n'est faite dans l'AD (équivalent -WhatIf).
.EXAMPLE
    .\Add-OUUusersToGroup.ps1 -NomOU "COMPTA" -NomGroupeGG "GG_Compta" -Simulation
#>

#Requires -Modules ActiveDirectory

param(
    [string]$NomOU,
    [string]$NomGroupeGG,
    [switch]$Simulation
)

New-Variable -Name Dn_Racine -Value "OU=UTILISATEURS,OU=ENTREPRISE,DC=julien,DC=local" -Option ReadOnly -Force

$RepertoireLog = "C:\AD-Lab\Logs\"
$FichierLog = "Add-OUUsersToGroup.log"
$CheminLog = Join-Path -Path $RepertoireLog -ChildPath $FichierLog
$NbUtilisateursAjoutes  = 0
$NbDejaMembres          = 0
$NbErreurs              = 0

if ($Simulation) { $Mode = "SIMULATION" } else { $Mode = "RÉEL" }

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

if ([string]::IsNullOrWhiteSpace($NomOU)){
    $NomOU = Read-Host "Entrez le nom de l'OU"
}

if ([String]::IsNullOrWhiteSpace($NomOU)) {
    Write-Log "Nom d'OU vide, script annulé" "ERREUR"
    exit 1
}

$DnOU = "OU=$NomOU,$Dn_Racine"

try {
    $null = Get-ADOrganizationalUnit -Identity $DnOU -ErrorAction Stop
}
catch {
    Write-Log "L'OU $DnOU n'existe pas, script annulé" "ERREUR"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($NomGroupeGG)){
    $NomGroupeGG = Read-Host "Entrez le nom du groupe de sécurité GG"
}

if ([String]::IsNullOrWhiteSpace($NomGroupeGG)) {
    Write-Log "Nom de groupe GG vide, script annulé" "ERREUR"
    exit 1
}

try{
    $GroupeGG = Get-ADGroup -Identity $NomGroupeGG -Properties Member -ErrorAction Stop
}
catch{
    Write-Log "Le groupe GG $NomGroupeGG n'existe pas, script annulé" "ERREUR"
    exit 1
}
$DnMembresActuelsDuGG = @($GroupeGG.Member)   # @() garantit un tableau, même si le groupe est vide

$UtilisateursOU = @(Get-ADUser -SearchBase $DnOU -SearchScope Subtree -Filter *)

Write-Log "Début du traitement, $($UtilisateursOU.Count) utilisateurs à traiter. Mode : $Mode. Lancé par $env:USERNAME" "INFO" -AfficherTerminal

foreach ($Utilisateur in $UtilisateursOU){

    if (-not ($DnMembresActuelsDuGG -contains $Utilisateur.DistinguishedName)) {
        try {
            $null = Add-ADGroupMember -Identity $NomGroupeGG -Members $Utilisateur -ErrorAction Stop -WhatIf:$Simulation
            Write-Log "[$Mode] L'utilisateur $($Utilisateur.SamAccountName) a été ajouté au groupe $NomGroupeGG" "INFO"
            $NbUtilisateursAjoutes++
        }
        catch{
            Write-Log "Ajout de l'utilisateur $($Utilisateur.SamAccountName) impossible : $($_.Exception.Message)" "ERREUR"
            $NbErreurs++
        }
    }
    else {
        Write-Log "[$Mode] L'utilisateur $($Utilisateur.SamAccountName) est déjà membre du groupe." "INFO"
        $NbDejaMembres++
    }
}


Write-Log "[$Mode] $NbUtilisateursAjoutes utilisateurs ont été ajoutés au groupe $NomGroupeGG, $NbDejaMembres utilisateurs en étaient déjà membres et n'ont pas été ajoutés" "INFO" -AfficherTerminal

if ($NbErreurs -gt 0) {exit 1}
exit 0