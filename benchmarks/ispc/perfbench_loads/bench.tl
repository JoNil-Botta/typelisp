;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::loads.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; The source deliberately preserves f32 accumulation and horizontal-sum
;; intent. Until #4969 lands, every backend mode must reject `loads` with the
;; exact diagnostic recorded in case.tsv; do not widen this case to f64.
(import stdlib.array)
(import stdlib.io)

(define (loads [values : (Array f32)] [count : i64]) : f32
  (spmd-reduce sum ([i : i64 0 count]) (cast 0.0 : f32) (array-ref values i)))

(define (loads-scalar [values : (Array f32)] [count : i64]) : f32
  (let
    [sum : f32 (cast 0.0 : f32)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (array-ref values i)))
          (set! i (+ i 1))))
      sum)))

(define (loads-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 3]
    [(= case-id 2) 8]
    [(= case-id 3) 16]
    [(= case-id 4) 19]
    [(= case-id 5) 12]
    [else 65536]))

(define (loads-case-value [case-id : i64] [index : i64]) : f32
  (cond
    [(= case-id 1) (cast (+ index 1) : f32)]
    [(= case-id 2) (cast 1.0 : f32)]
    [(= case-id 3) (cast 1.0 : f32)]
    [(= case-id 4) (cast (- (% index 7) 3) : f32)]
    [(= case-id 5)
      (if (= (% index 2) 0)
        (cast 1024.0 : f32)
        (cast -1024.0 : f32))]
    [else (cast 1.0 : f32)]))

(define (loads-fill-case! [values : (Array f32)] [case-id : i64] [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! values i (loads-case-value case-id i))
        (set! i (+ i 1))))))

(define (loads-case-expected-bits [case-id : i64]) : u32
  (cond
    [(= case-id 0) (cast 0x00000000 : u32)]
    [(= case-id 1) (cast 0x40c00000 : u32)]
    [(= case-id 2) (cast 0x41000000 : u32)]
    [(= case-id 3) (cast 0x41800000 : u32)]
    [(= case-id 4) (cast 0xc0a00000 : u32)]
    [(= case-id 5) (cast 0x00000000 : u32)]
    [else (cast 0x47800000 : u32)]))

(define (main) : i64
  (let
    [values : (Array f32) (array.make-array f32 65536)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< case-id 7))
        (let
          [count : i64 (loads-case-count case-id)]
          (begin
            (loads-fill-case! values case-id count)
            (if (and
              (=
                (io.float-f32-bits (loads-scalar values count))
                (loads-case-expected-bits case-id))
              (=
                (io.float-f32-bits (loads values count))
                (loads-case-expected-bits case-id)))
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        42
        1))))