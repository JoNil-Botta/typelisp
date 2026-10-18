;; A nullary variant holds no reference, so in a body that binds a name spelled
;; like a caller lifetime it still takes any lifetime: returned as the caller's,
;; stored into caller storage, or bound under a same-spelled local's.
(defenum Next
  (:lifetimes a)
  (Done)
  (Item (& a i64)))

(defstruct Holder
  (:lifetimes a)
  (next (Next a)))

(define (pick [a : i64] [p : (& a i64)]) : (Next a)
  (if (> a 0)
    (Next.Item p)
    (Next.Done)))

(define (reset [a : i64] [h : (&mut a (Holder a))]) : unit
  (set! h.next (Next.Done)))

(define (local-done [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [n : (Next a) (Next.Done)]
    a))

(define (main) : i64
  0)