;; The name conversion is for scalars: a move-only name at its region-tagged
;; type stays rejected (#9737).
; Must fail: `s` is not Copy.
(define (bad [p : (& p String)] [s : String]) : (in p String)
  s)

(define (main) : i64
  0)