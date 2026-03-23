#!/bin/bash
# =============================================================================
# check_health.sh — Supervision des bornes WiFi
# =============================================================================
# Usage :
#   ./scripts/check_health.sh --mode ping        # Niveau 1 : ping ICMP
#   ./scripts/check_health.sh --mode heartbeat   # Niveau 2 : vérif heartbeat
#   ./scripts/check_health.sh                    # Les deux niveaux
#
# Planification recommandée via cron :
#   */5 * * * * /chemin/check_health.sh --mode ping
#   0 */6 * * * /chemin/check_health.sh --mode heartbeat
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/config.sh"

# --- Fonctions utilitaires ---------------------------------------------------
log_info()   { echo -e "\e[34m[INFO]\e[0m    $1"; }
log_ok()     { echo -e "\e[32m[OK]\e[0m      $1"; }
log_warn()   { echo -e "\e[33m[ATTENTION]\e[0m $1"; }
log_alerte() {
  local msg="[ALERTE] $(date '+%Y-%m-%d %H:%M:%S') — $1"
  echo -e "\e[31m$msg\e[0m"
  echo "$msg" >> "$ALERTE_LOG"
  _envoyer_notification "$1"
}

_envoyer_notification() {
  local message="$1"
  case "$NOTIFICATION_MODE" in
    email)
      # Nécessite mailutils installé sur le serveur
      echo "$message" | mail -s "[SYSLOG-TOOLKIT] Alerte borne WiFi" "$NOTIFICATION_EMAIL" 2>/dev/null || true
      ;;
    webhook)
      # Webhook générique (Slack, Teams, Mattermost...)
      curl -s -X POST "$NOTIFICATION_WEBHOOK_URL" \
        -H 'Content-type: application/json' \
        --data "{\"text\":\"$message\"}" > /dev/null 2>&1 || true
      ;;
    log_only|*)
      # Par défaut : log uniquement, pas de notification externe
      ;;
  esac
}

# --- Mode de lancement -------------------------------------------------------
MODE="${1:-}"
case "$MODE" in
  --mode) MODE="$2" ;;
  "")     MODE="all" ;;
esac

# --- Niveau 1 : Ping ICMP ----------------------------------------------------
_check_ping() {
  log_info "=== Niveau 1 : Ping ICMP ==="
  local nb_ok=0
  local nb_ko=0

  for borne_entry in "${BORNES[@]}"; do
    local nom="${borne_entry%%:*}"
    local ip="${borne_entry##*:}"

    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" > /dev/null 2>&1; then
      log_ok "$nom ($ip) — joignable"
      ((nb_ok++))
    else
      log_alerte "Borne $nom ($ip) ne répond pas au ping — panne réseau ou matérielle possible"
      ((nb_ko++))
    fi
  done

  echo ""
  log_info "Ping : $nb_ok borne(s) OK / $nb_ko borne(s) en défaut"
}

# --- Niveau 2 : Heartbeat syslog ---------------------------------------------
_check_heartbeat() {
  log_info "=== Niveau 2 : Vérification heartbeat ==="
  local nb_ok=0
  local nb_ko=0
  local seuil_secondes=$(( HEARTBEAT_SEUIL_HEURES * 3600 ))
  local maintenant=$(date +%s)

  for borne_entry in "${BORNES[@]}"; do
    local nom="${borne_entry%%:*}"
    local fichier_log="$LOG_DIR/${nom}.log"

    if [[ ! -f "$fichier_log" ]]; then
      log_alerte "Borne $nom — aucun fichier de log trouvé dans $LOG_DIR"
      ((nb_ko++))
      continue
    fi

    # Chercher le dernier heartbeat dans le fichier de log de la borne
    local dernier_heartbeat
    dernier_heartbeat=$(grep "$HEARTBEAT_TAG" "$fichier_log" 2>/dev/null | tail -1 || echo "")

    if [[ -z "$dernier_heartbeat" ]]; then
      log_alerte "Borne $nom — aucun heartbeat trouvé dans les logs"
      ((nb_ko++))
      continue
    fi

    # Extraire l'horodatage du dernier heartbeat (format syslog : Mar 23 14:00:01)
    local ts_heartbeat
    ts_heartbeat=$(echo "$dernier_heartbeat" | awk '{print $1, $2, $3}')
    local ts_epoch
    ts_epoch=$(date -d "$ts_heartbeat $(date +%Y)" +%s 2>/dev/null || echo "0")

    local ecart=$(( maintenant - ts_epoch ))

    if [[ $ecart -gt $seuil_secondes ]]; then
      local ecart_h=$(( ecart / 3600 ))
      log_alerte "Borne $nom — dernier heartbeat il y a ${ecart_h}h (seuil : ${HEARTBEAT_SEUIL_HEURES}h)"
      ((nb_ko++))
    else
      log_ok "$nom — heartbeat reçu il y a $(( ecart / 60 )) minutes"
      ((nb_ok++))
    fi
  done

  echo ""
  log_info "Heartbeat : $nb_ok borne(s) OK / $nb_ko borne(s) en défaut"
}

# --- Exécution ---------------------------------------------------------------
echo "============================================================"
echo "  check_health.sh — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

case "$MODE" in
  ping)       _check_ping ;;
  heartbeat)  _check_heartbeat ;;
  all|*)
    _check_ping
    echo ""
    _check_heartbeat
    ;;
esac

echo ""
echo "Alertes enregistrées dans : $ALERTE_LOG"
