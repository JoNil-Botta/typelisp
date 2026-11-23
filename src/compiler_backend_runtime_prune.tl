;; In a closed executable the generated text is the last word on helper
;; dependencies. In particular, an IR BoundsCheck may disappear in emission,
;; while a located abort, a copy thunk, or an allocator slow path can introduce
;; a reference after the IR call census. Only explicitly nominated fragments
;; are eligible for removal. All other text and data are roots.
(import stdlib.hashmap)
(import stdlib.iterator)
(import stdlib.runtime)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import (hashmap.hashmap i64 i64) as label_map)

(define optional-begin : String
  "# typelisp optional runtime begin\n")
(define optional-end : String
  "# typelisp optional runtime end\n")
(define bundle-begin : String
  "# typelisp runtime bundle begin\n")
(define bundle-end : String
  "# typelisp runtime bundle end\n")

(define (optional-fragment [body : String]) : String
  (str_cat.str-cat optional-begin body optional-end))

(define (optional-bundle [body : String]) : String
  (str_cat.str-cat bundle-begin body bundle-end))

(defstruct RuntimeFragment
  (start i64)
  (end i64))

;; A bounded mask keeps the scratch footprint independent of program size.
;; The full original bundle is valid if a new target exceeds this inventory.
(define fragment-capacity : i64
  64)

(define (line-end [data : (Ptr u8)] [start : i64] [limit : i64]) : i64
  (let
    [end : i64 start]
    (unsafe
      (while (and (< end limit) (!= (ptr-read (ptr-offset data end)) 10))
        (+= end 1)))
    (if (< end limit)
      (+ end 1)
      limit)))

(define (has-prefix?
  [data : (Ptr u8)]
  [start : i64]
  [limit : i64]
  [prefix : (& str)]) : bool
  (let
    [length : i64 (string.string-length prefix)]
    (when (> length (- limit start)) (return false))
    (unsafe
      (let
        [bytes : (Ptr u8) (string-data prefix)]
        (for [i (iterator.range 0 length)]
          (when
            (!=
              (ptr-read (ptr-offset data (+ start i)))
              (ptr-read (ptr-offset bytes i)))
            (return false)))))
    true))

