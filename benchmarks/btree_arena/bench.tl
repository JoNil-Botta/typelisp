;# benchmarks/btree_arena/bench.tl - arena-backed order-16 B-tree workload.
;#
;# Equivalent to benchmarks/btree_arena/baseline.c. Pre-allocates a flat SoA
;# node arena for an order-16 B-tree (max 15 keys, 16 children per node) and
;# resets the arena pointer to 0 at the start of every round. Each round inserts
;# `inserts` deterministic keys using proactive child splitting (leaf and
;# internal splits), then runs `queries` mixed point lookups (hits + misses) and
;# recursive range scans `[lo, hi]`, folding query answers and the arena node
;# count into a wrapping 64-bit FNV-1a checksum. Insert count, query count, and
;# round count are runtime CLI arguments.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64 core) as i64vec)

(define bt-hash-basis : u64
  0xcbf29ce484222325)
(define bt-hash-prime : u64
  1099511628211)
(define bt-max-keys : i64
  15)
(define bt-mid : i64
  7)
(define bt-key-mask : u64
  1048575)

(defstruct TreeState
  (root i64)
  (node-count i64))

(define (bt-mix [h : u64] [v : u64]) : u64
  (* (bit-xor h v) bt-hash-prime))

(define (bt-splitmix [x : u64]) : u64
  (let
    [z : u64 (+ x 0x9e3779b97f4a7c15)]
    (set! z (* (bit-xor z (shr z 30)) 0xbf58476d1ce4e5b9))
    (set! z (* (bit-xor z (shr z 27)) 0x94d049bb133111eb))
    (bit-xor z (shr z 31))))

