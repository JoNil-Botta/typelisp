;; A `let` binding of an inline aggregate owns its storage. The lowering may
;; adopt storage that its own initializer reserved (a constructor or call
;; result) instead of copying it, but must copy whenever the initializer's
;; value can still be reached through another binding, global, or branch.
(import stdlib.io)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defstruct Outer
  (inner Triple)
  (tag i64))

(define global-triple : Triple
  (Triple 1 2 3))

(define (make [n : i64]) : Triple
  (Triple n (+ n 1) (+ n 2)))

;; Binding another local copies it.
(define (local-copy-case) : i64
  (let
    [t : Triple (Triple 1 2 3)]
    [u : Triple t]
    (begin
      (set! t.a 10)
      u.a)))

;; Binding a projection copies it.
(define (projection-case) : i64
  (let
    [o : Outer (Outer (Triple 4 5 6) 0)]
    [i : Triple o.inner]
    (begin
      (set! o.inner.a 99)
      i.a)))

;; A binding returned out of a nested scope is no longer reachable by name.
(define (nested-case) : i64
  (let
    [x : Triple
      (let
        [t : Triple (Triple 5 6 7)]
        t)]
    [y : Triple
      (let
        [t : Triple (Triple 50 60 70)]
        t)]
    (begin
      (set! x.a (+ x.a 1))
      (+ x.a y.a))))

;; Each iteration re-initializes the binding; the saved copy is unaffected.
(define (loop-case) : i64
  (let
    [prev : Triple (Triple 0 0 0)]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i 3)
        (let
          [cur : Triple (Triple i i i)]
          (begin
            (set! sum (+ sum prev.a))
            (set! prev cur)
            (set! i (+ i 1)))))
      (+ (* 10 prev.a) sum))))

;; Two call results have distinct homes.
(define (call-case) : i64
  (let
    [x : Triple (make 7)]
    [y : Triple (make 8)]
    (begin
      (set! x.a 70)
      (+ x.a y.a))))

;; A branch may yield an existing local, so the join is copied.
(define (branch-case [pick-local : bool]) : i64
  (let
    [t : Triple (Triple 1 1 1)]
    [x : Triple
      (if pick-local
        t
        (Triple 2 2 2))]
    (begin
      (set! t.a 100)
      x.a)))

;; A global keeps its own home.
(define (global-case) : i64
  (let
    [x : Triple global-triple]
    (begin
      (set! global-triple (Triple 9 9 9))
      x.a)))

;; A binding written later cannot share the storage it was bound from.
(define (alias-write-case) : i64
  (let
    [t : Triple (Triple 1 2 3)]
    [u : Triple t]
    (begin
      (set! u.a 10)
      (+ (* 100 t.a) u.a))))

;; Rebinding an unwritten parameter and writing the new binding.
(define (param-rebind [p : Triple]) : i64
  (let
    [q : Triple p]
    (begin
      (set! q.b 5)
      (+ (* 100 p.b) q.b))))

(define (rotate [t : Triple]) : Triple
  (Triple t.b t.c t.a))

;; `set!` of a call result that reads the target.
(define (set-from-call-case) : i64
  (let
    [t : Triple (Triple 1 2 3)]
    (begin
      (set! t (rotate t))
      (set! t t)
      (+ (* 100 t.a) (* 10 t.b) t.c))))

;; `set!` from a call result may rebind the binding to the result's storage,
;; but not inside a loop: the next iteration would pass that same storage as
;; both the argument and the result slot. `swap-bump` stores `first` before it
;; copies `p.first`, so such aliasing would corrupt the result.
(defstruct Pair2
  (first Triple)
  (second Triple))

(define (bump [t : Triple]) : Triple
  (Triple (+ t.a 1) t.b t.c))

(define (swap-bump [p : Pair2]) : Pair2
  (Pair2 (bump p.second) p.first))

(define (loop-assign-case) : i64
  (let
    [p : Pair2 (Pair2 (Triple 1 0 0) (Triple 10 0 0))]
    [i : i64 0]
    (begin
      (while (< i 2)
        (begin
          (set! p (swap-bump p))
          (set! i (+ i 1))))
      (+ (* 100 p.first.a) p.second.a))))

(define (straight-assign-case) : i64
  (let
    [p : Pair2 (Pair2 (Triple 1 0 0) (Triple 10 0 0))]
    (begin
      (set! p (swap-bump p))
      (set! p (swap-bump p))
      (+ (* 100 p.first.a) p.second.a))))

;; Rebinding sites outside the loop and copying sites inside it, on one binding.
(define (mixed-assign-case) : i64
  (let
    [p : Pair2 (Pair2 (Triple 1 0 0) (Triple 10 0 0))]
    [i : i64 0]
    (begin
      (set! p (swap-bump p))
      (while (< i 2)
        (begin
          (set! p (swap-bump p))
          (set! i (+ i 1))))
      (set! p (swap-bump p))
      (+ (* 100 p.first.a) p.second.a))))

