;; Returning a non-Copy tuple element read through a mutable reference without
;; an explicit `deref` moves it out of the referent (#9430), which is rejected
;; (E0208) as through a shared reference.
(define (take-text [pair : (&mut pair (Tuple String i64))]) : String
  (tuple-ref pair 0))

(define (main) : i64
  (let
    [pair (tuple "abc" 1)]
    (take-text (&mut pair))
    42))
