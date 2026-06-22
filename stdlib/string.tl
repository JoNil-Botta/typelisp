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
(module stdlib.string)

;: Runtime bounds-check trap shared with array/string indexing.
(extern (tl_oob_abort) : never)

;: Runtime helper that builds a borrowed string view record without copying
;: bytes. The public wrappers below perform bounds checks before calling it.
(cfg
  feature-str-view
  (unsafe
    (extern (tl_str_view [text : (& text str)] [start : i64] [len : i64]) : (&
      text
      str))))

;: Runtime active-arena allocator used by integer rendering.
(extern (string-runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;; Internal raw byte copy primitive backed by the always-emitted runtime helper.
;;
;; Caller contract: `n >= 0`; `src` points at at least `n` initialized readable
;; bytes; `dst` points at at least `n` writable bytes; and both ranges remain
;; live for the call. Overlap is allowed because `tl_memcpy` has memmove
;; semantics for the `dst > src` case.
(unsafe
  (extern (string-runtime-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [n : i64]) : unit (:symbol "tl_memcpy")))

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
          (int->string-write-byte! dst (+ base index) (+ 48 digit))
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
    [digits : i64 (int->string-negative-digit-count magnitude)]
    [len : i64
      (if negative
        (+ digits 1)
        digits)]
    [buf : (MutPtr u8) (string-runtime-alloc len)]
    (begin
      (if negative
        (int->string-write-byte! buf 0 45)
        unit)
      (int->string-write-negative-digits!
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
    (cond
      [(< start 0) (tl_oob_abort)]
      [(< len 0) (tl_oob_abort)]
      [(> start n) (tl_oob_abort)]
      [else
        (let
          [remaining : i64 (- n start)]
          (if (> len remaining)
            (tl_oob_abort)
            unit))])))

;: Copy `n` initialized bytes from `src` into `dst` at byte offset `doff`.
;:
;: This is a stdlib-internal raw-pointer helper. Callers must uphold the
;: `string-runtime-copy-bytes!` range contract above.
(define (str-copy-bytes-into
  [src : (Ptr u8)]
  [dst : (MutPtr u8)]
  [doff : i64]
  [n : i64]) : unit
  (unsafe
    (string-runtime-copy-bytes! (ptr-offset dst doff) src n)))

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
      (str-copy-bytes-into
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
      (str-copy-bytes-into left-src dst 0 left-len)
      (str-copy-bytes-into right-src dst left-len right-len)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))

;: Return a fresh active-arena copy of borrowed text.
(define (string-copy-borrowed [text : (& text str)]) : String
  (substring-borrowed text 0 (string-length text)))

;: Borrowed alias for `string-append-borrowed`.
(define (string-concat-borrowed [left : (& left str)] [right : (& right str)]) : String
  (string-append-borrowed left right))

;: Return a fresh active-arena String by concatenating two owned strings.
(define (string-append [left : String] [right : String]) : String
  (string-append-borrowed (& left) (& right)))

;: Alias for `string-append`.
(define (string-concat [left : String] [right : String]) : String
  (string-append left right))

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
                (str-copy-bytes-into
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
  (string-concat5 a b c "" ""))

;: Return a fresh active-arena String by concatenating four owned strings.
(define (string-concat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-concat5 a b c d ""))

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
      (str-copy-bytes-into
        (unsafe
          (string-data (& a)))
        dst
        off
        a-len)
      (set! off (+ off a-len))
      (str-copy-bytes-into
        (unsafe
          (string-data (& b)))
        dst
        off
        b-len)
      (set! off (+ off b-len))
      (str-copy-bytes-into
        (unsafe
          (string-data (& c)))
        dst
        off
        c-len)
      (set! off (+ off c-len))
      (str-copy-bytes-into
        (unsafe
          (string-data (& d)))
        dst
        off
        d-len)
      (set! off (+ off d-len))
      (str-copy-bytes-into
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
    (substring-bounds-check text start len)
    (substring-copy-checked text start len)))

