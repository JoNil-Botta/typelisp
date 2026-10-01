;; Passing a bare-annotated owner to a bare `arena.Arena` parameter borrows it;
;; the owner can still be destroyed afterwards (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (measure [scratch : arena.Arena]) : i64
  (string.string-length (in-arena scratch (string.concat "forty" "-two!"))))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [first : i64 (measure owner)]
    [second : i64 (measure owner)]
    (begin
      (arena.destroy-safe! owner)
      (+ (* first 4) (+ second (- 2 10))))))