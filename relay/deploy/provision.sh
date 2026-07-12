#!/usr/bin/env bash
# Provision the Pocket Mac relay droplet: Caddy (Let's Encrypt TLS via sslip.io) → relay on :8080.
set -e
IP="$1"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -qq
apt-get install -y -qq caddy >/dev/null

chmod +x /usr/local/bin/relayd

cat >/etc/systemd/system/pocketmac-relay.service <<EOF
[Unit]
Description=Pocket Mac zero-knowledge relay
After=network.target
[Service]
# Bind to localhost only; Caddy is the sole public entry point (TLS terminates there).
ExecStart=/usr/local/bin/relayd -addr 127.0.0.1:8080 -trust-forwarded-for -rendezvous-timeout 120s
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/caddy/Caddyfile <<EOF
${IP}.sslip.io {
    reverse_proxy localhost:8080
}
EOF

systemctl daemon-reload
systemctl enable --now pocketmac-relay
systemctl reload caddy 2>/dev/null || systemctl restart caddy
sleep 1
systemctl is-active pocketmac-relay && echo "relay: active"
systemctl is-active caddy && echo "caddy: active"
echo "SETUP_DONE"
