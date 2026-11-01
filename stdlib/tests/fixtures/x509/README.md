# Independent certificate fixtures

These public test certificates were generated once with OpenSSL 3.6.5
(2026-09-29), independently of the TypeLisp parser. Test compilation and runtime
read only the pinned data and never invoke OpenSSL or another parser. Private
keys are not part of these fixtures. The certificates are test data, not trust
anchors.

The four `*.hex.in` files contain lowercase hexadecimal DER (no newline).
`rsa.pem.in` is the same RSA certificate in PEM. All have serial 42, validity
2026-11-01 to 2027-11-01, subject/issuer CN `TypeLisp parser fixture`, O
`Independent test data`, and these extensions: SKI, AKI, basicConstraints
(critical CA/pathlen=2), keyUsage (digitalSignature/keyCertSign/cRLSign), EKU
(serverAuth/clientAuth), SAN (mixed-case DNS, IPv4, IPv6, email, URI), name
constraints (DNS and IPv4 permitted, IPv6 excluded), and unknown critical
1.2.3.4 containing DER NULL. RSA/RSA-PSS keys are 2048 bits; EC is P-256;
Ed25519 uses its standard key/signature encoding. PSS uses SHA-256, MGF1 with
SHA-256, salt length 32, omitted default trailer, and a PSS SPKI.

Generation used `openssl genpkey -algorithm RSA|RSA-PSS|EC|ED25519` (EC with
`-pkeyopt ec_paramgen_curve:P-256`), followed by `openssl req -new -x509
-set_serial 42 -days 365 -subj ... -addext ...` and `openssl x509 -outform DER`.
OpenSSL's independent text output supplied the field expectations. Exact TBS
ranges and SHA-256 hashes are pinned in the TypeLisp test. The fixture file
SHA-256 values are:

| File | SHA-256 |
|---|---|
| rsa.hex.in | 2b67263f5b94425182f1d9bacb1d2edf2a6f89547e38f1d25df5cf901ac8ac63 |
| ec.hex.in | 04c493348cfb9e77e68a16495f91b47d954c994c4b893ddbe131f5796f5928f6 |
| ed.hex.in | 843765ed6bd0c23e12db549f7cef30a9cd3df89e1aca208d68d84763153839df |
| pss.hex.in | 65e373ed822d79511f8a975119b77a751e123227edd8839a9bfaf573459ced97 |
| rsa.pem.in | 02fe2aef67d25006e7be2c2adb4ff59d19a9e05c280bb1b79f480b9c7c3f2673 |

The test also builds small unauthenticated encodings to exercise field/schema
errors, every truncated RSA prefix, 512 deterministic DER mutations (seed
6987) and 256 deterministic PEM mutations (seed 7468). Mutation acceptance
does not imply authenticity; unchanged or changed signature bytes can be
well-encoded while carrying no valid signature.
