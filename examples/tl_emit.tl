;; tl_emit.tl - Milestone 1 self-hosting code emitter + program driver.
;;
;; This is the backend half of the first self-hosted compiler slice (#155). It
;; lowers a tiny arithmetic Expr AST to x86_64 text using a stack discipline:
;; every expression leaves its result in %rax; a binary expression pushes the
;; left result, emits the right, moves it to %rcx, restores the left result, and
;; emits the operator instruction.
;;
;; #156 productizes that instruction sequence into a COMPLETE runnable `.s`:
;; `emit-program` wraps `emit-expr`'s body in the same `main` + `_start` skeleton
;; the Rust backend emits. The body leaves the computed value in %rax, `main`
;; returns it, and `_start` exits with that value - so the printed `.s`, when
;; assembled (`as`) + linked (`ld`) + run, EXITS 7 for `(+ 1 (* 2 3))`.

(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul))

(defenum Expr
  (EInt i64)
  (EBin BinOp Expr Expr))

(define (emit-int [n : i64]) : String
  (string-append "    movq $" (string-append (int->string n) ", %rax\n")))

(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]))

(define (emit-bin [op : BinOp] [a : Expr] [b : Expr]) : String
  (string-append (emit-expr a)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr b)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-expr [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EBin op a b) (emit-bin op a b)]))

;; emit-program: wrap the body asm in the complete backend-shaped `.s` skeleton.
;; `(-> Expr String)`. This mirrors the repository backend:
;;   .text / .globl main / .globl _start
;;   main: prologue, emitted body, epilogue, ret
;;   _start: call main, move %rax to the exit-status arg, exit syscall
;; Assembled + linked + run, this `.s` exits with the value the expression
;; computes (7 for `(+ 1 (* 2 3))`).
(define (emit-program [e : Expr]) : String
  (string-append "    .text\n"
    (string-append "    .globl main\n"
      (string-append "    .globl _start\n\n"
        (string-append "main:\n"
          (string-append "    push %rbp\n"
            (string-append "    mov %rsp, %rbp\n"
              (string-append (emit-expr e)
                (string-append "    pop %rbp\n"
                  (string-append "    ret\n\n"
                    (string-append "_start:\n"
                      (string-append "    call main\n"
                        (string-append "    movq %rax, %rdi\n"
                          (string-append "    movq $60, %rax\n"
                            "    syscall\n"))))))))))))))

(define (sample) : Expr
  (EBin (OpAdd) (EInt 1) (EBin (OpMul) (EInt 2) (EInt 3))))

;; main: emit and PRINT the COMPLETE runnable `.s` for the sample `(+ 1 (* 2 3))`.
;; The Linux-gated integration test assembles and links this printed text, then
;; runs it and asserts exit status 7.
(define (main) : unit
  (print-string (emit-program (sample))))
