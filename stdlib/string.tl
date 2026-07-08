;# String utility library for TypeLisp.
;#
;# Provides string operations built on compiler/runtime primitives. New
;# compilers enable `feature-private-string-intrinsics`, where public helpers
;# route through `__tl_string_length`, `__tl_string_ref`, `__tl_string_eq`, and
;# `__tl_string_to_int`. The `feature-compiler-private-string-intrinsics`
;# capability means the compiling seed can typecheck those private names; without
;# it, the checked-in stdlib stays bootstrap-compatible with published stage0.
;#
;# Usage: `(import stdlib.string)`
;#
;# ```typelisp
;# (import stdlib.string)
;# (define ok : bool
;#   (let
;#     [s : String "  alpha  "]
;#     [haystack : String (string.trim-left (& s))]
;#     [needle : String "ph"]
;#     (string.contains (& haystack) (& needle))))
;# ```
(import stdlib.array)
(import stdlib.comptime)

;: Runtime bounds-check trap shared with array/string indexing.
(extern (tl_oob_abort) : never)

;: Runtime helper that builds a borrowed string view record without copying
;: bytes. The public wrappers below perform bounds checks before calling it.
;: `feature-runtime-str-view-extern` keeps published stage0 compilers from
;: declaring this extern before they understand the renamed stdlib.runtime
;: helper as the same fixed ABI symbol.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
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

;; Internal raw byte-search primitive backed by the always-emitted runtime
;; helper. Returns the zero-based offset in `ptr[0..len)` or -1 when absent.
(cfg
  feature-tl-memchr
  (unsafe
    (extern (string-runtime-index-of-byte
      [ptr : (Ptr u8)]
      [len : i64]
      [byte : u8]) : i64 (:symbol "tl_memchr"))))

;: Bootstrap compatibility aliases for compiler sources that call private
;: intrinsics directly. Published stage0 compilers only have the legacy public
;: primitive names, so map the private spellings back until the compiler
;: capability cfg is enabled.
(cfg
  (not feature-compiler-private-string-intrinsics)
  (defmacro (__tl_string_length [text : comptime.Expr]) : i64
    `(string-length ,text)))

(cfg
  (not feature-compiler-private-string-intrinsics)
  (defmacro (__tl_string_ref [text : comptime.Expr] [index : comptime.Expr]) : char
    `(string-ref ,text ,index)))

(cfg
  (not feature-compiler-private-string-intrinsics)
  (defmacro (__tl_string_eq [left : comptime.Expr] [right : comptime.Expr]) : bool
    `(eq ,left ,right)))

(cfg
  (not feature-compiler-private-string-intrinsics)
  (defmacro (__tl_string_to_int [text : comptime.Expr]) : i64
    `(>int ,text)))

;: Return the byte length of borrowed or owned text without allocating.
(cfg
  feature-compiler-private-string-intrinsics
  (define (string-length [text : (& text str)]) : i64
    (__tl_string_length text)))

;: Read one byte from borrowed or owned text as a `char` with bounds checking.
(cfg
  feature-compiler-private-string-intrinsics
  (define (string-ref [text : (& text str)] [index : i64]) : char
    (__tl_string_ref text index)))

;: Alias for `string-ref`.
(cfg
  feature-compiler-private-string-intrinsics
  (define (char-at [text : (& text str)] [index : i64]) : char
    (__tl_string_ref text index)))

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
    [n : i64 (__tl_string_length text)]
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

;: Copy `n` bytes from owned `chunk` into `dst` at byte offset `start`.
(define (str-copy-owned-bytes-into
  [chunk : String]
  [dst : (MutPtr u8)]
  [start : i64]
  [n : i64]) : unit
  (let
    [src : (Ptr u8)
      (unsafe
        (string-data (& chunk)))]
    [words : i64 (/ n 8)]
    [src64 : (Ptr i64)
      (unsafe
        (ptr-cast src : (Ptr i64)))]
    [dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset dst start) : (MutPtr i64)))]
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
              (ptr-offset dst (+ start b))
              (ptr-read (ptr-offset src b))))
          (set! b (+ b 1))))
      unit)))

