; R3-P2b: pin the "global points at cells owned by a destroyed arena" class.
;
; The macro walk's per-declaration generations are `tl_arena_destroy`d, not
; rewound. Any structure that (a) is built while such a generation is current
; and (b) is then published into a PROCESS-GLOBAL is a use-after-free the moment
; that generation dies -- even though the publishing code looks correct, because
; the global holds the cell array by reference rather than by value.
;
; That is exactly how `ast-node-pool-context-install!` loses:
; `AstNodePoolContext` is two one-element arrays, `install!` points the global
; active context straight at them, and every later `capture-active!` writes
; THROUGH them. A context built inside a declaration generation therefore leaves
; the global aliasing freed pages. In-tree it reproduces as a SIGSEGV on
; `tests/integration/compile_profile_cross_file_single_compilation`, two splices
; after the generation that built the context.
;
; This fixture is the shape, not the compiler: a global cell holder, a
; destroyed (not rewound) scratch arena, a publish from inside it, and a
; write-through read after the destroy. The GUARDED path allocates the cells in
; the long-lived arena before publishing, which is what
; `ast-node-pool-context-cells-pin-base!` does in the compiler.
;
; Exit 42 on success, like the other arena-ownership fixtures.
(import stdlib.arena)
(import stdlib.array)

; The "pool state" a global points at: a one-element cell holding a payload.
(defstruct CellHolder
  (cells (Array i64)))

; The process-global. `install!` re-points it at the caller's cells, so whatever
; arena those cells live in becomes this global's lifetime.
(define global-holder : CellHolder
  (CellHolder (array.make-array i64 1)))
(define long-lived-arena : i64
  (arena.tl_arena_current))
(define pin-cells-to-long-lived : bool
  false)

(define (holder-new [value : i64]) : CellHolder
  (if (not pin-cells-to-long-lived)
    ; UNGUARDED: cells come from whatever arena is current.
    (let
      [cells : (Array i64) (array.make-array i64 1)]
      (begin
        (array-set! cells 0 value)
        (CellHolder cells)))
    ; GUARDED: cells come from the arena that outlives every scratch generation.
    (let
      [prev : i64 (arena.tl_arena_current)]
      [_enter : unit
        (unsafe
          (arena.tl_arena_set long-lived-arena))]
      [cells : (Array i64) (array.make-array i64 1)]
      [head : i64 (arena.tl_arena_current)]
      [_leave : unit
        (begin
          ; Republish the grown head (H4) and restore the caller's arena.
          (set! long-lived-arena head)
          (unsafe
            (arena.tl_arena_set prev)))]
      (begin
        (array-set! cells 0 value)
        (CellHolder cells)))))

(define (holder-install! [holder : CellHolder]) : unit
  (set! (struct-get global-holder cells) (struct-get holder cells)))

; Write THROUGH the global's cells, exactly as `capture-active!` does.
(define (holder-capture! [value : i64]) : unit
  (array-set! (struct-get global-holder cells) 0 value))

(define (holder-read) : i64
  (array-ref (struct-get global-holder cells) 0))

; One "declaration generation": create it, publish a holder from inside it,
; return the generation handle so the caller can destroy it later.
(define (generation-run [value : i64]) : i64
  (let
    [prev : i64 (arena.tl_arena_current)]
    [generation : i64 (arena.tl_arena_make)]
    [_enter : unit
      (unsafe
        (arena.tl_arena_set generation))]
    [holder : CellHolder (holder-new value)]
    [_publish : unit (holder-install! holder)]
    [head : i64 (arena.tl_arena_current)]
    [_leave : unit
      (unsafe
        (arena.tl_arena_set prev))]
    head))

; Two-generation ring, like the splice ring: retire one behind, destroy the one
; retired before that. The write-through read happens two generations after the
; one that published, which is where the compiler faulted.
(define (ring-cycle [rounds : i64]) : bool
  (let
    [current : i64 0]
    [retired : i64 0]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index rounds)
        (let
          [next : i64 (generation-run (+ index 100))]
          (begin
            (if (= retired 0)
              unit
              (unsafe
                (arena.tl_arena_destroy retired)))
            (set! retired current)
            (set! current next)
            ; The global was re-pointed by the generation just run; write
            ; through it and read it back after the older generation died.
            (holder-capture! (+ index 200))
            (if (= (holder-read) (+ index 200))
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
      ok)))

(define (main) : i64
  (begin
    ; Guarded: the cells the global aliases are long-lived, so every
    ; write-through after a destroy is safe.
    (set! pin-cells-to-long-lived true)
    (if (ring-cycle 8)
      (begin
        ; Re-point the global at storage the fixture owns for the rest of the
        ; run, so nothing observable is left aliasing a destroyed arena.
        (holder-install! (holder-new 0))
        (holder-capture! 42)
        (holder-read))
      0)))