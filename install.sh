#!/bin/bash
# =============================================================================
# install.sh — Installation et configuration du serveur rsyslog
# =============================================================================
# VERSION : 2.0
#
# USAGE :
#   sudo ./scripts/install.sh --reseau public    # WiFi public uniquement
#   sudo ./scripts/install.sh --reseau interne   # WiFi interne uniquement
#   sudo ./scripts/install.sh --reseau all       # Les deux réseaux
#
# IDEMPOTENT : ce script peut être relancé sans risque sur un serveur déjà
# configuré. Il vérifie l'état avant chaque action et ne refait que ce qui
# est nécessaire.
#
# CHECKLIST DE VALIDATION (à exécuter sur VM après installation) :
# -----------------------------------------------------------------------------
# [ ] TEST 1 — Installation complète réseau public
#       sudo ./install.sh --reseau public
#       Résultat attendu : toutes les étapes affichées [OK], rsyslog actif
#
# [ ] TEST 2 — Idempotence — relancer sans erreur
#       sudo ./install.sh --reseau public  (une deuxième fois)
#       Résultat attendu : "Existant" pour les dossiers, aucune erreur
#
# [ ] TEST 3 — Installation des deux réseaux
#       sudo ./install.sh --reseau all
#       Résultat attendu : deux règles dans /etc/rsyslog.d/, deux dossiers de logs
#       Vérifier : ls /etc/rsyslog.d/10-wifi-*.conf
#
# [ ] TEST 4 — Vérification écoute port 514
#       ss -ulnp | grep 514   (UDP)
#       ss -tlnp | grep 514   (TCP)
#       Résultat attendu : rsyslogd en écoute sur 0.0.0.0:514
#
# [ ] TEST 5 — Test de réception depuis une autre machine du réseau
#       logger -n [IP_SERVEUR_SYSLOG] -P 514 -T "test depuis machine externe"
#       Résultat attendu : message visible dans /var/log/wifi-public/ ou syslog
#
# [ ] TEST 6 — Vérification logrotate
#       sudo logrotate -d /etc/logrotate.d/wifi-public
#       Résultat attendu : aucune erreur dans la sortie
#
# [ ] TEST 7 — Vérification trace dans syslog
#       grep "install.sh" /var/log/syslog | tail -5
#       Résultat attendu : entrées de début et fin d'installation
#
# [ ] TEST 8 — Vérification backup rsyslog.conf
#       ls /etc/rsyslog.conf.backup_*
#       Résultat attendu : un fichier backup horodaté présent
# -----------------------------------------------------------------------------
#
# AUTEUR : Thibaut — Stagiaire DevOps — DSI Mairie de Rezé — 2026
# =============================================================================

set -euo pipefail
# NOTE : set -euo pipefail protège contre les erreurs silencieuses.
# -e = arrêt immédiat si une commande échoue
# -u = arrêt si une variable non définie est utilisée
# -o pipefail = une pipeline échoue si l'une de ses parties échoue

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
SCRIPT_NAME=$(basename "$0")

# =============================================================================
# FONCTIONS
# =============================================================================

# Fonction de log unifiée — console colorée + trace dans syslog système.
# Utiliser : _log INFO "message" | _log OK "..." | _log ATTENTION "..." | _log ERREUR "..."
# NOTE ÉVOLUTION : pour notifier par email ou webhook lors d'une erreur
# d'installation, ajouter la logique dans le bloc ERREUR ci-dessous.
_log() {
  local niveau="$1" message="$2"
  local couleur
  case "$niveau" in
    INFO)      couleur="\e[34m" ;;   # bleu
    OK)        couleur="\e[32m" ;;   # vert
    ATTENTION) couleur="\e[33m" ;;   # orange
    ERREUR)    couleur="\e[31m" ;;   # rouge
    *)         couleur="\e[0m"  ;;
  esac

  echo -e "${couleur}[${niveau}]\e[0m  $message"
  logger -t "$SCRIPT_NAME" "$niveau — $message"

  [[ "$niveau" == "ERREUR" ]] && exit 1
}

