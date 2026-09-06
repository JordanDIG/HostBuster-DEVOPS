# HostBuster-Proxmox - Documentation

## Vue d'ensemble
**HostBuster** est un script Bash automatisant la création et la configuration de conteneurs LXC sur un serveur Proxmox. Il prend en charge deux modes de fonctionnement :

1. **Mode template** - Création de conteneurs prêts à l'emploi (GLPI, Minecraft, Odoo, WordPress)
2. **Mode production** - Création de conteneurs serveurs internes (SvISP, SvZabbix, SvWeb, SvBackend)

## Prérequis
- Serveur **Proxmox VE** avec les commandes `pct`, `pveam`, `apt` disponibles
- Bridge réseau : `vmbr0` (public/DHCP), `vmbr10` (réseau interne 192.168.255.0/24), `vmbr11` (clients 192.168.0.0/24), `vmbr12` (DMZ 10.0.0.0/29)
- Pool de ressources Proxmox : `CLIENTS` (templates) et `PRODUCTION` (serveurs)
- Accès réseau pour télécharger les paquets et templates

## Structure des fichiers
```
HostBuster-Proxmox-production/
├── create_lxc.sh              # Script principal
└── templates/
    ├── GLPI.sh                # Installation GLPI (GLPI + MariaDB + NGINX)
    ├── MINECRAFT.sh           # Installation serveur Minecraft
    ├── ODOO.sh                # Installation Odoo (Odoo + PostgreSQL + NGINX)
    └── WORDPRESS.sh           # Installation WordPress (WordPress + MariaDB + NGINX)
```

## Exécution
```bash
bash /usr/local/sbin/create_lxc.sh
```

Le script doit être exécuté **en tant que root** sur l'hôte Proxmox.

## Fonctionnement détaillé du script principal (`create_lxc.sh`)

### Étape 1 - Mise à jour et téléchargement du template Debian 13
Le script interroge le gestionnaire de templates Proxmox (`pveam`) pour récupérer automatiquement la dernière version disponible de Debian 13 (`debian-13-standard_*_amd64.tar.zst`). Si le template n'est pas déjà présent localement, il le télécharge.

### Étape 2 - Saisie du VMID
L'utilisateur doit fournir un **ID de conteneur (VMID)** respectant les règles suivantes :

| Règle | Détail |
|-------|--------|
| Format | Nombre entier uniquement |
| Plage | 100 à 999 999 |
| Interdit | Commencer par un zéro (ex: 001) |
| Unicité | Le VMID ne doit pas déjà exister |

### Étape 3 - Mode template ou conteneur standard
Le script demande si le conteneur est un **template** (o/n) :

#### Mode template
L'utilisateur choisit parmi 4 applications :

| Choix | Application | RAM | Swap | Tags | Pool |
|-------|------------|-----|------|------|------|
| 1 | GLPI | 512 MB | 0 | `glpi-essentiel`, `bridge-clients`, `proxy` | CLIENTS |
| 2 | Minecraft | 1024 MB | 0 | `minecraft-essentiel`, `bridge-clients` | CLIENTS |
| 3 | Odoo | 512 MB | 256 MB | `odoo-essentiel`, `bridge-clients`, `proxy` | CLIENTS |
| 4 | WordPress | 512 MB | 0 | `wordpress-essentiel`, `bridge-clients`, `proxy` | CLIENTS |

- **Hostname** généré automatiquement : `DEB13-{APP}-{DATE}` (ex: `DEB13-GLPI-06-09-2026`)
- **Réseau** : interface `eth0` sur `vmbr11` avec IP automatique (plage 192.168.0.2 - 192.168.0.254), passerelle `192.168.0.1`

#### Mode production
L'utilisateur choisit parmi 4 serveurs internes :
| Choix | Hostname | Réseau | IP(s) | Pool |
|-------|----------|--------|-------|------|
| 1 | SvISP | vmbr0 (DHCP) + vmbr10 + vmbr11 + vmbr12 | 192.168.255.1 / 192.168.0.1 / 10.0.0.3 | PRODUCTION |
| 2 | SvZabbix | vmbr10 | 192.168.255.3 | PRODUCTION |
| 3 | SvWeb | vmbr10 | 192.168.255.4 | PRODUCTION |
| 4 | SvBackend | vmbr10 | 192.168.255.5 | PRODUCTION |

