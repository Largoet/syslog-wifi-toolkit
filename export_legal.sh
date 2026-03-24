#!/bin/bash
# =============================================================================
# export_legal.sh — Export certifié pour réquisition judiciaire (LCEN)
# =============================================================================
# VERSION : 3.0 — simplifiée et annotée
#
# USAGE :
#   ./scripts/export_legal.sh --reseau public  --debut 2026-01-01 --fin 2026-01-31
#   ./scripts/export_legal.sh --reseau interne --debut 2026-01-01 --fin 2026-01-31
#   ./scripts/export_legal.sh --reseau public  --debut 2026-01-01 --fin 2026-01-31 --force
#
# PRODUIT :
#   [prefix]_[debut]_[fin].tar.gz          Archive compressée des logs
#   [prefix]_[debut]_[fin].sha256          Checksum de l'archive (intégrité post-export)
#   [prefix]_[debut]_[fin]_sources.sha256  Checksums des fichiers sources (intégrité pré-export)
#   [prefix]_[debut]_[fin]_metadata.txt    Métadonnées et base légale
#   [prefix]_[debut]_[fin]_errors.log      Erreurs éventuelles
#
# CHECKLIST DE VALIDATION (à exécuter sur VM avant mise en production) :
# -----------------------------------------------------------------------------
# [ ] TEST 1 — Export standard
#       ./export_legal.sh --reseau public --debut YYYY-MM-DD --fin YYYY-MM-DD
#       Résultat attendu : archive créée, checksums présents, lignes > 0
#
# [ ] TEST 2 — Période sans logs (doit échouer proprement)
#       ./export_legal.sh --reseau public --debut 2020-01-01 --fin 2020-01-31
#       Résultat attendu : message "[ERREUR] Aucun log trouvé", exit code 1
#       Vérifier : echo $?  →  doit afficher 1
#
# [ ] TEST 3 — Date de début > date de fin (doit échouer proprement)
#       ./export_legal.sh --reseau public --debut 2026-03-31 --fin 2026-03-01
#       Résultat attendu : "[ERREUR] La date de début est postérieure..."
#
# [ ] TEST 4 — Export chevauchant deux années (cas le plus risqué)
#       ./export_legal.sh --reseau public --debut 2025-12-01 --fin 2026-01-31
#       Résultat attendu : logs de décembre ET janvier présents dans l'archive
#       Vérifier : tar -tzf archive.tar.gz | head
#
# [ ] TEST 5 — Archive existante sans --force (doit demander confirmation)
#       Relancer le TEST 1 une deuxième fois
#       Résultat attendu : demande "Écraser ? (o/N)"
#       Répondre "N" → export annulé
#       Relancer avec --force → écrase sans demander
#
# [ ] TEST 6 — Vérification de l'intégrité après export
#       cd /var/log/exports/public
#       sha256sum -c export_wifi_*.sha256
#       Résultat attendu : "OK" pour chaque fichier
#
# [ ] TEST 7 — Vérification dans syslog
#       grep "export_legal" /var/log/syslog | tail -5
#       Résultat attendu : entrées DEBUT EXPORT et FIN EXPORT avec les bons paramètres
#
# [ ] TEST 8 — Espace disque insuffisant
#       Difficile à simuler — vérifier visuellement la section "espace disque"
#       dans le code ci-dessous
# -----------------------------------------------------------------------------
#
# BASE LÉGALE : Loi LCEN art. 6-II / Décret n°2011-219
# AUTEUR : Thibaut — Stagiaire DevOps — DSI Mairie de Rezé — 2026
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
SCRIPT_NAME=$(basename "$0")

# =============================================================================
# FONCTIONS
# =============================================================================

# Fonction de log unifiée — affiche dans la console ET trace dans syslog système.
# Usage : _log INFO "message" | _log OK "message" | _log ERREUR "message"
# NOTE ÉVOLUTION : pour envoyer les alertes vers un outil de supervision
# (Zabbix, email, webhook...), ajouter la logique ici.
_log() {
  local niveau="$1" message="$2"
  local couleur
  case "$niveau" in
    INFO)     couleur="\e[34m" ;;  # bleu
    OK)       couleur="\e[32m" ;;  # vert
    ATTENTION) couleur="\e[33m" ;; # orange
    ERREUR)   couleur="\e[31m" ;;  # rouge
    *)        couleur="\e[0m"  ;;
  esac

  if [[ "$niveau" == "ERREUR" ]]; then
    echo -e "${couleur}[${niveau}]\e[0m  $message" >&2
  else
    echo -e "${couleur}[${niveau}]\e[0m  $message"
  fi

  logger -t "$SCRIPT_NAME" "$niveau — $message"

  [[ "$niveau" == "ERREUR" ]] && exit 1
}

