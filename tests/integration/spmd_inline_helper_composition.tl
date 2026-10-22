;; Acyclic helper bodies and completed caller arguments may reuse a callee.
;; Distinct inputs, masked branches and 13 lanes pin the packed path and tail.
(import spmd_inline_helper_composition_provider as provider)

(define (bump [value : i64]) : i64
  (+ value 1))

(define (compose [value : i64]) : i64
  (bump value))

(define (combine [left : i64] [right : i64]) : i64
  (+ (bump left) (bump right)))

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [masked : (&mut masked (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set!
        (array-ref out i)
        (+
          (compose (bump (array-ref xs i)))
          (combine (bump (array-ref xs i)) (bump i))))
      (if (< (array-ref xs i) 0)
        (set!
          (array-ref masked i)
          (provider.compose (provider.bump (array-ref xs i))))
        (set!
          (array-ref masked i)
          (provider.combine (provider.bump (array-ref xs i)) (provider.bump i)))))))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 13)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 13)]
    [masked : (__tl_dyn-array i64) (__tl_make-array i64 13)]
    [i : i64 0]
    (while (< i 13)
      (set! (array-ref xs i) (- i 6))
      (+= i 1))
    (fill (& xs) (&mut out) (&mut masked) 0)
    (fill (& xs) (&mut out) (&mut masked) 13)
    (set! i 0)
    (while (< i 13)
      (let
        [value : i64 (array-ref xs i)]
        [want : i64 (+ (compose (bump value)) (combine (bump value) (bump i)))]
        [want-masked : i64
          (if (< value 0)
            (provider.compose (provider.bump value))
            (provider.combine (provider.bump value) (provider.bump i)))]
        (when (!= (array-ref out i) want) (return 1))
        (when (!= (array-ref masked i) want-masked) (return 2)))
      (+= i 1))
    42))