;: Return a checked borrowed substring view without copying bytes.
(cfg
  feature-str-view
  (define (substring-view [text : (& text str)] [start : i64] [len : i64]) : (&
      text
      str)
    (begin
      (substring-bounds-check text start len)
      (unsafe
        (tl_str_view text start len)))))

;: Return a fresh active-arena owned substring copied from owned text.
(define (substring [text : String] [start : i64] [len : i64]) : String
  (substring-borrowed (& text) start len))

;: Borrowed alias for `substring-borrowed`.
(define (string-slice-borrowed [text : (& text str)] [start : i64] [len : i64]) : String
  (substring-borrowed text start len))

;: Borrowed alias for `substring-view`.
(cfg
  feature-str-view
  (define (string-slice-view [text : (& text str)] [start : i64] [len : i64]) : (&
      text
      str)
    (substring-view text start len)))

;: Alias for `substring`.
(define (string-slice [text : String] [start : i64] [len : i64]) : String
  (substring text start len))

;: Compare two chars for equality.
(define (char-eq [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;: Return true if the character is ASCII whitespace.
(define (is-char-whitespace [c : char]) : bool
  (cond
    [(char-eq c ' ') true]
    [(char-eq c '\t') true]
    [(char-eq c '\n') true]
    [else (char-eq c '\r')]))

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
  (string-eq-borrowed (& left) (& right)))

;: Alias for `string-eq`.
(define (string=? [left : String] [right : String]) : bool
  (string-eq left right))

;: Parse a decimal integer from borrowed text using the legacy compatibility rules.
(define (string->int-borrowed [text : (& text str)]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [negative : bool false]
    [value : i64 0]
    (begin
      (if (if (> n 0)
        (char-eq (string-ref text 0) '-')
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
  (string->int-borrowed (& text)))

;: Return a borrowed view of text with leading whitespace removed.
(cfg
  feature-str-view
  (define (string-trim-left-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (string-length s)]
      [i : i64 0]
      [done : bool false]
      (begin
        (while (and (not done) (< i n))
          (if (is-char-whitespace (string-ref s i))
            (set! i (+ i 1))
            (set! done true)))
        (substring-view s i (- n i))))))

;: Trim leading whitespace from borrowed text.
(define (string-trim-left [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (is-char-whitespace (string-ref s i))
          (set! i (+ i 1))
          (set! done true)))
      (substring-borrowed s i (- n i)))))

;: Return a borrowed view of text with trailing whitespace removed.
(cfg
  feature-str-view
  (define (string-trim-right-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (string-length s)]
      [i : i64 (- n 1)]
      [done : bool false]
      (begin
        (while (and (not done) (>= i 0))
          (if (is-char-whitespace (string-ref s i))
            (set! i (- i 1))
            (set! done true)))
        (substring-view s 0 (+ i 1))))))

;: Trim trailing whitespace from borrowed text.
(define (string-trim-right [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 (- n 1)]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (is-char-whitespace (string-ref s i))
          (set! i (- i 1))
          (set! done true)))
      (substring-borrowed s 0 (+ i 1)))))

;: Return a borrowed view of text with leading and trailing whitespace removed.
(cfg
  feature-str-view
  (define (string-trim-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (string-length s)]
      [start : i64 0]
      [end : i64 (- n 1)]
      [done-left : bool false]
      [done-right : bool false]
      (begin
        (while (and (not done-left) (< start n))
          (if (is-char-whitespace (string-ref s start))
            (set! start (+ start 1))
            (set! done-left true)))
        (while (and (not done-right) (>= end start))
          (if (is-char-whitespace (string-ref s end))
            (set! end (- end 1))
            (set! done-right true)))
        (substring-view s start (- (+ end 1) start))))))

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
        (if (is-char-whitespace (string-ref s start))
          (set! start (+ start 1))
          (set! done-left true)))
      (while (and (not done-right) (>= end start))
        (if (is-char-whitespace (string-ref s end))
          (set! end (- end 1))
          (set! done-right true)))
      (substring-borrowed s start (- (+ end 1) start)))))

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
              (if (is-string-prefix-at haystack needle i)
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
        (if (char-eq (string-ref haystack i) c)
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
              (if (char-eq (string-ref s (+ i j)) (string-ref old j))
                (set! j (+ j 1))
                (set! ok false)))
            (if ok
              (set! found true)
              (set! i (+ i 1))))))
      (if found
        (begin
          (string-append
            (string-append (substring s 0 i) new)
            (substring s (+ i olen) (- (- hlen i) olen))))
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
              (if (char-eq
                (string-ref haystack (+ start j))
                (string-ref needle j))
                (set! j (+ j 1))
                (set! ok false)))
            ok))))))

