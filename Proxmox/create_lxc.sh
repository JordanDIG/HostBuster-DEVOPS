#!/bin/bash
# Script de création d'un conteneur LXC

echo "[INFO] Mise à jour des templates..."
pveam update

LATEST_DEBIAN13=$(pveam available | \
    grep -Eo 'debian-13-standard_[0-9\.-]+_amd64\.tar\.zst' | \
    sort -V | tail -n1)
if [ -z "$LATEST_DEBIAN13" ]; then
    echo "[ERREUR] Aucun template Debian 13 disponible."
    exit 1
fi

if pveam list local | grep -q "$LATEST_DEBIAN13"; then
    echo "[INFO] Template Debian 13 déjà présent : $LATEST_DEBIAN13"
else
    echo "[INFO] Téléchargement du template Debian 13 : $LATEST_DEBIAN13 ..."
    pveam download local "$LATEST_DEBIAN13"
fi

while true; do
    read -rp "ID du conteneur (>= 100, sans zéro en tête) : " CTID
    if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
        echo "Erreur : le VMID doit être un nombre."
        continue
    fi
    if [[ "$CTID" =~ ^0+[0-9]+$ ]]; then
        echo "Erreur : le VMID ne doit pas commencer par zéro."
        continue
    fi
    if (( CTID < 100 || CTID > 999999 )); then
        echo "Erreur : le VMID doit être compris entre 100 et 999999."
        continue
    fi
    if pct status "$CTID" &>/dev/null; then
        echo "Erreur : un conteneur avec le VMID $CTID existe déjà."
        continue
    fi
    break
done

while true; do
    read -p "Le conteneur est-il un template ? (o/n) : " is_template
    is_template="${is_template,,}"
    if [[ "$is_template" =~ ^(o|oui|y|yes)$ ]]; then
        template_mode=true
        break
    elif [[ "$is_template" =~ ^(n|non|no)$ ]]; then
        template_mode=false
        break
    else
        echo "Réponse invalide."
    fi
done

