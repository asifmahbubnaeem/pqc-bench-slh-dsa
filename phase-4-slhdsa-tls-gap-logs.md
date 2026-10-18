# Phase 4: SLH-DSA TLS Gap — Reference Logs

**Context:** pqc-bench Phase 4 planned to measure SLH-DSA-SHA2-128f cert chain
latency at WAN RTT. The ~17 kB signature was expected to push the cert chain
past TCP initcwnd (14.6 kB), forcing an extra round-trip.

Three failure modes across two nights. All runs on `c7g.large` arm64 Ubuntu
24.04 in us-east-1, consistent with Phase 1–3 infra.

Reproduce by cloning this repo and running `terraform apply` from
`terraform/phase-3/` with the Night 2 take-2 tfvars. The failures surface
within ~35 min of apply time.

---

## Night 1 (Oct 11 2026) — OpenSSL 3.5.0 lists SLH-DSA OIDs but keygen fails

Target: `ami-0439939f24b73421c` (Phase 3 baked AMI, OpenSSL 3.5.0).

### What the registry shows

```
$ /opt/openssl-3.5/bin/openssl list -public-key-algorithms | grep -i slh
  Name: OpenSSL SLH-DSA-SHA2-128f implementation
    IDs: { 2.16.840.1.101.3.4.3.21, id-slh-dsa-sha2-128f, SLH-DSA-SHA2-128f }
  (... all other SLH-DSA variants listed similarly)
```

### What the command does

```
$ /opt/openssl-3.5/bin/openssl genpkey -algorithm SLH-DSA-SHA2-128f -out slh.key
Error: unsupported algorithm
```

**Finding:** OIDs are registered, operations are not implemented. OpenSSL
3.5.0 shipped the OID allocation ahead of the implementation.

**Decision:** bump to OpenSSL 3.5.2 (Aug 2026), which includes the SLH-DSA
keygen/sign/verify implementation.

---

## Night 2 attempt 1 (Oct 15 2026) — OpenSSL 3.5.2 keygen works, nginx can't serve the cert

Target rebuilt from Ubuntu 24.04 base with OpenSSL 3.5.2 from source. ~20
min user-data build. Target reports `/var/lib/pqc-bench-ready`.

### Keygen works

```
$ /opt/openssl-3.5/bin/openssl version
OpenSSL 3.5.2 5 Aug 2025 (Library: OpenSSL 3.5.2 5 Aug 2025)

$ /opt/openssl-3.5/bin/openssl genpkey -algorithm SLH-DSA-SHA2-128f -out /tmp/t.key && echo "SLH-DSA KEYGEN OK"
SLH-DSA KEYGEN OK

$ ls -la /tmp/t.key
-rw------- 1 ubuntu ubuntu 168 Oct 15 08:35 /tmp/t.key
```

### Self-signing works, cert size matches thesis

```
$ /opt/openssl-3.5/bin/openssl req -new -x509 \
    -key /tmp/t.key \
    -out /tmp/t.crt \
    -days 365 \
    -subj "/CN=test"

$ wc -c /tmp/t.crt
23556 /tmp/t.crt
```

Cert chain is ~23 kB — comfortably past the 14.6 kB TCP initcwnd. Phase 4's
premise holds for the data on disk.

### TLS signature algorithm registry does NOT include SLH-DSA

```
$ /opt/openssl-3.5/bin/openssl list -tls-signature-algorithms
ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:ecdsa_secp521r1_sha512:ed25519:ed448:ecdsa_sha224:ecdsa_sha1:ecdsa_brainpoolP256r1tls13_sha256:ecdsa_brainpoolP384r1tls13_sha384:ecdsa_brainpoolP512r1tls13_sha512:rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:rsa_pss_pss_sha256:rsa_pss_pss_sha384:rsa_pss_pss_sha512:rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512:rsa_pkcs1_sha224:rsa_pkcs1_sha1:dsa_sha256:dsa_sha384:dsa_sha512:dsa_sha224:dsa_sha1:mldsa44:mldsa65:mldsa87
```

