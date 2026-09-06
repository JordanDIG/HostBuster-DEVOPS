#!/bin/bash

CTID="$1"

# Installation et configuration du template GLPI
echo "Début de l'installation de GLPI dans le conteneur $CTID..."

pct exec "$CTID" -- bash -s </dev/tty >/dev/tty 2>&1 <<'END_INSTALL'
#!/bin/bash
# Script d'installation de GLPI dans un conteneur LXC

PASSWORD_FILE="/root/passwords"
GLPI_DB="glpi"
GLPI_DB_USER="glpi_adm"

CT_NAME=$(hostname -s)
DOMAIN="${CT_NAME}.carabuster.filiere.info"

export LANG=C.UTF-8
export LANGUAGE=C.UTF-8
export LC_ALL=C.UTF-8

gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
echo "[INFO] Génération des mots de passe..."
MYSQL_ROOT_PASSWORD=$(gen_pass)
GLPI_DB_PASSWORD=$(gen_pass)

echo "[INFO] Sauvegarde des mots de passe dans $PASSWORD_FILE..."
cat > "$PASSWORD_FILE" <<END
MySQL root
Mot de passe : $MYSQL_ROOT_PASSWORD

Base de données GLPI
Nom : $GLPI_DB
Utilisateur : $GLPI_DB_USER
Mot de passe : $GLPI_DB_PASSWORD
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
systemctl restart nftables
echo "[INFO] nftables configuré et redémarré."

apt install -y curl nginx mariadb-server htop php-fpm php-curl php-gd php-intl php-mysql php-zip php-bcmath php-mbstring php-xml php-bz2
echo "[INFO] Paquets requis installés."

echo "[INFO] Création du service pour hostbuster-php-fpm..."
echo "d /run/php 0755 www-data www-data -" > /etc/tmpfiles.d/php-fpm.conf
cat > /etc/systemd/system/hostbuster-php-fpm.service <<END
[Unit]
Description=HostBuster - Créer /run/php pour PHP-FPM
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/php-fpm.conf

[Install]
WantedBy=multi-user.target
END
echo "[INFO] Service hostbuster-php-fpm créé."

echo "[INFO] Sécurisation des sessions PHP..."
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
sed -i 's/^;*session.cookie_httponly.*/session.cookie_httponly = On/' "/etc/php/${PHP_VERSION}/fpm/php.ini"
sed -i 's/^;*session.cookie_samesite.*/session.cookie_samesite = Lax/' "/etc/php/${PHP_VERSION}/fpm/php.ini"
systemctl restart php${PHP_VERSION}-fpm

mariadb <<END
ALTER USER 'root'@'localhost'
IDENTIFIED VIA mysql_native_password
USING PASSWORD('$MYSQL_ROOT_PASSWORD');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
END
echo "[INFO] Base MariaDB sécurisée."

mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" <<END
CREATE DATABASE $GLPI_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$GLPI_DB_USER'@'localhost' IDENTIFIED BY '$GLPI_DB_PASSWORD';
GRANT ALL PRIVILEGES ON $GLPI_DB.* TO '$GLPI_DB_USER'@'localhost';
FLUSH PRIVILEGES;
END
echo "[INFO] Base GLPI et utilisateur créés."

cd /tmp
wget "$(curl -fsSL https://api.github.com/repos/glpi-project/glpi/releases/latest | grep browser_download_url | grep tgz | cut -d '"' -f4)" -O glpi.tgz
tar -xzf glpi.tgz -C /var/www/
chown -R www-data:www-data /var/www/glpi
mkdir -p /etc/glpi /var/lib/glpi /var/log/glpi
chown www-data:www-data /etc/glpi /var/lib/glpi /var/log/glpi
mv /var/www/glpi/config /etc/glpi
mv /var/www/glpi/files /var/lib/glpi
echo "[INFO] GLPI téléchargé, déployé et permissions configurées."

cat > /var/www/glpi/inc/downstream.php <<END
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
END
cat > /etc/glpi/local_define.php <<END
<?php
define('GLPI_VAR_DIR', '/var/lib/glpi/files');
define('GLPI_LOG_DIR', '/var/log/glpi');
END
echo "[INFO] Configuration GLPI terminée."

rm -r /var/www/html
echo "[INFO] Supression du répertoire HTML par défaut de NGINX."

