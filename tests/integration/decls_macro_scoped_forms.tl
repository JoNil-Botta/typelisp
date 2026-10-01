;; decls_macro_scoped_forms.tl - expression forms inside declarations that
;; Decls and Module macros generate (#7918).
;;
;; A declaration macro's output is spelled back as source and parsed as
;; declarations. Forms that conversion did not know -- `in-arena` and `with`
;; were the reported ones -- failed with "module macro output contains syntax
;; that cannot be parsed as a declaration". Every generated function below uses
;; one such form, and the results must add up to 42.
(import stdlib.arena)
(import stdlib.string)

;; The reported reproducer: `in-arena` in a Decls-generated body.
(defmacro (gen-in-arena [name : Expr]) : Decls
  `(begin
    (define (,name [x : i64]) : i64
      (let
        [a : arena.Arena (arena.current)]
        (in-arena a (+ x 1))))))

(gen-in-arena in-arena-plus-one)

;; Scoped arenas, loop control, a lambda and comptime, all in one Decls output.
(defmacro (gen-scoped) : Decls
  `(begin
    (define (scoped-arena-length) : i64
      (with-arena scratch (string.length (string.append "ab" "cd"))))
    (define (scratch-length) : i64
      (with-scratch (string.length (string.append "x" "yz"))))
    (define (loop-control [limit : i64]) : i64
      (let
        [i : i64 0]
        [sum : i64 0]
        (begin
          (while true
            (begin
              (set! i (+ i 1))
              (if (> i limit)
                (break)
                (if (= (% i 2) 0)
                  (continue)
                  (set! sum (+ sum i))))))
          sum)))
    (define (lambda-apply [x : i64]) : i64
      (let
        [twice
          (lambda ([y : i64]) : i64
            (* y 2))]
        (twice x)))
    (define (comptime-value) : i64
      (comptime (+ 1 2)))))

(gen-scoped)

;; The second reported reproducer: `with` in a Module macro.
(defmacro (mk-with [_T : type]) : Module
  `(begin
    (module gen.mkwith)
    (defstruct Res
      (:cleanup release)
      (token (Box i64) (:cleanup drop-token)))
    (define (drop-token [token : (Box i64)]) : unit
      unit)
    (define (use-one [r : Res]) : i64
      (with ([held r release]) 4))))

(import (mk-with i64) as m)

(define (main) : i64
  ;; 2 + 4 + 3 + 9 + 14 + 3 + 4 + 3 = 42
  (+
    (in-arena-plus-one 1)
    (scoped-arena-length)
    (scratch-length)
    (loop-control 5)
    (lambda-apply 7)
    (comptime-value)
    (m.use-one (m.Res (box 1)))
    3))