# Affichage de l'aide
_usage() {
  echo "Usage : $SCRIPT_NAME --reseau [public|interne] --debut YYYY-MM-DD --fin YYYY-MM-DD [--force]"
  echo ""
  echo "  --reseau  public|interne   Réseau cible (obligatoire)"
  echo "  --debut   YYYY-MM-DD       Date de début (incluse)"
  echo "  --fin     YYYY-MM-DD       Date de fin (incluse)"
  echo "  --force                    Écraser une archive existante sans confirmation"
  echo "  --help                     Afficher cette aide"
  exit 0
}

# Filtre les lignes d'un fichier de logs pour une période donnée.
# Usage : _filtrer_periode "contenu_du_fichier" ts_debut ts_fin annee_debut annee_fin
# NOTE TECHNIQUE : awk est utilisé pour la performance — une boucle bash
# appellerait `date` pour chaque ligne (trop lent sur de gros fichiers).
# NOTE ÉVOLUTION : si les bornes passent au format RFC 5424 (avec année
# incluse dans l'horodatage), cette fonction peut être simplifiée.
_filtrer_periode() {
  local contenu="$1"
  echo "$contenu" | awk \
    -v ts_debut="$2" -v ts_fin="$3" \
    -v annee_debut="$4" -v annee_fin="$5" \
    '
    {
      # Format syslog RFC 3164 : "Mar 23 14:00:01 hostname process: message"
      mois_jours_heure = $1 " " $2 " " $3

      cmd = "date -d \"" mois_jours_heure " " annee_debut "\" +%s 2>/dev/null"
      cmd | getline ts; close(cmd)
      if (ts >= ts_debut && ts <= ts_fin) { print $0; next }

      # Gestion du chevauchement de deux années (ex: déc 2025 → jan 2026)
      if (annee_fin != annee_debut) {
        cmd2 = "date -d \"" mois_jours_heure " " annee_fin "\" +%s 2>/dev/null"
        cmd2 | getline ts2; close(cmd2)
        if (ts2 >= ts_debut && ts2 <= ts_fin) { print $0; next }
      }
    }
  ' 2>/dev/null || true
}

# =============================================================================
# PARSING DES ARGUMENTS
# =============================================================================

RESEAU="" DATE_DEBUT="" DATE_FIN="" FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reseau) RESEAU="$2";     shift 2 ;;
    --debut)  DATE_DEBUT="$2"; shift 2 ;;
    --fin)    DATE_FIN="$2";   shift 2 ;;
    --force)  FORCE=true;      shift ;;
    --help)   _usage ;;
    *) echo "[ERREUR] Option inconnue : $1"; _usage ;;
  esac
done

# =============================================================================
# VÉRIFICATIONS PRÉALABLES
# =============================================================================

[[ -z "$RESEAU" ]]     && { echo "[ERREUR] --reseau est obligatoire."; _usage; }
[[ -z "$DATE_DEBUT" ]] && { echo "[ERREUR] --debut est obligatoire."; _usage; }
[[ -z "$DATE_FIN" ]]   && { echo "[ERREUR] --fin est obligatoire."; _usage; }

# Validation des dates (format et cohérence)
date -d "$DATE_DEBUT" '+%Y-%m-%d' > /dev/null 2>&1 \
  || _log ERREUR "Date invalide : $DATE_DEBUT (format attendu : YYYY-MM-DD)"
date -d "$DATE_FIN" '+%Y-%m-%d' > /dev/null 2>&1 \
  || _log ERREUR "Date invalide : $DATE_FIN (format attendu : YYYY-MM-DD)"

TS_DEBUT=$(date -d "$DATE_DEBUT" +%s)
TS_FIN=$(date -d "$DATE_FIN 23:59:59" +%s)
# NOTE : "23:59:59" inclut toute la journée de fin dans l'export.

[[ $TS_DEBUT -gt $TS_FIN ]] \
  && _log ERREUR "La date de début ($DATE_DEBUT) est postérieure à la date de fin ($DATE_FIN)."

# Chargement de la config réseau
# NOTE CONTEXTE : config.public.sh et config.interne.sh ne sont pas versionnés
# dans Git — ils contiennent les IPs et chemins spécifiques à l'infrastructure.
# Copier config.example.sh pour les créer.
CONFIG_FILE="$CONFIG_DIR/config.${RESEAU}.sh"
[[ ! -f "$CONFIG_FILE" ]] \
  && _log ERREUR "Config introuvable : $CONFIG_FILE — copier config.example.sh et le renseigner."
source "$CONFIG_FILE"

