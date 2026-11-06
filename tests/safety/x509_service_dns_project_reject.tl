; Editing public DNS records and bypassing insertion still fails at matching.
(import stdlib.x509)

(define (main) : i64
  (let
    [name : x509.ServiceDnsName (x509.ServiceDnsName "example.test")]
    [references : x509.ServiceReferences (x509.service-references-new)]
    [certificate : x509.Certificate (init : x509.Certificate)]
    (set! name.canonical "192.0.2.1")
    (set! (array-ref references.values 0) (x509.Dns name))
    (set! references.length 1)
    (match (x509.service-identity
      (& certificate)
      (& references)
      (x509.service-identity-default-limits))
      [(x509.ServiceIdentityMatch _ _) 1]
      [(x509.ServiceIdentityErr error)
        (if (= error.kind (x509.InvalidReference))
          42
          2)])))