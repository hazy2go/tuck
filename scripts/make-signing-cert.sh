#!/bin/bash
# Create a local self-signed code-signing certificate ("Tuck Local Signing")
# so macOS keeps Tuck's Accessibility permission across rebuilds.
# The certificate lives only in your login keychain.
set -euo pipefail

NAME="${TUCK_SIGN_ID:-Tuck Local Signing}"
if security find-identity -p codesigning | grep -q "$NAME"; then
	echo "'$NAME' already exists. Nothing to do."
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.cnf <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf \
	-keyout key.pem -out cert.pem 2>/dev/null
PASS="$(openssl rand -hex 12)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASS" 2>/dev/null \
	|| openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASS"
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created '$NAME'. Run ./build.sh. You'll grant Accessibility one last time."
