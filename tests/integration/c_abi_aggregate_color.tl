(defstruct Color
  (r u8)
  (g u8)
  (b u8)
  (a u8))

(extern (color-make [arg0 : u8] [arg1 : u8] [arg2 : u8] [arg3 : u8]) : Color (:symbol "tl_cabi_color_make"))

(extern (color-use [arg0 : Color]) : i64 (:symbol "tl_cabi_color_use"))

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