# Affichage de l'aide
_usage() {
  echo "Usage : sudo $SCRIPT_NAME --reseau [public|interne|all]"
  echo ""
  echo "  --reseau public    Configure la collecte WiFi public"
  echo "  --reseau interne   Configure la collecte WiFi interne (agents)"
  echo "  --reseau all       Configure les deux réseaux simultanément"
  exit 0
}

# Extrait le préfixe réseau depuis une notation CIDR.
# Exemple : "192.168.10.0/24" → "192.168.10"
# Cette valeur est utilisée dans la règle rsyslog pour filtrer les logs
# entrants selon l'IP source des bornes.
#
# NOTE TECHNIQUE : rsyslog utilise "startswith" pour filtrer par préfixe IP.
# On doit donc extraire "192.168.10" depuis "192.168.10.0/24".
# La fonction valide le format attendu avant de procéder.
#
# NOTE ÉVOLUTION : si la DSI utilise des plages non standard (ex: /16),
# cette fonction devra être adaptée pour extraire le bon nombre d'octets.
_extraire_prefixe_ip() {
  local cidr="$1"

  # Validation : le format attendu est X.X.X.X/XX
  if ! echo "$cidr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
    _log ERREUR "Format IP invalide : '$cidr' — format attendu : 192.168.10.0/24"
  fi

  # Extraction : on prend la partie avant le /CIDR, puis on supprime le dernier octet
  # Exemple : 192.168.10.0/24 → 192.168.10.0 → 192.168.10
  echo "$cidr" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev
}

# =============================================================================
# PARSING DES ARGUMENTS
# =============================================================================

RESEAU=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reseau) RESEAU="$2"; shift 2 ;;
    --help)   _usage ;;
    *) echo "[ERREUR] Option inconnue : $1"; _usage ;;
  esac
done

# =============================================================================
# VÉRIFICATIONS PRÉALABLES
# =============================================================================

[[ -z "$RESEAU" ]] && { echo "[ERREUR] --reseau est obligatoire."; _usage; }

# Vérification des droits root — nécessaire pour apt, systemctl, ufw, etc.
[[ $EUID -ne 0 ]] && _log ERREUR "Ce script doit être exécuté avec sudo."

# Détermination des fichiers de config à charger selon le réseau demandé
CONFIGS=()
case "$RESEAU" in
  public)  CONFIGS=("$CONFIG_DIR/config.public.sh") ;;
  interne) CONFIGS=("$CONFIG_DIR/config.interne.sh") ;;
  all)     CONFIGS=("$CONFIG_DIR/config.public.sh" "$CONFIG_DIR/config.interne.sh") ;;
  *) _log ERREUR "Réseau inconnu : '$RESEAU'. Valeurs acceptées : public, interne, all" ;;
esac

# Vérification que les fichiers de config existent
# NOTE : ces fichiers ne sont pas dans Git (voir .gitignore).
# Les créer depuis config.example.sh avant de lancer ce script.
for cfg in "${CONFIGS[@]}"; do
  [[ ! -f "$cfg" ]] && _log ERREUR "Config introuvable : $cfg — copier config.example.sh et le renseigner."
done

# Traçage du démarrage de l'installation dans syslog
logger -t "$SCRIPT_NAME" "DEBUT INSTALLATION — réseau=$RESEAU opérateur=$(whoami)@$(hostname)"

# =============================================================================
# INSTALLATION DE RSYSLOG
# =============================================================================

# rsyslog est souvent déjà présent sur Debian/Ubuntu — on vérifie avant d'installer.
# NOTE : "command -v" vérifie si une commande existe sans l'exécuter.
if ! command -v rsyslogd &>/dev/null; then
  _log INFO "Installation de rsyslog..."
  apt update -q && apt install -y rsyslog
  _log OK "rsyslog installé."
