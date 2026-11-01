(module macro_struct_pattern_owner_reject)

(import macro_struct_pattern_defs as defs)

(defstruct Pair
  (marker bool)
  (left i64)
  (right i64))

(define (main [pair : Pair]) : i64
  (defs.pair-sum pair))