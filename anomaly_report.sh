#!/bin/bash
# =============================================================================
# install.sh — Installation et configuration du serveur rsyslog
# =============================================================================
# Usage : sudo ./scripts/install.sh
#
# Ce script est idempotent : peut être relancé sans risque sur un serveur
# déjà configuré. Il vérifie chaque étape avant de l'exécuter.
# =============================================================================

set -euo pipefail

# --- Chargement de la configuration -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[ERREUR] Fichier de configuration introuvable : $CONFIG_FILE"
  echo "         Copier config/config.example.sh vers config/config.sh et le renseigner."
  exit 1
fi

source "$CONFIG_FILE"

# --- Fonctions utilitaires ---------------------------------------------------
log_info()    { echo -e "\e[34m[INFO]\e[0m    $1"; }
log_ok()      { echo -e "\e[32m[OK]\e[0m      $1"; }
log_warn()    { echo -e "\e[33m[ATTENTION]\e[0m $1"; }
log_erreur()  { echo -e "\e[31m[ERREUR]\e[0m  $1"; exit 1; }

# --- Vérifications préalables ------------------------------------------------
log_info "Vérification des prérequis..."

# Droits root
if [[ $EUID -ne 0 ]]; then
  log_erreur "Ce script doit être exécuté avec sudo."
fi

# OS compatible
if ! command -v apt &>/dev/null; then
  log_erreur "Ce script nécessite une distribution basée sur Debian/Ubuntu."
fi

log_ok "Prérequis validés."

# --- Installation de rsyslog -------------------------------------------------
log_info "Vérification de rsyslog..."

if command -v rsyslogd &>/dev/null; then
  log_ok "rsyslog déjà installé ($(rsyslogd -v | head -1))."
else
  log_info "Installation de rsyslog..."
  apt update -q
  apt install -y rsyslog
  log_ok "rsyslog installé."
fi

# --- Création de l'arborescence des logs -------------------------------------
log_info "Création des dossiers de logs..."

for dir in "$LOG_DIR" "$RAPPORT_DIR" "$EXPORT_DIR"; do
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    chown syslog:adm "$dir"
    chmod 750 "$dir"
    log_ok "Dossier créé : $dir"
  else
    log_ok "Dossier déjà existant : $dir"
  fi
done

# --- Configuration rsyslog ---------------------------------------------------
log_info "Configuration de rsyslog en mode récepteur..."

RSYSLOG_CONF="/etc/rsyslog.conf"
RSYSLOG_WIFI_CONF="/etc/rsyslog.d/10-wifi.conf"

# Activer la réception UDP et TCP dans rsyslog.conf
if grep -q "^#module(load=\"imudp\")" "$RSYSLOG_CONF"; then
  sed -i 's/^#module(load="imudp")/module(load="imudp")/' "$RSYSLOG_CONF"
  sed -i 's/^#input(type="imudp"/input(type="imudp"/' "$RSYSLOG_CONF"
  log_ok "Réception UDP activée."
fi

if grep -q "^#module(load=\"imtcp\")" "$RSYSLOG_CONF"; then
  sed -i 's/^#module(load="imtcp")/module(load="imtcp")/' "$RSYSLOG_CONF"
  sed -i 's/^#input(type="imtcp"/input(type="imtcp"/' "$RSYSLOG_CONF"
  log_ok "Réception TCP activée."
fi

# Créer la règle de tri par borne WiFi
cat > "$RSYSLOG_WIFI_CONF" <<EOF
# Configuration rsyslog — Logs WiFi public
# Généré par install.sh le $(date '+%Y-%m-%d %H:%M')

# Tri des logs entrants par borne (fichier séparé par hostname source)
\$template PerBorne,"/var/log/wifi/%HOSTNAME%.log"

# Appliquer uniquement aux logs venant de la plage IP des bornes
if \$fromhost-ip startswith "$(echo "$BORNES_PLAGE_IP" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)." then ?PerBorne
& stop
EOF

log_ok "Configuration rsyslog WiFi créée : $RSYSLOG_WIFI_CONF"

# --- Configuration logrotate -------------------------------------------------
log_info "Configuration de logrotate..."

cat > /etc/logrotate.d/wifi-syslog <<EOF
# Rotation des logs WiFi public — conservation 1 an (LCEN)
# Généré par install.sh le $(date '+%Y-%m-%d %H:%M')

$LOG_DIR/*.log {
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

log_ok "logrotate configuré (rotation quotidienne, conservation 365 jours)."

# --- Configuration du firewall -----------------------------------------------
log_info "Configuration du firewall (ufw)..."

if ! command -v ufw &>/dev/null; then
  apt install -y ufw
fi

ufw allow ssh > /dev/null
ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_UDP" proto udp > /dev/null
ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_TCP" proto tcp > /dev/null

# Activer ufw si pas déjà actif
if ! ufw status | grep -q "Status: active"; then
  ufw --force enable > /dev/null
fi

log_ok "Firewall configuré — port 514 UDP/TCP ouvert pour $BORNES_PLAGE_IP"

# --- Validation de la configuration rsyslog ----------------------------------
log_info "Validation de la configuration rsyslog..."

if rsyslogd -N1 2>&1 | grep -qi "error"; then
  log_erreur "Erreur dans la configuration rsyslog. Vérifier $RSYSLOG_CONF et $RSYSLOG_WIFI_CONF."
fi

log_ok "Configuration rsyslog valide."

# --- Démarrage du service ----------------------------------------------------
log_info "Activation et démarrage de rsyslog..."

systemctl enable rsyslog > /dev/null
systemctl restart rsyslog

sleep 1

if systemctl is-active --quiet rsyslog; then
  log_ok "rsyslog actif et en écoute."
else
  log_erreur "rsyslog n'a pas démarré. Vérifier : journalctl -u rsyslog"
fi

# --- Test de réception -------------------------------------------------------
log_info "Test de réception d'un log synthétique..."

logger -p local0.info "syslog-toolkit install.sh : installation validée le $(date)"
sleep 1

if grep -q "syslog-toolkit" /var/log/syslog 2>/dev/null; then
  log_ok "Test de réception réussi."
else
  log_warn "Test de réception non concluant — vérifier /var/log/syslog manuellement."
fi

# --- Résumé ------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Installation terminée avec succès"
echo "============================================================"
echo "  Serveur syslog    : $SYSLOG_IP:$SYSLOG_PORT_TCP (TCP)"
echo "  Logs WiFi         : $LOG_DIR/"
echo "  Rapports          : $RAPPORT_DIR/"
echo "  Exports légaux    : $EXPORT_DIR/"
echo ""
echo "  Prochaine étape : configurer le forwarding syslog"
echo "  sur les bornes WiFi vers $SYSLOG_IP:514"
echo "============================================================"
