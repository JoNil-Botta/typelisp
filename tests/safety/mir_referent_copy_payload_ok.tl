;; A Copy payload bound from a field behind a shared reference is copied
;; out; the arm's region-tagged view and the match's plain type agree.
(import stdlib.io)

(defstruct Context
  (base u64)
  (offset i64))

(defenum MaybeContext
  (None)
  (Some Context))

(defstruct State
  (active bool)
  (context MaybeContext))

(define (context-of [state : (& state State)]) : Context
  (match state.context
    [(MaybeContext.Some context) context]
    [(MaybeContext.None) (io.panic "no context")]))

(define (main) : i64
  (let
    [state : State (State true (MaybeContext.Some (Context 1 41)))]
    (+ 1 (context-of (& state)).offset)))