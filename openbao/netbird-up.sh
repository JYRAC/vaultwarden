#!/bin/sh
# NetBird（netstack）に参加する。クライアント役なので、受信用の転送（NB_ENABLE_NETSTACK_LOCAL_FORWARDING）は、
# 有効にしない（このコンテナの localhost を、NetBird に出さない）。
# 成功したら 0、できなければ 1 を返す。ログには、セットアップキーを出さない。
export NB_USE_NETSTACK_MODE=true
export NB_CONFIG=/tmp/nb/config.json

mkdir -p /tmp/nb
chmod 700 /tmp/nb

mask() { sed "s|${NB_SETUP_KEY}|***|g"; }

netbird service run > /tmp/nb/service.log 2>&1 &

# 常駐プロセスの起動待ち（最大30秒）
i=0
while [ "$i" -lt 30 ]; do
  netbird status >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

if ! netbird up --setup-key "$NB_SETUP_KEY" --hostname "${NB_HOSTNAME:-vaultwarden}" > /tmp/nb/up.log 2>&1; then
  echo "NB: netbird up に失敗しました:" >&2
  tail -n 5 /tmp/nb/up.log | mask >&2
  exit 1
fi

# 接続待ち（最大40秒）
i=0
while [ "$i" -lt 40 ]; do
  if netbird status 2>/dev/null | grep -qi "Management: Connected"; then
    echo "NB: connected ip=$(netbird status --ipv4 2>/dev/null || echo unknown)"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

echo "NB: 接続の確認が、時間切れになりました" >&2
tail -n 5 /tmp/nb/service.log | mask >&2
exit 1
