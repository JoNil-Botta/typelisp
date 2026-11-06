; A short-lived DNS reference cannot be inserted into a longer-lived list.
(import stdlib.x509)

(define (main) : i64
  (let
    [references : x509.ServiceReferences (x509.service-references-new)]
    (with-arena
      scratch
      (match (x509.service-reference "example.test")
        [(x509.ServiceReferenceErr _) unit]
        [(x509.ServiceReferenceOk reference)
          (x509.service-reference-add!
            (&mut references)
            reference
            (x509.service-identity-default-limits))
          unit]))
    (let
      [certificate : x509.Certificate (init : x509.Certificate)]
      (match (x509.service-identity
        (& certificate)
        (& references)
        (x509.service-identity-default-limits))
        [(x509.ServiceIdentityMatch _ _) 42]
        [(x509.ServiceIdentityErr _) 1]))))