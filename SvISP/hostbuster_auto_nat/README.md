# HostBuster-Auto-NAT - Documentation

## Vue d'ensemble
**HostBuster-Auto-NAT** est un script Bash exécuté en service sur le serveur **SvISP**. Il interroge l'API Proxmox VE pour découvrir automatiquement les conteneurs LXC Minecraft en cours d'exécution portant les tags `bridge-clients` et `minecraft`, puis génère dynamiquement une configuration **rinetd** pour exposer chaque serveur Minecraft sur un port public.

- Attribution automatique d'un port public dérivé de l'ID du conteneur
- Redirection vers le port Minecraft interne (25565) de chaque conteneur
- Rechargement automatique de rinetd lors de chaque changement détecté
- Prise en charge du port IPv6 (bind `::`)

## Prérequis
- Serveur **SvISP** avec accès réseau vers l'API Proxmox VE (port 8006)
- Dépendances : `curl`, `jq`, `rinetd`
- Un **token d'API Proxmox** avec la permission `PVEAuditor` sur le path `/vms`
- Un service **rinetd** opérationnel sur le serveur

## Structure des fichiers
```
hostbuster_auto_nat/
├── hostbuster_auto_nat.sh        # Script principal
├── hostbuster_auto_nat.env       # Configuration (token, nœud, plage de ports)
└── hostbuster_auto_nat.service   # Unité systemd
```

## Installation
1. Installer les dépendances :
   ```bash
   apt update && apt install -y curl jq rinetd
   ```
2. Créer un **token d'API** sur le Proxmox VE (Datacenter → Permissions → API Tokens)
3. Attribuer au token la permission sur le path `/vms` avec le rôle **`PVEAuditor`**
4. Déposer le `.env` dans `/usr/local/sbin/hostbuster_auto_nat.env` et le compléter
5. Déposer le script dans `/usr/local/sbin/hostbuster_auto_nat.sh`
6. Rendre le script exécutable :
   ```bash
   chmod +x /usr/local/sbin/hostbuster_auto_nat.sh
   ```
7. Déposer le service dans `/etc/systemd/system/hostbuster_auto_nat.service`
8. Recharger le démon systemd :
   ```bash
   systemctl daemon-reload
   ```
9. Activer et démarrer le service :
   ```bash
   systemctl enable --now hostbuster_auto_nat
   ```
10. Vérifier le statut du service :
    ```bash
    systemctl status hostbuster_auto_nat
    ```
11. Suivre les logs :
    ```bash
    journalctl -u hostbuster_auto_nat -f
    ```

> **Attention :** N'oubliez pas d'ajouter une règle de **firewall nftables** pour autoriser les ports que vous souhaitez utiliser pour l'auto-NAT. Dans notre cas, la plage **25000-26000** est utilisée :
> ```
> tcp dport 25000-26000 counter log prefix "AUTO-NAT: " accept
> ```

## Configuration du `.env`
| Variable | Description |
|----------|-------------|
| `TOKEN_ID` | ID du token d'API Proxmox (ex: `user@pam!token`) |
| `PVE_TOKEN_SECRET` | Secret (UUID) du token d'API Proxmox |
| `NODE` | Nom du nœud Proxmox à interroger (ex: `pve1`) |
| `NODE_IP` | Adresse IP du nœud Proxmox (API sur le port 8006) |
| `PORT_START` | Port public de départ (par défaut : 26000) |
| `PORT_END` | Port public de fin (par défaut : 65535) |

> Les valeurs par défaut s'appliquent si `PORT_START`/`PORT_END` sont vides dans le `.env`. Le port 25565 (Minecraft) est fixé par la variable interne `MINECRAFT_PORT` (par défaut : 25565).

## Correspondance ID → Port public
Le port public est calculé à partir de l'ID du conteneur :
```
port_public = PORT_START + vmid
```
| VMID | Port public (avec PORT_START=25000) |
|------|-------------------------------------|
| 200 | 25200 |
| 300 | 25300 |
| 1000 | 26000 |