else
  _log OK "rsyslog déjà présent ($(rsyslogd -v | head -1))."
fi

# =============================================================================
# BACKUP DE RSYSLOG.CONF
# =============================================================================

RSYSLOG_CONF="/etc/rsyslog.conf"

# On ne crée le backup qu'une seule fois — s'il existe déjà, on ne l'écrase pas.
# NOTE : le backup est horodaté pour garder une trace de l'état initial du fichier.
# En cas de problème après installation, restaurer avec :
#   cp /etc/rsyslog.conf.backup_YYYYMMDD_HHMMSS /etc/rsyslog.conf
#   systemctl restart rsyslog
BACKUP_CONF="/etc/rsyslog.conf.backup_$(date '+%Y%m%d_%H%M%S')"
if ! ls /etc/rsyslog.conf.backup_* &>/dev/null; then
  cp "$RSYSLOG_CONF" "$BACKUP_CONF"
  _log OK "Backup rsyslog.conf créé : $BACKUP_CONF"
else
  _log OK "Backup rsyslog.conf déjà existant — conservé."
fi

# =============================================================================
# ACTIVATION DE LA RÉCEPTION UDP/TCP DANS RSYSLOG.CONF
# =============================================================================

# rsyslog n'écoute pas les connexions réseau par défaut.
# On doit décommenter les modules imudp (UDP) et imtcp (TCP) dans rsyslog.conf.
#
# NOTE SUR LES sed :
# sed -i 's/ancien/nouveau/' fichier  →  remplace "ancien" par "nouveau" dans le fichier
# Le ^ signifie "début de ligne" — on cherche une ligne qui commence par #module...
# Si la ligne est déjà décommentée, le sed ne trouve rien et ne fait rien (pas d'erreur).
#
# On vérifie APRÈS si les modules sont bien actifs, plutôt que de supposer
# que le sed a fonctionné.

_log INFO "Activation de la réception UDP/TCP dans rsyslog..."

# Décommenter les modules UDP et TCP si nécessaire
sed -i 's/^#module(load="imudp")/module(load="imudp")/' "$RSYSLOG_CONF"
sed -i 's/^#input(type="imudp"/input(type="imudp"/'     "$RSYSLOG_CONF"
sed -i 's/^#module(load="imtcp")/module(load="imtcp")/' "$RSYSLOG_CONF"
sed -i 's/^#input(type="imtcp"/input(type="imtcp"/'     "$RSYSLOG_CONF"

# Vérification que les modules sont bien présents et actifs après les sed
# NOTE : on vérifie le résultat plutôt que de faire confiance au sed.
if ! grep -q '^module(load="imudp")' "$RSYSLOG_CONF"; then
  _log ATTENTION "Module UDP (imudp) non trouvé dans $RSYSLOG_CONF — vérification manuelle requise."
fi
if ! grep -q '^module(load="imtcp")' "$RSYSLOG_CONF"; then
  _log ATTENTION "Module TCP (imtcp) non trouvé dans $RSYSLOG_CONF — vérification manuelle requise."
fi

_log OK "Réception UDP/TCP activée."

# =============================================================================
# CONFIGURATION PAR RÉSEAU
# =============================================================================

