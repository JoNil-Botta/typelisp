;# benchmarks/intern_table/bench.tl - the compiler's interner hash/probe path.
;#
;# Equivalent to benchmarks/intern_table/baseline.c. The kernel is extracted
;# from src/compiler_intern.tl, the interner the `intern.slice_misses` /
;# `intern.slice_hits` compile-profile rows instrument, and the input is the
;# REAL identifier stream: benchmarks/intern_table/data/idents.txt holds every
;# `Token.Sym` lexeme that src/lex.tl produces for src/lex.tl,
;# src/compiler_liveness.tl, src/compiler_symbols.tl and src/compiler_lower.tl,
;# one per line, in encounter order, exported by
;# benchmarks/intern_table/tools/export_idents.py. Encounter order carries the
;# distribution that matters: the real first-occurrence-miss / repeat-hit ratio,
;# the real length distribution, and the real collision families the compiler's
;# dashed naming produces.
;#
;# What it mirrors, function for function:
;#   `intern-hash-words`  the hash itself: `h = 5381 + len`, then one 64-bit
;#     little-endian word at a time `h = (h ^ word) * -7046029254386353131`,
;#     then the sub-word tail accumulated as `tail = tail * 256 + byte`, a final
;#     `h = (h ^ tail) * -7046029254386353131`, and the finalizer
;#     `h = h ^ (logical-shift-right h 29)`. The compiler loads each word with
;#     one raw `(ptr-read (ptr-cast ... (Ptr i64)))`; both implementations here
;#     spell that load as an explicit little-endian byte composition instead, so
;#     neither side gets an unsafe pointer path the other lacks. The hash values
;#     are identical on a little-endian host.
;#   `intern-bucket`  `hash & (capacity - 1)`, capacity a power of two.
;#   `intern-slice`  the probe loop reached from `intern-source-slice`, which is
;#     the lexer's entry: probe from the bucket, stop on an empty slot (miss) or
;#     on a slot whose stored hash equals and whose stored bytes compare equal
;#     (hit), otherwise step linearly, bounded by `steps < capacity`.
;#   `intern-string-slice-eq?`  the byte-for-byte compare of a pool name against
;#     a source slice, including its `(and (< i len) ok)` loop shape.
;#   `intern-id-slot-encode` / `intern-id-slot-empty?`  the compact id lane that
;#     reserves zero for "empty" and stores `id + 1`.
;#   `intern-persistent-substring`  the slice storage: a miss is the only case
;#     that copies bytes, and it copies them into a persistent name pool that
;#     later probes compare against. A hit allocates nothing.
;#   `intern-map-insert-existing-from` / `intern-map-insert-existing!` /
;#     `intern-map-rebuild-prefix`  insertion probing, and rehash-all, which the
;#     compiler performs by recomputing `intern-hash` for every live id.
;#   `intern-structural-table-intern` / `intern-structural-table-grow-map!`  the
;#     growth rule: when `(count + 1) * 4 >= capacity * 3` the map doubles and
;#     every existing id is reinserted. (The compiler's string map is instead
;#     preallocated at a fixed `intern-capacity` of 131072; this benchmark keeps
;#     the preallocated storage but takes the load-factor doubling from the
;#     structural table, so growth is actually exercised. Doubling is a logical
;#     capacity change plus a clear plus a rehash-all: the same work, minus one
;#     allocation.)
;#   `intern-reset!`  each round clears the map and the pool and starts over,
;#     which is what the driver does per compile.
;#
;# A round is one compile: pass A interns the whole stream into a fresh table,
;# so it sees the corpus's real miss-then-hit mix and drives the table through
;# its growth steps; pass B re-interns the same stream against the now-populated
;# table, which is the hit-dominated re-read of symbols later frontend phases
;# perform. Every assigned id folds into a wrapping 64-bit accumulator. The
;# corpus path and round count are runtime arguments, so nothing can be constant
;# folded, and all arithmetic wraps modulo 2^64 in both languages, so the
;# printed decimal matches the C baseline's `%lld`.
(module intern_table_kernel)

(import stdlib.string)
(import stdlib.vector)
(import (vector.vector u8) as u8vec)
(import (vector.vector i64) as i64vec)

(define (it-i64-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (it-i64-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(define (it-u8-ref [items : (& items u8vec.Vec)] [index : i64]) : u8
  (array-ref (u8vec.slots items) index))

(define (it-u8-set! [items : (&mut items u8vec.Vec)] [index : i64] [value : u8]) : unit
  (set! (array-ref (u8vec.slots-mut items) index) value))

(define (it-string-to-u8-vec [source : String]) : u8vec.Vec
  (let
    [n : i64 (string.string-length source)]
    [out : u8vec.Vec (u8vec.Vec (__tl_make-array u8 n) n)]
    [slots (u8vec.slots-mut (&mut out))]
    [src : (Ptr u8)
      (unsafe
        (string-data (& source)))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            (array-ref slots i)
            (unsafe
              (ptr-read (ptr-offset src i))))
          (set! i (+ i 1))))
      out)))

