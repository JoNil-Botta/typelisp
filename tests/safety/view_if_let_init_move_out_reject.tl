;; An `if` initializing an owned binding from a field read through a shared
;; reference moves the field out of the holder (main accepted it, #8449).
(import stdlib.string)

(defstruct Holder
  (name String)
  (n i64))

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (run [h : (& h Holder)]) : i64
  (let
    [s : String
      (if (> h.n 0)
        h.name
        (string.copy "y"))]
    (consume s)))

(define (main) : i64
  42)