#!/bin/bash

CTID="$1"

# Installation et configuration du template MINECRAFT
echo "Début de l'installation de MINECRAFT dans le conteneur $CTID..."

pct exec "$CTID" -- bash -s </dev/tty >/dev/tty 2>&1 <<'END_INSTALL'
#!/bin/bash
# Script d'installation de Minecraft dans un conteneur LXC

PASSWORD_FILE="/root/passwords"

export LANG=C.UTF-8
export LANGUAGE=C.UTF-8
export LC_ALL=C.UTF-8

gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
echo "[INFO] Génération du mot de passe RCON..."
RCON_PASSWORD=$(gen_pass)

echo "[INFO] Sauvegarde du mot de passe dans $PASSWORD_FILE..."
cat > "$PASSWORD_FILE" <<END
RCON
Mot de passe : $RCON_PASSWORD
END
chmod 600 "$PASSWORD_FILE"
echo "[INFO] Mots de passe sauvegardés et fichier sécurisé."

cat << 'END' > /etc/nftables.conf
#!/usr/sbin/nft -f

table inet filter {
    chain input {
        type filter hook input priority filter;
        policy drop;

        # ALLOW LOOPBACK TO HOST
        iif lo counter log prefix "INPUT ACCEPT LOOPBACK: " flags all accept

        # ALLOW ESTABLISHED,RELATED CONNECTIONS TO HOST
        ct state established,related counter log prefix "INPUT ACCEPT ESTABLISHED: " flags all accept

        # ALLOW SvISP TO HOST PORT 25565 (Minecraft)
        ip saddr 192.168.0.1 tcp dport 25565 counter log prefix "INPUT ACCEPT MINECRAFT: " flags all accept

        # ALLOW SvZabbix TO HOST ICMP
        ip saddr 192.168.255.3 ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } counter log prefix "INPUT ACCEPT ICMP: " flags all accept

        # DROP INPUT PACKETS
        log prefix "INPUT DROP PACKET: " flags all counter drop
    }

    chain forward {
        type filter hook forward priority filter;
        policy drop;

    }

    chain output {
        type filter hook output priority filter;
        policy accept;

    }
}
END
systemctl restart nftables
echo "[INFO] nftables configuré et redémarré."

apt install -y build-essential curl git jq unzip
echo "[INFO] Paquets requis installés."

useradd -r -s /usr/sbin/nologin hostbuster-minecraft
echo "[INFO] Utilisateur hostbuster-minecraft créé."

mkdir /opt/minecraft
echo "[INFO] Répertoire /opt/minecraft créé et permissions définies."

echo "[INFO] Téléchargement du dernier serveur Minecraft..."
wget -O /opt/minecraft/server.jar "$(
    curl -s "$(
        curl -s https://launchermeta.mojang.com/mc/game/version_manifest.json |
        jq -r --arg VER "$(
            curl -s https://launchermeta.mojang.com/mc/game/version_manifest.json |
            jq -r '.latest.release'
        )" '.versions[] | select(.id==$VER) | .url'
    )" |
    jq -r '.downloads.server.url'

)"

JAVA_VERSION="$(
    curl -s "$(
        curl -s https://launchermeta.mojang.com/mc/game/version_manifest.json |
        jq -r --arg VER "$(
            curl -s https://launchermeta.mojang.com/mc/game/version_manifest.json |
            jq -r '.latest.release'
        )" '.versions[] | select(.id==$VER) | .url'
    )" |
    jq -r '.javaVersion.majorVersion'
)"
echo "[INFO] Version Java requise : $JAVA_VERSION"
apt install -y "openjdk-${JAVA_VERSION}-jre-headless"

echo "[INFO] Permissions définies pour hostbuster-minecraft sur /opt/minecraft."
chown -R hostbuster-minecraft:hostbuster-minecraft /opt/minecraft

echo "eula=true" > /opt/minecraft/eula.txt
echo "[INFO] EULA acceptée."

echo "[INFO] Création du script de démarrage hostbuster-start-minecraft.sh..."
cat > /usr/local/sbin/hostbuster-start-minecraft.sh <<'END'
#!/bin/bash
# Ce script démarre le serveur Minecraft en allouant 95% de la RAM totale du conteneur

RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024*0.95}' /proc/meminfo)
exec /usr/bin/java -Xms${RAM_MB}M -Xmx${RAM_MB}M -jar /opt/minecraft/server.jar nogui
END
chmod +x /usr/local/sbin/hostbuster-start-minecraft.sh

echo "[INFO] Démarrage du serveur et générer les fichiers de configuration..."
echo "[INFO] Le serveur va s'arrêter automatiquement après 1 minute"
(
    sleep 60
    echo "stop"
) | runuser -u hostbuster-minecraft -- bash -c '
    cd /opt/minecraft || exit 1
    /usr/local/sbin/hostbuster-start-minecraft.sh'

