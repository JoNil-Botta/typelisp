;; SW-1 runtime coverage for the general shrink-wrap placement: the prologue is
;; emitted at the dominator of the frame's uses, and every return the placement
;; bypasses is a bare `ret` -- no callee-saved pops, no `add rsp`.
;;
;; A wrong pop count or a stray `add rsp` on ANY path corrupts the caller's
;; callee-saved registers or the return address, so each shape below is called
;; on both sides of its guard and the caller checks a value it kept in a
;; callee-saved register across the call. The guard reads a mutable global, so
;; the entry test is a load and a compare -- the shape form (a) cannot admit --
;; and the optimizer cannot fold the branch away.
(import stdlib.io)

(define sw-armed : i64
  0)
(define sw-calls : i64
  0)

(define (sw-sink [x : i64]) : i64
  (begin
    (set! sw-calls (+ sw-calls 1))
    (+ x 1)))

;; Four values live across four calls after the save point: the plan homes them
;; in callee-saved registers, so the framed path pops and the bypass must not.
(define (sw-cold-body [a : i64] [b : i64] [c : i64]) : i64
  (if (= sw-armed 0)
    (+ a 100)
    (let
      [p : i64 (sw-sink a)]
      [q : i64 (sw-sink b)]
      [r : i64 (sw-sink c)]
      [s : i64 (sw-sink (+ a b))]
      (+ p (+ q (+ r s))))))

;; Recursion: the bypass returns before the frame exists on every level, and the
;; recursive path returns through the full epilogue on every level.
(define (sw-recurse [n : i64]) : i64
  (if (= sw-armed 0)
    (- 0 1)
    (if (<= n 0)
      0
      (+ (sw-sink n) (sw-recurse (- n 1))))))

;; A tail self-call after the save point. The tail arm has to tear the frame
;; down before the jump while the bypass never built one.
(define (sw-tail-loop [n : i64] [acc : i64]) : i64
  (if (= sw-armed 0)
    acc
    (if (<= n 0)
      acc
      (sw-tail-loop (- n 1) (+ acc (sw-sink n))))))

;; A second guard behind the first, so form (a) admits the first exit and the
;; general placement has to sink the prologue past the second.
(define (sw-two-exit [k : i64]) : i64
  (if (< k 0)
    0
    (if (>= k sw-armed)
      0
      (+ (sw-sink k) (sw-sink (+ k 1))))))

(define keep-cold : (-> i64 i64 i64 i64)
  sw-cold-body)
(define keep-recurse : (-> i64 i64)
  sw-recurse)
(define keep-tail : (-> i64 i64 i64)
  sw-tail-loop)
(define keep-two-exit : (-> i64 i64)
  sw-two-exit)

;; `witness` stays live across each call, so a callee that pops the wrong number
;; of registers is observed here rather than only at the final return.
(define (sw-probe [witness : i64]) : i64
  (let
    [a : i64 (sw-cold-body 1 2 3)]
    [w1 : i64 (+ witness 0)]
    [b : i64 (sw-recurse 4)]
    [w2 : i64 (+ w1 0)]
    [c : i64 (sw-tail-loop 4 0)]
    [w3 : i64 (+ w2 0)]
    [d : i64 (sw-two-exit 2)]
    (+ (+ a (+ b (+ c d))) (* w3 1000))))

(define (main) : i64
  (begin
    (io.print-format "{}\n" (sw-probe 7))
    (set! sw-armed 3)
    (io.print-format "{}\n" (sw-probe 7))
    (io.print-format "{}\n" sw-calls)
    42))