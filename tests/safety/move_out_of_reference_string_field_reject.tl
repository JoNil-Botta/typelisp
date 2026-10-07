;; An owned String field read through a reference is not Copy (#8554).
(import stdlib.string)

(defstruct Pt
  (name String)
  (x i64))

(define (len-of [s : String]) : i64
  (string.string-length s))

(define (via-ref [p : (& Pt)]) : i64
  (len-of p.name))

(define (main) : i64
  (let
    [p (Pt "abc" 1)]
    (via-ref (& p))))