(test
  string-borrowed-str-gate
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [input : String "borrowed"]
    [view : (& input str) (& input)]
    (if (= (string-length view) (string-length input))
      unit
      (fail))))

(test
  string-scoped-arena-allocation-policy
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    (with-arena
      outer
      (let
        [s : String "  outer  "]
        [outer-trimmed : String (stdlib.string.string-trim (& s))]
        [outer-slice : String (stdlib.string.substring-borrowed (& s) 2 5)]
        [outer-suffix : String "-append"]
        [outer-appended : String
          (stdlib.string.string-append-borrowed
            (& outer-trimmed)
            (& outer-suffix))]
        [outer-number : String (stdlib.string.int->string 12345)]
        [outer-expected : String "outer"]
        [outer-appended-expected : String "outer-append"]
        [outer-number-expected : String "12345"]
        (begin
          (if (stdlib.string.string-eq-borrowed
            (& outer-trimmed)
            (& outer-expected))
            unit
            (fail))
          (if (stdlib.string.string-eq-borrowed
            (& outer-slice)
            (& outer-expected))
            unit
            (fail))
          (if (stdlib.string.string-eq-borrowed
            (& outer-appended)
            (& outer-appended-expected))
            unit
            (fail))
          (if (stdlib.string.string-eq-borrowed
            (& outer-number)
            (& outer-number-expected))
            unit
            (fail))
          (with-arena
            inner
            (let
              [inner-replaced : String
                (stdlib.string.string-replace "alpha" "ph" "ren")]
              [inner-slice : String (stdlib.string.string-slice "alphabet" 2 3)]
              [inner-appended : String
                (stdlib.string.string-append "inner" "-append")]
              [inner-concat : String
                (stdlib.string.string-concat "inner" "-concat")]
              [inner-number : String (stdlib.string.int->string -6789)]
              [inner-borrowed : String
                (stdlib.string.string-append-borrowed
                  (& inner-slice)
                  (& inner-replaced))]
              [inner-replaced-expected : String "alrena"]
              [inner-slice-expected : String "pha"]
              [inner-appended-expected : String "inner-append"]
              [inner-concat-expected : String "inner-concat"]
              [inner-number-expected : String "-6789"]
              [inner-borrowed-expected : String "phaalrena"]
              (begin
                (if (stdlib.string.string-eq-borrowed
                  (& inner-replaced)
                  (& inner-replaced-expected))
                  unit
                  (fail))
                (if (stdlib.string.string-eq-borrowed
                  (& inner-slice)
                  (& inner-slice-expected))
                  unit
                  (fail))
                (if (stdlib.string.string-eq-borrowed
                  (& inner-appended)
                  (& inner-appended-expected))
                  unit
                  (fail))
                (if (stdlib.string.string-eq-borrowed
                  (& inner-concat)
                  (& inner-concat-expected))
                  unit
                  (fail))
                (if (stdlib.string.string-eq-borrowed
                  (& inner-number)
                  (& inner-number-expected))
                  unit
                  (fail))
                (if (stdlib.string.string-eq-borrowed
                  (& inner-borrowed)
                  (& inner-borrowed-expected))
                  unit
                  (fail))
                (if (= (string-length outer-trimmed) 5)
                  unit
                  (fail))
                (if (= (string-length outer-appended) 12)
                  unit
                  (fail))
                (if (= (string-length outer-number) 5)
                  unit
                  (fail))))))))))