(define (bt-zero-vec [n : i64]) : i64vec.Vec
  (let
    [v : i64vec.Vec (i64vec.with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (i64vec.push! v 0)
      (set! i (+ i 1)))
    v))

(define (bt-alloc-node
  [st : (&mut st TreeState)]
  [nkeys : (&mut nkeys (Slice i64))]
  [leaf : (&mut leaf (Slice i64))]
  [is-leaf : i64]) : i64
  (let
    [id : i64 st.node-count]
    (set! st.node-count (+ id 1))
    (set! (array-ref nkeys id) 0)
    (set! (array-ref leaf id) is-leaf)
    id))

;; Binary search for first slot in `[0, n)` with `keys[base + slot] >= key`.
(define (bt-lower-bound
  [keys : (& keys (Slice i64))]
  [base : i64]
  [n : i64]
  [key : i64]) : i64
  (let
    [lo : i64 0]
    [hi : i64 n]
    (while (< lo hi)
      (let
        [mid : i64 (shr (+ lo hi) 1)]
        (if (< (array-ref keys (+ base mid)) key)
          (set! lo (+ mid 1))
          (set! hi mid))))
    lo))

(define (bt-lower-bound-mut
  [keys : (&mut keys (Slice i64))]
  [base : i64]
  [n : i64]
  [key : i64]) : i64
  (let
    [lo : i64 0]
    [hi : i64 n]
    (while (< lo hi)
      (let
        [mid : i64 (shr (+ lo hi) 1)]
        (if (< (array-ref keys (+ base mid)) key)
          (set! lo (+ mid 1))
          (set! hi mid))))
    lo))

(define (bt-split-child
  [st : (&mut st TreeState)]
  [nkeys : (&mut nkeys (Slice i64))]
  [leaf : (&mut leaf (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [children : (&mut children (Slice i64))]
  [parent : i64]
  [idx : i64]) : unit
  (let
    [p-base : i64 (shl parent 4)]
    [y : i64 (array-ref children (+ p-base idx))]
    [y-base : i64 (shl y 4)]
    [y-leaf : i64 (array-ref leaf y)]
    [z : i64 (bt-alloc-node st nkeys leaf y-leaf)]
    [z-base : i64 (shl z 4)]
    [pn : i64 (array-ref nkeys parent)]
    [j : i64 0]
    (while (< j bt-mid)
      (set! (array-ref keys (+ z-base j)) (array-ref keys (+ y-base (+ j 8))))
      (set! (array-ref vals (+ z-base j)) (array-ref vals (+ y-base (+ j 8))))
      (set! j (+ j 1)))
    (when
      (= y-leaf 0)
      (set! j 0)
      (while (<= j bt-mid)
        (set!
          (array-ref children (+ z-base j))
          (array-ref children (+ y-base (+ j 8))))
        (set! j (+ j 1))))
    (set! (array-ref nkeys z) bt-mid)
    (set! (array-ref nkeys y) bt-mid)
    (set! j pn)
    (while (> j idx)
      (set!
        (array-ref children (+ p-base (+ j 1)))
        (array-ref children (+ p-base j)))
      (set! j (- j 1)))
    (set! (array-ref children (+ p-base (+ idx 1))) z)
    (set! j (- pn 1))
    (while (>= j idx)
      (set! (array-ref keys (+ p-base (+ j 1))) (array-ref keys (+ p-base j)))
      (set! (array-ref vals (+ p-base (+ j 1))) (array-ref vals (+ p-base j)))
      (set! j (- j 1)))
    (set! (array-ref keys (+ p-base idx)) (array-ref keys (+ y-base bt-mid)))
    (set! (array-ref vals (+ p-base idx)) (array-ref vals (+ y-base bt-mid)))
    (set! (array-ref nkeys parent) (+ pn 1))))

(define (bt-insert
  [st : (&mut st TreeState)]
  [nkeys : (&mut nkeys (Slice i64))]
  [leaf : (&mut leaf (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [children : (&mut children (Slice i64))]
  [key : i64]
  [val : i64]) : unit
  (when
    (= (array-ref nkeys st.root) bt-max-keys)
    (let
      [old-root : i64 st.root]
      [new-root : i64 (bt-alloc-node st nkeys leaf 0)]
      (set! (array-ref children (shl new-root 4)) old-root)
      (set! st.root new-root)
      (bt-split-child st nkeys leaf keys vals children new-root 0)))
  (let
    [x : i64 st.root]
    [done : bool false]
    (while (not done)
      (let
        [x-base : i64 (shl x 4)]
        [n : i64 (array-ref nkeys x)]
        [pos : i64 (bt-lower-bound-mut keys x-base n key)]
        (if (and (< pos n) (= (array-ref keys (+ x-base pos)) key))
          (begin
            (set! (array-ref vals (+ x-base pos)) val)
            (set! done true))
          (if (= (array-ref leaf x) 1)
            (let
              [j : i64 (- n 1)]
              (while (>= j pos)
                (set!
                  (array-ref keys (+ x-base (+ j 1)))
                  (array-ref keys (+ x-base j)))
                (set!
                  (array-ref vals (+ x-base (+ j 1)))
                  (array-ref vals (+ x-base j)))
                (set! j (- j 1)))
              (set! (array-ref keys (+ x-base pos)) key)
              (set! (array-ref vals (+ x-base pos)) val)
              (set! (array-ref nkeys x) (+ n 1))
              (set! done true))
            (let
              [child : i64 (array-ref children (+ x-base pos))]
              (if (= (array-ref nkeys child) bt-max-keys)
                (begin
                  (bt-split-child st nkeys leaf keys vals children x pos)
                  (let
                    [pk : i64 (array-ref keys (+ x-base pos))]
                    (cond
                      [(= key pk)
                        (set! (array-ref vals (+ x-base pos)) val)
                        (set! done true)]
                      [(> key pk)
                        (set! x (array-ref children (+ x-base (+ pos 1))))]
                      [else (set! x (array-ref children (+ x-base pos)))])))
                (set! x child)))))))))

(define (bt-find
  [nkeys : (& nkeys (Slice i64))]
  [leaf : (& leaf (Slice i64))]
  [keys : (& keys (Slice i64))]
  [vals : (& vals (Slice i64))]
  [children : (& children (Slice i64))]
  [root : i64]
  [key : i64]) : i64
  (let
    [x : i64 root]
    [res : i64 -1]
    [done : bool false]
    (while (not done)
      (let
        [x-base : i64 (shl x 4)]
        [n : i64 (array-ref nkeys x)]
        [pos : i64 (bt-lower-bound keys x-base n key)]
        (if (and (< pos n) (= (array-ref keys (+ x-base pos)) key))
          (begin
            (set! res (array-ref vals (+ x-base pos)))
            (set! done true))
          (if (= (array-ref leaf x) 1)
            (set! done true)
            (set! x (array-ref children (+ x-base pos)))))))
    res))

(define (bt-range-scan
  [nkeys : (& nkeys (Slice i64))]
  [leaf : (& leaf (Slice i64))]
  [keys : (& keys (Slice i64))]
  [vals : (& vals (Slice i64))]
  [children : (& children (Slice i64))]
  [node : i64]
  [lo : i64]
  [hi : i64]
  [acc : u64]) : u64
  (let
    [base : i64 (shl node 4)]
    [n : i64 (array-ref nkeys node)]
    [is-leaf : i64 (array-ref leaf node)]
    [i : i64 (bt-lower-bound keys base n lo)]
    [h : u64 acc]
    [stopped : bool false]
    (while (and (< i n) (not stopped))
      (when
        (= is-leaf 0)
        (set!
          h
          (bt-range-scan
            nkeys
            leaf
            keys
            vals
            children
            (array-ref children (+ base i))
            lo
            hi
            h)))
      (let
        [k : i64 (array-ref keys (+ base i))]
        (if (> k hi)
          (set! stopped true)
          (begin
            (set! h (bt-mix h (cast k : u64)))
            (set! h (bt-mix h (cast (array-ref vals (+ base i)) : u64)))
            (set! i (+ i 1))))))
    (when
      (and (not stopped) (= is-leaf 0))
      (set!
        h
        (bt-range-scan
          nkeys
          leaf
          keys
          vals
          children
          (array-ref children (+ base n))
          lo
          hi
          h)))
    h))

(define (bt-bench [inserts : i64] [queries : i64] [rounds : i64]) : u64
  (let
    [max-nodes : i64 (+ inserts 64)]
    [nkeys-v : i64vec.Vec (bt-zero-vec max-nodes)]
    [leaf-v : i64vec.Vec (bt-zero-vec max-nodes)]
    [keys-v : i64vec.Vec (bt-zero-vec (shl max-nodes 4))]
    [vals-v : i64vec.Vec (bt-zero-vec (shl max-nodes 4))]
    [children-v : i64vec.Vec (bt-zero-vec (shl max-nodes 4))]
    [inserted-v : i64vec.Vec (bt-zero-vec inserts)]
    [rng : u64 0x243f6a8885a308d3]
    [acc : u64 bt-hash-basis]
    [round : i64 0]
    (while (< round rounds)
      (let
        [st : TreeState (TreeState 0 0)]
        (let
          [nkeys : (&mut nkeys-v (Slice i64)) (i64vec.view-mut (&mut nkeys-v))]
          [leaf : (&mut leaf-v (Slice i64)) (i64vec.view-mut (&mut leaf-v))]
          [keys : (&mut keys-v (Slice i64)) (i64vec.view-mut (&mut keys-v))]
          [vals : (&mut vals-v (Slice i64)) (i64vec.view-mut (&mut vals-v))]
          [children : (&mut children-v (Slice i64))
            (i64vec.view-mut (&mut children-v))]
          [inserted : (&mut inserted-v (Slice i64))
            (i64vec.view-mut (&mut inserted-v))]
          [i : i64 0]
          (set! st.root (bt-alloc-node (&mut st) nkeys leaf 1))
          (while (< i inserts)
            (set! rng (+ rng 0x9e3779b97f4a7c15))
            (let
              [k : i64 (cast (bit-and (bt-splitmix rng) bt-key-mask) : i64)]
              [v : i64 (+ (* k 3) round)]
              (set! (array-ref inserted i) k)
              (bt-insert (&mut st) nkeys leaf keys vals children k v))
            (set! i (+ i 1))))
        (let
          [nkeys-r : (& nkeys-v (Slice i64)) (i64vec.view (& nkeys-v))]
          [leaf-r : (& leaf-v (Slice i64)) (i64vec.view (& leaf-v))]
          [keys-r : (& keys-v (Slice i64)) (i64vec.view (& keys-v))]
          [vals-r : (& vals-v (Slice i64)) (i64vec.view (& vals-v))]
          [children-r : (& children-v (Slice i64)) (i64vec.view (& children-v))]
          [inserted-r : (& inserted-v (Slice i64)) (i64vec.view (& inserted-v))]
          [q : i64 0]
          (while (< q queries)
            (set! rng (+ rng 0x9e3779b97f4a7c15))
            (let
              [draw : u64 (bt-splitmix rng)]
              (if (= (bit-and q 3) 0)
                (let
                  [lo : i64 (cast (bit-and draw bt-key-mask) : i64)]
                  [hi : i64 (+ lo 4096)]
                  (set!
                    acc
                    (bt-range-scan
                      nkeys-r
                      leaf-r
                      keys-r
                      vals-r
                      children-r
                      st.root
                      lo
                      hi
                      acc)))
                (let
                  [target : i64
                    (if (= (bit-and q 1) 1)
                      (array-ref
                        inserted-r
                        (% (cast (bit-and draw 2147483647) : i64) inserts))
                      (cast (bit-and draw bt-key-mask) : i64))]
                  [found : i64
                    (bt-find
                      nkeys-r
                      leaf-r
                      keys-r
                      vals-r
                      children-r
                      st.root
                      target)]
                  (set! acc (bt-mix acc (cast found : u64))))))
            (set! q (+ q 1))))
        (set! acc (bt-mix acc (cast st.node-count : u64))))
      (set! round (+ round 1)))
    acc))

(define (main) : i64
  (let
    [inserts : i64 (string.>int (io.arg 1))]
    [queries : i64 (string.>int (io.arg 2))]
    [rounds : i64 (string.>int (io.arg 3))]
    (io.println "{}" (bt-bench inserts queries rounds))
    0))