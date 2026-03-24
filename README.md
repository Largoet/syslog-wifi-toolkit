# syslog-toolkit

> Suite d'outils Bash pour la centralisation et l'exploitation des logs syslog — collecte, supervision et export légal (LCEN)

---

## Contexte

Ce projet met en place une infrastructure de centralisation des journaux syslog issus d'équipements réseau WiFi (bornes d'accès) et/ou de pare-feu (Sophos).

Il supporte la gestion de **plusieurs réseaux distincts** en parallèle — typiquement un réseau WiFi public (visiteurs) et un réseau WiFi interne (agents/employés) — avec des configurations, des dossiers de logs et des rapports séparés pour chaque réseau.

Conçu pour être déployé sur n'importe quelle infrastructure Linux.

---

## Prérequis

- Serveur Linux (Debian 12 ou Ubuntu Server 24.04)
- rsyslog installé et configuré en mode récepteur
- Droits sudo sur le serveur
- Bash 5+

---

## Installation

### 1. Cloner le dépôt

```bash
git clone https://github.com/TON_USERNAME/syslog-toolkit.git
cd syslog-toolkit
```

### 2. Créer les fichiers de configuration

```bash
# Pour le réseau public
cp config/config.example.sh config/config.public.sh
nano config/config.public.sh

# Pour le réseau interne
cp config/config.example.sh config/config.interne.sh
nano config/config.interne.sh
```

### 3. Rendre les scripts exécutables

```bash
chmod +x scripts/*.sh
```

### 4. Installer le serveur syslog

```bash
# Un réseau
sudo ./scripts/install.sh --reseau public

# L'autre réseau
sudo ./scripts/install.sh --reseau interne

# Les deux en une commande
sudo ./scripts/install.sh --reseau all
```

---

## Configuration

Toutes les variables sont centralisées dans des fichiers de configuration par réseau.  
Ne jamais commiter ces fichiers — ils sont dans le `.gitignore`.

Voir [`config/config.example.sh`](config/config.example.sh) pour la liste complète des variables.

| Fichier | Réseau |
|---|---|
| `config/config.public.sh` | WiFi public (visiteurs) |
| `config/config.interne.sh` | WiFi interne (agents) |

---

## Scripts disponibles

Chaque script accepte un paramètre `--reseau [public|interne]` qui détermine sur quel réseau il opère.

| Script | Description |
|---|---|
| `install.sh` | Installation et configuration du serveur rsyslog |
| `check_health.sh` | Supervision des bornes (ping + heartbeat) |
| `search.sh` | Recherche dans les logs par IP, MAC ou date |
| `export_legal.sh` | Export certifié pour réquisition judiciaire (LCEN) |
| `anomaly_report.sh` | Rapport quotidien d'anomalies comportementales |

---

## Détail des scripts

### `install.sh`

Déploie et configure le serveur syslog. Idempotent — peut être relancé sans risque.

```bash
sudo ./scripts/install.sh --reseau public
sudo ./scripts/install.sh --reseau interne
sudo ./scripts/install.sh --reseau all
```

---

### `check_health.sh`

Vérifie que chaque borne est joignable et envoie ses logs, sans dépendre de l'activité utilisateur.

| Niveau | Mécanisme | Fréquence recommandée |
|---|---|---|
| 1 | Ping ICMP | Toutes les 5 minutes |
| 2 | Heartbeat syslog | Toutes les 6 heures |

```bash
./scripts/check_health.sh --reseau public
./scripts/check_health.sh --reseau interne --mode ping
./scripts/check_health.sh --reseau public --mode heartbeat
```

Planification via cron :

```bash
*/5 * * * * /chemin/scripts/check_health.sh --reseau public --mode ping
*/5 * * * * /chemin/scripts/check_health.sh --reseau interne --mode ping
0 */6 * * * /chemin/scripts/check_health.sh --reseau public --mode heartbeat
0 */6 * * * /chemin/scripts/check_health.sh --reseau interne --mode heartbeat
```

---

### `search.sh`

Recherche dans les logs archivés par IP, MAC ou date.

```bash
./scripts/search.sh --reseau public --ip 192.168.10.45
./scripts/search.sh --reseau interne --mac AA:BB:CC:DD:EE:FF
./scripts/search.sh --reseau public --date 2026-03-15
./scripts/search.sh --reseau interne --ip 192.168.20.10 --date 2026-03-15 --export
```

---

### `export_legal.sh`

Génère un export certifié pour une période donnée.  
Produit une archive compressée + un checksum SHA256 (preuve d'intégrité des logs).

```bash
./scripts/export_legal.sh --reseau public --debut 2026-01-01 --fin 2026-01-31
./scripts/export_legal.sh --reseau interne --debut 2026-01-01 --fin 2026-01-31
```

---

### `anomaly_report.sh`

Analyse les logs de la veille et génère un rapport quotidien d'anomalies comportementales.

```bash
./scripts/anomaly_report.sh --reseau public
./scripts/anomaly_report.sh --reseau interne
```

Planification automatique :

```bash
0 2 * * * /chemin/scripts/anomaly_report.sh --reseau public
0 2 * * * /chemin/scripts/anomaly_report.sh --reseau interne
```

> **Périmètre** : ce script analyse des métadonnées de connexion (MAC, IP, horodatage). Il ne voit pas le contenu des échanges réseau.

---

## Organisation des logs

```
/var/log/wifi-public/           ← logs bornes WiFi public
/var/log/wifi-interne/          ← logs bornes WiFi interne
/var/log/sophos/                ← logs pare-feu Sophos (si source active)
/var/log/rapports/public/       ← rapports d'anomalies WiFi public
/var/log/rapports/interne/      ← rapports d'anomalies WiFi interne
/var/log/exports/public/        ← exports légaux WiFi public
/var/log/exports/interne/       ← exports légaux WiFi interne
/var/log/syslog-alerts-public.log
/var/log/syslog-alerts-interne.log
```

---

## Structure du dépôt

```
syslog-toolkit/
├── README.md
├── .gitignore
├── config/
│   ├── config.example.sh       ← template à copier
│   ├── config.public.sh        ← config réseau public (non versionné)
│   └── config.interne.sh       ← config réseau interne (non versionné)
└── scripts/
    ├── install.sh
    ├── check_health.sh
    ├── search.sh
    ├── export_legal.sh
    └── anomaly_report.sh
```

---

## Conformité légale

- **Loi LCEN** (art. 6-II) — conservation des logs de connexion pendant **1 an** (WiFi public)
- **Décret n°2011-219** — données à conserver : IP, MAC, horodatage
- **RGPD** — les logs contiennent des données personnelles — accès restreint aux personnes habilitées

---

## Auteur

Thibaut — Stagiaire DevOps — 2026
