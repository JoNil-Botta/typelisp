;; #2386 milestone: a 16-byte two-word register-group struct. Both fields are
;; word-class, so `P` is carried in two GP registers (IrInstrPack builds the two
;; words; IrInstrWord extracts a field). This exercises construction + field
;; extract with NO call/return ABI (main returns a plain i64).
(defstruct P
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [p : P (P 17 25)]
    (+ (struct-get p a) (struct-get p b))))