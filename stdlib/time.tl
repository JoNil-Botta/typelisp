;# Portable wall-clock and monotonic timestamp helpers.
;#
;# This module owns user-facing time names separately from `profile.tl`.
;# It exposes coarse millisecond timestamps and a portable blocking sleep.
;# Calendar conversion, formatting, time zones, locale behavior, timers, and
;# scheduling are out of scope.
;#
;# Usage: `(import stdlib.time)`
;#
;# ```typelisp
;# (import stdlib.time)
;# (define (main) : i64
;#   (match (time.sleep-ms 1)
;#     [(time.OkTimeUnit) 42]
;#     [(time.ErrTimeUnit _) 1]))
;# ```
(import stdlib.array)
(import stdlib.string)

;: Recoverable time source error.
(defenum TimeError
  (TimeUnavailable String))

;: Result of reading a millisecond timestamp.
(defenum ResultTimeMs
  (OkTimeMs i64)
  (ErrTimeMs TimeError))

;: Result of a time operation that returns no value.
(defenum ResultTimeUnit
  (OkTimeUnit)
  (ErrTimeUnit TimeError))

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

;: Shared error result for unavailable platform sleep operations.
(define (sleep-unavailable [message : String]) : ResultTimeUnit
  (ErrTimeUnit (TimeUnavailable message)))

;: Convert a `timespec {sec,nsec}` array to milliseconds.
(define (timespec-ms [timespec : (Array i64)]) : i64
  (+ (* (array-ref timespec 0) 1000) (/ (array-ref timespec 1) 1000000)))

;: Fill a Linux `timespec {sec,nsec}` without overflowing for any nonnegative i64 milliseconds.
(define (timespec-from-ms! [timespec : (Array i64)] [milliseconds : i64]) : unit
  (begin
    (array-set! timespec 0 (/ milliseconds 1000))
    (array-set! timespec 1 (* (% milliseconds 1000) 1000000))))

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

;: True when a raw Linux syscall result requests a nanosleep restart.
(cfg
  (not windows)
  (define (linux-sleep-interrupted? [status : i64]) : bool
    (= status -4)))

;: Linux blocking sleep via raw `nanosleep` syscall 35.
(cfg
  (not windows)
  (define (linux-sleep-ms [milliseconds : i64]) : ResultTimeUnit
    (let
      [request : (Array i64) (array.make-array i64 2)]
      [remaining : (Array i64) (array.make-array i64 2)]
      [done : bool false]
      [ok : bool false]
      (begin
        (stdlib.time.timespec-from-ms! request milliseconds)
        (while (not done)
          (let
            [status : i64
              (unsafe
                (syscall
                  35
                  (stdlib.time.array-addr request)
                  (stdlib.time.array-addr remaining)))]
            (if (= status 0)
              (begin
                (set! ok true)
                (set! done true))
              (if (stdlib.time.linux-sleep-interrupted? status)
                (begin
                  (array-set! request 0 (array-ref remaining 0))
                  (array-set! request 1 (array-ref remaining 1)))
                (set! done true)))))
        (if ok
          (OkTimeUnit)
          (stdlib.time.sleep-unavailable "time: nanosleep unavailable"))))))

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

;: Windows kernel32 blocking `Sleep` binding.
(cfg
  windows
  (extern (windows-sleep [milliseconds : u32]) : unit (:symbol "Sleep")))

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

;: Largest finite duration accepted by one Windows `Sleep` call.
(cfg
  windows
  (define (windows-sleep-max-chunk-ms) : i64
    4294967294))

;: Select one finite Windows sleep chunk, never the `0xffffffff` INFINITE sentinel.
(cfg
  windows
  (define (windows-sleep-chunk-ms [remaining : i64]) : u32
    (cast
      (if (> remaining (stdlib.time.windows-sleep-max-chunk-ms))
        (stdlib.time.windows-sleep-max-chunk-ms)
        remaining)
      : u32)))

