# iot-dolomi

# mTLS Authentication for IoT Devices with Kong

This project demonstrates how to secure IoT device APIs using **mutual TLS (mTLS)** and **certificate-to-JWT** authentication in **Kong Gateway**.

Each device presents a client certificate issued by a device-specific Intermediate CA. Kong verifies the certificate, maps it to a trusted CA, and converts the certificate identity into a **short-lived JWT** that is passed to upstream services.

This provides:

* Hardware-bound device identity
* Zero shared secrets on devices
* Centralized trust and revocation
* Fine-grained authorization (roles and scopes)

---

## Architecture

```
+------------------+        mTLS        +-------------------+       JWT       +------------------+
|  IoT Device      |  <----------------> |   Kong Gateway    |  ------------> |  IoT Backend     |
| (cert + key)     |                    | (cert-to-jwt)     |                 | (JWT auth)      |
+------------------+                    +-------------------+                 +------------------+
        |                                           |
        |                 Trust via CA              |
        +-------------------------------------------+
```

Each device connects using a **TLS client certificate**. Kong validates the certificate against trusted Intermediate CAs and converts that cryptographic identity into a JWT that downstream services can verify.

---

## Certificate Model

```
Root CA
├── Server CA
│   └── Kong TLS certificate
└── Device Intermediate CAs
    ├── watertrt CA
    │   └── watertrt devices (x00000001, x00000002, ...)
    └── watch CA
        └── watch devices (x00000001, x00000002, ...)
```

Each product line has its own Intermediate CA.
Revoking a product line is done by removing its CA from Kong.

---

## Directory Layout

```
infra/
├── certs.script.sh
├── certs/
│   ├── ca/
│   │   ├── server/
│   │   └── deviceinter/
│   │       ├── watertrt.crt
│   │       └── watch.crt
│   └── devices/
│       ├── watertrt/
│       └── watch/
└── docker-compose.yml
```

---

## 1. Generate Certificates

Generate all PKI material:

```bash
make certs
```

This creates:

* Root CA
* Server CA
* Device Intermediate CAs
* Per-device certificates

---

## 2. Start Kong

Run database migrations:

```bash
make migration
```

Start Kong:

```bash
make run
```

Kong endpoints:

* Proxy (HTTPS): `https://localhost:8443`
* Admin API: `http://localhost:8001`

---

## 3. Upload Trusted Device CAs

Register device CAs with Kong:

```bash
make upload
```

This uploads:

| CA       | Tag          |
| -------- | ------------ |
| watertrt | iot-watertrt |
| watch    | iot-watch    |

Kong uses these tags to associate certificates with device families.

---

## 4. Configure Device Services

```bash
make setup
```

Two services are created:

| Service      | Host           | Path                 | Roles         | Scope      |
| ------------ | -------------- | -------------------- | ------------- | ---------- |
| iot-watertrt | watertrt.local | /secure-iot-watertrt | watertrt, iot | write      |
| iot-watch    | watch.local    | /secure-iot-watch    | watch, iot    | read,write |

Each service installs the **cert-to-jwt** plugin.

---

## How cert-to-jwt Works

When a device connects:

1. Kong validates the TLS client certificate
2. Kong checks that it chains to a trusted CA
3. Kong generates a signed JWT

Example JWT payload:

```json
{
  "sub": "CN=x00000002",
  "iss": "dolomi.watertrt.kong.issuer",
  "roles": ["watertrt", "iot"],
  "scope": "write",
  "exp": 300
}
```

Kong injects the token into:

```
Authorization: Bearer <jwt>
```

Backends only validate JWTs — they never need to handle certificates.

---

## 5. Test Watertrt Device

```bash
make waterc
```

This sends a request using:

* Watertrt device certificate
* Device private key
* Kong server CA
* `Host: watertrt.local`

A valid device receives `200 OK` and the request is forwarded with a JWT.

---

## 6. Test Watch Device

```bash
make watchc
```

Same flow using Watch credentials.

---

## Security Guarantees

| Property         | How it is enforced              |
| ---------------- | ------------------------------- |
| Device identity  | X.509 certificate               |
| No shared secret | Private key never leaves device |
| Revocation       | Remove cert or CA from Kong     |
| Isolation        | Separate CA per product line    |
| Short-lived auth | JWT expires in 300 seconds      |
| Least privilege  | Roles and scopes in JWT         |

---

## Why This Beats API Keys

| API Keys       | mTLS + cert-to-JWT |
| -------------- | ------------------ |
| Copyable       | Hardware-bound     |
| Hard to rotate | Re-issue certs     |
| Shared secrets | None               |
| No identity    | Per-device ID      |
| Flat access    | Roles + scopes     |

---

## Summary

This setup implements **zero-trust IoT authentication**:

Devices authenticate with cryptography, Kong acts as the trust and policy authority, backends receive standard JWTs, and compromised devices can be revoked instantly.
