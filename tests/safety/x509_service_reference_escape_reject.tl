; An arena-owned validated DNS reference cannot outlive its backing storage.
(import stdlib.x509)

(define (main) : i64
  (let
    [escaped : x509.ServiceReferenceResult
      (with-arena scratch (x509.service-reference "example.test"))]
    (match escaped
      [(x509.ServiceReferenceOk _) 42]
      [(x509.ServiceReferenceErr _) 1])))