;; The string part copies move whole words, then one overlapping final word
;; from 8 bytes up, or a first and last 4 (or 2) bytes below that, or one byte
;; at length 1. For every length 0..40 at destination offsets 0..9, both copy
;; helpers must reproduce the source exactly and leave every byte before and
;; after the copied range untouched. `concat3-borrowed`, which copies its parts
;; through them, is checked against a byte-by-byte reference for part lengths
;; 0..17.
(import stdlib.string)
(import stdlib.text_buf)

(define sentinel : u8
  (cast 238 : u8))

;; LEN bytes, each different from its neighbours and from the sentinel.
(define (make [len : i64] [seed : i64]) : String
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (while (< i len)
      (set!
        out
        (text_buf.append
          out
          (string.substring
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            (% (+ i seed) 62)
            1)))
      (set! i (+ i 1)))
    (text_buf.render out)))

;; 0 when copying SRC into a sentinel-filled buffer at OFFSET with the owned or
;; the borrowed helper copies exactly SRC's bytes there and nothing else.
(define (copy-errors [src : String] [offset : i64] [owned : bool]) : i64
  (let
    [len : i64 (string.string-length (& src))]
    [size : i64 (+ offset (+ len 16))]
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 size)]
    [i : i64 0]
    [bad : i64 0]
    (while (< i size)
      (set! (array-ref buf i) sentinel)
      (set! i (+ i 1)))
    (let
      [dst : (MutPtr u8)
        (unsafe
          (__tl_array-data buf))]
      (if owned
        (string.str-copy-owned-bytes-into (string.copy (& src)) dst offset len)
        (string.str-copy-borrowed-bytes-into (& src) dst offset len)))
    (set! i 0)
    (while (< i size)
      (let
        [want : u8
          (if (and (>= i offset) (< i (+ offset len)))
            (cast (string.string-ref (& src) (- i offset)) : u8)
            sentinel)]
        (unless (= (array-ref buf i) want) (set! bad (+ bad 1))))
      (set! i (+ i 1)))
    bad))

(define (ref-concat3-ok? [a : String] [b : String] [c : String]) : bool
  (let
    [got : String (string.concat3-borrowed (& a) (& b) (& c))]
    [want : String
      (text_buf.render
        (text_buf.append
          (text_buf.append (text_buf.append (text_buf.empty) a) b)
          c))]
    [n : i64 (string.string-length (& want))]
    [i : i64 0]
    [ok : bool (= (string.string-length (& got)) n)]
    (while (and ok (< i n))
      (unless
        (= (string.string-ref (& got) i) (string.string-ref (& want) i))
        (set! ok false))
      (set! i (+ i 1)))
    ok))

(define (main) : i64
  (let
    [bad : i64 0]
    [len : i64 0]
    (while (<= len 40)
      (let
        [offset : i64 0]
        (while (< offset 10)
          (let
            [src : String (make len (+ len offset))]
            (set! bad (+ bad (copy-errors (string.copy (& src)) offset true)))
            (set! bad (+ bad (copy-errors src offset false))))
          (set! offset (+ offset 1))))
      (set! len (+ len 1)))
    (let
      [la : i64 0]
      (while (<= la 17)
        (let
          [lc : i64 0]
          (while (<= lc 17)
            (unless
              (ref-concat3-ok? (make la 1) (make (% (+ la lc) 9) 7) (make lc 3))
              (set! bad (+ bad 1)))
            (set! lc (+ lc 1))))
        (set! la (+ la 1))))
    (if (= bad 0)
      42
      1)))