# =============================================================================
# TRAÇAGE DU DÉMARRAGE (valeur légale — ne pas supprimer)
# NOTE : ces deux entrées syslog (DEBUT + FIN) permettent de prouver
# qu'un export a bien eu lieu, par qui et quand, en cas de contestation.
# =============================================================================
logger -t "$SCRIPT_NAME" "DEBUT EXPORT — réseau=$RESEAU_NOM période=$DATE_DEBUT→$DATE_FIN opérateur=$(whoami)@$(hostname)"

# =============================================================================
# VÉRIFICATION DE L'ESPACE DISQUE
# NOTE : estimation conservative (x2) pour couvrir le dossier temp + l'archive.
# La compression tar.gz réduit généralement les logs texte de 70 à 80%.
# =============================================================================
TAILLE_KB=$(( $(du -sk "$LOG_DIR" 2>/dev/null | awk '{print $1}' || echo 0) * 2 ))
mkdir -p "$EXPORT_DIR"

[[ $(df -k /tmp        | awk 'NR==2{print $4}') -lt $TAILLE_KB ]] \
  && _log ERREUR "Espace insuffisant dans /tmp (estimé nécessaire : ${TAILLE_KB}KB)"
[[ $(df -k "$EXPORT_DIR" | awk 'NR==2{print $4}') -lt $(( TAILLE_KB / 2 )) ]] \
  && _log ERREUR "Espace insuffisant dans $EXPORT_DIR"

_log OK "Espace disque suffisant"

# =============================================================================
# PRÉPARATION DES FICHIERS DE SORTIE
# NOTE ÉVOLUTION : pour ajouter un numéro de réquisition dans le nom des
# fichiers, ajouter --ref comme paramètre et l'intégrer dans NOM_EXPORT.
# =============================================================================
DATE_DEBUT_C=$(echo "$DATE_DEBUT" | tr -d '-')
DATE_FIN_C=$(echo "$DATE_FIN"     | tr -d '-')
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

NOM_EXPORT="${EXPORT_PREFIX}_${DATE_DEBUT_C}_${DATE_FIN_C}"
DOSSIER_TEMP="/tmp/${NOM_EXPORT}_${TIMESTAMP}"
FICHIER_EXPORT="$EXPORT_DIR/${NOM_EXPORT}.tar.gz"
FICHIER_CHECKSUM="$EXPORT_DIR/${NOM_EXPORT}.sha256"
FICHIER_CHECKSUM_SOURCES="$EXPORT_DIR/${NOM_EXPORT}_sources.sha256"
FICHIER_META="$EXPORT_DIR/${NOM_EXPORT}_metadata.txt"
FICHIER_ERREURS="$EXPORT_DIR/${NOM_EXPORT}_errors.log"

# Vérification si archive existante
if [[ -f "$FICHIER_EXPORT" ]] && ! $FORCE; then
  _log ATTENTION "Une archive existe déjà : $FICHIER_EXPORT"
  read -r -p "Écraser ? (o/N) : " reponse
  if [[ "${reponse,,}" != "o" ]]; then
    logger -t "$SCRIPT_NAME" "EXPORT ANNULÉ — archive existante conservée"
    echo "Export annulé."; exit 1
  fi
fi

mkdir -p "$DOSSIER_TEMP"
trap 'rm -rf "$DOSSIER_TEMP"' EXIT          # nettoyage garanti même en cas d'erreur
exec 2> >(tee -a "$FICHIER_ERREURS" >&2)   # stderr → fichier + console

echo "============================================================"
echo "  export_legal.sh — $RESEAU_NOM ($RESEAU_DESCRIPTION)"
echo "  $(date '+%Y-%m-%d %H:%M:%S') | Période : $DATE_DEBUT → $DATE_FIN"
echo "============================================================"

# =============================================================================
# EXTRACTION DES LOGS
# =============================================================================
_log INFO "Extraction des logs en cours..."

NB_LIGNES_TOTAL=0
BORNES_PRESENTES=()
CHECKSUMS_SOURCES=""
ANNEE_DEBUT=$(date -d "$DATE_DEBUT" '+%Y')
ANNEE_FIN=$(date -d "$DATE_FIN"     '+%Y')

