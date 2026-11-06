; Checked DNS reference bytes cannot be changed through a foreign field access.
(import stdlib.x509)

(define (length [name : (& name x509.ServiceDnsName)]) : i64
  name.length)

(define (main) : i64
  0)