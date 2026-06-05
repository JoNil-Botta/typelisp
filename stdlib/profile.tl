;# Runtime profiling helper API.
;#
;# Provides allocation counters and a coarse monotonic millisecond timestamp via
;# backend runtime hooks. These helpers are ordinary stdlib functions; import
;# them explicitly with `(import "stdlib/profile.tl")`.
;:
;: Runtime hook backing `profile-now-ms`.
(extern tl_profile_now_ms : (-> i64))

;: Runtime hook backing `profile-alloc-total`.
(extern tl_profile_alloc_total : (-> i64))

;: Runtime hook backing `profile-alloc-live`.
(extern tl_profile_alloc_live : (-> i64))

;: Runtime hook backing `profile-alloc-peak`.
(extern tl_profile_alloc_peak : (-> i64))

;: Runtime hook backing `profile-alloc-reset-peak`.
(extern tl_profile_alloc_reset_peak : (-> unit))

;: Return a coarse monotonic timestamp in milliseconds.
(define (profile-now-ms) : i64
  (tl_profile_now_ms))

;: Return total allocated bytes since process start.
(define (profile-alloc-total) : i64
  (tl_profile_alloc_total))

;: Return currently live bytes in runtime allocation arenas.
(define (profile-alloc-live) : i64
  (tl_profile_alloc_live))

;: Return the peak live byte count since process start or last peak reset.
(define (profile-alloc-peak) : i64
  (tl_profile_alloc_peak))

;: Reset the peak live byte counter to the current live byte count.
(define (profile-alloc-reset-peak) : unit
  (tl_profile_alloc_reset_peak))