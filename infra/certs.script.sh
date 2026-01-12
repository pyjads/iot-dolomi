#!/bin/bash
set -euo pipefail
umask 077

########################################
# Cleanup old certs
########################################
rm -rf infra/certs

########################################
# Directory layout
########################################
CERTS_ROOT="infra/certs"
KEYS_ROOT="$CERTS_ROOT/keys"

SERVER_DIR="$CERTS_ROOT/server"

CA_DIR="$CERTS_ROOT/ca"
SERVER_CA_DIR="$CA_DIR/server"
DEVICE_ROOT_CA_DIR="$CA_DIR/deviceroot"
DEVICE_INTER_CA_DIR="$CA_DIR/deviceinter"

SERVER_CA_KEY_DIR="$KEYS_ROOT/serverca"
DEVICE_ROOT_KEY_DIR="$KEYS_ROOT/deviceroot"
DEVICE_INTER_KEY_DIR="$KEYS_ROOT/deviceinter"

DEVICE_DIR="$CERTS_ROOT/devices"
WATCH_DIR="$DEVICE_DIR/watch"
WATERTRT_DIR="$DEVICE_DIR/watertrt"

BUNDLE_DIR="$CERTS_ROOT/bundles"
CLIENT_BUNDLE="$BUNDLE_DIR/client-ca-bundle.crt"

JWT_DIR="$CERTS_ROOT/jwt"
JWT_PRIVATE="$JWT_DIR/jwt-rs256.key"
JWT_PUBLIC="$JWT_DIR/jwt-rs256.pub"

EXT_DIR="$CERTS_ROOT/ext"

mkdir -p \
  "$SERVER_DIR" \
  "$SERVER_CA_DIR" "$DEVICE_ROOT_CA_DIR" "$DEVICE_INTER_CA_DIR" \
  "$SERVER_CA_KEY_DIR" "$DEVICE_ROOT_KEY_DIR" "$DEVICE_INTER_KEY_DIR" \
  "$WATCH_DIR" "$WATERTRT_DIR" \
  "$BUNDLE_DIR" \
  "$JWT_DIR" \
  "$EXT_DIR"

SERVER_SERIAL="$SERVER_CA_DIR/ca.srl"
DEVICE_ROOT_SERIAL="$DEVICE_ROOT_CA_DIR/root-ca.srl"

########################################
# CONFIGURATION
########################################
COUNTRY="DE"
STATE="BE"
ORG="dolomi"

NUM_WATER_DEVICES=3
NUM_WATCH_DEVICES=3

INTER_EXT="$EXT_DIR/inter-ca.ext"
DEVICE_EXT="$EXT_DIR/device.ext"

########################################
# 1. Generate Server CA + TLS Cert
########################################
echo "[*] Generating Server CA..."
openssl genrsa -out "$SERVER_CA_KEY_DIR/ca.key" 4096
openssl req -x509 -new -nodes -key "$SERVER_CA_KEY_DIR/ca.key" -sha256 -days 3650 \
  -subj "/C=US/ST=CA/O=MyServerCA/CN=server-ca.local" \
  -out "$SERVER_CA_DIR/ca.crt"

echo "[*] Generating Server TLS Certificate..."
openssl genrsa -out "$SERVER_DIR/server.key" 2048
openssl req -new -key "$SERVER_DIR/server.key" \
  -subj "/C=US/ST=CA/O=MyServer/CN=localhost" \
  -out "$SERVER_DIR/server.csr"

openssl x509 -req -in "$SERVER_DIR/server.csr" \
  -CA "$SERVER_CA_DIR/ca.crt" -CAkey "$SERVER_CA_KEY_DIR/ca.key" \
  -CAserial "$SERVER_SERIAL" -CAcreateserial \
  -out "$SERVER_DIR/server.crt" -days 825 -sha256 -outform PEM

########################################
# 2. Generate Device Root CA
########################################
echo "[*] Generating Device Root CA..."
openssl genrsa -out "$DEVICE_ROOT_KEY_DIR/root-ca.key" 4096
openssl req -x509 -new -nodes -key "$DEVICE_ROOT_KEY_DIR/root-ca.key" -sha256 -days 3650 \
  -subj "/C=$COUNTRY/ST=$STATE/O=$ORG/CN=dolomi.root.local" \
  -out "$DEVICE_ROOT_CA_DIR/root-ca.crt"

