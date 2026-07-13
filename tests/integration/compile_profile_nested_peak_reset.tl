;; compile_profile_nested_peak_reset.tl - Compile-wide peak reset fixture.
(import stdlib.array)
(import stdlib.profile)

(define (transient-allocation) : i64
  (let
    [items : (Array i64) (array.make-array i64 4096)]
    (begin
      (array-set! items 0 37)
      (array-ref items 0))))

(cfg
  compile-profile
  (define (main) : i64
    (begin
      (profile.compile-wide-peak-start!)
      (let
        [marker : i64 (transient-allocation)]
        (begin
          ;; Preserve the transient high-water mark before clearing the
          ;; runtime's nested peak counter.
          (profile.alloc-reset-peak)
          (if (and (= marker 37) (> (profile.compile-wide-peak-finish!) 0))
            0
            1))))))

(cfg
  (not compile-profile)
  (define (main) : i64
    42))