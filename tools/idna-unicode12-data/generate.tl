(import pins)
(import parse)
(import read)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.vector)
(import stdlib.sort)
(import (stdlib.vector.vector u8) as octets)
(import (stdlib.vector.vector u64) as keys)
(import (stdlib.sort.vec u64) as key-sort)

(define (append [out : (&mut out octets.Vec)] [text : String]) : unit
  (let
    [index : i64 0]
    (while (< index (string.string-length text))
      (octets.push-ref! out (cast (string.string-ref text index) : u8))
      (set! index (+ index 1)))))

;; Integers have fixed widths in immutable ASCII-hex storage. This avoids
;; executable array constructors and keeps every runtime read bounded.
(define (hex [out : (&mut out octets.Vec)] [value : u32] [width : i64]) : unit
  (let
    [index : i64 (- width 1)]
    [digits : String "0123456789ABCDEF"]
    (when
      (or
        (< width 1)
        (> width 8)
        (and
          (< width 8)
          (>= (cast value : u64) (shl (cast 1 : u64) (cast (* width 4) : u64)))))
      (parse.fail "generated" 0 "fixed-width encoding overflow"))
    (while (>= index 0)
      (let
        [digit : i64
          (cast (bit-and (shr value (cast (* index 4) : u64)) 15) : i64)]
        (octets.push-ref! out (cast (string.string-ref digits digit) : u8)))
      (set! index (- index 1)))))

(define (table-start [out : (&mut out octets.Vec)] [name : (& name str)]) : unit
  (append
    out
    (str_cat.str-cat
      ";: Immutable "
      (string.copy name)
      " fixed-width table.\n(define ("
      (string.copy name)
      ") : String\n  \"")))

(define (table-end [out : (&mut out octets.Vec)]) : unit
  (append out "\")\n\n"))

(define (count
  [out : (&mut out octets.Vec)]
  [name : (& name str)]
  [value : i64]) : unit
  (append
    out
    (str_cat.str-cat
      ";: Number of "
      (string.copy name)
      " entries.\n(define ("
      (string.copy name)
      ") : i64\n  "
      (string.int->string value)
      ")\n\n")))

(define (ranges
  [out : (&mut out octets.Vec)]
  [data : (& data read.Data)]
  [idna : bool]) : i64
  (let
    [start : i64 0]
    [rows : i64 0]
    (table-start
      out
      (if idna
        "idna-ranges"
        "support-ranges"))
    (while (< start 1114112)
      (let
        [end : i64 start]
        [value : u32
          (if idna
            (cast (array-ref data.idna start) : u32)
            (bit-and (array-ref data.facts start) 0x3fffff))]
        (while (and
          (< end 1114111)
          (=
            value
            (if idna
              (cast (array-ref data.idna (+ end 1)) : u32)
              (bit-and (array-ref data.facts (+ end 1)) 0x3fffff))))
          (set! end (+ end 1)))
        (hex out (cast start : u32) 6)
        (hex out (cast end : u32) 6)
        (hex
          out
          value
          (if idna
            2
            8))
        (set! rows (+ rows 1))
        (set! start (+ end 1))))
    (table-end out)
    rows))

(define (decompositions
  [out : (&mut out octets.Vec)]
  [data : (& data read.Data)]) : i64
  (let
    [cp : i64 0]
    [rows : i64 0]
    (table-start out "decomposition-index")
    (while (< cp 1114112)
      (let
        [length : i64 (cast (array-ref data.lengths cp) : i64)]
        [offset : i64 (cast (array-ref data.offsets cp) : i64)]
        (when
          (> length 0)
          (when
            (> (+ offset length) data.pool-count)
            (parse.fail "generated" 0 "decomposition span outside pool"))
          (hex out (cast cp : u32) 6)
          (hex out (cast offset : u32) 8)
          (hex out (cast length : u32) 2)
          (set! rows (+ rows 1))))
      (set! cp (+ cp 1)))
    (table-end out)
    (table-start out "decomposition-pool")
    (set! cp 0)
    (while (< cp data.pool-count)
      (hex out (array-ref data.pool cp) 6)
      (set! cp (+ cp 1)))
    (table-end out)
    rows))

