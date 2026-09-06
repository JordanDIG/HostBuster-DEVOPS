#!/bin/bash

CTID="$1"

# Installation et configuration du template Odoo
echo "Début de l'installation d'Odoo dans le conteneur $CTID..."

pct exec "$CTID" -- bash -s </dev/tty >/dev/tty 2>&1 <<'END_INSTALL'
#!/bin/bash
# Script d'installation d'Odoo dans un conteneur LXC

PASSWORD_FILE="/root/passwords"
ODOO_DB_USER="odoo"
ODOO_CONF="/etc/odoo/odoo.conf"
ODOO_LOG="/var/log/odoo/odoo-server.log"

CT_NAME=$(hostname -s)
DOMAIN="${CT_NAME}.carabuster.filiere.info"

# Définir les locales
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8
export LC_ALL=C.UTF-8

# Génération des mots de passe
gen_pass() {
    head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 30
}

echo "[INFO] Génération des mots de passe..."
ODOO_DB_PASSWORDWORD=$(gen_pass)
ODOO_MASTER_PASSWORDWORD=$(gen_pass)

# Configuration nftables
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

        # ALLOW SvISP TO HOST PORT 80 (HTTP)
        ip saddr 192.168.0.1 tcp dport 80 counter log prefix "INPUT ACCEPT HTTP: " flags all accept

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
echo "[INFO] nftables configuré."

# Installation des dépendances
echo "[INFO] Installation des dépendances..."
apt install -y curl postgresql gnupg nginx python3-pypdf equivs

# Ajout de la clé et du dépôt Odoo
echo "[INFO] Configuration du dépôt Odoo..."
wget -O - https://nightly.odoo.com/odoo.key | gpg --dearmor -o /usr/share/keyrings/odoo-archive-keyring.gpg
ODOO_VERSION=$(
    curl -fsSL https://nightly.odoo.com/ |
    grep -oE '[0-9]+\.[0-9]+' |
    sort -V |
    tail -n1
)
if [ -z "$ODOO_VERSION" ]; then
    echo "[WARN] Impossible de détecter la dernière version Odoo."
    ODOO_VERSION="19.0"
fi
echo "[INFO] Dernière version détectée : $ODOO_VERSION"
cat > /etc/apt/sources.list.d/odoo.list <<EOF
deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/ ./
EOF

echo "[INFO] Création du paquet de compatibilité python3-pypdf2..."
BUILD_DIR=$(mktemp -d /tmp/pypdf2-compat.XXXXXX)
cd "$BUILD_DIR"
cat > python3-pypdf2 <<'EOF'
Section: python
Priority: optional
Package: python3-pypdf2
Version: 5.4.0
Depends: python3-pypdf
Provides: python3-pypdf2
Architecture: all
Description: Compatibility package for Odoo on Debian 13
EOF
equivs-build python3-pypdf2
dpkg -i python3-pypdf2_*.deb

# Mise à jour des dépôts et installation d'Odoo
echo "[INFO] Mise à jour des dépôts et installation d'Odoo..."
apt update && apt install -y odoo

# Configuration PostgreSQL
echo "[INFO] Configuration de PostgreSQL..."
su - postgres -c "createuser --createdb --no-createrole --no-superuser ${ODOO_DB_USER}"
su - postgres -c "psql -c \"ALTER USER ${ODOO_DB_USER} WITH PASSWORD '${ODOO_DB_PASSWORDWORD}';\""
echo "[INFO] Utilisateur PostgreSQL Odoo configuré."

# Configuration Odoo
mkdir -p /etc/odoo /var/log/odoo /var/lib/odoo /opt/odoo/custom-addons
chown -R odoo:odoo /var/log/odoo /var/lib/odoo /opt/odoo
chmod 750 /opt/odoo/custom-addons

cat > "$ODOO_CONF" <<END
[options]
admin_passwd = ${ODOO_MASTER_PASSWORDWORD}
db_host = False
db_port = False
db_user = ${ODOO_DB_USER}
db_password = ${ODOO_DB_PASSWORDWORD}
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/opt/odoo/custom-addons
logfile = ${ODOO_LOG}
proxy_mode = True
xmlrpc_interface = 127.0.0.1
xmlrpc_port = 8069
gevent_port = 8072
list_db = True
workers = 2
max_cron_threads = 1
END
chown odoo:odoo "$ODOO_CONF"
chmod 640 "$ODOO_CONF"
systemctl restart odoo
echo "[INFO] Configuration Odoo créée et rechargée."

# Sauvegarde des mots de passe
echo "[INFO] Sauvegarde des mots de passe dans $PASSWORD_FILE..."
cat > "$PASSWORD_FILE" <<END
Odoo
Mot de passe maître Odoo : ${ODOO_MASTER_PASSWORDWORD}

Base de données Odoo
Utilisateur : ${ODOO_DB_USER}
Mot de passe : ${ODOO_DB_PASSWORDWORD}
END
chmod 600 "$PASSWORD_FILE"
echo "[INFO] Mots de passe sauvegardés et fichier sécurisé."

# Configuration NGINX en reverse proxy vers Odoo
cat > "/etc/nginx/sites-enabled/default" <<END
upstream odoo_backend {
    server 127.0.0.1:8069;
}

upstream odoo_websocket {
    server 127.0.0.1:8072;
}

