#!/bin/bash
# LocalPort uninstall — run with sudo
set -e

echo "Removing LocalPort system configuration..."

# Remove DNS resolver
rm -f /etc/resolver/test

# Remove pfctl anchor
rm -f /etc/pf.anchors/localport

# Remove localport lines from pf.conf
if grep -q 'localport' /etc/pf.conf 2>/dev/null; then
    sed -i '' '/localport/d' /etc/pf.conf
    pfctl -f /etc/pf.conf 2>/dev/null || true
fi

# Remove launchd plist
launchctl unload /Library/LaunchDaemons/com.localport.pfctl.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.localport.pfctl.plist

# Remove daemon socket
rm -f /tmp/localport-*.sock

echo "LocalPort system configuration removed."
echo "To fully uninstall, also delete:"
echo "  - /Applications/LocalPort.app"
echo "  - ~/.config/localport/"
