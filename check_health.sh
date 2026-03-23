#!/bin/bash
# =============================================================================
# anomaly_report.sh — Rapport quotidien d'anomalies comportementales
# =============================================================================
# Usage :
#   ./scripts/anomaly_report.sh
#
# Planification recommandée :
#   0 2 * * * /chemin/syslog-toolkit/scripts/anomaly_report.sh
#
# PÉRIMÈTRE : ce script analyse des métadonnées de connexion (MAC, IP,
# horodatage). Il ne voit pas le contenu des échanges réseau.
# Les anomalies détectées sont comportementales, pas applicatives.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/config.sh"

# --- Initialisation ----------------------------------------------------------
DATE_HIER=$(date -d "yesterday" '+%Y-%m-%d')
DATE_HIER_SYSLOG=$(date -d "yesterday" '+%b %e')
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
FICHIER_RAPPORT="$RAPPORT_DIR/anomaly_$(date -d yesterday '+%Y%m%d').txt"

mkdir -p "$RAPPORT_DIR"

NB_INFO=0
NB_ATTENTION=0
NB_ANOMALIE=0

RAPPORT_CONTENU=""

_ajouter() {
  local niveau="$1"
  local message="$2"
  RAPPORT_CONTENU+="[$niveau] $message"$'\n'
  case "$niveau" in
    INFO)     ((NB_INFO++)) ;;
    ATTENTION) ((NB_ATTENTION++)) ;;
    ANOMALIE) ((NB_ANOMALIE++)) ;;
  esac
}

# --- Collecte des logs de la veille ------------------------------------------
LOGS_HIER=""
for fichier in "$LOG_DIR"/*.log "$LOG_DIR"/*.log*.gz; do
  [[ -f "$fichier" ]] || continue
  if [[ "$fichier" == *.gz ]]; then
    LOGS_HIER+=$(zgrep "$DATE_HIER_SYSLOG" "$fichier" 2>/dev/null || true)
  else
    LOGS_HIER+=$(grep "$DATE_HIER_SYSLOG" "$fichier" 2>/dev/null || true)
  fi
done

if [[ -z "$LOGS_HIER" ]]; then
  _ajouter "INFO" "Aucun log reçu pour la journée du $DATE_HIER — journée sans activité ou problème de collecte."
fi

# --- Statistiques générales --------------------------------------------------
NB_CONNEXIONS_TOTAL=$(echo "$LOGS_HIER" | grep -ci "connect\|assoc\|auth" 2>/dev/null || echo "0")
NB_MAC_UNIQUES=$(echo "$LOGS_HIER" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | sort -u | wc -l || echo "0")

_ajouter "INFO" "Connexions totales le $DATE_HIER : $NB_CONNEXIONS_TOTAL"
_ajouter "INFO" "Terminaux distincts (MAC uniques) : $NB_MAC_UNIQUES"

# --- Anomalie 1 : Reconnexions en boucle -------------------------------------
# Même MAC : plus de N événements en 1 heure
echo "$LOGS_HIER" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | sort | uniq -c | sort -rn | while read -r count mac; do
  if [[ $count -gt $SEUIL_RECONNEXIONS ]]; then
    _ajouter "ANOMALIE" "Reconnexions en boucle — MAC $mac : $count événements (seuil : $SEUIL_RECONNEXIONS)"
  fi
done

# --- Anomalie 2 : Activité nocturne ------------------------------------------
LOGS_NUIT=$(echo "$LOGS_HIER" | awk -v debut="$HEURE_NUIT_DEBUT" -v fin="$HEURE_NUIT_FIN" '{
  split($3, t, ":");
  h = t[1] + 0;
  if (h >= debut || h < fin) print $0
}' 2>/dev/null || true)

NB_NUIT=$(echo "$LOGS_NUIT" | grep -c "." 2>/dev/null || echo "0")

if [[ $NB_NUIT -gt 0 ]]; then
  _ajouter "ATTENTION" "Activité nocturne détectée (${HEURE_NUIT_DEBUT}h–${HEURE_NUIT_FIN}h) : $NB_NUIT événement(s)"
  # Lister les bornes concernées
  bornes_nuit=$(echo "$LOGS_NUIT" | awk '{print $4}' | sort -u | tr '\n' ', ' | sed 's/,$//')
  _ajouter "INFO" "Bornes concernées par l'activité nocturne : $bornes_nuit"
fi

# --- Anomalie 3 : Borne anormalement bavarde ---------------------------------
for fichier in "$LOG_DIR"/*.log; do
  [[ -f "$fichier" ]] || continue
  nom_borne=$(basename "$fichier" .log)

  # Compter les lignes de la veille pour cette borne
  nb_hier=$(grep -c "$DATE_HIER_SYSLOG" "$fichier" 2>/dev/null || echo "0")

  # Compter la moyenne sur les 7 derniers jours (approximation)
  nb_total=$(wc -l < "$fichier" 2>/dev/null || echo "0")
  # Moyenne grossière : total / 7
  moyenne=$(( nb_total / 7 ))

  if [[ $moyenne -gt 0 && $nb_hier -gt $(( moyenne * SEUIL_BORNE_BAVARDE / 100 )) ]]; then
    _ajouter "ATTENTION" "Borne $nom_borne — volume anormal : $nb_hier lignes hier (moyenne ~$moyenne/jour, seuil ${SEUIL_BORNE_BAVARDE}%)"
  else
    _ajouter "INFO" "Borne $nom_borne — $nb_hier ligne(s) hier (normale)"
  fi
done

# --- Génération du rapport ---------------------------------------------------
{
  echo "============================================================"
  echo "  RAPPORT D'ANOMALIES — WIFI PUBLIC"
  echo "  Mairie de Rezé — DSI"
  echo "  Période analysée : $DATE_HIER"
  echo "  Généré le        : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================================"
  echo ""
  echo "  RÉSUMÉ :"
  echo "  INFO      : $NB_INFO"
  echo "  ATTENTION : $NB_ATTENTION"
  echo "  ANOMALIE  : $NB_ANOMALIE"
  echo ""
  echo "------------------------------------------------------------"
  echo "  DÉTAIL :"
  echo ""
  echo "$RAPPORT_CONTENU"
  echo "------------------------------------------------------------"
  echo ""
  echo "  NOTE : Ce rapport est basé sur les métadonnées de connexion"
  echo "  (MAC, IP, horodatage). Il ne reflète pas le contenu des"
  echo "  échanges réseau. Pour une analyse approfondie, consulter"
  echo "  les logs bruts dans $LOG_DIR/"
  echo "============================================================"
} > "$FICHIER_RAPPORT"

# Afficher le rapport dans la console
cat "$FICHIER_RAPPORT"

echo ""
echo "Rapport enregistré : $FICHIER_RAPPORT"

# Notification si anomalies détectées
if [[ $NB_ANOMALIE -gt 0 ]]; then
  source "$SCRIPT_DIR/check_health.sh" 2>/dev/null || true
  # Réutiliser la fonction de notification de check_health si disponible
  echo "[ANOMALIE] $NB_ANOMALIE anomalie(s) détectée(s) le $DATE_HIER — consulter $FICHIER_RAPPORT" >> "$ALERTE_LOG"
fi
