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

(import "tl_ast_types.tl")

;; --------------------------------------------------------------------------
;; The compile-time name->slot environment (#163).
;; --------------------------------------------------------------------------
;; `let` gives compiled programs the ability to NAME intermediate values. A
;; `(let ((x v)) body)` binds `x` to the value of `v` for the duration of
;; `body`. The emitter resolves each `x` to a fixed stack slot expressed as a
;; `%rbp`-relative byte offset, threading a compile-time environment - the
;; direct analogue of the interpreter's value `Env` (`tl_eval.tl:219-221`)
;; specialised to `i64` slot offsets. `CNil` is the empty scope; each
;; `(CBind name off rest)` extends `rest` with one name bound to slot `off`.
;; Lookup walks head-first so the innermost binding wins (lexical scoping).
(defenum CEnv
  (CNil)
  (CBind String i64 CEnv))

;; cenv-lookup: resolve a variable name to its `%rbp`-relative slot offset,
;; walking head-first so the most recent (innermost) binding wins. An unbound
;; name is a malformed program - abort via `panic`, exactly how the interpreter
;; `lookup` (tl_eval.tl:250-256) reports a free variable. The trailing `0`
;; gives the never-returning `panic` arm an `i64` so the function typechecks.
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

;; emit-bin: lower `a OP b` with the stack discipline - emit `a` (result in
;; %rax), push it BELOW the reserved slot region, emit `b`, move it to %rcx,
;; pop `a` back into %rax, and emit the operator. Both operands are emitted in
;; the SAME `env`/`depth`, so any `let` slot they reference is the one the
;; enclosing scope reserved. The `pushq`/`popq` is balanced and operates below
;; the fixed slot region, so %rsp returns to its post-prologue level before any
;; `let` store and the slots are never disturbed (#163).
(define (emit-bin [op : BinOp] [a : Expr] [b : Expr] [env : CEnv] [depth : i64]) : String
  (string-append (emit-expr a env depth)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr b env depth)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

;; emit-var: load a bound variable from its fixed `%rbp`-relative slot into %rax.
(define (emit-var [name : String] [env : CEnv]) : String
  (string-append "    movq -"
    (string-append (int->string (cenv-lookup env name))
      "(%rbp), %rax\n")))

;; emit-let: lower `(let ((name val)) body)`. `depth` is the number of slots
;; already reserved by enclosing lets, so this binding takes the NEXT slot,
;; `-8*(depth+1)(%rbp)`. Emit `val` (result in %rax), store it into that slot,
;; then emit `body` with the environment extended by `name->off` and `depth+1`.
;; Allocating by nesting depth (never reusing a slot while a binding is live)
;; guarantees correctness without a liveness pass; a nested `let` in `body`
;; takes the next deeper slot, so distinct bindings never collide.
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

;; --------------------------------------------------------------------------
;; Frame sizing: reserve the let-slot region ONCE in the prologue (#163).
;; --------------------------------------------------------------------------
;; let-depth: the maximum NESTING DEPTH of `let` in an expression - i.e. how
;; many distinct slots can be simultaneously live. Each `let` adds one to the
;; depth of its body; siblings (the two operands of a `EBin`) do not stack, so
;; the depth of a binary node is the MAX of its children, not their sum (a slot
;; freed when one operand finishes is reused by the other - but since we never
;; emit a store past the body, taking the max is the tight bound).
(define (max2 [a : i64] [b : i64]) : i64
  (if (> a b) a b))

(define (let-depth [e : Expr]) : i64
  (match e
    [(EInt _) 0]
    [(EVar _) 0]
    [(EBin _ a b) (max2 (let-depth a) (let-depth b))]
    [(ELet _ val body) (max2 (let-depth val) (+ 1 (let-depth body)))]
    [(ECall _ _) 0]))

;; round-up-16: round a byte count up to the next multiple of 16, keeping the
;; frame 16-byte aligned exactly as the Rust backend does
;; (`(stack_size + 15) & !15`, src/backend/mod.rs:1990).
(define (round-up-16 [n : i64]) : i64
  (* (/ (+ n 15) 16) 16))

;; emit-frame-reserve / emit-frame-restore: the `sub`/`add` that bracket the
;; let-slot region. When the program uses no `let` (K = 0) BOTH emit the empty
;; string, so the pure-arithmetic `.s` stays BYTE-IDENTICAL to the M1 golden
;; (no `sub $0` noise). When K > 0 the prologue subtracts K to drop %rsp below
;; the lowest slot, and the epilogue adds K back before `pop %rbp` restores %rbp.
(define (emit-frame-reserve [k : i64]) : String
  (if (= k 0)
      ""
      (string-append "    sub $" (string-append (int->string k) ", %rsp\n"))))

(define (emit-frame-restore [k : i64]) : String
  (if (= k 0)
      ""
      (string-append "    add $" (string-append (int->string k) ", %rsp\n"))))

;; emit-program: wrap the body asm in the complete backend-shaped `.s` skeleton.
;; `(-> Expr String)`. This mirrors the repository backend:
;;   .text / .globl main / .globl _start
;;   main: prologue, emitted body, epilogue, ret
;;   _start: call main, move %rax to the exit-status arg, exit syscall
;; Assembled + linked + run, this `.s` exits with the value the expression
;; computes (7 for `(+ 1 (* 2 3))`).
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

(define (sample) : Expr
  (EBin (OpAdd) (EInt 1) (EBin (OpMul) (EInt 2) (EInt 3))))

;; main: emit and PRINT the COMPLETE runnable `.s` for the sample `(+ 1 (* 2 3))`.
;; The Linux-gated integration test assembles and links this printed text, then
;; runs it and asserts exit status 7.
(define (main) : unit
  (print-string (emit-program (sample))))