;: Copy a checked borrowed byte range into a fresh active-arena String.
(define (substring-copy-checked [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [buf : (Array u8) (array.make-array u8 len)]
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
(define (append [left : (& left str)] [right : (& right str)]) : String
  (let
    [left-len : i64 (__tl_string_length left)]
    [right-len : i64 (__tl_string_length right)]
    [total-len : i64 (+ left-len right-len)]
    [buf : (Array u8) (array.make-array u8 total-len)]
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
(define (copy [text : (& text str)]) : String
  (substring text 0 (__tl_string_length text)))

;: Alias for `append`.
(define (concat [left : (& left str)] [right : (& right str)]) : String
  (append left right))

;: Return a fresh active-arena String by concatenating all owned strings in order.
(define (concat-all [parts : (Array String)]) : String
  (let
    [count : i64 (array-length parts)]
    [len-index : i64 0]
    [total-len : i64 0]
    (begin
      (while (< len-index count)
        (let
          [part : String (array-ref parts len-index)]
          (begin
            (set! total-len (+ total-len (__tl_string_length part)))
            (set! len-index (+ len-index 1)))))
      (let
        [buf : (Array u8) (array.make-array u8 total-len)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data buf))]
        [copy-index : i64 0]
        [off : i64 0]
        (begin
          (while (< copy-index count)
            (let
              [part : String (array-ref parts copy-index)]
              [len : i64 (__tl_string_length part)]
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
(define (concat-all-pack-part
  [parts : (Array String)]
  [index : i64]
  [value : String]) : (Array String)
  (begin
    (array-set! parts index value)
    parts))

;: Return a fresh active-arena String by concatenating three owned strings.
(define (concat3 [a : String] [b : String] [c : String]) : String
  (let
    [a-len : i64 (__tl_string_length a)]
    [b-len : i64 (__tl_string_length b)]
    [c-len : i64 (__tl_string_length c)]
    [total-len : i64 (+ a-len (+ b-len c-len))]
    (if (= total-len 0)
      ""
      (let
        [buf : (Array u8) (array.make-array u8 total-len)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data buf))]
        (begin
          (str-copy-owned-bytes-into a dst 0 a-len)
          (str-copy-owned-bytes-into b dst a-len b-len)
          (str-copy-owned-bytes-into c dst (+ a-len b-len) c-len)
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))))

;: Return a fresh active-arena String by concatenating four owned strings.
(define (concat4 [a : String] [b : String] [c : String] [d : String]) : String
  (let
    [a-len : i64 (__tl_string_length a)]
    [b-len : i64 (__tl_string_length b)]
    [c-len : i64 (__tl_string_length c)]
    [d-len : i64 (__tl_string_length d)]
    [total-len : i64 (+ a-len (+ b-len (+ c-len d-len)))]
    (if (= total-len 0)
      ""
      (let
        [buf : (Array u8) (array.make-array u8 total-len)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data buf))]
        (begin
          (str-copy-owned-bytes-into a dst 0 a-len)
          (str-copy-owned-bytes-into b dst a-len b-len)
          (str-copy-owned-bytes-into c dst (+ a-len b-len) c-len)
          (str-copy-owned-bytes-into d dst (+ a-len (+ b-len c-len)) d-len)
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))))

;: Return a fresh active-arena String by concatenating five owned strings.
(define (concat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (let
    [a-len : i64 (__tl_string_length a)]
    [b-len : i64 (__tl_string_length b)]
    [c-len : i64 (__tl_string_length c)]
    [d-len : i64 (__tl_string_length d)]
    [e-len : i64 (__tl_string_length e)]
    [total-len : i64 (+ a-len (+ b-len (+ c-len (+ d-len e-len))))]
    (if (= total-len 0)
      ""
      (let
        [buf : (Array u8) (array.make-array u8 total-len)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data buf))]
        (begin
          (str-copy-owned-bytes-into a dst 0 a-len)
          (str-copy-owned-bytes-into b dst a-len b-len)
          (str-copy-owned-bytes-into c dst (+ a-len b-len) c-len)
          (str-copy-owned-bytes-into d dst (+ a-len (+ b-len c-len)) d-len)
          (str-copy-owned-bytes-into
            e
            dst
            (+ a-len (+ b-len (+ c-len d-len)))
            e-len)
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total-len)))))))

;: Stage0 bootstrap compatibility for str-cat fast-path output.
;; lint-allow: redundant-function-name
(define (string-concat-all [parts : (Array String)]) : String
  (concat-all parts))

;: Stage0 bootstrap compatibility for str-cat fast-path output.
;; lint-allow: redundant-function-name
(define (string-concat-all-pack-part
  [parts : (Array String)]
  [index : i64]
  [value : String]) : (Array String)
  (concat-all-pack-part parts index value))

;: Stage0 bootstrap compatibility for str-cat fast-path output.
;; lint-allow: redundant-function-name
(define (string-concat3 [a : String] [b : String] [c : String]) : String
  (concat3 a b c))

;: Stage0 bootstrap compatibility for str-cat fast-path output.
;; lint-allow: redundant-function-name
(define (string-concat4 [a : String] [b : String] [c : String] [d : String]) : String
  (concat4 a b c d))

;: Stage0 bootstrap compatibility for str-cat fast-path output.
;; lint-allow: redundant-function-name
(define (string-concat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (concat5 a b c d e))

;: Return a fresh active-arena owned substring copied from borrowed text.
(define (substring [text : (& text str)] [start : i64] [len : i64]) : String
  (begin
    (substring-bounds-check text start len)
    (substring-copy-checked text start len)))

;: Return a checked borrowed substring view without copying bytes.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
  (define (substring-view [text : (& text str)] [start : i64] [len : i64]) : (&
      text
      str)
    (begin
      (substring-bounds-check text start len)
      (unsafe
        (tl_str_view text start len)))))

;: Borrowed alias for `substring-view`.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
  (define (slice-view [text : (& text str)] [start : i64] [len : i64]) : (&
      text
      str)
    (substring-view text start len)))

;: Alias for `substring`.
(define (slice [text : (& text str)] [start : i64] [len : i64]) : String
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

;: Return the first byte index at or after start, or -1 when absent.
(cfg
  feature-tl-memchr
  (define (index-of-byte [text : (& text str)] [start : i64] [byte : u8]) : i64
    (let
      [n : i64 (__tl_string_length text)]
      (if (or (< start 0) (>= start n))
        -1
        (let
          [offset : i64
            (unsafe
              (string-runtime-index-of-byte
                (ptr-offset (string-data text) start)
                (- n start)
                byte))]
          (if (< offset 0)
            -1
            (+ start offset)))))))

;: Return the first byte index at or after start, or -1 when absent.
(cfg
  (not feature-tl-memchr)
  (define (index-of-byte [text : (& text str)] [start : i64] [byte : u8]) : i64
    (let
      [n : i64 (__tl_string_length text)]
      [i : i64 start]
      [found : i64 -1]
      [done : bool false]
      (begin
        (if (or (< start 0) (>= start n))
          (set! done true)
          unit)
        (while (not done)
          (if (< i n)
            (if (= (cast (__tl_string_ref text i) : u8) byte)
              (begin
                (set! found i)
                (set! done true))
              (set! i (+ i 1)))
            (set! done true)))
        found))))

;: Compare two borrowed strings byte-for-byte without allocating.
(define (eq [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-len : i64 (__tl_string_length left)]
    [right-len : i64 (__tl_string_length right)]
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

;: Alias for `eq`.
(define (string=? [left : (& left str)] [right : (& right str)]) : bool
  (eq left right))

;: Parse a decimal integer from borrowed text using the legacy compatibility rules.
(define (>int [text : (& text str)]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_to_int text)
    (let
      [n : i64 (string-length text)]
      [i : i64 0]
      [negative : bool false]
      [value : i64 0]
      (begin
        (if (and (> n 0) (= (cast (string-ref text 0) : i64) 45))
          (begin
            (set! negative true)
            (set! i 1))
          unit)
        (while (< i n)
          (begin
            (set!
              value
              (+ (* value 10) (- (cast (string-ref text i) : i64) 48)))
            (set! i (+ i 1))))
        (if negative
          (- 0 value)
          value)))))

;: Return a borrowed view of text with leading whitespace removed.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
  (define (trim-left-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (__tl_string_length s)]
      [i : i64 0]
      [done : bool false]
      (begin
        (while (and (not done) (< i n))
          (if (is-char-whitespace (__tl_string_ref s i))
            (set! i (+ i 1))
            (set! done true)))
        (substring-view s i (- n i))))))

;: Trim leading whitespace from borrowed text.
(define (trim-left [s : (& s str)]) : String
  (let
    [n : i64 (__tl_string_length s)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (is-char-whitespace (__tl_string_ref s i))
          (set! i (+ i 1))
          (set! done true)))
      (substring s i (- n i)))))

;: Return a borrowed view of text with trailing whitespace removed.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
  (define (trim-right-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (__tl_string_length s)]
      [i : i64 (- n 1)]
      [done : bool false]
      (begin
        (while (and (not done) (>= i 0))
          (if (is-char-whitespace (__tl_string_ref s i))
            (set! i (- i 1))
            (set! done true)))
        (substring-view s 0 (+ i 1))))))

