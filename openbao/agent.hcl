vault {
  address = "https://openbao.jyrac.stki.org"
}

auto_auth {
  method {
    type = "token_file"
    config = {
      token_file_path = "/tmp/vault-token"
    }
  }
}

env_template "DATABASE_URL" {
  contents = "{{ with secret \"database/creds/vaultwarden\" }}postgresql://{{ .Data.username }}.kuajmlczxracqobxkzee:{{ .Data.password }}@aws-0-us-west-2.pooler.supabase.com:5432/postgres?sslmode=require{{ end }}"
}

env_template "ADMIN_TOKEN" {
  contents = "{{ with secret \"kv/data/secrets/vaultwarden/config\" }}{{ .Data.data.admin_token }}{{ end }}"
}

env_template "SSO_CLIENT_SECRET" {
  contents = "{{ with secret \"kv/data/secrets/vaultwarden/config\" }}{{ .Data.data.sso_client_secret }}{{ end }}"
}

# ゲート専用の、読み取りだけのDB資格情報（Vaultwarden本体のロールとは別）。
# GATE_ で始まる環境変数は、ゲートが Vaultwarden の子プロセスには渡さない。
env_template "GATE_DB_USER" {
  contents = "{{ with secret \"database/creds/gate-reader\" }}{{ .Data.username }}.kuajmlczxracqobxkzee{{ end }}"
}

env_template "GATE_DB_PASSWORD" {
  contents = "{{ with secret \"database/creds/gate-reader\" }}{{ .Data.password }}{{ end }}"
}

# Vaultwarden本体は、ゲートが起動する（Dockerfile の GATE_CHILD_CMD）。
exec {
  command                   = ["/app/gate"]
  restart_on_secret_changes = "always"
}
