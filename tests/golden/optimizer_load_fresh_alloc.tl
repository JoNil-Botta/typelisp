;; Golden IR fixture for the load-GVN fresh-allocation epoch rule.
;;
;; `values` is a plain (Array i64) parameter, so its descriptor has no proven
;; alias root (NoRoot). Building `scratch` runs tl_alloc, tl_array_zero, and the
;; descriptor header stores between the two length reads. Every one of those
;; writes goes through storage allocated after the first length load was cached,
;; so the cached entry survives and the second read becomes a copy: the dump
;; must contain exactly one load of the parameter's length field.
(import stdlib.array)

(define (load-across-fresh-alloc [values : (__tl_dyn-array i64)]) : i64
  (let
    [before : i64 (array-length values)]
    [scratch : (__tl_dyn-array i64) (array.make-array i64 4)]
    (begin
      (array-set! scratch 0 before)
      (+ before (array-length values)))))

(define (main) : i64
  (load-across-fresh-alloc (array.make-array i64 2)))