;: Trim trailing whitespace from borrowed text.
(define (trim-right [s : (& s str)]) : String
  (let
    [n : i64 (__tl_string_length s)]
    [i : i64 (- n 1)]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (is-char-whitespace (__tl_string_ref s i))
          (set! i (- i 1))
          (set! done true)))
      (substring s 0 (+ i 1)))))

;: Return a borrowed view of text with leading and trailing whitespace removed.
(cfg
  (all feature-str-view feature-runtime-str-view-extern)
  (define (trim-view [s : (& s str)]) : (& s str)
    (let
      [n : i64 (__tl_string_length s)]
      [start : i64 0]
      [end : i64 (- n 1)]
      [done-left : bool false]
      [done-right : bool false]
      (begin
        (while (and (not done-left) (< start n))
          (if (is-char-whitespace (__tl_string_ref s start))
            (set! start (+ start 1))
            (set! done-left true)))
        (while (and (not done-right) (>= end start))
          (if (is-char-whitespace (__tl_string_ref s end))
            (set! end (- end 1))
            (set! done-right true)))
        (substring-view s start (- (+ end 1) start))))))

;: Trim whitespace from both ends of borrowed text.
(define (trim [s : (& s str)]) : String
  (let
    [n : i64 (__tl_string_length s)]
    [start : i64 0]
    [end : i64 (- n 1)]
    [done-left : bool false]
    [done-right : bool false]
    (begin
      (while (and (not done-left) (< start n))
        (if (is-char-whitespace (__tl_string_ref s start))
          (set! start (+ start 1))
          (set! done-left true)))
      (while (and (not done-right) (>= end start))
        (if (is-char-whitespace (__tl_string_ref s end))
          (set! end (- end 1))
          (set! done-right true)))
      (substring s start (- (+ end 1) start)))))

