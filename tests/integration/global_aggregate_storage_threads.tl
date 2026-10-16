(import stdlib.thread)
(import (thread.handle i64) as task)
(import stdlib.arena)
(cfg compile-profile (import stdlib.profile))

(cfg
  compiler-arena-debug
  (unsafe
    (extern (debug-layout [owner : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install"))))

(define left : (Array i64 3)
  (array 0 0 0))
(define right : (Array i64 3)
  (array 0 0 0))
(define ready : i64
  0)
(define released : i64
  0)

;; Each worker owns a distinct global. The barrier races only the private
;; allocator's first use and page growth; join orders the parent's later reads.
(define (worker [first : bool]) : i64
  (unsafe
    (atomic-fetch-add! (ptr-addr-of ready) 1))
  (while (=
    (unsafe
      (atomic-load (ptr-addr-of released)))
    0)
    unit)
  (let
    [i : i64 0]
    (while (< i 256)
      (with-scratch
        (let
          [before : i64 (arena.tl_arena_current)]
          (if first
            (set! left (array i (+ i 1) (+ i 2)))
            (set! right (array (- 0 i) (- 1 i) (- 2 i))))
          (when (not (= (arena.tl_arena_current) before)) (return 1))))
      (if first
        (when (not (= (array-ref left 0) i)) (return 2))
        (when (not (= (array-ref right 0) (- 0 i))) (return 3)))
      (+= i 1)))
  42)

(define (join-value [handle : task.Handle]) : i64
  (match (task.join handle)
    [(task.I64JoinOk value) value]
    [(task.I64JoinErr _) -1]))

(define (release!) : unit
  (unsafe
    (atomic-store! (ptr-addr-of released) 1)))

(define (main) : i64
  (cfg
    compiler-arena-debug
    (unsafe
      (debug-layout 0)))
  (cfg compile-profile (profile.alloc-total))
  (match (task.spawn
    (lambda () : i64
      (worker true)))
    [(task.I64SpawnErr _) 1]
    [(task.I64SpawnOk first)
      (match (task.spawn
        (lambda () : i64
          (worker false)))
        [(task.I64SpawnErr _)
          (release!)
          (join-value first)
          2]
        [(task.I64SpawnOk second)
          (while (<
            (unsafe
              (atomic-load (ptr-addr-of ready)))
            2)
            unit)
          (release!)
          (let
            [a : i64 (join-value first)]
            [b : i64 (join-value second)]
            (if (and
              (= a 42)
              (= b 42)
              (= (array-ref left 0) 255)
              (= (array-ref left 2) 257)
              (= (array-ref right 0) -255)
              (= (array-ref right 2) -253))
              42
              3))])]))