;; #2386 regression guards for register-group values at three call/merge
;; boundaries that miscompiled (word1 dropped or compared away):
;; - a 16-byte struct returned through a trivial-phi match merge (the
;;   [Phi; Return] fast path emitted only word0 without the program index);
;; - a 16-byte struct passed to an indirect closure call (vars=0 made the
;;   stack-homed group arg read word0 for both words);
;; - `=` on two 16-byte enums (the scalar compare looked at word0/tag only).
(defstruct Pair
  (x i64)
  (y i64))

(defenum Cond
  (CondA)
  (CondB))

(defenum E16
  (EA i64)
  (EB i64))

(define (pick [c : Cond] [p : Pair] [q : Pair]) : Pair
  (match c
    [(CondA) p]
    [(CondB) q]))

(define (pick-address-taken [c : Cond] [p : Pair] [q : Pair]) : Pair
  (match c
    [(CondA) p]
    [(CondB) q]))

(define (apply-fn [f : (-> Pair i64)] [p : Pair]) : i64
  (f p))

(define (apply-pick
  [f : (-> Cond Pair Pair Pair)]
  [c : Cond]
  [p : Pair]
  [q : Pair]) : Pair
  (f c p q))

(define (main) : i64
  (+
    (struct-get (pick (CondA) (Pair 1 2) (Pair 3 4)) y)
    (+
      (struct-get
        (apply-pick pick-address-taken (CondB) (Pair 99 100) (Pair 0 0))
        y)
      (+
        (apply-fn
          (lambda ([p : Pair]) : i64
            (struct-get p y))
          (Pair 5 9))
        (if (= (EA 1) (EA 2))
          100
          31)))))