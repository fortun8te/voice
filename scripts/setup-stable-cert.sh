#!/bin/bash
# Create a persistent self-signed code-signing identity called `voice-dev`,
# import it into the login keychain, and trust it for code signing.
#
# RUN THIS ONCE. After it succeeds, future builds sign with the SAME identity →
# same codesign designated requirement → TCC keeps Microphone + Accessibility
# grants across rebuilds. No more "Voice OLD" entries.
#
# This is a workaround for the situation where the Apple Development cert's
# private key isn't available in the login keychain (so `Apple Development:
# michael@knaap.nu` fails with errSecInternalComponent when signing).
#
# Usage:
#   ./scripts/setup-stable-cert.sh
#   # then edit project.yml and set CODE_SIGN_IDENTITY: "voice-dev"
#   # then ./scripts/build-install.sh

set -euo pipefail

CERT_NAME="voice-dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMP_DIR="$(mktemp -d)"
trap "rm -rf $TMP_DIR" EXIT

# Check if it already exists.
if security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
    echo "✅ Identity '${CERT_NAME}' already exists in the keychain. Nothing to do."
    echo ""
    echo "To use it, set in project.yml:"
    echo "    CODE_SIGN_IDENTITY: \"${CERT_NAME}\""
    echo "Then run xcodegen generate && ./scripts/build-install.sh"
    exit 0
fi

echo "→ Generating self-signed code-signing cert '${CERT_NAME}'..."
echo "  (You'll be prompted for your login keychain password once.)"
echo ""

# Generate RSA private key + self-signed cert with codesigning EKU.
# The OID 1.3.6.1.5.5.7.3.3 is id-kp-codeSigning (RFC 5280).
cat > "${TMP_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no

[req_dn]
CN = ${CERT_NAME}
O = Voice Local Dev
C = US

[v3_ca]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMP_DIR}/key.pem" \
    -out    "${TMP_DIR}/cert.pem" \
    -days   3650 \
    -config "${TMP_DIR}/openssl.cnf" 2>/dev/null

# Bundle private key + cert into a single PKCS#12 file (with a throwaway passphrase).
P12_PASS="voice-dev-temp"
openssl pkcs12 -export \
    -inkey "${TMP_DIR}/key.pem" \
    -in    "${TMP_DIR}/cert.pem" \
    -out   "${TMP_DIR}/bundle.p12" \
    -name  "${CERT_NAME}" \
    -passout "pass:${P12_PASS}" \
    -legacy 2>/dev/null || \
openssl pkcs12 -export \
    -inkey "${TMP_DIR}/key.pem" \
    -in    "${TMP_DIR}/cert.pem" \
    -out   "${TMP_DIR}/bundle.p12" \
    -name  "${CERT_NAME}" \
    -passout "pass:${P12_PASS}" 2>/dev/null

# Import into the login keychain WITHOUT an ACL prompt every time we sign.
# -A grants access to ALL apps; -T /usr/bin/codesign grants only codesign.
# We use -T for tighter scope.
security import "${TMP_DIR}/bundle.p12" \
    -k "${KEYCHAIN}" \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security 2>&1 | grep -v "imported." || true

# Some macOS versions require explicitly setting the partition list so codesign
# can use the key without a GUI prompt every time. This DOES prompt for the
# login keychain password once (because it's modifying ACLs).
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$(security default-keychain | awk -F'\"' '{print $2}')" \
    "${KEYCHAIN}" >/dev/null 2>&1 || \
echo "  (set-key-partition-list skipped — codesign may prompt the first time)"

# Verify it's usable.
echo ""
echo "→ Verifying identity is usable for codesigning..."
if security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
    echo "✅ Identity '${CERT_NAME}' is installed and trusted for codesigning."
else
    echo "❌ Identity was imported but doesn't show as codesigning-trusted."
    echo "   Open Keychain Access, find '${CERT_NAME}', double-click → Trust →"
    echo "   set 'Code Signing' to 'Always Trust'. Then re-run."
    exit 1
fi

# Try a smoke-test sign on /bin/ls copy to confirm it actually works without prompting.
SMOKE_BIN="${TMP_DIR}/smoke"
cp /bin/ls "${SMOKE_BIN}"
if codesign --force --sign "${CERT_NAME}" "${SMOKE_BIN}" 2>/dev/null; then
    echo "✅ Smoke-test sign succeeded — no prompts needed."
else
    echo "⚠️  Smoke-test sign failed. macOS may prompt once on first real sign."
    echo "   When the prompt appears, click 'Always Allow'."
fi

echo ""
echo "Now edit project.yml:"
echo "    CODE_SIGN_IDENTITY: \"${CERT_NAME}\""
echo "Then run:"
echo "    xcodegen generate && ./scripts/build-install.sh"
echo ""
echo "Future rebuilds will produce the SAME codesign designated requirement, so"
echo "TCC will keep your Microphone + Accessibility grants. No more re-granting."