(define (fast-entry? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (and
    (or (= (- end start) 14) (= (- end start) 15))
    (has-prefix? data start end ".L_tl_alloc")
    (unsafe
      (let
        [digit : u8 (ptr-read (ptr-offset data (- end 3)))]
        (and
          (>= digit 48)
          (<= digit 57)
          (= (ptr-read (ptr-offset data (- end 2))) 58))))))

;; Runtime bundles supply one self-contained function per .globl line.
;; Allocator fast entries are object-local functions. Other labels belong to
;; the current function, including cross-entry branch targets.
(define (bundle-entry? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (or
    (has-prefix? data start end "    .globl ")
    (fast-entry? data start end)
    (has-prefix? data start end ".L_tl_alloc_win_commit_to:")))

(define (record-range!
  [ranges : (&mut (__tl_dyn-array RuntimeFragment))]
  [count : i64]
  [start : i64]
  [end : i64]) : i64
  (if (or (< start 0) (>= count (array-length ranges)))
    count
    (begin
      (set! (array-ref ranges count) (RuntimeFragment start end))
      (+ count 1))))

(define (find-ranges!
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (&mut (__tl_dyn-array RuntimeFragment))]) : i64
  (let
    [count : i64 0]
    [pos : i64 0]
    [start : i64 -1]
    [bundle : bool false]
    (while (and (< pos length) (< count (array-length ranges)))
      (let
        [end : i64 (line-end data pos length)]
        (cond
          [(has-prefix? data pos end (& optional-begin)) (set! start pos)]
          [(has-prefix? data pos end (& optional-end))
            (set! count (record-range! ranges count start end))
            (set! start -1)]
          [(has-prefix? data pos end (& bundle-begin)) (set! bundle true)]
          [(has-prefix? data pos end (& bundle-end))
            (set! count (record-range! ranges count start end))
            (set! start -1)
            (set! bundle false)]
          [(and bundle (bundle-entry? data pos end))
            (set! count (record-range! ranges count start pos))
            (set! start pos)]
          [else unit])
        (set! pos end)))
    (if (or bundle (>= start 0))
      fragment-capacity
      count)))

(define (symbol-byte? [byte : u8]) : bool
  (or
    (and (>= byte 65) (<= byte 90))
    (and (>= byte 97) (<= byte 122))
    (and (>= byte 48) (<= byte 57))
    (= byte 95)
    (= byte 46)
    (= byte 36)))

;; Only generated symbols can name a fragment. Quoted GAS symbols, including
;; argument entries containing colons, hash verbatim between their quotes.
;; A collision retains every matching fragment, so it cannot lose an edge.
(define (symbol-token [data : (Ptr u8)] [start : i64] [limit : i64]) : (Tuple
    i64
    i64)
  (unsafe
    (let
      [quoted : bool (= (ptr-read (ptr-offset data start)) 34)]
      [pos : i64
        (if quoted
          (+ start 1)
          start)]
      [hash : i64 0]
      (while (and
        (< pos limit)
        (if quoted
          (!= (ptr-read (ptr-offset data pos)) 34)
          (symbol-byte? (ptr-read (ptr-offset data pos)))))
        (set!
          hash
          (+ (* hash 131) (cast (ptr-read (ptr-offset data pos)) : i64)))
        (+= pos 1))
      (tuple
        hash
        (if (and quoted (< pos limit))
          (+ pos 1)
          pos)))))

(define (symbol-mask [labels : (& label_map.Map)] [hash : i64]) : i64
  (label_map.get-value-or labels hash 0))

(define (index-labels!
  [data : (Ptr u8)]
  [range : RuntimeFragment]
  [bit : i64]
  [labels : (&mut label_map.Map)]) : unit
  (unsafe
    (let
      [pos : i64 range.start]
      (while (< pos range.end)
        (let
          [end : i64 (line-end data pos range.end)]
          (when
            (and
              (> (- end pos) 2)
              (= (ptr-read (ptr-offset data (- end 2))) 58))
            (let
              [token : (Tuple i64 i64) (symbol-token data pos end)]
              [hash : i64 (tuple-ref token 0)]
              (when
                (= (tuple-ref token 1) (- end 2))
                (label_map.insert-ref!
                  labels
                  hash
                  (bit-or bit (symbol-mask (& labels) hash))))))
          (set! pos end))))))

(define (reference-mask
  [data : (Ptr u8)]
  [start : i64]
  [limit : i64]
  [labels : (& label_map.Map)]) : i64
  (unsafe
    (let
      [pos : i64 start]
      [mask : i64 0]
      (while (< pos limit)
        (let
          [end : i64 (line-end data pos limit)]
          [cursor : i64 pos]
          (while (and
            (< cursor end)
            (<= (ptr-read (ptr-offset data cursor)) 32))
            (+= cursor 1))
          ;; Abort rows record the uses of each handler in the .irp list.
          (unless
            (or
              (has-prefix? data cursor end ".extern ")
              (has-prefix? data cursor end ".globl ")
              (has-prefix? data cursor end ".type ")
              (has-prefix? data cursor end ".size ")
              (has-prefix? data cursor end ".irp "))
            (while (< cursor end)
              (let
                [byte : u8 (ptr-read (ptr-offset data cursor))]
                (cond
                  [(= byte 35) (set! cursor end)]
                  [(or (= byte 34) (and (!= byte 36) (symbol-byte? byte)))
                    (let
                      [token : (Tuple i64 i64) (symbol-token data cursor end)]
                      (set!
                        mask
                        (bit-or mask (symbol-mask labels (tuple-ref token 0))))
                      (set! cursor (tuple-ref token 1)))]
                  [else (+= cursor 1)]))))
          (set! pos end)))
      mask)))

(define (reachable-fragments
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (& (__tl_dyn-array RuntimeFragment))]
  [count : i64]) : i64
  (let
    [labels : label_map.Map (label_map.with-capacity 256)]
    [live : i64 0]
    [seen : i64 0]
    [cursor : i64 0]
    (for [index (iterator.range 0 count)]
      (index-labels! data (array-ref ranges index) (shl 1 index) (&mut labels)))
    (for [index (iterator.range 0 count)]
      (let
        [range : RuntimeFragment (array-ref ranges index)]
        (set!
          live
          (bit-or live (reference-mask data cursor range.start (& labels))))
        (set! cursor range.end)))
    (set! live (bit-or live (reference-mask data cursor length (& labels))))
    (while (!= live seen)
      (for [index (iterator.range 0 count)]
        (let
          [bit : i64 (shl 1 index)]
          (when
            (and (!= (bit-and live bit) 0) (= (bit-and seen bit) 0))
            (let
              [range : RuntimeFragment (array-ref ranges index)]
              (set! seen (bit-or seen bit))
              (set!
                live
                (bit-or
                  live
                  (reference-mask data range.start range.end (& labels)))))))))
    live))

(unsafe
  (extern (copy-range! [dst : (MutPtr u8)] [src : (Ptr u8)] [length : i64]) : unit (:symbol "tl_memcpy_fresh")))

(define (render-kept
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (& (__tl_dyn-array RuntimeFragment))]
  [count : i64]
  [live : i64]) : String
  (unsafe
    (let
      [kept-length : i64 length]
      [start : i64 0]
      [written : i64 0]
      (for [index (iterator.range 0 count)]
        (when
          (= (bit-and live (shl 1 index)) 0)
          (let
            [range : RuntimeFragment (array-ref ranges index)]
            (-= kept-length (- range.end range.start)))))
      (let
        [out : (MutPtr u8) (runtime.runtime-alloc (+ kept-length 1))]
        (for [index (iterator.range 0 count)]
          (when
            (= (bit-and live (shl 1 index)) 0)
            (let
              [range : RuntimeFragment (array-ref ranges index)]
              [span : i64 (- range.start start)]
              (copy-range!
                (ptr-offset out written)
                (ptr-offset data start)
                span)
              (+= written span)
              (set! start range.end))))
        (copy-range!
          (ptr-offset out written)
          (ptr-offset data start)
          (- length start))
        (ptr-write! (ptr-offset out kept-length) 0)
        (string-from-bytes (ptr-cast out : (Ptr u8)) kept-length)))))

(define (prune [asm : String]) : String
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data (& asm)))]
    [length : i64 (string.string-length (& asm))]
    [ranges : (__tl_dyn-array RuntimeFragment)
      (__tl_make-array RuntimeFragment fragment-capacity)]
    [count : i64 (find-ranges! data length (&mut ranges))]
    (if (or (= count 0) (= count fragment-capacity))
      asm
      (let
        [live : i64
          (with-arena
            scratch
            (reachable-fragments data length (& ranges) count))]
        [all : i64 (- (shl 1 count) 1)]
        (if (= live all)
          asm
          (render-kept data length (& ranges) count live))))))