;: Return true if haystack contains needle at any position.
(define (contains [haystack : (& haystack str)] [needle : (& needle str)]) : bool
  (let
    [hlen : i64 (__tl_string_length haystack)]
    [nlen : i64 (__tl_string_length needle)]
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
(define (contains-char [haystack : (& haystack str)] [c : char]) : bool
  (>= (index-of-byte haystack 0 (cast c : u8)) 0))

;: Replace first occurrence of old with new in s.
;:
;: Returns s unchanged if old is not present. Full multi-replace needs a string
;: builder.
(define (replace [s : String] [old : String] [new : String]) : String
  (let
    [hlen : i64 (__tl_string_length s)]
    [olen : i64 (__tl_string_length old)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (<= i (- hlen olen)))
        (let
          [j : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< j olen))
              (if (char-eq (__tl_string_ref s (+ i j)) (__tl_string_ref old j))
                (set! j (+ j 1))
                (set! ok false)))
            (if ok
              (set! found true)
              (set! i (+ i 1))))))
      (if found
        (concat3
          (substring s 0 i)
          new
          (substring s (+ i olen) (- (- hlen i) olen)))
        s))))

;: Return true if haystack has needle at position start.
(define (is-string-prefix-at
  [haystack : (& haystack str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [hlen : i64 (__tl_string_length haystack)]
    [nlen : i64 (__tl_string_length needle)]
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
                (__tl_string_ref haystack (+ start j))
                (__tl_string_ref needle j))
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
    (if (= (__tl_string_length view) (__tl_string_length input))
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
        [outer-trimmed : String (stdlib.string.trim (& s))]
        [outer-slice : String (stdlib.string.substring (& s) 2 5)]
        [outer-suffix : String "-append"]
        [outer-appended : String
          (stdlib.string.append (& outer-trimmed) (& outer-suffix))]
        [outer-number : String (stdlib.string.int->string 12345)]
        [outer-expected : String "outer"]
        [outer-appended-expected : String "outer-append"]
        [outer-number-expected : String "12345"]
        (begin
          (if (stdlib.string.eq (& outer-trimmed) (& outer-expected))
            unit
            (fail))
          (if (stdlib.string.eq (& outer-slice) (& outer-expected))
            unit
            (fail))
          (if (stdlib.string.eq (& outer-appended) (& outer-appended-expected))
            unit
            (fail))
          (if (stdlib.string.eq (& outer-number) (& outer-number-expected))
            unit
            (fail))
          (with-arena
            inner
            (let
              [inner-replaced : String
                (stdlib.string.replace "alpha" "ph" "ren")]
              [inner-slice : String (stdlib.string.slice "alphabet" 2 3)]
              [inner-appended : String (stdlib.string.append "inner" "-append")]
              [inner-concat : String (stdlib.string.concat "inner" "-concat")]
              [inner-number : String (stdlib.string.int->string -6789)]
              [inner-borrowed : String
                (stdlib.string.append (& inner-slice) (& inner-replaced))]
              [inner-replaced-expected : String "alrena"]
              [inner-slice-expected : String "pha"]
              [inner-appended-expected : String "inner-append"]
              [inner-concat-expected : String "inner-concat"]
              [inner-number-expected : String "-6789"]
              [inner-borrowed-expected : String "phaalrena"]
              (begin
                (if (stdlib.string.eq
                  (& inner-replaced)
                  (& inner-replaced-expected))
                  unit
                  (fail))
                (if (stdlib.string.eq (& inner-slice) (& inner-slice-expected))
                  unit
                  (fail))
                (if (stdlib.string.eq
                  (& inner-appended)
                  (& inner-appended-expected))
                  unit
                  (fail))
                (if (stdlib.string.eq
                  (& inner-concat)
                  (& inner-concat-expected))
                  unit
                  (fail))
                (if (stdlib.string.eq
                  (& inner-number)
                  (& inner-number-expected))
                  unit
                  (fail))
                (if (stdlib.string.eq
                  (& inner-borrowed)
                  (& inner-borrowed-expected))
                  unit
                  (fail))
                (if (= (__tl_string_length outer-trimmed) 5)
                  unit
                  (fail))
                (if (= (__tl_string_length outer-appended) 12)
                  unit
                  (fail))
                (if (= (__tl_string_length outer-number) 5)
                  unit
                  (fail))))))))))

