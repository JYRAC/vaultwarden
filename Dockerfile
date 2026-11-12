# Go製IPゲートをビルド
#   gate.go（ゲートと監視）、policy.go（許可リストの読み込み）、rules.go（公開読み取りの例外。
#   Vaultwarden では使わないが、同じソースを共有している）を、Goモジュールとしてビルドする。
#   go.sum は、ビルド時に pgx の版から作る（Goのチェックサムデータベースで改ざんを検証）。
FROM golang:1.27-alpine AS gate-build
# 依存の pgx が、より新しいGoを求める場合に、必要な版を自動で取得する
ENV GOTOOLCHAIN=auto \
    CGO_ENABLED=0
ARG PGX_VERSION=v5.9.2
WORKDIR /src
COPY gate.go policy.go rules.go ./
RUN go mod init gate && \
    go get github.com/jackc/pgx/v5@${PGX_VERSION} && \
    go mod tidy && \
    go build -trimpath -ldflags="-s -w" -o /out/gate .

# NetBird クライアントを取得
FROM alpine:3.24 AS netbird-download
ARG NETBIRD_VERSION=0.81.5
RUN apk add --no-cache curl && \
    curl -fsSL -o /tmp/netbird.tar.gz \
      "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION}_linux_amd64.tar.gz" && \
    mkdir -p /tmp/netbird-bin && \
    tar -xzf /tmp/netbird.tar.gz -C /tmp/netbird-bin netbird

# ※ FROM の版は、手元の最新に合わせること（これは、送ってもらった zip の版）
FROM vaultwarden/server:1.37.5

ARG BAO_VERSION=2.7.2
RUN curl -fsSL -o /tmp/bao.tar.gz \
      "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/openbao_${BAO_VERSION}_linux_amd64.tar.gz" && \
    mkdir -p /tmp/bao-extract && \
    tar -xzf /tmp/bao.tar.gz -C /tmp/bao-extract && \
    mv /tmp/bao-extract/bao /usr/local/bin/bao && \
    chmod +x /usr/local/bin/bao && \
    rm -rf /tmp/bao.tar.gz /tmp/bao-extract

COPY --from=netbird-download /tmp/netbird-bin/netbird /usr/local/bin/netbird
COPY --from=gate-build /out/gate /app/gate

# NetBird の実行確認もここで行う。
RUN chmod +x /usr/local/bin/netbird /app/gate && \
    /usr/local/bin/netbird version

# ゲートが起動するアプリ（Vaultwarden）。秘密ではないので、コードと一緒に版管理する。
#   Vaultwarden は、ゲートの内側（127.0.0.1:3457）だけで待ち受ける。公開ポート（$PORT）はゲートが受ける。
#   Render の環境変数に ROCKET_PORT=10000 が残っていても、GATE_CHILD_ENV が上書きする。
ENV GATE_CHILD_CMD='["/vaultwarden"]' \
    GATE_CHILD_ENV='ROCKET_ADDRESS=127.0.0.1,ROCKET_PORT=3457' \
    GATE_UPSTREAM=127.0.0.1:3457 \
    GATE_UPSTREAM_HEALTH_PATH=/alive \
    GATE_WAIT_READY_SEC=300

# OpenBao の NetBird 向け証明書
COPY openbao/ca.crt /etc/openbao/ca.crt
COPY openbao/agent.hcl /etc/openbao/agent.hcl
COPY openbao/entrypoint.sh /entrypoint.sh
COPY openbao/netbird-up.sh /netbird-up.sh
RUN sed -i 's/\r$//' /entrypoint.sh /netbird-up.sh && chmod +x /entrypoint.sh /netbird-up.sh

ENTRYPOINT ["/entrypoint.sh"]