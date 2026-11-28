(import stdlib.arena)
(import stdlib.profile)
(import stdlib.thread)

;; Compiler-private runtime ABI. Source-level aligned allocation remains out of
;; scope; this fixture exercises the backend building block directly.
(extern (tl_alloc_aligned [size : i64] [alignment : i64]) : i64)
(extern (tl_arena_poison_enable) : unit)
(cfg linux (extern (tl_alloc [size : i64]) : i64))

(define (align-up [value : i64] [alignment : i64]) : i64
  (bit-and (+ value (- alignment 1)) (- 0 alignment)))

(define (aligned? [value : i64] [alignment : i64]) : bool
  (= (% value alignment) 0))

(define (mixed-and-profile-ok?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    [_set : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- isolate allocator cursor and counter checks.
        (arena.set! owner))]
    [start : i64 (arena.mark-raw-handle (arena.mark))]
    [_peak-reset : unit (profile.alloc-reset-peak)]
    [total-before : i64 (profile.alloc-total)]
    [live-before : i64 (profile.alloc-live)]
    [p8 : i64 (tl_alloc_aligned 1 8)]
    [p16 : i64 (tl_alloc_aligned 9 16)]
    [p32 : i64 (tl_alloc_aligned 17 32)]
    [p64 : i64 (tl_alloc_aligned 33 64)]
    [p4096 : i64 (tl_alloc_aligned 65 4096)]
    [z1 : i64 (tl_alloc_aligned 0 32)]
    [z2 : i64 (tl_alloc_aligned 0 32)]
    [finish : i64 (arena.mark-raw-handle (arena.mark))]
    [total-after : i64 (profile.alloc-total)]
    [live-after : i64 (profile.alloc-live)]
    [peak-after : i64 (profile.alloc-peak)]
    [payload : i64 (+ 8 16 24 40 72 8 8)]
    [expected-p8 : i64 (align-up start 8)]
    [expected-p16 : i64 (align-up (+ expected-p8 8) 16)]
    [expected-p32 : i64 (align-up (+ expected-p16 16) 32)]
    [expected-p64 : i64 (align-up (+ expected-p32 24) 64)]
    [expected-p4096 : i64 (align-up (+ expected-p64 40) 4096)]
    [expected-z1 : i64 (align-up (+ expected-p4096 72) 32)]
    [expected-z2 : i64 (align-up (+ expected-z1 8) 32)]
    [expected-finish : i64 (+ expected-z2 8)]
    [ok : bool
      (and
        (= p8 expected-p8)
        (= p16 expected-p16)
        (= p32 expected-p32)
        (= p64 expected-p64)
        (= p4096 expected-p4096)
        (= z1 expected-z1)
        (= z2 expected-z2)
        (= finish expected-finish)
        (aligned? p8 8)
        (aligned? p16 16)
        (aligned? p32 32)
        (aligned? p64 64)
        (aligned? p4096 4096)
        (aligned? z1 32)
        (aligned? z2 32)
        (>= p16 (+ p8 8))
        (>= p32 (+ p16 16))
        (>= p64 (+ p32 24))
        (>= p4096 (+ p64 40))
        (>= z1 (+ p4096 72))
        (>= z2 (+ z1 8))
        (not (= z1 z2))
        (= (- total-after total-before) payload)
        (= (- live-after live-before) (- expected-finish start))
        (= peak-after live-after))]
    (unsafe
      ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
      (arena.set! home))
    (unsafe
      ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
      (arena.destroy owner))
    ok))

(define (rewind-reuses-aligned-start?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    [_set : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- isolate aligned rewind behavior.
        (arena.set! owner))]
    [mark : arena.ArenaMark (arena.mark)]
    [first : i64 (tl_alloc_aligned 57 4096)]
    [_reset : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- the fixture deliberately exercises rewind.
        (arena.rewind mark))]
    [second : i64 (tl_alloc_aligned 57 4096)]
    [ok : bool (and (= first second) (aligned? second 4096))]
    (unsafe
      ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
      (arena.set! home))
    (unsafe
      ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
      (arena.destroy owner))
    ok))

