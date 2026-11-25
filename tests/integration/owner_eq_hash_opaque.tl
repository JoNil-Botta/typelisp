;; Owner-side equality and hashing for an `(:opaque)` type used outside its
;; module family (#8103, #8183). This module compares and hashes borrowed
;; tokens through the owner's `eq-token`/`hash-token` hooks, directly and via
;; the `(eq.eq T)`/`(hash.hash T)` adapters, and keys a HashMap and a Set by the
;; owner's sealed `TokenKey` handle, whose hooks delegate to the token's. Every
;; handle hashes to one bucket, so lookups confirm through owner equality.
;; Exits 42, or the number of the failed check.
(import stdlib.eq)
(import stdlib.hash)
(import stdlib.hashmap)
(import stdlib.set)
(import owner_eq_hash_token as owner)
(import (eq.eq owner.Token) as token_eq)
(import (hash.hash owner.Token) as token_hash)
(import (hashmap.hashmap owner.TokenKey i64) as key_map)
(import (set.set owner.TokenKey) as key_set)

;: Compare and hash tokens lent by the owner: ONE and ONE-AGAIN are equal
;: tokens at distinct addresses, TWO differs.
(define (check-tokens
  [one : (& one owner.Token)]
  [one-again : (& one-again owner.Token)]
  [two : (& two owner.Token)]) : bool
  (and
    (owner.eq-token one one-again)
    (not (owner.eq-token one two))
    (token_eq.eq one one-again)
    (not (token_eq.eq? one two))
    (= (owner.hash-token one) (owner.hash-token one-again))
    (= (token_hash.hash one) (owner.hash-token one-again))
    (!= (token_hash.hash one) (token_hash.hash two))))

(define (map-ok?) : bool
  (let
    [m : key_map.Map (key_map.with-capacity 2)]
    (key_map.insert! m (owner.token-key 0) 10)
    (key_map.insert! m (owner.token-key 1) 20)
    (key_map.insert! m (owner.token-key 3) 30)
    (key_map.insert! m (owner.token-key 2) 11)
    (let
      [found-one : i64
        (key_map.lookup-value-or (key_map.get (& m) (owner.token-key 0)) -1)]
      [found-three : i64
        (key_map.lookup-value-or (key_map.get (& m) (owner.token-key 3)) -1)]
      [len-before : i64 (key_map.len (& m))]
      (key_map.remove! m (owner.token-key 1))
      (and
        (= len-before 3)
        (= found-one 11)
        (= found-three 30)
        (= (key_map.len (& m)) 2)
        (not (key_map.contains? (& m) (owner.token-key 1)))
        (key_map.contains? (& m) (owner.token-key 2))))))

(define (set-ok?) : bool
  (let
    [s : key_set.Set (key_set.with-capacity 2)]
    [one-again : owner.TokenKey (owner.token-key 2)]
    [two : owner.TokenKey (owner.token-key 1)]
    (key_set.insert! s (owner.token-key 0))
    (key_set.insert! s (owner.token-key 1))
    (key_set.insert! s (owner.token-key 2))
    (key_set.insert! s (owner.token-key 3))
    (let
      [len-before : i64 (key_set.len (& s))]
      (key_set.remove-borrowed! s (& two))
      (and
        (= len-before 3)
        (key_set.contains-borrowed? (& s) (& one-again))
        (key_set.contains? (& s) (owner.token-key 3))
        (not (key_set.contains-borrowed? (& s) (& two)))
        (= (key_set.len (& s)) 2)))))

(define (main) : i64
  (cond
    [(not (owner.check-pool check-tokens)) 1]
    [(not (map-ok?)) 2]
    [(not (set-ok?)) 3]
    [else 42]))