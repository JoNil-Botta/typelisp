(defstruct Vec2
  (:repr c)
  (x f32)
  (y f32))

(defstruct Mix8
  (:repr c)
  (tag u32)
  (value f32))

(extern (vec2-score [arg : Vec2] [tag : u64]) : i64 (:symbol "tl_cabi_vec2_score"))
(extern (vec2-make [tag : u64]) : Vec2 (:symbol "tl_cabi_vec2_make"))
(extern vec2-maker (:symbol "tl_cabi_vec2_make_ptr") : (-> u64 Vec2))
(extern (mix8-score [arg : Mix8] [tag : u64]) : i64 (:symbol "tl_cabi_mix8_score"))
(extern (mix8-make [tag : u32]) : Mix8 (:symbol "tl_cabi_mix8_make"))
(extern mix8-maker (:symbol "tl_cabi_mix8_make_ptr") : (-> u32 Mix8))

(define (main) : i64
  (let
    [direct-vec : Vec2 (Vec2 1.5 2.25)]
    [direct-vec-score : i64 (vec2-score direct-vec (cast 7 : u64))]
    [returned-vec : Vec2 (vec2-make (cast 3 : u64))]
    [returned-vec-score : i64 (vec2-score returned-vec (cast 3 : u64))]
    [indirect-vec : Vec2 (vec2-maker (cast 5 : u64))]
    [indirect-vec-score : i64 (vec2-score indirect-vec (cast 5 : u64))]
    [direct-mix : Mix8 (Mix8 (cast 11 : u32) 6.5)]
    [direct-mix-score : i64 (mix8-score direct-mix (cast 11 : u64))]
    [returned-mix : Mix8 (mix8-make (cast 17 : u32))]
    [returned-mix-score : i64 (mix8-score returned-mix (cast 17 : u64))]
    [indirect-mix : Mix8 (mix8-maker (cast 19 : u32))]
    [indirect-mix-score : i64 (mix8-score indirect-mix (cast 19 : u64))]
    (cond
      [(not (= direct-vec-score 11)) 1]
      [(not (= returned-vec-score 12)) 2]
      [(not (= indirect-vec-score 13)) 3]
      [(not (= direct-mix-score 14)) 4]
      [(not (= returned-mix-score 15)) 5]
      [(not (= indirect-mix-score 16)) 6]
      [else 42])))