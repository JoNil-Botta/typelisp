(module arena_raw_authority)

(import stdlib.arena)
(import stdlib.string)

;; A separately declared Arena has ordinary public fields.
(defstruct Arena
  (handle i64))

(define (restore-handle [word : (&mut word i64)] [original : i64]) : unit
  (set! (deref word) original))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [raw : i64 (arena.raw-handle owner)]
    ;; The live owner remains live through every use of this raw view.
    [view : arena.Arena
      (unsafe
        (arena.from-raw-handle raw))]
    [zero : arena.Arena
      (unsafe
        (arena.from-raw-handle 0))]
    [local : Arena (Arena 40)]
    [size : i64 (in-arena view (string.string-length (string.concat "a" "b")))]
    (begin
      (set! local.handle 39)
      (let
        [prior : i64 (replace! local.handle 0)]
        (restore-handle (&mut local.handle) (+ prior 1)))
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.destroy owner))
      (if (= (arena.raw-handle zero) 0)
        (+ local.handle size)
        1))))