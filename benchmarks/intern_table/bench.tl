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
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

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

;; `intern-hash-words`, with the compiler's raw 64-bit word load spelled as an
;; explicit little-endian composition of eight bytes.
(define (it-load-word [src : (Array u8)] [at : i64]) : i64
  (let
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set!
            word
            (bit-or (shl word 8) (cast (array-ref src (+ at b)) : i64)))
          (set! b (- b 1))))
      word)))

(define (it-hash-words [src : (Array u8)] [start : i64] [len : i64]) : i64
  (let
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
          (set! tail (+ (* tail 256) (cast (array-ref src (+ start i)) : i64)))
          (set! i (+ i 1))))
      (set! h (* (bit-xor h tail) it-hash-multiplier))
      (bit-xor h (cast (shr (cast h : u64) 29) : i64)))))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (it-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;; `intern-string-slice-eq?`: compare a pool name against a source slice.
(define (it-slice-eq?
  [names : (Array u8)]
  [name-start : i64]
  [name-length : i64]
  [text : (Array u8)]
  [start : i64]
  [len : i64]) : bool
  (if (= name-length len)
    (let
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and (< i len) ok)
          (begin
            (if (=
              (array-ref names (+ name-start i))
              (array-ref text (+ start i)))
              unit
              (set! ok false))
            (set! i (+ i 1))))
        ok))
    false))

;; `intern-map-insert-existing-from`: probe forward from `cursor` for the first
;; empty id lane and claim it. The id lane stores `id + 1`, so zero is empty.
(define (it-map-insert-from
  [map-ids : (Array i64)]
  [map-hashes : (Array i64)]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [capacity : i64]) : unit
  (let
    [slot : i64 cursor]
    [probes : i64 0]
    [placed : bool false]
    (begin
      (while (and (< probes capacity) (not placed))
        (if (= (array-ref map-ids slot) 0)
          (begin
            (array-set! map-ids slot (+ id 1))
            (array-set! map-hashes slot hash)
            (set! placed true))
          (begin
            (set! slot (it-bucket (+ slot 1) capacity))
            (set! probes (+ probes 1)))))
      unit)))

