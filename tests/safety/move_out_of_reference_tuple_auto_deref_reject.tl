;; A non-Copy tuple element read through a shared reference without an
;; explicit `deref` is still a move out of the reference (#9430): lowering
;; reads such elements in place, so the checker alone rejects the move (E0208).
(import stdlib.string)

(define (first-text [pair : (& pair (Tuple String i64))]) : i64
  (let
    [text : String (tuple-ref pair 0)]
    (string.string-length (& text))))

(define (main) : i64
  (let
    [pair (tuple "abc" 1)]
    (first-text (& pair))))
