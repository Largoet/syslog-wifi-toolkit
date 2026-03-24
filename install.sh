#!/bin/bash
# =============================================================================
# install.sh — Installation et configuration du serveur rsyslog
# =============================================================================
# Usage :
#   sudo ./scripts/install.sh --reseau public
#   sudo ./scripts/install.sh --reseau interne
#   sudo ./scripts/install.sh --reseau all     # Les deux réseaux
#
# Idempotent : peut être relancé sans risque sur un serveur déjà configuré.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"

# --- Fonctions utilitaires ---------------------------------------------------
log_info()   { echo -e "\e[34m[INFO]\e[0m    $1"; }
log_ok()     { echo -e "\e[32m[OK]\e[0m      $1"; }
log_warn()   { echo -e "\e[33m[ATTENTION]\e[0m $1"; }
log_erreur() { echo -e "\e[31m[ERREUR]\e[0m  $1"; exit 1; }

_usage() {
  echo "Usage : sudo ./scripts/install.sh --reseau [public|interne|all]"
  echo ""
  echo "  --reseau public    Configure la collecte WiFi public"
  echo "  --reseau interne   Configure la collecte WiFi interne (agents)"
  echo "  --reseau all       Configure les deux réseaux"
  exit 0
}

# --- Parsing des arguments ---------------------------------------------------
RESEAU=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reseau) RESEAU="$2"; shift 2 ;;
    --help)   _usage ;;
    *) echo "[ERREUR] Option inconnue : $1"; _usage ;;
  esac
done

[[ -z "$RESEAU" ]] && { echo "[ERREUR] --reseau est obligatoire."; _usage; }
[[ $EUID -ne 0 ]]  && log_erreur "Ce script doit être exécuté avec sudo."

# --- Détermine les configs à charger -----------------------------------------
CONFIGS=()
case "$RESEAU" in
  public)  CONFIGS=("$CONFIG_DIR/config.public.sh") ;;
  interne) CONFIGS=("$CONFIG_DIR/config.interne.sh") ;;
  all)     CONFIGS=("$CONFIG_DIR/config.public.sh" "$CONFIG_DIR/config.interne.sh") ;;
  *) log_erreur "Réseau inconnu : $RESEAU. Valeurs acceptées : public, interne, all" ;;
esac

# --- Vérification des fichiers de config -------------------------------------
for cfg in "${CONFIGS[@]}"; do
  if [[ ! -f "$cfg" ]]; then
    log_erreur "Fichier de configuration introuvable : $cfg\nCopier config.example.sh et le renseigner."
  fi
done

# --- Installation de rsyslog (une seule fois) --------------------------------
if ! command -v rsyslogd &>/dev/null; then
  log_info "Installation de rsyslog..."
  apt update -q && apt install -y rsyslog
  log_ok "rsyslog installé."
else
  log_ok "rsyslog déjà installé."
fi

# --- Boucle sur chaque réseau à configurer -----------------------------------
for cfg in "${CONFIGS[@]}"; do
  source "$cfg"

  echo ""
  echo "============================================================"
  echo "  Configuration réseau : $RESEAU_NOM — $RESEAU_DESCRIPTION"
  echo "============================================================"

  # Création des dossiers
  log_info "Création des dossiers de logs..."
  for dir in "$LOG_DIR" "$RAPPORT_DIR" "$EXPORT_DIR"; do
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      chown syslog:adm "$dir"
      chmod 750 "$dir"
      log_ok "Créé : $dir"
    else
      log_ok "Existant : $dir"
    fi
  done

  # Règle rsyslog pour ce réseau
  RSYSLOG_CONF_RESEAU="/etc/rsyslog.d/10-wifi-${RESEAU_NOM}.conf"
  log_info "Création de la règle rsyslog pour $RESEAU_NOM..."

  cat > "$RSYSLOG_CONF_RESEAU" <<EOF
# Configuration rsyslog — WiFi ${RESEAU_NOM} (${RESEAU_DESCRIPTION})
# Généré par install.sh le $(date '+%Y-%m-%d %H:%M')

\$template Wifi_${RESEAU_NOM},"${LOG_DIR}/%HOSTNAME%.log"

if \$fromhost-ip startswith "$(echo "$BORNES_PLAGE_IP" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)." then ?Wifi_${RESEAU_NOM}
& stop
EOF

  log_ok "Règle rsyslog créée : $RSYSLOG_CONF_RESEAU"

  # Logrotate pour ce réseau
  log_info "Configuration logrotate pour $RESEAU_NOM..."
  cat > "/etc/logrotate.d/wifi-${RESEAU_NOM}" <<EOF
# Rotation logs WiFi ${RESEAU_NOM} — conservation 1 an
${LOG_DIR}/*.log {
    daily
    rotate 365
    compress
    delaycompress
    missingok
    notifempty
    create 640 syslog adm
    dateext
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF
  log_ok "logrotate configuré pour $RESEAU_NOM."

  # Firewall
  log_info "Ouverture du port 514 pour $BORNES_PLAGE_IP..."
  command -v ufw &>/dev/null || apt install -y ufw
  ufw allow ssh > /dev/null 2>&1 || true
  ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_UDP" proto udp > /dev/null
  ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_TCP" proto tcp > /dev/null
  ufw --force enable > /dev/null 2>&1 || true
  log_ok "Firewall configuré pour $RESEAU_NOM."
done

# --- Activer la réception UDP/TCP dans rsyslog.conf --------------------------
RSYSLOG_CONF="/etc/rsyslog.conf"
log_info "Activation de la réception UDP/TCP dans rsyslog..."

sed -i 's/^#module(load="imudp")/module(load="imudp")/' "$RSYSLOG_CONF"
sed -i 's/^#input(type="imudp"/input(type="imudp"/' "$RSYSLOG_CONF"
sed -i 's/^#module(load="imtcp")/module(load="imtcp")/' "$RSYSLOG_CONF"
sed -i 's/^#input(type="imtcp"/input(type="imtcp"/' "$RSYSLOG_CONF"

# --- Validation et redémarrage -----------------------------------------------
log_info "Validation de la configuration rsyslog..."
rsyslogd -N1 2>&1 | grep -qi "error" && log_erreur "Erreur de configuration rsyslog."
log_ok "Configuration valide."

systemctl enable rsyslog > /dev/null
systemctl restart rsyslog
sleep 1
systemctl is-active --quiet rsyslog && log_ok "rsyslog actif." || log_erreur "rsyslog n'a pas démarré."

# --- Test de réception -------------------------------------------------------
logger -p local0.info "syslog-toolkit install.sh : installation $RESEAU validée le $(date)"
sleep 1
grep -q "syslog-toolkit" /var/log/syslog 2>/dev/null && log_ok "Test de réception OK." || log_warn "Vérifier /var/log/syslog manuellement."

echo ""
echo "============================================================"
echo "  Installation terminée — réseau(x) : $RESEAU"
echo "============================================================"
echo "  Serveur syslog : $SYSLOG_IP:514"
echo "  Prochaine étape : configurer le forwarding sur les bornes"
echo "============================================================"
