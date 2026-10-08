;; The TypeLisp side of the shared-object dlopen test (#8257): a global set by
;; a runtime initializer and a function that allocates through the arena.
;; scripts/verify-linux-shared-object-code-model.sh builds it with the
;; shared-object code model, links it with the C shim it writes into a DSO, and
;; its C driver calls it from two host threads.
(import stdlib.string)

(define suffix : String
  (string.int->string 7000))

;; The total decimal length of `seed + i` and of `suffix`, for i below 2000.
;; Each step allocates a fresh string in the calling thread's arena.
(define (work [seed : i64]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
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
    total))

;; Not run in a shared object, which has no entry; it keeps `work` reachable
;; until #8194's export policy roots exported functions.
(define (main) : i64
  (work 1))