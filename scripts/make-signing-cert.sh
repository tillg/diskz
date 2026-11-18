#!/bin/sh
# Creates the self-signed code-signing certificate "diskz-dev" in the login keychain (once).
# A stable signing identity lets macOS keep Diskz.app's Full Disk Access grant across rebuilds.
# Remove it again with:  security delete-identity -c diskz-dev
set -eu
NAME=diskz-dev
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "certificate $NAME already exists"
    exit 0
fi
# Key material is created in a temp directory and deleted afterwards; it never touches the repo.
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -name "$NAME" -out "$DIR/id.p12" -passout pass:diskz
security import "$DIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P diskz -T /usr/bin/codesign
echo "created certificate $NAME"