(define (it-zero-i64-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (it-zero-u8-vec [n : i64]) : u8vec.Vec
  (u8vec.Vec (__tl_make-array u8 n) n))

(define (it-u8-len [items : (& items u8vec.Vec)]) : i64
  (u8vec.len items))

;; `intern-hash-words`'s multiplier, 0x9E3779B97F4A7C15 as a signed i64.
(define it-hash-multiplier : i64
  -7046029254386353131)

;; Initial map capacity. A power of two, so `intern-bucket` stays a mask.
(define it-initial-capacity : i64
  1024)

;; Indexes into the mutable table-state cell.
(define it-state-capacity : i64
  0)
(define it-state-count : i64
  1)
(define it-state-name-cursor : i64
  2)

(define (it-load-word [src : (& src u8vec.Vec)] [at : i64]) : i64
  (let
    [slots (u8vec.slots src)]
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set!
            word
            (bit-or (shl word 8) (cast (array-ref slots (+ at b)) : i64)))
          (set! b (- b 1))))
      word)))

(define (it-hash-words [src : (& src u8vec.Vec)] [start : i64] [len : i64]) : i64
  (let
    [slots (u8vec.slots src)]
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    [tail : i64 0]
    (begin
      (while (< i words)
        (begin
          (set!
            h
            (* (bit-xor h (it-load-word src (+ start i))) it-hash-multiplier))
          (set! i (+ i 8))))
      (while (< i len)
        (begin
          (set!
            tail
            (+ (* tail 256) (cast (array-ref slots (+ start i)) : i64)))
          (set! i (+ i 1))))
      (set! h (* (bit-xor h tail) it-hash-multiplier))
      (bit-xor h (cast (shr (cast h : u64) 29) : i64)))))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (it-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;; `intern-string-slice-eq?`: compare a pool name against a source slice.
(define (it-slice-eq?
  [names : (& names u8vec.Vec)]
  [name-start : i64]
  [name-length : i64]
  [text : (& text u8vec.Vec)]
  [start : i64]
  [len : i64]) : bool
  (if (= name-length len)
    (let
      [name-slots (u8vec.slots names)]
      [text-slots (u8vec.slots text)]
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and (< i len) ok)
          (begin
            (if (=
              (array-ref name-slots (+ name-start i))
              (array-ref text-slots (+ start i)))
              unit
              (set! ok false))
            (set! i (+ i 1))))
        ok))
    false))

;; `intern-map-insert-existing-from`: probe forward from `cursor` for the first
;; empty id lane and claim it. The id lane stores `id + 1`, so zero is empty.
(define (it-map-insert-from
  [map-ids : (&mut map-ids i64vec.Vec)]
  [map-hashes : (&mut map-hashes i64vec.Vec)]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [capacity : i64]) : unit
  (let
    [id-slots (i64vec.slots-mut map-ids)]
    [hash-slots (i64vec.slots-mut map-hashes)]
    [slot : i64 cursor]
    [probes : i64 0]
    [placed : bool false]
    (begin
      (while (and (< probes capacity) (not placed))
        (if (= (array-ref id-slots slot) 0)
          (begin
            (set! (array-ref id-slots slot) (+ id 1))
            (set! (array-ref hash-slots slot) hash)
            (set! placed true))
          (begin
            (set! slot (it-bucket (+ slot 1) capacity))
            (set! probes (+ probes 1)))))
      unit)))

;; `intern-map-rebuild-prefix` + `intern-map-insert-existing!`: after doubling,
;; every live id is rehashed from its pool name and reinserted.
(define (it-grow!
  [map-ids : (&mut map-ids i64vec.Vec)]
  [map-hashes : (&mut map-hashes i64vec.Vec)]
  [names : (& names u8vec.Vec)]
  [name-off : (& name-off i64vec.Vec)]
  [name-len : (& name-len i64vec.Vec)]
  [state : (&mut state i64vec.Vec)]) : unit
  (let
    [capacity : i64 (* (it-i64-ref state it-state-capacity) 2)]
    [count : i64 (it-i64-ref state it-state-count)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (it-i64-set! map-ids i 0)
          (set! i (+ i 1))))
      (it-i64-set! state it-state-capacity capacity)
      (set! i 0)
      (while (< i count)
        (let
          [hash : i64
            (it-hash-words
              names
              (it-i64-ref name-off i)
              (it-i64-ref name-len i))]
          (begin
            (it-map-insert-from
              map-ids
              map-hashes
              i
              hash
              (it-bucket hash capacity)
              capacity)
            (set! i (+ i 1)))))
      unit)))

