# RSA verifier fixture provenance

`crypto_rsa_verify_api.tl` embeds public-only hex fixtures. Normal tests read
only checked-in literals; they do not run OpenSSL, Python, a host crypto
provider, or the network.

The 2048/3072/4096-bit PKCS#1-v1_5/SHA-256 and
PSS/SHA-256/MGF1-SHA-256/32-salt positives are `tcId: 1` from the corresponding
`rsa_signature_{2048,3072,4096}_sha256_test.json` and
`rsa_pss_{2048,3072,4096}_sha256_mgf1_32_test.json` files in
[C2SP/Wycheproof `testvectors_v1`](https://github.com/C2SP/wycheproof/tree/3fa63dd0344abb611f1fb1d77e119938603ea230/testvectors_v1).
The 8192-bit PKCS#1 positive is `tcId: 1` from
`rsa_signature_8192_sha256_test.json` at that same commit. All vector messages
are empty. The public modulus literals remove the source's single DER-positive
sign octet; the RSA core receives canonical unsigned big-endian bytes.

The zero-salt negative is a valid PSS `tcId: 1` from
`rsa_pss_2048_sha256_mgf1_0_test.json` at the same commit, using the same
2048-bit key. The fixed 32-salt verifier must reject it.

The 8192-bit PSS positive was generated offline using OpenSSL 3.6.3 on the
empty message, then checked in as public modulus/signature bytes:

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:8192 -out key.pem
openssl dgst -sha256 -sign key.pem -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 -out sig.bin /dev/null
openssl rsa -in key.pem -noout -modulus
od -An -tx1 -v sig.bin
```

The 2049-bit edge uses a different offline oracle because this OpenSSL build
rounded a `rsa_keygen_bits:2049` request down to 2048. Two primes were generated
with `openssl prime -generate -bits 1025 -hex` and `-bits 1024 -hex`, retrying
until their product had exactly 2049 bits. Python 3 built-in integer `pow` and
`hashlib.sha256` independently formed the RFC 8017 PSS encoded message for the
empty message and salt `00 01 ... 1f`: `emBits=2048`, `emLen=256`,
`DB=00*190 || 01 || salt`, `H=SHA256(00*8 || SHA256("") || salt)`,
`mask=MGF1-SHA256(H,223)`, `EM=(DB xor mask) || H || bc`. With
`e=65537`, `d=e^-1 mod ((p-1)*(q-1))`, the signature was `pow(EM,d,n)` serialized
to exactly 257 bytes. The fixture also pins the expected 257-byte RSAVP1 result
`00 || EM`; an `n-1` signature proves that a nonzero discarded prefix is
rejected through the public verifier.

The source primes/private exponent and temporary OpenSSL key files are not
checked in. The published vectors and independent encoded-message fixture
guard the TypeLisp implementation without a fixture-generation dependency.
