;; Writes through a match on a `&mut` path stay accepted where every reference
;; on the path is mutable, and reads through a `&` payload stay accepted
;; (#9753): only a write through a `&` binder is rejected. `unsafe` only mints
;; the `program`-lifetime references the payloads hold.
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Mine
  (Some (&mut program Holder) (Box i64))
  (None))

(defenum Owned
  (Some Holder (Box i64))
  (None))

(defenum Shared
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (mine Mine)
  (owned Owned)
  (shared Shared))

(define (mint-shared [h : (& h Holder)]) : (& program Holder)
  (unsafe
    (ptr-read (ptr-cast (ptr-addr-of h) : (Ptr (& program Holder))))))

(define (mint-mut [h : (&mut h Holder)]) : (&mut program Holder)
  (unsafe
    (ptr-read (ptr-cast (ptr-addr-of h) : (Ptr (&mut program Holder))))))

;; A `&mut` payload through a `&mut` root writes its referent.
(define (write-mine [r : (&mut r Outer)]) : unit
  (match r.mine
    [(Mine.Some s _k) (set! (deref s.b) 20)]
    [(Mine.None) unit]))

;; An owned payload is a mutable view; so is a sibling of a `&` payload.
(define (write-owned [r : (&mut r Outer)]) : unit
  (match r.owned
    [(Owned.Some s k)
      (set! (deref s.b) 10)
      (set! (deref k) 5)]
    [(Owned.None) unit])
  (match r.shared
    [(Shared.Some _s k) (set! (deref k) 2)]
    [(Shared.None) unit]))

;; Reads through a `&` payload, directly and through a kept view.
(define (read-shared [r : (&mut r Outer)]) : i64
  (match r.shared
    [(Shared.Some s k)
      (let
        [v : (Box i64) s.b]
        (+ (+ (deref s.c) (deref v)) (deref k)))]
    [(Shared.None) 0]))

(define (owned-sum [o : (& o Outer)]) : i64
  (match o.owned
    [(Owned.Some s k) (+ (deref s.b) (deref k))]
    [(Owned.None) 0]))

(define (main) : i64
  (let
    [target : Holder (Holder (box 1) (box 0))]
    [read-only : Holder (Holder (box 2) (box 3))]
    [outer : Outer
      (Outer
        (Mine.Some (mint-mut (&mut target)) (box 0))
        (Owned.Some (Holder (box 0) (box 0)) (box 0))
        (Shared.Some (mint-shared (& read-only)) (box 0)))]
    (write-mine (&mut outer))
    (write-owned (&mut outer))
    ;; 20 + (10 + 5) + (3 + 2 + 2) = 42
    (+ (deref target.b) (+ (owned-sum (& outer)) (read-shared (&mut outer))))))