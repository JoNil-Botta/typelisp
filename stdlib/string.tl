;# String utility library for TypeLisp.
;#
;# Provides string operations built on compiler/runtime primitives:
;# `string-length`, `string-ref`, `string-data`, `array-data`, `tl_alloc`, and
;# `string-from-bytes`.
;#
;# Usage: `(import stdlib.string)`
;#
;# ```typelisp
;# (import stdlib.string)
;# (define ok : bool
;#   (let
;#     [s : String "  alpha  "]
;#     [haystack : String (string.string-trim-left (& s))]
;#     [needle : String "ph"]
;#     (string.string-contains (& haystack) (& needle))))
;# ```
;: Runtime bounds-check trap shared with array/string indexing.
(module stdlib.string)

(extern (tl_oob_abort) : never)

;: Runtime active-arena allocator used by integer rendering.
(extern (string-runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;: Write one ASCII byte into an active-arena buffer.
(define (int->string-write-byte!
  [dst : (MutPtr u8)]
  [offset : i64]
  [byte : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset dst offset) (cast byte : u8))))

;: Count decimal digits for a non-positive value without negating i64-min.
(define (int->string-negative-digit-count [value : i64]) : i64
  (let
    [count : i64 1]
    [cursor : i64 value]
    (begin
      (while (<= cursor -10)
        (begin
          (set! cursor (/ cursor 10))
          (set! count (+ count 1))))
      count)))

;: Write decimal digits for a non-positive value at `base` in `dst`.
(define (int->string-write-negative-digits!
  [dst : (MutPtr u8)]
  [base : i64]
  [value : i64]
  [digits : i64]) : unit
  (let
    [cursor : i64 value]
    [index : i64 (- digits 1)]
    (while (>= index 0)
      (let
        [digit : i64 (- 0 (% cursor 10))]
        (begin
          (stdlib.string.int->string-write-byte!
            dst
            (+ base index)
            (+ 48 digit))
          (set! cursor (/ cursor 10))
          (set! index (- index 1)))))))

;: Return the decimal spelling of `value` in fresh active-arena String storage.
(define (int->string [value : i64]) : String
  (let
    [negative : bool (< value 0)]
    [magnitude : i64
      (if negative
        value
        (- 0 value))]
    [digits : i64 (stdlib.string.int->string-negative-digit-count magnitude)]
    [len : i64
      (if negative
        (+ digits 1)
        digits)]
    [buf : (MutPtr u8) (stdlib.string.string-runtime-alloc len)]
    (begin
      (if negative
        (stdlib.string.int->string-write-byte! buf 0 45)
        unit)
      (stdlib.string.int->string-write-negative-digits!
        buf
        (if negative
          1
          0)
        magnitude
        digits)
      (unsafe
        (string-from-bytes (ptr-cast buf : (Ptr u8)) len)))))

;: Trap when the requested substring range is outside `text`.
(define (substring-bounds-check [text : (& text str)] [start : i64] [len : i64]) : unit
  (let
    [n : i64 (string-length text)]
    (if (< start 0)
      (stdlib.string.tl_oob_abort)
      (if (< len 0)
        (stdlib.string.tl_oob_abort)
        (if (> start n)
          (stdlib.string.tl_oob_abort)
          (let
            [remaining : i64 (- n start)]
            (if (> len remaining)
              (stdlib.string.tl_oob_abort)
              unit)))))))

;: Copy `n` bytes from `src` into `dst` at byte offset `doff`, eight bytes at a
;: time with a byte tail. x86 tolerates the unaligned word stores, and the final
;: partial word is copied byte-wise so no read passes `src`'s `n`th byte.
(define (str-copy-bytes-into
  [src : (Ptr u8)]
  [dst : (MutPtr u8)]
  [doff : i64]
  [n : i64]) : unit
  (let
    [words : i64 (/ n 8)]
    [src64 : (Ptr i64)
      (unsafe
        (ptr-cast src : (Ptr i64)))]
    [dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset dst doff) : (MutPtr i64)))]
    [w : i64 0]
    [b : i64 (* words 8)]
    (begin
      (while (< w words)
        (begin
          (unsafe
            (ptr-write! (ptr-offset dst64 w) (ptr-read (ptr-offset src64 w))))
          (set! w (+ w 1))))
      (while (< b n)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst (+ doff b))
              (ptr-read (ptr-offset src b))))
          (set! b (+ b 1))))
      unit)))

