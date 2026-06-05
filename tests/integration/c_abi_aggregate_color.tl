(defstruct Color
  (r u8)
  (g u8)
  (b u8)
  (a u8))

(extern color-make (:symbol "tl_cabi_color_make") : (-> u8 u8 u8 u8 Color))

(extern color-use (:symbol "tl_cabi_color_use") : (-> Color i64))

(define (main) : i64
  (let
    [c : Color
      (color-make (cast 5 : u8) (cast 7 : u8) (cast 11 : u8) (cast 13 : u8))]
    [weighted : i64 (color-use c)]
    [sum : i64
      (+
        (cast (struct-get c r) : i64)
        (+
          (cast (struct-get c g) : i64)
          (+ (cast (struct-get c b) : i64) (cast (struct-get c a) : i64))))]
    (if (= weighted 104)
      (if (= sum 36)
        42
        2)
      1)))