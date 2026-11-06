;; Run the same complete API corpus at opt0/1/2 on Linux and Windows.
(import stdlib.tests.crypto_p256_ecdsa_api as cases)

(define (main) : i64
  (cases.run-tests)
  42)