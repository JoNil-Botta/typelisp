;; Runtime SIMD dispatch selection fixture (#1485).
;;
;; Each variant computes the same i64 SPMD checksum, then returns a distinct tag
;; so the shell harness can tell which runtime-selected body executed: scalar =
;; 42, avx2 = 106, avx512 = 170. A bad SIMD result returns a small failure code
;; instead of the tag. Keep the SPMD loop directly inside each variant while
;; sharing ordinary scalar setup/checksum helpers across all variants.
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_seed_a [i : i64]) : i64
  (+ i 1))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_seed_b [i : i64]) : i64
  (* i 2))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_fill_inputs
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (&mut b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (dispatch_seed_a i))
        (set! (array-ref b i) (dispatch_seed_b i))
        (set! i (+ i 1))))))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_checksum [out : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      acc)))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_scalar [n : i64]) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs (&mut a) (&mut b) n)
      (foreach
        ([i : i64 0 n])
        (set! (array-ref out i) (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
      (if (= (bit-and acc 0xff) 247)
        42
        5))))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_avx2 [n : i64]) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs (&mut a) (&mut b) n)
      (foreach
        ([i : i64 0 n])
        (set! (array-ref out i) (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
      (if (= (bit-and acc 0xff) 247)
        106
        6))))

;; lint-allow: function-name-case -- assembly dispatch symbol fixture
(define (dispatch_avx512 [n : i64]) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs (&mut a) (&mut b) n)
      (foreach
        ([i : i64 0 n])
        (set! (array-ref out i) (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
      (if (= (bit-and acc 0xff) 247)
        170
        7))))

(defdispatch
  ;; lint-allow: function-name-case -- assembly dispatch symbol fixture
  dispatch_run
  (scalar dispatch_scalar)
  (avx2 dispatch_avx2)
  (avx512 dispatch_avx512))

(define (dispatch-spawn [ready : i64] [start : i64]) : thread_i64.SpawnResult
  (thread_i64.spawn
    (lambda () : i64
      (if (thread.semaphore-post (thread.ThreadSemaphore ready))
        (if (thread.semaphore-wait (thread.ThreadSemaphore start))
          (dispatch_run 13)
          249)
        248))))

(define (dispatch-semaphore-wait-count [handle : i64] [remaining : i64]) : bool
  (if (= remaining 0)
    true
    (and
      (thread.semaphore-wait (thread.ThreadSemaphore handle))
      (dispatch-semaphore-wait-count handle (- remaining 1)))))

(define (dispatch-semaphore-post-count [handle : i64] [remaining : i64]) : bool
  (if (= remaining 0)
    true
    (let
      [posted : bool (thread.semaphore-post (thread.ThreadSemaphore handle))]
      [rest : bool (dispatch-semaphore-post-count handle (- remaining 1))]
      (and posted rest))))

(define (dispatch-join-value [worker : thread_i64.Handle]) : i64
  (match (thread_i64.join worker)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) 247]))

(define (dispatch-finish-contended
  [ready : i64]
  [start : i64]
  [a : thread_i64.Handle]
  [b : thread_i64.Handle]
  [c : thread_i64.Handle]
  [d : thread_i64.Handle]) : i64
  (let
    [all-ready : bool (dispatch-semaphore-wait-count ready 4)]
    [all-released : bool (dispatch-semaphore-post-count start 4)]
    [av : i64 (dispatch-join-value a)]
    [bv : i64 (dispatch-join-value b)]
    [cv : i64 (dispatch-join-value c)]
    [dv : i64 (dispatch-join-value d)]
    [ready-closed : bool
      (thread.semaphore-close (thread.ThreadSemaphore ready))]
    [start-closed : bool
      (thread.semaphore-close (thread.ThreadSemaphore start))]
    [warm : i64 (dispatch_run 13)]
    (if (and
      all-ready
      all-released
      ready-closed
      start-closed
      (= av bv)
      (= av cv)
      (= av dv)
      (= av warm))
      av
      246)))

(define (dispatch-run-contended [ready : i64] [start : i64]) : i64
  (match (dispatch-spawn ready start)
    [(thread_i64.I64SpawnErr _) 241]
    [(thread_i64.I64SpawnOk a)
      (match (dispatch-spawn ready start)
        [(thread_i64.I64SpawnErr _) 242]
        [(thread_i64.I64SpawnOk b)
          (match (dispatch-spawn ready start)
            [(thread_i64.I64SpawnErr _) 243]
            [(thread_i64.I64SpawnOk c)
              (match (dispatch-spawn ready start)
                [(thread_i64.I64SpawnErr _) 244]
                [(thread_i64.I64SpawnOk d)
                  (dispatch-finish-contended ready start a b c d)])])])]))

(define (main) : i64
  (let
    [ready : i64 (thread.semaphore-create-handle-or 0 -1)]
    [start : i64 (thread.semaphore-create-handle-or 0 -1)]
    (if (or (< ready 0) (< start 0))
      245
      (dispatch-run-contended ready start))))