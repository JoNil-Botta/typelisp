(import "stdlib/io.tl")

;; FORCING TEST for GAP3c: the param ABI-pin gate is PER-INTERVAL, not
;; function-global.
;;
;; * `dead-early` (apply_op shape, call variant): params a/b are fully consumed
;;   BEFORE the first clobber point (the recursive bump call), so both keep
;;   their incoming %rdi/%rsi even though the function contains a real call.
;;   Pre-GAP3c any clobber point anywhere revoked ALL pins: a/b were copied to
;;   callee-saved registers at entry.
;; * `div-arm` (apply_op shape, div variant): a div bans only pins it is
;;   SPANNED by. a/b are last-used AT the `%` (read before %rax:%rdx are
;;   clobbered) and op (%rdx) dies at the dispatch before the div arm, so all
;;   three keep their pins even though the function contains a div -- the
;;   audit's apply_op case, where the function-global gate revoked everything.
;;
;; target/param-interval-gate.sh asserts both shapes and FAILS on the
;; pre-GAP3c compiler at the entry-copy check. bump is recursive so it is
;; never inlined (the call must survive as dead-early's clobber point); the
;; never-taken poke branches take dead-early/div-arm addresses so no inline
;; path may absorb them into main.

(define (bump [x : i64]) : i64
  (if (<= x 0) 1 (+ 1 (bump (- x 1)))))

(define (dead-early [a : i64] [b : i64]) : i64
  (let
    [t : i64 (* (+ a b) 3)]
    (+ t (bump t))))

(define (div-arm [a : i64] [b : i64] [op : i64]) : i64
  (cond
    [(= op 0) (+ a b)]
    [(= op 1) (- a b)]
    [else (% a b)]))

;; Never executed; take addresses so neither function can be inlined.
(define (poke2 [f : (-> i64 i64 i64)] [a : i64] [b : i64]) : i64
  (f a b))
(define (poke3 [f : (-> i64 i64 i64 i64)] [a : i64] [b : i64] [c : i64]) : i64
  (f a b c))

(define (main) : i64
  (let
    ;; no CLI args: arg-count = 1 (program name), so a = 5, b = 4.
    [a : i64 (+ (arg-count) 4)]
    [b : i64 (+ (arg-count) 3)]
    (begin
      (if (> b 100)
        (begin
          (poke2 dead-early a b)
          (poke3 div-arm a b 0)
          unit)
        unit)
      ;; dead-early(5,4): t = 27, bump(27) = 28 -> 55
      (unless (= (dead-early a b) 55) (return 1))
      ;; div-arm(5,4,0) = 9; (5,4,1) = 1; (5,4,2) = 5%4 = 1
      (unless (= (div-arm a b 0) 9) (return 2))
      (unless (= (div-arm a b 1) 1) (return 3))
      (unless (= (div-arm a b 2) 1) (return 4))
      42)))
