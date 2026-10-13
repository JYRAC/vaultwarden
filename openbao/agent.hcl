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

exec {
  command                   = ["/vaultwarden"]
  restart_on_secret_changes = "always"
}