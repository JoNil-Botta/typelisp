(import stdlib.io)

;; SCAV1 forcing fixture -- the argument parallel-move CYCLE-BREAK temp.
;;
;; A caller passes its own (register-homed) params to a callee in a permutation
;; that maps each arg register onto another arg register's value, so the
;; marshalling is a true cycle (%rdi<-arg_j, %rsi<-arg_i, ...) with no unblocked
;; move. The backend breaks the cycle by stashing one source in a temp. When the
;; occupancy-checked scavenge finds a free scratch it uses a register; when it
;; finds NONE (saturation) it must fall back to a SOUND swap.
;;
;; The old fallback was a RAW `movq srcreg, %r11` -- neither occupancy-checked
;; nor save/restore-wrapped -- so a value homed in %r11 would be clobbered. The
;; fix breaks the cycle through a reserved frame temp instead, a register-free
;; swap that clobbers nothing. Building the compiler with `--cfg arg-cycle-stack`
;; forces that saturation path for every cycle break
;; (the natural path never reaches it: %r10/%r11 are caller-saved and never join
;; a gp-parallel arg cycle nor hold a call-survivor, so a free scratch always
;; exists). Run with such a compiler, this fixture asserts that the frame-temp
;; rotation is correct and still returns 42.
;;
;; Run normally (register-temp break) it is a runtime regression guard on
;; argument-cycle correctness. Values come from (io.arg-count) so the optimizer
;; cannot fold the calls away and must emit the real call + marshalling.
;; 2-cycle: %rdi<->%rsi.
(define (c2-callee [x : i64] [y : i64]) : i64
  (- (* x 10) y))

(define (c2-caller [a : i64] [b : i64]) : i64
  (c2-callee b a))

;; 3-cycle: %rdi<-%rsi, %rsi<-%rdx, %rdx<-%rdi.
(define (c3-callee [x : i64] [y : i64] [z : i64]) : i64
  (+ (* x 100) (+ (* y 10) z)))

(define (c3-caller [a : i64] [b : i64] [c : i64]) : i64
  (c3-callee b c a))

;; 6-cycle across all GP arg registers incl. %r8/%r9: rotate right one place, so
;; %rdi<-%r9, %r9<-%r8, %r8<-%rcx, %rcx<-%rdx, %rdx<-%rsi, %rsi<-%rdi -- a single
;; cycle touching every SysV arg register.
(define (c6-callee [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [f : i64]) : i64
  (+ a (+ (* b 2) (+ (* c 4) (+ (* d 8) (+ (* e 16) (* f 32)))))))

(define (c6-caller [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [f : i64]) : i64
  (c6-callee f a b c d e))

;; Cycle + non-cycle REGISTER-homed sources -- the exact SCAV1 hazard. p/q form a
;; 2-cycle while w/x/u are computed and register-homed; their sources lie OUTSIDE
;; the cycle and must survive the break. The old `movq src,%r11` break could
;; clobber a %r11-homed non-cycle source; the stack (and register) break excludes
;; every source/dest so it cannot.
(define (mix-callee [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
  (+ (* a 10000) (+ (* b 1000) (+ (* c 100) (+ (* d 10) e)))))

(define (mix-caller [p : i64] [q : i64]) : i64
  (let
    [w : i64 (+ (* p 3) q)]
    [x : i64 (+ (* q 3) p)]
    [u : i64 (+ w x)]
    (mix-callee q p w x u)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r2 : i64 (c2-caller (* n 3) (* n 7))]
    [r3 : i64 (c3-caller (* n 1) (* n 2) (* n 3))]
    [r6 : i64 (c6-caller (* n 1) (* n 2) (* n 3) (* n 4) (* n 5) (* n 6))]
    [rm : i64 (mix-caller (* n 2) (* n 1))]
    (if (and (= r2 67) (= r3 231) (= r6 264) (= rm 12762))
      42
      1)))