;: Windows blocking sleep split into finite `DWORD` chunks.
(cfg
  windows
  (define (windows-sleep-ms [milliseconds : i64]) : ResultTimeUnit
    (let
      [remaining : i64 milliseconds]
      (begin
        (while (> remaining 0)
          (let
            [chunk : u32 (stdlib.time.windows-sleep-chunk-ms remaining)]
            (begin
              (stdlib.time.windows-sleep chunk)
              (set! remaining (- remaining (cast chunk : i64))))))
        (OkTimeUnit)))))

;: Return wall-clock Unix epoch milliseconds.
(define (unix-ms) : ResultTimeMs
  (cfg windows (stdlib.time.windows-unix-ms) (stdlib.time.linux-clock-ms 0)))

;: Return monotonic elapsed milliseconds. The epoch is platform-defined.
(define (monotonic-ms) : ResultTimeMs
  (cfg
    windows
    (stdlib.time.windows-monotonic-ms)
    (stdlib.time.linux-clock-ms 1)))

;: Block the current thread for at least `milliseconds` of relative time.
;:
;: Negative durations return `ErrTimeUnit`; zero is an immediate successful
;: no-op. The operation may wake later than requested and does not promise
;: scheduler fairness. Linux restarts an interrupted wait from the kernel's
;: returned remainder. Windows uses finite chunks and never passes `INFINITE`.
(define (sleep-ms [milliseconds : i64]) : ResultTimeUnit
  (if (< milliseconds 0)
    (stdlib.time.sleep-unavailable "time: sleep duration must be nonnegative")
    (if (= milliseconds 0)
      (OkTimeUnit)
      (cfg
        windows
        (stdlib.time.windows-sleep-ms milliseconds)
        (stdlib.time.linux-sleep-ms milliseconds)))))

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

;: Inline test assertion for a successful unit result.
(define (test-assert-unit-ok [result : ResultTimeUnit]) : unit
  (match result
    [(OkTimeUnit) unit]
    [(ErrTimeUnit _) (stdlib.time.test-fail)]))

;: Inline test assertion for a unit error result.
(define (test-assert-unit-error [result : ResultTimeUnit] [message : String]) : unit
  (match result
    [(OkTimeUnit) (stdlib.time.test-fail)]
    [(ErrTimeUnit err)
      (stdlib.time.test-assert-string-eq
        (stdlib.time.error-message err)
        message)]))

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
    (stdlib.time.test-assert-unit-error
      (stdlib.time.sleep-ms -1)
      "time: sleep duration must be nonnegative")
    (stdlib.time.test-assert-unit-ok (stdlib.time.sleep-ms 0))
    (let
      [converted : (Array i64) (array.make-array i64 2)]
      (begin
        (stdlib.time.timespec-from-ms! converted 9223372036854775807)
        (stdlib.time.test-assert-i64-eq
          (array-ref converted 0)
          9223372036854775)
        (stdlib.time.test-assert-i64-eq (array-ref converted 1) 807000000)))
    (cfg
      windows
      (begin
        (stdlib.time.test-assert-i64-eq
          (cast (stdlib.time.windows-sleep-chunk-ms 1) : i64)
          1)
        (stdlib.time.test-assert-i64-eq
          (cast (stdlib.time.windows-sleep-chunk-ms 4294967294) : i64)
          4294967294)
        (stdlib.time.test-assert-i64-eq
          (cast (stdlib.time.windows-sleep-chunk-ms 4294967295) : i64)
          4294967294))
      (begin
        (stdlib.time.test-assert (stdlib.time.linux-sleep-interrupted? -4))
        (stdlib.time.test-assert
          (not (stdlib.time.linux-sleep-interrupted? -1)))))
    (stdlib.time.test-assert-unix-range (stdlib.time.unix-ms))
    (let
      [first : i64
        (stdlib.time.test-assert-monotonic-nonnegative
          (stdlib.time.monotonic-ms))]
      [_sleep-ok : unit
        (stdlib.time.test-assert-unit-ok (stdlib.time.sleep-ms 20))]
      [second : i64
        (stdlib.time.test-assert-monotonic-nonnegative
          (stdlib.time.monotonic-ms))]
      (begin
        (stdlib.time.test-assert (>= (- second first) 1))
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.ms-or (OkTimeMs 123) 0)
          123)
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.ms-or (ErrTimeMs (TimeUnavailable "x")) 7)
          7)))))