for cfg in "${CONFIGS[@]}"; do

  # Chargement des variables du réseau (LOG_DIR, BORNES_PLAGE_IP, etc.)
  source "$cfg"

  echo ""
  echo "============================================================"
  echo "  Réseau : $RESEAU_NOM — $RESEAU_DESCRIPTION"
  echo "============================================================"

  # --- Validation du format de la plage IP -----------------------------------
  # On valide AVANT de générer la règle rsyslog pour éviter une règle cassée.
  PREFIXE_IP=$(_extraire_prefixe_ip "$BORNES_PLAGE_IP")
  _log OK "Préfixe IP extrait : $PREFIXE_IP (depuis $BORNES_PLAGE_IP)"

  # --- Création des dossiers de logs -----------------------------------------
  # chmod 750 = lecture/écriture pour le propriétaire (syslog), lecture pour
  # le groupe (adm), aucun accès pour les autres — seuls les admins peuvent lire.
  _log INFO "Création des dossiers..."
  for dir in "$LOG_DIR" "$RAPPORT_DIR" "$EXPORT_DIR"; do
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      chown syslog:adm "$dir"
      chmod 750 "$dir"
      _log OK "Créé : $dir"
    else
      _log OK "Existant : $dir"
    fi
  done

  # --- Règle rsyslog pour ce réseau ------------------------------------------
  # Cette règle dit à rsyslog :
  #   "Si le log vient d'une IP qui commence par [PREFIXE_IP],
  #    l'écrire dans /var/log/wifi-[reseau]/[nom_borne].log
  #    et ne pas le traiter ailleurs (& stop)"
  #
  # NOTE : le fichier est dans /etc/rsyslog.d/ — rsyslog charge automatiquement
  # tous les fichiers .conf de ce dossier au démarrage.
  # NOTE ÉVOLUTION : pour ajouter une source Sophos, créer un fichier
  # /etc/rsyslog.d/10-sophos.conf avec la même logique et l'IP du Sophos.
  RSYSLOG_CONF_RESEAU="/etc/rsyslog.d/10-wifi-${RESEAU_NOM}.conf"
  _log INFO "Création règle rsyslog pour $RESEAU_NOM..."

  cat > "$RSYSLOG_CONF_RESEAU" <<EOF
# =============================================================
# Règle rsyslog — WiFi ${RESEAU_NOM} (${RESEAU_DESCRIPTION})
# Généré par install.sh le $(date '+%Y-%m-%d %H:%M')
# NE PAS MODIFIER MANUELLEMENT — relancer install.sh pour régénérer
# =============================================================

# Template : définit le chemin du fichier de log par borne
# %HOSTNAME% sera remplacé par le nom de la borne source du log
\$template Wifi_${RESEAU_NOM},"${LOG_DIR}/%HOSTNAME%.log"

# Règle de filtrage : si le log vient de la plage IP des bornes ${RESEAU_NOM}
# alors l'écrire dans le fichier défini par le template ci-dessus
if \$fromhost-ip startswith "${PREFIXE_IP}." then ?Wifi_${RESEAU_NOM}

# "& stop" : ne pas traiter ce log dans d'autres règles rsyslog
& stop
EOF

  _log OK "Règle rsyslog créée : $RSYSLOG_CONF_RESEAU"

  # --- Configuration logrotate -----------------------------------------------
  # logrotate tourne automatiquement chaque nuit (via cron).
  # Il archive et compresse les anciens logs pour éviter de saturer le disque.
  #
  # Paramètres clés :
  #   daily      = rotation chaque jour
  #   rotate 365 = garder 365 fichiers = 1 an (obligation LCEN)
  #   compress   = compresser en .gz pour économiser l'espace
  #   dateext    = nommer les archives avec la date (ex: borne.log-20260323)
  _log INFO "Configuration logrotate pour $RESEAU_NOM..."

  cat > "/etc/logrotate.d/wifi-${RESEAU_NOM}" <<EOF
# logrotate — WiFi ${RESEAU_NOM}
# Conservation 1 an (obligation LCEN art. 6-II)
# Généré par install.sh le $(date '+%Y-%m-%d %H:%M')
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

  _log OK "logrotate configuré pour $RESEAU_NOM (365 jours)."

  # --- Configuration du firewall (ufw) ----------------------------------------
  # On restreint la réception syslog (port 514) aux seules IPs des bornes.
  # Cela évite que n'importe quelle machine du réseau envoie des logs au serveur.
  #
  # NOTE : "|| true" sur ufw allow ssh évite un arrêt du script si la règle
  # SSH existe déjà — ufw retourne une erreur dans ce cas, ce qui est normal.
  _log INFO "Configuration firewall pour $RESEAU_NOM..."

  command -v ufw &>/dev/null || apt install -y ufw

  ufw allow ssh              > /dev/null 2>&1 || true   # SSH — ne jamais bloquer
  ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_UDP" proto udp > /dev/null
  ufw allow from "$BORNES_PLAGE_IP" to any port "$SYSLOG_PORT_TCP" proto tcp > /dev/null
  ufw --force enable         > /dev/null 2>&1 || true

  _log OK "Firewall : port 514 ouvert pour $BORNES_PLAGE_IP"

