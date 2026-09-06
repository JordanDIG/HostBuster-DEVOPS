#!/bin/bash

CTID="$1"

# Installation et configuration du template WordPress
echo "Début de l'installation de WordPress dans le conteneur $CTID..."

pct exec "$CTID" -- bash -s </dev/tty >/dev/tty 2>&1 <<'END_INSTALL'
#!/bin/bash
# Script d'installation de WordPress dans un conteneur LXC

PASSWORD_FILE="/root/passwords"
WP_DB="wordpress"
WP_DB_USER="wp_adm"

export LANG=C.UTF-8
export LANGUAGE=C.UTF-8
export LC_ALL=C.UTF-8

# Génération des mots de passe
gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
echo "[INFO] Génération des mots de passe..."
MYSQL_ROOT_PASSWORD=$(gen_pass)
WP_DB_PASSWORD=$(gen_pass)

echo "[INFO] Sauvegarde des mots de passe dans $PASSWORD_FILE..."
cat > "$PASSWORD_FILE" <<END
MySQL root
Mot de passe : $MYSQL_ROOT_PASSWORD

Base de données WordPress
Nom : $WP_DB
Utilisateur : $WP_DB_USER
Mot de passe : $WP_DB_PASSWORD
END
chmod 600 "$PASSWORD_FILE"
echo "[INFO] Mots de passe sauvegardés et fichier sécurisé."

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
   
    chain output { type filter hook output priority filter;
    policy accept;
    
    }
}
END
systemctl restart nftables
echo "[INFO] nftables configuré et redémarré."

apt install -y curl nginx mariadb-server php-fpm php-curl php-gd php-intl php-mysql php-zip php-mbstring php-xml php-imagick php-xmlrpc php-soap ed
echo "[INFO] Paquets requis installés."

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
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "/etc/php/${PHP_VERSION}/fpm/php.ini"
sed -i 's/post_max_size = .*/post_max_size = 64M/' "/etc/php/${PHP_VERSION}/fpm/php.ini"
systemctl restart php${PHP_VERSION}-fpm

mariadb <<END
ALTER USER 'root'@'localhost'
IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user
WHERE User='root'
AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db
WHERE Db='test'
OR Db='test\\_%';
FLUSH PRIVILEGES;
END
echo "[INFO] Base MariaDB sécurisée."

mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" <<END
CREATE DATABASE $WP_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';
GRANT ALL PRIVILEGES ON $WP_DB.* TO '$WP_DB_USER'@'localhost';
FLUSH PRIVILEGES;
END
echo "[INFO] Base WordPress et utilisateur créés."

cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress /var/www/wordpress
chown -R www-data:www-data /var/www/wordpress
echo "[INFO] WordPress téléchargé et déployé dans /var/www/wordpress."

# Configuration initiale wp-config.php
mv /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php
sed -i "s/database_name_here/$WP_DB/" /var/www/wordpress/wp-config.php
sed -i "s/username_here/$WP_DB_USER/" /var/www/wordpress/wp-config.php
sed -i "s/password_here/$WP_DB_PASSWORD/" /var/www/wordpress/wp-config.php

SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
printf '%s\n' "g/put your unique phrase here/d" a "$SALT" . w | ed -s /var/www/wordpress/wp-config.php
echo "[INFO] wp-config.php configuré avec les informations de la base de données et les clés de sécurité."

sed -i '/\/\* Add any custom values between this line and the "stop editing" line\. \*\//a\
if (\
    isset($_SERVER['\''HTTP_X_FORWARDED_PROTO'\'']) &&\
    $_SERVER['\''HTTP_X_FORWARDED_PROTO'\''] === '\''https'\''\
) {\
    $_SERVER['\''HTTPS'\''] = '\''on'\'';\
}\
' /var/www/wordpress/wp-config.php
perl -0pi -e 's/\r//g; s/\n{3,}(\/\* That.s all, stop editing! Happy publishing\. \*\/)/\n\n$1/s' /var/www/wordpress/wp-config.php
echo "[INFO] Configuration wp-config.php mise à jour pour HTTPS."

