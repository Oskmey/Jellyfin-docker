#!/bin/sh
set -eu

OUTPUT_FILE="/tmp/nginx-lan-allowlist.conf"

: "${NGINX_ALLOWED_CIDRS:=127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7,fe80::/10}"

{
  echo "# Generated from NGINX_ALLOWED_CIDRS"
  old_ifs="${IFS}"
  IFS=','
  for cidr in ${NGINX_ALLOWED_CIDRS}; do
    trimmed_cidr="$(printf '%s' "${cidr}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "${trimmed_cidr}" ]; then
      printf 'allow %s;\n' "${trimmed_cidr}"
    fi
  done
  IFS="${old_ifs}"
  printf 'deny all;\n'
} > "${OUTPUT_FILE}"
