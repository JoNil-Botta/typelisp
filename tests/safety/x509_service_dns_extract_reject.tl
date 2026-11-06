; Extracting the owned DNS field must retain its arena lifetime restriction.
(import stdlib.x509)

(define (domain) : x509.ServiceDnsName
  (match (x509.service-reference "example.test")
    [(x509.ServiceReferenceOk value)
      (match value
        [(x509.Dns name) name]
        [(x509.Ip _) (x509.ServiceDnsName "unused")])]
    [(x509.ServiceReferenceErr _) (x509.ServiceDnsName "unused")]))

(define (main) : i64
  (let
    [escaped : String
      (with-arena
        scratch
        (let
          [name : x509.ServiceDnsName (domain)]
          name.canonical))]
    [references : x509.ServiceReferences (x509.service-references-new)]
    (x509.service-reference-add!
      (&mut references)
      (x509.Dns (x509.ServiceDnsName escaped))
      (x509.service-identity-default-limits))
    42))