; R3-P2d: pin the "lazily opened whole-run singleton keeps a RAW ADDRESS into
; whatever arena was current at first use" class.
;
; This is a different shape from `arena_pool_context_escape`, and no guard for
; that one covers it:
;
;   * Nothing is published into a global by an `install!`. A constructor simply
;     RETURNS a value and the caller parks it in a process-global singleton.
;   * What dangles is an INTEGER, not a reference: the escaping datum is
;     `ptr->int` of an array's data pointer, kept because it has to be handed to
;     foreign code. No reference-tracing or ownership-typed check can see it,
;     and the array it came from may not be retained at all.
;   * The lifetime mismatch is created by LAZY INITIALIZATION. The singleton is
;     opened on first use, so which arena owns it is decided by whichever
;     caller happens to touch it first. Under a batched generation ring that is
;     an arena with a lifetime of a few declarations; every later use is a read
;     into freed pages.
;
; In-tree this is `TlciLoadedImage.host-table-addr`. The embedded stdlib tlci
; image is mapped on the first embedded-stdlib macro call and dispatched from
; every later one; `tlci-loader-dispatch-macro` re-reads the host callback
; table through that raw address on EVERY dispatch. Measured on the failing
; gate: the image was mapped inside the declaration generation covering
; declarations 33-64, that generation was destroyed on entering declaration 97,
; and declaration 98's dispatch segfaulted. The fix is the one this fixture
; models: the load takes the owning arena as a required parameter, and the
; caller names an arena that outlives the image.
;
; The cadence rule does not reach this: the singleton is opened once per RUN and
; read for the rest of the run, so there is no reset cadence to align a destroy
; to. Ownership has to be decided where the storage is allocated.
;
; Exit 42 on success, like the other arena-ownership fixtures.
(import stdlib.arena)
(import stdlib.array)

(define session-magic : i64
  305419896)

; The whole-run singleton: an "is it open" flag and the RAW ADDRESS of the
; storage the open produced. Only the address is kept, exactly as the loader
; keeps `host-table-addr`.
(define session-open-flag : (Array i64)
  (array.make-array i64 1))
(define session-addr-cell : (Array i64)
  (array.make-array i64 1))

; Flip to false to get the defect back: the storage is then owned by whatever
; arena is current at the first call, i.e. by a generation.
(define session-storage-has-owner : bool
  true)

(define (raw-addr-of [items : (Array i64)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data items) : (Ptr u8))))
    : i64))

(define (read-i64-at [addr : i64]) : i64
  (unsafe
    (ptr-read (int->ptr addr : (Ptr i64)))))

; Open the session. `owner-arena` is a required parameter with no default, so a
; caller cannot inherit "whatever arena is current" by omission -- that arity is
; the whole enforcement.
(define (session-open! [owner-arena : i64]) : unit
  (if (= (array-ref session-open-flag 0) 1)
    unit
    (let
      [prev : i64 (arena.tl_arena_current)]
      [_enter : unit
        (if session-storage-has-owner
          (unsafe
            (arena.tl_arena_set owner-arena))
          unit)]
      [storage : (Array i64) (array.make-array i64 8)]
      [_fill : unit (array-set! storage 0 session-magic)]
      [addr : i64 (raw-addr-of storage)]
      [_restore : unit
        (if session-storage-has-owner
          (unsafe
            (arena.tl_arena_set prev))
          unit)]
      (begin
        (array-set! session-addr-cell 0 addr)
        (array-set! session-open-flag 0 1)))))

; The dispatch-path read: it only ever sees the integer.
(define (session-dispatch) : i64
  (read-i64-at (array-ref session-addr-cell 0)))

; One batch of "declarations" running inside one generation. The batch whose
; index is `open-batch` is the one that first touches the session, which is the
; only thing that decides ownership in the unguarded build.
(define (batch-run
  [generation : i64]
  [owner-arena : i64]
  [index : i64]
  [open-batch : i64]
  [batch-size : i64]) : bool
  (let
    [prev : i64 (arena.tl_arena_current)]
    [_enter : unit
      (unsafe
        (arena.tl_arena_set generation))]
    [step : i64 0]
    [ok : bool true]
    [_work : unit
      (while (< step batch-size)
        (begin
          ; Ordinary per-declaration garbage in the generation.
          (array-set! (array.make-array i64 16) 0 step)
          (if (>= index open-batch)
            (begin
              (session-open! owner-arena)
              (if (= (session-dispatch) session-magic)
                unit
                (set! ok false)))
            unit)
          (set! step (+ step 1))))]
    [_leave : unit
      (unsafe
        (arena.tl_arena_set prev))]
    ok))

; The two-generation batch ring R3-P1 uses: a fresh generation every
; `batch-size` declarations, retiring one behind, so the generation that opened
; the session is destroyed two rotations later and every later batch dispatches
; against it.
(define (ring-run [batches : i64] [batch-size : i64] [open-batch : i64]) : bool
  (let
    [owner-arena : i64 (arena.tl_arena_current)]
    [current : i64 0]
    [retired : i64 0]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index batches)
        (let
          [next : i64 (arena.tl_arena_make)]
          (begin
            (if (= retired 0)
              unit
              (unsafe
                (arena.tl_arena_destroy retired)))
            (set! retired current)
            (set! current next)
            (if (batch-run next owner-arena index open-batch batch-size)
              unit
              (set! ok false))
            (set! index (+ index 1)))))
      (if (= retired 0)
        unit
        (unsafe
          (arena.tl_arena_destroy retired)))
      (if (= current 0)
        unit
        (unsafe
          (arena.tl_arena_destroy current)))
      ; Every generation is gone now. The singleton is still live for the rest
      ; of the run, and this is the read that faults without an owner.
      (if (= (session-dispatch) session-magic)
        ok
        false))))

(define (main) : i64
  (if (ring-run 8 4 1)
    42
    0))