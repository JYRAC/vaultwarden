#!/bin/sh
set -e

BAO_URL="https://openbao.jyrac.stki.org"

if [ -z "$OPENBAO_WRAPPED_TOKEN" ]; then
  echo "OPENBAO_WRAPPED_TOKEN is not set" >&2
  exit 1
fi

REAL_TOKEN=$(bao unwrap -address="$BAO_URL" -field=token "$OPENBAO_WRAPPED_TOKEN")

if [ -z "$REAL_TOKEN" ]; then
  echo "unwrap failed" >&2
  exit 1
fi

echo "$REAL_TOKEN" > /tmp/vault-token

mkdir -p /data
BAO_TOKEN="$REAL_TOKEN" bao kv get -address="$BAO_URL" -mount=kv \
  -field=rsa_key_pem secrets/vaultwarden/config > /data/rsa_key.pem

if [ ! -s /data/rsa_key.pem ]; then
  echo "failed to fetch rsa key" >&2
  exit 1
fi
chmod 600 /data/rsa_key.pem

exec bao agent -config=/etc/openbao/agent.hcl