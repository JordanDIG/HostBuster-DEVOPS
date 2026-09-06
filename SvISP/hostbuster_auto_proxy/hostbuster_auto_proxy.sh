#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo "               HOSTBUSTER AUTO PROXY CADDY"
echo "     journalctl -u hostbuster_auto_proxy.service -f"
echo "============================================================"
echo "Ce script génère automatiquement une configuration Caddy pour les conteneurs LXC de Proxmox avec les tags appropriés."
echo ""

# LOGGING
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

info() {
    log "INFO" "$@"
}

warn() {
    log "AVERTISSEMENT" "$@"
}

error() {
    log "ERREUR" "$@"
}

# LOAD ENV
source "/usr/local/sbin/hostbuster_auto_proxy.env" 2>/dev/null || {
    error "Impossible de charger les informations du token depuis le fichier .env."
    exit 1
}

CADDY_FILE="/etc/caddy/hostbuster_auto_proxy.caddy"

# HELPERS
api() {
    local endpoint="$1"
    local response status body

    response=$(curl -sk --connect-timeout 3 --max-time 5 -w "\n%{http_code}" -H "Authorization: PVEAPIToken=${TOKEN_ID}=${PVE_TOKEN_SECRET}" "https://$NODE_IP:8006/api2/json/$endpoint") || {
        error "API injoignable (curl)"
        return 1
    }

    status=$(tail -n1 <<< "$response")
    body=$(sed '$d' <<< "$response")

    if [[ "$status" != "200" ]]; then
        error "API erreur HTTP ($status)"
        return 1
    fi

    echo "$body"
}

write_header() {
    cat <<EOF > "$1"
# ===============================================
# FICHIER AUTO-GENERE PAR HOSTBUSTER_AUTO_PROXY #
# ===============================================
EOF
}

# DEPENDENCIES CHECK
info "Vérification des dépendances système"

for cmd in curl jq caddy; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "La commande '$cmd' n'est pas installée"
        exit 1
    }
done

info "Toutes les dépendances sont présentes"

# MAIN LOOP
while true; do
    TMP_FILE="$(mktemp)"
    trap 'rm -f "$TMP_FILE"' EXIT

    blocks=()
    declare -A used_ctids=()

    info "Démarrage de la génération de configuration Caddy"

    write_header "$TMP_FILE"

    # DISCOVERY LXC
    for i in 1 2 3; do
        lxc_json="$(api "nodes/$NODE/lxc")" && break
        warn "Impossible de récupérer les conteneurs LXC, nouvel essai dans 10 secondes..."
        sleep 10
    done

    [ -z "$lxc_json" ] && {
        error "Impossible de récupérer les conteneurs LXC après 30 secondes"
        exit 1
    }

    for ctid in $(jq -r '.data[] | .vmid // empty' <<< "$lxc_json" | sort -n); do
        config="$(api "nodes/$NODE/lxc/$ctid/config")" || {
            error "API config KO pour CT $ctid"
            exit 1
        }

        if [[ "$(jq -r '.data.tags // ""' <<< "$config")" != *bridge-clients* ]]; then
            info "$ctid ignoré : tag bridge-clients absent"
            continue
        fi

        if [[ "$(jq -r '.data.tags // ""' <<< "$config")" != *proxy* ]]; then
            info "$ctid ignoré : tag proxy absent"
            continue
        fi

        interfaces="$(api "nodes/$NODE/lxc/$ctid/interfaces")" || {
            error "API interfaces KO pour CT $ctid"
            exit 1
        }

        ipv4=$(
            jq -r '
                .data[]?
                | select(.name != "lo")
                | .["ip-addresses"][]?
                | select(."ip-address-type" == "inet")
                | ."ip-address"
            ' <<< "$interfaces" \
            | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
        )

        if [[ -z "$ipv4" ]]; then
            warn "$ctid ignoré : aucune IPv4 trouvée"
            continue
        fi

        current_domain="$(
            jq -r '.data.hostname // "unknown"' <<< "$config" \
                | tr '[:upper:]' '[:lower:]' \
                | sed 's/[^a-z0-9.-]/-/g'
        ).carabuster.filiere.info"

        # Gestion des doublons
        if [[ -n "${used_ctids[$current_domain]:-}" ]]; then
            if (( ctid > used_ctids[$current_domain] )); then
                warn "Doublon détecté : $current_domain (CT $ctid ignoré, CT ${used_ctids[$current_domain]} conservé car ID plus petit)"
                continue
            else
                warn "Doublon détecté : $current_domain (CT ${used_ctids[$current_domain]} remplacé par CT $ctid) car ID plus petit)"

                new_blocks=()

                for block in "${blocks[@]}"; do
                    [[ "$block" == "$current_domain {"* ]] && continue
                    new_blocks+=("$block")
                done

                blocks=("${new_blocks[@]}")
            fi
        fi

        used_ctids["$current_domain"]="$ctid"

        info "Ajout du reverse proxy : $current_domain -> $ipv4"

        blocks+=("$current_domain {
    reverse_proxy $ipv4:80
}")
    done

    # WRITE GENERATED FILE
    if [[ ${#blocks[@]} -eq 0 ]]; then
        warn "Aucun conteneur correspondant trouvé"
    else
        info "Écriture du fichier temporaire de configuration Caddy avec ${#blocks[@]} blocs"
        printf '%s\n' "${blocks[@]}" >> "$TMP_FILE"
    fi

    # CHANGE DETECTION
    if cmp -s "$TMP_FILE" "$CADDY_FILE" 2>/dev/null; then
        info "Aucun changement détecté, aucune mise à jour nécessaire"
        rm -f "$TMP_FILE"
        sleep 30
        continue
    fi

    info "Changements détectés, mise à jour de la configuration"

    install -m 644 "$TMP_FILE" "$CADDY_FILE"

    # ENSURE IMPORT
    if [[ ! -f "/etc/caddy/Caddyfile" ]]; then
        info "Création du Caddyfile principal"
        touch "/etc/caddy/Caddyfile"
    fi

    if ! grep -Fxq "import $CADDY_FILE" "/etc/caddy/Caddyfile"; then
        info "Ajout de l'import automatique dans le Caddyfile principal"
        echo "import $CADDY_FILE" >> "/etc/caddy/Caddyfile"
        caddy fmt --overwrite "/etc/caddy/Caddyfile" >/dev/null 2>&1
    fi

    # VALIDATION
    info "Validation de la configuration Caddy"

    if ! caddy validate --config "/etc/caddy/Caddyfile" --adapter caddyfile >/dev/null 2>&1; then
        error "Configuration Caddy invalide"
        rm -f "$TMP_FILE"
        exit 1
    fi

    # RELOAD
    info "Rechargement du service Caddy"

    if ! systemctl reload caddy; then
        error "Échec du rechargement de Caddy"
        rm -f "$TMP_FILE"
        exit 1
    fi

    info "Caddy rechargé avec succès"

    sleep 30
done
