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

;; Validate one native timestamp response without allocating. Nonnegative
;; values are milliseconds; -1 is malformed native output, -2 is arithmetic
;; range failure, and -3 is a failed host call. Kind 0 is Linux timespec, kind
;; 1 is Windows QPC, and kind 2 is Windows FILETIME.
(define (timespec-ms
  [kind : i64]
  [status : i64]
  [status2 : i64]
  [left : i64]
  [right : i64]) : i64
  (cond
    [(= kind 0)
      (if (< status 0)
        -3
        (if (or (< left 0) (< right 0) (>= right 1000000000))
          -1
          (let
            [fraction : i64 (/ right 1000000)]
            [limit : i64 (/ 9223372036854775807 1000)]
            (if (> left limit)
              -2
              (let
                [whole : i64 (* left 1000)]
                (if (> fraction (- 9223372036854775807 whole))
                  -2
                  (+ whole fraction)))))))]
    [(= kind 1)
      (if (or (= status 0) (= status2 0))
        -3
        (if (or (< left 0) (<= right 0))
          -1
          (let
            [seconds : i64 (/ left right)]
            [remainder : i64 (% left right)]
            [fraction : i64
              (if (<= remainder (/ 9223372036854775807 1000))
                (/ (* remainder 1000) right)
                (let
                  [bit : i64 512]
                  [quotient : i64 0]
                  [rest : i64 0]
                  (begin
                    (while (> bit 0)
                      (begin
                        (if (>= rest (- right rest))
                          (begin
                            (set! rest (- rest (- right rest)))
                            (set! quotient (+ (* quotient 2) 1)))
                          (begin
                            (set! rest (+ rest rest))
                            (set! quotient (* quotient 2))))
                        (if (not (= (bit-and 1000 bit) 0))
                          (if (>= rest (- right remainder))
                            (begin
                              (set! rest (- rest (- right remainder)))
                              (set! quotient (+ quotient 1)))
                            (set! rest (+ rest remainder)))
                          unit)
                        (set! bit (/ bit 2))))
                    quotient)))]
            [limit : i64 (/ 9223372036854775807 1000)]
            (if (> seconds limit)
              -2
              (let
                [whole : i64 (* seconds 1000)]
                (if (> fraction (- 9223372036854775807 whole))
                  -2
                  (+ whole fraction)))))))]
    [(= kind 2)
      (if (or (< left 0) (> left 4294967295) (< right 0) (> right 4294967295))
        -1
        (let
          [ticks : u64 (bit-or (cast left : u64) (shl (cast right : u64) 32))]
          [milliseconds : u64 (/ ticks (cast 10000 : u64))]
          [offset : u64 (cast 11644473600000 : u64)]
          (if (< milliseconds offset)
            -1
            (let
              [unix-ms : u64 (- milliseconds offset)]
              (if (> unix-ms (cast 9223372036854775807 : u64))
                -2
                (cast unix-ms : i64))))))]
    [else -3]))

;: Fill a Linux `timespec {sec,nsec}` without overflowing for any nonnegative i64 milliseconds.
(define (timespec-from-ms!
  [timespec : (&mut timespec (__tl_dyn-array i64))]
  [milliseconds : i64]) : unit
  (begin
    (set! (array-ref timespec 0) (/ milliseconds 1000))
    (set! (array-ref timespec 1) (* (% milliseconds 1000) 1000000))))

;: Linux `clock_gettime(clock_id)` via raw syscall 228.
(cfg
  (not windows)
  (define (linux-clock-ms [clock-id : i64]) : ResultTimeMs
    (let
      [timespec : (Array i64 2) (array 0 0)]
      [status : i64
        (unsafe
          (syscall
            228
            clock-id
            (cast (ptr->int (ptr-cast (ptr-addr-of timespec) : (Ptr u8))) : i64)))]
      [milliseconds : i64
        (stdlib.time.timespec-ms
          0
          status
          1
          (array-ref timespec 0)
          (array-ref timespec 1))]
      (cond
        [(= milliseconds -3)
          (stdlib.time.unavailable "time: clock_gettime unavailable")]
        [(= milliseconds -1)
          (stdlib.time.unavailable
            "time: clock_gettime returned invalid timestamp")]
        [(= milliseconds -2)
          (stdlib.time.unavailable "time: clock_gettime timestamp out of range")]
        [else (OkTimeMs milliseconds)]))))

