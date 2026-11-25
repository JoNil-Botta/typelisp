;; Owner module for the owner-side equality/hash rejection cases (#7034,
;; #7049, #8103, #8183): a plain struct and an `(:opaque)` one with owner hooks.
(module owner_eq_hash_dep)

(import stdlib.eq)
(import stdlib.hash)

(defstruct Point
  (x i64))

(defstruct Token
  (:opaque)
  (id i64))

(eq.gen Token)

(hash.gen Token)