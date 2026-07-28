;; compiler_startup_clock.tl - Earliest source-level startup timestamp.
;;
;; Keep this module's dependency graph deliberately small and import it before
;; the compiler graph. Its initializer runs after the platform timer scratch is
;; ready but before compiler globals, separating OS/argv startup from global
;; initialization. The process-entry hook is selected by this extern's presence,
;; so ordinary compiles do not gain runtime data or entry instructions.
(import stdlib.profile)

(extern (compiler-startup-clock-process-entry) : i64 (:symbol "tl_startup_profile_process_entry_tick"))

(define compiler-startup-clock-globals-start-tick : i64
  (profile.now-ticks))

(define (compiler-startup-clock-process-entry-tick) : i64
  (compiler-startup-clock-process-entry))

(define (compiler-startup-clock-globals-start) : i64
  compiler-startup-clock-globals-start-tick)