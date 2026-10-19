;; A match binder of a field read through a shared reference, returned by
;; value, moves the field out of the holder (main accepted it, #8449).
(import stdlib.string)

(defstruct Holder
  (name String)
  (n i64))

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (take [h : (& h Holder)]) : String
  (match h.name
    [s s]))

(define (main) : i64
  42)