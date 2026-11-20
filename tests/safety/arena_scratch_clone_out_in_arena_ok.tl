;: Control for the clone-out escape fixtures: the same with-scratch result is a
;: fresh allocation in the enclosing `with-arena r`, so reading it inside that
;: body is accepted and sees live storage (red-team finds f01-f06).
(import stdlib.string)

(extern (tl_arena_poison_enable) : unit)

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (with-arena
      r
      (let
        [s : String (with-scratch (string.append "a" "b"))]
        [b : (Box String) (with-scratch (box (string.append "c" "d")))]
        (if (and (string.eq (& s) "ab") (string.eq (& (deref b)) "cd"))
          42
          7)))))