;: Linux blocking sleep via raw `nanosleep` syscall 35.
(cfg
  (not windows)
  (define (linux-sleep-ms [milliseconds : i64]) : ResultTimeUnit
    (let
      [request : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      [remaining : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      [done : bool false]
      [ok : bool false]
      (begin
        (stdlib.time.timespec-from-ms! (&mut request) milliseconds)
        (while (not done)
          (let
            [status : i64
              (unsafe
                (syscall
                  35
                  (unsafe
                    (cast
                      (ptr->int (ptr-cast (__tl_array-data request) : (Ptr u8)))
                      : i64))
                  (unsafe
                    (cast
                      (ptr->int
                        (ptr-cast (__tl_array-data remaining) : (Ptr u8)))
                      : i64))))]
            (if (= status 0)
              (begin
                (set! ok true)
                (set! done true))
              (if (= status -4)
                (begin
                  (set! (array-ref request 0) (array-ref remaining 0))
                  (set! (array-ref request 1) (array-ref remaining 1)))
                (set! done true)))))
        (if ok
          (OkTimeUnit)
          (stdlib.time.sleep-unavailable "time: nanosleep unavailable"))))))

;: Windows kernel32 `GetSystemTimeAsFileTime` binding.
(cfg
  windows
  (extern (windows-get-system-time-as-file-time [arg0 : (MutPtr u32)]) : unit (:symbol "GetSystemTimeAsFileTime")))

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

;: Windows wall-clock Unix milliseconds via `GetSystemTimeAsFileTime`.
(cfg
  windows
  (define (windows-unix-ms) : ResultTimeMs
    (let
      [file-time : (Array u32 2) (array (cast 0 : u32) (cast 0 : u32))]
      [_ok : unit
        (stdlib.time.windows-get-system-time-as-file-time
          (unsafe
            (ptr-cast (ptr-addr-of file-time) : (MutPtr u32))))]
      [milliseconds : i64
        (stdlib.time.timespec-ms
          2
          1
          1
          (cast (array-ref file-time 0) : i64)
          (cast (array-ref file-time 1) : i64))]
      (cond
        [(= milliseconds -1)
          (stdlib.time.unavailable "time: system time before Unix epoch")]
        [(= milliseconds -2)
          (stdlib.time.unavailable "time: system time timestamp out of range")]
        [else (OkTimeMs milliseconds)]))))

;: Windows monotonic milliseconds via `QueryPerformanceCounter/Frequency`.
(cfg
  windows
  (define (windows-monotonic-ms) : ResultTimeMs
    (let
      [counter : i64 0]
      [frequency : i64 0]
      [counter-ok : i32
        (stdlib.time.windows-query-performance-counter
          (unsafe
            (ptr-addr-of counter)))]
      [freq-ok : i32
        (stdlib.time.windows-query-performance-frequency
          (unsafe
            (ptr-addr-of frequency)))]
      [milliseconds : i64
        (stdlib.time.timespec-ms
          1
          (cast counter-ok : i64)
          (cast freq-ok : i64)
          counter
          frequency)]
      (cond
        [(= milliseconds -3)
          (stdlib.time.unavailable "time: performance counter unavailable")]
        [(= milliseconds -1)
          (stdlib.time.unavailable
            "time: performance counter returned invalid timestamp")]
        [(= milliseconds -2)
          (stdlib.time.unavailable
            "time: performance counter timestamp out of range")]
        [else (OkTimeMs milliseconds)]))))

;: Select one finite Windows sleep chunk, never the `0xffffffff` INFINITE sentinel.
(cfg
  windows
  (define (windows-sleep-chunk-ms [remaining : i64]) : u32
    (cast
      (if (> remaining (cast 4294967294 : i64))
        (cast 4294967294 : i64)
        remaining)
      : u32)))

;: Convert a sub-second millisecond remainder to the first counter tick at or after it.
(cfg
  windows
  (define (windows-sleep-remainder-ticks
    [millisecond-remainder : i64]
    [frequency : i64]) : i64
    (+
      (* millisecond-remainder (/ frequency 1000))
      (/ (+ (* millisecond-remainder (% frequency 1000)) 999) 1000))))

;: True once a performance-counter interval covers the requested duration.
(cfg
  windows
  (define (windows-sleep-complete?
    [elapsed-ticks : i64]
    [frequency : i64]
    [milliseconds : i64]) : bool
    (let
      [elapsed-seconds : i64 (/ elapsed-ticks frequency)]
      [requested-seconds : i64 (/ milliseconds 1000)]
      (or
        (> elapsed-seconds requested-seconds)
        (and
          (= elapsed-seconds requested-seconds)
          (>=
            (% elapsed-ticks frequency)
            (stdlib.time.windows-sleep-remainder-ticks
              (% milliseconds 1000)
              frequency)))))))

;: Windows blocking sleep split into finite `DWORD` chunks and checked against QPC.
(cfg
  windows
  (define (windows-sleep-ms [milliseconds : i64]) : ResultTimeUnit
    (let
      [counter : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [frequency-buffer : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [counter-ok : i32
        (stdlib.time.windows-query-performance-counter
          (unsafe
            (__tl_array-data counter)))]
      [frequency-ok : i32
        (stdlib.time.windows-query-performance-frequency
          (unsafe
            (__tl_array-data frequency-buffer)))]
      [frequency : i64 (array-ref frequency-buffer 0)]
      [start : i64 (array-ref counter 0)]
      [remaining : i64 milliseconds]
      [done : bool false]
      [ok : bool false]
      (begin
        (if (or
          (= counter-ok (cast 0 : i32))
          (= frequency-ok (cast 0 : i32))
          (<= frequency 0))
          (set! done true)
          unit)
        (while (not done)
          (let
            [chunk : u32 (stdlib.time.windows-sleep-chunk-ms remaining)]
            (begin
              (stdlib.time.windows-sleep chunk)
              (if (> remaining (cast chunk : i64))
                (set! remaining (- remaining (cast chunk : i64)))
                (set! remaining 0))
              (let
                [status : i32
                  (stdlib.time.windows-query-performance-counter
                    (unsafe
                      (__tl_array-data counter)))]
                [elapsed : i64 (- (array-ref counter 0) start)]
                (if (or (= status (cast 0 : i32)) (< elapsed 0))
                  (set! done true)
                  (if (stdlib.time.windows-sleep-complete?
                    elapsed
                    frequency
                    milliseconds)
                    (begin
                      (set! ok true)
                      (set! done true))
                    (if (= remaining 0)
                      (set! remaining 1)
                      unit)))))))
        (if ok
          (OkTimeUnit)
          (stdlib.time.sleep-unavailable
            "time: performance counter unavailable"))))))

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
    (stdlib.time.test-assert-i64-eq
      (comptime (size-of (type (Array i64 2))))
      16)
    (stdlib.time.test-assert-i64-eq
      (comptime (align-of (type (Array i64 2))))
      8)
    (stdlib.time.test-assert-i64-eq (comptime (size-of (type (Array u32 2)))) 8)
    (stdlib.time.test-assert-i64-eq
      (comptime (align-of (type (Array u32 2))))
      4)
    (stdlib.time.test-assert-result-error-shape)
    (stdlib.time.test-assert-unit-error
      (stdlib.time.sleep-ms -1)
      "time: sleep duration must be nonnegative")
    (stdlib.time.test-assert-unit-ok (stdlib.time.sleep-ms 0))
    (let
      [converted : (__tl_dyn-array i64) (__tl_make-array i64 2)]
      (begin
        (stdlib.time.timespec-from-ms! (&mut converted) 9223372036854775807)
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
          4294967294)
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.windows-sleep-remainder-ticks 1 3)
          1)
        (stdlib.time.test-assert-i64-eq
          (stdlib.time.windows-sleep-remainder-ticks 999 3)
          3)
        (stdlib.time.test-assert
          (not (stdlib.time.windows-sleep-complete? 189999 10000000 19)))
        (stdlib.time.test-assert
          (stdlib.time.windows-sleep-complete? 190000 10000000 19)))
      (begin
        unit))
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