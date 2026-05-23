;; tl_emit.tl — Self-hosting Milestone 1: x86_64 .s text emitter
;; Issue #155: https://github.com/JoNil-Botta/typelisp/issues/155
;;
;; Emits Intel-syntax x86_64 assembly text for integer arithmetic
;; expressions, using a stack-machine approach matching the Rust
;; backend (src/backend/mod.rs).
;;
;; Each sub-expression leaves its result in %rax.  A binary op pushes
;; the left operand, computes the right, pops, and combines.

(defenum Expr
  (EInt i64)
  (EBin BinOp Expr Expr))

(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul))

;; Emit a single Expr as assembly text.
;;
;; Grammar:
;;   (EInt n)    → "    movq $<n>, %rax\n"
;;   (EBin op l r) → emit(l)
;;                   "    pushq %rax\n"
;;                   emit(r)
;;                   "    movq %rax, %rcx\n"
;;                   "    popq %rax\n"
;;                   emit-op(op)
(define (emit-expr [e : Expr]) : String
  (match e
    [(EInt n)
     (string-append "    movq $"
     (string-append (int->string n)
                    ", %rax\n"))]
    [(EBin op a b)
     (string-append (emit-expr a)
     (string-append "    pushq %rax\n"
     (string-append (emit-expr b)
     (string-append "    movq %rax, %rcx\n"
     (string-append "    popq %rax\n"
                    (emit-op op))))))]))

;; Emit the operator instruction.
;;
;; Grammar:
;;   OpAdd → "    addq %rcx, %rax\n"
;;   OpSub → "    subq %rcx, %rax\n"
;;   OpMul → "    imulq %rcx, %rax\n"
(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]))

;; Hard-coded test case for the expression:
;;   (+ 1 (* 2 3))
;;
;; Expected emitted text (from #27):
;;   movq $1, %rax
;;   pushq %rax
;;   movq $2, %rax
;;   pushq %rax
;;   movq $3, %rax
;;   movq %rax, %rcx
;;   popq %rax
;;   imulq %rcx, %rax
;;   movq %rax, %rcx
;;   popq %rax
;;   addq %rcx, %rax
(define (test-expr) : Expr
  (EBin (OpAdd)
        (EInt 1)
        (EBin (OpMul)
              (EInt 2)
              (EInt 3))))

(define (main) : i64
  (begin
    (print-string (emit-expr (test-expr)))
    0))