### Étape 4 - Attribution automatique d'IP (mode template)
Le script scanne tous les fichiers de configuration LXC existants (`/etc/pve/lxc/*.conf`) pour détecter les IP déjà utilisées dans la plage `192.168.0.0/24`. L'IP réservée `192.168.0.1` (SvISP) est exclue. La première IP libre disponible (de `.2` à `.254`) est attribuée.

### Étape 5 - Création du conteneur LXC
Paramètres communs à tous les conteneurs :
| Paramètre | Valeur |
|-----------|--------|
| Système | Debian 13 (dernier template) |
| CPU | 1 cœur |
| Disque | 10 GB (`local-lvm`) |
| MTU | 1370 |
| Unprivileged (exécution de commandes en tant que non-root) | Oui |
| Nesting (permet de créer des conteneurs dans des conteneurs) | Activé |
| Onboot (démarrage automatique au démarrage du système) | Activé |

### Étape 6 - Démarrage et vérification
Le conteneur est démarré et le script attend que le statut soit `running`.

### Étape 7 - Configuration réseau (MTU)
Pour tous les conteneurs, le script ajoute `mtu 1370` dans `/etc/network/interfaces` sur les interfaces concernées et redémarre le service réseau.
- **SvISP** : MTU ajoutée sur `eth1`, `eth2`, `eth3`
- **Autres** : MTU ajoutée sur `eth0`

### Étape 8 - Configuration système
| Étape | Action |
|-------|--------|
| Timezone | `Europe/Paris` |
| Locales | `fr_FR.UTF-8` (principal) + `en_US.UTF-8` |
| Mise à jour | `apt full-upgrade -y && apt autoremove -y` |
| SSH | Désinstallé (`openssh-server` supprimé) |
| Monitoring | `htop` installé |

### Étape 9 - Installation Zabbix Agent 2
> **Sauf** pour le conteneur SvZabbix et les templates.

- Dépôt Zabbix 7.4 pour Debian 13
- Installation de `zabbix-agent2`
- Génération d'une clé PSK unique (64 caractères hexadécimaux)
- Configuration : serveur Zabbix = `192.168.255.3`, authentification PSK
- La clé PSK est affichée dans les logs pour chaque conteneur

### Étape 10 - Installation de l'application (templates uniquement)
Le script détecte et exécute le script correspondant depuis le dossier `templates/` :
| Variable | Script exécuté |
|----------|---------------|
| `APP=GLPI` | `templates/GLPI.sh` |
| `APP=MINECRAFT` | `templates/MINECRAFT.sh` |
| `APP=ODOO` | `templates/ODOO.sh` |
| `APP=WORDPRESS` | `templates/WORDPRESS.sh` |

### Étape 11 - Conversion en template (templates uniquement)
Le conteneur est arrêté puis converti en **template Proxmox** via `pct template`.

## Détails des scripts d'installation

### GLPI (`templates/GLPI.sh`)
**Services installés** : NGINX, MariaDB, PHP-FPM, nftables

| Composant | Détail |
|-----------|--------|
| Base de données | MariaDB - Base `glpi`, utilisateur `glpi_adm` |
| App web | GLPI (dernière version GitHub) |
| Web server | NGINX (reverse proxy PHP-FPM) |
| Sécurité | nftables (INPUT: HTTP depuis SvISP, ICMP depuis SvZabbix) |
| Sessions PHP | `cookie_httponly = On`, `cookie_samesite = Lax` |
| Domaine | `{hostname}.carabuster.filiere.info` |

**Firstboot** : À la première extraction du template, le script `hostbuster-firstboot-glpi.sh` régénère les mots de passe MySQL, met à jour la config GLPI, puis se désactive automatiquement.
**Installation finale** : L'utilisateur doit finaliser l'installation via l'interface web dans un délai de 3 minutes (mot de passe root MySQL et glpi_adm affichés à l'écran).

### Minecraft (`templates/MINECRAFT.sh`)
**Services installés** : nftables, systemd (`hostbuster-minecraft.service`)
| Composant | Détail |
|-----------|--------|
| Serveur | Dernière version stable (via API Mojang) |
| Java | Version détectée automatiquement selon la version du serveur |
| Utilisateur | `hostbuster-minecraft` (non-login) |
| RCON | Activé, port 25575 |
| RAM | 95% de la RAM du conteneur |
| mcrcon | Client RCON compilé depuis GitHub |

