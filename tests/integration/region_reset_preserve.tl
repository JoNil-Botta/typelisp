(import "stdlib/string.tl")

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
      (string-append "tmp" (int->string n))
      (tl_region_reset m))))

(define (main) : i64
  (let
    [s : String (string-append "a" "b")]
    [arr : (Array i64) (make-array i64 2)]
    [box : Box (make-box 7)]
    [pair : Pair (make-pair 5 6)]
    [m : u64 (tl_region_mark)]
    (begin
      (array-set! arr 0 20)
      (array-set! arr 1 22)
      (string-append "temporary" (int->string 99))
      (tl_region_reset m)
      (cycle 1)
      (cycle 2)
      (+
        (string-length s)
        (+
          (array-ref arr 0)
          (+
            (array-ref arr 1)
            (+ (box-value box) (+ (struct-get pair x) (struct-get pair y)))))))))