;; Inline coverage migrated from stdlib/tests/string_edges.tl (#3082).
(cfg test (import stdlib.test))

(cfg
  test
  (define (string-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (string-test-trim-left [s : String]) : String
    (string-trim-left (& s))))

(cfg
  test
  (define (string-test-trim-right [s : String]) : String
    (string-trim-right (& s))))

(cfg
  test
  (define (string-test-trim [s : String]) : String
    (string-trim (& s))))

(cfg
  test
  (define (string-test-contains [haystack : String] [needle : String]) : bool
    (string-contains (& haystack) (& needle))))

(cfg
  test
  (define (string-test-contains-char [haystack : String] [c : char]) : bool
    (string-contains-char (& haystack) c)))

(cfg
  test
  (define (string-test-eq-borrowed [left : String] [right : String]) : bool
    (string-eq-borrowed (& left) (& right))))

(cfg
  test
  (define (string-test-to-int-borrowed [text : String]) : i64
    (string->int-borrowed (& text))))

(cfg
  test
  (define (string-test-copy-borrowed [text : String]) : String
    (string-copy-borrowed (& text))))

(cfg
  test
  (define (string-test-append-borrowed [left : String] [right : String]) : String
    (string-append-borrowed (& left) (& right))))

(cfg
  test
  (define (string-test-concat-borrowed [left : String] [right : String]) : String
    (string-concat-borrowed (& left) (& right))))

(cfg
  test
  (define (string-test-concat-all-empty) : String
    (string-concat-all (make-array String 0))))

(cfg
  test
  (define (string-test-concat-all-many) : String
    (let
      [parts : (Array String) (make-array String 6)]
      (begin
        (array-set! parts 0 "ab")
        (array-set! parts 1 "")
        (array-set! parts 2 "cd")
        (array-set! parts 3 "ef")
        (array-set! parts 4 "")
        (array-set! parts 5 "gh")
        (string-concat-all parts)))))

(cfg
  test
  (define (string-test-substring-borrowed
    [text : String]
    [start : i64]
    [len : i64]) : String
    (substring-borrowed (& text) start len)))

(cfg
  test
  (define (string-test-slice-borrowed [text : String] [start : i64] [len : i64]) : String
    (string-slice-borrowed (& text) start len)))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-substring-view-eq
      [text : String]
      [start : i64]
      [len : i64]
      [expected : String]) : bool
      (string-eq-borrowed (substring-view (& text) start len) (& expected)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-substring-view-len
      [text : String]
      [start : i64]
      [len : i64]) : i64
      (string-length (substring-view (& text) start len)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-slice-view-eq
      [text : String]
      [start : i64]
      [len : i64]
      [expected : String]) : bool
      (string-eq-borrowed (string-slice-view (& text) start len) (& expected)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-trim-left-view-eq [s : String] [expected : String]) : bool
      (string-eq-borrowed (string-trim-left-view (& s)) (& expected)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-trim-right-view-eq [s : String] [expected : String]) : bool
      (string-eq-borrowed (string-trim-right-view (& s)) (& expected)))))

(cfg
  test
  (cfg
    feature-str-view
    (define (string-test-trim-view-eq [s : String] [expected : String]) : bool
      (string-eq-borrowed (string-trim-view (& s)) (& expected)))))

(cfg
  test
  (define (string-test-prefix-at
    [haystack : String]
    [needle : String]
    [start : i64]) : bool
    (is-string-prefix-at (& haystack) (& needle) start)))

