# HostBuster-Auto-Proxy - Documentation

## Vue d'ensemble
**HostBuster-Auto-Proxy** est un script Bash exécuté en service sur le serveur **SvISP**. Il interroge l'API Proxmox VE pour découvrir automatiquement les conteneurs LXC portant les tags `bridge-clients` et `proxy`, puis génère dynamiquement une configuration **Caddy** pour les exposer en reverse proxy.

- Création automatique des blocs reverse proxy pour chaque conteneur éligible
- Rechargement automatique de Caddy lors de chaque changement détecté
- Détection et résolution des domaines en doublon
- Fonctionnement continu (boucle) avec vérification toutes les 30 secondes

## Prérequis
- Serveur **SvISP** avec accès réseau vers l'API Proxmox VE (port 8006)
- Dépendances : `curl`, `jq`, `caddy`
- Un **token d'API Proxmox** avec la permission `PVEAuditor` sur le path `/vms`
- Un service **Caddy** opérationnel sur le serveur

## Structure des fichiers
```
hostbuster_auto_proxy/
├── hostbuster_auto_proxy.sh        # Script principal
├── hostbuster_auto_proxy.env       # Configuration (token, nœud)
└── hostbuster_auto_proxy.service   # Unité systemd
```

## Installation
1. Installer les dépendances :
   ```bash
   apt update && apt install -y curl jq caddy
   ```
2. Créer un **token d'API** sur le Proxmox VE (Datacenter → Permissions → API Tokens)
3. Attribuer au token la permission sur le path `/vms` avec le rôle **`PVEAuditor`**
4. Déposer le `.env` dans `/usr/local/sbin/hostbuster_auto_proxy.env` et le compléter
5. Déposer le script dans `/usr/local/sbin/hostbuster_auto_proxy.sh`
6. Rendre le script exécutable :
   ```bash
   chmod +x /usr/local/sbin/hostbuster_auto_proxy.sh
   ```
7. Déposer le service dans `/etc/systemd/system/hostbuster_auto_proxy.service`
8. Recharger le démon systemd :
   ```bash
   systemctl daemon-reload
   ```
9. Activer et démarrer le service :
   ```bash
   systemctl enable --now hostbuster_auto_proxy
   ```
10. Vérifier le statut du service :
    ```bash
    systemctl status hostbuster_auto_proxy
    ```
11. Suivre les logs :
    ```bash
    journalctl -u hostbuster_auto_proxy -f
    ```

> **Attention :** N'oubliez pas d'ajouter une règle de **firewall nftables** pour autoriser le port **443** sur votre serveur :
> ```
> tcp dport 443 counter log prefix "AUTO-PROXY: " accept
> ```

## Configuration du `.env`
| Variable | Description |
|----------|-------------|
| `TOKEN_ID` | ID du token d'API Proxmox (ex: `user@pam!token`) |
| `PVE_TOKEN_SECRET` | Secret (UUID) du token d'API Proxmox |
| `NODE` | Nom du nœud Proxmox à interroger (ex: `pve1`) |
| `NODE_IP` | Adresse IP du nœud Proxmox (API sur le port 8006) |

## Fonctionnement détaillé du script

### Étape 1 - Chargement de la configuration
Le script charge les variables du fichier `.env` via `source`. En cas d'échec, il affiche une erreur et quitte.

### Étape 2 - Vérification des dépendances
Il vérifie la présence de `curl`, `jq` et `caddy`. Toute commande manquante provoque l'arrêt du script.

### Étape 3 - Boucle principale (toutes les 30 secondes)
Le script fonctionne en continu. À chaque cycle :

#### Découverte des conteneurs LXC
Il interroge l'API `nodes/{NODE}/lxc`. En cas d'échec, il réessaie jusqu'à 3 fois (10 secondes d'intervalle). Après 30 secondes d'échec cumulées, le script quitte.

#### Filtrage par tags
Pour chaque conteneur (`vmid`, trié numériquement), le script récupère sa configuration et vérifie les tags :
- Tag **`bridge-clients`** présent → sinon le conteneur est ignoré
- Tag **`proxy`** présent → sinon le conteneur est ignoré

#### Récupération de l'adresse IPv4
Le script interroge les interfaces du conteneur et extrait la première adresse IPv4 valide (hors interface `lo`). Si aucune IPv4 n'est trouvée, le conteneur est ignoré.

#### Construction du domaine
Le domaine est construit à partir du hostname du conteneur :
```
{hostname}.carabuster.filiere.info
```
Le hostname est converti en minuscules et les caractères non valides sont remplacés par `-`.

#### Gestion des doublons
Si deux conteneurs génèrent le même domaine, le script conserve le conteneur avec le **plus petit ID** et ignore l'autre.

#### Création du bloc Caddy
Pour chaque conteneur valide, un bloc reverse proxy est généré :
```
{domaine} {
    reverse_proxy {ipv4}:80
}
```

### Étape 4 - Écriture du fichier de configuration
- Si aucun conteneur éligible n'est trouvé, un avertissement est affiché
- Sinon, les blocs sont écrits dans un fichier temporaire

### Étape 5 - Détection des changements
Le fichier généré est comparé au fichier existant `/etc/caddy/hostbuster_auto_proxy.caddy`. Si aucune différence, le cycle s'arrête (pas de rechargement inutile).

### Étape 6 - Mise à jour de la configuration
- Le fichier temporaire est installé en `/etc/caddy/hostbuster_auto_proxy.caddy`
- Si le `Caddyfile` principal n'existe pas, il est créé
- La ligne `import /etc/caddy/hostbuster_auto_proxy.caddy` est ajoutée si absente
- Le `Caddyfile` principal est formaté (`caddy fmt`)

### Étape 7 - Validation
La configuration est validée avec :
```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```
Si la configuration est invalide, le script quitte sans appliquer les changements.

### Étape 8 - Rechargement
Le service Caddy est rechargé avec `systemctl reload caddy`. Le nouveau fichier est alors actif.

## Fichiers générés

| Fichier | Description |
|---------|-------------|
| `/etc/caddy/hostbuster_auto_proxy.caddy` | Configuration Caddy générée (importée par le Caddyfile) |
| `/etc/caddy/Caddyfile` | Caddyfile principal contenant l'import |

## Sécurité
| Mesure | Détail |
|--------|--------|
| **Token API** | Permission restreinte `PVEAuditor` sur `/vms` (lecture seule) |
| **HTTPS** | Caddy gère les certificats TLS pour chaque domaine |
| **Firewall** | Port 443 ouvert via règle nftables dédiée |
| **Fichiers** | Le `.env` contient les secrets ; à protéger (lecture root uniquement) |

## Commandes utiles
| Commande | Description |
|----------|-------------|
| `systemctl restart hostbuster_auto_proxy` | Redémarrer le service |
| `journalctl -u hostbuster_auto_proxy -f` | Suivre les logs en direct |
| `cat /etc/caddy/hostbuster_auto_proxy.caddy` | Voir la configuration Caddy générée |
| `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` | Valider manuellement la configuration |

## Notes techniques
- **Boucle infinie** : le service tourne en continu, les vérifications ont lieu toutes les 30 secondes
- **Passage à l'échelle** : l'ajout d'un nouveau conteneur éligible est détecté automatiquement
- **Domaine** : `{hostname}.carabuster.filiere.info`
- **Comparaison** : le fichier n'est réécrit et Caddy rechargé que si un changement réel est détecté