**Ports** :
| Port | Protocole | Usage |
|------|-----------|-------|
| 25565 | TCP | Jeu Minecraft |
| 25575 | TCP | RCON |

**Sécurité** : nftables autorise uniquement le port 25565 depuis SvISP (192.168.0.1) et l'ICMP depuis SvZabbix.
**Firstboot** : Régénère le mot de passe RCON, supprime le monde existant pour une configuration propre, puis active le service Minecraft.

### Odoo (`templates/ODOO.sh`)
**Services installés** : NGINX, PostgreSQL, Odoo, nftables
| Composant | Détail |
|-----------|--------|
| Base de données | PostgreSQL - Utilisateur `odoo` |
| App web | Odoo (dernière version nightly) |
| Web server | NGINX (reverse proxy, ports 8069 + 8072 websocket) |
| Sécurité | nftables (HTTP depuis SvISP, ICMP depuis SvZabbix) |
| Addons custom | `/opt/odoo/custom-addons` |
| Workers | 2 (mode production) |

**Paquet de compatibilité** : `python3-pypdf2` construit via `equivs` pour la compatibilité Debian 13/Odoo.
**Domaine** : `{hostname}.carabuster.filiere.info`
**Firstboot** : Régénère les mots de passe (maître Odoo + PostgreSQL), met à jour `odoo.conf`, redémarre Odoo et NGINX.
**Installation finale** : L'utilisateur doit finaliser via l'interface web (mot de passe maître affiché).

### WordPress (`templates/WORDPRESS.sh`)

**Services installés** : NGINX, MariaDB, PHP-FPM, nftables
| Composant | Détail |
|-----------|--------|
| Base de données | MariaDB - Base `wordpress`, utilisateur `wp_adm` |
| App web | WordPress (dernière version officielle) |
| Web server | NGINX |
| Sécurité | nftables (HTTP depuis SvISP, ICMP depuis SvZabbix) |
| Sessions PHP | `cookie_httponly = On`, `cookie_samesite = Lax` |
| Upload | `upload_max_filesize = 64M`, `post_max_size = 64M` |
| Sécurité wp | Clés SALT générées automatiquement via API WordPress.org |

**Proxy HTTPS** : Configuration `X-Forwarded-Proto` dans `wp-config.php` pour le support HTTPS derrière un reverse proxy.
**Firstboot** : Régénère les mots de passe MySQL, met à jour `wp-config.php`, puis se désactive.

## Sécurité
| Mesure | Détail |
|--------|--------|
| **nftables** | Politique INPUT drop par défaut ; règles par conteneur |
| **SSH désactivé** | Supprimé de tous les conteneurs |
| **Mots de passe** | Générés aléatoirement (30 caractères alphanumériques), stockés dans `/root/passwords` (chmod 600) |
| **Firstboot** | Régénération automatique des mots de passe à la première extraction du template |
| **Unprivileged** | Tous les conteneurs sont non-privlégiés |
| **Nesting** | Activé (nécessaire pour certains services) |

## Commandes utiles sur le PVE
| Commande | Description |
|----------|-------------|
| `pct status <CTID>` | Vérifier le statut d'un conteneur |
| `pct enter <CTID>` | Entrer dans un conteneur |
| `pct exec <CTID> -- <cmd>` | Exécuter une commande dans un conteneur |
| `pct start <CTID>` | Démarrer un conteneur |
| `pct stop <CTID>` | Arrêter un conteneur |
| `pct template <CTID>` | Convertir un conteneur en template |
| `pct clone <CTID> <NEW_ID>` | Cloner un template |
| `pveam available` | Lister les templates disponibles |
| `pveam list local` | Lister les templates téléchargés |

## Notes techniques
- **MTU 1370** : Toutes les interfaces utilisent une MTU réduite, probablement pour accommoder le tunneling/overlay réseau
- **Patronyme** : Les templates sont disponibles dans le pool `CLIENTS`, les serveurs de production dans `PRODUCTION`
- **Domaine** : Les services web utilisent le sous-domaine `{hostname}.carabuster.filiere.info`
- **Timeout firstboot** : GLPI et Odoo laissent 3 minutes pour finaliser l'installation via l'interface web avant de supprimer le fichier d'installation