cat > "/etc/nginx/sites-enabled/default" <<END
server {
    listen 80 default_server;
    server_name _;
    root /var/www/wordpress;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires max;
        log_not_found off;
    }
}
END
systemctl reload nginx
echo "[INFO] NGINX configuré et rechargé."

# Création du script hostbuster-firstboot-wordpress.sh
echo "[INFO] Création du script hostbuster-firstboot-wordpress.sh..."
cat > /usr/local/sbin/hostbuster-firstboot-wordpress.sh <<'END_FIRSTBOOT'
#!/bin/bash
# Script firstboot Wordpress pour régénérer les mots de passe et finaliser la configuration

PASSWORD_FILE="/root/passwords"

echo "$(date '+%A %d/%m/%Y') à $(date '+%H:%M:%S')"

echo "[INFO] Début du script hostbuster-firstboot-wordpress.sh"

BACKUP_FILE="/root/passwords.$(date +%F_%H-%M-%S)"

OLD_ROOT_PASS=$(awk '/^MySQL root/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")
OLD_WP_PASS=$(awk '/^Utilisateur : wp_adm/ {found=1} found && /^Mot de passe/ {sub(/.*Mot de passe : /,"",$0); print; exit}' "$PASSWORD_FILE")

# Génération nouveaux mots de passe
gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 30
}
NEW_ROOT_PASS=$(gen_pass)
NEW_WP_PASS=$(gen_pass)
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
ALTER USER 'wp_adm'@'localhost' IDENTIFIED BY '$NEW_WP_PASS';
FLUSH PRIVILEGES;
END
echo "[INFO] Mots de passe MySQL mis à jour."

cp "$PASSWORD_FILE" "$BACKUP_FILE"
echo "[INFO] Sauvegarde réalisée dans $BACKUP_FILE"

awk -v new_root="$NEW_ROOT_PASS" -v new_wp="$NEW_WP_PASS" '
BEGIN { in_mysql_root=0; in_wp_adm=0 }
/^MySQL root/ { in_mysql_root=1 }
/^Utilisateur : wp_adm/ { in_wp_adm=1 }
in_mysql_root && /^Mot de passe/ {
    print "Mot de passe : " new_root
    in_mysql_root=0
    next
}
in_wp_adm && /^Mot de passe/ {
    print "Mot de passe : " new_wp
    in_wp_adm=0
    next
}
{ print }
' "$BACKUP_FILE" > "$PASSWORD_FILE"
echo "[INFO] Fichier $PASSWORD_FILE mis à jour."

sed -i "s/define( 'DB_PASSWORD', '.*' );/define( 'DB_PASSWORD', '$NEW_WP_PASS' );/" /var/www/wordpress/wp-config.php
echo "[INFO] Configuration wp-config.php mise à jour avec le nouveau mot de passe."

systemctl disable hostbuster-firstboot-wordpress.service

echo "[INFO] Le service hostbuster-firstboot-wordpress.service a été désactivé."
echo "[INFO] Installation terminée."
END_FIRSTBOOT

echo "[INFO] Création du service systemd hostbuster-firstboot-wordpress..."
cat > /etc/systemd/system/hostbuster-firstboot-wordpress.service <<END
[Unit]
Description=HostBuster - Firstboot WordPress
After=mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hostbuster-firstboot-wordpress.sh
StandardOutput=append:/var/log/hostbuster-firstboot-wordpress.log
StandardError=append:/var/log/hostbuster-firstboot-wordpress.log

[Install]
WantedBy=multi-user.target
END
chmod +x /usr/local/sbin/hostbuster-firstboot-wordpress.sh
systemctl daemon-reload
systemctl enable hostbuster-firstboot-wordpress.service
echo "[INFO] Le service hostbuster-firstboot-wordpress est activé au démarrage."

systemctl enable --now nginx mariadb php${PHP_VERSION}-fpm nftables hostbuster-php-fpm.service
echo "[INFO] Les services requis sont activés au démarrage et lancés."

rm -f /var/www/wordpress/readme.html && rm -f /var/www/wordpress/license.txt
echo "[INFO] Fichiers readme.html et license.txt supprimés."

LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo ""
echo "[INFO] Adresse IP locale : $LOCAL_IP"
echo ""

echo "[INFO] Installation de WordPress terminée."
END_INSTALL