#!/bin/bash
# =============================================================================
# export_legal.sh — Export certifié pour réquisition judiciaire (LCEN)
# =============================================================================
# Usage :
#   ./scripts/export_legal.sh --debut 2026-01-01 --fin 2026-01-31
#
# Produit :
#   - Un fichier d'export compressé horodaté
#   - Un fichier de checksum SHA256 (preuve d'intégrité)
#   - Un fichier de métadonnées (période, bornes, nombre de lignes)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/config.sh"

# --- Aide --------------------------------------------------------------------
_usage() {
  echo "Usage : ./scripts/export_legal.sh --debut YYYY-MM-DD --fin YYYY-MM-DD"
  echo ""
  echo "Options :"
  echo "  --debut <date>   Date de début de la période (incluse)"
  echo "  --fin   <date>   Date de fin de la période (incluse)"
  echo "  --help           Afficher cette aide"
  echo ""
  echo "Exemple :"
  echo "  ./scripts/export_legal.sh --debut 2026-01-01 --fin 2026-01-31"
  exit 0
}

# --- Parsing des arguments ---------------------------------------------------
DATE_DEBUT=""
DATE_FIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debut) DATE_DEBUT="$2"; shift 2 ;;
    --fin)   DATE_FIN="$2";   shift 2 ;;
    --help)  _usage ;;
    *) echo "[ERREUR] Option inconnue : $1"; _usage ;;
  esac
done

if [[ -z "$DATE_DEBUT" || -z "$DATE_FIN" ]]; then
  echo "[ERREUR] Les dates de début et de fin sont obligatoires."
  _usage
fi

# Validation du format des dates
date -d "$DATE_DEBUT" '+%Y-%m-%d' > /dev/null 2>&1 || { echo "[ERREUR] Format de date invalide : $DATE_DEBUT"; exit 1; }
date -d "$DATE_FIN"   '+%Y-%m-%d' > /dev/null 2>&1 || { echo "[ERREUR] Format de date invalide : $DATE_FIN";   exit 1; }

# --- Préparation de l'export -------------------------------------------------
mkdir -p "$EXPORT_DIR"

DATE_DEBUT_COMPACT=$(echo "$DATE_DEBUT" | tr -d '-')
DATE_FIN_COMPACT=$(echo "$DATE_FIN"     | tr -d '-')
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

NOM_EXPORT="${EXPORT_PREFIX}_${DATE_DEBUT_COMPACT}_${DATE_FIN_COMPACT}"
DOSSIER_TEMP="/tmp/${NOM_EXPORT}_${TIMESTAMP}"
FICHIER_EXPORT="$EXPORT_DIR/${NOM_EXPORT}.tar.gz"
FICHIER_CHECKSUM="$EXPORT_DIR/${NOM_EXPORT}.sha256"
FICHIER_META="$EXPORT_DIR/${NOM_EXPORT}_metadata.txt"

mkdir -p "$DOSSIER_TEMP"

echo "============================================================"
echo "  export_legal.sh — Export pour réquisition LCEN"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""
echo "  Période : $DATE_DEBUT → $DATE_FIN"
echo "  Destination : $EXPORT_DIR/"
echo ""

# --- Extraction des logs pour la période -------------------------------------
echo "[INFO] Extraction des logs en cours..."

NB_LIGNES_TOTAL=0
BORNES_PRESENTES=()

# Convertir les dates en format syslog pour le filtrage
TS_DEBUT=$(date -d "$DATE_DEBUT" +%s)
TS_FIN=$(date -d "$DATE_FIN 23:59:59" +%s)