;; A macro-hygienic binder that is written cannot share the storage it was
;; bound from; its write is tracked under its own structural identity.
(defmacro (with-overwritten-copy [x : Expr] [body : Expr]) : Expr
  `(let
    [tmp ,x]
    (begin
      (set! tmp (Triple 99 0 0))
      (+ ,body tmp.a))))

(define (hygienic-write-case) : i64
  (let
    [t : Triple (Triple 1 2 3)]
    (with-overwritten-copy t t.a)))

;; Returning a call result may hand the callee this function's own result
;; slot; that callee may return early, and its arguments may be places.
(define (pick-early [flag : bool] [t : Triple]) : Triple
  (begin
    (when flag (return (Triple 7 8 9)))
    t))

(define (forward-pick [flag : bool] [t : Triple]) : Triple
  (pick-early flag t))

(define (forward-swap [p : Pair2]) : Pair2
  (swap-bump p))

(define (forwarded-return-case) : i64
  (let
    [a : Triple (forward-pick true (Triple 1 2 3))]
    [b : Triple (forward-pick false (Triple 4 5 6))]
    [p : Pair2 (forward-swap (Pair2 (Triple 1 0 0) (Triple 10 0 0)))]
    (+ (* 1000 a.a) (* 100 b.a) (* 10 p.first.a) p.second.a)))

;; A forwarded result slot is not always filled: a `try` early exit in the
;; callee returns its `Err` in fresh heap storage, so the forwarding function
;; must return the callee's pointer. The loop reuses the caller's slot, so a
;; stale `Ok` from the first iteration would be read back on the second.
(defenum Checked
  (Ok Triple)
  (Err i64))

(define (check-positive [t : Triple]) : Checked
  (if (< t.a 0)
    (Checked.Err t.a)
    (Checked.Ok t)))

(define (try-bump [t : Triple]) : Checked
  (let
    [u : Triple (try (check-positive t))]
    (Checked.Ok (Triple u.a (+ u.b 1) u.c))))

(define (forward-try [n : i64]) : Checked
  (try-bump (Triple n n n)))

(define (forwarded-try-case) : i64
  (let
    [score : i64 0]
    [i : i64 0]
    (begin
      (while (< i 2)
        (begin
          (match (forward-try
            (if (= i 0)
              4
              (- 0 5)))
            [(Checked.Ok t) (set! score (+ score t.b))]
            [(Checked.Err e) (set! score (- score (* 100 e)))])
          (set! i (+ i 1))))
      score)))

;; A boxed call result is built directly in the new box; the callee's `try`
;; early exit writes its `Err` there as well.
(define (boxed-call-case) : i64
  (let
    [ok : (Box Checked) (box (try-bump (Triple 4 4 4)))]
    [err : (Box Checked) (box (try-bump (Triple (- 0 7) 0 0)))]
    (+
      (match (deref ok)
        [(Checked.Ok t) t.b]
        [(Checked.Err _) 0])
      (match (deref err)
        [(Checked.Ok _) 0]
        [(Checked.Err e) (* (- 0 100) e)]))))

;; Recursive activations have separate homes.
(define (recursive-case [n : i64]) : i64
  (let
    [x : Triple (make n)]
    (if (= n 0)
      x.a
      (+ (recursive-case (- n 1)) x.a))))

(define (main) : i64
  (let
    [results : i64
      (+
        (if (= (local-copy-case) 1)
          1
          0)
        (if (= (projection-case) 4)
          2
          0)
        (if (= (nested-case) 56)
          4
          0)
        (if (= (loop-case) 21)
          8
          0)
        (if (= (call-case) 78)
          16
          0)
        (if (= (branch-case true) 1)
          32
          0)
        (if (= (branch-case false) 2)
          64
          0)
        (if (= (global-case) 1)
          128
          0)
        (if (= (recursive-case 3) 6)
          256
          0)
        (if (= (alias-write-case) 110)
          512
          0)
        (if (= (param-rebind (Triple 1 2 3)) 205)
          1024
          0)
        (if (= (set-from-call-case) 231)
          2048
          0)
        (if (= (loop-assign-case) 211)
          4096
          0)
        (if (= (straight-assign-case) 211)
          8192
          0)
        (if (= (mixed-assign-case) 312)
          16384
          0)
        (if (= (hygienic-write-case) 100)
          32768
          0)
        (if (= (forwarded-return-case) 7511)
          65536
          0)
        (if (= (forwarded-try-case) 505)
          131072
          0)
        (if (= (boxed-call-case) 705)
          262144
          0))]
    (begin
      (io.print-format "{}\n" results)
      (if (= results 524287)
        42
        results))))