;; Writing box contents reached through a shared reference is rejected through
;; the `__tl-box-place` bridge exactly as through `deref`.
(defstruct Storage
  (count (Box i64)))

(defstruct State
  (storage (Box Storage)))

(define (bump [state : (& state State)]) : unit
  (set!
    (deref (__tl-project-field (__tl-box-place state.storage) count))
    (+ (deref (__tl-project-field (__tl-box-place state.storage) count)) 1)))

(define (main) : i64
  (let
    [state : State (State (box (Storage (box 41))))]
    (begin
      (bump (& state))
      (deref (__tl-project-field (__tl-box-place state.storage) count)))))