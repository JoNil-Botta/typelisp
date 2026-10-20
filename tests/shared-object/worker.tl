;; The TypeLisp side of the shared-object dlopen test (#8257): a global set by
;; a runtime initializer and a function that allocates through the arena.
;; scripts/verify-linux-shared-object-code-model.sh builds it with the
;; shared-object code model, links it with the C shim it writes into a DSO, and
;; its C driver calls it from two host threads.
(import stdlib.string)
(import stdlib.arena)

(define suffix : String
  (string.int->string 7000))

;; The total decimal length of `seed + i` and of `suffix`, for i below 2000.
;; Each step allocates a fresh string in the calling thread's arena.
(define (work [seed : i64]) : i64
  (let
    [root : i64
      (unsafe
        (arena.tl_arena_growth_target 0))]
    [total : i64 0]
    [i : i64 0]
    (unless
      (and
        (!= root 0)
        (=
          (unsafe
            (arena.tl_arena_growth_target root))
          root))
      (return -1))
    (while (< i 2000)
      (let
        [text : String (string.int->string (+ seed i))]
        (set!
          total
          (+
            total
            (+
              (string.string-length (& text))
              (string.string-length (& suffix))))))
      (set! i (+ i 1)))
    (if (= (arena.tl_arena_current) root)
      total
      -2)))

;; Not run in a shared object, which has no entry; it keeps `work` reachable
;; until #8194's export policy roots exported functions.
(define (main) : i64
  (work 1))