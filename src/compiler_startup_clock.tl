;; compiler_startup_clock.tl - Earliest source-level startup timestamp.
;;
;; Keep this module's dependency graph deliberately small and import it before
;; the compiler graph. Its initializer runs after the platform timer scratch is
;; ready but before compiler globals, separating OS/argv startup from global
;; initialization without requiring a backend-owned `_tl_start` hook.
(import stdlib.profile)

(define compiler-startup-clock-globals-start-tick : i64
  (profile.now-ticks))

(define (compiler-startup-clock-globals-start) : i64
  compiler-startup-clock-globals-start-tick)