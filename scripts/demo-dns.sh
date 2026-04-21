#!/usr/bin/env bash
# Demo helpers for Kuadrant DNSPolicy flow on macOS.
#
# Usage:
#   demo-dns.sh show
#   demo-dns.sh wait-route53 [empty|populated]
#   demo-dns.sh wait-dns <hostname>
#   demo-dns.sh flush
#   demo-dns.sh ready <hostname>      # wait-route53 populated + flush + wait-dns
#   demo-dns.sh reset <hostname>      # flush + wait-route53 empty
#
# Env vars (with defaults):
#   ZONE_NAME   default: demo.leonlevy.lol
#   DNS_SERVER  default: 1.1.1.1

set -euo pipefail

ZONE_NAME="${ZONE_NAME:-demo.leonlevy.lol}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"

get_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[0].Id" --output text
}

cmd_show() {
  local zone_id
  zone_id=$(get_zone_id)
  aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --no-cli-pager \
    --query 'ResourceRecordSets[].[Name, Type, TTL, join(`, `, ResourceRecords[].Value)]' \
    --output table
}

cmd_wait_route53() {
  local target="${1:-populated}"
  local zone_id
  zone_id=$(get_zone_id)
  echo "Waiting for Route53 to be $target..."
  while true; do
    local count
    count=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --no-cli-pager \
      --query 'length(ResourceRecordSets[?Type!=`NS` && Type!=`SOA`])' --output text)
    case "$target" in
      empty)     [[ "$count" == "0" ]] && break ;;
      populated) [[ "$count" != "0" ]] && break ;;
      *) echo "Unknown target: $target (use 'empty' or 'populated')" >&2; exit 2 ;;
    esac
    sleep 2
  done
  echo "Route53 is $target."
}

cmd_wait_dns() {
  local host="${1:?hostname required}"
  echo "Waiting for DNS to resolve $host to an IP..."
  until dig +short "$host" @"$DNS_SERVER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
    sleep 2
  done
  echo "DNS resolves."
}

cmd_flush() {
  echo "Flushing macOS DNS caches..."
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  sudo killall mDNSResponderHelper 2>/dev/null || true
  sudo killall mDNSResponder 2>/dev/null || true
  echo "Flushed."
}

# Composite: wait for Kuadrant + flush local caches + verify resolution
cmd_ready() {
  local host="${1:?hostname required}"
  cmd_wait_route53 populated
  cmd_flush
  cmd_wait_dns "$host"
  # Warm the getaddrinfo path curl uses
  dscacheutil -q host -a name "$host" >/dev/null 2>&1 || true
  echo "Ready: $host should now curl successfully."
}

# Composite: wait for Route53 to drain + flush local caches
cmd_reset() {
  cmd_wait_route53 empty
  cmd_flush
  echo "Reset complete: no records in Route53, local caches cleared."
}

case "${1:-}" in
  show)         shift; cmd_show "$@" ;;
  wait-route53) shift; cmd_wait_route53 "$@" ;;
  wait-dns)     shift; cmd_wait_dns "$@" ;;
  flush)        shift; cmd_flush ;;
  ready)        shift; cmd_ready "$@" ;;
  reset)        shift; cmd_reset "$@" ;;
  *)
    echo "Usage: $0 {show|wait-route53 [empty|populated]|wait-dns <host>|flush|ready <host>|reset <host>}" >&2
    exit 2
    ;;
esac