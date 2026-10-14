;; A shift's computed count keeps its own type when the shift has no expected
;; type (#8449 M5): `(* index 8)` is an i64 count of a u64 shift.
(define (byte-at [value : i64] [index : i64]) : i64
  (cast (bit-and (shr (cast value : u64) (* index 8)) (cast 255 : u64)) : i64))

(define (main) : i64
  (byte-at 10794 1))