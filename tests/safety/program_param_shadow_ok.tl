;; A parameter named `program` names its own lifetime, shadowing the reserved
;; one: `(& program Prog)` there is an ordinary borrow for the call, so a local
;; is lent and moved afterwards (main 4e46ce356 exits 3).
(defstruct Prog
  (decls (__tl_dyn-array i64)))

(define (count-decls [program : (& program Prog)]) : i64
  (array-length program.decls))

(define (consume [program : Prog]) : i64
  (array-length program.decls))

(define (main) : i64
  (let
    [program : Prog (Prog (__tl_make-array i64 3))]
    [n : i64 (count-decls (& program))]
    (if (= n (consume program))
      3
      1)))