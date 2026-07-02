(import "stdlib/io.tl")

;; FORCING TEST for GAP5 (post-emission dead frame-store sweep).
;;
;; A call/syscall result is stored to its dst-home frame slot unconditionally
;; by the backend. When EVERY read of that slot is register-forwarded from
;; %rax by the owner-map text peephole (or the value flows straight to the
;; return in %rax), the store becomes an ORPHANED frame write -- a
;; `movq %rax, N(%rsp)` whose slot is never read anywhere in the function.
;; This is invisible to IR-level deadness (the store's IR use existed until
;; the peephole rewrote its reads to a register), so only a post-emission
;; per-function sweep of never-read local frame stores removes it.
;;
;; `grab` issues a raw syscall (getpid = 39, no args, no side effect we read),
;; stores %rax to a frame slot, and returns it. The never-taken self-recursion
;; blocks the leaf inliner AND tail-call optimization so the named function's
;; body survives for the gate to inspect. target/dead-store-sweep-gate.sh
;; asserts grab's body contains ZERO `movq %rax, N(%rsp)` frame stores (FAILS
;; on the pre-GAP5 compiler, which emits the orphaned store -- proven forcing).
;;
;; `relay` forwards the previous call's result straight into a tail call (arg
;; register), a second peephole-orphaned-store shape (the dst-home store's
;; only read is forwarded to %rdi). `keep` sums both so neither is DCE'd.

(define (grab [seed : i64]) : i64
  (if (< seed -999999)
    (grab (- seed 1))
    (unsafe
      (syscall 39))))

(define (echo-id [x : i64]) : i64
  (if (< x -999999) (echo-id (- x 1)) x))

(define (relay [seed : i64]) : i64
  (echo-id (grab seed)))

(define (main) : i64
  (let
    [a : i64 (grab 0)]
    [b : i64 (relay 0)]
    ;; getpid returns the same positive pid for both; require > 0 so the
    ;; result is exercised but the exact value is not pinned.
    (if (and (> a 0) (> b 0)) 42 1)))
