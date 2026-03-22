#!/bin/bash
# LocalPort first-time setup — run with sudo
set -e

TLD="${1:-test}"

# Validate TLD
if [[ ! "$TLD" =~ ^[a-z0-9]+$ ]]; then
    echo "Invalid TLD: $TLD (must be lowercase alphanumeric)"
    exit 1
fi

# Backup pf.conf
cp /etc/pf.conf /etc/pf.conf.localport-backup

# DNS resolver
mkdir -p /etc/resolver
printf 'nameserver 127.0.0.1\nport 5553\n' > "/etc/resolver/$TLD"

# pfctl anchor
cat > /etc/pf.anchors/localport << 'PF'
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 8080
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 8443
PF

# Insert anchor into pf.conf if not already there
if ! grep -q 'localport' /etc/pf.conf; then
    sed -i '' '/rdr-anchor "com.apple/a\
rdr-anchor "localport"\
load anchor "localport" from "/etc/pf.anchors/localport"
' /etc/pf.conf
fi

# Load rules
pfctl -f /etc/pf.conf 2>/dev/null || true
pfctl -e 2>/dev/null || true

# Install launchd plist so pfctl rules survive reboots
cat > /Library/LaunchDaemons/com.localport.pfctl.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.localport.pfctl</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/pfctl</string>
        <string>-f</string>
        <string>/etc/pf.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

launchctl load /Library/LaunchDaemons/com.localport.pfctl.plist 2>/dev/null || true

echo "LocalPort setup complete"
