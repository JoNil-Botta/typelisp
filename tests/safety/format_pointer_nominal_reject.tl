(import stdlib.format)

(defstruct PointerLookalike
  (address u64))

(define (reject-pointer-format [value : PointerLookalike]) : String
  (unsafe
    (format.format "{:p}" value)))