;; tl_emit.tl - The first slice of the SELF-HOSTED CODE GENERATOR (#27/#155):
;; an `Expr -> String` x86_64 assembly-text emitter for the integer + `+`/`-`/`*`
;; subset of the compiler's arithmetic AST, written as a STACK MACHINE.
;;
;; Where `parser.tl` builds the recursive `Expr` AST and `tl_eval.tl` INTERPRETS a
;; tree, this is the codegen half: it WALKS the same `Expr` tree and PRODUCES the
;; x86_64 assembly TEXT that, when assembled and run, computes the expression's
;; value. It does not evaluate the expression at compile time - it emits the
;; instruction sequence a real backend would, so the output is genuine machine-code
;; text rather than a number.
;;
;;   Expr --emit-expr--> String   (a sequence of "    <insn>\n" lines)
;;
;; --------------------------------------------------------------------------
;; The AST: the integer + `+`/`-`/`*` subset of the compiler `Expr` (refs #111).
;; --------------------------------------------------------------------------
;; The exact recursive enum `parser.tl` builds (minus `/`, which the backend
;; lowers via a different idiom - cqto/idivq - so it is deferred to a later
;; slice): an integer literal, or a binary node over two sub-expressions for each
;; of the three arithmetic operators. Recursive enum payloads (#111) make each
;; `Expr` child an 8-byte heap pointer, so the layout is finite and the tree is
;; built bottom-up the way the parser would build it.
(defenum Expr
  (ENum i64)
  (EAdd Expr Expr)
  (ESub Expr Expr)
  (EMul Expr Expr))

;; --------------------------------------------------------------------------
;; emit-expr: the recursive STACK-MACHINE code generator. `(-> Expr String)`.
;; --------------------------------------------------------------------------
;; A post-order walk of the `Expr` tree that yields the x86_64 assembly TEXT
;; computing the expression, with the result left in `%rax`. This mirrors the
;; Rust backend's own integer-arithmetic emission (`src/backend/mod.rs:2198-2213`):
;; load the lhs into `%rax`, the rhs into `%rcx`, then `addq %rcx,%rax` /
;; `subq %rcx,%rax` / `imulq %rcx,%rax`.
;;
;;   (ENum n)   -> a single `movq $n, %rax` that loads the literal into %rax.
;;                 `int->string` renders the i64 `n` as its decimal text, spliced
;;                 between the `movq $` prefix and the `, %rax\n` suffix.
;;   (EAdd a b) / (ESub a b) / (EMul a b)
;;              -> the STACK-MACHINE binary sequence. Each sub-expression leaves
;;                 its result in %rax, so a binary op:
;;                   1. emits the LEFT operand            (-> result in %rax)
;;                   2. `pushq %rax`                      (save the left result)
;;                   3. emits the RIGHT operand           (-> result in %rax)
;;                   4. `movq %rax, %rcx`                 (right result -> %rcx)
;;                   5. `popq %rax`                       (left result back -> %rax)
;;                   6. the op mnemonic, combining %rax (op) %rcx -> %rax.
;;                 The stack discipline is what makes nesting work to arbitrary
;;                 depth: an inner op pushes/pops around its own children before
;;                 the outer op pushes/pops around it.
;;
;; The text is assembled with pairwise `string-append` (the registered host
;; builtin, `src/typechecker.rs:138`, lowering to the `tl_string_concat` runtime
;; that copies both operands into one fresh heap String). A chunked string builder
;; is a known scaling follow-up, not needed for one expression. `emit-expr` is
;; genuinely recursive: a binary node re-enters `emit-expr` on each child, so the
;; emitted text reflects the whole nested tree shape.
(define (emit-expr [e : Expr]) : String
  (match e
    [(ENum n)
     (string-append "    movq $"
                    (string-append (int->string n) ", %rax\n"))]
    [(EAdd a b) (emit-binop a b "    addq %rcx, %rax\n")]
    [(ESub a b) (emit-binop a b "    subq %rcx, %rax\n")]
    [(EMul a b) (emit-binop a b "    imulq %rcx, %rax\n")]))

;; emit-binop: the shared stack-machine sequence for every binary node. The three
;; arithmetic variants differ ONLY in the final mnemonic, so they all funnel
;; through this helper, which threads the operator's instruction text in as `op`.
;; Emits left, saves it, emits right, moves right to %rcx, restores left to %rax,
;; then the op - exactly the six-step shape documented on `emit-expr`.
(define (emit-binop [a : Expr] [b : Expr] [op : String]) : String
  (string-append
   (emit-expr a)
   (string-append "    pushq %rax\n"
   (string-append
    (emit-expr b)
    (string-append "    movq %rax, %rcx\n"
    (string-append "    popq %rax\n" op))))))

;; --------------------------------------------------------------------------
;; main: emit and PRINT the asm for the sample expression `(+ 1 (* 2 3))`.
;; --------------------------------------------------------------------------
;; Build the AST `(EAdd (ENum 1) (EMul (ENum 2) (ENum 3)))` by hand (a parser
;; would build this from the surface syntax `(+ 1 (* 2 3))`) and print the asm
;; text `emit-expr` produces for it via the host `print-string` builtin (raw
;; bytes to fd 1, no extra trailing newline - each instruction line already ends
;; in `\n`). Because `*` is the right child of `+`, the multiplication is emitted
;; (with its own push/pop) BEFORE the addition combines, so a later assemble+run
;; of this text computes `1 + (2 * 3)` = 7. `main` returns 0 (clean exit); the
;; observable result of this program is the PRINTED assembly, asserted exactly by
;; the Linux-gated stdout test.
(define (main) : i64
  (begin
    (print-string
     (emit-expr (EAdd (ENum 1) (EMul (ENum 2) (ENum 3)))))
    0))
