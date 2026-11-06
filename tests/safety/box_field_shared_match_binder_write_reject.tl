;; A match on an enum read through a shared reference binds views of its
;; payloads: writing a Box payload's contents writes the caller's box (#8927).
(defenum Slot
  (Full (Box i64))
  (Empty))

(defstruct Holder
  (slot Slot))

(define (mutate [r : (& r Holder)]) : unit
  (match r.slot
    [(Slot.Full b) (set! (deref b) 42)]
    [(Slot.Empty) unit]))

(define (main) : i64
  (let
    [h : Holder (Holder (Slot.Full (box 40)))]
    (mutate (& h))
    (match h.slot
      [(Slot.Full b) (deref b)]
      [(Slot.Empty) 0])))