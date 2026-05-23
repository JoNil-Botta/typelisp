;; tl_parse.tl - The s-expression PARSER that completes the end-to-end
;; self-hosted compiler pipeline: `lex -> read -> parse -> emit-program` turns
;; SOURCE TEXT into a runnable x86_64 `.s`, all in TypeLisp (#154).
;;
;; --------------------------------------------------------------------------
;; Where this sits in the front end.
;; --------------------------------------------------------------------------
;; The reader (`tl_read.tl`) turns the lexer's token stream into the generic
;; cons-cell `Sexpr` tree the parens describe - it knows nothing about which
;; symbols are operators. The BACKEND (`tl_emit.tl`) lowers a tiny, TYPED
;; arithmetic `Expr` AST (`(EInt n)` / `(EBin op a b)`) to x86_64 text. This
;; module is the missing middle: `parse : Sexpr -> Expr` recognises the
;; arithmetic SUBSET of s-expressions and projects it onto that `Expr` AST, so
;;
;;   String --lex--> (Array Token) --read--> Sexpr --parse--> Expr --emit--> .s
;;
;; becomes a single composition. `main` runs the WHOLE pipeline on the literal
;; source string "(+ 1 (* 2 3))" and prints the complete runnable `.s`; assembled
;; (`as`) + linked (`ld`) + run, that `.s` EXITS 7 - the same value the emitter
;; proved, now reached THROUGH lex -> read -> parse.
;;
;; --------------------------------------------------------------------------
;; The import decision: import shared AST types + reader, duplicate emitter helpers.
;; --------------------------------------------------------------------------
;; `tl_read.tl` is a `main`-less module (refs #44): `(import "tl_read.tl")` pulls
;; in `lex`, `read`, and the `Sexpr` AST (it transitively imports the `main`-less
;; `tl_lex.tl` + `tl_token.tl`). The module loader is whole-program-concatenation,
;; so it copies all imported declarations into one program before typecheck ->
;; lower -> codegen. That import is clean BECAUSE none of those modules declares a
;; `main`.
;;
;; The shared `tl_ast_types.tl` module is also `main`-less, so `BinOp` / `Expr`
;; come from the same AST definition used by `tl_emit.tl`.
;;
;; The backend `tl_emit.tl`, by contrast, is a runnable DEMO and carries its own
;; `main`. Importing it here - where we ALSO need a `main` to drive the pipeline -
;; would concatenate two `main`s into one program and clash on the duplicate
;; symbol (the known module limitation documented in tl_read.tl). So only the
;; `emit-*` / `emit-program` helpers are duplicated below, pending a shared
;; `main`-less emitter module (see #27). This is the same trade-off tl_eval.tl
;; took: import the `main`-less front end, keep the `main`-bearing piece separate.
;; The result COMPILES with exactly one `main` (this file's) and runs the real
;; pipeline.
;;
;; `string-eq` (used by `parse-op`) is a host builtin (see its many uses in
;; tl_eval.tl), not a module export, so it needs no import.

(import "tl_ast_types.tl")
(import "tl_read.tl")

;; ==========================================================================
;; Duplicated from tl_emit.tl (#155/#156) pending a shared module (see #27).
;; The x86_64 emitter helpers. The AST comes from `tl_ast_types.tl`.
;; ==========================================================================

;; Compile-time name->slot environment (#163), duplicated from tl_emit.tl
;; alongside the emitter helpers (same shared-module trade-off documented above).
(defenum CEnv
  (CNil)
  (CBind String i64 CEnv))

(define (cenv-lookup [env : CEnv] [name : String]) : i64
  (match env
    [(CNil) (begin (panic "emit: unbound variable") 0)]
    [(CBind bound off rest)
     (if (string-eq bound name) off (cenv-lookup rest name))]))

(define (emit-int [n : i64]) : String
  (string-append "    movq $" (string-append (int->string n) ", %rax\n")))

(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]))

(define (emit-bin [op : BinOp] [a : Expr] [b : Expr] [env : CEnv] [depth : i64]) : String
  (string-append (emit-expr a env depth)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr b env depth)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-var [name : String] [env : CEnv]) : String
  (string-append "    movq -"
    (string-append (int->string (cenv-lookup env name))
      "(%rbp), %rax\n")))

(define (emit-let [name : String] [val : Expr] [body : Expr] [env : CEnv] [depth : i64]) : String
  (let ([off : i64 (* 8 (+ depth 1))])
    (string-append (emit-expr val env depth)
      (string-append "    movq %rax, -"
        (string-append (int->string off)
          (string-append "(%rbp)\n"
            (emit-expr body (CBind name off env) (+ depth 1))))))))

(define (emit-expr [e : Expr] [env : CEnv] [depth : i64]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar name) (emit-var name env)]
    [(EBin op a b) (emit-bin op a b env depth)]
    [(ELet name val body) (emit-let name val body env depth)]
    [(ECall _ _) (begin (panic "emit: calls are not in M1 arithmetic") "")]))

(define (max2 [a : i64] [b : i64]) : i64
  (if (> a b) a b))

(define (let-depth [e : Expr]) : i64
  (match e
    [(EInt _) 0]
    [(EVar _) 0]
    [(EBin _ a b) (max2 (let-depth a) (let-depth b))]
    [(ELet _ val body) (max2 (let-depth val) (+ 1 (let-depth body)))]
    [(ECall _ _) 0]))

(define (round-up-16 [n : i64]) : i64
  (* (/ (+ n 15) 16) 16))

(define (emit-frame-reserve [k : i64]) : String
  (if (= k 0)
      ""
      (string-append "    sub $" (string-append (int->string k) ", %rsp\n"))))

(define (emit-frame-restore [k : i64]) : String
  (if (= k 0)
      ""
      (string-append "    add $" (string-append (int->string k) ", %rsp\n"))))

(define (emit-program [e : Expr]) : String
  (let ([k : i64 (round-up-16 (* 8 (let-depth e)))])
    (string-append "    .text\n"
      (string-append "    .globl main\n"
        (string-append "    .globl _start\n\n"
          (string-append "main:\n"
            (string-append "    push %rbp\n"
              (string-append "    mov %rsp, %rbp\n"
                (string-append (emit-frame-reserve k)
                  (string-append (emit-expr e (CNil) 0)
                    (string-append (emit-frame-restore k)
                      (string-append "    pop %rbp\n"
                        (string-append "    ret\n\n"
                          (string-append "_start:\n"
                            (string-append "    call main\n"
                              (string-append "    movq %rax, %rdi\n"
                                (string-append "    movq $60, %rax\n"
                                  "    syscall\n")))))))))))))))))

;; ==========================================================================
;; The PARSER: `Sexpr -> Expr`, the new contribution of this module (#154).
;; ==========================================================================

;; parse-op: resolve an operator SYMBOL's text to its `BinOp` tag. The arithmetic
;; surface recognises exactly `+`, `-`, `*`, dispatched byte-wise on the lexeme
;; with the host `string-eq` (the same builtin tl_eval.tl uses for operator
;; dispatch). Any other head symbol is not part of the recognised arithmetic
;; subset, so it is a MALFORMED program: abort via the `panic` builtin (#45) -
;; the codebase's channel for malformed input, exactly as the reader uses it.
;; `panic` never returns, but the trailing `(OpAdd)` gives the `if` a `BinOp` so
;; the function typechecks.
(define (parse-op [op : String]) : BinOp
  (if (string-eq op "+")
      (OpAdd)
      (if (string-eq op "-")
          (OpSub)
          (if (string-eq op "*")
              (OpMul)
              (begin
                (panic "parse: unknown operator")
                (OpAdd))))))

;; parse: project the arithmetic SUBSET of the generic `Sexpr` tree onto the
;; typed `Expr` AST the emitter consumes.
;;   (SInt n)                                 -> (EInt n)              an int leaf
;;   (SCons (SSym op) (SCons a (SCons b (SNil)))) -> (EBin (parse-op op)
;;                                                          (parse a) (parse b))
;; i.e. exactly a proper 3-element list whose head is a symbol: an operator
;; applied to two operand sub-expressions, each parsed recursively (so nesting
;; like `(* 2 3)` inside `(+ 1 ...)` is handled for free). Anything else - a bare
;; symbol, a string atom, the empty list, a list of the wrong shape/arity, or an
;; operator applied to non-two operands - is OUTSIDE the recognised arithmetic
;; subset and therefore a MALFORMED program: abort via `panic`, keeping `parse`
;; TOTAL (it returns an `Expr` on every well-formed input and never otherwise) and
;; directly composable as `(emit-program (parse (read (lex src))))`. The trailing
;; `(EInt 0)` is unreachable dead code that gives the fall-through `match` arm an
;; `Expr` so the function typechecks.
;; parse-let: project the single-binding `let` shape onto `(ELet name val body)`.
;; The reader builds `(let ((x e)) body)` as
;;   (SCons (SSym "let")
;;     (SCons (SCons (SCons (SSym x) (SCons e (SNil))) (SNil))   ; one-binding list
;;       (SCons body (SNil))))                                    ; the body
;; `rest` here is the tail AFTER the `let` head, i.e. the binding-list cons'd
;; onto the body. Slice 1 accepts EXACTLY one binding and exactly one body form;
;; any other shape (zero/multiple bindings, missing body, non-symbol binder) is
;; a MALFORMED program - abort via `panic`, keeping `parse-let` total. The
;; trailing `(EInt 0)` gives the never-returning `panic` arm an `Expr` so the
;; function typechecks.
(define (parse-let [rest : Sexpr]) : Expr
  (match rest
    [(SCons (SCons (SCons (SSym x) (SCons e (SNil))) (SNil)) (SCons body (SNil)))
     (ELet x (parse e) (parse body))]
    [_ (begin
         (panic "parse: malformed let")
         (EInt 0))]))

;; parse: project the recognised SUBSET of the generic `Sexpr` tree onto the
;; typed `Expr` AST the emitter consumes. A bare `(SSym name)` is a variable
;; reference `(EVar name)`. A list whose head symbol is `let` is dispatched to
;; `parse-let` BEFORE the operator-application shape, so `let` is a special form
;; rather than a call to a function named "let". Otherwise a proper 3-element
;; list headed by an operator symbol is a binary application. Anything else is
;; MALFORMED - abort via `panic`. The trailing `(EInt 0)` is unreachable dead
;; code for the fall-through arm so the function typechecks.
(define (parse [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SCons (SSym op) rest)
     (if (string-eq op "let")
         (parse-let rest)
         (match rest
           [(SCons a (SCons b (SNil)))
            (EBin (parse-op op) (parse a) (parse b))]
           [_ (begin
                (panic "parse: malformed expression")
                (EInt 0))]))]
    [_ (begin
         (panic "parse: malformed expression")
         (EInt 0))]))

;; main: run the WHOLE self-hosted pipeline end to end on a literal source string
;; and PRINT the complete runnable `.s`. `lex` tokenises the text, `read` builds
;; the `Sexpr` cons tree, `parse` projects it onto the `Expr` AST, and
;; `emit-program` lowers that to a full backend-shaped `.s`. For "(+ 1 (* 2 3))"
;; the emitted program, when assembled + linked + run, exits 7 - so this single
;; line takes SOURCE TEXT to machine code that runs and returns 7, the headline
;; of #154. The Linux-gated integration test assembles the printed text and
;; asserts exit status 7; the printed `.s` is byte-identical to tl_emit's, since
;; both compute `(+ 1 (* 2 3))`.
(define (main) : unit
  (print-string (emit-program (parse (read (lex "(+ 1 (* 2 3))"))))))
