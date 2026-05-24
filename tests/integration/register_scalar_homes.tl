(define (scalar-homes [seed : i64]) : i64
  (let
    [a : i64 5]
    [b : i64 7]
    [c : i64 11]
    [d : i64 13]
    [e : i64 17]
    [f : i64 19]
    (begin
      (set! a (+ a seed))
      (set! b (+ b a))
      (set! c (+ c b))
      (set! d (+ d c))
      (set! e (+ e d))
      (set! f (+ f e))
      (+ (+ (+ a b) (+ c d)) (+ e f)))))

(define (narrow-homes) : i64
  (let
    [s : i8 (cast -1 : i8)]
    [u : u8 (cast 255 : u8)]
    [ok : bool true]
    (if ok
      (+ (cast s : i64) (cast u : i64))
      0)))

(define (main) : i64
  (+ (- (scalar-homes 1) 165) (- (narrow-homes) 254)))