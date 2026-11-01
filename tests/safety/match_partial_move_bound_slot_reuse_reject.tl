;; A tuple slot a by-value match binds by move cannot be used again; the
;; other slots stay usable (#8449).
(import stdlib.string)

(define (take-s [s : String]) : i64
  (string.string-length (& s)))

(define (f [p : (Tuple String String)]) : i64
  (+
    (match p
      [(tuple a _) (take-s a)])
    (take-s (tuple-ref p 0))))

(define (main) : i64
  42)