cat > "/etc/nginx/sites-available/default" <<END
server {
    listen 80 default_server;
    server_name _;
    root /var/www/glpi/public;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ ^/index\.php$ {
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
END
echo "[INFO] Configuration NGINX par défaut mise à jour."

sed -i '/server_tokens off;/a\
\
\tserver_names_hash_bucket_size 128;' /etc/nginx/nginx.conf
systemctl reload nginx
echo "[INFO] NGINX configuré et rechargé."

echo "[INFO] Création du script hostbuster-firstboot-glpi.sh..."
cat > /usr/local/sbin/hostbuster-firstboot-glpi.sh <<'END_FIRSTBOOT'
#!/bin/bash
# Script firstboot GLPI pour régénérer les mots de passe et finaliser la configuration

PASSWORD_FILE="/root/passwords"

echo "$(date '+%A %d/%m/%Y') à $(date '+%H:%M:%S')"

echo "[INFO] Début du script hostbuster-firstboot-glpi.sh"

BACKUP_FILE="/root/passwords.$(date +%F_%H-%M-%S)"

OLD_ROOT_PASS=$(awk '/^MySQL root/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")
OLD_GLPI_PASS=$(awk '/^Utilisateur : glpi_adm/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")

gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
NEW_ROOT_PASS=$(gen_pass)
NEW_GLPI_PASS=$(gen_pass)
echo "[INFO] Nouveaux mots de passe générés."

echo "[INFO] Attente de MariaDB..."
for i in {1..12}; do
  [ -S /run/mysqld/mysqld.sock ] && break
  sleep 5
done
[ ! -S /run/mysqld/mysqld.sock ] && {
  echo "[ERREUR] MariaDB indisponible après 60 secondes d'attente."
  exit 1
}

mysql -u root -p"$OLD_ROOT_PASS" <<END
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_ROOT_PASS';
ALTER USER 'glpi_adm'@'localhost' IDENTIFIED BY '$NEW_GLPI_PASS';
FLUSH PRIVILEGES;
END
echo "[INFO] Mots de passe MySQL mis à jour."

cp "$PASSWORD_FILE" "$BACKUP_FILE"
echo "[INFO] Sauvegarde réalisée dans $BACKUP_FILE"

awk -v new_root="$NEW_ROOT_PASS" -v new_glpi="$NEW_GLPI_PASS" '
BEGIN { in_mysql_root=0; in_glpi_adm=0 }
/^MySQL root/ {in_mysql_root=1}
/^Utilisateur : glpi_adm/ {in_glpi_adm=1}
in_mysql_root && /^Mot de passe/ {print "Mot de passe : " new_root; in_mysql_root=0; next}
in_glpi_adm && /^Mot de passe/ {print "Mot de passe : " new_glpi; in_glpi_adm=0; next}
{print}
' "$BACKUP_FILE" > "$PASSWORD_FILE"
echo "[INFO] Fichier $PASSWORD_FILE mis à jour."

sed -i -E "s|(public[[:space:]]+\\\$dbpassword[[:space:]]*=[[:space:]]*')[^']*(';)|\1$NEW_GLPI_PASS\2|" "/etc/glpi/config_db.php"
echo "[INFO] Configuration GLPI mise à jour avec le nouveau mot de passe."

systemctl disable hostbuster-firstboot-glpi.service

echo "[INFO] Le service hostbuster-firstboot-glpi.service a été désactivé."
echo "[INFO] Installation terminée."
END_FIRSTBOOT

echo "[INFO] Création du service systemd hostbuster-firstboot-glpi..."
cat > /etc/systemd/system/hostbuster-firstboot-glpi.service <<END
[Unit]
Description=HostBuster - Firstboot GLPI Script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hostbuster-firstboot-glpi.sh
StandardOutput=append:/var/log/hostbuster-firstboot-glpi.log
StandardError=append:/var/log/hostbuster-firstboot-glpi.log

[Install]
WantedBy=multi-user.target
END
chmod +x /usr/local/sbin/hostbuster-firstboot-glpi.sh
systemctl daemon-reload
systemctl enable hostbuster-firstboot-glpi.service
echo "[INFO] Le service hostbuster-firstboot-glpi est activé au démarrage."

systemctl enable --now nginx mariadb php${PHP_VERSION}-fpm nftables hostbuster-php-fpm.service
echo "[INFO] Les services requis sont activés au démarrage et lancés."

LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo ""
echo "[INFO] Adresse IP locale : $LOCAL_IP"
echo ""
echo "Pour finaliser l'installation de GLPI :"
echo "- Ouvrez votre navigateur à l'adresse : https://$DOMAIN"
echo "- Suivez l'assistant d'installation"
echo "- Lors de l'étape de configuration de la base de données :"
echo "  Serveur SQL : localhost"
echo "  Utilisateur SQL : $GLPI_DB_USER"
echo "  Mot de passe SQL : $GLPI_DB_PASSWORD"
echo "  Base de données : $GLPI_DB"
echo "- Décochez l'option \"Envoyer les statistiques d'usage\""
echo ""
echo "[INFO] Vous avez 3 minutes pour finaliser l'installation via l'interface WEB."
echo "En attente de la fin de l'installation GLPI..."
sleep 180

rm -f /var/www/glpi/install/install.php
echo "[INFO] Fichier d'installation supprimé."

echo "[INFO] Installation de GLPI terminée."
END_INSTALL