echo "[INFO] Installation de mcrcon..."
mkdir /opt/mcrcon && cd /opt/mcrcon
git clone https://github.com/Tiiffi/mcrcon.git
cd mcrcon
make
cp mcrcon /usr/local/bin/
chmod +x /usr/local/bin/mcrcon
ln -s /usr/local/bin/mcrcon /usr/bin/mcrcon

echo "[INFO] Modification de server.properties pour autoriser les connexions RCON..."
sed -i "s/^enable-rcon=false/enable-rcon=true/" /opt/minecraft/server.properties
sed -i "s/^rcon.password=.*/rcon.password=$RCON_PASSWORD/" /opt/minecraft/server.properties

echo "[INFO] Création du service systemd hostbuster-minecraft..."
cat > /etc/systemd/system/hostbuster-minecraft.service <<END
[Unit]
Description=HostBuster - Minecraft Server
After=network.target

[Service]
WorkingDirectory=/opt/minecraft
User=hostbuster-minecraft
KillMode=process
KillSignal=SIGINT
ExecStop=mcrcon -H localhost -P 25575 -p "$RCON_PASSWORD" -w 10 "say Le serveur va être mis hors ligne pour maintenance" "kick @a Maintenance en cours" save-all stop
ExecStart=/usr/local/sbin/hostbuster-start-minecraft.sh
TimeoutSec=0
SuccessExitStatus=130

[Install]
WantedBy=multi-user.target
END
systemctl daemon-reload

echo "[INFO] Création du script hostbuster-firstboot-minecraft.sh..."
cat > /usr/local/sbin/hostbuster-firstboot-minecraft.sh <<'END_FIRSTBOOT'
#!/bin/bash
# Script firstboot Minecraft pour régénérer les mots de passe et supprimer le monde existant

PASSWORD_FILE="/root/passwords"

echo "$(date '+%A %d/%m/%Y') à $(date '+%H:%M:%S')"
    
echo "[INFO] Début du script hostbuster-firstboot-minecraft.sh"

BACKUP_FILE="/root/passwords.$(date +%F_%H-%M-%S)"

OLD_RCON_PASS=$(awk '/^RCON$/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")
gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
echo "[INFO] Génération du nouveau mot de passe RCON..."
NEW_RCON_PASS=$(gen_pass)
echo "[INFO] Nouveau mot de passe RCON généré."

cp "$PASSWORD_FILE" "$BACKUP_FILE"
echo "[INFO] Sauvegarde des anciens mots de passe réalisée dans $BACKUP_FILE"

sed -i '/^RCON$/,/^$/ s/^Mot de passe :.*/Mot de passe : '"$NEW_RCON_PASS"'/' "$PASSWORD_FILE"
echo "[INFO] Fichier $PASSWORD_FILE mis à jour."

sed -i "s/^rcon.password=.*/rcon.password=$NEW_RCON_PASS/" /opt/minecraft/server.properties
sed -i 's/-p "[^"]*"/-p "'"$NEW_RCON_PASS"'"/' /etc/systemd/system/hostbuster-minecraft.service
echo "[INFO] Configuration du serveur Minecraft et du service systemd mises à jour avec le nouveau mot de passe RCON."

rm -r /opt/minecraft/world/
echo "[INFO] Monde Minecraft supprimé pour une configuration propre."

systemctl enable --now hostbuster-minecraft.service
echo "[INFO] Service hostbuster-minecraft activé et démarré."

systemctl disable hostbuster-firstboot-minecraft.service

echo "[INFO] Le service hostbuster-firstboot-minecraft.service a été désactivé."
echo "[INFO] Installation terminée."
END_FIRSTBOOT

echo "[INFO] Création du service systemd hostbuster-firstboot-minecraft..."
cat > /etc/systemd/system/hostbuster-firstboot-minecraft.service <<END
[Unit]
Description=HostBuster - Firstboot Minecraft Script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hostbuster-firstboot-minecraft.sh
StandardOutput=append:/var/log/hostbuster-firstboot-minecraft.log
StandardError=append:/var/log/hostbuster-firstboot-minecraft.log

[Install]
WantedBy=multi-user.target
END
chmod +x /usr/local/sbin/hostbuster-firstboot-minecraft.sh
systemctl daemon-reload
systemctl enable hostbuster-firstboot-minecraft.service
echo "[INFO] Le service hostbuster-firstboot-minecraft est activé au démarrage."

LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo ""
echo "[INFO] Adresse IP locale : $LOCAL_IP"
echo ""

echo "[INFO] Installation de Minecraft terminée."
END_INSTALL