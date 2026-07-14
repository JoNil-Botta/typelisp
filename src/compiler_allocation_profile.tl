;; compiler_allocation_profile.tl - Opt-in compiler arena ownership telemetry.
;;
;; Keep the inactive footprint deliberately small: one state word and one
;; control function. No accounting is added to tl_alloc or the inline bump
;; allocator. Actions are 0=query, 1=start, 2=snapshot, and 3=finish.
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

(define compiler-allocation-profile-output-arena : i64
  0)

(define (compiler-allocation-profile-control!
  [action : i64]
  [phase : String]
  [owner : String]
  [arena-handle : i64]) : i64
  (match action
    [0
      (if (= compiler-allocation-profile-output-arena 0)
        0
        1)]
    [1
      (begin
        (if (= compiler-allocation-profile-output-arena 0)
          (begin
            (set!
              compiler-allocation-profile-output-arena
              (arena.tl_arena_make))
            (io.print-error
              "compile-allocation-profile|phase|owner|arena_root|bump_bytes|committed_bytes|reserved_bytes|segments\n"))
          unit)
        0)]
    [2
      (if (= compiler-allocation-profile-output-arena 0)
        0
        (let
          [root-candidate : i64
            (if (= arena-handle 0)
              0
              (unsafe
                (ptr-read (ptr-offset (int->ptr arena-handle : (Ptr i64)) 5))))]
          [root : i64
            (if (= arena-handle 0)
              0
              (if (= root-candidate 0)
                arena-handle
                root-candidate))]
          [active : i64
            (if (= root 0)
              0
              (let
                [current : i64
                  (unsafe
                    (ptr-read (ptr-offset (int->ptr root : (Ptr i64)) 7)))]
                (if (= current 0)
                  root
                  current)))]
          [retired : i64
            (if (= root 0)
              0
              (unsafe
                (ptr-read (ptr-offset (int->ptr root : (Ptr i64)) 4))))]
          [used : i64 0]
          [committed : i64 0]
          [reserved : i64 0]
          [segments : i64 0]
          [cursor : i64 active]
          (begin
            (while (not (= cursor 0))
              (let
                [segment-used : i64
                  (-
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 2)))
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 1))))]
                [committed-end : i64
                  (cfg
                    windows
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 8)))
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 3))))]
                [segment-committed : i64 (- committed-end cursor)]
                [segment-reserved : i64
                  (-
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 3)))
                    cursor)]
                (begin
                  (if (> segment-used 0)
                    (set! used (+ used segment-used))
                    unit)
                  (if (> segment-committed 0)
                    (set! committed (+ committed segment-committed))
                    unit)
                  (if (> segment-reserved 0)
                    (set! reserved (+ reserved segment-reserved))
                    unit)
                  (set! segments (+ segments 1))
                  (set!
                    cursor
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 0)))))))
            (set! cursor retired)
            (while (not (= cursor 0))
              (let
                [segment-used : i64
                  (-
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 2)))
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 1))))]
                [committed-end : i64
                  (cfg
                    windows
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 8)))
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 3))))]
                [segment-committed : i64 (- committed-end cursor)]
                [segment-reserved : i64
                  (-
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 3)))
                    cursor)]
                (begin
                  (if (> segment-used 0)
                    (set! used (+ used segment-used))
                    unit)
                  (if (> segment-committed 0)
                    (set! committed (+ committed segment-committed))
                    unit)
                  (if (> segment-reserved 0)
                    (set! reserved (+ reserved segment-reserved))
                    unit)
                  (set! segments (+ segments 1))
                  (set!
                    cursor
                    (unsafe
                      (ptr-read (ptr-offset (int->ptr cursor : (Ptr i64)) 4)))))))
            (let
              [home : i64 (arena.tl_arena_current)]
              (begin
                (unsafe
                  (arena.tl_arena_set compiler-allocation-profile-output-arena))
                (let
                  [mark : i64 (arena.tl_region_mark)]
                  (begin
                    (io.print-error "compile-allocation-profile|")
                    (io.print-error phase)
                    (io.print-error "|")
                    (io.print-error owner)
                    (io.print-error "|")
                    (io.print-error (string.int->string root))
                    (io.print-error "|")
                    (io.print-error (string.int->string used))
                    (io.print-error "|")
                    (io.print-error (string.int->string committed))
                    (io.print-error "|")
                    (io.print-error (string.int->string reserved))
                    (io.print-error "|")
                    (io.print-error (string.int->string segments))
                    (io.print-error "\n")
                    (unsafe
                      (arena.tl_region_reset mark))))
                (unsafe
                  (arena.tl_arena_set home))))
            0)))]
    [_
      (begin
        (if (= compiler-allocation-profile-output-arena 0)
          unit
          (let
            [scratch : i64 compiler-allocation-profile-output-arena]
            (begin
              (set! compiler-allocation-profile-output-arena 0)
              (unsafe
                (arena.tl_arena_destroy scratch)))))
        0)]))