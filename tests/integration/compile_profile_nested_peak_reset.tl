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
    (let
      [before-live : i64 (profile.alloc-live)]
      [_profile-start : unit (profile.compile-wide-peak-start!)]
      [marker : i64 (with-arena transient (transient-allocation))]
      [after-live : i64 (profile.alloc-live)]
      [_nested-reset : unit (profile.alloc-reset-peak)]
      [compile-wide-peak : i64 (profile.compile-wide-peak-finish!)]
      ;; The scoped arena restores live bytes before the nested reset, so the
      ;; final runtime peak is back at the baseline. Only the compile-wide
      ;; accumulator can preserve the transient allocation's high-water mark.
      (if (and (= marker 37) (= after-live before-live) (> compile-wide-peak 0))
        0
        1))))

(cfg
  (not compile-profile)
  (define (main) : i64
    (begin
      ;; Keep the profile import live under the lint configuration too.
      (profile.alloc-live)
      42)))