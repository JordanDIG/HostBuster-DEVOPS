#!/bin/bash
# Script pour créer en masse des items pour pinger les adresses IP des conteneurs des clients.

echo "Début de la création des 254 items..."

for i in {1..254}
do
    IP="192.168.0.$i"
    
    # Construction du JSON propre (SANS le paramètre "auth")
    JSON_DATA='{
        "jsonrpc": "2.0",
        "method": "item.create",
        "params": {
            "name": "'"$IP"'",
            "key_": "ping['"$IP"']",
            "hostid": "'"$TEMPLATE_ID"'",
            "type": 3,
            "value_type": 3,
            "delay": "1m",
            "history": "31d",
            "trends": "365d"
        },
        "id": '$i'
    }'

    # Envoi à l'API Zabbix avec le Token dans le Header Authorization
    RESPONSE=$(curl -s -X POST \
      -H "Content-Type: application/json-rpc" \
      -H "Authorization: Bearer $TOKEN" \
      -d "$JSON_DATA" "$ZABBIX_URL")

    # Vérification du résultat
    if echo "$RESPONSE" | grep -q "error"; then
        echo "IP 192.168.0.$i : Déjà existant ou Erreur"
        echo "Détail : $RESPONSE"
    else
        echo "IP 192.168.0.$i : Créé avec succès"
    fi
done

echo "Opération terminée !"