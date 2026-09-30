(import stdlib.arena)
(import stdlib.io)

(define (release-return
  [owner : (arena.Arena r) (:invalidate r)]
  [early : bool]) : i64
  (if early
    (begin
      (arena.destroy-safe! owner)
      (return 20))
    (begin
      (arena.destroy-safe! owner)
      22)))

(define (release-or-panic
  [owner : (arena.Arena r) (:invalidate r)]
  [fail : bool]) : unit
  (if fail
    (io.panic "no normal exit")
    (arena.destroy-safe! owner)))

(define (release-after-loop
  [owner : (arena.Arena r) (:invalidate r)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! i (+ i 1))
          (if (= i 2)
            (break)
            (continue))))
      (arena.destroy-safe! owner))))

(define (main) : i64
  (let
    [a (arena.make)]
    [b (arena.make)]
    [c (arena.make)]
    [d (arena.make)]
    [e (arena.make)]
    [x : i64 (release-return a true)]
    [y : i64 (release-return b false)]
    (begin
      (release-or-panic c false)
      (release-after-loop d 0)
      (release-after-loop e 3)
      (+ x y))))