ML-DSA (3 variants) is in there. SLH-DSA is not. Grep confirms:

```
$ /opt/openssl-3.5/bin/openssl list -tls-signature-algorithms | tr ':' '\n' | grep -i slh
(no output)
```

### nginx cannot load an SLH-DSA cert

Minimal nginx config pointing at the cert generated above:

```
server {
    listen 8443 ssl;
    ssl_certificate /tmp/t.crt;
    ssl_certificate_key /tmp/t.key;
    ssl_protocols TLSv1.3;
    ssl_conf_command SignatureAlgorithms SLH-DSA-SHA2-128f;
    location / { return 200 "ok\n"; }
}
```

```
$ sudo /usr/local/sbin/nginx-pq -t -c /tmp/test-nginx.conf
nginx: [emerg] SSL_CTX_use_certificate("/tmp/t.crt") failed
    (SSL: error:0A0000F7:SSL routines::unknown certificate type)
nginx: configuration file /tmp/test-nginx.conf test failed
```

**Finding:** OpenSSL 3.5.2 has SLH-DSA at the X.509 and crypto layers but
not at the TLS layer. The TLS code path has no handler for an SLH-DSA cert
type.

**Decision:** install oqs-provider 0.12.0-dev to supply the missing TLS
layer.

---

## Night 2 attempt 2 (Oct 15–16 2026) — oqs-provider loads but TLS layer still rejects SLH-DSA certs

Full rebuild: liboqs (shared, from main branch) + oqs-provider 0.12.0-dev
(from main branch), linked against OpenSSL 3.5.2. All installed under
`/opt/openssl-3.5.2/`. ~35 min user-data build. `openssl.cnf` activates both
providers at init.

### Both providers active

```
$ /opt/openssl-3.5/bin/openssl list -providers
Providers:
  default
    name: OpenSSL Default Provider
    version: 3.5.2
    status: active
  oqsprovider
    name: OpenSSL OQS Provider
    version: 0.12.0-dev
    status: active
```

### SLH-DSA entries all come from the default provider, zero from oqs

```
$ /opt/openssl-3.5/bin/openssl list -signature-algorithms | grep -i slh
  { 2.16.840.1.101.3.4.3.20, id-slh-dsa-sha2-128s, SLH-DSA-SHA2-128s } @ default
  { 2.16.840.1.101.3.4.3.21, id-slh-dsa-sha2-128f, SLH-DSA-SHA2-128f } @ default
  { 2.16.840.1.101.3.4.3.22, id-slh-dsa-sha2-192s, SLH-DSA-SHA2-192s } @ default
  { 2.16.840.1.101.3.4.3.23, id-slh-dsa-sha2-192f, SLH-DSA-SHA2-192f } @ default
  { 2.16.840.1.101.3.4.3.24, id-slh-dsa-sha2-256s, SLH-DSA-SHA2-256s } @ default
  { 2.16.840.1.101.3.4.3.25, id-slh-dsa-sha2-256f, SLH-DSA-SHA2-256f } @ default
  { 2.16.840.1.101.3.4.3.26, id-slh-dsa-shake-128s, SLH-DSA-SHAKE-128s } @ default
  { 2.16.840.1.101.3.4.3.27, id-slh-dsa-shake-128f, SLH-DSA-SHAKE-128f } @ default
  { 2.16.840.1.101.3.4.3.28, id-slh-dsa-shake-192s, SLH-DSA-SHAKE-192s } @ default
  { 2.16.840.1.101.3.4.3.29, id-slh-dsa-shake-192f, SLH-DSA-SHAKE-192f } @ default
  { 2.16.840.1.101.3.4.3.30, id-slh-dsa-shake-256s, SLH-DSA-SHAKE-256s } @ default
  { 2.16.840.1.101.3.4.3.31, id-slh-dsa-shake-256f, SLH-DSA-SHAKE-256f } @ default
```

All entries marked `@ default`. **Zero `@ oqsprovider`.** oqs-provider v0.12
has deprecated its own SLH-DSA implementation now that OpenSSL 3.5.2 ships
SLH-DSA natively — it defers to the default provider.

