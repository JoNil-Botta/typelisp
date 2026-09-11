(import stdlib.arena)
(import stdlib.profile)
(import stdlib.thread)

;; Compiler-private runtime ABI. Source-level aligned allocation remains out of
;; scope; this fixture exercises the backend building block directly.
(extern (tl_alloc_aligned [size : i64] [alignment : i64]) : i64)
(extern (tl_arena_poison_enable) : unit)

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
    (begin
      (unsafe
        (arena.set! home))
      (unsafe
        (arena.destroy owner))
      ok)))

(define (rewind-reuses-aligned-start?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    [_set : unit
      (unsafe
        (arena.set! owner))]
    [mark : arena.ArenaMark (arena.mark)]
    [first : i64 (tl_alloc_aligned 57 4096)]
    [_reset : unit
      (unsafe
        (arena.rewind mark))]
    [second : i64 (tl_alloc_aligned 57 4096)]
    [ok : bool (and (= first second) (aligned? second 4096))]
    (begin
      (unsafe
        (arena.set! home))
      (unsafe
        (arena.destroy owner))
      ok)))

(define (exact-end-fit-grows-afterward?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    [_set : unit
      (unsafe
        (arena.set! owner))]
    [root : i64 (arena.raw-handle owner)]
    [cursor : i64 (arena.mark-raw-handle (arena.mark))]
    [arena-end : i64 (+ root 67108864)]
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
    (begin
      (unsafe
        (arena.set! home))
      (unsafe
        (arena.destroy owner))
      ok)))

(defmacro (array-i64-address [items : Expr]) : i64
  `(unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data ,items) : (Ptr u8))) : i64)))

(define (address-as-i64-pointer [address : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast address : u64) : (MutPtr i64))))

(define (atomic-aligned-worker [context : i64]) : i64
  (let
    [context-ptr : (MutPtr i64) (address-as-i64-pointer context)]
    [owner : i64
      (unsafe
        (ptr-read context-ptr))]
    [home : i64 (arena.tl_arena_current)]
    [i : i64 0]
    [last : i64 0]
    [valid : bool true]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      (while (< i 4096)
        (let
          [current : i64 (tl_alloc_aligned 17 64)]
          (begin
            (unsafe
              (ptr-write! (ptr-offset context-ptr (+ i 1)) current))
            (if (or
              (not (aligned? current 64))
              (and (not (= last 0)) (<= current last)))
              (set! valid false)
              unit)
            (set! last current)
            (set! i (+ i 1)))))
      (unsafe
        (arena.tl_arena_set home))
      (if valid
        last
        0))))

(define (atomic-records-nonoverlap?
  [left : (& left (__tl_dyn-array i64))]
  [right : (& right (__tl_dyn-array i64))]) : bool
  (let
    [left-index : i64 1]
    [right-index : i64 1]
    [previous : i64 0]
    [valid : bool true]
    (begin
      (while (or (< left-index 4097) (< right-index 4097))
        (let
          [take-left : bool
            (and
              (< left-index 4097)
              (or
                (>= right-index 4097)
                (<= (array-ref left left-index) (array-ref right right-index))))]
          [current : i64
            (if take-left
              (array-ref left left-index)
              (array-ref right right-index))]
          (begin
            (if (or
              (not (aligned? current 64))
              (and (not (= previous 0)) (< current (+ previous 24))))
              (set! valid false)
              unit)
            (set! previous current)
            (if take-left
              (set! left-index (+ left-index 1))
              (set! right-index (+ right-index 1))))))
      valid)))

(define (joined-address [result : thread.ThreadJoinResult]) : i64
  (match result
    [(thread.ThreadJoinOk value) value]
    [(thread.ThreadJoinErr _) 0]))

(define (atomic-contention-ok?) : bool
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [context-a : (__tl_dyn-array i64) (__tl_make-array i64 4097)]
    [context-b : (__tl_dyn-array i64) (__tl_make-array i64 4097)]
    (begin
      (set! (array-ref context-a 0) (arena.raw-handle owner))
      (set! (array-ref context-b 0) (arena.raw-handle owner))
      (match (thread.spawn atomic-aligned-worker (array-i64-address context-a))
        [(thread.ThreadSpawnErr _) false]
        [(thread.ThreadSpawnOk worker-a)
          (match (thread.spawn
            atomic-aligned-worker
            (array-i64-address context-b))
            [(thread.ThreadSpawnErr _)
              (begin
                (thread.join worker-a)
                false)]
            [(thread.ThreadSpawnOk worker-b)
              (let
                [address-a : i64 (joined-address (thread.join worker-a))]
                [address-b : i64 (joined-address (thread.join worker-b))]
                [ok : bool
                  (and
                    (not (= address-a 0))
                    (not (= address-b 0))
                    (not (= address-a address-b))
                    (aligned? address-a 64)
                    (aligned? address-b 64)
                    (atomic-records-nonoverlap? (& context-a) (& context-b)))]
                (begin
                  (arena.destroy-safe! owner)
                  ok))])]))))

(define (poison-reset-reuses-aligned-start?) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [home : arena.Arena (arena.current)]
    (begin
      (tl_arena_poison_enable)
      (unsafe
        (arena.set! owner))
      (let
        [mark : arena.ArenaMark (arena.mark)]
        [first : i64 (tl_alloc_aligned 257 4096)]
        [_reset : unit
          (unsafe
            (arena.rewind mark))]
        [second : i64 (tl_alloc_aligned 257 4096)]
        [ok : bool (and (= first second) (aligned? second 4096))]
        (begin
          (unsafe
            (arena.set! home))
          (unsafe
            (arena.destroy owner))
          ok)))))

(define (main) : i64
  (cond
    [(not (mixed-and-profile-ok?)) 1]
    [(not (rewind-reuses-aligned-start?)) 2]
    [(not (exact-end-fit-grows-afterward?)) 3]
    [(not (atomic-contention-ok?)) 4]
    [(not (poison-reset-reuses-aligned-start?)) 5]
    [else 42]))