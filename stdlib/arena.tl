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
;#       [text : String (string.string-append-borrowed (& prefix) (& suffix))]
;#       (string-length (& text)))))
;# ```
;#
;# To keep one result from repeated scratch work, allocate a first-class arena
;# with `arena-make` and use `with-escape`; the form clones supported results
;# back into the enclosing active arena:
;#
;# ```typelisp
;# (import stdlib.arena)
;# (import stdlib.string)
;#
;# (define (build-message [scratch : i64] [n : i64]) : String
;#   (with-escape
;#     scratch
;#     (let
;#       [prefix : String "kept:"]
;#       [suffix : String (string.int->string n)]
;#       (string.string-append-borrowed (& prefix) (& suffix)))))
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
;# (define (build-in-level [level : i64] [n : i64]) : String
;#   (in-arena
;#     level
;#     (string.string-append "level:" (string.int->string n))))
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
;#     [home : i64 (arena.arena-current)]
;#     [scratch : i64 (arena.arena-make)]
;#     (unsafe
;#       (begin
;#         (arena.arena-set! scratch)
;#         (arena.arena-rewind (arena.arena-mark))
;#         (arena.arena-set! home)
;#         (arena.arena-destroy scratch)))))
;# ```
;#
;# `ArenaHandle`/`ArenaMark` are temporary `i64` aliases until opaque public
;# handle types land (#182/#1632). The public helpers are wrappers over raw
;# runtime externs so this module stays formatter-stable until extern metadata
;# formatting is fixed (#1827).
;: Runtime hook backing `arena-make`.
(module stdlib.arena)

(extern (tl_arena_make) : i64)

;: Runtime hook backing `arena-current`.
(extern (tl_arena_current) : i64)

;: Runtime hook backing `arena-mark`.
(extern (tl_region_mark) : i64)

;: Runtime hook backing `arena-set!`.
(unsafe
  (extern (tl_arena_set [arg0 : i64]) : unit))

;: Runtime hook backing `arena-destroy`.
(unsafe
  (extern (tl_arena_destroy [arg0 : i64]) : unit))

;: Runtime hook backing `arena-rewind`.
(unsafe
  (extern (tl_region_reset [arg0 : i64]) : unit))

;: Create a fresh independent arena and return its handle without switching to it.
;:
;: Prefer passing the handle to `with-escape` for safe scratch-work clone-out.
;: Direct switching or destruction of the handle remains unsafe.
(define (arena-make) : i64
  (stdlib.arena.tl_arena_make))

;: Return the current active arena handle, or `0` before the first allocation.
(define (arena-current) : i64
  (stdlib.arena.tl_arena_current))

;: Return a rewind mark for the current active arena.
;:
;: Rewinding to the mark is unsafe because it invalidates later allocations.
(define (arena-mark) : i64
  (stdlib.arena.tl_region_mark))

;: Switch the active arena to `arena`.
;:
;: This invalidates allocation assumptions for code that still expects the old
;: active arena, so calls require `(unsafe ...)`.
(unsafe
  (define (arena-set! [arena : i64]) : unit
    (unsafe
      (stdlib.arena.tl_arena_set arena))))

;: Destroy `arena` and any chained arena segments reachable from it.
;:
;: All heap handles into that arena become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (arena-destroy [arena : i64]) : unit
    (unsafe
      (stdlib.arena.tl_arena_destroy arena))))

;: Rewind the current active arena to `mark`.
;:
;: Heap handles allocated after the mark become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (arena-rewind [mark : i64]) : unit
    (unsafe
      (stdlib.arena.tl_region_reset mark))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value tl_arena_make)
  (value tl_arena_current)
  (value tl_region_mark)
  (value arena-make)
  (value arena-current)
  (value arena-mark)
  (value arena-destroy)
  (value arena-rewind)
  (value arena-set!)
  (value tl_arena_destroy)
  (value tl_arena_set)
  (value tl_region_reset))