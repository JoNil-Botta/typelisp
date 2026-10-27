;; Control (#9297): an inferred lambda result that borrows a capture is a
;; region escape, reported as before the capture rule.
(define (main) : i64
  (let
    [x : i64 42]
    ; Must fail: the inferred result is region-tagged.
    [f
      (lambda ()
        (& x))]
    [r (f)]
    (deref r)))