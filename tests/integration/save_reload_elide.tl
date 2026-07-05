;; FORCING TEST for SCAV3 (redundant same-block save/reload elision via precise
;; owner-map single-dest recognition).
;;
;; The owner-map reload-elision peephole tracks, per GP register, the stack slot
;; it currently mirrors, and drops/rewrites a `movq SLOT, %rX` reload when a
;; register already holds SLOT. Before SCAV3, a 32/16/8-bit-width move
;; (`xorl %r8d,%r8d`, `movl $c,%reg`, `movb`, `set<cc>`) was NOT recognized as a
;; single-dest instruction, so it CLEARED THE WHOLE owner map -- discarding an
;; unrelated register's slot mirror and forcing a redundant reload.
;;
;; `relay` reproduces the exact compiler shape (compiler_symbols
;; add_module_aliases): a call result (`v`, in %rax) is stored to a home slot
;; while the next (7-arg) call's args are marshalled under register pressure; the
;; 5th arg `0` emits `xorl %r8d,%r8d`; the 6th arg is `v`. Pre-SCAV3 the xorl
;; wipes the owner map so `v` is reloaded `movq SLOT, %r9`; with precise
;; single-dest recognition the xorl clears only %r8, `%rax` still mirrors the
;; slot, and the reload becomes a reg-reg move / the now-dead store is swept.
;; Never-taken self-recursion blocks inlining + TCO so the named bodies survive
;; for the gate to inspect (target/save-reload-gate.sh; FAILS pre-SCAV3).
;; 7-ary sink so there is a stack arg (7th) and register pressure during
;; marshalling: arg5=0 -> xorl %r8d, arg6=v -> %r9.
(define (sink7
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : i64
  (if (< a -999999)
    (sink7 (- a 1) b c d e f g)
    (+ a (+ b (+ c (+ d (+ e (+ f g))))))))

;; produces the value that becomes the 6th arg (a call result, so it is spilled).
(define (src [x : i64]) : i64
  (if (< x -999999)
    (src (- x 1))
    (+ (* x 7) 3)))

(define (relay [p : i64] [q : i64] [r : i64] [s : i64] [t : i64] [w : i64]) : i64
  (if (< p -999999)
    (relay (- p 1) q r s t w)
    (let
      [v : i64 (src p)]
      (sink7 p q r s 0 v t))))

(define (main) : i64
  (let
    [out : i64 (relay 1 2 3 4 5 6)]
    (if (> out 0)
      42
      1)))