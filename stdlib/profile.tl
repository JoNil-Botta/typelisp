;# Runtime profiling helper API.
;#
;# Provides allocation counters and a coarse monotonic millisecond timestamp.
;# Time is implemented here over platform FFI/syscalls; allocation counters remain
;# allocator-runtime hooks. Import explicitly with `(import stdlib.profile)`.
(module stdlib.profile)

;: Shared scratch for the time helper's OS out-parameters. Allocated once at
;: module initialization so `now-ms` does not allocate on every sample.
(define profile-now-scratch : (Array i64)
  (make-array i64 2))

;: Windows kernel32 high-resolution performance counter bindings.
(cfg
  windows
  (extern (profile-win-query-performance-counter [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (profile-win-query-performance-frequency [arg0 : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

;: Runtime hook backing `alloc-total`.
(extern (tl_profile_alloc_total) : i64)

;: Runtime hook backing `alloc-live`.
(extern (tl_profile_alloc_live) : i64)

;: Runtime hook backing `alloc-peak`.
(extern (tl_profile_alloc_peak) : i64)

;: Runtime hook backing `alloc-reset-peak`.
(extern (tl_profile_alloc_reset_peak) : unit)

;: Return a pointer to one slot in the shared timestamp scratch buffer.
(define (scratch-ptr [slot : i64]) : (MutPtr i64)
  (unsafe
    (ptr-offset
      (ptr-cast (array-data stdlib.profile.profile-now-scratch) : (MutPtr i64))
      slot)))

;: Return the shared timestamp scratch data address for raw Linux syscalls.
(define (scratch-addr) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast (array-data stdlib.profile.profile-now-scratch) : (Ptr u8)))
      : i64)))

;: Linux `clock_gettime(CLOCK_MONOTONIC)` via raw syscall 228.
(define (linux-now-ms) : i64
  (let
    [status : i64
      (unsafe
        (syscall 228 1 (stdlib.profile.scratch-addr)))]
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
          (stdlib.profile.scratch-ptr 0))]
      [freq-ok : i32
        (stdlib.profile.profile-win-query-performance-frequency
          (stdlib.profile.scratch-ptr 1))]
      [freq : i64 (array-ref stdlib.profile.profile-now-scratch 1)]
      (if (or (= counter-ok (cast 0 : i32)) (= freq-ok (cast 0 : i32)))
        0
        (if (= freq 0)
          0
          (/ (* (array-ref stdlib.profile.profile-now-scratch 0) 1000) freq))))))

;: Return a coarse monotonic timestamp in milliseconds.
(define (now-ms) : i64
  (cfg
    windows
    (stdlib.profile.profile-windows-now-ms)
    (stdlib.profile.linux-now-ms)))

;: Return total allocated bytes since process start.
(define (alloc-total) : i64
  (stdlib.profile.tl_profile_alloc_total))

;: Return currently live bytes in runtime allocation arenas.
(define (alloc-live) : i64
  (stdlib.profile.tl_profile_alloc_live))

;: Return the peak live byte count since process start or last peak reset.
(define (alloc-peak) : i64
  (stdlib.profile.tl_profile_alloc_peak))

;: Reset the peak live byte counter to the current live byte count.
(define (alloc-reset-peak) : unit
  (stdlib.profile.tl_profile_alloc_reset_peak))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (stdlib.profile.test-fail)))

;: Allocate an array so allocation counters have observable work.
(define (test-allocation) : (Array i64)
  (let
    [items : (Array i64) (make-array i64 4)]
    (begin
      (array-set! items 0 12)
      items)))

(test
  profile-api
  (begin
    (stdlib.profile.test-assert (>= (stdlib.profile.now-ms) 0))
    (stdlib.profile.alloc-reset-peak)
    (let
      [before-total : i64 (stdlib.profile.alloc-total)]
      [before-live : i64 (stdlib.profile.alloc-live)]
      [items : (Array i64) (stdlib.profile.test-allocation)]
      [after-total : i64 (stdlib.profile.alloc-total)]
      [after-live : i64 (stdlib.profile.alloc-live)]
      [peak : i64 (stdlib.profile.alloc-peak)]
      (begin
        (stdlib.profile.test-assert (= (array-length items) 4))
        (stdlib.profile.test-assert (= (array-ref items 0) 12))
        (stdlib.profile.test-assert (>= after-total before-total))
        (stdlib.profile.test-assert (>= after-live before-live))
        (stdlib.profile.test-assert (>= peak after-live))))))