;; verify.tl - Prove every build-time payload decodes to its source with the
;; inline tests blanked and prose comments cut, that blanking removed exactly
;; the top-level inline tests and moved no other token (#8713), and that every
;; other line is kept or is a prose comment cut to its first `;` (#8659).
(import compiler_embedded_stdlib as embedded)
(import compiler_intern as ci)
(import lex as lexer)
(import token)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (embedded-stdlib-verify-line-end
  [manifest : (& manifest str)]
  [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length manifest)]
    (while (and (< index length) (!= (string.string-ref manifest index) '\n'))
      (set! index (+ index 1)))
    index))

(define (embedded-stdlib-verify-trim-cr [line : String]) : String
  (let
    [length : i64 (string.string-length line)]
    (if (and (> length 0) (= (string.string-ref line (- length 1)) '\r'))
      (string.substring line 0 (- length 1))
      line)))

;; One lexed source as parallel arrays: each token's identity key (its tag
;; and payload), line and column. The last entry is the end token.
(defstruct EmbeddedStdlibVerifyTokens
  (keys (__tl_dyn-array String))
  (lines (__tl_dyn-array i64))
  (cols (__tl_dyn-array i64)))

(define (embedded-stdlib-verify-key [tok : (& tok token.SpannedToken)]) : String
  (let
    [tag : String
      (string.int->string (token.tag-ref (token.spanned-token-token-ref tok)))]
    (match (token.spanned-token-token-ref tok)
      [(Int value _) (str_cat.str-cat tag ":" (string.int->string value))]
      [(Sym id) (str_cat.str-cat tag ":" (ci.intern-id-str id))]
      [(Str id) (str_cat.str-cat tag ":" (ci.intern-id-str id))]
      [(Char c) (str_cat.str-cat tag ":" (string.int->string (cast c : i64)))]
      [(Float text) (str_cat.str-cat tag ":" (string.copy text))]
      [_ tag])))

(define (embedded-stdlib-verify-lex [source : String]) : EmbeddedStdlibVerifyTokens
  (match (lexer.spanned-result source)
    [(Ok shared)
      (let
        [count : i64 0]
        (while (!=
          (token.tag-ref
            (token.spanned-token-token-ref (& (array-ref shared count))))
          (token.tag-end))
          (set! count (+ count 1)))
        (let
          [keys : (__tl_dyn-array String) (__tl_make-array String (+ count 1))]
          [lines : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
          [cols : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
          [index : i64 0]
          (while (<= index count)
            (set!
              (array-ref keys index)
              (embedded-stdlib-verify-key (& (array-ref shared index))))
            (set!
              (array-ref lines index)
              (token.spanned-token-line (& (array-ref shared index))))
            (set!
              (array-ref cols index)
              (token.spanned-token-col (& (array-ref shared index))))
            (set! index (+ index 1)))
          (EmbeddedStdlibVerifyTokens keys lines cols)))]
    [(Err _)
      (EmbeddedStdlibVerifyTokens
        (__tl_make-array String 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0))]))

(define (embedded-stdlib-verify-key-at
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]) : String
  (string.copy (& (array-ref tokens.keys index))))

(define (embedded-stdlib-verify-tag-is?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]
  [tag : i64]) : bool
  (string.eq
    (embedded-stdlib-verify-key-at tokens index)
    (string.int->string tag)))

(define (embedded-stdlib-verify-open?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]) : bool
  (or
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-lparen))
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-lbracket))))

(define (embedded-stdlib-verify-close?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]) : bool
  (or
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-rparen))
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-rbracket))))

(define (embedded-stdlib-verify-prefix?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]) : bool
  (or
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-quote))
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-backtick))
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-comma))
    (embedded-stdlib-verify-tag-is? tokens index (token.tag-comma-at))))

(define (embedded-stdlib-verify-sym?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [index : i64]
  [text : (& text str)]) : bool
  (string.eq
    (embedded-stdlib-verify-key-at tokens index)
    (str_cat.str-cat
      (string.int->string (token.tag-sym))
      ":"
      (string.copy text))))

;; The index of the token that closes the bracket opened at `start`.
(define (embedded-stdlib-verify-close
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [start : i64]) : i64
  (let
    [index : i64 start]
    [depth : i64 0]
    [done : bool false]
    (while (not done)
      (cond
        [(embedded-stdlib-verify-open? tokens index) (set! depth (+ depth 1))]
        [(embedded-stdlib-verify-close? tokens index)
          (set! depth (- depth 1))
          (when (= depth 0) (set! done true))]
        [(embedded-stdlib-verify-tag-is? tokens index (token.tag-end))
          (set! done true)]
        [else unit])
      (when (not done) (set! index (+ index 1))))
    index))

