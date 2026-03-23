#!/bin/bash
# =============================================================================
# search.sh — Recherche dans les logs WiFi
# =============================================================================
# Usage :
#   ./scripts/search.sh --ip 192.168.10.45
#   ./scripts/search.sh --mac AA:BB:CC:DD:EE:FF
#   ./scripts/search.sh --date 2026-03-15
#   ./scripts/search.sh --ip 192.168.10.45 --date 2026-03-15
#   ./scripts/search.sh --ip 192.168.10.45 --export
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/config.sh"

# --- Aide --------------------------------------------------------------------
_usage() {
  echo "Usage : ./scripts/search.sh [OPTIONS]"
  echo ""
  echo "Options :"
  echo "  --ip    <adresse>   Recherche par adresse IP"
  echo "  --mac   <adresse>   Recherche par adresse MAC (format AA:BB:CC:DD:EE:FF)"
  echo "  --date  <date>      Recherche par date (format YYYY-MM-DD)"
  echo "  --borne <nom>       Recherche sur une borne spécifique"
  echo "  --export            Exporter les résultats dans un fichier"
  echo "  --help              Afficher cette aide"
  echo ""
  echo "Exemples :"
  echo "  ./scripts/search.sh --ip 192.168.10.45"
  echo "  ./scripts/search.sh --date 2026-03-15 --export"
  echo "  ./scripts/search.sh --mac AA:BB:CC:DD:EE:FF --date 2026-03-15"
  exit 0
}

# --- Parsing des arguments ---------------------------------------------------
SEARCH_IP=""
SEARCH_MAC=""
SEARCH_DATE=""
SEARCH_BORNE=""
EXPORT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)    SEARCH_IP="$2";    shift 2 ;;
    --mac)   SEARCH_MAC="$2";   shift 2 ;;
    --date)  SEARCH_DATE="$2";  shift 2 ;;
    --borne) SEARCH_BORNE="$2"; shift 2 ;;
    --export) EXPORT=true;      shift ;;
    --help)  _usage ;;
    *) echo "[ERREUR] Option inconnue : $1"; _usage ;;
  esac
done

# Au moins un critère requis
if [[ -z "$SEARCH_IP" && -z "$SEARCH_MAC" && -z "$SEARCH_DATE" && -z "$SEARCH_BORNE" ]]; then
  echo "[ERREUR] Au moins un critère de recherche est requis."
  _usage
fi

# --- Construction du pattern de recherche ------------------------------------
PATTERN=""

[[ -n "$SEARCH_IP" ]]    && PATTERN="$SEARCH_IP"
[[ -n "$SEARCH_MAC" ]]   && PATTERN="${PATTERN:+$PATTERN.*}$SEARCH_MAC"
[[ -n "$SEARCH_DATE" ]]  && {
  # Convertir YYYY-MM-DD en format syslog partiel (ex: "Mar 15" ou "Mar  5")
  DATE_SYSLOG=$(date -d "$SEARCH_DATE" '+%b %e' 2>/dev/null || echo "$SEARCH_DATE")
  PATTERN="${PATTERN:+$PATTERN.*}$DATE_SYSLOG"
}

# --- Sélection des fichiers à parcourir --------------------------------------
if [[ -n "$SEARCH_BORNE" ]]; then
  FICHIERS=("$LOG_DIR/${SEARCH_BORNE}.log")
  # Inclure aussi les archives compressées
  FICHIERS_GZ=("$LOG_DIR/${SEARCH_BORNE}.log"*.gz)
else
  FICHIERS=("$LOG_DIR"/*.log)
  FICHIERS_GZ=("$LOG_DIR"/*.log*.gz)
fi

# --- Recherche ---------------------------------------------------------------
echo "============================================================"
echo "  search.sh — Recherche dans les logs WiFi"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""
[[ -n "$SEARCH_IP" ]]    && echo "  IP      : $SEARCH_IP"
[[ -n "$SEARCH_MAC" ]]   && echo "  MAC     : $SEARCH_MAC"
[[ -n "$SEARCH_DATE" ]]  && echo "  Date    : $SEARCH_DATE"
[[ -n "$SEARCH_BORNE" ]] && echo "  Borne   : $SEARCH_BORNE"
echo ""
echo "------------------------------------------------------------"

RESULTATS=""

# Parcourir les fichiers de logs actifs
for f in "${FICHIERS[@]}"; do
  [[ -f "$f" ]] || continue
  RESULTATS+=$(grep -i "$PATTERN" "$f" 2>/dev/null | sed "s|^|[$(basename "$f" .log)] |" || true)
done

# Parcourir les archives compressées
for f in "${FICHIERS_GZ[@]}"; do
  [[ -f "$f" ]] || continue
  RESULTATS+=$(zgrep -i "$PATTERN" "$f" 2>/dev/null | sed "s|^|[$(basename "$f" .log.gz) archive] |" || true)
done

if [[ -z "$RESULTATS" ]]; then
  echo "  Aucun résultat trouvé pour les critères spécifiés."
else
  echo "$RESULTATS"
  NB_LIGNES=$(echo "$RESULTATS" | wc -l)
  echo ""
  echo "------------------------------------------------------------"
  echo "  $NB_LIGNES résultat(s) trouvé(s)."

  # Export si demandé
  if $EXPORT; then
    mkdir -p "$RAPPORT_DIR"
    FICHIER_EXPORT="$RAPPORT_DIR/search_$(date '+%Y%m%d_%H%M%S').txt"
    {
      echo "Export de recherche — syslog-toolkit"
      echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
      [[ -n "$SEARCH_IP" ]]    && echo "IP         : $SEARCH_IP"
      [[ -n "$SEARCH_MAC" ]]   && echo "MAC        : $SEARCH_MAC"
      [[ -n "$SEARCH_DATE" ]]  && echo "Date       : $SEARCH_DATE"
      [[ -n "$SEARCH_BORNE" ]] && echo "Borne      : $SEARCH_BORNE"
      echo "Résultats  : $NB_LIGNES ligne(s)"
      echo "------------------------------------------------------------"
      echo "$RESULTATS"
    } > "$FICHIER_EXPORT"
    echo "  Export enregistré : $FICHIER_EXPORT"
  fi
fi

echo "============================================================"
