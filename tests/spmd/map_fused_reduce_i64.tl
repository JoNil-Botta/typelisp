;; Map-fused i64 reductions over a contiguous input (#5181). The neutral lane
;; term exercises mixed Array/Uniform/LaneIndex plans while keeping scalar,
;; AVX2, and AVX-512 results identical across full gangs and scalar tails.
(import stdlib.array)

(define (manual-map-sum [values : (Array i64)] [n : i64] [uniform : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (+ (array-ref values i) uniform)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-map-fused [values : (Array i64)] [n : i64] [uniform : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref values i) uniform)))

(define (reduce-map-lane-neutral
  [values : (Array i64)]
  [n : i64]
  [uniform : i64]) : i64
  (spmd-reduce
    sum
    ([i : i64 0 n])
    0
    (+ (+ (array-ref values i) uniform) (bit-and (program-index) 0))))

(define (manual-surface-sum [values : (Array i64)] [n : i64] [uniform : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (+
              acc
              (-
                (bit-or (array-ref values i) uniform)
                (bit-xor (array-ref values i) 1))))
          (set! i (+ i 1))))
      acc)))

(define (reduce-map-surface [values : (Array i64)] [n : i64] [uniform : i64]) : i64
  (spmd-reduce
    sum
    ([i : i64 0 n])
    0
    (- (bit-or (array-ref values i) uniform) (bit-xor (array-ref values i) 1))))

(define (manual-shift-sum [values : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (shl (array-ref values i) 1)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-map-shift [values : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (shl (array-ref values i) 1)))

(define (main) : i64
  (let
    [values : (Array i64) (array.make-array i64 11)]
    [i : i64 0]
    (begin
      (while (< i 11)
        (begin
          (array-set! values i (+ i 1))
          (set! i (+ i 1))))
      (cond
        [(!= (reduce-map-fused values 0 3) 0) 1]
        [(!= (reduce-map-fused values 3 3) 15) 2]
        [(!= (reduce-map-fused values 4 3) 22) 3]
        [(!= (reduce-map-fused values 5 3) 30) 4]
        [(!= (reduce-map-fused values 8 3) 60) 5]
        [(!= (reduce-map-fused values 11 3) 99) 6]
        [(!= (reduce-map-fused values 11 3) (manual-map-sum values 11 3)) 7]
        [(!= (reduce-map-lane-neutral values 11 3) (manual-map-sum values 11 3))
          8]
        [(!= (reduce-map-surface values 11 3) (manual-surface-sum values 11 3))
          9]
        [(!= (reduce-map-shift values 11) (manual-shift-sum values 11)) 10]
        [else 42]))))