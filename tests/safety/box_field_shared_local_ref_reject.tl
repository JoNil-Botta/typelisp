;; A local shared reference holds the same loan as a parameter: a Box bound
;; from a field read through it cannot write the owner's box (#8927).
(defstruct Holder
  (b (Box i64)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (let
      [r : (& h Holder) (& h)]
      (let
        [b : (Box i64) r.b]
        (set! (deref b) 42)))
    (deref h.b)))