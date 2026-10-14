(import stdlib.string)

(defenum Slot
  (Text String)
  (Number i64))

(define g : Slot
  (Slot.Text "still borrowed"))

(define (rebind!) : unit
  (set! g (Slot.Number 9)))

(define (main) : i64
  (match (& g)
    [(Slot.Text text)
      (begin
        (rebind!)
        (string.string-length text))]
    [(Slot.Number n) n]))