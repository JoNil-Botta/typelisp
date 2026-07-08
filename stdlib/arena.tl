;# First-class arena helper API.
;#
;# Provides explicit arena handles for advanced allocation control. Prefer
;# `(with-arena ...)` for scoped reclamation when possible; these helpers expose
;# manual switching/rewinding/destruction and can invalidate live heap handles.
;#
;# Usage: `(import stdlib.arena)`
;#
;# Temporary scratch work should usually use lexical `with-arena`; values
;# allocated inside the scoped arena cannot escape:
;#
;# ```typelisp
;# (import stdlib.arena)
;# (import stdlib.string)
;#
;# (define (scratch-score [n : i64]) : i64
;#   (with-arena scratch
;#     (let
;#       [prefix : String "phase:"]
;#       [suffix : String (string.int->string n)]
;#       [text : String (string.append (& prefix) (& suffix))]
;#       (string.string-length text))))
;# ```
;#
;# To keep one result from repeated scratch work, allocate a first-class arena
;# with `make` and use `with-escape`; the form clones supported results
;# back into the enclosing active arena:
;#
;# ```typelisp
;# (import stdlib.arena)
;# (import stdlib.string)
;#
;# (define (build-message [scratch : arena.Arena] [n : i64]) : String
;#   (with-escape
;#     scratch
;#     (let
;#       [prefix : String "kept:"]
;#       [suffix : String (string.int->string n)]
;#       (string.append (& prefix) (& suffix)))))
;# ```
;#
;# For one-shot scratch work, `with-scratch` creates and destroys the scratch
;# arena itself while cloning one supported result back into the enclosing
;# active arena:
;#
;# ```typelisp
;# (import stdlib.string)
;#
;# (define (build-once [n : i64]) : String
;#   (with-scratch
;#     (string.append "once:" (string.int->string n))))
;# ```
;#
;# To keep results owned by the target arena itself, use `in-arena`. It switches
;# the active allocation target for the dynamic extent and restores the previous
;# active arena without marking, rewinding, destroying, or cloning:
;#
;# ```typelisp
;# (import stdlib.arena)
;# (import stdlib.string)
;#
;# (define (build-in-level [level : arena.Arena] [n : i64]) : String
;#   (in-arena
;#     level
;#     (string.append "level:" (string.int->string n))))
;# ```
;#
;# Manual arena switching, rewinding, and destruction remain explicit unsafe
;# operations for code that can prove all invalidated handles are dead:
;#
;# ```typelisp
;# (import stdlib.arena)
;#
;# (define (manual-step) : unit
;#   (let
;#     [home : arena.Arena (arena.current)]
;#     [scratch : arena.Arena (arena.make)]
;#     (unsafe
;#       (begin
;#         (arena.set! scratch)
;#         (arena.rewind (arena.mark))
;#         (arena.set! home)
;#         (arena.destroy scratch)))))
;# ```
;#
;# `Arena` and `ArenaMark` are nominal wrappers over raw runtime handles. The
;# raw `tl_*` hooks remain exported for compiler/runtime internals and FFI-like
;# low-level code; ordinary user code should use the typed helpers below.
;: First-class arena handle. The runtime representation is a raw `i64` handle,
;: but the source type is nominal so raw integers cannot satisfy arena APIs.
(defstruct Arena
  (handle i64))

;: Rewind mark for the current active arena.
(defstruct ArenaMark
  (handle i64))

;: Safe ordinary-arena phase token.
(defstruct ArenaPhase
  (arena Arena)
  (mark ArenaMark))

;: Runtime hook backing `make`.
(extern (tl_arena_make) : i64)

;: Runtime hook backing `make-atomic`.
(extern (tl_arena_make_atomic) : i64)

;: Runtime hook backing `current`.
(extern (tl_arena_current) : i64)

;: Runtime hook backing `mark`.
(extern (tl_region_mark) : i64)

;: Runtime hook backing `set!`.
(unsafe
  (extern (tl_arena_set [arg0 : i64]) : unit))

;: Runtime hook backing `destroy`.
(unsafe
  (extern (tl_arena_destroy [arg0 : i64]) : unit))

;: Runtime hook backing `rewind`.
(unsafe
  (extern (tl_region_reset [arg0 : i64]) : unit))