RESERVED_IPS=("192.168.0.1") # SvISP
declare -A USED_IPS
shopt -s nullglob
for conf in /etc/pve/lxc/*.conf; do
    [ -f "$conf" ] || continue
    while read -r line; do
        [[ "$line" =~ ^net ]] || continue
        for ip_entry in $(echo "$line" | grep -o 'ip=[^,]*'); do
            ip_only=${ip_entry#ip=}
            ip_only=${ip_only%%/*}
            if [[ "$ip_only" == 192.168.0.* ]]; then
                USED_IPS["$ip_only"]=1
            fi
        done
    done < "$conf"
done
echo "[INFO] IP réservées : ${RESERVED_IPS[*]}"

for ip in "${RESERVED_IPS[@]}"; do
    USED_IPS["$ip"]=1
done
echo "[INFO] IP utilisées : ${!USED_IPS[@]}"
    
FREE_IP=""
for i in $(seq 2 254); do
    candidate="192.168.0.$i"
    if [[ -z "${USED_IPS[$candidate]}" ]]; then
        FREE_IP="$candidate"
        break
    fi
done
if [[ -z "$FREE_IP" ]]; then
    echo "Aucune IP libre disponible dans 192.168.0.0/24"
    exit 1
fi
echo "[INFO] IP libre trouvée : $FREE_IP"

DATE=$(date +"%d-%m-%Y")
if $template_mode; then
    while true; do
        echo "Choisissez un template :"
        echo "1) GLPI"
        echo "2) MINECRAFT"
        echo "3) ODOO"
        echo "4) WORDPRESS"
        read -p "Votre choix : " choice
    case "$choice" in
    1)
        APP="GLPI"
        MEMORY=512
        SWAP=0
        TAGS="glpi-essentiel,bridge-clients,proxy"
        ;;
    2)
        APP="MINECRAFT"
        MEMORY=1024
        SWAP=0
        TAGS="minecraft-essentiel,bridge-clients"
        ;;
    3)
        APP="ODOO"
        MEMORY=512
        SWAP=256
        TAGS="odoo-essentiel,bridge-clients,proxy"
        ;;
    4)
        APP="WORDPRESS"
        MEMORY=512
        SWAP=0
        TAGS="wordpress-essentiel,bridge-clients,proxy"
        ;;
    *)
        echo "Choix invalide."
        continue
        ;;
        esac
        HOSTNAME="DEB13-$APP-$DATE"
        break
    done
else
    echo "Création d'un conteneur standard..."
    echo "Choisissez le conteneur à créer :"
    echo "1) SvISP"
    echo "2) SvZabbix"
    echo "3) SvWeb"
    echo "4) SvBackend"
    while true; do
        read -p "Votre choix : " choice
        case "$choice" in
            1)
                HOSTNAME="SvISP"
                IP1="192.168.255.1"
                IP2="192.168.0.1"
                IP3="10.0.0.3"
                break
                ;;
            2)
                HOSTNAME="SvZabbix"
                IP="192.168.255.3"
                break
                ;;
            3)
                HOSTNAME="SvWeb"
                IP="192.168.255.4"
                break
                ;;
            4)
                HOSTNAME="SvBackend"
                IP="192.168.255.5"
                break
                ;;
            *)
                echo "Choix invalide."
                ;;
        esac
    done
fi

if $template_mode; then
    pct create "$CTID" "local:vztmpl/$LATEST_DEBIAN13" --hostname "$HOSTNAME" --cores 1 --memory "$MEMORY" --swap "$SWAP" --net0 name=eth0,bridge=vmbr11,firewall=0,ip=$FREE_IP/24,gw=192.168.0.1,mtu=1370,type=veth --onboot 1 --rootfs local-lvm:10 --unprivileged 1 --features nesting=1 --tags $TAGS --pool CLIENTS
else
    if [ "$choice" = "1" ]; then
        pct create "$CTID" "local:vztmpl/$LATEST_DEBIAN13" --hostname "$HOSTNAME" --cores 1 --memory 512 --swap 0 --net0 name=eth0,bridge=vmbr0,firewall=0,ip=dhcp,ip6=auto,mtu=1370,type=veth --net1 name=eth1,bridge=vmbr10,firewall=0,ip=$IP1/24,mtu=1370,type=veth --net2 name=eth2,bridge=vmbr11,firewall=0,ip=$IP2/24,mtu=1370,type=veth --net3 name=eth3,bridge=vmbr12,firewall=0,ip=$IP3/29,mtu=1370,type=veth --onboot 1 --rootfs local-lvm:10 --unprivileged 1 --features nesting=1 --pool PRODUCTION
    else
        if [ "$choice" = "2" ]; then
            pct create "$CTID" "local:vztmpl/$LATEST_DEBIAN13" --hostname "$HOSTNAME" --cores 1 --memory 1024 --swap 0 --net0 name=eth0,bridge=vmbr10,firewall=0,ip=$IP/24,gw=192.168.255.1,mtu=1370,type=veth --onboot 1 --rootfs local-lvm:10 --unprivileged 1 --features nesting=1 --pool PRODUCTION
        else
            pct create "$CTID" "local:vztmpl/$LATEST_DEBIAN13" --hostname "$HOSTNAME" --cores 1 --memory 512 --swap 0 --net0 name=eth0,bridge=vmbr10,firewall=0,ip=$IP/24,gw=192.168.255.1,mtu=1370,type=veth --onboot 1 --rootfs local-lvm:10 --unprivileged 1 --features nesting=1 --pool PRODUCTION
        fi
    fi
fi
echo "[INFO] Conteneur $CTID créé avec succès."

pct start "$CTID"
echo "[INFO] Conteneur $CTID démarré."

echo "[INFO] Vérification du démarrage du conteneur..."
while true; do
    if ! pct status "$CTID" &>/dev/null; then
        echo "[ERREUR] Le conteneur $CTID n'existe pas."
        exit 1
    fi
    if [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') == "running" ]]; then
        echo "[INFO] Le conteneur est démarré et prêt à être utilisé."
        break
    fi
    sleep 1
done

echo "[INFO] Attente de 10 secondes pour que le conteneur soit complètement opérationnel..."
sleep 10

if [ "$HOSTNAME" = "SvISP" ]; then
    pct exec "$CTID" -- bash -c "
    sed -i '/iface eth1 inet static/a\        mtu 1370' /etc/network/interfaces
    sed -i '/iface eth2 inet static/a\        mtu 1370' /etc/network/interfaces
    sed -i '/iface eth3 inet static/a\        mtu 1370' /etc/network/interfaces
    systemctl restart networking"
    echo "[INFO] MTU ajoutée sur eth1, eth2 et eth3 pour SvISP."
else
    pct exec "$CTID" -- bash -c "
    sed -i '/iface eth0 inet /a\        mtu 1370' /etc/network/interfaces
    systemctl restart networking"
    echo "[INFO] MTU ajoutée sur eth0."
fi

pct exec "$CTID" -- bash -c "
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
echo 'Europe/Paris' > /etc/timezone"
echo "[INFO] Timezone configurée en Europe/Paris."

pct exec "$CTID" -- bash -c "
export DEBIAN_FRONTEND=noninteractive
export LANG=C
export LC_ALL=C
apt update
apt install -y locales
sed -i 's/^# *fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=fr_FR.UTF-8
export LANG=fr_FR.UTF-8
export LC_ALL=fr_FR.UTF-8
apt full-upgrade -y && apt autoremove -y"

pct exec "$CTID" -- bash -c "
apt remove -y openssh-server"
echo "[INFO] openssh-server (SSH) désinstallé."

pct exec "$CTID" -- bash -c "
apt install htop"
echo "[INFO] htop installé."

if ! $template_mode && [ "$HOSTNAME" != "SvZabbix" ]; then
    pct exec "$CTID" -- bash -c "
    wget -q https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian13_all.deb && dpkg -i zabbix-release_latest_7.4+debian13_all.deb
    rm -f zabbix-release_latest_7.4+debian13_all.deb
    apt update -qq
    apt install -y zabbix-agent2
    PSK=\$(openssl rand -hex 32)
    echo \$PSK > /etc/zabbix/secret.psk
    chmod 600 /etc/zabbix/secret.psk
    chown zabbix:zabbix /etc/zabbix/secret.psk
    sed -i 's/^Server=127.0.0.1/Server=192.168.255.3/' /etc/zabbix/zabbix_agent2.conf
    sed -i 's/^ServerActive=127.0.0.1/#ServerActive=127.0.0.1/' /etc/zabbix/zabbix_agent2.conf
    sed -i 's/^Hostname=Zabbix server/Hostname=$HOSTNAME/' /etc/zabbix/zabbix_agent2.conf
    sed -i 's/^# TLSConnect=unencrypted/TLSConnect=psk/' /etc/zabbix/zabbix_agent2.conf
    sed -i 's/^# TLSAccept=unencrypted/TLSAccept=psk/' /etc/zabbix/zabbix_agent2.conf
    sed -i 's|^# TLSPSKIdentity=.*|TLSPSKIdentity=$HOSTNAME|' /etc/zabbix/zabbix_agent2.conf
    sed -i 's|^# TLSPSKFile=.*|TLSPSKFile=/etc/zabbix/secret.psk|' /etc/zabbix/zabbix_agent2.conf
    systemctl restart zabbix-agent2
    echo 'PSK ZABBIX :'
    echo \$PSK
    "
    echo "[INFO] Zabbix Agent 2 installé et configuré."
fi

if $template_mode; then
if [ -f "$(cd "$(dirname "$0")" && pwd)/templates/${APP}.sh" ]; then
    echo "[INFO] Lancement du script d'installation"
    bash "$(cd "$(dirname "$0")" && pwd)/templates/${APP}.sh" "$CTID"
else
    echo "[ERREUR] Script d'installation introuvable."
    exit 1
fi
fi

if $template_mode; then
    pct shutdown "$CTID"
    echo "[INFO] Attente de l'arrêt..."
    while true; do
        STATUS=$(pct status "$CTID" | awk '{print $2}')
        if [[ "$STATUS" == "stopped" ]]; then
            break
        fi
        sleep 2
    done
    pct template "$CTID"
    echo "[INFO] Template créé avec succès."
fi