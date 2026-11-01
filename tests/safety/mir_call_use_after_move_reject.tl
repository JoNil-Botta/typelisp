;; A move-only argument moves into the callee; the second use reads a moved
;; value. The read is the primary location and the first move is labelled.
(define (consume [_text : String]) : i64
  1)

(define (twice [text : String]) : i64
  (+ (consume text) (consume text)))

(define (main) : i64
  0)