;: Create a fresh independent arena and return its handle without switching to it.
;:
;: Prefer `with-scratch` for one-shot scratch clone-out, or pass the handle to
;: `with-escape` when the scratch arena should be reused. Direct switching or
;: destruction of the handle remains unsafe.
(define (make) : Arena
  (Arena (tl_arena_make)))

;: Create a fresh independent atomic arena without switching to it.
(define (make-atomic) : Arena
  (Arena (tl_arena_make_atomic)))

;: Return the current active arena handle, or `0` before the first allocation.
(define (current) : Arena
  (Arena (tl_arena_current)))

;: Return a rewind mark for the current active arena.
;:
;: Rewinding to the mark is unsafe because it invalidates later allocations.
(define (mark) : ArenaMark
  (ArenaMark (tl_region_mark)))

;: Start a safe phase for a direct-local arena owner.
;:
;: The compiler recognizes this call when the argument is a direct local
;: `make` or `make-atomic` owner. It records a checker generation for later
;: `in-arena` allocations and returns a token that can be consumed by
;: `rewind-safe!`.
(define (phase [arena : Arena]) : ArenaPhase
  (let
    [home : Arena (current)]
    (begin
      (unsafe
        (tl_arena_set (raw-handle arena)))
      (let
        [mark : ArenaMark (mark)]
        (begin
          (unsafe
            (tl_arena_set (raw-handle home)))
          (ArenaPhase arena mark))))))

;: Return the raw runtime handle for low-level interop.
(define (raw-handle [arena : Arena]) : i64
  (struct-get arena handle))

;: Return the raw runtime mark for low-level interop.
(define (mark-raw-handle [mark : ArenaMark]) : i64
  (struct-get mark handle))

;: Compare two arena handles by their raw runtime identity.
(define (eq? [left : Arena] [right : Arena]) : bool
  (= (raw-handle left) (raw-handle right)))

;: Compare two arena marks by their raw runtime identity.
(define (mark-eq? [left : ArenaMark] [right : ArenaMark]) : bool
  (= (mark-raw-handle left) (mark-raw-handle right)))

;: Switch the active arena to `arena`.
;:
;: This invalidates allocation assumptions for code that still expects the old
;: active arena, so calls require `(unsafe ...)`.
(unsafe
  (define (set! [arena : Arena]) : unit
    (unsafe
      (tl_arena_set (raw-handle arena)))))

;: Destroy `arena` and any chained arena segments reachable from it.
;:
;: All heap handles into that arena become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (destroy [arena : Arena]) : unit
    (unsafe
      (tl_arena_destroy (raw-handle arena)))))

;: Rewind the current active arena to `mark`.
;:
;: Heap handles allocated after the mark become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (rewind [mark : ArenaMark]) : unit
    (unsafe
      (tl_region_reset (mark-raw-handle mark)))))

;: Safely rewind a direct-local arena owner to a phase mark.
;:
;: The compiler consumes `phase` and rejects later use of values allocated in
;: the phase generation. Atomic owners additionally require all checker-visible
;: thread users to be joined or released before the rewind.
(define (rewind-safe! [phase : ArenaPhase]) : unit
  (let
    [home : Arena (current)]
    (unsafe
      (begin
        (tl_arena_set (raw-handle (struct-get phase arena)))
        (tl_region_reset (mark-raw-handle (struct-get phase mark)))
        (tl_arena_set (raw-handle home))))))

;: Safely destroy a direct-local arena owner after its values are dead.
;:
;: The compiler consumes the owner handle and rejects later use of that owner or
;: values tagged with any of its generations. Atomic owners additionally require
;: all checker-visible thread users to be joined or released before destruction.
(define (destroy-safe! [arena : Arena]) : unit
  (unsafe
    (tl_arena_destroy (raw-handle arena))))

(test
  arena-first-class-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [home : Arena (current)]
    [scratch : Arena (make)]
    (begin
      (unsafe
        (stdlib.arena.set! scratch))
      (let
        [scratch-current : Arena (current)]
        [scratch-mark : ArenaMark (mark)]
        (begin
          (if (eq? scratch-current scratch)
            unit
            (fail))
          (unsafe
            (begin
              (rewind scratch-mark)
              (stdlib.arena.set! home)
              (destroy scratch))))))))