# Wallet Access

The Canton wallet UI runs on port 8888, bound to `127.0.0.1` only. It is never exposed publicly. Two access methods are supported: SSH tunnel (default) and Cloudflare Tunnel (optional).

---

## SSH Tunnel (default)

Open a tunnel from your local machine to the server:

```bash
ssh -L 8888:127.0.0.1:8888 user@your-server -N
```

Then open in browser:

```
http://wallet.localhost:8888
```

Login: `validator` / `<your password>`

**Notes:**
- Use `http://` explicitly — Chrome may redirect to HTTPS on some versions. Use Firefox if that happens.
- The tunnel must be active before opening the URL.
- Add `-f` to run the tunnel in background: `ssh -fN -L 8888:...`

To access wallet + monitoring in one tunnel:

```bash
ssh -L 8888:127.0.0.1:8888 \
    -L 3001:127.0.0.1:3001 \
    -L 9091:127.0.0.1:9091 \
    user@your-server -N
```

---

## Cloudflare Tunnel (optional)

No open ports. Access from anywhere at `https://wallet.yourdomain.com`.

### Setup

**1. Install cloudflared:**

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
  https://pkg.cloudflare.com/cloudflared focal main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt-get update && sudo apt-get install -y cloudflared
```

**2. Authenticate:**

```bash
cloudflared tunnel login
```

This opens a browser URL — complete auth on Cloudflare dashboard.

**3. Create tunnel:**

```bash
cloudflared tunnel create canton-wallet
```

Note the tunnel ID from the output.

**4. Configure tunnel:**

```bash
mkdir -p ~/.cloudflared
```

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: <your-tunnel-id>
credentials-file: /home/<user>/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: wallet.yourdomain.com
    service: http://127.0.0.1:8888
    originRequest:
      httpHostHeader: wallet.localhost
  - service: http_status:404
```

**5. Add DNS record:**

```bash
cloudflared tunnel route dns canton-wallet wallet.yourdomain.com
```

**6. Start tunnel:**

```bash
cloudflared tunnel run canton-wallet
```

**7. Run as systemd service:**

```bash
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

---

## nginx virtual hosts

The nginx container routes requests by `Host` header. All services share port 8888:

| Host header | Routes to | Auth |
|-------------|-----------|------|
| `wallet.localhost` | `wallet-web-ui:8080` | basic auth |
| `ans.localhost` | `ans-web-ui:8080` | basic auth |
| `validator.localhost` | `validator:10013/metrics` | none |
| `participant.localhost` | `participant:10013/metrics` | none |
| `json-ledger-api.localhost` | `participant:7575` | none |
| `grpc-ledger-api.localhost` | `participant:5001` | none (gRPC) |

API paths (`/api/validator/*`) bypass basic auth — required for JWT-authenticated wallet API calls.

---

## Change wallet password

```bash
# Generate new hash
NEW_HASH=$(openssl passwd -apr1 "yournewpassword")

# Update .htpasswd
HTPASSWD="$HOME/.canton/current/splice-node/docker-compose/validator/nginx/.htpasswd"
echo "validator:$NEW_HASH" > "$HTPASSWD"

# Reload nginx (no downtime)
docker exec splice-validator-nginx-1 nginx -s reload
```

---

## Wallet API (CLI access)

The wallet API is also available directly for scripting:

```bash
# Get JWT token
TOKEN=$(python3 ~/.canton/current/splice-node/docker-compose/validator/get-token.py administrator)

# Check balance
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Host: wallet.localhost" \
  http://127.0.0.1:8888/api/validator/v0/wallet/balance | jq .
```

Or use the toolkit CLI:

```bash
~/canton-validator-toolkit/scripts/transfer.sh balance
~/canton-validator-toolkit/scripts/transfer.sh send --to "PARTY::1220..." --amount 10.0
~/canton-validator-toolkit/scripts/transfer.sh history --limit 20
```

---

## Security notes

- Port 8888 is always `127.0.0.1` only — this is enforced in `compose.yaml` by the toolkit
- Basic auth password is hashed with APR1-MD5 via `openssl passwd -apr1` (no apache2-utils needed)
- JWT tokens use HS256 with secret `unsafe` — safe only because the port is never exposed
- Cloudflare Tunnel creates outbound-only connections — no inbound ports opened on the server
- For Cloudflare Zero Trust access control (email/Google/GitHub auth), configure an Access Application in the Cloudflare dashboard for `wallet.yourdomain.com`

---

## TBD — Advanced

**Zero Trust access policies** — restrict wallet access to specific email addresses or GitHub orgs via Cloudflare Access. No VPN needed, works from mobile.

**mTLS client certificates** — for high-security environments, require a client certificate to access the wallet alongside basic auth.

**Read-only API proxy** — expose a subset of wallet API endpoints publicly (e.g. balance, transaction history) with rate limiting and API key auth, without exposing the full wallet UI.

**Hardware security key (FIDO2)** — use Cloudflare Access with hardware key requirement for wallet login from any device.