server {
    listen 80 default_server;
    server_name _;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    client_max_body_size 128M;

    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    location /websocket {
        proxy_pass http://odoo_websocket;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;
    }

    location / {
        proxy_pass http://odoo_backend;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo_backend;
    }
}
END

systemctl reload nginx
echo "[INFO] NGINX configuré et rechargé."

systemctl enable --now nginx postgresql odoo nftables
echo "[INFO] Services NGINX, PostgreSQL, Odoo et nftables activés et démarrés."

# Création du script hostbuster-firstboot-odoo.sh
echo "[INFO] Création du script hostbuster-firstboot-odoo.sh..."
cat > /usr/local/sbin/hostbuster-firstboot-odoo.sh <<'END_FIRSTBOOT'
#!/bin/bash
# Script firstboot Odoo pour régénérer les mots de passe et finaliser la configuration

set -euo pipefail

PASSWORD_FILE="/root/passwords"
ODOO_DB_USER="odoo"
ODOO_CONF="/etc/odoo/odoo.conf"

echo "$(date '+%A %d/%m/%Y') à $(date '+%H:%M:%S')"
echo "[INFO] Début du script hostbuster-firstboot-odoo.sh"

BACKUP_FILE="/root/passwords.$(date +%F_%H-%M-%S)"
echo "[INFO] Backup des anciens mots de passe dans $BACKUP_FILE"

OLD_ODOO_MASTER_PASSWORD=$(awk '/^Mot de passe maître Odoo/ {sub(/.*Mot de passe maître Odoo : /,"",$0); print; exit}' "$PASSWORD_FILE")
OLD_ODOO_DB_PASSWORD=$(awk '/^Utilisateur : odoo/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")

if [[ -z "$OLD_ODOO_MASTER_PASSWORD" || -z "$OLD_ODOO_DB_PASSWORD" ]]; then
    echo "[ERREUR] Mots de passe non trouvés..."
    exit 1
fi

# Génération nouveaux mots de passe
gen_pass() {
    head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 30
}
ODOO_MASTER_PASSWORD=$(gen_pass)
ODOO_DB_PASSWORD=$(gen_pass)
echo "[INFO] Nouveaux mots de passe générés."

# Attente PostgreSQL
wait_for_postgresql() {
    local elapsed=0
    echo "[INFO] Attente de PostgreSQL"
    until su - postgres -c "pg_isready" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "60" ]; then
            echo "[ERREUR] PostgreSQL non disponible après 60 secondes..."
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 0
}
wait_for_postgresql || exit 1

# Mise à jour PostgreSQL
su - postgres -c "psql -c \"ALTER USER ${ODOO_DB_USER} WITH PASSWORD '${ODOO_DB_PASSWORD}';\""

# Backup du fichier passwords
cp "$PASSWORD_FILE" "$BACKUP_FILE"
echo "[INFO] Sauvegarde réalisée dans $BACKUP_FILE"

# Mise à jour odoo.conf
sed -i "s/^admin_passwd = .*/admin_passwd = ${ODOO_MASTER_PASSWORD}/" "$ODOO_CONF"
sed -i "s/^db_password = .*/db_password = ${ODOO_DB_PASSWORD}/" "$ODOO_CONF"
chown odoo:odoo "$ODOO_CONF"
chmod 640 "$ODOO_CONF"

# Mise à jour du fichier passwords
sed -i "s/$OLD_ODOO_MASTER_PASSWORD/$ODOO_MASTER_PASSWORD/" "$PASSWORD_FILE"
sed -i "s/$OLD_ODOO_DB_PASSWORD/$ODOO_DB_PASSWORD/" "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

systemctl restart odoo nginx
echo "[INFO] Services Odoo et NGINX redémarrés."

systemctl disable hostbuster-firstboot-odoo.service
echo "[INFO] Le service hostbuster-firstboot-odoo.service a été désactivé."

echo "[INFO] Installation terminée."
echo "[INFO] Firstboot Odoo terminé."
END_FIRSTBOOT

chmod +x /usr/local/sbin/hostbuster-firstboot-odoo.sh

# Service Firstboot
cat > /etc/systemd/system/hostbuster-firstboot-odoo.service <<END
[Unit]
Description=HostBuster - Firstboot Odoo Script
After=postgresql.service odoo.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hostbuster-firstboot-odoo.sh
StandardOutput=append:/var/log/hostbuster-firstboot-odoo.log
StandardError=append:/var/log/hostbuster-firstboot-odoo.log

[Install]
WantedBy=multi-user.target
END

systemctl daemon-reload
systemctl enable hostbuster-firstboot-odoo.service

LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo ""
echo "[INFO] Adresse IP locale : $LOCAL_IP"
echo ""
echo "Pour finaliser l'installation d'Odoo :"
echo "- Ouvrez votre navigateur à l'adresse : https://$DOMAIN"
echo "- Suivez l'assistant d'installation"
echo "- Lors de l'étape de configuration :"
echo "  Mot de passe maître : $ODOO_MASTER_PASSWORDWORD"
echo "  Nom de la base de données, email et mot de passe : odoo"
echo "  Langue : French / Français"
echo ""
echo "[INFO] Vous avez 3 minutes pour finaliser l'installation via l'interface WEB."
echo "[INFO] En attente de la fin de l'installation d'Odoo..."
sleep 180
echo ""
echo "[INFO] Installation d'Odoo terminée."
END_INSTALL