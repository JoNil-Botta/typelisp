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