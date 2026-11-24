;; #9944: User definitions and local bindings shadow program-argc, program-argv,
;; program-envp, and syscall while unshadowed calls in other modules keep the
;; compiler builtins.
(import process_syscall_shadow_dep as dep)

(define (program-argc [n : i64]) : i64
  (+ n 10))

(define (program-argv) : i64
  11)

(define (program-envp [a : i64] [b : i64]) : i64
  (+ a b))

;; User-defined `syscall` is an ordinary safe function (no `unsafe` required)
;; and may take zero arguments.
(define (syscall) : i64
  13)

(define (local-shadows-ok?) : bool
  (let
    [program-argc
      (lambda () : i64
        21)]
    [program-argv
      (lambda ([x : i64]) : i64
        (+ x 2))]
    [program-envp
      (lambda () : i64
        23)]
    [syscall
      (lambda ([x : i64]) : i64
        (* x 3))]
    (and
      (= (program-argc) 21)
      (= (program-argv 20) 22)
      (= (program-envp) 23)
      (= (syscall 8) 24))))

(define (main) : i64
  (unless (dep.real-builtins-ok?) (return 1))
  (unless (= (program-argc 5) 15) (return 2))
  (unless (= (program-argv) 11) (return 3))
  (unless (= (program-envp 4 8) 12) (return 4))
  (unless (= (syscall) 13) (return 5))
  (unless (local-shadows-ok?) (return 6))
  42)