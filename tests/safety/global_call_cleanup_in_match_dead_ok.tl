;: The `with` cleanup `close-handle` assigns `g` (through `drop-word`) at the
;: scope's exit, after the last use of `text`, the borrow of `g`'s payload:
;: no loan of `g` is live there, as in Rust (#7904; non-lexical lifetimes).
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
      (with ([h (Handle 9) close-handle]) (string.string-length text))]
    [(Slot.Number n) n]))