;; Inline test coverage.
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
    (trim-left (& s))))

(cfg
  test
  (define (string-test-trim-right [s : String]) : String
    (trim-right (& s))))

(cfg
  test
  (define (string-test-trim [s : String]) : String
    (trim (& s))))

(cfg
  test
  (define (string-test-contains [haystack : String] [needle : String]) : bool
    (contains (& haystack) (& needle))))

(cfg
  test
  (define (string-test-contains-char [haystack : String] [c : char]) : bool
    (contains-char (& haystack) c)))

(cfg
  test
  (define (string-test-with-nul) : String
    (let
      [bytes : (Array u8) (array.make-array u8 3)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data bytes))]
      (begin
        (array-set! bytes 0 (cast 'a' : u8))
        (array-set! bytes 1 (cast 0 : u8))
        (array-set! bytes 2 (cast 'b' : u8))
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) 3))))))

(cfg
  test
  (define (string-test-eq-explicit-borrow [left : String] [right : String]) : bool
    (eq (& left) (& right))))

(cfg
  test
  (define (string-test-to-int-explicit-borrow [text : String]) : i64
    (>int (& text))))

(cfg
  test
  (define (string-test-copy-explicit-borrow [text : String]) : String
    (copy (& text))))

(cfg
  test
  (define (string-test-append-explicit-borrow [left : String] [right : String]) : String
    (append (& left) (& right))))

