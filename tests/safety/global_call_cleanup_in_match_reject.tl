;: The `with` cleanup `close-handle` assigns `g` (through `drop-word`) at the
;: scope's exit while `text`, a borrow of `g`'s payload, is still read after
;: it (#7904).
(import stdlib.string)

(defenum Slot
  (Text String)
  (Number i64))

(define g : Slot
  (Text "safe"))

(define (drop-word [n : i64]) : unit
  (set! g (Number n)))

(defstruct Handle
  (:cleanup close-handle)
  (n i64 (:cleanup drop-word)))

(define (main) : i64
  (match (& g)
    [(Slot.Text text)
      (let
        [k : i64 (with ([h (Handle 9) close-handle]) 0)]
        (+ k (string.string-length text)))]
    [(Slot.Number n) n]))