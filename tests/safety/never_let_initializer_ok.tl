;; A diverging initializer is an exit: its binding is initialized on no path
;; that reaches the binding's scope, and the bindings and body after it never
;; run, as the forms after a diverging one in a `begin`. Each function binds a
;; diverging initializer: a never call (alone, or followed by another form), a
;; later binding of several, an `if` or a `match` whose arms all diverge, a
;; `with` binding, `return` and `break`. Only the `return` and `break`
;; initializers run here.
(import stdlib.io)

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct Token
  (id i64)
  (name String))

(defenum Mode
  (Quiet)
  (Loud i64))

(define (side) : unit
  unit)

(define (consume [t : Token]) : i64
  t.id)

(define (never-call) : bool
  (let
    [ok : bool (io.panic "boom")]
    ok))

(define (never-call-then-form) : bool
  (let
    [ok : bool (io.panic "boom")]
    (side)
    ok))

(define (later-binding [x : i64]) : i64
  (let
    [a : i64 (+ x 1)]
    [ok : bool (io.panic "later")]
    [c : i64 (+ a 2)]
    (if ok
      c
      a)))

(define (if-arms [x : i64]) : bool
  (let
    [ok : bool
      (if (> x 0)
        (io.panic "positive")
        (io.panic "not positive"))]
    ok))

(define (match-arms [mode : Mode]) : bool
  (let
    [ok : bool
      (match mode
        [(Mode.Quiet) (io.panic "quiet")]
        [(Mode.Loud _) (io.panic "loud")])]
    ok))

;; The owner is never initialized, so no cleanup runs for it.
(define (with-binding [x : i64]) : i64
  (with ([h (io.panic "no handle") cleanup-handle]) (+ h.fd x)))

;; A `return` initializer leaves through the scope of the earlier owner, whose
;; cleanup runs once on that exit; the never-initialized owner has none.
(define (with-return [x : i64]) : i64
  (with
    ([g (Handle 1) cleanup-handle] [h (return x) cleanup-handle])
    (+ g.fd h.fd)))

;; What follows the exit is typed but carries no ownership effect, as after a
;; diverging form in a `begin` (`mir_unreachable_tail_ok`).
(define (dead-tail [t : Token]) : i64
  (let
    [ok : bool (io.panic "boom")]
    [a : i64 (consume t)]
    (if ok
      (+ a (consume t))
      a)))

(define (return-initializer [x : i64]) : i64
  (let
    [early : i64 (return (+ x 1))]
    (* early 100)))

(define (break-initializer [limit : i64]) : i64
  (let
    [n : i64 0]
    (while (< n limit)
      (let
        [step : i64 (break)]
        (set! n (+ n step))))
    n))

(define (select [mode : i64]) : i64
  (if (= mode 0)
    (if (never-call)
      1
      0)
    (if (= mode 1)
      (if (never-call-then-form)
        1
        0)
      (if (= mode 2)
        (later-binding 0)
        (if (= mode 3)
          (if (if-arms 0)
            1
            0)
          (if (= mode 4)
            (if (match-arms (Mode.Quiet))
              1
              0)
            (if (= mode 5)
              (with-binding 0)
              (if (= mode 6)
                (dead-tail (Token 1 "t"))
                (+
                  (return-initializer 1)
                  (break-initializer 10)
                  (with-return 0)
                  (* closes 40))))))))))

(define (main) : i64
  (select 7))