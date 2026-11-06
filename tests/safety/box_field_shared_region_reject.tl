;; A region-qualified Box: a holder allocated in an arena and read through a
;; shared reference keeps that reference as its Box field's origin (#8927).
(defstruct Holder
  (b (Box i64)))

(define (main) : i64
  (with-arena
    scratch
    (let
      [h (Holder (box 40))]
      (let
        [r (& h)]
        (let
          [b r.b]
          (set! (deref b) 42)))
      (deref h.b))))