done

# =============================================================================
# VALIDATION DE LA CONFIGURATION RSYSLOG
# =============================================================================

# rsyslogd -N1 vérifie la syntaxe de tous les fichiers de config sans
# redémarrer le service — c'est l'équivalent d'un "dry run".
_log INFO "Validation de la configuration rsyslog..."

# NOTE : on redirige stderr vers stdout (2>&1) pour capturer les messages
# d'erreur de rsyslogd qui sortent sur stderr par défaut.
if rsyslogd -N1 2>&1 | grep -qi "error"; then
  _log ERREUR "Erreur dans la configuration rsyslog — vérifier /etc/rsyslog.conf et /etc/rsyslog.d/"
fi

_log OK "Configuration rsyslog valide."

# =============================================================================
# DÉMARRAGE DU SERVICE
# =============================================================================

# systemctl enable = démarrer rsyslog automatiquement au boot du serveur
# systemctl restart = relancer pour prendre en compte les nouvelles configs
systemctl enable rsyslog > /dev/null
systemctl restart rsyslog
sleep 1   # petite pause pour laisser le temps au service de démarrer

if systemctl is-active --quiet rsyslog; then
  _log OK "rsyslog actif et en écoute."
else
  _log ERREUR "rsyslog n'a pas démarré. Diagnostic : journalctl -u rsyslog --no-pager | tail -20"
fi

# =============================================================================
# TEST DE RÉCEPTION
# =============================================================================

# On envoie un log de test depuis ce serveur vers lui-même pour vérifier
# que rsyslog reçoit et écrit bien les logs locaux.
# NOTE : ce test ne valide pas la réception depuis les bornes WiFi —
# voir TEST 5 de la checklist pour ça (nécessite une autre machine).
_log INFO "Test de réception local..."
logger -p local0.info "syslog-toolkit install.sh : installation $RESEAU validée le $(date)"
sleep 1

if grep -q "syslog-toolkit" /var/log/syslog 2>/dev/null; then
  _log OK "Test de réception local OK."
else
  _log ATTENTION "Test de réception non concluant — vérifier /var/log/syslog manuellement."
fi

# =============================================================================
# TRAÇAGE DE FIN + RÉSUMÉ
# =============================================================================

logger -t "$SCRIPT_NAME" "FIN INSTALLATION — réseau=$RESEAU opérateur=$(whoami) statut=OK"

echo ""
echo "============================================================"
echo "  Installation terminée — réseau(x) : $RESEAU"
echo "============================================================"
echo ""
echo "  Dossiers de logs :"
for cfg in "${CONFIGS[@]}"; do
  source "$cfg"
  echo "    $RESEAU_NOM → $LOG_DIR"
done
echo ""
echo "  Règles rsyslog : /etc/rsyslog.d/10-wifi-*.conf"
echo "  Backup config  : /etc/rsyslog.conf.backup_*"
echo ""
echo "  Prochaine étape :"
echo "  Configurer le forwarding syslog sur les bornes WiFi"
echo "  et/ou sur Sophos vers $(source "${CONFIGS[0]}" && echo "$SYSLOG_IP"):514"
echo "============================================================"
echo ""
echo "  Tests à valider (voir checklist en en-tête du script) :"
echo "  ss -tlnp | grep 514   →  rsyslog doit écouter sur 0.0.0.0:514"
echo "  ss -ulnp | grep 514   →  idem en UDP"
echo "============================================================"
