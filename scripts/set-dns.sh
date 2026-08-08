#!/usr/bin/env bash
# Point the desktop's DNS record at an address, creating it if absent.
#
# The record is UPDATED IN PLACE and never deleted. Deleting it on every
# teardown was causing resolvers to cache NXDOMAIN, so the hostname stayed
# broken for the length of the zone's negative-cache TTL even after the
# desktop came back.
#
# When the desktop is down the record is parked on 192.0.2.1 - RFC 5737
# TEST-NET-1, permanently unroutable and unclaimable. That matters: parking it
# on a released AWS elastic IP would invite a subdomain takeover, where someone
# else's content is served from this hostname under a certificate for it.
#
# Usage: set-dns.sh <fqdn> <ip>
set -euo pipefail

FQDN="${1:?usage: set-dns.sh <fqdn> <ip>}"
IP="${2:?usage: set-dns.sh <fqdn> <ip>}"
ZONE="${FQDN#*.}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is not set}"

api() { curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" "$@"; }

ZID=$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")')
[ -n "$ZID" ] || { echo "FATAL: zone $ZONE not found"; exit 1; }

RID=$(api "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records?name=$FQDN&type=A" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result") or []; print(r[0]["id"] if r else "")')

BODY=$(python3 -c 'import json,sys; print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"ttl":60,"proxied":False,"comment":"ephemeral desktop - updated in place, never deleted"}))' "$FQDN" "$IP")

if [ -n "$RID" ]; then
  OK=$(api -X PATCH -d "$BODY" "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records/$RID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')
  echo "updated $FQDN -> $IP (success=$OK)"
else
  OK=$(api -X POST -d "$BODY" "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')
  echo "created $FQDN -> $IP (success=$OK)"
fi
