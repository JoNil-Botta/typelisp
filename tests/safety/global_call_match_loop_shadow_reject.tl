(import stdlib.string)

(defenum Slot
  (Text String)
  (Number i64))

(define g : Slot
  (Slot.Text "still borrowed"))

(define (rebind!) : unit
  (set! g (Slot.Number 9)))

(define (main) : i64
  (let
    [index : i64 0]
    (while (< index 1)
      (begin
        (match (& g)
          [(Slot.Text g)
            (rebind!)
            (string.string-length g)]
          [(Slot.Number n) n])
        (+= index 1)))
    42))