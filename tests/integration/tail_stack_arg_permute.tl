;; A direct tail call whose arguments overflow the registers into the caller's
;; incoming stack area, and whose register arguments are a permutation of the
;; caller's: `step` hands its first parameter on as `finish`'s fifth. Loading
;; the register prefix in argument order overwrites that first parameter's
;; register with `finish`'s first argument before it is moved out, so the
;; marshalling has to resolve the prefix as one parallel move (and store any
;; overflow argument read out of a register before that move).
(defstruct Seq
  (len i64)
  (start i64))

(defenum Res
  (Some Seq i64 i64)
  (None))

;; Every argument is weighted by its position, so a swapped or overwritten
;; argument changes the result.
(define (finish
  [block-label : i64]
  [head-label : i64]
  [seq-start : i64]
  [lead : (& Seq)]
  [instrs : (& Seq)]
  [index : (& Seq)]
  [census : (& Seq)]
  [func-name : i64]
  [vars : i64]
  [caller-blocks : i64]
  [added : i64]
  [scc : (& Seq)]
  [caller-scc : i64]
  [spans : (& Seq)]
  [weight : i64]) : Res
  (if (> instrs.len 0)
    (Some
      (Seq (+ lead.len block-label) (+ head-label (* 2 seq-start)))
      (+ (* 3 index.len) (+ (* 5 census.len) (+ (* 7 func-name) (* 11 vars))))
      (+
        (* 13 caller-blocks)
        (+
          (* 17 added)
          (+ (* 19 scc.len) (+ (* 23 caller-scc) (* weight spans.len))))))
    (None)))

;; Walks `pos` up to `count` (a self tail call the optimizer turns into a
;; loop), then tail-calls `finish` with its arguments permuted.
(define (step
  [instrs : (& Seq)]
  [pos : i64]
  [count : i64]
  [block-label : i64]
  [head-label : i64]
  [seq-start : i64]
  [lead : (& Seq)]
  [site-pos : i64]
  [index : (& Seq)]
  [census : (& Seq)]
  [func-name : i64]
  [vars : i64]
  [caller-blocks : i64]
  [added : i64]
  [scc : (& Seq)]
  [caller-scc : i64]
  [spans : (& Seq)]
  [weight : i64]) : Res
  (if (>= pos count)
    (finish
      block-label
      head-label
      seq-start
      lead
      instrs
      index
      census
      func-name
      vars
      caller-blocks
      added
      scc
      caller-scc
      spans
      weight)
    (step
      instrs
      (+ pos 1)
      count
      block-label
      head-label
      seq-start
      lead
      site-pos
      index
      census
      func-name
      vars
      caller-blocks
      added
      scc
      caller-scc
      spans
      weight)))

(define (main) : i64
  ;; Every argument is distinct, so an argument read from a register another
  ;; argument already overwrote changes the result.
  (let
    [instrs : Seq (Seq 3 0)]
    [lead : Seq (Seq 5 0)]
    [index : Seq (Seq 7 0)]
    [census : Seq (Seq 11 0)]
    [scc : Seq (Seq 13 0)]
    [spans : Seq (Seq 17 0)]
    (match (step
      (& instrs)
      0
      2
      1
      12
      3
      (& lead)
      10
      (& index)
      (& census)
      4
      5
      6
      7
      (& scc)
      8
      (& spans)
      9)
      ;; s = Seq 6 18; x = 21 + 55 + 28 + 55 = 159;
      ;; y = 78 + 119 + 247 + 184 + 153 = 781; 6 + 18 + 159 + 781 = 964.
      [(Some s x y) (- (+ (+ s.len s.start) (+ x y)) 922)]
      [(None) 1])))