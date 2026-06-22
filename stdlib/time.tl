;# Portable wall-clock and monotonic timestamp helpers (#2679).
;#
;# This module owns user-facing time names separately from `profile.tl`.
;# It exposes coarse millisecond timestamps only: Unix wall-clock milliseconds
;# and monotonic elapsed milliseconds. Calendar conversion, formatting, time
;# zones, locale behavior, sleep, timers, and scheduling are deferred.
;#
;# Usage: `(import stdlib.time)`
;#
;# ```typelisp
;# (import stdlib.time)
;# (define (main) : i64
;#   (match (time.time-unix-ms)
;#     [(time.OkTimeMs ms) (if (> ms 0) 42 1)]
;#     [(time.ErrTimeMs _) 2]))
;# ```
(module stdlib.time)

;: Recoverable time source error.
(defenum TimeError
  (TimeUnavailable String))

;: Result of reading a millisecond timestamp.
(defenum ResultTimeMs
  (OkTimeMs i64)
  (ErrTimeMs TimeError))

;: Return a human-readable time error message.
(define (time-error-message [err : TimeError]) : String
  (match err
    [(TimeUnavailable message) message]))

;: Return the timestamp value from an `OkTimeMs` result, or `fallback`.
(define (time-ms-or [result : ResultTimeMs] [fallback : i64]) : i64
  (match result
    [(OkTimeMs ms) ms]
    [(ErrTimeMs _) fallback]))

;: Shared error result for unavailable platform time sources.
(define (time-unavailable [message : String]) : ResultTimeMs
  (ErrTimeMs (TimeUnavailable message)))

;: Convert a `timespec {sec,nsec}` array to milliseconds.
(define (time-timespec-ms [timespec : (Array i64)]) : i64
  (+ (* (array-ref timespec 0) 1000) (/ (array-ref timespec 1) 1000000)))

;: Return the raw data address of an `i64` array for Linux syscalls.
(cfg
  (not windows)
  (define (time-array-addr [items : (Array i64)]) : i64
    (unsafe
      (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64))))

;: Linux `clock_gettime(clock_id)` via raw syscall 228.
(cfg
  (not windows)
  (define (time-linux-clock-ms [clock-id : i64]) : ResultTimeMs
    (let
      [timespec : (Array i64) (make-array i64 2)]
      [status : i64
        (unsafe
          (syscall 228 clock-id (stdlib.time.time-array-addr timespec)))]
      (if (< status 0)
        (stdlib.time.time-unavailable "time: clock_gettime unavailable")
        (OkTimeMs (stdlib.time.time-timespec-ms timespec))))))

;: Windows kernel32 `GetSystemTimeAsFileTime` binding.
(cfg
  windows
  (extern (time-windows-get-system-time-as-file-time [arg0 : (MutPtr i64)]) : unit (:symbol "GetSystemTimeAsFileTime")))