(cfg
  test
  (define (string-test-main) : i64
    (begin
      (test.assert-true (is-char-whitespace ' ') "space is whitespace")
      (test.assert-true (is-char-whitespace '\t') "tab is whitespace")
      (test.assert-true (is-char-whitespace '\n') "newline is whitespace")
      (test.assert-true (is-char-whitespace '\r') "return is whitespace")
      (test.assert-false (is-char-whitespace 'A') "letter is not whitespace")
      (test.assert-true (char-eq 'A' 'A') "same chars compare equal")
      (test.assert-false
        (char-eq 'A' 'B')
        "different chars do not compare equal")
      (test.assert-true (string-eq "" "") "empty strings compare equal")
      (test.assert-true
        (string-eq "hello" "hello")
        "same strings compare equal")
      (test.assert-true
        (string=? "alias" (string-append "ali" "as"))
        "string=? aliases string-eq")
      (string-test-assert-owned-string-eq
        (string-append "" "")
        ""
        "string-append handles two empty strings")
      (string-test-assert-owned-string-eq
        (string-append "" "right")
        "right"
        "string-append handles empty left")
      (string-test-assert-owned-string-eq
        (string-append "left" "")
        "left"
        "string-append handles empty right")
      (string-test-assert-owned-string-eq
        (string-append "foo" "bar")
        "foobar"
        "string-append concatenates short strings")
      (string-test-assert-owned-string-eq
        (string-append
          "abcdefghijklmnopqrstuvwxyz"
          "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "string-append concatenates long strings")
      (string-test-assert-owned-string-eq
        (string-concat "con" "cat")
        "concat"
        "string-concat aliases string-append")
      (string-test-assert-owned-string-eq
        (string-test-concat-all-empty)
        ""
        "string-concat-all handles an empty parts array")
      (string-test-assert-owned-string-eq
        (string-test-concat-all-many)
        "abcdefgh"
        "string-concat-all concatenates many parts")
      (string-test-assert-owned-string-eq
        (string-concat3 "a" "b" "c")
        "abc"
        "string-concat3 concatenates three strings")
      (string-test-assert-owned-string-eq
        (string-concat4 "a" "b" "c" "d")
        "abcd"
        "string-concat4 concatenates four strings")
      (string-test-assert-owned-string-eq
        (string-concat5 "a" "b" "c" "d" "e")
        "abcde"
        "string-concat5 concatenates five strings")
      (string-test-assert-owned-string-eq
        (string-test-copy-borrowed "borrow-copy")
        "borrow-copy"
        "string-copy-borrowed copies borrowed text")
      (string-test-assert-owned-string-eq
        (string-test-append-borrowed "bor" "row")
        "borrow"
        "string-append-borrowed concatenates borrowed inputs")
      (string-test-assert-owned-string-eq
        (string-test-concat-borrowed "" "borrowed")
        "borrowed"
        "string-concat-borrowed handles empty borrowed input")
      (test.assert-false (string-eq "hello" "world") "different strings differ")
      (test.assert-false (string-eq "hi" "high") "length mismatch differs")
      (test.assert-true
        (string-test-eq-borrowed "borrow" (string-append "bor" "row"))
        "borrowed string equality compares contents")
      (test.assert-false
        (string-test-eq-borrowed "borrow" "borrows")
        "borrowed string equality rejects length mismatch")
      (test.assert-i64-eq (string->int "") 0 "empty string parses as zero")
      (test.assert-i64-eq
        (string->int "-")
        0
        "minus-only string parses as zero")
      (test.assert-i64-eq (string->int "123") 123 "positive integer parses")
      (test.assert-i64-eq (string->int "-42") -42 "negative integer parses")
      (test.assert-i64-eq
        (string-test-to-int-borrowed "12a")
        169
        "borrowed parser keeps legacy non-digit arithmetic")
      (string-test-assert-owned-string-eq
        (int->string 0)
        "0"
        "int->string renders zero")
      (string-test-assert-owned-string-eq
        (int->string 123456789)
        "123456789"
        "int->string renders positive values")
      (string-test-assert-owned-string-eq
        (int->string -42)
        "-42"
        "int->string renders negative values")
      (string-test-assert-owned-string-eq
        (int->string 9223372036854775807)
        "9223372036854775807"
        "int->string renders i64 max")
      (string-test-assert-owned-string-eq
        (int->string (- (- 0 9223372036854775807) 1))
        "-9223372036854775808"
        "int->string renders i64 min")
      (string-test-assert-owned-string-eq
        (substring "abcdef" 2 3)
        "cde"
        "public substring copies middle slice")
      (string-test-assert-owned-string-eq
        (string-slice "abcdef" 6 0)
        ""
        "public string-slice copies empty boundary slice")
      (string-test-assert-owned-string-eq
        (string-test-substring-borrowed "abcdef" 0 6)
        "abcdef"
        "borrowed substring copies full slice")
      (string-test-assert-owned-string-eq
        (string-test-slice-borrowed "abcdef" 5 1)
        "f"
        "borrowed string-slice copies final byte")
      (string-test-assert-owned-string-eq
        (string-test-substring-borrowed
          "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          10
          40)
        "klmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN"
        "borrowed substring copies long slice")
      (cfg
        feature-str-view
        (begin
          (test.assert-true
            (string-test-substring-view-eq "abcdef" 2 3 "cde")
            "substring-view borrows middle slice")
          (test.assert-i64-eq
            (string-test-substring-view-len "abcdef" 6 0)
            0
            "substring-view borrows empty boundary slice")
          (test.assert-true
            (string-test-slice-view-eq "abcdef" 5 1 "f")
            "string-slice-view aliases borrowed substring view"))
        unit)
      (string-test-assert-owned-string-eq
        (string-test-trim-left "  hello")
        "hello"
        "trim-left removes leading spaces")
      (string-test-assert-owned-string-eq
        (string-test-trim-left "")
        ""
        "trim-left handles empty strings")
      (string-test-assert-owned-string-eq
        (string-test-trim-right "hello  ")
        "hello"
        "trim-right removes trailing spaces")
      (string-test-assert-owned-string-eq
        (string-test-trim-right "   ")
        ""
        "trim-right handles all-space strings")
      (string-test-assert-owned-string-eq
        (string-test-trim "  hello  ")
        "hello"
        "trim removes both sides")
      (string-test-assert-owned-string-eq
        (string-test-trim "")
        ""
        "trim handles empty strings")
      (cfg
        feature-str-view
        (begin
          (test.assert-true
            (string-test-trim-left-view-eq "  hello" "hello")
            "trim-left-view removes leading spaces")
          (test.assert-true
            (string-test-trim-right-view-eq "hello  " "hello")
            "trim-right-view removes trailing spaces")
          (test.assert-true
            (string-test-trim-view-eq "  hello  " "hello")
            "trim-view removes both sides")
          (test.assert-true
            (string-test-trim-view-eq "   " "")
            "trim-view handles all-space strings"))
        unit)
      (test.assert-true
        (string-test-contains "hello" "ell")
        "contains finds middle needle")
      (test.assert-true
        (string-test-contains "hello" "")
        "contains accepts empty needle")
      (test.assert-false
        (string-test-contains "hello" "world")
        "contains reports miss")
      (test.assert-false
        (string-test-contains "hi" "hello")
        "contains rejects too-long needle")
      (test.assert-true
        (string-test-contains-char "hello" 'e')
        "contains-char finds char")
      (test.assert-false
        (string-test-contains-char "hello" 'z')
        "contains-char reports miss")
      (test.assert-false
        (string-test-contains-char "" 'z')
        "contains-char handles empty string")
      (string-test-assert-owned-string-eq
        (string-replace "hello" "ell" "ipp")
        "hippo"
        "replace middle")
      (string-test-assert-owned-string-eq
        (string-replace "hello" "he" "ye")
        "yello"
        "replace prefix")
      (string-test-assert-owned-string-eq
        (string-replace "hello" "lo" "p")
        "help"
        "replace suffix")
      (string-test-assert-owned-string-eq
        (string-replace "hello" "zz" "yy")
        "hello"
        "replace miss returns input")
      (string-test-assert-owned-string-eq
        (string-replace "abc" "" "x")
        "xabc"
        "replace empty needle prefixes")
      (test.assert-true
        (string-test-prefix-at "hello" "he" 0)
        "prefix at start")
      (test.assert-true
        (string-test-prefix-at "hello" "ll" 2)
        "prefix in middle")
      (test.assert-true
        (string-test-prefix-at "hello" "" 5)
        "empty prefix at end")
      (test.assert-false
        (string-test-prefix-at "hello" "he" -1)
        "negative prefix position")
      (test.assert-false
        (string-test-prefix-at "hello" "hello!" 0)
        "too-long prefix")
      (test.assert-false
        (string-test-prefix-at "hello" "lo" 4)
        "prefix past end")
      42)))

(cfg
  test
  (test
    string-api-edges
    (test.assert-i64-eq (string-test-main) 42 "string-api-edges fixture result")))

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