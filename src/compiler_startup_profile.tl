;; compiler_startup_profile.tl - Low-perturbation one-shot compile markers.
;;
;; This module is imported only under `compile-startup-profile`. Markers retain
;; raw monotonic ticks in one fixed array and render them after compilation, so
;; formatting and stderr I/O cannot inflate the measured compile preamble.
(import compiler_startup_clock as startup_clock)
(import stdlib.array)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define compiler-startup-profile-marker-count : i64
  13)
(define compiler-startup-profile-ticks : (__tl_dyn-array i64)
  (array.make-array i64 compiler-startup-profile-marker-count))

(define (compiler-startup-profile-mark! [index : i64]) : unit
  (array-set! compiler-startup-profile-ticks index (profile.now-ticks)))

(define (compiler-startup-profile-mark-main-entry!) : unit
  (compiler-startup-profile-mark! 0))

(define (compiler-startup-profile-mark-cli-compile-action!) : unit
  (compiler-startup-profile-mark! 1))

(define (compiler-startup-profile-mark-driver-state-begin!) : unit
  (compiler-startup-profile-mark! 2))

(define (compiler-startup-profile-mark-driver-state-end!) : unit
  (compiler-startup-profile-mark! 3))

(define (compiler-startup-profile-mark-preflight-begin!) : unit
  (compiler-startup-profile-mark! 4))

(define (compiler-startup-profile-mark-preflight-end!) : unit
  (compiler-startup-profile-mark! 5))

(define (compiler-startup-profile-mark-file-state-reset-end!) : unit
  (compiler-startup-profile-mark! 6))

(define (compiler-startup-profile-mark-compile-driver-start!) : unit
  (compiler-startup-profile-mark! 7))

(define (compiler-startup-profile-mark-prelude-begin!) : unit
  (compiler-startup-profile-mark! 8))

(define (compiler-startup-profile-mark-surface-begin!) : unit
  (compiler-startup-profile-mark! 9))

(define (compiler-startup-profile-mark-surface-end!) : unit
  (compiler-startup-profile-mark! 10))

(define (compiler-startup-profile-mark-prelude-end!) : unit
  (compiler-startup-profile-mark! 11))

(define (compiler-startup-profile-mark-user-entry-start!) : unit
  (compiler-startup-profile-mark! 12))

(define (compiler-startup-profile-print-row!
  [name : String]
  [index : i64]
  [frequency : i64]) : unit
  (let
    [tick : i64 (array-ref compiler-startup-profile-ticks index)]
    (if (> tick 0)
      (io.print-error
        (str_cat.str-cat
          "compile-startup-profile|"
          name
          "|"
          (string.int->string tick)
          "|"
          (string.int->string frequency)
          "\n"))
      unit)))

(define (compiler-startup-profile-print-tick-row!
  [name : String]
  [tick : i64]
  [frequency : i64]) : unit
  (if (> tick 0)
    (io.print-error
      (str_cat.str-cat
        "compile-startup-profile|"
        name
        "|"
        (string.int->string tick)
        "|"
        (string.int->string frequency)
        "\n"))
    unit))

(define (compiler-startup-profile-print!) : unit
  (let
    [frequency : i64 (profile.ticks-per-second)]
    (begin
      (io.print-error "compile-startup-profile|marker|tick|frequency\n")
      (compiler-startup-profile-print-tick-row!
        "process.entry"
        (startup_clock.compiler-startup-clock-process-entry-tick)
        frequency)
      (compiler-startup-profile-print-tick-row!
        "globals.start"
        (startup_clock.compiler-startup-clock-globals-start)
        frequency)
      (compiler-startup-profile-print-row! "main.entry" 0 frequency)
      (compiler-startup-profile-print-row! "cli.compile_action" 1 frequency)
      (compiler-startup-profile-print-row! "driver_state.begin" 2 frequency)
      (compiler-startup-profile-print-row! "driver_state.end" 3 frequency)
      (compiler-startup-profile-print-row! "preflight.begin" 4 frequency)
      (compiler-startup-profile-print-row! "preflight.end" 5 frequency)
      (compiler-startup-profile-print-row! "file_state_reset.end" 6 frequency)
      (compiler-startup-profile-print-row! "compile_driver.start" 7 frequency)
      (compiler-startup-profile-print-row! "prelude.begin" 8 frequency)
      (compiler-startup-profile-print-row! "surface.begin" 9 frequency)
      (compiler-startup-profile-print-row! "surface.end" 10 frequency)
      (compiler-startup-profile-print-row! "prelude.end" 11 frequency)
      (compiler-startup-profile-print-row! "user_entry.start" 12 frequency))))