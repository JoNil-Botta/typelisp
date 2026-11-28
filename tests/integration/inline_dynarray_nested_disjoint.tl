;; Regression test for nested inline 16B DynArray element-vs-header
;; disjointness across helper calls (`CopyBytes` and `StorePtr` into outer
;; element buffers) and loops (LICM + Load-CSE).
(defstruct SmallVec
  (slots (__tl_dyn-array i64))
  (tag i64))

(define (replace-row!
  [rows : (&mut rows (__tl_dyn-array (__tl_dyn-array i64)))]
  [idx : i64]
  [seed : i64]) : unit
  (let
    [fresh : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (set! (array-ref fresh 0) seed)
    (set! (array-ref fresh 1) (+ seed 1))
    (set! (array-ref fresh 2) (+ seed 2))
    (set! (array-ref rows idx) fresh)))

(define (push-row!
  [rows : (&mut rows (__tl_dyn-array (__tl_dyn-array i64)))]
  [idx : i64]
  [v : i64]) : unit
  (__tl_array-push! (array-ref rows idx) v))

(define (replace-vec-row!
  [rows : (&mut rows (__tl_dyn-array SmallVec))]
  [idx : i64]
  [seed : i64]) : unit
  (let
    [fresh : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (set! (array-ref fresh 0) seed)
    (set! (array-ref fresh 1) (+ seed 5))
    (set! (array-ref rows idx) (SmallVec fresh seed))))

(define (test-nested-loops) : i64
  (let
    [rows : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 2)]
    [sum : i64 0]
    (set! (array-ref rows 0) (__tl_make-array i64 0))
    (set! (array-ref rows 1) (__tl_make-array i64 0))
    ;; Loop pushing into rows[i % 2] while reading rows[0].len and rows[0][0]:
    ;; LICM and Load-CSE must not hoist or cache rows[0]'s inline header across
    ;; mutations to rows[idx] in the same outer element buffer.
    (let
      [i : i64 0]
      (while (< i 4)
        (let
          [idx : i64 (% i 2)]
          (__tl_array-push! (array-ref rows idx) (+ i 1))
          (+= sum (array-length (array-ref rows 0)))
          (+= sum (array-ref (array-ref rows 0) 0)))
        (+= i 1)))
    ;; i=0: push 1 to rows[0] -> len0=1, r0[0]=1 -> sum += 2
    ;; i=1: push 2 to rows[1] -> len0=1, r0[0]=1 -> sum += 2
    ;; i=2: push 3 to rows[0] -> len0=2, r0[0]=1 -> sum += 3
    ;; i=3: push 4 to rows[1] -> len0=2, r0[0]=1 -> sum += 3
    ;; total sum = 10
    (if (= sum 10)
      10
      (- 0 100))))

(define (test-nested-calls) : i64
  (let
    [rows : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 2)]
    [total : i64 0]
    (set! (array-ref rows 0) (__tl_make-array i64 1))
    (set! (array-ref (array-ref rows 0) 0) 1)
    (set! (array-ref rows 1) (__tl_make-array i64 1))
    (set! (array-ref (array-ref rows 1) 0) 2)
    ;; Read rows[0].len before helper call that replaces rows[0] via CopyBytes.
    (+= total (array-length (array-ref rows 0)))
    (replace-row! (&mut rows) 0 10)
    (+= total (array-length (array-ref rows 0)))
    (+= total (array-ref (array-ref rows 0) 0))
    ;; Read rows[0].len before helper call that pushes into rows[0] via StorePtr.
    (push-row! (&mut rows) 0 20)
    (+= total (array-length (array-ref rows 0)))
    (+= total (array-ref (array-ref rows 0) 3))
    ;; total = 1 + 3 + 10 + 4 + 20 = 38
    (if (= total 38)
      20
      (- 0 200))))

(define (test-nested-struct-vec) : i64
  (let
    [vecs : (__tl_dyn-array SmallVec) (__tl_make-array SmallVec 2)]
    [acc : i64 0]
    (set! (array-ref vecs 0) (SmallVec (__tl_make-array i64 1) 1))
    (set! (array-ref (array-ref vecs 0).slots 0) 2)
    (set! (array-ref vecs 1) (SmallVec (__tl_make-array i64 1) 3))
    (+= acc (array-length (array-ref vecs 0).slots))
    (replace-vec-row! (&mut vecs) 0 4)
    (+= acc (array-length (array-ref vecs 0).slots))
    (+= acc (array-ref (array-ref vecs 0).slots 1))
    ;; acc = 1 + 2 + 9 = 12
    (if (= acc 12)
      12
      (- 0 300))))

(define (main) : i64
  (+ (test-nested-loops) (+ (test-nested-calls) (test-nested-struct-vec))))