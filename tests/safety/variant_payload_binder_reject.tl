;; A bare binder in a payload position may not spell a variant of the payload
;; enum: it would match every value.
(defenum Width
  (Byte)
  (Word))

(defenum Instr
  (Load i64 Width)
  (Halt))

(define (size [instr : Instr]) : i64
  (match instr
    [(Load base Byte) base]
    [_ 0]))

(define (main) : i64
  (size (Instr.Load 42 Width.Word)))