;; A `&mut program` payload bound by a match through a shared reference grants
;; shared access only: a store through it writes through that `&` (Rust
;; E0594). Main 4e46ce356 accepts it.
(defstruct Pt
  (name String)
  (x i64))

(defenum Slot
  (Some (&mut program Pt))
  (None))

(defstruct Slots
  (slot Slot))

(define (poke [s : (& Slots)]) : unit
  (match s.slot
    [(Slot.Some r) (set! r.x 5)]
    [Slot.None unit]))

(define (main) : i64
  42)