;: Copy a checked borrowed byte range into a fresh active-arena String.
(define (substring-copy-checked [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 len)]
    [src : (Ptr u8)
      (unsafe
        (string-data text))]
    [dst : (MutPtr u8)
      (unsafe
        (array-data buf))]
    (begin
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (ptr-offset src start))
        dst
        0
        len)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))

;: Return a fresh active-arena String by concatenating two borrowed strings.
(define (string-append-borrowed [left : (& left str)] [right : (& right str)]) : String
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    [total-len : i64 (+ left-len right-len)]
    [buf : (Array u8) (make-array u8 total-len)]
    [left-src : (Ptr u8)
      (unsafe
        (string-data left))]
    [right-src : (Ptr u8)
      (unsafe
        (string-data right))]
    [dst : (MutPtr u8)
      (unsafe
        (array-data buf))]
    (begin
      (stdlib.string.str-copy-bytes-into left-src dst 0 left-len)
      (stdlib.string.str-copy-bytes-into right-src dst left-len right-len)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))

;: Return a fresh active-arena copy of borrowed text.
(define (string-copy-borrowed [text : (& text str)]) : String
  (stdlib.string.substring-borrowed text 0 (string-length text)))

;: Borrowed alias for `string-append-borrowed`.
(define (string-concat-borrowed [left : (& left str)] [right : (& right str)]) : String
  (stdlib.string.string-append-borrowed left right))

;: Return a fresh active-arena String by concatenating two owned strings.
(define (string-append [left : String] [right : String]) : String
  (stdlib.string.string-append-borrowed (& left) (& right)))

;: Alias for `string-append`.
(define (string-concat [left : String] [right : String]) : String
  (stdlib.string.string-append left right))

;: Return a fresh active-arena String by concatenating all owned strings in order.
(define (string-concat-all [parts : (Array String)]) : String
  (let
    [count : i64 (array-length parts)]
    [len-index : i64 0]
    [total-len : i64 0]
    (begin
      (while (< len-index count)
        (let
          [part : String (array-ref parts len-index)]
          (begin
            (set! total-len (+ total-len (string-length part)))
            (set! len-index (+ len-index 1)))))
      (let
        [buf : (Array u8) (make-array u8 total-len)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data buf))]
        [copy-index : i64 0]
        [off : i64 0]
        (begin
          (while (< copy-index count)
            (let
              [part : String (array-ref parts copy-index)]
              [len : i64 (string-length part)]
              (begin
                (stdlib.string.str-copy-bytes-into
                  (unsafe
                    (string-data (& part)))
                  dst
                  off
                  len)
                (set! off (+ off len))
                (set! copy-index (+ copy-index 1)))))
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))))

;: Store `value` in `parts` and return `parts` for macro-generated pack chains.
(define (string-concat-all-pack-part
  [parts : (Array String)]
  [index : i64]
  [value : String]) : (Array String)
  (begin
    (array-set! parts index value)
    parts))

;: Return a fresh active-arena String by concatenating three owned strings.
(define (string-concat3 [a : String] [b : String] [c : String]) : String
  (stdlib.string.string-concat5 a b c "" ""))

;: Return a fresh active-arena String by concatenating four owned strings.
(define (string-concat4 [a : String] [b : String] [c : String] [d : String]) : String
  (stdlib.string.string-concat5 a b c d ""))

;: Return a fresh active-arena String by concatenating five owned strings.
(define (string-concat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (let
    [a-len : i64 (string-length a)]
    [b-len : i64 (string-length b)]
    [c-len : i64 (string-length c)]
    [d-len : i64 (string-length d)]
    [e-len : i64 (string-length e)]
    [total-len : i64 (+ a-len (+ b-len (+ c-len (+ d-len e-len))))]
    [buf : (Array u8) (make-array u8 total-len)]
    [dst : (MutPtr u8)
      (unsafe
        (array-data buf))]
    [off : i64 0]
    (begin
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (string-data (& a)))
        dst
        off
        a-len)
      (set! off (+ off a-len))
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (string-data (& b)))
        dst
        off
        b-len)
      (set! off (+ off b-len))
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (string-data (& c)))
        dst
        off
        c-len)
      (set! off (+ off c-len))
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (string-data (& d)))
        dst
        off
        d-len)
      (set! off (+ off d-len))
      (stdlib.string.str-copy-bytes-into
        (unsafe
          (string-data (& e)))
        dst
        off
        e-len)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))

