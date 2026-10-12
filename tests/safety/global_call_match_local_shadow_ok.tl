(import stdlib.string)

(defenum Slot
  (Text String)
  (Number i64))

(define g : Slot
  (Slot.Text "global"))

(define (rebind!) : unit
  (set! g (Slot.Number 9)))

(define (main) : i64
  (let
    [g : Slot (Slot.Text "local")]
    (if (=
      (match (& g)
        [(Slot.Text g)
          (rebind!)
          (string.string-length g)]
        [(Slot.Number n) n])
      5)
      42
      1)))