;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::stores.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; The upstream kernel converts each lane's f32 zero to i32, then converts it
;; back to f32 for the store. TypeLisp's current SIMD IR has no vector numeric
;; conversion, so this port loads/stores f32 directly and restricts zeros to
;; exactly representable integer values. The observable result is bit-exact.
(import stdlib.array)
(import stdlib.io)

(define (stores
  [values : (Array f32)]
  [count : i64]
  [zeros : (Array f32)]
  [_result : (Array f32)]) : unit
  (foreach
    ([i : i64 0 count])
    (array-set! values i (array-ref zeros (program-index)))))

(define (stores-detect-width [values : (Array f32)]) : i64
  (let
    [first-bits : u32 (io.float-f32-bits (array-ref values 0))]
    [width : i64 1]
    (begin
      (while (and
        (< width 32)
        (!= (io.float-f32-bits (array-ref values width)) first-bits))
        (set! width (+ width 1)))
      width)))

(define (stores-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 3]
    [(= case-id 2) 4]
    [(= case-id 3) 8]
    [(= case-id 4) 16]
    [(= case-id 5) 19]
    [else 65536]))

(define (stores-zero [lane : i64]) : f32
  (cast (- (* (+ lane 1) 17) 133) : f32))

(define (stores-fill! [values : (Array f32)] [count : i64] [value : f32]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! values i value)
        (set! i (+ i 1))))))

(define (stores-init-zeros! [zeros : (Array f32)] [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! zeros i (stores-zero i))
        (set! i (+ i 1))))))

(define (stores-output-matches?
  [values : (Array f32)]
  [count : i64]
  [width : i64]
  [sentinel : f32]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (begin
          (if (=
            (io.float-f32-bits (array-ref values i))
            (io.float-f32-bits (stores-zero (% i width))))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (and
        ok
        (=
          (io.float-f32-bits (array-ref values count))
          (io.float-f32-bits sentinel))))))

(define (main) : i64
  (let
    [max-count : i64 65536]
    [values : (Array f32) (array.make-array f32 (+ max-count 1))]
    [zeros : (Array f32) (array.make-array f32 32)]
    [result : (Array f32) (array.make-array f32 1)]
    [width : i64 0]
    [sentinel : f32 (cast 12345.0 : f32)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (stores-init-zeros! zeros 32)
      ;; Infer the f32 gang width from the backend-observable lane pattern.
      ;; Returning it in the exit code lets the harness distinguish modes.
      (stores-fill! values 33 sentinel)
      (stores values 32 zeros result)
      (set! width (stores-detect-width values))
      (if (or (= width 1) (= width 8) (= width 16))
        unit
        (set! ok false))
      (while (and ok (< case-id 7))
        (let
          [count : i64 (stores-case-count case-id)]
          [repetition : i64 0]
          (begin
            (stores-fill! values (+ count 1) sentinel)
            (while (< repetition 100)
              (begin
                (stores values count zeros result)
                (set! repetition (+ repetition 1))))
            (if (stores-output-matches? values count width sentinel)
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        (+ 41 width)
        1))))