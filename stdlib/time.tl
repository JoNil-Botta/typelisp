;# Portable wall-clock and monotonic timestamp helpers (#2679).
;#
;# This module owns user-facing time names separately from `profile.tl`.
;# It exposes coarse millisecond timestamps only: Unix wall-clock milliseconds
;# and monotonic elapsed milliseconds. Calendar conversion, formatting, time
;# zones, locale behavior, sleep, timers, and scheduling are deferred.
;#
;# Usage: `(import "stdlib/time.tl")`
;#
;# ```typelisp
;# (import "stdlib/time.tl")
;# (define (main) : i64
;#   (match (time-unix-ms)
;#     [(OkTimeMs ms) (if (> ms 0) 42 1)]
;#     [(ErrTimeMs _) 2]))
;# ```
;: Recoverable time source error.
(defenum TimeError
  (TimeUnavailable String))

;: Result of reading a millisecond timestamp.
(import "string.tl")

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
          (syscall 228 clock-id (time-array-addr timespec)))]
      (if (< status 0)
        (time-unavailable "time: clock_gettime unavailable")
        (OkTimeMs (time-timespec-ms timespec))))))

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
        (time-windows-get-system-time-as-file-time
          (unsafe
            (array-data file-time)))]
      [unix-ms : i64
        (-
          (/ (array-ref file-time 0) 10000)
          (time-windows-filetime-unix-epoch-ms))]
      (if (< unix-ms 0)
        (time-unavailable "time: system time before Unix epoch")
        (OkTimeMs unix-ms)))))

;: Windows monotonic milliseconds via `QueryPerformanceCounter/Frequency`.
(cfg
  windows
  (define (time-windows-monotonic-ms) : ResultTimeMs
    (let
      [counter : (Array i64) (make-array i64 1)]
      [freq : (Array i64) (make-array i64 1)]
      [counter-ok : i32
        (time-windows-query-performance-counter
          (unsafe
            (array-data counter)))]
      [freq-ok : i32
        (time-windows-query-performance-frequency
          (unsafe
            (array-data freq)))]
      [freq-value : i64 (array-ref freq 0)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        (time-unavailable "time: performance counter unavailable")
        (if (= freq-value 0)
          (time-unavailable "time: performance counter frequency is zero")
          (OkTimeMs (/ (* (array-ref counter 0) 1000) freq-value)))))))

;: Return wall-clock Unix epoch milliseconds.
(define (time-unix-ms) : ResultTimeMs
  (cfg windows (time-windows-unix-ms) (time-linux-clock-ms 0)))

;: Return monotonic elapsed milliseconds. The epoch is platform-defined.
(define (time-monotonic-ms) : ResultTimeMs
  (cfg windows (time-windows-monotonic-ms) (time-linux-clock-ms 1)))

;: Inline test failure helper.
(define (time-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (time-test-assert [ok : bool]) : unit
  (if ok
    unit
    (time-test-fail)))

;: Inline test integer assertion.
(define (time-test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (time-test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (time-test-assert-string-eq [actual : String] [expected : String]) : unit
  (time-test-assert (string-eq actual expected)))

;: Inline test assertion for error result shape.
(define (time-test-assert-result-error-shape) : unit
  (match (ErrTimeMs (TimeUnavailable "time unavailable"))
    [(OkTimeMs _) (time-test-fail)]
    [(ErrTimeMs err)
      (time-test-assert-string-eq (time-error-message err) "time unavailable")]))

;: Inline test assertion for wall-clock range.
(define (time-test-assert-unix-range [result : ResultTimeMs]) : unit
  (match result
    [(OkTimeMs ms)
      (begin
        (time-test-assert (> ms 946684800000))
        (time-test-assert (< ms 4102444800000)))]
    [(ErrTimeMs _) (time-test-fail)]))

;: Inline test assertion for monotonic timestamp shape.
(define (time-test-assert-monotonic-nonnegative [result : ResultTimeMs]) : i64
  (match result
    [(OkTimeMs ms)
      (begin
        (time-test-assert (>= ms 0))
        ms)]
    [(ErrTimeMs _) 0]))

(test
  time-api
  (begin
    (time-test-assert-result-error-shape)
    (time-test-assert-unix-range (time-unix-ms))
    (let
      [first : i64 (time-test-assert-monotonic-nonnegative (time-monotonic-ms))]
      [second : i64
        (time-test-assert-monotonic-nonnegative (time-monotonic-ms))]
      (begin
        (time-test-assert (>= second first))
        (time-test-assert-i64-eq (time-ms-or (OkTimeMs 123) 0) 123)
        (time-test-assert-i64-eq
          (time-ms-or (ErrTimeMs (TimeUnavailable "x")) 7)
          7)))))