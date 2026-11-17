#!/bin/sh
set -e
umask 077

if [ -z "${OPENBAO_WRAPPED_TOKEN:-}" ]; then
  echo "OPENBAO_WRAPPED_TOKEN is not set" >&2
  exit 1
fi

# 接続先:
#   OPENBAO_NB_ADDR     OpenBao の NetBird 側の宛先。例 https://100.74.x.y:8210（IP 指定。名前は引けない）
#   NB_SETUP_KEY        NetBird の使い捨てキー（Actions がデプロイのたびに作って、Render に渡す）
NB_ADDR="${OPENBAO_NB_ADDR:-}"
NB_SNI="${OPENBAO_NB_SERVER_NAME:-openbao.netbird.cloud}"

export BAO_CLIENT_TIMEOUT=30s

VIA=""

# NetBird 経由: SOCKS5（127.0.0.1:1080）に通し、ピン留めした証明書で、この名前を確認する。
use_netbird() {
  export HTTPS_PROXY=socks5://127.0.0.1:1080 https_proxy=socks5://127.0.0.1:1080
  export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
  export BAO_CACERT=/etc/openbao/ca.crt
  export BAO_TLS_SERVER_NAME="$NB_SNI"
  export BAO_ADDR="$NB_ADDR"
  VIA=netbird
}

# OpenBao へは、NetBird 経由だけ（公開側は、閉じた）。接続できなければ、起動を止める。
if [ -z "$NB_ADDR" ] || [ -z "${NB_SETUP_KEY:-}" ]; then
  echo "NB: OPENBAO_NB_ADDR か NB_SETUP_KEY がありません。OpenBao の公開側は閉じたので、接続できません（デプロイのワークフローが、キーを作れたかを確認）" >&2
  exit 1
fi
if ! /netbird-up.sh; then
  echo "NB: NetBird に接続できませんでした。OpenBao の公開側は閉じたので、接続できません（NetBird のポリシー、OpenBao の起動、setup key を確認）" >&2
  exit 1
fi
NB_OK=1
use_netbird
# キーは、もう使わない。アプリ側の環境に残さない。
unset NB_SETUP_KEY

# Casdoor（SSO）への、サーバー側の通信（発見文書、トークン、ユーザー情報、鍵）は、NetBird 経由で、Casdoor の内部口 A に出す。
#   CASDOOR_NB_ADDR  内部口 A の、NetBird の IP:ポート（Casdoor の固定ピアの IP:8443。IPv4 のみ）。空だと、SSO は使えない。
# Vaultwarden は、発見文書に書かれた公開の URL（https://auth.jyrac.stki.org/...）に通信するので、URL は変えずに、
#   1. /etc/hosts で、この名前を 127.0.0.1 に向け、
#   2. nbtcp が、127.0.0.1:443 で受けて、NetBird の SOCKS5 経由で、内部口 A に、バイトをそのまま流す（TLS は終わらせない）。
#   3. Vaultwarden が、Casdoor と直接 TLS で話し、名前 auth.jyrac.stki.org と、システムの信頼する証明書
#      （ルート入り。Dockerfile で追加）で、検証する。検証は、切らない。
# ブラウザが開く認可の URL は、公開のまま（利用者の通信は、内部口を通さない。/etc/hosts は、このコンテナの中だけ）。
# どれかが使えなければ、SSO のログインができない（公開側へは、戻らない。Casdoor の公開側は、IP 制限で、届かない）。アプリ本体は、起動する。
CASDOOR_HOST="${CASDOOR_HOSTNAME:-auth.jyrac.stki.org}"
CASDOOR_VIA=none
if [ -n "${CASDOOR_NB_ADDR:-}" ]; then
  nbtcp >&2 &
  if ! nbtcp --wait-listen; then
    echo "NB: 127.0.0.1:443 で待ち受けられませんでした。SSO のログインができません" >&2
  elif ! echo "127.0.0.1 $CASDOOR_HOST" >> /etc/hosts 2>/dev/null; then
    echo "NB: /etc/hosts に書けませんでした。SSO のログインができません" >&2
  else
    ( nbtcp --check >&2 || echo "NB: Casdoor の内部口に NetBird 経由で届きません。SSO のログインができません" >&2 ) &
    CASDOOR_VIA=netbird
  fi
else
  echo "NB: CASDOOR_NB_ADDR が空です。SSO のログインができません" >&2
fi
echo "CASDOOR_VIA=$CASDOOR_VIA host=$CASDOOR_HOST"

unwrap() {
  bao unwrap -field=token "$OPENBAO_WRAPPED_TOKEN" 2>/tmp/unwrap.err
}

REAL_TOKEN=$(unwrap) || REAL_TOKEN=""
if [ -z "$REAL_TOKEN" ]; then
  echo "NB: NetBird 経由の unwrap に失敗しました（公開側へは、戻りません）" >&2
  echo "unwrap failed: $(tail -n 3 /tmp/unwrap.err | tr '\n' ' ')" >&2
  exit 1
fi

printf '%s' "$REAL_TOKEN" > /tmp/vault-token

# Vaultwarden の RSA 鍵を OpenBao から取り出す（unwrap と同じ経路を使う。BAO_ADDR などは、上で設定済み）。
mkdir -p /data
BAO_TOKEN="$REAL_TOKEN" bao kv get -mount=kv \
  -field=rsa_key_pem secrets/vaultwarden/config > /data/rsa_key.pem

if [ ! -s /data/rsa_key.pem ]; then
  echo "failed to fetch rsa key" >&2
  exit 1
fi
chmod 600 /data/rsa_key.pem

unset REAL_TOKEN OPENBAO_WRAPPED_TOKEN

# Agent の接続設定（vault ブロック）は、経路によって変わるので、ここで作って、agent.hcl の前に付ける。
{
  echo 'vault {'
  echo "  address = \"$BAO_ADDR\""
  if [ "$VIA" = "netbird" ]; then
    echo '  ca_cert         = "/etc/openbao/ca.crt"'
    echo "  tls_server_name = \"$NB_SNI\""
  fi
  echo '}'
  echo
  cat /etc/openbao/agent.hcl
} > /tmp/agent.hcl

echo "OPENBAO_VIA=$VIA addr=$BAO_ADDR"
exec bao agent -config=/tmp/agent.hcl
