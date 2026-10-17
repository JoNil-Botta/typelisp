;; A call whose result becomes a field of this function's own result may build
;; that result in place: the optimizer hands the callee the field as its result
;; slot (`slot_fwd`). Each case pins a shape of that forwarding.
(import stdlib.io)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defstruct Pair
  (first Triple)
  (second Triple))

(defenum Checked
  (Ok Triple)
  (Err i64))

(defstruct Holder
  (tag i64)
  (inner Checked))

(define (bump [t : Triple]) : Triple
  (Triple (+ t.a 1) (+ t.b 10) (+ t.c 100)))

(define (check [t : Triple]) : Checked
  (if (< t.a 0)
    (Checked.Err t.a)
    (Checked.Ok t)))

(define (try-bump [t : Triple]) : Checked
  (let
    [u : Triple (try (check t))]
    (Checked.Ok (bump u))))

;; The variant tag is stored between the call and the payload copy.
(define (wrap-ok [t : Triple]) : Checked
  (Checked.Ok (bump t)))

;; Two forwarded fields: each window holds the other call or copy.
(define (swap-bump [p : Pair]) : Pair
  (Pair (bump p.second) (bump p.first)))

;; The callee may leave through `try`; it still fills the slot it was given.
(define (hold [t : Triple]) : Holder
  (Holder 7 (try-bump t)))

(define (wrap-ok-case) : i64
  (match (wrap-ok (Triple 1 2 3))
    [(Checked.Ok t) (+ t.a t.b t.c)]
    [(Checked.Err _) 0]))

(define (swap-bump-case) : i64
  (let
    [p : Pair (swap-bump (Pair (Triple 1 2 3) (Triple 4 5 6)))]
    (+ (* 1000 p.first.a) (* 100 p.second.a) (* 10 p.first.b) p.second.c)))

(define (hold-case) : i64
  (let
    [ok : Holder (hold (Triple 1 2 3))]
    [err : Holder (hold (Triple (- 0 4) 0 0))]
    (+
      ok.tag
      (match ok.inner
        [(Checked.Ok t) (+ t.a t.b t.c)]
        [(Checked.Err _) 0])
      (match err.inner
        [(Checked.Ok _) 0]
        [(Checked.Err e) (* (- 0 1000) e)]))))

;; Repeated calls reuse one caller slot; each fills it completely.
(define (loop-case) : i64
  (let
    [sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i 3)
        (begin
          (match (hold (Triple (- i 1) i i))
            [(Holder tag inner)
              (match inner
                [(Checked.Ok t) (set! sum (+ sum tag t.a))]
                [(Checked.Err e) (set! sum (- sum (* 100 e)))])])
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [results : i64
      (+
        (if (= (wrap-ok-case) 117)
          1
          0)
        (if (= (swap-bump-case) 5453)
          2
          0)
        (if (= (hold-case) 4124)
          4
          0)
        (if (= (loop-case) 117)
          8
          0))]
    (begin
      (io.print-format "{}\n" results)
      (if (= results 15)
        42
        results))))