(cfg
  test
  (define (string-test-concat-explicit-borrow [left : String] [right : String]) : String
    (concat (& left) (& right))))

(cfg
  test
  (define (string-test-append-auto-borrow-param
    [left : String]
    [right : String]) : bool
    (let
      [joined : String (append left right)]
      (and
        (string=? joined "owned-param")
        (and (string=? left "owned") (string=? right "-param"))))))

(cfg
  test
  (define (string-test-concat-all-empty) : String
    (concat-all (array.make-array String 0))))

(cfg
  test
  (define (string-test-concat-all-many) : String
    (let
      [parts : (Array String) (array.make-array String 6)]
      (begin
        (array-set! parts 0 "ab")
        (array-set! parts 1 "")
        (array-set! parts 2 "cd")
        (array-set! parts 3 "ef")
        (array-set! parts 4 "")
        (array-set! parts 5 "gh")
        (concat-all parts)))))

(cfg
  test
  (define (string-test-substring [text : String] [start : i64] [len : i64]) : String
    (substring (& text) start len)))

(cfg
  test
  (define (string-test-slice-explicit-borrow
    [text : String]
    [start : i64]
    [len : i64]) : String
    (slice (& text) start len)))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-substring-view-eq
      [text : String]
      [start : i64]
      [len : i64]
      [expected : String]) : bool
      (eq (substring-view (& text) start len) (& expected)))))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-substring-view-len
      [text : String]
      [start : i64]
      [len : i64]) : i64
      (__tl_string_length (substring-view (& text) start len)))))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-slice-view-eq
      [text : String]
      [start : i64]
      [len : i64]
      [expected : String]) : bool
      (eq (slice-view (& text) start len) (& expected)))))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-trim-left-view-eq [s : String] [expected : String]) : bool
      (eq (trim-left-view (& s)) (& expected)))))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-trim-right-view-eq [s : String] [expected : String]) : bool
      (eq (trim-right-view (& s)) (& expected)))))