(define (exact-end-fit-grows-afterward?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    [_set : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- isolate exact-end arena growth behavior.
        (arena.set! owner))]
    [root : i64 (arena.raw-handle owner)]
    [cursor : i64 (arena.mark-raw-handle (arena.mark))]
    [arena-end : i64 (+ root (cfg linux 262144 67108864))]
    [start : i64 (align-up cursor 4096)]
    [payload : i64 (- arena-end start)]
    [exact : i64 (tl_alloc_aligned payload 4096)]
    [exact-end : i64 (arena.mark-raw-handle (arena.mark))]
    [overflow : i64 (tl_alloc_aligned 8 4096)]
    [root-after : i64 (arena.raw-handle (arena.current))]
    [ok : bool
      (and
        (> payload 0)
        (= exact start)
        (= exact-end arena-end)
        (aligned? overflow 4096)
        (not (= overflow exact-end))
        (= root-after root))]
    (unsafe
      ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
      (arena.set! home))
    (unsafe
      ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
      (arena.destroy owner))
    ok))

(defmacro (array-i64-address [items : Expr]) : i64
  `(unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data ,items) : (Ptr u8))) : i64)))

(define (address-as-i64-pointer [address : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast address : u64) : (MutPtr i64))))

(cfg
  linux
  (define (chunk-word [chunk : i64] [offset : i64]) : i64
    (unsafe
      (ptr-read (address-as-i64-pointer (+ chunk offset))))))

(cfg
  linux
  (define (geometric-rewind-ok?) : bool
    (let
      [owner : arena.Arena (arena.make)]
      [home : arena.Arena (arena.current)]
      [root : i64 (arena.raw-handle owner)]
      [length : i64 262144]
      [chunk : i64 root]
      [live-before : i64 (profile.alloc-live)]
      [valid : bool true]
      (unsafe
        ;; lint-allow: raw-arena-op -- inspect chunk lengths across growth.
        (arena.set! owner))
      (let
        [mark : arena.ArenaMark (arena.mark)]
        (while (< length 2097152)
          (let
            [end : i64 (chunk-word chunk 24)]
            [cursor : i64 (chunk-word chunk 16)]
            [fill : i64 (tl_alloc (- end cursor))]
            [first : i64 (tl_alloc 8)]
            [next : i64 (chunk-word root 56)]
            (set!
              valid
              (and
                valid
                (= end (+ chunk length))
                (= fill cursor)
                (= first (+ next 64))
                (= (chunk-word next 0) chunk)))
            (set! chunk next)
            (set! length (* length 2))))
        (set! valid (and valid (= (chunk-word chunk 24) (+ chunk length))))
        (unsafe
          ;; lint-allow: raw-arena-op -- retire all growth chunks in one rewind.
          (arena.rewind mark))
        (set!
          valid
          (and
            valid
            (= (profile.alloc-live) live-before)
            (= (chunk-word root 56) root)
            (= (tl_alloc 8) (+ root 64)))))
      (unsafe
        ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
        (arena.set! home)
        ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
        (arena.destroy owner))
      (and valid (= (profile.alloc-live) live-before)))))

(cfg
  linux
  (define (huge-then-capped-ok? [owner : arena.Arena]) : bool
    (let
      [home : arena.Arena (arena.current)]
      [root : i64 (arena.raw-handle owner)]
      [live-before : i64 (profile.alloc-live)]
      (unsafe
        ;; lint-allow: raw-arena-op -- exercise ordinary and atomic map paths.
        (arena.set! owner))
      (let
        [huge : i64 (tl_alloc_aligned 67108872 4096)]
        [huge-chunk : i64 (chunk-word root 56)]
        [next : i64 (- (tl_alloc 4096) 64)]
        [ok : bool
          (and
            (= huge (+ huge-chunk 4096))
            (= (chunk-word huge-chunk 24) (+ huge-chunk 67117056))
            (= (chunk-word next 0) huge-chunk)
            (= (chunk-word next 24) (+ next 67108864)))]
        (unsafe
          ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
          (arena.set! home)
          ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
          (arena.destroy owner))
        (and ok (= (profile.alloc-live) live-before))))))

(define (atomic-aligned-worker [context : i64]) : i64
  (let
    [context-ptr : (MutPtr i64) (address-as-i64-pointer context)]
    [owner : i64
      (unsafe
        (ptr-read context-ptr))]
    [home : i64 (arena.tl_arena_current)]
    [i : i64 0]
    (unsafe
      ;; lint-allow: raw-arena-op -- install the shared atomic arena in this worker.
      (arena.tl_arena_set owner))
    (while (< i 4096)
      (let
        [current : i64 (tl_alloc_aligned 17 64)]
        (when
          (aligned? current 64)
          (unsafe
            (atomic-store! (address-as-i64-pointer current) (+ context (* i 8)))
            (ptr-write! (ptr-offset context-ptr (+ i 1)) current)))
        (set! i (+ i 1))))
    (unsafe
      ;; lint-allow: raw-arena-op -- restore the worker's original arena.
      (arena.tl_arena_set home))
    42))

(define (atomic-records-intact?
  [records : (& records (__tl_dyn-array i64))]
  [context : i64]) : bool
  ;; These 24-byte allocations can only overlap if their 64-byte-aligned
  ;; addresses coincide. Each marker identifies a unique allocation even
  ;; when chunk addresses decrease.
  (let
    [i : i64 0]
    (while (< i 4096)
      (let
        [current : i64 (array-ref records (+ i 1))]
        (when
          (or
            (= current 0)
            (not (aligned? current 64))
            (!=
              (unsafe
                (atomic-load (address-as-i64-pointer current)))
              (+ context (* i 8))))
          (return false))
        (set! i (+ i 1))))
    true))

(define (worker-completed? [result : thread.ThreadJoinResult]) : bool
  (match result
    [(ThreadJoinOk value) (= value 42)]
    [(ThreadJoinErr _) false]))

(define (atomic-contention-ok?) : bool
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [context-a : (__tl_dyn-array i64) (__tl_make-array i64 4097)]
    [context-b : (__tl_dyn-array i64) (__tl_make-array i64 4097)]
    (set! (array-ref context-a 0) (arena.raw-handle owner))
    (set! (array-ref context-b 0) (arena.raw-handle owner))
    (match (unsafe
      (thread.spawn atomic-aligned-worker (array-i64-address context-a)))
      [(ThreadSpawnErr _) false]
      [(ThreadSpawnOk worker-a)
        (match (unsafe
          (thread.spawn atomic-aligned-worker (array-i64-address context-b)))
          [(ThreadSpawnErr _)
            (unsafe
              (thread.join worker-a))
            false]
          [(ThreadSpawnOk worker-b)
            (let
              [done-a : bool
                (worker-completed?
                  (unsafe
                    (thread.join worker-a)))]
              [done-b : bool
                (worker-completed?
                  (unsafe
                    (thread.join worker-b)))]
              [ok : bool
                (and
                  done-a
                  done-b
                  (atomic-records-intact?
                    (& context-a)
                    (array-i64-address context-a))
                  (atomic-records-intact?
                    (& context-b)
                    (array-i64-address context-b)))]
              (arena.destroy-safe! owner)
              ok)])])))

(define (poison-reset-reuses-aligned-start?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    (tl_arena_poison_enable)
    (unsafe
      ;; lint-allow: raw-arena-op -- isolate poisoned rewind behavior.
      (arena.set! owner))
    (let
      [mark : arena.ArenaMark (arena.mark)]
      [first : i64 (tl_alloc_aligned 257 4096)]
      [_reset : unit
        (unsafe
          ;; lint-allow: raw-arena-op -- the fixture deliberately exercises rewind.
          (arena.rewind mark))]
      [second : i64 (tl_alloc_aligned 257 4096)]
      [ok : bool (and (= first second) (aligned? second 4096))]
      (unsafe
        ;; lint-allow: raw-arena-op -- restore the caller before retiring owner.
        (arena.set! home))
      (unsafe
        ;; lint-allow: raw-arena-op -- final retirement after restoring the caller.
        (arena.destroy owner))
      ok)))

(define (main) : i64
  (cond
    [(not (mixed-and-profile-ok?)) 1]
    [(not (rewind-reuses-aligned-start?)) 2]
    [(not (exact-end-fit-grows-afterward?)) 3]
    [(not (atomic-contention-ok?)) 4]
    [(cfg linux (not (geometric-rewind-ok?)) false) 6]
    [(cfg linux (not (huge-then-capped-ok? (arena.make))) false) 7]
    [(cfg linux (not (huge-then-capped-ok? (arena.make-atomic))) false) 8]
    [(not (poison-reset-reuses-aligned-start?)) 5]
    [else 42]))