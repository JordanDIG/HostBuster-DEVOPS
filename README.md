# HostBuster-DEVOPS

## Vue d'ensemble
**HostBuster-DEVOPS** regroupe l'ensemble des scripts Bash et services systemd utilisés pour automatiser l'infrastructure : la création de conteneurs sur **Proxmox**, l'exposition des services clients via **reverse proxy** et **NAT**, ainsi que le **monitoring** avec Zabbix.

## Emplacement d'installation : `/usr/local/sbin`
Tous les scripts de ce dépôt sont conçus pour être déployés dans **`/usr/local/sbin`**.

### Qu'est-ce que `/usr/local/sbin` ?
Sur un système Linux/Debian, le répertoire `/usr/local/sbin` est destiné aux **programmes exécutables réservés à l'administration système (root)** installés localement sur la machine, c'est-à-dire **en dehors de la gestion du gestionnaire de paquets** (`apt`). C'est l'emplacement standard pour les scripts maison et les outils internes.

## Structure du dépôt
```
HostBuster-DEVOPS/
├── Proxmox/                       # Création des conteneurs LXC (serveur Proxmox)
│   ├── create_lxc.sh              # Script principal de création de conteneurs
│   ├── README.md                  # Documentation détaillée
│   └── templates/
│       ├── GLPI.sh                # Template GLPI
│       ├── MINECRAFT.sh           # Template Minecraft
│       ├── ODOO.sh                # Template Odoo
│       └── WORDPRESS.sh           # Template WordPress
├── SvISP/
│   ├── hostbuster_auto_proxy/     # Reverse proxy automatique Caddy (→ /usr/local/sbin)
│   │   ├── hostbuster_auto_proxy.sh
│   │   ├── hostbuster_auto_proxy.env
│   │   ├── hostbuster_auto_proxy.service
│   │   └── README.md
│   └── hostbuster_auto_nat/       # NAT automatique Minecraft via rinetd (→ /usr/local/sbin)
│       ├── hostbuster_auto_nat.sh
│       ├── hostbuster_auto_nat.env
│       ├── hostbuster_auto_nat.service
│       └── README.md
└── SvZabbix/
    └── zabbix_ping_items/         # Création en masse des items de monitoring (→ /usr/local/sbin)
        ├── zabbix_ping_items.sh
        ├── zabbix_ping_items.env
        └── README.md
```