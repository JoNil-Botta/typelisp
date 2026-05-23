;; tl_define.tl - Self-hosting M1 (#169): `define` + `ECall` codegen demo.
;;
;; This is the BIG construct of the self-hosted backend slice: user FUNCTIONS,
;; CALLS, and RECURSION. `tl_emit_core.tl`'s `emit-items` walks a `(List Item)`
;; and lowers each `(define (name p..) body)` to its own `<name>:` block under
;; the System V AMD64 calling convention:
;;
;;   * prologue `push %rbp` / `mov %rsp,%rbp` / `sub $frame,%rsp`;
;;   * spill the incoming argument registers (%rdi,%rsi,..) into per-parameter
;;     stack slots, pre-binding each parameter name into the function's initial
;;     CEnv so `EVar` resolves a parameter through the SAME path as a `let`;
;;   * body -> %rax;
;;   * epilogue `mov %rbp,%rsp` / `pop %rbp` / `ret`.
;;
;; An `(ECall name args)` evaluates each argument left-to-right with a balanced
;; `pushq %rax`, pops them into the argument registers in reverse, then
;; `call <name>`; the result lands in %rax. RECURSION needs no special handling:
;; a self-call's `call <name>` resolves against the emitted label at assembly
;; time. The `define` named `main` is the entry; `_start` calls it and turns its
;; %rax into the process exit code.
;;
;; `main` here builds the AST for
;;
;;   (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
;;   (define (main) (fact 5))
;;
;; and PRINTS the complete runnable `.s`. Assembled (`as`) + linked (`ld`) + run,
;; that `.s` EXITS 120 - i.e. `fact 5` = 120, witnessing that define, multi-block
;; emission, the call sequence, AND RECURSION all work end to end.

(import "tl_emit_core.tl")

;; fact-body: (if (= n 0) 1 (* n (fact (- n 1))))
(define (fact-body) : Expr
  (EIf (EBin (OpEq) (EVar "n") (EInt 0))
       (EInt 1)
       (EBin (OpMul)
             (EVar "n")
             (ECall "fact" (ELCons (EBin (OpSub) (EVar "n") (EInt 1)) ELNil)))))

;; program: the two-define list `[ (define (fact n) ..) , (define (main) (fact 5)) ]`.
(define (program) : ItemList
  (ILCons (IDefFn "fact" (SLCons "n" SLNil) (fact-body))
    (ILCons (IDefFn "main" SLNil
              (ECall "fact" (ELCons (EInt 5) ELNil)))
      ILNil)))

;; main: emit and PRINT the COMPLETE runnable `.s` for the recursive `fact`
;; program. The Linux-gated integration test assembles and links this printed
;; text, then runs it and asserts exit status 120.
(define (main) : unit
  (print-string (emit-items (program))))
