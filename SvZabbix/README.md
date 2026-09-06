# Zabbix-Ping-Items - Documentation

## Vue d'ensemble
**Zabbix-Ping-Items** est un script Bash exécuté sur le serveur **SvZabbix**. Il crée en masse des **items de monitoring** dans Zabbix afin de *pinger* l'ensemble des adresses IP des conteneurs clients sur le réseau `192.168.0.0/24`.

- Création de **254 items** de type « agent simple » (Simple Check - ICMP ping)
- Une IP surveillée par item, de `192.168.0.1` à `192.168.0.254`
- Authentification via **token API Zabbix** (Bearer)
- Attribution possible d'un *value mapping* « STATUS » (0 = DOWN, 1 = OK)

## Prérequis
- Serveur **SvZabbix** avec accès réseau vers l'API Zabbix
- Dépendance : `curl`
- Un **token API Zabbix** (généré dans l'interface : Users → votre utilisateur → API tokens)
- L'**ID du template** de destination (créé au préalable dans Zabbix)

## Structure des fichiers
```
zabbix_ping_items.sh        # Script principal
zabbix_ping_items.env       # Configuration (URL, token, template)
```

## Installation
1. Installer la dépendance :
   ```bash
   apt update && apt install -y curl
   ```
2. Créer un **token API** sur Zabbix (Utilisateurs → API tokens)
3. Déposer le `.env` dans `/usr/local/sbin/zabbix_ping_items.env` et le compléter
4. Pour obtenir l'**ID du template** : ouvrez le template dans Zabbix et récupérez l'ID dans **l'URL**
5. Déposer le script dans `/usr/local/sbin/zabbix_ping_items.sh`
6. Rendre le script exécutable :
   ```bash
   chmod +x /usr/local/sbin/zabbix_ping_items.sh
   ```
7. Exécuter le script :
   ```bash
   source /usr/local/sbin/zabbix_ping_items.env && /usr/local/sbin/zabbix_ping_items.sh
   ```
8. Vérifier dans Zabbix que les items ont été créés
9. Sélectionner les items auxquels attribuer le *value mapping* **« STATUS »** (0 = DOWN, 1 = OK)
10. Appliquer le *value mapping* aux items sélectionnés

## Configuration du `.env`
| Variable | Description |
|----------|-------------|
| `ZABBIX_URL` | Adresse de l'API Zabbix (ex: `http://192.168.255.3/api_jsonrpc.php`) |
| `TOKEN` | Token d'authentification API Zabbix |
| `TEMPLATE_ID` | ID du template Zabbix dans lequel créer les items |

## Fonctionnement détaillé du script

### Étape 1 - Boucle sur les 254 adresses IP
Le script parcourt la plage de `1` à `254`, c'est-à-dire toutes les adresses `192.168.0.0/24` (hors `.0` réseau et `.255` broadcast).

### Étape 2 - Construction de la requête JSON-RPC
Pour chaque IP, une requête **Zabbix API** (`item.create`) est construite :
| Paramètre | Valeur |
|-----------|--------|
| `jsonrpc` | `2.0` |
| `method` | `item.create` |
| `name` | `{ip}` (ex: `192.168.0.10`) |
| `key_` | `ping[{ip}]` (ex: `ping[192.168.0.10]`) |
| `hostid` | `$TEMPLATE_ID` |
| `type` | `3` (Simple Check) |
| `value_type` | `3` (Unsigned / entier) |
| `delay` | `1m` (vérification toutes les minutes) |
| `history` | `31d` (conservation 31 jours) |
| `trends` | `365d` (tendances 1 an) |

> Le `id` de la requête est incrémenté à chaque itération pour respecter le protocole JSON-RPC.

### Étape 3 - Envoi à l'API Zabbix
La requête est envoyée via `curl` avec le header :
```
Authorization: Bearer $TOKEN
```

### Étape 4 - Analyse du résultat
- Si la réponse contient `error`, le script affiche **« IP x : Déjà existant ou Erreur »** et le détail de la réponse
- Sinon, il affiche **« IP x : Créé avec succès »**

### Étape 5 - Fin
Le script affiche **« Opération terminée ! »** une fois les 254 items traités.

## Sécurité
| Mesure | Détail |
|--------|--------|
| **Token API** | Authentification par token Bearer (pas de mot de passe en clair dans le script) |
| **Value mapping** | 0 = DOWN (hôte injoignable) / 1 = OK (hôte joignable) |
| **Fichiers** | Le `.env` contient le token ; à protéger (lecture root uniquement) |

## Commandes utiles
| Commande | Description |
|----------|-------------|
| `source /usr/local/sbin/zabbix_ping_items.env && /usr/local/sbin/zabbix_ping_items.sh` | (Ré)exécuter le script |
| `curl -s -H "Authorization: Bearer $TOKEN" "$ZABBIX_URL"` | Tester manuellement l'API Zabbix |

## Notes techniques
- **Simple Check (ICMP)** : le type `3` utilise le module *Simple Checks* de Zabbix (ICMP ping)
- **Value type** : les items sont de type entier afin de supporter le value mapping binaire DOWN/OK
- **Idempotent** : si un item existe déjà, il est signalé comme « Déjà existant » (pas d'écrasement)
- **Plage surveillée** : l'intégralité du réseau clients `192.168.0.0/24` est couverte