; Checked DNS reference storage cannot be constructed outside stdlib.x509.
(import stdlib.x509)

(define (main) : i64
  (let
    [_name (x509.ServiceDnsName (make-array u8 253) 0)]
    0))