;; A generated hashmap built in a scratch arena and escaped with `clone` keeps
;; its exact layout after the scratch is destroyed (#8384): the same length,
;; capacity, tombstone count, slot iteration order and lookups. The optimizer's
;; program summaries escape their result tables this way.
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as imap)

;; The occupied slot indexes of `map`, in slot order, folded into one number.
(define (slot-order-hash [map : (& map imap.Map)]) : i64
  (let
    [capacity : i64 (imap.capacity map)]
    [index : i64 (imap.next-occupied map 0)]
    [hash : i64 7]
    (while (< index capacity)
      (set! hash (+ (* hash 31) index))
      (set! index (imap.next-occupied map (+ index 1))))
    hash))

(define (build) : imap.Map
  (let
    [map : imap.Map (imap.with-capacity 8)]
    [key : i64 0]
    (while (< key 20)
      (imap.insert-ref! (&mut map) (* key 97) (+ key 1000))
      (set! key (+ key 1)))
    ;; Two removals leave tombstones the copy must keep.
    (imap.remove-ref! (&mut map) (* 3 97))
    (imap.remove-ref! (&mut map) (* 11 97))
    map))

(define (lookups-ok? [map : (& map imap.Map)]) : bool
  (let
    [key : i64 0]
    [ok : bool true]
    (while (< key 20)
      (let
        [expected : i64
          (if (or (= key 3) (= key 11))
            -1
            (+ key 1000))]
        (if (= (imap.get-value-or map (* key 97) -1) expected)
          unit
          (set! ok false))
        (set! key (+ key 1))))
    ok))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [built : imap.Map (in-arena scratch (build))]
    [len : i64 (imap.len (& built))]
    [capacity : i64 (imap.capacity (& built))]
    [deleted : i64 (imap.deleted (& built))]
    [order : i64 (slot-order-hash (& built))]
    [copy : imap.Map (clone built)]
    [empty-scratch : arena.Arena (arena.make)]
    [empty : imap.Map (in-arena empty-scratch (imap.new))]
    [empty-copy : imap.Map (clone empty)]
    (arena.destroy-safe! scratch)
    (arena.destroy-safe! empty-scratch)
    (if (and
      (= len 18)
      (= (imap.len (& copy)) len)
      (= (imap.capacity (& copy)) capacity)
      (= (imap.deleted (& copy)) deleted)
      (> deleted 0)
      (= (slot-order-hash (& copy)) order)
      (lookups-ok? (& copy))
      (= (imap.len (& empty-copy)) 0)
      (= (imap.get-value-or (& empty-copy) 97 -1) -1))
      42
      1)))