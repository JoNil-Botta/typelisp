;; Known conservative rejection (#9503; #9464, #9256): a nominal whose only
;; mention of the brand is a phantom (bivariant) lifetime keeps the arena
;; region, as main does for the unshortened read and for `(in r T)` parameters,
;; so a shortened copy read after the end is rejected though it holds no arena
;; storage.
(import stdlib.arena)

(defstruct Phantom
  (:lifetimes a)
  (n i64))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (Phantom r)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (Phantom k) x]
      (begin
        (arena.destroy-safe! owner)
        alias.n))))

(define (main) : i64
  0)