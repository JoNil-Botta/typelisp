; A raw pointer is not a DNS owner and cannot be reconstructed as a reference.
(import stdlib.x509)

(define (main) : i64
  (let
    [_reference (x509.Dns (ptr-null : (Ptr x509.ServiceDnsName)))]
    42))