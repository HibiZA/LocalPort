#!/bin/bash
# LocalPort system setup — run as root (the app runs it via the admin prompt).
#
#   setup.sh <tld> <http_port> <https_port> <dns_port>
#
# Installs:
#   /etc/resolver/<tld>                         *.<tld> -> LocalPort's DNS responder
#   /etc/pf.anchors/localport                   80/443 -> Caddy's ports on loopback
#   /Library/Application Support/LocalPort/pf-load.sh
#   /Library/LaunchDaemons/com.localport.pfctl.plist
#       re-applies the pf rules at boot and whenever /etc/pf.conf changes
#       (macOS updates reset it), and enables pf, which is off at boot.
#
# The app trusts the local CA itself: macOS only lets a process with UI
# access change admin trust settings, and this script has none.
set -euo pipefail

TLD="${1:-test}"
HTTP_PORT="${2:-47080}"
HTTPS_PORT="${3:-47443}"
DNS_PORT="${4:-5553}"

if [[ ! "$TLD" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Invalid TLD: $TLD" >&2
    exit 1
fi
for p in "$HTTP_PORT" "$HTTPS_PORT" "$DNS_PORT"; do
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        echo "Invalid port: $p" >&2
        exit 1
    fi
done

SUPPORT_DIR="/Library/Application Support/LocalPort"
LOADER="$SUPPORT_DIR/pf-load.sh"
PLIST="/Library/LaunchDaemons/com.localport.pfctl.plist"

# Keep one pristine backup of pf.conf from before LocalPort touched it.
if [[ ! -f /etc/pf.conf.localport-backup ]]; then
    cp /etc/pf.conf /etc/pf.conf.localport-backup
fi

# DNS resolver
mkdir -p /etc/resolver
printf '# Managed by LocalPort\nnameserver 127.0.0.1\nport %s\n' "$DNS_PORT" > "/etc/resolver/$TLD"

# pf anchor: redirect the standard ports to Caddy on loopback.
cat > /etc/pf.anchors/localport <<PF
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port $HTTP_PORT
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port $HTTPS_PORT
PF

# Loader: (re)insert the anchor into pf.conf if missing, load, enable pf.
mkdir -p "$SUPPORT_DIR"
cat > "$LOADER" <<'LOADER'
#!/bin/bash
# Managed by LocalPort — see setup.sh.
if ! grep -q 'anchor "localport"' /etc/pf.conf; then
    sed -i '' '/rdr-anchor "com.apple/a\
rdr-anchor "localport"\
load anchor "localport" from "/etc/pf.anchors/localport"
' /etc/pf.conf
fi
/sbin/pfctl -f /etc/pf.conf 2>/dev/null || true
/sbin/pfctl -e 2>/dev/null || true   # exits non-zero if already enabled
LOADER
chmod 755 "$LOADER"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.localport.pfctl</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$LOADER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/etc/pf.conf</string>
    </array>
</dict>
</plist>
PLIST

# Replace any previously loaded version of the job, then apply now.
launchctl bootout system/com.localport.pfctl 2>/dev/null || true
launchctl bootstrap system "$PLIST" 2>/dev/null || true
/bin/bash "$LOADER"

echo "LocalPort setup complete"
