;; #1983: Linux System V register-class aggregate arguments. The flat Pair
;; proves two INTEGER eightbytes, Outer proves recursive nested flattening, and
;; Mixed proves independent INTEGER/SSE banks for a two-eightbyte struct.
(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(defstruct Pair
  (lo i64)
  (hi i64))

(defstruct Inner
  (x i64))

(defstruct Outer
  (inner Inner)
  (tail i64))

(defstruct Mixed
  (tag u64)
  (value f64))

(extern (pair-score [arg0 : Pair] [salt : i64]) : i64 (:symbol "tl_cabi_pair_score"))

(extern pair-scorer (:symbol "tl_cabi_pair_score_ptr") : (-> Pair i64 i64))

(extern (outer-score [arg0 : Outer]) : i64 (:symbol "tl_cabi_outer_score"))

(extern (mixed-score [arg0 : Mixed] [scale : i64]) : i64 (:symbol "tl_cabi_mixed_score"))

(define (main) : i64
  (let
    [pair : Pair (Pair 10 20)]
    [outer : Outer (Outer (Inner 3) 21)]
    [mixed : Mixed (Mixed (cast 7 : u64) 2.5)]
    [pair-copy : (-> Pair i64 i64) pair-scorer]
    [pair-result : i64 (pair-score pair 5)]
    [pair-via-ptr : i64 (pair-copy pair 6)]
    [outer-result : i64 (outer-score outer)]
    [mixed-result : i64 (mixed-score mixed 4)]
    (begin
      (core/unless (= pair-result 135) (return 1))
      (core/unless (= pair-via-ptr 106) (return 2))
      (core/unless (= outer-result 42) (return 3))
      (core/unless (= mixed-result 17) (return 4))
      42)))