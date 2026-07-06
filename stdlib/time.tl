;# Portable wall-clock and monotonic timestamp helpers.
;#
;# This module owns user-facing time names separately from `profile.tl`.
;# It exposes coarse millisecond timestamps only: Unix wall-clock milliseconds
;# and monotonic elapsed milliseconds. Calendar conversion, formatting, time
;# zones, locale behavior, sleep, timers, and scheduling are out of scope.
;#
;# Usage: `(import stdlib.time)`
;#
;# ```typelisp
;# (import stdlib.time)
;# (define (main) : i64
;#   (match (time.unix-ms)
;#     [(time.OkTimeMs ms) (if (> ms 0) 42 1)]
;#     [(time.ErrTimeMs _) 2]))
;# ```
(module stdlib.time)

(import stdlib.array)
(import stdlib.string)

;: Recoverable time source error.
(defenum TimeError
  (TimeUnavailable String))

;: Result of reading a millisecond timestamp.
(defenum ResultTimeMs
  (OkTimeMs i64)
  (ErrTimeMs TimeError))

;: Return a human-readable time error message.
(define (error-message [err : TimeError]) : String
  (match err
    [(TimeUnavailable message) message]))

;: Return the timestamp value from an `OkTimeMs` result, or `fallback`.
(define (ms-or [result : ResultTimeMs] [fallback : i64]) : i64
  (match result
    [(OkTimeMs ms) ms]
    [(ErrTimeMs _) fallback]))

;: Shared error result for unavailable platform time sources.
(define (unavailable [message : String]) : ResultTimeMs
  (ErrTimeMs (TimeUnavailable message)))

;: Convert a `timespec {sec,nsec}` array to milliseconds.
(define (timespec-ms [timespec : (Array i64)]) : i64
  (+ (* (array-ref timespec 0) 1000) (/ (array-ref timespec 1) 1000000)))

;: Return the raw data address of an `i64` array for Linux syscalls.
(cfg
  (not windows)
  (define (array-addr [items : (Array i64)]) : i64
    (unsafe
      (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64))))

;: Linux `clock_gettime(clock_id)` via raw syscall 228.
(cfg
  (not windows)
  (define (linux-clock-ms [clock-id : i64]) : ResultTimeMs
    (let
      [timespec : (Array i64) (array.make-array i64 2)]
      [status : i64
        (unsafe
          (syscall 228 clock-id (stdlib.time.array-addr timespec)))]
      (if (< status 0)
        (stdlib.time.unavailable "time: clock_gettime unavailable")
        (OkTimeMs (stdlib.time.timespec-ms timespec))))))

;: Windows kernel32 `GetSystemTimeAsFileTime` binding.
(cfg
  windows
  (extern (windows-get-system-time-as-file-time [arg0 : (MutPtr i64)]) : unit (:symbol "GetSystemTimeAsFileTime")))

;: Windows kernel32 high-resolution performance counter bindings.
(cfg
  windows
  (extern (windows-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (windows-query-performance-frequency [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

;: Windows FILETIME milliseconds between 1601-01-01 UTC and Unix epoch.
(cfg
  windows
  (define (windows-filetime-unix-epoch-ms) : i64
    11644473600000))

;: Windows wall-clock Unix milliseconds via `GetSystemTimeAsFileTime`.
(cfg
  windows
  (define (windows-unix-ms) : ResultTimeMs
    (let
      [file-time : (Array i64) (array.make-array i64 1)]
      [_ok : unit
        (stdlib.time.windows-get-system-time-as-file-time
          (unsafe
            (array-data file-time)))]
      [unix-ms : i64
        (-
          (/ (array-ref file-time 0) 10000)
          (stdlib.time.windows-filetime-unix-epoch-ms))]
      (if (< unix-ms 0)
        (stdlib.time.unavailable "time: system time before Unix epoch")
        (OkTimeMs unix-ms)))))

;: Windows monotonic milliseconds via `QueryPerformanceCounter/Frequency`.
(cfg
  windows
  (define (windows-monotonic-ms) : ResultTimeMs
    (let
      [counter : (Array i64) (array.make-array i64 1)]
      [freq : (Array i64) (array.make-array i64 1)]
      [counter-ok : i32
        (stdlib.time.windows-query-performance-counter
          (unsafe
            (array-data counter)))]
      [freq-ok : i32
        (stdlib.time.windows-query-performance-frequency
          (unsafe
            (array-data freq)))]
      [freq-value : i64 (array-ref freq 0)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        (stdlib.time.unavailable "time: performance counter unavailable")
        (if (= freq-value 0)
          (stdlib.time.unavailable
            "time: performance counter frequency is zero")
          (OkTimeMs (/ (* (array-ref counter 0) 1000) freq-value)))))))

;: Return wall-clock Unix epoch milliseconds.
(define (unix-ms) : ResultTimeMs
  (cfg windows (stdlib.time.windows-unix-ms) (stdlib.time.linux-clock-ms 0)))

;: Return monotonic elapsed milliseconds. The epoch is platform-defined.
(define (monotonic-ms) : ResultTimeMs
  (cfg
    windows
    (stdlib.time.windows-monotonic-ms)
    (stdlib.time.linux-clock-ms 1)))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (stdlib.time.test-fail)))

;: Inline test integer assertion.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (stdlib.time.test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (test-assert-string-eq [actual : String] [expected : String]) : unit
  (stdlib.time.test-assert (string.eq actual expected)))

;: Inline test assertion for error result shape.
(define (test-assert-result-error-shape) : unit
  (match (ErrTimeMs (TimeUnavailable "time unavailable"))
    [(OkTimeMs _) (stdlib.time.test-fail)]
    [(ErrTimeMs err)
      (stdlib.time.test-assert-string-eq
        (stdlib.time.error-message err)
        "time unavailable")]))

;: Inline test assertion for wall-clock range.
(define (test-assert-unix-range [result : ResultTimeMs]) : unit
  (match result
    [(OkTimeMs ms)
      (begin
        (stdlib.time.test-assert (> ms 946684800000))
        (stdlib.time.test-assert (< ms 4102444800000)))]
    [(ErrTimeMs _) (stdlib.time.test-fail)]))

;: Inline test assertion for monotonic timestamp shape.
(define (test-assert-monotonic-nonnegative [result : ResultTimeMs]) : i64
  (match result
    [(OkTimeMs ms)
      (begin
        (stdlib.time.test-assert (>= ms 0))
        ms)]
    [(ErrTimeMs _) 0]))

(test
  time-api
  (begin
    (stdlib.time.test-assert-result-error-shape)
    (stdlib.time.test-assert-unix-range (stdlib.time.unix-ms))
    (let
      [first : i64
        (stdlib.time.test-assert-monotonic-nonnegative
          (stdlib.time.monotonic-ms))]
      [second : i64
        (stdlib.time.test-assert-monotonic-nonnegative
          (stdlib.time.monotonic-ms))]
      (begin
        (stdlib.time.test-assert (>= second first))
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.ms-or (OkTimeMs 123) 0)
          123)
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.ms-or (ErrTimeMs (TimeUnavailable "x")) 7)
          7)))))