(cfg
  test
  (cfg
    (all feature-str-view feature-runtime-str-view-extern)
    (define (string-test-trim-view-eq [s : String] [expected : String]) : bool
      (eq (trim-view (& s)) (& expected)))))

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
      (test.assert-true (eq "" "") "empty strings compare equal")
      (test.assert-true (eq "hello" "hello") "same strings compare equal")
      (test.assert-true
        (string=? "alias" (append "ali" "as"))
        "string=? aliases eq")
      (string-test-assert-owned-string-eq
        (append "" "")
        ""
        "append handles two empty strings")
      (string-test-assert-owned-string-eq
        (append "" "right")
        "right"
        "append handles empty left")
      (string-test-assert-owned-string-eq
        (append "left" "")
        "left"
        "append handles empty right")
      (string-test-assert-owned-string-eq
        (append "foo" "bar")
        "foobar"
        "append concatenates short strings")
      (string-test-assert-owned-string-eq
        (append
          "abcdefghijklmnopqrstuvwxyz"
          "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "append concatenates long strings")
      (string-test-assert-owned-string-eq
        (concat "con" "cat")
        "concat"
        "concat aliases append")
      (string-test-assert-owned-string-eq
        (string-test-concat-all-empty)
        ""
        "concat-all handles an empty parts array")
      (string-test-assert-owned-string-eq
        (string-test-concat-all-many)
        "abcdefgh"
        "concat-all concatenates many parts")
      (string-test-assert-owned-string-eq
        (concat3 "a" "b" "c")
        "abc"
        "concat3 concatenates three strings")
      (string-test-assert-owned-string-eq
        (concat4 "a" "b" "c" "d")
        "abcd"
        "concat4 concatenates four strings")
      (string-test-assert-owned-string-eq
        (concat5 "a" "b" "c" "d" "e")
        "abcde"
        "concat5 concatenates five strings")
      (string-test-assert-owned-string-eq
        (string-test-copy-explicit-borrow "borrow-copy")
        "borrow-copy"
        "copy copies explicitly borrowed text")
      (string-test-assert-owned-string-eq
        (string-test-append-explicit-borrow "bor" "row")
        "borrow"
        "append concatenates explicitly borrowed inputs")
      (string-test-assert-owned-string-eq
        (string-test-concat-explicit-borrow "" "borrowed")
        "borrowed"
        "concat handles empty explicitly borrowed input")
      (let
        [left : String "owned"]
        [right : String "-place"]
        [joined : String (append left right)]
        (begin
          (string-test-assert-owned-string-eq
            joined
            "owned-place"
            "append auto-borrows owned places")
          (string-test-assert-owned-string-eq
            left
            "owned"
            "append leaves the left owned place usable")
          (string-test-assert-owned-string-eq
            right
            "-place"
            "append leaves the right owned place usable")))
      (test.assert-true
        (string-test-append-auto-borrow-param "owned" "-param")
        "append auto-borrows owned parameters")
      (test.assert-false (eq "hello" "world") "different strings differ")
      (test.assert-false (eq "hi" "high") "length mismatch differs")
      (test.assert-true
        (string-test-eq-explicit-borrow "borrow" (concat3 "bor" "row" ""))
        "explicitly borrowed string equality compares contents")
      (test.assert-false
        (string-test-eq-explicit-borrow "borrow" "borrows")
        "explicitly borrowed string equality rejects length mismatch")
      (test.assert-i64-eq (>int "") 0 "empty string parses as zero")
      (test.assert-i64-eq (>int "-") 0 "minus-only string parses as zero")
      (test.assert-i64-eq (>int "123") 123 "positive integer parses")
      (test.assert-i64-eq (>int "-42") -42 "negative integer parses")
      (test.assert-i64-eq
        (string-test-to-int-explicit-borrow "12a")
        169
        "explicitly borrowed parser keeps legacy non-digit arithmetic")
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
        (slice "abcdef" 6 0)
        ""
        "public slice copies empty boundary slice")
      (string-test-assert-owned-string-eq
        (string-test-substring "abcdef" 0 6)
        "abcdef"
        "borrowed substring copies full slice")
      (string-test-assert-owned-string-eq
        (string-test-slice-explicit-borrow "abcdef" 5 1)
        "f"
        "explicitly borrowed slice copies final byte")
      (string-test-assert-owned-string-eq
        (string-test-substring
          "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          10
          40)
        "klmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN"
        "borrowed substring copies long slice")
      (cfg
        (all feature-str-view feature-runtime-str-view-extern)
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
        (all feature-str-view feature-runtime-str-view-extern)
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
      (test.assert-i64-eq
        (index-of-byte "hello" 0 (cast 'h' : u8))
        0
        "index-of-byte finds first byte")
      (test.assert-i64-eq
        (index-of-byte "hello" 3 (cast 'l' : u8))
        3
        "index-of-byte honors nonzero start")
      (test.assert-i64-eq
        (index-of-byte "hello" 0 (cast 'z' : u8))
        -1
        "index-of-byte reports miss")
      (test.assert-i64-eq
        (index-of-byte "hello" 5 (cast 'o' : u8))
        -1
        "index-of-byte rejects start at length")
      (test.assert-i64-eq
        (index-of-byte "hello" -1 (cast 'h' : u8))
        -1
        "index-of-byte rejects negative start")
      (test.assert-i64-eq
        (index-of-byte "" 0 (cast 'h' : u8))
        -1
        "index-of-byte handles empty string")
      (let
        [with-nul : String (string-test-with-nul)]
        (test.assert-i64-eq
          (index-of-byte (& with-nul) 0 (cast 0 : u8))
          1
          "index-of-byte finds embedded nul"))
      (string-test-assert-owned-string-eq
        (replace "hello" "ell" "ipp")
        "hippo"
        "replace middle")
      (string-test-assert-owned-string-eq
        (replace "hello" "he" "ye")
        "yello"
        "replace prefix")
      (string-test-assert-owned-string-eq
        (replace "hello" "lo" "p")
        "help"
        "replace suffix")
      (string-test-assert-owned-string-eq
        (replace "hello" "zz" "yy")
        "hello"
        "replace miss returns input")
      (string-test-assert-owned-string-eq
        (replace "abc" "" "x")
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