for fichier in "$LOG_DIR"/*.log "$LOG_DIR"/*.log*.gz; do
  [[ -f "$fichier" ]] || continue

  nom_borne=$(basename "$fichier" | sed 's/\.log.*//')

  # Checksum source AVANT extraction — premier niveau de preuve d'intégrité légale
  CHECKSUMS_SOURCES+="$(sha256sum "$fichier" | awk '{print $1}')  $(basename "$fichier")"$'\n'

  # Lecture (compressé ou non)
  if [[ "$fichier" == *.gz ]]; then
    contenu=$(zcat "$fichier" 2>/dev/null || true)
  else
    contenu=$(cat "$fichier" 2>/dev/null || true)
  fi
  [[ -z "$contenu" ]] && continue

  # Filtrage par période (fonction dédiée pour lisibilité)
  lignes=$(_filtrer_periode "$contenu" "$TS_DEBUT" "$TS_FIN" "$ANNEE_DEBUT" "$ANNEE_FIN")

  if [[ -n "$lignes" ]]; then
    echo "$lignes" >> "$DOSSIER_TEMP/${nom_borne}.log"
    nb=$(echo "$lignes" | wc -l)
    NB_LIGNES_TOTAL=$(( NB_LIGNES_TOTAL + nb ))
    BORNES_PRESENTES+=("$nom_borne ($nb lignes)")
    _log OK "$nom_borne : $nb ligne(s)"
  fi
done

# Sauvegarde des checksums sources
echo "$CHECKSUMS_SOURCES" | tee "$FICHIER_CHECKSUM_SOURCES" \
  > "$DOSSIER_TEMP/sources_checksums.sha256"

# Exit 1 si aucun log — un export vide est une anomalie, pas un succès
[[ $NB_LIGNES_TOTAL -eq 0 ]] \
  && _log ERREUR "Aucun log trouvé pour $DATE_DEBUT → $DATE_FIN sur $RESEAU_NOM. Vérifier : $LOG_DIR"

# =============================================================================
# MÉTADONNÉES
# NOTE ÉVOLUTION : ajouter --ref pour inclure un numéro de réquisition,
# le nom de l'officier demandeur, ou une référence judiciaire.
# =============================================================================
cat > "$FICHIER_META" <<EOF
=============================================================
  EXPORT LÉGAL — LOGS WIFI ${RESEAU_NOM^^} / ${RESEAU_DESCRIPTION}
=============================================================
Date d'export   : $(date '+%Y-%m-%d %H:%M:%S')
Opérateur       : $(whoami)@$(hostname)
Serveur syslog  : $SYSLOG_IP
Réseau          : $RESEAU_NOM — $RESEAU_DESCRIPTION
Période         : $DATE_DEBUT → $DATE_FIN
Lignes          : $NB_LIGNES_TOTAL

Bornes :
$(for b in "${BORNES_PRESENTES[@]}"; do echo "  - $b"; done)

Base légale     : Loi LCEN art. 6-II / Décret n°2011-219
Conservation    : 1 an minimum

-------------------------------------------------------------
INTÉGRITÉ — deux niveaux de vérification :
  1. Checksums sources (avant extraction) : $(basename "$FICHIER_CHECKSUM_SOURCES")
     → Prouve que les logs bruts n'ont pas été altérés avant export
  2. Checksum archive (après compression) : $(basename "$FICHIER_CHECKSUM")
     → Prouve que l'archive n'a pas été modifiée après création

Vérification : cd $EXPORT_DIR && sha256sum -c $(basename "$FICHIER_CHECKSUM")
=============================================================
EOF

cp "$FICHIER_META" "$DOSSIER_TEMP/metadata.txt"

# =============================================================================
# COMPRESSION + CHECKSUMS
# =============================================================================
echo ""
_log INFO "Compression..."
tar -czf "$FICHIER_EXPORT" -C "/tmp" "${NOM_EXPORT}_${TIMESTAMP}"
_log OK "Archive : $FICHIER_EXPORT"

# Checksum archive — second niveau de preuve d'intégrité légale
sha256sum "$FICHIER_EXPORT" > "$FICHIER_CHECKSUM"
_log OK "Checksums enregistrés"

# Traçage de fin (valeur légale — ne pas supprimer)
logger -t "$SCRIPT_NAME" "FIN EXPORT — réseau=$RESEAU_NOM période=$DATE_DEBUT→$DATE_FIN lignes=$NB_LIGNES_TOTAL archive=$(basename "$FICHIER_EXPORT") opérateur=$(whoami)"

# =============================================================================
# RÉSUMÉ
# =============================================================================
echo ""
echo "============================================================"
echo "  Export terminé — $RESEAU_NOM"
echo "  Archive          : $FICHIER_EXPORT"
echo "  Checksum archive : $FICHIER_CHECKSUM"
echo "  Checksum sources : $FICHIER_CHECKSUM_SOURCES"
echo "  Métadonnées      : $FICHIER_META"
echo "  Erreurs          : $FICHIER_ERREURS"
echo "  Lignes exportées : $NB_LIGNES_TOTAL"
echo ""
echo "  Vérification : cd $EXPORT_DIR && sha256sum -c $(basename "$FICHIER_CHECKSUM")"
echo "============================================================"