(define (compositions [out : (&mut out octets.Vec)] [data : (& data read.Data)]) : i64
  (let
    [ordered : keys.Vec (keys.new)]
    [cp : i64 0]
    (while (< cp 1114112)
      (when
        (and
          (= (array-ref data.lengths cp) 2)
          (= (bit-and (array-ref data.seen cp) 16) 0))
        (let
          [offset : i64 (cast (array-ref data.offsets cp) : i64)]
          [first : u32 (array-ref data.pool offset)]
          [second : u32 (array-ref data.pool (+ offset 1))]
          [key : u64
            (bit-or
              (shl (cast first : u64) (cast 21 : u64))
              (cast second : u64))]
          (when
            (!= (bit-and (array-ref data.facts (cast first : i64)) 255) 0)
            (parse.fail
              "generated"
              0
              "non-starter composition was not excluded"))
          ;; Include the result in the key so sorting preserves its association.
          (keys.push-ref!
            (&mut ordered)
            (bit-or (shl key (cast 21 : u64)) (cast cp : u64)))))
      (set! cp (+ cp 1)))
    (key-sort.sort! (&mut ordered))
    (table-start out "composition-pairs")
    (set! cp 0)
    (while (< cp (keys.len (& ordered)))
      (let
        [entry : u64 (keys.get (& ordered) cp 0)]
        (when
          (and
            (> cp 0)
            (=
              (shr entry (cast 21 : u64))
              (shr (keys.get (& ordered) (- cp 1) 0) (cast 21 : u64))))
          (parse.fail "generated" 0 "duplicate composition pair"))
        (hex out (cast (shr entry (cast 42 : u64)) : u32) 6)
        (hex out (cast (bit-and (shr entry (cast 21 : u64)) 0x1fffff) : u32) 6)
        (hex out (cast (bit-and entry 0x1fffff) : u32) 6))
      (set! cp (+ cp 1)))
    (table-end out)
    (keys.len (& ordered))))

(define (contexts [out : (&mut out octets.Vec)]) : unit
  (let
    [starts : (Array i64 9) (array 183 885 1523 1524 1632 1776 8204 8205 12539)]
    [ends : (Array i64 9) (array 183 885 1523 1524 1641 1785 8204 8205 12539)]
    [rules : (Array i64 9) (array 3 4 5 6 8 9 1 2 7)]
    [index : i64 0]
    (table-start out "context-ranges")
    (while (< index 9)
      (hex out (cast (array-ref starts index) : u32) 6)
      (hex out (cast (array-ref ends index) : u32) 6)
      (hex out (cast (array-ref rules index) : u32) 2)
      (hex
        out
        (if (or (= index 6) (= index 7))
          3
          1)
        2)
      (set! index (+ index 1)))
    (table-end out)))

(define (generate [texts : (& texts (__tl_dyn-array String))]) : byte_buf.ByteBuf
  (let
    [data : read.Data (read.new)]
    [out : octets.Vec (octets.new)]
    [index : i64 0]
    (read.context (& (array-ref texts 0)))
    (read.idna (&mut data) (& (array-ref texts 1)))
    (read.unicode-data (&mut data) (& (array-ref texts 2)))
    (read.normalization (&mut data) (& (array-ref texts 3)))
    (read.version (& (array-ref texts 4)) (pins.name 4))
    (read.properties (&mut data) (& (array-ref texts 5)) 5)
    (read.properties (&mut data) (& (array-ref texts 6)) 6)
    (read.properties (&mut data) (& (array-ref texts 7)) 7)
    (append
      (&mut out)
      ";# Generated by tools/idna-unicode12-data/generate.tl. Do not edit.\n;# Unicode data: tools/idna-unicode12-data/UNICODE-LICENSE.txt.\n;# Immutable fixed-width hexadecimal integers; no runtime initialization.\n")
    (append
      (&mut out)
      (str_cat.str-cat
        ";: Reviewed TypeLisp IDNA profile schema.\n(define (schema) : String\n  \""
        (pins.schema)
        "\")\n\n;: The Unicode version used by every table.\n(define (unicode-version) : String\n  \""
        (pins.unicode-version)
        "\")\n\n"))
    (while (< index 8)
      (append
        (&mut out)
        (str_cat.str-cat
          ";; "
          (pins.name index)
          " "
          (string.int->string (pins.size index))
          " "
          (pins.sha256 index)
          "\n"))
      (set! index (+ index 1)))
    (contexts (&mut out))
    (let
      [idna-rows : i64 (ranges (&mut out) (& data) true)]
      [support-rows : i64 (ranges (&mut out) (& data) false)]
      [decomposition-rows : i64 (decompositions (&mut out) (& data))]
      [composition-rows : i64 (compositions (&mut out) (& data))]
      (when
        (or
          (!= idna-rows 2869)
          (!= support-rows 1906)
          (!= decomposition-rows 2060)
          (!= data.pool-count 3085)
          (!= composition-rows 940))
        (parse.fail "generated" 0 "IDNA encoding changed audited range count"))
      (count (&mut out) "idna-range-count" idna-rows)
      (count (&mut out) "support-range-count" support-rows)
      (count (&mut out) "decomposition-count" decomposition-rows)
      (count (&mut out) "pool-count" data.pool-count)
      (count (&mut out) "composition-count" composition-rows)
      (io.println
        "IDNA ranges={} support ranges={} decompositions={} pool={} compositions={} source bytes={}"
        idna-rows
        support-rows
        decomposition-rows
        data.pool-count
        composition-rows
        (- (octets.len (& out)) 2)))
    (set! out.len (- out.len 2))
    (byte_buf.from-array-prefix out.slots out.len)))

(define (main) : i64
  (if (!= (io.arg-count) 3)
    (begin
      (io.eprintln "usage: generate <pinned-input-directory> <output.tl>")
      2)
    (let
      [texts : (__tl_dyn-array String) (read.sources (io.arg 1))]
      [out : byte_buf.ByteBuf (generate (& texts))]
      [path : String (io.arg 2)]
      (io.write-file path (byte_buf.as-bytes (& out)))
      0)))