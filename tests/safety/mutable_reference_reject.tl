;;; SPEC safe-code contract: mutable/shared-reference mutation is rejected until
;;; the mutable borrow checker can prove exclusivity.
(define (main [n : (&mut phase i64)]) : unit
  unit)