;; Deliberate sanitizer probes execute in isolated native subprocesses.
;; They never serve as source-language ownership acceptance tests.
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

(extern (tl_arena_sanitize_enable) : unit)
(extern (tl_alloc [bytes : i64]) : u64)

(define (sanitizer-byte [address : u64]) : i64
  (cast
    (unsafe
      (ptr-read (int->ptr address : (Ptr u8))))
    : i64))

(define (sanitizer-fill! [address : u64] [value : u8]) : unit
  (unsafe
    (ptr-write! (int->ptr address : (MutPtr u8)) value)))

(define (sanitizer-destroyed) : i64
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make_small)]
    [_set : unit
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.tl_arena_set owner))]
    [stale : u64 (tl_alloc 8)]
    [iteration : i64 0]
    (begin
      (sanitizer-fill! stale (cast 42 : u8))
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.tl_arena_set home))
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.tl_arena_destroy owner))
      ;; Same reservation size repeatedly exercises arena-to-arena reuse.
      (while (< iteration 128)
        (let
          [fresh : i64 (arena.tl_arena_make_small)]
          (begin
            (unsafe
              ;; lint-allow: raw-arena-op
              (arena.tl_arena_set fresh))
            (sanitizer-fill! (tl_alloc 8) (cast 42 : u8))
            (unsafe
              ;; lint-allow: raw-arena-op
              (arena.tl_arena_set home))
            (unsafe
              ;; lint-allow: raw-arena-op
              (arena.tl_arena_destroy fresh))
            (set! iteration (+ iteration 1)))))
      (sanitizer-byte stale))))

(define (sanitizer-rewind [mode : i64]) : i64
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make_small)]
    [_set : unit
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.tl_arena_set owner))]
    [prefix : u64 (tl_alloc 8)]
    [_prefix : unit (sanitizer-fill! prefix (cast 42 : u8))]
    [mark : i64 (arena.tl_region_mark)]
    ;; Mode2 forces a later segment; the other modes reclaim one segment's tail.
    [size : i64
      (if (= mode 2)
        16777216
        16384)]
    [stale : u64 (tl_alloc size)]
    [_write : unit (sanitizer-fill! stale (cast 7 : u8))]
    [_page : unit (sanitizer-fill! (+ stale (cast 8192 : u64)) (cast 9 : u8))]
    [_reset : unit
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.tl_region_reset mark))]
    [fresh : u64 (tl_alloc size)]
    [iteration : i64 0]
    (begin
      (sanitizer-fill! fresh (cast 11 : u8))
      (when (= fresh stale) (return 4))
      (unless (= (sanitizer-byte prefix) 42) (return 5))
      (cond
        [(= mode 2) (sanitizer-byte stale)]
        [(= mode 3) (sanitizer-byte (+ stale (cast 8192 : u64)))]
        [(= mode 4)
          ;; A partial page shared with live data cannot be protected. Its
          ;; poison survives the fresh allocation because the tail is sealed.
          (let
            [value : i64 (sanitizer-byte stale)]
            (begin
              (unsafe
                ;; lint-allow: raw-arena-op
                (arena.tl_arena_set home))
              (unsafe
                ;; lint-allow: raw-arena-op
                (arena.tl_arena_destroy owner))
              (if (= value 165)
                42
                6)))]
        [else
          (begin
            ;; Nested and repeated rewinds must preserve the live prefix and
            ;; safely release already sealed segment headers on destruction.
            (while (< iteration 128)
              (begin
                (unsafe
                  ;; lint-allow: raw-arena-op
                  (arena.tl_region_reset mark))
                (sanitizer-fill! (tl_alloc 16384) (cast 13 : u8))
                (unless (= (sanitizer-byte prefix) 42) (return 7))
                (set! iteration (+ iteration 1))))
            (unsafe
              ;; lint-allow: raw-arena-op
              (arena.tl_arena_set home))
            (unsafe
              ;; lint-allow: raw-arena-op
              (arena.tl_arena_destroy owner))
            42)]))))

(define (main) : i64
  (begin
    (tl_arena_sanitize_enable)
    (let
      [mode : i64 (string.>int (io.arg 1))]
      (if (= mode 1)
        (sanitizer-destroyed)
        (sanitizer-rewind mode)))))