(module arena_raw_authority)

(import stdlib.arena)
(import stdlib.string)

;; An unrelated nominal spelling does not acquire the builtin's effect.
(defstruct Arena
  (handle i64))

(define (restore-handle [word : (&mut word i64)] [original : i64]) : unit
  (set! (deref word) original))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [raw : i64 owner.handle]
    ;; The live owner remains live through every use of this raw view.
    [view : arena.Arena
      (unsafe
        (arena.Arena raw))]
    [zero : arena.Arena (init : arena.Arena)]
    [local : Arena (Arena 40)]
    [size : i64 (in-arena view (string.string-length (string.concat "a" "b")))]
    (begin
      (unsafe
        (begin
          (set! view.handle raw)
          (let
            [_prior : i64 (replace! view.handle raw)]
            (restore-handle (&mut view.handle) raw))))
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.destroy owner))
      (if (= zero.handle 0)
        (+ local.handle size)
        1))))