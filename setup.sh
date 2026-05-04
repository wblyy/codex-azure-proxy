#!/bin/bash
# codex-azure-proxy setup script
# Generates fake TLS cert, trusts it in macOS Keychain, installs LaunchAgent.

set -e

PROXY_DIR="$HOME/codex-proxy"
CERTS_DIR="$PROXY_DIR/certs"
PLIST="$HOME/Library/LaunchAgents/com.codex.azure-proxy.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Codex Azure Proxy Setup ==="
echo ""

# ── 1. Check required env vars ──────────────────────────────────────────────
if [ -z "$AZURE_BASE_URL" ] || [ -z "$OPENAI_API_KEY" ]; then
  echo "Error: Please set these environment variables before running setup:"
  echo "  export AZURE_BASE_URL=https://YOUR_RESOURCE.services.ai.azure.com/openai"
  echo "  export OPENAI_API_KEY=YOUR_AZURE_KEY"
  echo "  export AZURE_API_VERSION=2025-04-01-preview  # optional, this is the default"
  exit 1
fi

AZURE_API_VERSION="${AZURE_API_VERSION:-2025-04-01-preview}"

# ── 2. Create directories ────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR"
cp "$SCRIPT_DIR/proxy.js" "$PROXY_DIR/proxy.js"

# ── 3. Generate fake TLS cert ────────────────────────────────────────────────
echo "Generating fake TLS cert for api.openai.com..."
openssl req -x509 -newkey rsa:2048 \
  -keyout "$CERTS_DIR/api.openai.com.key" \
  -out "$CERTS_DIR/api.openai.com.crt" \
  -days 3650 -nodes \
  -subj "/CN=api.openai.com" \
  -addext "subjectAltName=DNS:api.openai.com" 2>/dev/null
echo "  -> $CERTS_DIR/api.openai.com.crt"

# ── 4. Trust cert in macOS Keychain ─────────────────────────────────────────
echo "Trusting cert in macOS Keychain (requires sudo)..."
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  "$CERTS_DIR/api.openai.com.crt"
echo "  -> Trusted"

# ── 5. Install LaunchAgent ───────────────────────────────────────────────────
echo "Installing LaunchAgent..."
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.codex.azure-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>$PROXY_DIR/proxy.js</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENAI_API_KEY</key><string>$OPENAI_API_KEY</string>
    <key>AZURE_BASE_URL</key><string>$AZURE_BASE_URL</string>
    <key>AZURE_API_VERSION</key><string>$AZURE_API_VERSION</string>
    <key>CERTS_DIR</key><string>$CERTS_DIR</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/codex-azure-proxy.log</string>
  <key>StandardOutPath</key><string>/tmp/codex-azure-proxy.log</string>
</dict>
</plist>
EOF
echo "  -> $PLIST"

# ── 6. Start proxy ───────────────────────────────────────────────────────────
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2

# ── 7. Verify ────────────────────────────────────────────────────────────────
echo ""
echo "Verifying proxy..."
RESULT=$(curl -sk --proxy http://127.0.0.1:8765 https://api.openai.com/health 2>&1)
if echo "$RESULT" | grep -q '"ok":true'; then
  echo "  ✓ Proxy running: $RESULT"
else
  echo "  ✗ Proxy check failed: $RESULT"
  echo "  Check logs: tail -f /tmp/codex-azure-proxy.log"
  exit 1
fi

# ── 8. ClashX config reminder ────────────────────────────────────────────────
echo ""
echo "=== Next: Configure ClashX ==="
echo "Add to ~/.config/clash/config.yaml:"
echo ""
echo "  proxies:"
echo "    - name: codex-mitm"
echo "      type: http"
echo "      server: 127.0.0.1"
echo "      port: 8765"
echo ""
echo "  rules:"
echo "    - DOMAIN,api.openai.com,codex-mitm"
echo ""
echo "Then reload ClashX config. Done!"