;; The number of elements directly inside the form spanning `start..close`; a
;; quote or unquote prefix belongs to the element it prefixes.
(define (embedded-stdlib-verify-elements
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [start : i64]
  [close : i64]) : i64
  (let
    [index : i64 (+ start 1)]
    [depth : i64 1]
    [count : i64 0]
    (while (< index close)
      (cond
        [(embedded-stdlib-verify-open? tokens index)
          (when (= depth 1) (set! count (+ count 1)))
          (set! depth (+ depth 1))]
        [(embedded-stdlib-verify-close? tokens index) (set! depth (- depth 1))]
        [(embedded-stdlib-verify-prefix? tokens index) unit]
        [else (when (= depth 1) (set! count (+ count 1)))])
      (set! index (+ index 1)))
    count))

;; Whether the top-level form spanning `start..close` is an inline test the
;; payload blanks: `(test ...)`, or `(cfg test BODY)` with exactly one body.
(define (embedded-stdlib-verify-inline-test?
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [start : i64]
  [close : i64]) : bool
  (and
    (embedded-stdlib-verify-tag-is? tokens start (token.tag-lparen))
    (< (+ start 1) close)
    (or
      (embedded-stdlib-verify-sym? tokens (+ start 1) "test")
      (and
        (< (+ start 2) close)
        (embedded-stdlib-verify-sym? tokens (+ start 1) "cfg")
        (embedded-stdlib-verify-sym? tokens (+ start 2) "test")
        (= (embedded-stdlib-verify-elements tokens start close) 3)))))

;; Whether `stripped` holds exactly `original`'s tokens minus its top-level
;; inline tests, each kept token at its original line and column.
(define (embedded-stdlib-verify-tokens [original : String] [stripped : String]) : bool
  (let
    [before : EmbeddedStdlibVerifyTokens (embedded-stdlib-verify-lex original)]
    [after : EmbeddedStdlibVerifyTokens (embedded-stdlib-verify-lex stripped)]
    [before-count : i64 (array-length before.keys)]
    [after-count : i64 (array-length after.keys)]
    [i : i64 0]
    [j : i64 0]
    [ok : bool (and (> before-count 0) (> after-count 0))]
    (while (and
      ok
      (< i before-count)
      (not (embedded-stdlib-verify-tag-is? (& before) i (token.tag-end))))
      (let
        [close : i64 (embedded-stdlib-verify-close (& before) i)]
        (if (embedded-stdlib-verify-inline-test? (& before) i close)
          (set! i (+ close 1))
          (while (and ok (<= i close))
            (set!
              ok
              (and
                (< j after-count)
                (string.eq
                  (embedded-stdlib-verify-key-at (& before) i)
                  (embedded-stdlib-verify-key-at (& after) j))
                (= (array-ref before.lines i) (array-ref after.lines j))
                (= (array-ref before.cols i) (array-ref after.cols j))))
            (set! i (+ i 1))
            (set! j (+ j 1))))))
    (and
      ok
      (< j after-count)
      (embedded-stdlib-verify-tag-is? (& after) j (token.tag-end)))))

;; The lines of the top-level inline tests in `tokens`, as flags indexed by
;; line number.
(define (embedded-stdlib-verify-test-lines
  [tokens : (& tokens EmbeddedStdlibVerifyTokens)]
  [line-count : i64]) : (__tl_dyn-array bool)
  (let
    [flags : (__tl_dyn-array bool) (__tl_make-array bool (+ line-count 2))]
    [count : i64 (array-length tokens.keys)]
    [i : i64 0]
    (while (and
      (< i count)
      (not (embedded-stdlib-verify-tag-is? tokens i (token.tag-end))))
      (let
        [close : i64 (embedded-stdlib-verify-close tokens i)]
        (when
          (embedded-stdlib-verify-inline-test? tokens i close)
          (let
            [line : i64 (array-ref tokens.lines i)]
            (while (and
              (<= line (array-ref tokens.lines close))
              (<= line line-count))
              (set! (array-ref flags line) true)
              (set! line (+ line 1)))))
        (set! i (+ close 1))))
    flags))

;; `text` split at each LF, without a final CR on any line.
(define (embedded-stdlib-verify-split-lines [text : (& text str)]) : (__tl_dyn-array
    String)
  (let
    [out : (__tl_dyn-array String) (__tl_make-array String 0)]
    [length : i64 (string.string-length text)]
    [start : i64 0]
    (while (<= start length)
      (let
        [end : i64 (embedded-stdlib-verify-line-end text start)]
        [line : String
          (embedded-stdlib-verify-trim-cr
            (string.substring text start (- end start)))]
        (__tl_array-push! out line)
        (set! start (+ end 1))))
    out))

