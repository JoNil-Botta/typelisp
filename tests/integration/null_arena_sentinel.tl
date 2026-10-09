(import stdlib.arena)
(import stdlib.string)
(import stdlib.thread)

;; A worker starts with a fresh current-arena slot holding the null-arena
;; sentinel, not 0 (#8538). Every path must read it as "no arena": the inline
;; allocation fast paths have no null test, so a slot left at 0 would fault.
;;
;; Each check that follows a "no arena" state allocates a fixed-size box, which
;; takes the inline fast path, and keeps it in a global so no optimization level
;; can drop the allocation.
(define region-sink : (Box i64)
  (box 0))
(define switch-sink : (Box i64)
  (box 0))

;; The region worker checks that `tl_arena_current` reports 0, that a region
;; entered with no arena marks 0 and its full reset reinstalls the sentinel,
;; and that the next allocations build a fresh arena chain.
(define (region-worker [unused : i64]) : i64
  (let
    [before : i64 (arena.tl_arena_current)]
    [inside : i64
      (with-arena
        r
        (let
          [s : String (string.int->string 123456)]
          (string.string-length (& s))))]
    [after-reset : i64 (arena.tl_arena_current)]
    (set! region-sink (box 77))
    (let
      [text : String (string.int->string 98765)]
      [after-alloc : i64 (arena.tl_arena_current)]
      (cond
        [(!= before 0) 10]
        [(!= inside 6) 11]
        [(!= after-reset 0) 12]
        [(!= (deref region-sink) 77) 15]
        [(not (string.eq (& text) "98765")) 13]
        [(= after-alloc 0) 14]
        [else (+ unused 0)]))))

;; The switch worker checks that an arena switch made before the first
;; allocation saves "none" and restores it, so the next allocation still builds
;; this thread's own chain instead of reusing the switched-to arena.
(define (switch-worker [unused : i64]) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [scratch-handle : i64 (arena.raw-handle scratch)]
    [inside : i64
      (in-arena
        scratch
        (let
          [s : String (string.int->string 4321)]
          (string.string-length (& s))))]
    [restored : i64 (arena.tl_arena_current)]
    (set! switch-sink (box 55))
    (let
      [text : String (string.int->string 2468)]
      [home : i64 (arena.tl_arena_current)]
      (arena.destroy-safe! scratch)
      (cond
        [(!= inside 4) 20]
        [(!= restored 0) 21]
        [(!= (deref switch-sink) 55) 25]
        [(not (string.eq (& text) "2468")) 22]
        [(= home 0) 23]
        [(= home scratch-handle) 24]
        [else (+ unused 0)]))))

(define (run-worker [entry : (-> i64 i64)]) : i64
  (let
    [spawn : thread.ThreadSpawnResult
      (unsafe
        (thread.spawn entry 0))]
    (if (not (thread.spawn-result-ok? (& spawn)))
      2
      (let
        [worker : thread.Thread
          (unsafe
            (thread.spawn-result-thread-or spawn (thread.Thread 0 0 0 "")))]
        (thread.join-result-value-or
          (unsafe
            (thread.join worker))
          3)))))

(define (main) : i64
  (let
    [region : i64 (run-worker region-worker)]
    [switch : i64 (run-worker switch-worker)]
    (cond [(!= region 0) region] [(!= switch 0) switch] [else 42])))