;; A struct field of the reserved `program` lifetime is like Rust's
;; `&'static mut`: the holder declares no lifetimes, its field's loans are the
;; program region's, and a holder is read, written through, passed, stored,
;; moved out of and matched like any owned value. A reborrow through the
;; path it is reached by is bounded by that path (main 4e46ce356 rejects most
;; of these as moves out of a reference or escapes).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (m (&mut program Pt)))

(defstruct Pair
  (h Holder)
  (k i64))

(defenum Slot
  (Some (&mut program Pt))
  (None))

(defstruct Slots
  (slot Slot))

(define (bump [p : (&mut p Pt)]) : unit
  (set! p.x (+ p.x 1)))

;; Main's typecheck smoke row (compiler-typecheck-place-through-shared-ok?).
(define (swap-out [h : (&mut Holder)]) : i64
  (let
    [old (replace! (deref (deref h).m) (Pt "z" 2))]
    old.x))

(define (read-x [h : Holder]) : i64
  (deref h.m).x)

(define (read-through-shared [h : (& Holder)]) : i64
  (deref (deref h).m).x)

(define (write-x [h : Holder]) : unit
  (set! (deref h.m).x 5))

(define (reborrow [h : (&mut Holder)]) : unit
  (bump (&mut (deref (deref h).m))))

(define (reborrow-nested [p : (&mut Pair)]) : unit
  (bump (&mut (deref (deref p).h.m))))

(define (wrap [r : (&mut program Pt)]) : Holder
  (Holder r))

(define (wrap-and-read [r : (&mut program Pt)]) : i64
  (let
    [h (Holder r)]
    (set! (deref h.m).x 5)
    (deref h.m).x))

(define (pass-on [h : Holder]) : Holder
  h)

(define (take-field [h : Holder]) : (&mut program Pt)
  h.m)

(define (destructure [h : Holder]) : unit
  (match h
    [(Holder m) (bump m)]))

(define (store [p : (&mut Pair)] [h : Holder]) : unit
  (set! (deref p).h h))

(define (push [hs : (&mut (__tl_dyn-array Holder))] [h : Holder]) : unit
  (__tl_array-push! (deref hs) h))

(define (write-element [hs : (&mut (Array Holder 2))]) : unit
  (set! (deref (array-ref (deref hs) 0).m).x 3))

(define (match-through-mut [s : (&mut Slots)]) : unit
  (match s.slot
    [(Slot.Some r) (set! r.x 5)]
    [Slot.None unit]))

(define (main) : i64
  42)