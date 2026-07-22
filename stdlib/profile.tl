;# Runtime profiling helper API.
;#
;# Provides allocation counters and a coarse monotonic millisecond timestamp.
;# Time is implemented here over platform FFI/syscalls; allocation counters remain
;# allocator-runtime hooks. Import explicitly with `(import stdlib.profile)`.
(import stdlib.array)

;: Shared scratch for the time helper's OS out-parameters. Allocated once at
;: module initialization so `now-ms` does not allocate on every sample.
(define now-scratch : (Array i64)
  (array.make-array i64 2))

;: Windows kernel32 high-resolution performance counter bindings.
(cfg
  windows
  (extern (windows-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (windows-query-performance-frequency [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

;: Runtime hook backing `alloc-total`.
(extern (alloc-total-hook) : i64 (:symbol "tl_profile_alloc_total"))

;: Runtime hook backing `alloc-live`.
(extern (alloc-live-hook) : i64 (:symbol "tl_profile_alloc_live"))

;: Runtime hook backing `alloc-peak`.
(extern (alloc-peak-hook) : i64 (:symbol "tl_profile_alloc_peak"))

;: Runtime hook backing `alloc-reset-peak`.
(extern (alloc-reset-peak-hook) : unit (:symbol "tl_profile_alloc_reset_peak"))

;; The runtime exposes one resettable peak counter, while compiler phase
;; profiling nests driver, typecheck, lower, optimize, and backend resets. Keep
;; a second source-level accumulator so those local resets cannot erase the
;; compile-wide high-water mark.
(cfg
  compile-profile
  (define compile-wide-peak-active : bool
    false))
(cfg
  compile-profile
  (define compile-wide-peak-start-live : i64
    0))
(cfg
  compile-profile
  (define compile-wide-peak-best : i64
    0))

(cfg
  compile-profile
  (define (compile-wide-peak-note!) : unit
    (if compile-wide-peak-active
      (let
        [delta : i64 (- (alloc-peak-hook) compile-wide-peak-start-live)]
        (if (> delta compile-wide-peak-best)
          (set! compile-wide-peak-best delta)
          unit))
      unit)))

(cfg
  compile-profile
  (define (compile-wide-peak-start!) : unit
    (begin
      (set! compile-wide-peak-start-live (alloc-live-hook))
      (set! compile-wide-peak-best 0)
      (set! compile-wide-peak-active true)
      ;; Discard any process-lifetime peak from before this compile.
      (alloc-reset-peak-hook))))

(cfg
  compile-profile
  (define (compile-wide-peak-finish!) : i64
    (begin
      (compile-wide-peak-note!)
      (set! compile-wide-peak-active false)
      compile-wide-peak-best)))

;: Return a pointer to one slot in the shared timestamp scratch buffer.
(define (scratch-ptr [slot : i64]) : (MutPtr i64)
  (unsafe
    (ptr-offset (ptr-cast (array-data now-scratch) : (MutPtr i64)) slot)))

;: Return the shared timestamp scratch data address for raw Linux syscalls.
(define (scratch-addr) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data now-scratch) : (Ptr u8))) : i64)))

;: Linux `clock_gettime(CLOCK_MONOTONIC)` via raw syscall 228.
(define (linux-now-ticks) : i64
  (let
    [status : i64
      (unsafe
        (syscall 228 1 (scratch-addr)))]
    (if (< status 0)
      0
      (+ (* (array-ref now-scratch 0) 1000000000) (array-ref now-scratch 1)))))

;: Linux monotonic ticks per second. `linux-now-ticks` returns nanoseconds.
(define (linux-ticks-per-second) : i64
  1000000000)

;: Linux `clock_gettime(CLOCK_MONOTONIC)` in coarse milliseconds.
(define (linux-now-ms) : i64
  (let
    [status : i64
      (unsafe
        (syscall 228 1 (scratch-addr)))]
    (if (< status 0)
      0
      (+
        (* (array-ref now-scratch 0) 1000)
        (/ (array-ref now-scratch 1) 1000000)))))

;: Windows raw `QueryPerformanceCounter` timestamp.
(cfg
  windows
  (define (windows-now-ticks) : i64
    (if (= (windows-query-performance-counter (scratch-ptr 0)) (cast 0 : i32))
      0
      (array-ref now-scratch 0))))

;: Windows `QueryPerformanceCounter` ticks per second.
(cfg
  windows
  (define (windows-ticks-per-second) : i64
    (if (= (windows-query-performance-frequency (scratch-ptr 1)) (cast 0 : i32))
      0
      (array-ref now-scratch 1))))

;: Windows `QueryPerformanceCounter/Frequency` timestamp.
(cfg
  windows
  (define (windows-now-ms) : i64
    (let
      [counter-ok : i32 (windows-query-performance-counter (scratch-ptr 0))]
      [freq-ok : i32 (windows-query-performance-frequency (scratch-ptr 1))]
      [freq : i64 (array-ref now-scratch 1)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        0
        (if (= freq 0)
          0
          (/ (* (array-ref now-scratch 0) 1000) freq))))))

;: Return a coarse monotonic timestamp in milliseconds.
(define (now-ms) : i64
  (cfg windows (windows-now-ms) (linux-now-ms)))

;: Return a high-resolution monotonic timestamp in platform-native ticks.
;: Windows returns QueryPerformanceCounter ticks; Linux returns nanoseconds.
(define (now-ticks) : i64
  (cfg windows (windows-now-ticks) (linux-now-ticks)))

;: Return the number of `now-ticks` units in one second.
(define (ticks-per-second) : i64
  (cfg windows (windows-ticks-per-second) (linux-ticks-per-second)))

;: Return total allocated bytes since process start.
(define (alloc-total) : i64
  (alloc-total-hook))

;: Return currently live bytes in runtime allocation arenas.
(define (alloc-live) : i64
  (alloc-live-hook))

;: Return the peak live byte count since process start or last peak reset.
(define (alloc-peak) : i64
  (alloc-peak-hook))

;: Reset the peak live byte counter to the current live byte count.
(define (alloc-reset-peak) : unit
  (begin
    (cfg compile-profile (compile-wide-peak-note!) unit)
    (alloc-reset-peak-hook)))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (test-fail)))

;: Allocate an array so allocation counters have observable work.
(define (test-allocation) : (Array i64)
  (let
    [items : (Array i64) (array.make-array i64 4)]
    (begin
      (array-set! items 0 12)
      items)))

(test
  profile-api
  (begin
    (test-assert (>= (now-ms) 0))
    (test-assert (> (ticks-per-second) 0))
    (test-assert (> (now-ticks) 0))
    (alloc-reset-peak)
    (let
      [before-total : i64 (alloc-total)]
      [before-live : i64 (alloc-live)]
      [items : (Array i64) (test-allocation)]
      [after-total : i64 (alloc-total)]
      [after-live : i64 (alloc-live)]
      [peak : i64 (alloc-peak)]
      (begin
        (test-assert (= (array-length items) 4))
        (test-assert (= (array-ref items 0) 12))
        (test-assert (>= after-total before-total))
        (test-assert (>= after-live before-live))
        (test-assert (>= peak after-live))))))