;: Return a fresh active-arena owned substring copied from borrowed text.
(define (substring-borrowed [text : (& text str)] [start : i64] [len : i64]) : String
  (begin
    (stdlib.string.substring-bounds-check text start len)
    (stdlib.string.substring-copy-checked text start len)))

;: Return a fresh active-arena owned substring copied from owned text.
(define (substring [text : String] [start : i64] [len : i64]) : String
  (stdlib.string.substring-borrowed (& text) start len))

;: Borrowed alias for `substring-borrowed`.
(define (string-slice-borrowed [text : (& text str)] [start : i64] [len : i64]) : String
  (stdlib.string.substring-borrowed text start len))

;: Alias for `substring`.
(define (string-slice [text : String] [start : i64] [len : i64]) : String
  (stdlib.string.substring text start len))

;: Compare two chars for equality.
(define (char-eq [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;: Return true if the character is ASCII whitespace.
(define (is-char-whitespace [c : char]) : bool
  (if (stdlib.string.char-eq c #\space')
    true
    (if (stdlib.string.char-eq c #\tab')
      true
      (if (stdlib.string.char-eq c #\newline')
        true
        (stdlib.string.char-eq c #\return')))))

;: Compare two borrowed strings byte-for-byte without allocating.
(define (string-eq-borrowed [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    (if (not (= left-len right-len))
      false
      (unsafe
        (let
          [lp : (Ptr u8) (string-data left)]
          [rp : (Ptr u8) (string-data right)]
          (if (= (ptr->int lp) (ptr->int rp))
            true
            (let
              [lw : (Ptr i64) (ptr-cast lp : (Ptr i64))]
              [rw : (Ptr i64) (ptr-cast rp : (Ptr i64))]
              [words : i64 (shr left-len 3)]
              [i : i64 0]
              [same : bool true]
              (begin
                (while (and same (< i words))
                  (if (=
                    (ptr-read (ptr-offset lw i))
                    (ptr-read (ptr-offset rw i)))
                    (set! i (+ i 1))
                    (set! same false)))
                (if same
                  (let
                    [j : i64 (* words 8)]
                    (begin
                      (while (and same (< j left-len))
                        (if (=
                          (cast (ptr-read (ptr-offset lp j)) : i64)
                          (cast (ptr-read (ptr-offset rp j)) : i64))
                          (set! j (+ j 1))
                          (set! same false)))
                      same))
                  false)))))))))

;: Compare two owned strings byte-for-byte without allocating.
(define (string-eq [left : String] [right : String]) : bool
  (stdlib.string.string-eq-borrowed (& left) (& right)))

;: Alias for `string-eq`.
(define (string=? [left : String] [right : String]) : bool
  (stdlib.string.string-eq left right))

;: Parse a decimal integer from borrowed text using the legacy compatibility rules.
(define (string->int-borrowed [text : (& text str)]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [negative : bool false]
    [value : i64 0]
    (begin
      (if (if (> n 0)
        (stdlib.string.char-eq (string-ref text 0) #-')
        false)
        (begin
          (set! negative true)
          (set! i 1))
        unit)
      (while (< i n)
        (begin
          (set! value (+ (* value 10) (- (cast (string-ref text i) : i64) 48)))
          (set! i (+ i 1))))
      (if negative
        (- 0 value)
        value))))

;: Parse a decimal integer using the legacy `string->int` compatibility rules.
(define (string->int [text : String]) : i64
  (stdlib.string.string->int-borrowed (& text)))

;: Trim leading whitespace from borrowed text.
(define (string-trim-left [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (stdlib.string.is-char-whitespace (string-ref s i))
          (set! i (+ i 1))
          (set! done true)))
      (stdlib.string.substring-borrowed s i (- n i)))))

;: Trim trailing whitespace from borrowed text.
(define (string-trim-right [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 (- n 1)]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (stdlib.string.is-char-whitespace (string-ref s i))
          (set! i (- i 1))
          (set! done true)))
      (stdlib.string.substring-borrowed s 0 (+ i 1)))))

;: Trim whitespace from both ends of borrowed text.
(define (string-trim [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [start : i64 0]
    [end : i64 (- n 1)]
    [done-left : bool false]
    [done-right : bool false]
    (begin
      (while (and (not done-left) (< start n))
        (if (stdlib.string.is-char-whitespace (string-ref s start))
          (set! start (+ start 1))
          (set! done-left true)))
      (while (and (not done-right) (>= end start))
        (if (stdlib.string.is-char-whitespace (string-ref s end))
          (set! end (- end 1))
          (set! done-right true)))
      (stdlib.string.substring-borrowed s start (- (+ end 1) start)))))

;: Return true if haystack contains needle at any position.
(define (string-contains
  [haystack : (& haystack str)]
  [needle : (& needle str)]) : bool
  (let
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)]
    (if (= nlen 0)
      true
      (if (> nlen hlen)
        false
        (let
          [found : bool false]
          [i : i64 0]
          (begin
            (while (and (not found) (<= i (- hlen nlen)))
              (if (stdlib.string.is-string-prefix-at haystack needle i)
                (set! found true)
                (set! i (+ i 1))))
            found))))))

;: Return true if borrowed haystack contains the character c.
(define (string-contains-char [haystack : (& haystack str)] [c : char]) : bool
  (let
    [n : i64 (string-length haystack)]
    [found : bool false]
    [i : i64 0]
    (begin
      (while (and (not found) (< i n))
        (if (stdlib.string.char-eq (string-ref haystack i) c)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Replace first occurrence of old with new in s.
;:
;: Returns s unchanged if old is not present. Full multi-replace needs a string
;: builder.
(define (string-replace [s : String] [old : String] [new : String]) : String
  (let
    [hlen : i64 (string-length s)]
    [olen : i64 (string-length old)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (<= i (- hlen olen)))
        (let
          [j : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< j olen))
              (if (stdlib.string.char-eq
                (string-ref s (+ i j))
                (string-ref old j))
                (set! j (+ j 1))
                (set! ok false)))
            (if ok
              (set! found true)
              (set! i (+ i 1))))))
      (if found
        (begin
          (stdlib.string.string-append
            (stdlib.string.string-append (stdlib.string.substring s 0 i) new)
            (stdlib.string.substring s (+ i olen) (- (- hlen i) olen))))
        s))))

;: Return true if haystack has needle at position start.
(define (is-string-prefix-at
  [haystack : (& haystack str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start nlen) hlen)
        false
        (let
          [ok : bool true]
          [j : i64 0]
          (begin
            (while (and ok (< j nlen))
              (if (stdlib.string.char-eq
                (string-ref haystack (+ start j))
                (string-ref needle j))
                (set! j (+ j 1))
                (set! ok false)))
            ok))))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value tl_oob_abort)
  (value string-runtime-alloc)
  (value int->string-write-byte!)
  (value int->string-negative-digit-count)
  (value int->string-write-negative-digits!)
  (value int->string)
  (value substring-bounds-check)
  (value str-copy-bytes-into)
  (value substring-copy-checked)
  (value string-append-borrowed)
  (value string-copy-borrowed)
  (value string-concat-borrowed)
  (value string-append)
  (value string-concat)
  (value string-concat-all)
  (value string-concat-all-pack-part)
  (value string-concat3)
  (value string-concat4)
  (value string-concat5)
  (value substring-borrowed)
  (value substring)
  (value string-slice-borrowed)
  (value string-slice)
  (value is-char-whitespace)
  (value char-eq)
  (value string-eq-borrowed)
  (value string-eq)
  (value string=?)
  (value string->int-borrowed)
  (value string->int)
  (value string-trim-left)
  (value string-trim-right)
  (value string-trim)
  (value string-contains)
  (value string-contains-char)
  (value string-replace)
  (value is-string-prefix-at))