(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(defstruct Narrow
  (x u8)
  (y u8)
  (guard u8))

(defenum State
  (Ready i64))

(defenum Signal
  (Ready i64))

(define state : Wide
  (Wide 257 66051 131585))
(define narrow-state : Narrow
  (Narrow 17 23 41))

;; lint-allow: global-name-case -- a value and enum share their root spelling.
(define State : Wide
  (Wide 257 66051 131585))

(defmacro (replace-y!) : Expr
  `(cast (replace! state.y 11) : i64))

(defmacro (replace-narrow-y!) : Expr
  `(cast (replace! narrow-state.y 11) : i64))

(defmacro (replace-enum-named-y!) : Expr
  `(replace! State.y 11))

(defmacro (shared-enum-variant) : Expr
  `(State.Ready 42))

(defmacro (enum-variant) : Expr
  `(Signal.Ready 42))

(define (control!) : i64
  (replace-y!))

(define (narrow-control!) : i64
  (replace-narrow-y!))

(define (shadow! [state : Narrow]) : i64
  (unless (= state.y 23) (return 1))
  (replace-y!))

(define (wide-shadow! [narrow-state : Wide]) : i64
  (unless (= narrow-state.y 2000) (return 1))
  (replace-narrow-y!))

(define (scalar-shadow! [state : i64]) : i64
  (unless (= state 17) (return 1))
  (replace-y!))

(define (enum-shadow) : i64
  (let
    ;; lint-allow: local-name-case -- caller value must not become an enum root.
    [Signal : Narrow (Narrow 17 23 41)]
    (unless (= Signal.y 23) (return 1))
    (match (enum-variant)
      [(Signal.Ready n) n])))

(define (main) : i64
  (unless (= (control!) 66051) (return 1))
  (unless (= state.y 11) (return 2))
  (unless (= (narrow-control!) 23) (return 3))
  (unless (= narrow-state.y 11) (return 4))
  (set! state.y 66051)
  (unless (= (shadow! (Narrow 17 23 41)) 66051) (return 5))
  (unless (= state.y 11) (return 6))
  (set! narrow-state.y 23)
  (unless (= (wide-shadow! (Wide 1000 2000 3000)) 23) (return 7))
  (unless (= narrow-state.y 11) (return 8))
  (set! state.y 66051)
  (unless (= (scalar-shadow! 17) 66051) (return 9))
  (unless (= state.y 11) (return 10))
  (unless (= state.x 257) (return 11))
  (unless (= state.guard 131585) (return 12))
  (unless (= narrow-state.x 17) (return 13))
  (unless (= narrow-state.guard 41) (return 14))
  (unless (= (replace-enum-named-y!) 66051) (return 15))
  (unless (= State.y 11) (return 16))
  (unless (= State.x 257) (return 17))
  (unless (= State.guard 131585) (return 18))
  (unless
    (=
      (match (shared-enum-variant)
        [(State.Ready n) n])
      42)
    (return 19))
  (unless
    (=
      (match (enum-variant)
        [(Signal.Ready n) n])
      42)
    (return 20))
  (unless (= (enum-shadow) 42) (return 21))
  42)