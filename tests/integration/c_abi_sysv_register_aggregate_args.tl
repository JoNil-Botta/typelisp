;; #1983: Linux System V register-class aggregate arguments. The flat Pair
;; proves two INTEGER eightbytes, Outer proves recursive nested flattening,
;; Mixed proves independent INTEGER/SSE banks for a two-eightbyte struct, and
;; Vec2 proves a packed {f32, f32} SSE eightbyte for args and returns.
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

(defstruct Vec2
  (x f32)
  (y f32))

(extern (pair-score [arg0 : Pair] [salt : i64]) : i64 (:symbol "tl_cabi_pair_score"))

(extern pair-scorer (:symbol "tl_cabi_pair_score_ptr") : (-> Pair i64 i64))

(extern (outer-score [arg0 : Outer]) : i64 (:symbol "tl_cabi_outer_score"))

(extern (mixed-score [arg0 : Mixed] [scale : i64]) : i64 (:symbol "tl_cabi_mixed_score"))

(extern (vec2-score [arg0 : Vec2] [salt : i64]) : i64 (:symbol "tl_cabi_vec2_score"))

(extern (vec2-make [seed : i64]) : Vec2 (:symbol "tl_cabi_vec2_make"))

(define (main) : i64
  (let
    [pair : Pair (Pair 10 20)]
    [outer : Outer (Outer (Inner 3) 21)]
    [mixed : Mixed (Mixed (cast 7 : u64) 2.5)]
    [vec : Vec2 (Vec2 1.5 2.25)]
    [pair-copy : (-> Pair i64 i64) pair-scorer]
    [pair-result : i64 (pair-score pair 5)]
    [pair-via-ptr : i64 (pair-copy pair 6)]
    [outer-result : i64 (outer-score outer)]
    [mixed-result : i64 (mixed-score mixed 4)]
    [vec2-result : i64 (vec2-score vec 8)]
    [made : Vec2 (vec2-make 4)]
    (begin
      (unless (= pair-result 135) (return 1))
      (unless (= pair-via-ptr 106) (return 2))
      (unless (= outer-result 42) (return 3))
      (unless (= mixed-result 17) (return 4))
      (unless (= vec2-result 45) (return 5))
      (unless (= (cast (struct-get made x) : i64) 6) (return 6))
      (unless (= (cast (struct-get made y) : i64) 7) (return 7))
      42)))