;; `intern-slice`, the path `intern-source-slice` calls once per lexed symbol.
(define (it-intern-slice
  [text : (& text u8vec.Vec)]
  [start : i64]
  [len : i64]
  [map-ids : (&mut map-ids i64vec.Vec)]
  [map-hashes : (&mut map-hashes i64vec.Vec)]
  [names : (&mut names u8vec.Vec)]
  [name-off : (&mut name-off i64vec.Vec)]
  [name-len : (&mut name-len i64vec.Vec)]
  [state : (&mut state i64vec.Vec)]) : i64
  (let
    [capacity : i64 (it-i64-ref state it-state-capacity)]
    [hash : i64 (it-hash-words text start len)]
    [cursor : i64 (it-bucket hash capacity)]
    [steps : i64 0]
    [out : i64 -1]
    [done : bool false]
    (begin
      (while (if done
        false
        (< steps capacity))
        (let
          [stored : i64 (it-i64-ref map-ids cursor)]
          (if (= stored 0)
            (let
              [count : i64 (it-i64-ref state it-state-count)]
              [name-cursor : i64 (it-i64-ref state it-state-name-cursor)]
              [i : i64 0]
              (begin
                ;; Miss: copy the slice into the persistent name pool, take the
                ;; next source id, then place it. Growth happens first so the
                ;; placement probe already runs at the final capacity.
                (while (< i len)
                  (begin
                    (it-u8-set!
                      names
                      (+ name-cursor i)
                      (it-u8-ref text (+ start i)))
                    (set! i (+ i 1))))
                (it-i64-set! name-off count name-cursor)
                (it-i64-set! name-len count len)
                (it-i64-set! state it-state-name-cursor (+ name-cursor len))
                (if (>= (* (+ count 1) 4) (* capacity 3))
                  (begin
                    (it-grow! map-ids map-hashes names name-off name-len state)
                    (set! capacity (it-i64-ref state it-state-capacity))
                    (set! cursor (it-bucket hash capacity)))
                  unit)
                (it-i64-set! state it-state-count (+ count 1))
                (it-map-insert-from
                  map-ids
                  map-hashes
                  count
                  hash
                  cursor
                  capacity)
                (set! out count)
                (set! done true)))
            (let
              [source-id : i64 (- stored 1)]
              (if (and
                (= (it-i64-ref map-hashes cursor) hash)
                (it-slice-eq?
                  names
                  (it-i64-ref name-off source-id)
                  (it-i64-ref name-len source-id)
                  text
                  start
                  len))
                (begin
                  (set! out source-id)
                  (set! done true))
                (begin
                  (set! cursor (it-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))))))
      out)))

;; `intern-reset!`: clear the dedup table and the pool for a fresh compile. The
;; compiler clears its whole fixed map; the analogue here is the capacity the
;; previous round grew to.
(define (it-reset!
  [map-ids : (&mut map-ids i64vec.Vec)]
  [state : (&mut state i64vec.Vec)]) : unit
  (let
    [capacity : i64 (it-i64-ref state it-state-capacity)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (it-i64-set! map-ids i 0)
          (set! i (+ i 1))))
      (it-i64-set! state it-state-capacity it-initial-capacity)
      (it-i64-set! state it-state-count 0)
      (it-i64-set! state it-state-name-cursor 0)
      unit)))

;; Index the newline-separated corpus into (start, length) slices without
;; copying: `intern-slice` takes a source buffer plus a range, exactly as the
;; lexer hands it the source text plus the token's extent.
(define (it-count-lines [text : (& text u8vec.Vec)] [n : i64]) : i64
  (let
    [text-slots (u8vec.slots text)]
    [i : i64 0]
    [lines : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (= (cast (array-ref text-slots i) : i64) 10)
            (set! lines (+ lines 1)))
          (set! i (+ i 1))))
      lines)))

(define (it-index-lines
  [text : (& text u8vec.Vec)]
  [n : i64]
  [starts : (&mut starts i64vec.Vec)]
  [lengths : (&mut lengths i64vec.Vec)]) : i64
  (let
    [text-slots (u8vec.slots text)]
    [start-slots (i64vec.slots-mut starts)]
    [length-slots (i64vec.slots-mut lengths)]
    [i : i64 0]
    [start : i64 0]
    [lines : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (= (cast (array-ref text-slots i) : i64) 10)
            (begin
              (set! (array-ref start-slots lines) start)
              (set! (array-ref length-slots lines) (- i start))
              (set! lines (+ lines 1))
              (set! start (+ i 1))))
          (set! i (+ i 1))))
      lines)))

;; Preallocated map storage. Doubling stops as soon as
;; `(count + 1) * 4 < capacity * 3`, so the capacity can never exceed
;; `8 * (distinct + 1) / 3`, and there are never more distinct names than lines.
(define (it-map-storage [lines : i64]) : i64
  (let
    [capacity : i64 it-initial-capacity]
    (begin
      (while (< capacity (* lines 3))
        (set! capacity (* capacity 2)))
      capacity)))