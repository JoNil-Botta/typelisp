;; A nullary variant, called or written bare, and a constructor lifetime no
;; argument fixes hold no reference, so in a body that binds a name spelled like
;; a caller lifetime they still take the caller's lifetime: returned, stored
;; into caller storage, or bound under a same-spelled local's.
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

(defenum Either
  (:lifetimes a b)
  (Left (& a i64))
  (Right (& b i64)))

(define (reset-bare [a : i64] [h : (&mut a (Holder a))]) : unit
  (set! h.next Next.Done))

(define (reset-unqualified [a : i64] [h : (&mut a (Holder a))]) : unit
  (set! h.next Done))

(define (none [a : i64] [p : (& a i64)]) : (Next a)
  Done)

(define (right-of [a : i64] [p : (& a i64)] [q : (& b i64)]) : (Either a b)
  (Either.Right q))

(define (main) : i64
  0)