;; `intern-map-rebuild-prefix` + `intern-map-insert-existing!`: after doubling,
;; every live id is rehashed from its pool name and reinserted.
(define (it-grow!
  [map-ids : (Array i64)]
  [map-hashes : (Array i64)]
  [names : (Array u8)]
  [name-off : (Array i64)]
  [name-len : (Array i64)]
  [state : (Array i64)]) : unit
  (let
    [capacity : i64 (* (array-ref state it-state-capacity) 2)]
    [count : i64 (array-ref state it-state-count)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (array-set! map-ids i 0)
          (set! i (+ i 1))))
      (array-set! state it-state-capacity capacity)
      (set! i 0)
      (while (< i count)
        (let
          [hash : i64
            (it-hash-words names (array-ref name-off i) (array-ref name-len i))]
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
  [text : (Array u8)]
  [start : i64]
  [len : i64]
  [map-ids : (Array i64)]
  [map-hashes : (Array i64)]
  [names : (Array u8)]
  [name-off : (Array i64)]
  [name-len : (Array i64)]
  [state : (Array i64)]) : i64
  (let
    [capacity : i64 (array-ref state it-state-capacity)]
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
          [stored : i64 (array-ref map-ids cursor)]
          (if (= stored 0)
            (let
              [count : i64 (array-ref state it-state-count)]
              [name-cursor : i64 (array-ref state it-state-name-cursor)]
              [i : i64 0]
              (begin
                ;; Miss: copy the slice into the persistent name pool, take the
                ;; next source id, then place it. Growth happens first so the
                ;; placement probe already runs at the final capacity.
                (while (< i len)
                  (begin
                    (array-set!
                      names
                      (+ name-cursor i)
                      (array-ref text (+ start i)))
                    (set! i (+ i 1))))
                (array-set! name-off count name-cursor)
                (array-set! name-len count len)
                (array-set! state it-state-name-cursor (+ name-cursor len))
                (if (>= (* (+ count 1) 4) (* capacity 3))
                  (begin
                    (it-grow! map-ids map-hashes names name-off name-len state)
                    (set! capacity (array-ref state it-state-capacity))
                    (set! cursor (it-bucket hash capacity)))
                  unit)
                (array-set! state it-state-count (+ count 1))
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
                (= (array-ref map-hashes cursor) hash)
                (it-slice-eq?
                  names
                  (array-ref name-off source-id)
                  (array-ref name-len source-id)
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
(define (it-reset! [map-ids : (Array i64)] [state : (Array i64)]) : unit
  (let
    [capacity : i64 (array-ref state it-state-capacity)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (array-set! map-ids i 0)
          (set! i (+ i 1))))
      (array-set! state it-state-capacity it-initial-capacity)
      (array-set! state it-state-count 0)
      (array-set! state it-state-name-cursor 0)
      unit)))

;; One pass over the identifier stream, in encounter order.
(define (it-pass
  [text : (Array u8)]
  [starts : (Array i64)]
  [lengths : (Array i64)]
  [lines : i64]
  [map-ids : (Array i64)]
  [map-hashes : (Array i64)]
  [names : (Array u8)]
  [name-off : (Array i64)]
  [name-len : (Array i64)]
  [state : (Array i64)]
  [seed-acc : i64]) : i64
  (let
    [k : i64 0]
    [acc : i64 seed-acc]
    (begin
      (while (< k lines)
        (let
          [id : i64
            (it-intern-slice
              text
              (array-ref starts k)
              (array-ref lengths k)
              map-ids
              map-hashes
              names
              name-off
              name-len
              state)]
          (begin
            (set! acc (+ (* acc 1000003) (* id 2654435761)))
            (set! k (+ k 1)))))
      acc)))

;; Index the newline-separated corpus into (start, length) slices without
;; copying: `intern-slice` takes a source buffer plus a range, exactly as the
;; lexer hands it the source text plus the token's extent.
(define (it-count-lines [text : (Array u8)] [n : i64]) : i64
  (let
    [i : i64 0]
    [lines : i64 0]
    (begin
      (while (< i n)
        (begin
          (when (= (cast (array-ref text i) : i64) 10) (set! lines (+ lines 1)))
          (set! i (+ i 1))))
      lines)))

(define (it-index-lines
  [text : (Array u8)]
  [n : i64]
  [starts : (Array i64)]
  [lengths : (Array i64)]) : i64
  (let
    [i : i64 0]
    [start : i64 0]
    [lines : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (= (cast (array-ref text i) : i64) 10)
            (begin
              (array-set! starts lines start)
              (array-set! lengths lines (- i start))
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

(define (it-string-to-array [source : String]) : (Array u8)
  (let
    [n : i64 (string-length source)]
    [out : (Array u8) (array.make-array u8 n)]
    [src : (Ptr u8)
      (unsafe
        (string-data (& source)))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set!
            out
            i
            (unsafe
              (ptr-read (ptr-offset src i))))
          (set! i (+ i 1))))
      out)))

(define (it-bench [path : String] [rounds : i64]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file path))]
    [text : (Array u8) (it-string-to-array source)]
    [n : i64 (array-length text)]
    [line-count : i64 (it-count-lines text n)]
    [starts : (Array i64) (array.make-array i64 (+ line-count 1))]
    [lengths : (Array i64) (array.make-array i64 (+ line-count 1))]
    [lines : i64 (it-index-lines text n starts lengths)]
    [storage : i64 (it-map-storage lines)]
    [map-ids : (Array i64) (array.make-array i64 storage)]
    [map-hashes : (Array i64) (array.make-array i64 storage)]
    [names : (Array u8) (array.make-array u8 (+ n 1))]
    [name-off : (Array i64) (array.make-array i64 (+ lines 1))]
    [name-len : (Array i64) (array.make-array i64 (+ lines 1))]
    [state : (Array i64) (array.make-array i64 3)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (it-reset! map-ids state)
          (set!
            acc
            (it-pass
              text
              starts
              lengths
              lines
              map-ids
              map-hashes
              names
              name-off
              name-len
              state
              acc))
          (set!
            acc
            (it-pass
              text
              starts
              lengths
              lines
              map-ids
              map-hashes
              names
              name-off
              name-len
              state
              acc))
          (set! round (+ round 1))))
      (+ (* acc 1000003) (array-ref state it-state-count)))))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (it-bench path rounds))
      0)))