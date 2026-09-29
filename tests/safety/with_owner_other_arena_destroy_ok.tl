;; Destroying one arena leaves a `with` owner allocated in another arena, and
;; an enclosing owner from the caller's arena, usable; so does destroying an
;; arena after the `with` scope that used it has ended.
(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [keep : arena.Arena (arena.make)]
    [after : arena.Arena (arena.make)]
    (begin
      (with
        ([ended
            (in-arena after (Owner 1 (string.concat "a" "b")))
            cleanup-owner])
        (string.string-length (& ended.text)))
      (arena.destroy-safe! after)
      (with
        ([outer (Owner 1 (string.concat "out" "er")) cleanup-owner]
          [kept
            (in-arena keep (Owner 1 (string.concat "ke" "pt")))
            cleanup-owner])
        (let
          [inner-len : i64
            (with
              ([inner
                  (in-arena scratch (Owner 1 (string.concat "in" "ner")))
                  cleanup-owner])
              (string.string-length (& inner.text)))]
          (begin
            (arena.destroy-safe! scratch)
            (+
              inner-len
              (string.string-length (& outer.text))
              (string.string-length (& kept.text))
              28)))))))