########################################
# 3. Extensions
########################################
cat > "$INTER_EXT" <<__INTER_EXT__
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
__INTER_EXT__

cat > "$DEVICE_EXT" <<__DEVICE_EXT__
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
__DEVICE_EXT__

########################################
# 4. Functions
########################################
generate_intermediate_ca() {
  local NAME=$1
  local CN="$ORG.$NAME.local"

  local KEY_PATH="$DEVICE_INTER_KEY_DIR/$NAME.key"
  local CSR_PATH="$DEVICE_INTER_KEY_DIR/$NAME.csr"
  local CRT_PATH="$DEVICE_INTER_CA_DIR/$NAME.crt"

  echo "[*] Generating intermediate CA for $NAME..."
  openssl genrsa -out "$KEY_PATH" 4096
  openssl req -new -key "$KEY_PATH" \
    -subj "/C=$COUNTRY/ST=$STATE/O=$ORG/CN=$CN" \
    -out "$CSR_PATH"

  openssl x509 -req -in "$CSR_PATH" \
    -CA "$DEVICE_ROOT_CA_DIR/root-ca.crt" -CAkey "$DEVICE_ROOT_KEY_DIR/root-ca.key" \
    -CAserial "$DEVICE_ROOT_SERIAL" -CAcreateserial \
    -out "$CRT_PATH" -days 1825 -sha256 \
    -extfile "$INTER_EXT" -outform PEM
}

generate_device_cert() {
  local NAME=$1        # watertrt or watch
  local NUM=$2
  local OUT_DIR="$DEVICE_DIR/$NAME"

  local DEVICE_ID
  DEVICE_ID=$(printf "x%08d" "$NUM")

  local CN="iot-${NAME}-${DEVICE_ID}"
  local KEY_PATH="$OUT_DIR/$DEVICE_ID.key"
  local CSR_PATH="$OUT_DIR/$DEVICE_ID.csr"
  local CRT_PATH="$OUT_DIR/$DEVICE_ID.crt"
  local SERIAL_PATH="$DEVICE_INTER_CA_DIR/$NAME.srl"

  echo "[*] Generating device cert for $NAME/$DEVICE_ID..."
  openssl genrsa -out "$KEY_PATH" 2048
  openssl req -new -key "$KEY_PATH" \
    -subj "/C=$COUNTRY/ST=$STATE/O=$ORG/CN=$CN" \
    -out "$CSR_PATH"

  openssl x509 -req -in "$CSR_PATH" \
    -CA "$DEVICE_INTER_CA_DIR/$NAME.crt" -CAkey "$DEVICE_INTER_KEY_DIR/$NAME.key" \
    -CAserial "$SERIAL_PATH" -CAcreateserial \
    -out "$CRT_PATH" -days 730 -sha256 \
    -extfile "$DEVICE_EXT" -outform PEM
}

########################################
# 5. Generate Intermediates + Devices
########################################
generate_intermediate_ca "watertrt"
for i in $(seq 1 $NUM_WATER_DEVICES); do
  generate_device_cert "watertrt" "$i"
done

generate_intermediate_ca "watch"
for i in $(seq 1 $NUM_WATCH_DEVICES); do
  generate_device_cert "watch" "$i"
done

########################################
# 6. Combine Intermediates for Kong
########################################
echo "[*] Creating combined CA bundle for Kong..."
cat "$DEVICE_INTER_CA_DIR/watertrt.crt" "$DEVICE_INTER_CA_DIR/watch.crt" "$DEVICE_ROOT_CA_DIR/root-ca.crt" > "$CLIENT_BUNDLE"

########################################
# 7. Generate JWT RS256 Keys
########################################
echo "[*] Generating JWT RS256 keypair..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$JWT_PRIVATE"
openssl rsa -in "$JWT_PRIVATE" -pubout -out "$JWT_PUBLIC"

########################################
# Done
########################################
echo "✅ All certs generated!"
echo "   - Server TLS cert + key: $SERVER_DIR/"
echo "   - Server CA cert: $SERVER_CA_DIR/"
echo "   - Server CA key: $SERVER_CA_KEY_DIR/"
echo "   - Device Root CA: $DEVICE_ROOT_CA_DIR/"
echo "   - Device Intermediates: $DEVICE_INTER_CA_DIR/"
echo "   - Kong client bundle: $CLIENT_BUNDLE"
echo "   - JWT private key: $JWT_PRIVATE"
echo "   - JWT public key:  $JWT_PUBLIC"