for fichier in "$LOG_DIR"/*.log "$LOG_DIR"/*.log*.gz; do
  [[ -f "$fichier" ]] || continue

  nom_borne=$(basename "$fichier" | sed 's/\.log.*//')
  fichier_dest="$DOSSIER_TEMP/${nom_borne}.log"

  # Extraire selon que le fichier est compressé ou non
  if [[ "$fichier" == *.gz ]]; then
    contenu=$(zcat "$fichier" 2>/dev/null || true)
  else
    contenu=$(cat "$fichier" 2>/dev/null || true)
  fi

  # Filtrer les lignes dans la période
  lignes_periode=""
  while IFS= read -r ligne; do
    # Extraire la date de chaque ligne syslog (format : "Mar 23 14:00:01")
    ts_ligne=$(echo "$ligne" | awk '{print $1, $2, $3}')
    ts_epoch=$(date -d "$ts_ligne $(date +%Y)" +%s 2>/dev/null || echo "0")

    if [[ $ts_epoch -ge $TS_DEBUT && $ts_epoch -le $TS_FIN ]]; then
      lignes_periode+="$ligne"$'\n'
    fi
  done <<< "$contenu"

  if [[ -n "$lignes_periode" ]]; then
    echo "$lignes_periode" >> "$fichier_dest"
    nb=$(echo "$lignes_periode" | wc -l)
    NB_LIGNES_TOTAL=$((NB_LIGNES_TOTAL + nb))
    BORNES_PRESENTES+=("$nom_borne ($nb lignes)")
    echo "[OK]   $nom_borne : $nb ligne(s) extraite(s)"
  fi
done

if [[ $NB_LIGNES_TOTAL -eq 0 ]]; then
  echo "[ATTENTION] Aucun log trouvé pour la période $DATE_DEBUT → $DATE_FIN"
  rm -rf "$DOSSIER_TEMP"
  exit 0
fi

# --- Génération du fichier de métadonnées ------------------------------------
cat > "$FICHIER_META" <<EOF
=============================================================
  EXPORT LÉGAL — LOGS WIFI PUBLIC
  Mairie de Rezé — Direction des Systèmes d'Information
=============================================================

Date d'export      : $(date '+%Y-%m-%d %H:%M:%S')
Opérateur          : $(whoami)@$(hostname)
Serveur syslog     : $SYSLOG_IP

Période couverte   : $DATE_DEBUT → $DATE_FIN
Lignes exportées   : $NB_LIGNES_TOTAL

Bornes concernées :
$(for b in "${BORNES_PRESENTES[@]}"; do echo "  - $b"; done)

Base légale        : Loi LCEN art. 6-II / Décret n°2011-219
Durée de conservation : 1 an

=============================================================
NOTE : Le fichier d'export est accompagné d'un checksum
SHA256 permettant de vérifier son intégrité.
Pour vérifier : sha256sum -c ${NOM_EXPORT}.sha256
=============================================================
EOF

cp "$FICHIER_META" "$DOSSIER_TEMP/metadata.txt"

# --- Compression de l'export -------------------------------------------------
echo ""
echo "[INFO] Compression de l'export..."
tar -czf "$FICHIER_EXPORT" -C "/tmp" "${NOM_EXPORT}_${TIMESTAMP}"
echo "[OK]   Archive créée : $FICHIER_EXPORT"

# --- Calcul du checksum ------------------------------------------------------
echo "[INFO] Calcul du checksum SHA256..."
sha256sum "$FICHIER_EXPORT" > "$FICHIER_CHECKSUM"
echo "[OK]   Checksum enregistré : $FICHIER_CHECKSUM"

# --- Nettoyage du dossier temporaire -----------------------------------------
rm -rf "$DOSSIER_TEMP"

# --- Résumé ------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Export terminé"
echo "============================================================"
echo "  Archive        : $FICHIER_EXPORT"
echo "  Checksum       : $FICHIER_CHECKSUM"
echo "  Métadonnées    : $FICHIER_META"
echo "  Lignes totales : $NB_LIGNES_TOTAL"
echo ""
echo "  Pour vérifier l'intégrité de l'archive :"
echo "  sha256sum -c $FICHIER_CHECKSUM"
echo "============================================================"
