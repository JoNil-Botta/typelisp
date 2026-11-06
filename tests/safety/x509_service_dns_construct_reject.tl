; A directly constructed DNS record cannot classify numeric IPv4 as DNS.
(import stdlib.x509)

(define (main) : i64
  (let
    [references : x509.ServiceReferences (x509.service-references-new)]
    [forged : x509.ServiceReference
      (x509.Dns (x509.ServiceDnsName "192.0.2.1"))]
    (match (x509.service-reference-add!
      (&mut references)
      forged
      (x509.service-identity-default-limits))
      [(x509.ServiceReferenceAdded) 1]
      [(x509.ServiceReferenceAddErr error)
        (if (= error.kind (x509.InvalidReference))
          42
          2)])))