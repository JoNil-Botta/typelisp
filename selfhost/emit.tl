;; emit.tl - Milestone 1 self-hosting code emitter + program driver.
;;
;; This is the backend half of the first self-hosted compiler slice (#155). It
;; lowers a tiny arithmetic Expr AST to x86_64 text using a stack discipline:
;; every expression leaves its result in %rax; a binary expression pushes the
;; left result, emits the right, moves it to %rcx, restores the left result, and
;; emits the operator instruction.
;;
;; #156 productizes that instruction sequence into a COMPLETE runnable `.s`:
;; `emit-program` wraps `emit-expr`'s body in the same `main` + `_start` skeleton
;; the legacy backend emitted. The body leaves the computed value in %rax, `main`
;; returns it, and `_start` exits with that value - so the printed `.s`, when
;; assembled (`as`) + linked (`ld`) + run, EXITS 7 for `(+ 1 (* 2 3))`.
(import "../stdlib/io.tl")

(import "emit_core.tl")

(define (sample) : Expr
  (EBin (OpAdd) (EInt 1) (EBin (OpMul) (EInt 2) (EInt 3))))

;; main: emit and PRINT the COMPLETE runnable `.s` for the sample `(+ 1 (* 2 3))`.
;; The Linux-gated integration test assembles and links this printed text, then
;; runs it and asserts exit status 7.
(define (main) : unit
  (print-string (emit-program (sample))))