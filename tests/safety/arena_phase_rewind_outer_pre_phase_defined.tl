;; #9480 control: a value allocated before the rewound phase stays readable,
;; and a later phase rewound first does not end the earlier one.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [kept (in-arena o (string.append "kept" "-text"))]
    [ph1 (arena.phase o)]
    [mid (in-arena o (string.append "mid" ""))]
    [ph2 (arena.phase o)]
    [v (in-arena o (string.append "late" ""))]
    [n : i64 (string.string-length (& v))]
    (begin
      (arena.rewind-safe! ph2)
      (let
        [m : i64 (string.string-length (& mid))]
        (begin
          (arena.rewind-safe! ph1)
          (in-arena o (string.append "clobber" "-the-old-text"))
          (if (string.string=? (& kept) "kept-text")
            (+ 35 (+ n m))
            7))))))