;; Whether `cut` is `original` with a prose comment cut to its first `;`: a
;; proper prefix ending in `;` whose removed tail is neither a doc comment
;; (`:` or `#` right after that `;`) nor a `name:` directive.
(define (embedded-stdlib-verify-prose-cut?
  [original : (& original str)]
  [cut : (& cut str)]) : bool
  (let
    [kept : i64 (string.string-length cut)]
    [length : i64 (string.string-length original)]
    (and
      (> kept 0)
      (< kept length)
      (string.eq (string.substring original 0 kept) cut)
      (= (string.string-ref cut (- kept 1)) ';')
      (let
        [next : char (string.string-ref original kept)]
        [j : i64 kept]
        (and
          (not (= next ':'))
          (not (= next '#'))
          (begin
            (while (and (< j length) (= (string.string-ref original j) ';'))
              (set! j (+ j 1)))
            (while (and (< j length) (= (string.string-ref original j) ' '))
              (set! j (+ j 1)))
            (let
              [k : i64 j]
              (while (and
                (< k length)
                (let
                  [c : char (string.string-ref original k)]
                  (or
                    (and (>= c 'a') (<= c 'z'))
                    (and (> k j) (>= c '0') (<= c '9'))
                    (and (> k j) (= c '-')))))
                (set! k (+ k 1)))
              (not
                (and
                  (> k j)
                  (< k length)
                  (= (string.string-ref original k) ':'))))))))))

;; Whether every line of `stripped` outside the inline tests equals the same
;; line of `original` or is a prose comment cut from it, with the line count
;; kept.
(define (embedded-stdlib-verify-lines-kept
  [original : String]
  [stripped : String]) : bool
  (let
    [before : (__tl_dyn-array String)
      (embedded-stdlib-verify-split-lines (& original))]
    [after : (__tl_dyn-array String)
      (embedded-stdlib-verify-split-lines (& stripped))]
    [tokens : EmbeddedStdlibVerifyTokens
      (embedded-stdlib-verify-lex (string.copy (& original)))]
    [tests : (__tl_dyn-array bool)
      (embedded-stdlib-verify-test-lines (& tokens) (array-length before))]
    [index : i64 0]
    [ok : bool (= (array-length before) (array-length after))]
    (while (and ok (< index (array-length before)))
      (let
        [o : (& before str) (& (array-ref before index))]
        [s : (& after str) (& (array-ref after index))]
        (unless
          (or
            (array-ref tests (+ index 1))
            (string.eq o s)
            (embedded-stdlib-verify-prose-cut? o s))
          (set! ok false)))
      (set! index (+ index 1)))
    ok))

(define (embedded-stdlib-verify-one [suffix : (& suffix str)]) : bool
  (let
    [original : String
      (byte_buf.to-string (io.read-file (str_cat.str-cat "stdlib/" suffix)))]
    [expected : String
      (embedded.compiler-embedded-stdlib-payload-source
        (string.copy (& original)))]
    (and
      (embedded-stdlib-verify-tokens
        (string.copy (& original))
        (string.copy (& expected)))
      (embedded-stdlib-verify-lines-kept
        (string.copy (& original))
        (string.copy (& expected)))
      (match (embedded.compiler-embedded-stdlib-lookup
        (string.substring suffix 0 (string.string-length suffix)))
        [(CompilerEmbeddedStdlibSomeSource actual) (string.eq expected actual)]
        [(CompilerEmbeddedStdlibNoSource) false]))))

(define (embedded-stdlib-verify-lines [manifest : String] [start : i64]) : bool
  (if (>= start (string.string-length manifest))
    true
    (let
      [end : i64 (embedded-stdlib-verify-line-end (& manifest) start)]
      [line : String
        (embedded-stdlib-verify-trim-cr
          (string.substring manifest start (- end start)))]
      [next : i64
        (if (< end (string.string-length manifest))
          (+ end 1)
          end)]
      (if (and
        (or
          (= (string.string-length line) 0)
          (embedded-stdlib-verify-one (& line)))
        (embedded-stdlib-verify-lines manifest next))
        true
        (begin
          (when
            (> (string.string-length line) 0)
            (io.print-error
              (str_cat.str-cat "embedded stdlib exact-source mismatch: " line)))
          false)))))

(define (main) : i64
  (if (= (io.arg-count) 2)
    (if (embedded-stdlib-verify-lines
      (byte_buf.to-string (io.read-file (io.arg 1)))
      0)
      42
      1)
    (begin
      (io.print-error "usage: verify <module-manifest>")
      2)))