;: Windows kernel32 high-resolution performance counter bindings.
(cfg
  windows
  (extern (time-windows-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (time-windows-query-performance-frequency [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

;: Windows FILETIME milliseconds between 1601-01-01 UTC and Unix epoch.
(cfg
  windows
  (define (time-windows-filetime-unix-epoch-ms) : i64
    11644473600000))

;: Windows wall-clock Unix milliseconds via `GetSystemTimeAsFileTime`.
(cfg
  windows
  (define (time-windows-unix-ms) : ResultTimeMs
    (let
      [file-time : (Array i64) (make-array i64 1)]
      [_ok : unit
        (stdlib.time.time-windows-get-system-time-as-file-time
          (unsafe
            (array-data file-time)))]
      [unix-ms : i64
        (-
          (/ (array-ref file-time 0) 10000)
          (stdlib.time.time-windows-filetime-unix-epoch-ms))]
      (if (< unix-ms 0)
        (stdlib.time.time-unavailable "time: system time before Unix epoch")
        (OkTimeMs unix-ms)))))

;: Windows monotonic milliseconds via `QueryPerformanceCounter/Frequency`.
(cfg
  windows
  (define (time-windows-monotonic-ms) : ResultTimeMs
    (let
      [counter : (Array i64) (make-array i64 1)]
      [freq : (Array i64) (make-array i64 1)]
      [counter-ok : i32
        (stdlib.time.time-windows-query-performance-counter
          (unsafe
            (array-data counter)))]
      [freq-ok : i32
        (stdlib.time.time-windows-query-performance-frequency
          (unsafe
            (array-data freq)))]
      [freq-value : i64 (array-ref freq 0)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        (stdlib.time.time-unavailable "time: performance counter unavailable")
        (if (= freq-value 0)
          (stdlib.time.time-unavailable
            "time: performance counter frequency is zero")
          (OkTimeMs (/ (* (array-ref counter 0) 1000) freq-value)))))))

;: Return wall-clock Unix epoch milliseconds.
(define (time-unix-ms) : ResultTimeMs
  (cfg
    windows
    (stdlib.time.time-windows-unix-ms)
    (stdlib.time.time-linux-clock-ms 0)))

;: Return monotonic elapsed milliseconds. The epoch is platform-defined.
(define (time-monotonic-ms) : ResultTimeMs
  (cfg
    windows
    (stdlib.time.time-windows-monotonic-ms)
    (stdlib.time.time-linux-clock-ms 1)))

;: Inline test failure helper.
(define (time-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (time-test-assert [ok : bool]) : unit
  (if ok
    unit
    (stdlib.time.time-test-fail)))

;: Inline test integer assertion.
(define (time-test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (stdlib.time.time-test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (time-test-assert-string-eq [actual : String] [expected : String]) : unit
  (stdlib.time.time-test-assert (string-eq actual expected)))

;: Inline test assertion for error result shape.
(define (time-test-assert-result-error-shape) : unit
  (match (ErrTimeMs (TimeUnavailable "time unavailable"))
    [(OkTimeMs _) (stdlib.time.time-test-fail)]
    [(ErrTimeMs err)
      (stdlib.time.time-test-assert-string-eq
        (stdlib.time.time-error-message err)
        "time unavailable")]))

;: Inline test assertion for wall-clock range.
(define (time-test-assert-unix-range [result : ResultTimeMs]) : unit
  (match result
    [(OkTimeMs ms)
      (begin
        (stdlib.time.time-test-assert (> ms 946684800000))
        (stdlib.time.time-test-assert (< ms 4102444800000)))]
    [(ErrTimeMs _) (stdlib.time.time-test-fail)]))

;: Inline test assertion for monotonic timestamp shape.
(define (time-test-assert-monotonic-nonnegative [result : ResultTimeMs]) : i64
  (match result
    [(OkTimeMs ms)
      (begin
        (stdlib.time.time-test-assert (>= ms 0))
        ms)]
    [(ErrTimeMs _) 0]))

(test
  time-api
  (begin
    (stdlib.time.time-test-assert-result-error-shape)
    (stdlib.time.time-test-assert-unix-range (stdlib.time.time-unix-ms))
    (let
      [first : i64
        (stdlib.time.time-test-assert-monotonic-nonnegative
          (stdlib.time.time-monotonic-ms))]
      [second : i64
        (stdlib.time.time-test-assert-monotonic-nonnegative
          (stdlib.time.time-monotonic-ms))]
      (begin
        (stdlib.time.time-test-assert (>= second first))
        (stdlib.time.time-test-assert-i64-eq
          (stdlib.time.time-ms-or (OkTimeMs 123) 0)
          123)
        (stdlib.time.time-test-assert-i64-eq
          (stdlib.time.time-ms-or (ErrTimeMs (TimeUnavailable "x")) 7)
          7)))))

(cfg (not windows) (export (value time-array-addr) (value time-linux-clock-ms)))

(cfg
  windows
  (export
    (value time-windows-get-system-time-as-file-time)
    (value time-windows-query-performance-counter)
    (value time-windows-query-performance-frequency)
    (value time-windows-filetime-unix-epoch-ms)
    (value time-windows-unix-ms)
    (value time-windows-monotonic-ms)))

(cfg
  test
  (export
    (value time-test-fail)
    (value time-test-assert)
    (value time-test-assert-i64-eq)
    (value time-test-assert-string-eq)
    (value time-test-assert-result-error-shape)
    (value time-test-assert-unix-range)
    (value time-test-assert-monotonic-nonnegative)))

(export
  (value time-error-message)
  (value time-ms-or)
  (value time-unavailable)
  (value time-timespec-ms)
  (value time-unix-ms)
  (value time-monotonic-ms)
  (type TimeError)
  (type ResultTimeMs)
  (variant TimeUnavailable)
  (variant OkTimeMs)
  (variant ErrTimeMs))