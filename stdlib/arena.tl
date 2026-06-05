;# First-class arena helper API.
;#
;# Provides explicit arena handles for advanced allocation control. Prefer
;# `(with-arena ...)` for scoped reclamation when possible; these helpers expose
;# manual switching/rewinding/destruction and can invalidate live heap handles.
;#
;# Usage: `(import "stdlib/arena.tl")`
;#
;# `ArenaHandle`/`ArenaMark` are temporary `i64` aliases until opaque public
;# handle types land (#182/#1632). The public helpers are wrappers over raw
;# runtime externs so this module stays formatter-stable until extern metadata
;# formatting is fixed (#1827).
;: Runtime hook backing `arena-make`.
(extern tl_arena_make : (-> i64))

;: Runtime hook backing `arena-current`.
(extern tl_arena_current : (-> i64))

;: Runtime hook backing `arena-mark`.
(extern tl_region_mark : (-> i64))

;: Runtime hook backing `arena-set!`.
(unsafe
  (extern tl_arena_set : (-> i64 unit)))

;: Runtime hook backing `arena-destroy`.
(unsafe
  (extern tl_arena_destroy : (-> i64 unit)))

;: Runtime hook backing `arena-rewind`.
(unsafe
  (extern tl_region_reset : (-> i64 unit)))

;: Create a fresh independent arena and return its handle without switching to it.
(define (arena-make) : i64
  (tl_arena_make))

;: Return the current active arena handle, or `0` before the first allocation.
(define (arena-current) : i64
  (tl_arena_current))

;: Return a rewind mark for the current active arena.
(define (arena-mark) : i64
  (tl_region_mark))

;: Switch the active arena to `arena`.
;:
;: This invalidates allocation assumptions for code that still expects the old
;: active arena, so calls require `(unsafe ...)`.
(unsafe
  (define (arena-set! [arena : i64]) : unit
    (unsafe
      (tl_arena_set arena))))

;: Destroy `arena` and any chained arena segments reachable from it.
;:
;: All heap handles into that arena become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (arena-destroy [arena : i64]) : unit
    (unsafe
      (tl_arena_destroy arena))))

;: Rewind the current active arena to `mark`.
;:
;: Heap handles allocated after the mark become invalid, so calls require
;: `(unsafe ...)`.
(unsafe
  (define (arena-rewind [mark : i64]) : unit
    (unsafe
      (tl_region_reset mark))))