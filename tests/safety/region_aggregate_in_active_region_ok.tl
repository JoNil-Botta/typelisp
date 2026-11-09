;; Pins SPEC 3.9's exception: an aggregate built inside the active region may
;; hold a tagged value in a constructor field or an array element. Its own
;; escape is then checked.
(import stdlib.string)

(defstruct Holder
  (text String))

(define (constructed) : i64
  (with-arena
    r
    (let
      [s (string.int->string 1)]
      [w (Holder s)]
      (string.string-length (& w.text)))))

(define (arrayed) : i64
  (with-arena
    r
    (let
      [s (string.int->string 1)]
      [u (string.int->string 2)]
      [a (array s u)]
      1)))

(define (main) : i64
  (+ (constructed) (arrayed)))