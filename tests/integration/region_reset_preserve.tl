(import stdlib.string)

(extern (tl_region_mark) : u64)
(extern (tl_region_reset [arg0 : u64]) : unit)

(defenum Box
  (Boxed i64))

(defstruct Pair
  (x i64)
  (y i64))

(define (make-box [n : i64]) : Box
  (Boxed n))

(define (make-pair [x : i64] [y : i64]) : Pair
  (Pair x y))

(define (box-value [b : Box]) : i64
  (match b
    [(Boxed n) n]))

(define (cycle [n : i64]) : unit
  (let
    [m : u64 (tl_region_mark)]
    (begin
      (string.append "tmp" (string.int->string n))
      (tl_region_reset m))))

(define (main) : i64
  (let
    [s : String (string.append "a" "b")]
    [arr : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [box : Box (make-box 7)]
    [pair : Pair (make-pair 5 6)]
    [m : u64 (tl_region_mark)]
    (begin
      (set! (array-ref arr 0) 20)
      (set! (array-ref arr 1) 22)
      (string.append "temporary" (string.int->string 99))
      (tl_region_reset m)
      (cycle 1)
      (cycle 2)
      (+
        (string-length s)
        (+
          (array-ref arr 0)
          (+ (array-ref arr 1) (+ (box-value box) (+ pair.x pair.y))))))))