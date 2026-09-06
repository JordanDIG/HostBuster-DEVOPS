#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo "               HOSTBUSTER AUTO NAT MINECRAFT"
echo "     journalctl -u hostbuster_auto_nat.service -f"
echo "============================================================"
echo "Ce script génère automatiquement la configuration rinetd pour les conteneurs LXC Minecraft."
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

PORT_START="${PORT_START:-26000}"
PORT_END="${PORT_END:-65535}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"

if (( PORT_END < PORT_START )); then
    error "PORT_END ($PORT_END) doit être supérieur ou égal à PORT_START ($PORT_START)"
    exit 1
fi

if (( PORT_END > 65535 )); then
    error "PORT_END ($PORT_END) ne peut pas dépasser 65535"
    exit 1
fi

# HELPERS
api() {
    local endpoint="$1"
    local response status body

    response=$(
        curl -sk \
            --connect-timeout 3 \
            --max-time 5 \
            -w "\n%{http_code}" \
            -H "Authorization: PVEAPIToken=${TOKEN_ID}=${PVE_TOKEN_SECRET}" \
            "https://$NODE_IP:8006/api2/json/$endpoint"
    ) || {
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

# CONVERT CTID TO PORT
ctid_to_port() {
    local ctid="$1"
    printf '%d\n' "$((PORT_START + ctid))"
}

generate_rinetd_file() {
    local rules="$1"
    local tmpfile

    tmpfile=$(mktemp)

    while IFS=' ' read -r ctid ipv4 ext_port; do
        [[ -z "$ctid" ]] && continue

        printf ':: %s %s %s\n' \
            "$ext_port" \
            "$ipv4" \
            "$MINECRAFT_PORT"
    done <<< "$rules" > "$tmpfile"

    printf '%s\n' "$tmpfile"
}

reload_rinetd() {
    local file="$1"

    cp "$file" /etc/rinetd.conf
    rm -f "$file"

    if ! rinetd -c /etc/rinetd.conf >/dev/null 2>&1; then
        error "Configuration rinetd invalide"
        return 1
    fi

    if ! systemctl reload rinetd; then
        error "Impossible de recharger rinetd"
        return 1
    fi

    info "Configuration rinetd rechargée"
}

# DEPENDENCIES CHECK
info "Vérification des dépendances système"

for cmd in curl jq rinetd; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "La commande '$cmd' n'est pas installée"
        exit 1
    }
done

info "Toutes les dépendances sont présentes"

# MAIN LOOP
prev_snapshot=""

while true; do
    info "Démarrage de la synchronisation rinetd"

    lxc_json=""

    for i in 1 2 3; do
        lxc_json="$(api "nodes/$NODE/lxc")" && break

        warn "Impossible de récupérer les conteneurs LXC, nouvel essai dans 10 secondes..."
        sleep 10
    done

    if [[ -z "$lxc_json" ]]; then
        error "Impossible de récupérer les conteneurs LXC après 30 secondes"
        sleep 30
        continue
    fi

    snapshot=""
    rules=""

    while read -r ctid; do
        [[ -z "$ctid" ]] && continue

        config="$(api "nodes/$NODE/lxc/$ctid/config")" || {
            warn "Config CT $ctid KO"
            continue
        }

        tags="$(jq -r '.data.tags // ""' <<< "$config")"

        [[ "$tags" == *bridge-clients* ]] || {
            info "$ctid ignoré : tag bridge-clients absent"
            continue
        }

        [[ "$tags" == *minecraft* ]] || {
            info "$ctid ignoré : tag minecraft absent"
            continue
        }

        status_json="$(api "nodes/$NODE/lxc/$ctid/status/current")" || {
            warn "Status CT $ctid KO"
            continue
        }

        status="$(jq -r '.data.status // "stopped"' <<< "$status_json")"

        [[ "$status" == "running" ]] || {
            warn "CT $ctid ignoré : statut '$status'"
            continue
        }

        interfaces="$(api "nodes/$NODE/lxc/$ctid/interfaces")" || {
            warn "Interfaces CT $ctid KO"
            continue
        }

        ipv4=$(
            jq -r '
                .data[]?
                | select(.name != "lo")
                | .["ip-addresses"][]?
                | select(."ip-address-type" == "inet")
                | ."ip-address"
            ' <<< "$interfaces" |
                grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
        )

        [[ -n "$ipv4" ]] || {
            warn "CT $ctid ignoré : pas d'IPv4"
            continue
        }

        ext_port="$(ctid_to_port "$ctid")"

        if (( ext_port > PORT_END )); then
            warn "CT $ctid ignoré : port calculé $ext_port supérieur à PORT_END=$PORT_END"
            continue
        fi

        info "Ajout du proxy : port $ext_port -> $ipv4:$MINECRAFT_PORT"

        snapshot+="$ctid:$ipv4:$ext_port"$'\n'
        rules+="$ctid $ipv4 $ext_port"$'\n'

    done < <(
        jq -r '.data[] | .vmid // empty' <<< "$lxc_json" | sort -n
    )

    snapshot="$(sort <<< "$snapshot")"

    if [[ "$snapshot" == "$prev_snapshot" ]]; then
        info "Aucun changement, prochain cycle dans 30s"
        sleep 30
        continue
    fi

    info "Changements détectés, reconstruction de la configuration rinetd"

    tmpfile="$(generate_rinetd_file "$rules")"

    reload_rinetd "$tmpfile" || {
        warn "Ancienne configuration conservée"
        rm -f "$tmpfile"
        sleep 30
        continue
    }

    prev_snapshot="$snapshot"

    info "Cycle terminé avec succès"
    info "Prochaine vérification dans 30 secondes"
    sleep 30
done
