;; compiler_arena_debug.tl - native never-reset arena guard fixture.
(import stdlib.array)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import "../../src/compiler_ast_types.tl")

(extern (tl_alloc [size : i64]) : i64)

(define (compiler-arena-debug-fixture-protected) : i64
  (let
    [handle : i64 (arena.tl_arena_make)]
    (begin
      (compiler-arena-debug-protect-never-reset! handle)
      (compiler-arena-debug-protect-never-reset! handle)
      handle)))

(define (compiler-arena-debug-fixture-allowed) : i64
  (let
    [handle : i64 (compiler-arena-debug-fixture-protected)]
    [_set : unit
      (unsafe
        (arena.tl_arena_set handle))]
    [values : (__tl_dyn-array i64) (array.make-array i64 1024)]
    (begin
      (array-set! values 1023 42)
      (array-ref values 1023))))

(define (compiler-arena-debug-fixture-reset-mark) : i64
  (let
    [handle : i64 (compiler-arena-debug-fixture-protected)]
    [_set : unit
      (unsafe
        (arena.tl_arena_set handle))]
    [mark : i64 (arena.tl_region_mark)]
    [_values : (__tl_dyn-array i64) (array.make-array i64 16)]
    (begin
      (unsafe
        (arena.tl_region_reset mark))
      0)))

(define (compiler-arena-debug-fixture-reset-all) : i64
  (let
    [handle : i64 (compiler-arena-debug-fixture-protected)]
    [_set : unit
      (unsafe
        (arena.tl_arena_set handle))]
    (begin
      (unsafe
        (arena.tl_region_reset 0))
      0)))

(define (compiler-arena-debug-fixture-overflow-reset) : i64
  (let
    [handle : i64 (arena.tl_arena_make_small)]
    [_protect : unit (compiler-arena-debug-protect-never-reset! handle)]
    [_set : unit
      (unsafe
        (arena.tl_arena_set handle))]
    [_overflow : i64 (tl_alloc 16777216)]
    (begin
      (compiler-arena-debug-protect-never-reset! handle)
      (unsafe
        (arena.tl_region_reset 0))
      0)))

(define (compiler-arena-debug-fixture-implicit-reset) : i64
  (let
    [_clear : unit
      (unsafe
        (arena.tl_arena_set 0))]
    [_allocation : i64 (tl_alloc 8)]
    [handle : i64 (arena.tl_arena_current)]
    (begin
      (compiler-arena-debug-protect-never-reset! handle)
      (unsafe
        (arena.tl_region_reset 0))
      0)))

(define (compiler-arena-debug-fixture-unprotected-reset) : i64
  (let
    [_clear : unit
      (unsafe
        (arena.tl_arena_set 0))]
    [_allocation : i64 (tl_alloc 8)]
    (begin
      (unsafe
        (arena.tl_region_reset 0))
      42)))

(define (compiler-arena-debug-fixture-destroy) : i64
  (let
    [handle : i64 (compiler-arena-debug-fixture-protected)]
    (begin
      (unsafe
        (arena.tl_arena_destroy handle))
      0)))

(define (compiler-arena-debug-fixture-pool-install) : i64
  (let
    [home : i64 (arena.tl_arena_current)]
    [handle : i64 (compiler-arena-debug-fixture-protected)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena 8 8 handle)]
    [_restore : unit
      (unsafe
        (arena.tl_arena_set home))]
    (begin
      (ast-node-pool-context-install! pools)
      0)))

(define (compiler-arena-debug-fixture-invalid-atomic) : i64
  (let
    [handle : i64 (arena.tl_arena_make_atomic)]
    (begin
      (compiler-arena-debug-protect-never-reset! handle)
      0)))

(define (main) : i64
  (if (< (io.arg-count) 2)
    2
    (let
      [operation : String (io.arg 1)]
      (cond
        [(string.eq operation "allowed") (compiler-arena-debug-fixture-allowed)]
        [(string.eq operation "reset-mark")
          (compiler-arena-debug-fixture-reset-mark)]
        [(string.eq operation "reset-all")
          (compiler-arena-debug-fixture-reset-all)]
        [(string.eq operation "overflow-reset")
          (compiler-arena-debug-fixture-overflow-reset)]
        [(string.eq operation "implicit-reset")
          (compiler-arena-debug-fixture-implicit-reset)]
        [(string.eq operation "unprotected-reset")
          (compiler-arena-debug-fixture-unprotected-reset)]
        [(string.eq operation "destroy") (compiler-arena-debug-fixture-destroy)]
        [(string.eq operation "pool-install")
          (compiler-arena-debug-fixture-pool-install)]
        [(string.eq operation "invalid-null")
          (begin
            (compiler-arena-debug-protect-never-reset! 0)
            0)]
        [(string.eq operation "invalid-address")
          (begin
            (compiler-arena-debug-protect-never-reset! 4096)
            0)]
        [(string.eq operation "invalid-atomic")
          (compiler-arena-debug-fixture-invalid-atomic)]
        [else 3]))))