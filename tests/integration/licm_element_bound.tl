;; #7992: LICM may move an element load to a loop's preheader only where the
;; load's index is proven in bounds there. Every read below indexes with `wild`,
;; a value far past any array (argv 1 times 2^40, so no fold sees it), and the
;; source never performs that read: the pred loop runs zero times, the arm is
;; never taken, the string loop stops first. A hoisted copy of the read -- LICM
;; used to take all four -- would load from `data + wild * 8`, which is not
;; mapped, and fault where the program returns normally.
;;
;; The abort twin passes `take` = 1: `ebt-arm` now takes its arm on the first
;; trip, so the read happens, and it must stop at the bounds diagnostic of the
;; source's own check, not at a fault.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (vref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(defmacro (ebt-ref [items : Expr] [index : Expr]) : Expr
  `(vref (& ,items) ,index))

(define ebt-pred-off : i64vec.Vec
  (zero-vec 1))
(define ebt-pred-edge : i64vec.Vec
  (zero-vec 1))
(define ebt-reachable : i64vec.Vec
  (zero-vec 1))
(define ebt-tin : i64vec.Vec
  (zero-vec 1))
(define ebt-tout : i64vec.Vec
  (zero-vec 1))
(define ebt-nblocks : i64
  0)

(define (ebt-dominates? [dominator : i64] [label : i64]) : bool
  (if (and
    (= (ebt-ref ebt-reachable dominator) 1)
    (= (ebt-ref ebt-reachable label) 1))
    (and
      (>= (ebt-ref ebt-tin dominator) 0)
      (>= (ebt-ref ebt-tin label) 0)
      (<= (ebt-ref ebt-tin dominator) (ebt-ref ebt-tin label))
      (<= (ebt-ref ebt-tout label) (ebt-ref ebt-tout dominator)))
    false))

;; ssa_construct's dominance-frontier scan: `label` is read only inside the
;; inlined `ebt-dominates?`, inside the pred loop, which has no trips here.
(define (ebt-frontier [label : i64]) : i64
  (let
    [block : i64 0]
    [len : i64 0]
    (begin
      (while (< block ebt-nblocks)
        (begin
          (when
            (= (ebt-ref ebt-reachable block) 1)
            (let
              [edge : i64 (ebt-ref ebt-pred-off block)]
              [end : i64 (ebt-ref ebt-pred-off (+ block 1))]
              [found : bool false]
              (begin
                (while (and (< edge end) (not found))
                  (let
                    [pred : i64 (ebt-ref ebt-pred-edge edge)]
                    (begin
                      (when
                        (and
                          (= (ebt-ref ebt-reachable pred) 1)
                          (ebt-dominates? label pred))
                        (set! found true))
                      (set! edge (+ edge 1)))))
                (when found (set! len (+ len 1))))))
          (set! block (+ block 1))))
      len)))

;; The read sits in an arm the loop never takes unless `take` is set.
(define (ebt-arm [items : (__tl_dyn-array i64)] [k : i64] [take : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i 10)
        (begin
          (when (< i take) (set! sum (+ sum (array-ref items k))))
          (set! i (+ i 1))))
      sum)))

;; The same arm through a borrowed Vec, whose handle is reloaded per access.
(define (ebt-vec-arm [items : (& items i64vec.Vec)] [k : i64] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (> i 1000000)
            (set! sum (+ sum (array-ref (i64vec.slots items) k))))
          (set! i (+ i 1))))
      sum)))

;; A string byte behind a loop exit taken first.
(define (ebt-text [text : (& text str)] [k : i64] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (= i 1000000)
            (set! sum (+ sum (cast (string.string-ref text k) : i64))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [wild : i64 (* (string.>int (io.arg 1)) 1099511627776)]
    [take : i64 (string.>int (io.arg 2))]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [vec : i64vec.Vec (zero-vec 4)]
    [text : String "bound"]
    (begin
      ;; One reachable block with no predecessor edges.
      (set! ebt-nblocks 1)
      (set! ebt-reachable (zero-vec 1))
      (set! (array-ref (i64vec.slots-mut (&mut ebt-reachable)) 0) 1)
      (set! ebt-pred-off (zero-vec 2))
      (set! ebt-pred-edge (zero-vec 1))
      (set! ebt-tin (zero-vec 1))
      (set! ebt-tout (zero-vec 1))
      (io.print-format "{}\n" (ebt-frontier wild))
      (io.print-format "{}\n" (ebt-vec-arm (& vec) wild 10))
      (io.print-format "{}\n" (ebt-text (& text) wild 10))
      (io.print-format "{}\n" (ebt-arm items wild take))
      42)))