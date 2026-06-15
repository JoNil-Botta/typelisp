(import stdlib.arena)

(import stdlib.test)

(define (main) : i64
  (let
    [home : i64 (arena.arena-current)]
    [scratch : i64 (arena.arena-make)]
    (begin
      (unsafe
        (begin
          (arena-set! scratch)))
      (let
        [scratch-current : i64 (arena.arena-current)]
        [scratch-mark : i64 (arena.arena-mark)]
        (begin
          (test.assert-i64-eq
            scratch-current
            scratch
            "arena-set! should switch the current arena")
          (unsafe
            (begin
              (arena-rewind scratch-mark)
              (arena-set! home)
              (arena-destroy scratch)))
          42)))))