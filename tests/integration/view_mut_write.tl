;; A view read through `&mut` references only is a mutable view: it shares the
;; referent's storage, so every write through it (box contents, a field,
;; `replace!`, a `&mut` loan, a view of it, a copy of it) lands in the caller's
;; value.
(import stdlib.string)

(defstruct In
  (b (Box String))
  (n i64))

(defstruct Mid
  (i In)
  (k i64))

(defstruct Out
  (s In)
  (m Mid)
  (t i64))

(define (bump-in [q : (&mut q In)]) : unit
  (set! q.n (+ q.n 1)))

(define (look [p : (& p Out)]) : i64
  p.t)

(define (write-all [p : (&mut p Out)]) : i64
  (let
    [v p.s]
    (set! (deref v.b) "first")
    (set! v.n 10)
    (bump-in (&mut v))
    (let
      [old : (Box String) (replace! v.b (box "second"))]
      (string.string-length (& (deref old))))))

(define (write-nested [p : (&mut p Out)]) : unit
  (let
    [v p.m]
    [u v.i]
    (set! u.n (+ u.n 17))
    (set! (deref u.b) "nested")
    (set! v.k (+ v.k 26))))

(define (write-copy [p : (&mut p Out)]) : unit
  (let
    [v p.s]
    [w v]
    (set! w.n (+ w.n 5))))

(define (write-loop [p : (&mut p Out)] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (let
        [v p.s]
        (set! v.n (+ v.n 1)))
      (set! index (+ index 1)))))

(define (write-then-read [p : (&mut p Out)]) : i64
  (let
    [v p.s]
    (set! v.n (+ v.n 81))
    (look p)))

(define (main) : i64
  (let
    [o : Out (Out (In (box "a") 1) (Mid (In (box "c") 3) 4) 5)]
    [old-length : i64 (write-all (&mut o))]
    [_nested : unit (write-nested (&mut o))]
    [_copy : unit (write-copy (&mut o))]
    [_loop : unit (write-loop (&mut o) 3)]
    [seen : i64 (write-then-read (&mut o))]
    (if (and
      (= old-length 5)
      (string.eq (deref o.s.b) "second")
      (= o.s.n 100)
      (= o.m.i.n 20)
      (string.eq (deref o.m.i.b) "nested")
      (= o.m.k 30)
      (= seen 5))
      42
      1)))