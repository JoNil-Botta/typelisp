;; A Box field reached through a reference keeps its origin, while owned
;; moves, explicit clones, shared reads, Copy fields and writes through a
;; mutable view stay accepted (#8927).
(defstruct Inner
  (b (Box i64)))

(defstruct Holder
  (b (Box i64))
  (inner Inner)
  (n i64))

;; Shared reads: through the field, a view binder and a nested field.
(define (read-shared [r : (& r Holder)]) : i64
  (let
    [view r.b]
    [nested r.inner.b]
    [count : i64 r.n]
    (+ (+ (deref r.b) (deref view)) (+ (deref nested) count))))

;; An explicit clone is an owned box of its own: writing it leaves the
;; caller's box unchanged.
(define (clone-and-write [r : (& r Holder)]) : i64
  (let
    [copy : (Box i64) (clone r.b)]
    (set! (deref copy) 100)
    (deref copy)))

;; A view read through a mutable reference writes the referent itself.
(define (write-mutable [r : (&mut r Holder)]) : unit
  (let
    [view r.b]
    (set! (deref view) 7)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 1) (Inner (box 2)) 3)]
    [shared : i64 (read-shared (& h))]
    [cloned : i64 (clone-and-write (& h))]
    (write-mutable (&mut h))
    ;; An owned move out of the holder's field.
    (let
      [owned : (Box i64) h.b]
      (set! (deref owned) (+ (deref owned) 1))
      ;; shared 1+1+2+3 = 7, cloned 100, inner 2, owned 7+1 = 8:
      ;; 7 + 100 - 75 + 2 + 8 = 42
      (+ (+ (- (+ shared cloned) 75) (deref h.inner.b)) (deref owned)))))