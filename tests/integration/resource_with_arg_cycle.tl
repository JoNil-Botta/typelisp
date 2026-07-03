; Forcing fixture for the tail-call argument parallel-move cycle-break fix.
;
; `lower-emit-cleanup-stack` tail-calls `lower-emit-cleanup-stack-at`, which
; returns a large struct via an sret pointer passed as the LAST argument. The
; caller forwards its own sret pointer (%rcx) into the callee's sret register
; (%r9), which -- together with the two Array-field args -- forms a register
; cycle. The pre-fix cycle-break temp picker could pick an already-placed arg
; destination (%rdx) as the scratch, clobbering an argument; the compiler then
; miscompiled its OWN `with`-lowering so that ANY `with`-resource program failed
; to compile ("lower: missing resource cleanup binding").
;
; This program exercises a multi-binding `with` (a cleanup stack of 3), so the
; compiled compiler must walk the cleanup stack correctly. It is runtime-
; observable: the cleanups must run in reverse binding order with the right
; values, so `trace` ends at 357753 and main returns 42.

(define resource-arg-cycle-trace : i64
  0)

(define (resource-arg-cycle-init [digit : i64]) : i64
  (begin
    (set!
      resource-arg-cycle-trace
      (+ (* resource-arg-cycle-trace 10) digit))
    digit))

(define (resource-arg-cycle-cleanup [digit : i64]) : unit
  (set!
    resource-arg-cycle-trace
    (+ (* resource-arg-cycle-trace 10) digit)))

(define (main) : i64
  (begin
    (with
      ([a (resource-arg-cycle-init 3) resource-arg-cycle-cleanup]
        [b (resource-arg-cycle-init 5) resource-arg-cycle-cleanup]
        [c (resource-arg-cycle-init 7) resource-arg-cycle-cleanup])
      unit)
    ; init:    3 -> 35 -> 357
    ; cleanup: 7 -> 5 -> 3  => 3577 -> 35775 -> 357753
    (if (= resource-arg-cycle-trace 357753)
      42
      1)))
