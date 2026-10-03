#!/bin/bash
# LocalPort uninstall — run as root (the app runs it via the admin prompt).
#
#   uninstall.sh [tld] [dns_port] [ca_root.crt]
#
# Reverses setup.sh and removes LocalPort's local CA from the System keychain.
set -uo pipefail

TLD="${1:-test}"
DNS_PORT="${2:-5553}"
CA_PATH="${3:-}"

echo "Removing LocalPort system configuration..."

# DNS resolvers — only files LocalPort wrote (current TLD, plus the default).
for t in "$TLD" test; do
    f="/etc/resolver/$t"
    if [[ -f "$f" ]] && grep -q "nameserver 127.0.0.1" "$f" && grep -Eq "port ($DNS_PORT|5553)" "$f"; then
        rm -f "$f"
    fi
done

# pf: stop the loader job first so editing pf.conf doesn't re-trigger it.
launchctl bootout system/com.localport.pfctl 2>/dev/null || \
    launchctl unload /Library/LaunchDaemons/com.localport.pfctl.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.localport.pfctl.plist
rm -rf "/Library/Application Support/LocalPort"
rm -f /etc/pf.anchors/localport
if grep -q 'localport' /etc/pf.conf 2>/dev/null; then
    sed -i '' '/localport/d' /etc/pf.conf
    pfctl -f /etc/pf.conf 2>/dev/null || true
fi

# Local CA: the app removes its trust setting (that needs UI access). Older
# versions also put the certificate in the System keychain; delete it.
if [[ -n "$CA_PATH" && -f "$CA_PATH" ]]; then
    SHA1=$(openssl x509 -noout -fingerprint -sha1 -in "$CA_PATH" 2>/dev/null | sed 's/.*=//; s/://g')
    if [[ -n "$SHA1" ]]; then
        security delete-certificate -Z "$SHA1" /Library/Keychains/System.keychain 2>/dev/null || true
    fi
fi

# Remove daemon socket
rm -f /tmp/localport-*.sock

echo "LocalPort system configuration removed."
