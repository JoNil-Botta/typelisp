;; Constructing an owned holder from a Box view moves the caller's box out of
;; the shared reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (copy-holder [r : (& r Holder)]) : Holder
  (let
    [b r.b]
    (Holder b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    [other : Holder (copy-holder (& h))]
    (set! (deref other.b) 42)
    (deref h.b)))