### oqs-provider's lowercase TLS codepoint name fails for keygen

```
$ /opt/openssl-3.5/bin/openssl genpkey -algorithm slhdsasha2128f -out /tmp/t.key
Error initializing slhdsasha2128f context
C0D837B0B8ED0000:error:0308010C:digital envelope routines:inner_evp_generic_fetch:unsupported:crypto/evp/evp_fetch.c:375:Global default library context, Algorithm (slhdsasha2128f : 0), Properties (<null>)
```

The lowercase name (`slhdsasha2128f`) is listed in oqs-provider's
`ALGORITHMS.md` as a TLS codepoint, but not as a keygen algorithm. The
`unsupported` error at `evp_fetch.c:375` confirms no provider claims the
name.

### Keygen succeeds via OpenSSL's native name

```
$ /opt/openssl-3.5/bin/openssl genpkey -algorithm SLH-DSA-SHA2-128f -out /tmp/t.key
$ /opt/openssl-3.5/bin/openssl req -new -x509 \
    -key /tmp/t.key \
    -out /tmp/t.crt \
    -days 365 \
    -subj "/CN=test"
$ wc -c /tmp/t.crt
23487 /tmp/t.crt
```

### s_server fails with the identical TLS error as attempt 1

```
$ /opt/openssl-3.5/bin/openssl s_server \
    -key /tmp/t.key -cert /tmp/t.crt \
    -accept 127.0.0.1:8443 -tls1_3 -www
Using default temp DH parameters
error setting certificate
C0D857A240F70000:error:0A0000F7:SSL routines:ssl_set_cert:unknown certificate type:ssl/ssl_rsa.c:269:
[1]+  Exit 1  /opt/openssl-3.5/bin/openssl s_server -key /tmp/t.key -cert /tmp/t.crt -accept 127.0.0.1:8443 -tls1_3 -www
```

**Finding:** oqs-provider 0.12 handed SLH-DSA ownership back to OpenSSL's
default provider. OpenSSL's default provider has layers 1 (crypto) and 2
(X.509), but not layer 3 (TLS integration). oqs-provider v0.12 does not
fill the TLS layer gap either.

**Decision:** Phase 4 as framed is not reproducible with current public
tooling. Park Phase 4 as an ecosystem-gap discovery; monitor for a future
oqs-provider release that re-registers the TLS codepoints, or for OpenSSL
to extend its default provider's SLH-DSA support into the TLS layer.

---

## Summary: three layers of PQ TLS support

| Layer | What it means | OpenSSL 3.5.2 | + oqs-provider 0.12.0-dev |
|---|---|---|---|
| **1. Cryptographic primitives** | `genpkey`, sign, verify | ✓ SLH-DSA, ML-DSA | ✓ |
| **2. X.509 encoding** | OIDs recognised when parsing cert ASN.1 | ✓ SLH-DSA, ML-DSA | ✓ |
| **3. TLS protocol integration** | `SSL_CTX_use_certificate` accepts, ClientHello sig_algs advertises, CertificateVerify signs | ✗ SLH-DSA, ✓ ML-DSA | ✗ SLH-DSA, ✓ ML-DSA |

ML-DSA has all three layers in OpenSSL 3.5.2 and is production-ready for
TLS deployment. SLH-DSA has layers 1 and 2 only; it's production-ready for
signing APIs (JWT, firmware, package signing) but not for TLS termination
as of October 2026.

---

## How to monitor the gap close

```bash
openssl list -tls-signature-algorithms | tr ':' '\n' | grep slh
```

The day this command prints anything, SLH-DSA at TLS has arrived — either
because OpenSSL's default provider extended into the TLS layer, or because
oqs-provider re-registered the TLS codepoints. pqc-bench Phase 5 will
measure SLH-DSA WAN handshake latency the week after.

## File provenance

Runs captured during pqc-bench Phase 4 Night 2 attempts, Oct 15–16 2026
(UTC+06:00 timestamps). Instance IDs rotated between runs; all exercises
destroyed after capture. Total EC2 cost across the two nights: ~$0.25.
