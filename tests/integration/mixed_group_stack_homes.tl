;; Refs #7820. The raw address exposes a contiguous stack pair while later
;; call results use ordinary group homes. Their writes must preserve both
;; words of the live pair. The old mixed offset maps overwrite it at opt0.
(import stdlib.io)

(defstruct Pair
  (x i64)
  (y i64))

(define (read [p : (MutPtr Pair)]) : i64
  (unsafe
    (let
      [v : Pair (ptr-read p)]
      (+ v.x v.y))))

(define (make [x : i64] [y : i64]) : Pair
  (if (< x 0)
    (make (- 0 x) y)
    (Pair x y)))

(define (probe [x : i64]) : i64
  (let
    [a : Pair (make x 7)]
    [before : i64
      (read
        (unsafe
          (ptr-addr-of a)))]
    [sum : i64 0]
    [p0 : Pair (make (+ x 0) 20)]
    [_s0 : unit (set! sum (+ sum (+ p0.x p0.y)))]
    [p1 : Pair (make (+ x 1) 21)]
    [_s1 : unit (set! sum (+ sum (+ p1.x p1.y)))]
    [p2 : Pair (make (+ x 2) 22)]
    [_s2 : unit (set! sum (+ sum (+ p2.x p2.y)))]
    [p3 : Pair (make (+ x 3) 23)]
    [_s3 : unit (set! sum (+ sum (+ p3.x p3.y)))]
    [after : i64
      (read
        (unsafe
          (ptr-addr-of a)))]
    (+ (+ before after) sum)))

(define (main) : i64
  (begin
    (unless (= (probe 5) 136) (io.panic "mixed group stack homes overlap"))
    42))