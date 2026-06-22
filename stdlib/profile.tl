;# Runtime profiling helper API.
;#
;# Provides allocation counters and a coarse monotonic millisecond timestamp.
;# Time is implemented here over platform FFI/syscalls; allocation counters remain
;# allocator-runtime hooks. Import explicitly with `(import stdlib.profile)`.
(module stdlib.profile)

;: Shared scratch for the time helper's OS out-parameters. Allocated once at
;: module initialization so `profile-now-ms` does not allocate on every sample.
(define profile-now-scratch : (Array i64)
  (make-array i64 2))

;: Windows kernel32 high-resolution performance counter bindings.
(cfg
  windows
  (extern (profile-win-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (profile-win-query-performance-frequency [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

;: Runtime hook backing `profile-alloc-total`.
(extern (tl_profile_alloc_total) : i64)

;: Runtime hook backing `profile-alloc-live`.
(extern (tl_profile_alloc_live) : i64)

;: Runtime hook backing `profile-alloc-peak`.
(extern (tl_profile_alloc_peak) : i64)

;: Runtime hook backing `profile-alloc-reset-peak`.
(extern (tl_profile_alloc_reset_peak) : unit)

;: Return a pointer to one slot in the shared timestamp scratch buffer.
(define (profile-scratch-ptr [slot : i64]) : (MutPtr i64)
  (unsafe
    (ptr-offset
      (ptr-cast (array-data stdlib.profile.profile-now-scratch) : (MutPtr i64))
      slot)))

;: Return the shared timestamp scratch data address for raw Linux syscalls.
(define (profile-scratch-addr) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast (array-data stdlib.profile.profile-now-scratch) : (Ptr u8)))
      : i64)))

;: Linux `clock_gettime(CLOCK_MONOTONIC)` via raw syscall 228.
(define (profile-linux-now-ms) : i64
  (let
    [status : i64
      (unsafe
        (syscall 228 1 (stdlib.profile.profile-scratch-addr)))]
    (if (< status 0)
      0
      (+
        (* (array-ref stdlib.profile.profile-now-scratch 0) 1000)
        (/ (array-ref stdlib.profile.profile-now-scratch 1) 1000000)))))

;: Windows `QueryPerformanceCounter/Frequency` timestamp.
(cfg
  windows
  (define (profile-windows-now-ms) : i64
    (let
      [counter-ok : i32
        (stdlib.profile.profile-win-query-performance-counter
          (stdlib.profile.profile-scratch-ptr 0))]
      [freq-ok : i32
        (stdlib.profile.profile-win-query-performance-frequency
          (stdlib.profile.profile-scratch-ptr 1))]
      [freq : i64 (array-ref stdlib.profile.profile-now-scratch 1)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        0
        (if (= freq 0)
          0
          (/ (* (array-ref stdlib.profile.profile-now-scratch 0) 1000) freq))))))

;: Return a coarse monotonic timestamp in milliseconds.
(define (profile-now-ms) : i64
  (cfg
    windows
    (stdlib.profile.profile-windows-now-ms)
    (stdlib.profile.profile-linux-now-ms)))

;: Return total allocated bytes since process start.
(define (profile-alloc-total) : i64
  (stdlib.profile.tl_profile_alloc_total))

;: Return currently live bytes in runtime allocation arenas.
(define (profile-alloc-live) : i64
  (stdlib.profile.tl_profile_alloc_live))

;: Return the peak live byte count since process start or last peak reset.
(define (profile-alloc-peak) : i64
  (stdlib.profile.tl_profile_alloc_peak))

;: Reset the peak live byte counter to the current live byte count.
(define (profile-alloc-reset-peak) : unit
  (stdlib.profile.tl_profile_alloc_reset_peak))

;: Inline test failure helper.
(define (profile-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (profile-test-assert [ok : bool]) : unit
  (if ok
    unit
    (stdlib.profile.profile-test-fail)))

;: Allocate an array so allocation counters have observable work.
(define (profile-test-allocation) : (Array i64)
  (let
    [items : (Array i64) (make-array i64 4)]
    (begin
      (array-set! items 0 12)
      items)))

(test
  profile-api
  (begin
    (stdlib.profile.profile-test-assert (>= (stdlib.profile.profile-now-ms) 0))
    (stdlib.profile.profile-alloc-reset-peak)
    (let
      [before-total : i64 (stdlib.profile.profile-alloc-total)]
      [before-live : i64 (stdlib.profile.profile-alloc-live)]
      [items : (Array i64) (stdlib.profile.profile-test-allocation)]
      [after-total : i64 (stdlib.profile.profile-alloc-total)]
      [after-live : i64 (stdlib.profile.profile-alloc-live)]
      [peak : i64 (stdlib.profile.profile-alloc-peak)]
      (begin
        (stdlib.profile.profile-test-assert (= (array-length items) 4))
        (stdlib.profile.profile-test-assert (= (array-ref items 0) 12))
        (stdlib.profile.profile-test-assert (>= after-total before-total))
        (stdlib.profile.profile-test-assert (>= after-live before-live))
        (stdlib.profile.profile-test-assert (>= peak after-live))))))

(cfg
  windows
  (export
    (value profile-win-query-performance-counter)
    (value profile-win-query-performance-frequency)
    (value profile-windows-now-ms)))

(cfg
  test
  (export
    (value profile-test-fail)
    (value profile-test-assert)
    (value profile-test-allocation)))

(export
  (value profile-now-scratch)
  (value tl_profile_alloc_total)
  (value tl_profile_alloc_live)
  (value tl_profile_alloc_peak)
  (value tl_profile_alloc_reset_peak)
  (value profile-scratch-ptr)
  (value profile-scratch-addr)
  (value profile-linux-now-ms)
  (value profile-now-ms)
  (value profile-alloc-total)
  (value profile-alloc-live)
  (value profile-alloc-peak)
  (value profile-alloc-reset-peak))