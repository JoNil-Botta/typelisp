(import stdlib.arena)
(import stdlib.thread)
(import stdlib.profile)

(extern (tl_alloc [size : u64]) : u64)
(extern (tl_alloc_aligned [size : u64] [alignment : u64]) : u64)
(extern (tl_arena_poison_enable) : unit)

(define (target [owner : i64]) : i64
  (unsafe
    (arena.tl_arena_growth_target owner)))

(define (read-owner [context : i64] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset (int->ptr (cast context : u64) : (Ptr i64)) index))))

;; No managed allocation precedes the first query in this fresh worker.
(define (foreign-worker [context : i64]) : i64
  (let
    [before : i64 (arena.tl_arena_current)]
    [allocated : i64 (profile.alloc-total)]
    [ordinary : i64 (read-owner context 0)]
    [atomic : i64 (read-owner context 1)]
    [third : i64 (arena.tl_arena_make)]
    [small : i64 (arena.tl_arena_make_small)]
    [third-owner : arena.Arena (arena.Arena third)]
    [home : i64 (in-arena third-owner (target ordinary))]
    (unless
      (and (= before 0) (!= home 0) (= (arena.tl_arena_current) 0))
      (return 1))
    (unless (= (profile.alloc-total) allocated) (return 8))
    (unless
      (and (!= home ordinary) (!= home third) (= (target home) home))
      (return 2))
    (let
      [accepted : bool
        (in-arena
          third-owner
          (and
            (= (target ordinary) home)
            (= (target atomic) atomic)
            (= (target small) small)
            (= (target third) third)
            (= (target 0) home)
            (= (arena.tl_arena_current) third)))]
      (unless (and accepted (= (arena.tl_arena_current) 0)) (return 3)))
    (unsafe
      (arena.tl_arena_set third))
    ;; Resetting an unrelated current root must preserve the default root.
    (unsafe
      (arena.tl_region_reset 0))
    (unless (and (= (arena.tl_arena_current) 0) (= (target 0) home)) (return 4))
    (unsafe
      (arena.tl_arena_destroy small))
    (unless (= (target 0) home) (return 5))
    ;; An allocation from the sentinel resumes the previously queried root.
    (tl_alloc (cast 8 : u64))
    (unless (= (arena.tl_arena_current) home) (return 6))
    (unsafe
      (arena.tl_arena_set 0))
    (tl_alloc_aligned (cast 8 : u64) (cast 64 : u64))
    (unless (= (arena.tl_arena_current) home) (return 7))
    0))

;; Exercise root creation through both allocator entry points, then teardown.
(define (allocation-worker [aligned : i64]) : i64
  (unless (= (arena.tl_arena_current) 0) (return 10))
  (tl_arena_poison_enable)
  (if (= aligned 0)
    (tl_alloc (cast 8 : u64))
    (tl_alloc_aligned (cast 8 : u64) (cast 64 : u64)))
  (let
    [home : i64 (arena.tl_arena_current)]
    (unless
      (and (!= home 0) (= (target home) home) (= (target 0) home))
      (return 11))
    (unsafe
      (arena.tl_region_reset 0))
    (unless (= (arena.tl_arena_current) 0) (return 12))
    (let
      [rebuilt : i64 (target 0)]
      (unless (and (!= rebuilt 0) (= (arena.tl_arena_current) 0)) (return 13))
      (tl_alloc (cast 8 : u64))
      (unless (= (arena.tl_arena_current) rebuilt) (return 14))
      (unsafe
        (arena.tl_arena_set 0))
      (unsafe
        (arena.tl_arena_destroy rebuilt))
      (let
        [after-destroy : i64 (target 0)]
        (unless (!= after-destroy 0) (return 15))
        (tl_alloc_aligned (cast 8 : u64) (cast 64 : u64))
        (unless (= (arena.tl_arena_current) after-destroy) (return 16))
        0))))

(define (run-worker [entry : (-> i64 i64)] [argument : i64]) : i64
  (match (unsafe
    (thread.spawn entry argument))
    [(thread.ThreadSpawnErr _) 20]
    [(thread.ThreadSpawnOk worker)
      (thread.join-result-value-or
        (unsafe
          (thread.join worker))
        21)]))

(define (main) : i64
  (let
    [ordinary : i64 (arena.tl_arena_make)]
    [atomic : i64 (arena.tl_arena_make_atomic)]
    [owners : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (set! (array-ref owners 0) ordinary)
    (set! (array-ref owners 1) atomic)
    (let
      [context : i64
        (unsafe
          (cast (ptr->int (__tl_array-data owners)) : i64))]
      [foreign : i64 (run-worker foreign-worker context)]
      [ordinary-root : i64 (run-worker allocation-worker 0)]
      [aligned-root : i64 (run-worker allocation-worker 1)]
      (unsafe
        (arena.tl_arena_destroy ordinary))
      (unsafe
        (arena.tl_arena_destroy atomic))
      (cond
        [(!= foreign 0) foreign]
        [(!= ordinary-root 0) ordinary-root]
        [(!= aligned-root 0) aligned-root]
        [else 42]))))