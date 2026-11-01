;; Refs #9503, B2: an unused nominal argument does not own reference storage.
(import stdlib.arena)

(defstruct Phantom
  (:lifetimes p)
  (n i64))

(defstruct Nested
  (:lifetimes p)
  (value (Phantom p)))

(defenum PhantomEnum
  (:lifetimes p)
  (Value (Phantom p)))

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& a (Phantom r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (Phantom k)) x]
    (arena.destroy-safe! owner)
    (deref alias).n))

(define (nested
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& a (Nested r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (Nested k)) x]
    (arena.destroy-safe! owner)
    (deref alias).value.n))

(define (enum-control
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& a (PhantomEnum r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (PhantomEnum k)) x]
    (arena.destroy-safe! owner)
    (match (deref alias)
      [(Value p) p.n])))

;; These bodies are the parity controls: their reference lifetime a is
;; independent of r. A called variant can encounter main's unrelated E0205.
(define (main) : i64
  0)