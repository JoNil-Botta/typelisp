;; Golden IR fixture for the load-GVN fresh-allocation epoch rule.
;;
;; `values` is a private dynamic-array parameter, so its descriptor has no
;; proven alias root (NoRoot). Building `scratch` runs tl_alloc, tl_array_zero, and the
;; descriptor header stores between the two length reads. Every one of those
;; writes goes through storage allocated after the first length load was cached,
;; so the cached entry survives and the second read is eliminated: the dump must
;; contain exactly one load of the parameter's length field, and under
;; substitution mode no copy either -- the add reads the surviving load's var
;; directly (see opt-load-gvn-subst-pair).

(define (load-across-fresh-alloc [values : (__tl_dyn-array i64)]) : i64
  (let
    [before : i64 (array-length values)]
    [scratch : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (begin
      (set! (array-ref scratch 0) before)
      (+ before (array-length values)))))

(define (main) : i64
  (load-across-fresh-alloc (__tl_make-array i64 2)))