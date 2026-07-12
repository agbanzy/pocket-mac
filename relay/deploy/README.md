# Deploying the Pocket Mac relay

The relay is a single static Go binary. Two supported targets:

## Live deployment (current)
- **Endpoint:** `wss://165.227.155.134.sslip.io/ws` · health: `https://165.227.155.134.sslip.io/healthz`
- **Where:** DigitalOcean droplet `pocketmac-relay` (fra1, `s-1vcpu-1gb`, ~$6/mo)
- **TLS:** Caddy + Let's Encrypt via `sslip.io` (the IP-as-hostname trick) — **no domain purchased**.
- **Posture:** the relay binds `127.0.0.1:8080`; Caddy is the only public entry (443) and reverse-proxies to it. The relay is zero-knowledge — it forwards opaque ciphertext and never terminates the E2E crypto.
- The iOS app defaults to this URL (`AppModel.defaultRelayURL`); override with the `com.innoedge.pocketmac.relayURL` UserDefaults key. The Mac helper takes `--relay <wss-url>`.

### Droplet deploy (what produced the live endpoint)
```bash
# 1. build the linux binary
( cd relay && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/relayd-linux ./cmd/relayd )
# 2. create the droplet with your SSH key (fra1, smallest viable)
doctl compute droplet create pocketmac-relay --region fra1 --size s-1vcpu-1gb --image ubuntu-24-04-x64 --ssh-keys <key-id> --wait
# 3. copy the binary + provisioning script, then run it (installs Caddy, writes systemd + Caddyfile, starts both)
scp /tmp/relayd-linux root@<ip>:/usr/local/bin/relayd
scp relay/deploy/provision.sh root@<ip>:/root/provision.sh
ssh root@<ip> "bash /root/provision.sh <ip>"
# 4. verify
curl https://<ip>.sslip.io/healthz     # → ok
```
Redeploy a new binary: rebuild, `scp` it over `/usr/local/bin/relayd`, `ssh root@<ip> systemctl restart pocketmac-relay`.
Tear down: `doctl compute droplet delete pocketmac-relay`.

## Alternative: App Platform (managed)
`app.yaml` is an App Platform spec that runs the container image from the account DOCR. It gives a
managed `*.ondigitalocean.app` domain + TLS with zero server ops, but requires a free registry repo
slot (the account's `docufy` starter registry was at its 5-repo limit, which is why the live
deployment uses a droplet instead). To use it: free a DOCR repo (or upgrade the tier), push
`registry.digitalocean.com/<registry>/pocketmac-relay:latest`, then `doctl apps create --spec relay/deploy/app.yaml`.
