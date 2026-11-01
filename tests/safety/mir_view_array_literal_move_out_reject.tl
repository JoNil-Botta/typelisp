;; A field read through a shared reference used as an element of an owned
;; array literal is taken out of the referent: the array would own a String
;; the holder still owns, and both would free it (#8449).
(import stdlib.string)

(defstruct Holder
  (name String)
  (n i64))

(define (names [h : (& h Holder)]) : (Array String 1)
  (array h.name))

(define (main) : i64
  (let
    [h : Holder (Holder (string.copy "abcdef") 1)]
    [a : (Array String 1) (names (& h))]
    (string.string-length (& (array-ref a 0)))))