## Fonctionnement détaillé du script

### Étape 1 - Chargement de la configuration
Le script charge les variables du fichier `.env` via `source`. Il applique les valeurs par défaut si nécessaires (`PORT_START=26000`, `PORT_END=65535`, `MINECRAFT_PORT=25565`).

### Étape 2 - Validation de la plage de ports
- Si `PORT_END < PORT_START`, le script quitte avec une erreur
- Si `PORT_END > 65535`, le script quitte avec une erreur

### Étape 3 - Vérification des dépendances
Il vérifie la présence de `curl`, `jq` et `rinetd`. Toute commande manquante provoque l'arrêt du script.

### Étape 4 - Boucle principale (toutes les 30 secondes)
Le script fonctionne en continu. À chaque cycle :

#### Découverte des conteneurs LXC
Il interroge l'API `nodes/{NODE}/lxc`. En cas d'échec, il réessaie jusqu'à 3 fois (10 secondes d'intervalle), puis attend 30 secondes avant de reprendre.

#### Filtrage par tags
Pour chaque conteneur (`vmid`, trié numériquement) :
- Tag **`bridge-clients`** présent → sinon le conteneur est ignoré
- Tag **`minecraft`** présent → sinon le conteneur est ignoré

#### Vérification du statut
Le conteneur doit être **`running`** pour être inclus. Sinon il est ignoré (avertissement).

#### Récupération de l'adresse IPv4
Le script extrait la première adresse IPv4 valide des interfaces du conteneur. Si aucune IPv4 n'est trouvée, le conteneur est ignoré.

#### Calcul et validation du port public
Le port public est calculé (`PORT_START + vmid`) puis vérifié :
- S'il dépasse `PORT_END`, le conteneur est ignoré avec un avertissement

#### Construction de la règle rinetd
Une règle de redirection est ajoutée :
```
:: {port_public} {ipv4} {minecraft_port}
```
Exemple :
```
:: 25300 192.168.0.200 25565
```

#### Détection des changements
Une "empreinte" de l'état actuel est construite et comparée à l'état précédent. Si aucun changement, le cycle s'arrête (pas de reconstruction inutile).

### Étape 5 - Mise à jour de la configuration rinetd
- Le fichier généré est copié dans `/etc/rinetd.conf`
- La configuration est validée avec `rinetd -c /etc/rinetd.conf`
- Le service est rechargé avec `systemctl reload rinetd`
- En cas d'échec, l'ancienne configuration est conservée et le cycle reprend

## Fichiers générés
| Fichier | Description |
|---------|-------------|
| `/etc/rinetd.conf` | Configuration rinetd (redirections de ports) |

## Sécurité
| Mesure | Détail |
|--------|--------|
| **Token API** | Permission restreinte `PVEAuditor` sur `/vms` (lecture seule) |
| **Firewall** | Plage de ports ouverte via règle nftables dédiée |
| **Validation** | Configuration rinetd validée avant rechargement |

## Commandes utiles
| Commande | Description |
|----------|-------------|
| `systemctl restart hostbuster_auto_nat` | Redémarrer le service |
| `journalctl -u hostbuster_auto_nat -f` | Suivre les logs en direct |
| `cat /etc/rinetd.conf` | Voir les redirections actives |
| `rinetd -c /etc/rinetd.conf` | Valider manuellement la configuration |
| `ss -tlnp \| grep rinetd` | Vérifier les ports en écoute |

## Notes techniques
- **Boucle infinie** : le service tourne en continu, les vérifications ont lieu toutes les 30 secondes
- **Minecraft uniquement** : seuls les conteneurs avec les tags `bridge-clients` + `minecraft` sont pris en compte
- **Port dérivé de l'ID** : chaque conteneur a un port public unique et stable tant que son ID ne change pas
- **IPv6** : le script bind les règles sur `::` (toutes les adresses), y compris IPv4 mappée