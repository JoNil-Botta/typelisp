;; #9502 control: an owner that is not on the activation stack can end inside
;; a `with-arena` nested in another arena.
(import stdlib.arena)
(import stdlib.string)

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (let
    [other (arena.make)]
    [n : i64
      (in-arena
        other
        (with-arena
          s
          (let
            [t : String (string.append "abc" "def")]
            (begin
              (arena.destroy-safe! owner)
              (+ 36 (string.string-length (& t)))))))]
    (begin
      (arena.destroy-safe! other)
      n)))

(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))