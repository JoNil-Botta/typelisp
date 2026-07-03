(import "stdlib/io.tl")

;; Forces arg-register SWAP/cycle marshalling. A caller passes its own params to
;; the callee in swapped (2-cycle), rotated (3-cycle), and fully reversed
;; (6-arg, three 2-cycles across all GP arg regs incl. %r8/%r9) order, so the
;; call must produce %rdi<-arg_j, %rsi<-arg_i etc. where each source is another
;; arg's destination register. A naive sequential marshalling clobbers a source
;; before it is read and miscompiles the callee's inputs; a sound parallel move
;; (cycle break via a scratch) preserves them. The 6-arg case specifically
;; covers positions 4-5 (%r8/%r9), exercised only when SysV eligibility extends
;; past 4 args.
;;
;; Values come from (arg-count) so the optimizer cannot constant-fold the calls
;; away and must emit the real call + marshalling. This passes both before the
;; register-eligibility change (args marshalled from memory) and after (args
;; marshalled from registers through the parallel-move solver) -- a regression
;; guard on argument-value correctness.
(define (swap2-callee [x : i64] [y : i64]) : i64
  (- x y))

(define (swap2-caller [a : i64] [b : i64]) : i64
  (swap2-callee b a))

(define (swap3-callee [x : i64] [y : i64] [z : i64]) : i64
  (+ (* x 100) (+ (* y 10) z)))

(define (swap3-caller [a : i64] [b : i64] [c : i64]) : i64
  (swap3-callee c a b))

(define (rev6-callee
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : i64
  (+ (* a 100000) (+ (* b 10000) (+ (* c 1000) (+ (* d 100) (+ (* e 10) f))))))

(define (rev6-caller
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : i64
  (rev6-callee f e d c b a))

;; Cycle + non-cycle TAIL: p/q form a 2-cycle while w/x/u are computed,
;; register-homed tail args. Their register sources lie OUTSIDE the cycle and
;; must survive the cycle break. The old hardcoded `movq src,%r11` break could
;; clobber a %r11-homed tail source (a non-cycle blocked `argreg<-%r11` still
;; pending); the scavenged temp excludes every source/dest so it cannot.
(define (ct5-callee [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
  (+ (* a 10000) (+ (* b 1000) (+ (* c 100) (+ (* d 10) e)))))

(define (ct5-caller [p : i64] [q : i64]) : i64
  (let
    [w : i64 (+ (* p 3) q)]
    [x : i64 (+ (* q 3) p)]
    [u : i64 (+ w x)]
    (ct5-callee q p w x u)))

(define (main) : i64
  (let
    [n : i64 (arg-count)]
    [r2 : i64 (swap2-caller (* n 50) (* n 8))]
    [r3 : i64 (swap3-caller (* n 1) (* n 2) (* n 3))]
    [r6 : i64 (rev6-caller (* n 1) (* n 2) (* n 3) (* n 4) (* n 5) (* n 6))]
    [rc : i64 (ct5-caller (* n 2) (* n 1))]
    (if (and (= r2 (- 0 42)) (and (= r3 312) (and (= r6 654321) (= rc 12762))))
      42
      1)))