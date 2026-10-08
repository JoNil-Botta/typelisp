;; compiler_embedded_stdlib.tl - Compressed stdlib source fallback: each module's
;; source with its inline tests blanked (#8713).
(cfg test (import compiler_embedded_stdlib_payload_seed as payload))
(cfg (not test) (import compiler_embedded_stdlib_payload as payload))
(import compiler_lzss as lzss)
(import lex as lexer)
(import stdlib.string)
(import stdlib.text_buf)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

;; The 16 MiB ceiling is far above any individual embedded source module while
;; rejecting corrupt length headers before they can request an unbounded
;; allocation.
(define (compiler-embedded-stdlib-source-limit) : i64
  16777216)

(define (compiler-embedded-stdlib-bytes->string [bytes : (__tl_dyn-array u8)]) : String
  (if (= (array-length bytes) 0)
    ""
    (let
      [data : (MutPtr u8)
        (unsafe
          (__tl_array-data bytes))]
      (unsafe
        (string-from-bytes (ptr-cast data : (Ptr u8)) (array-length bytes))))))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (payload.compiler-embedded-stdlib-payload-lookup suffix)
    [(CompilerEmbeddedStdlibPayloadNone) (CompilerEmbeddedStdlibNoSource)]
    [(CompilerEmbeddedStdlibPayloadSome compressed)
      (match (lzss.compiler-lzss-decode
        (& compressed)
        (compiler-embedded-stdlib-source-limit))
        [(Ok bytes)
          (CompilerEmbeddedStdlibSomeSource
            (compiler-embedded-stdlib-bytes->string bytes))]
        [(Err _)
          (string.tl_oob_abort)
          (CompilerEmbeddedStdlibNoSource)])]))

;; Whether `c` ends an atom: whitespace or one of `()[]";`. Most source bytes
;; are letters, past `;`, so they take the two-compare branch.
(define (compiler-embedded-stdlib-delimiter? [c : char]) : bool
  (if (> c ';')
    (or (= c '[') (= c ']'))
    (or (lexer.is-space c) (= c '(') (= c ')') (= c '"') (= c ';'))))

;; The end of the atom starting at `start`: the first delimiter, or `n`.
(define (compiler-embedded-stdlib-atom-end
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while (and keep (< j n))
      (if (compiler-embedded-stdlib-delimiter? (__tl_string_ref src j))
        (set! keep false)
        (set! j (+ j 1))))
    j))

;; Whether the atom at `start..end` of `src` is exactly `text`.
(define (compiler-embedded-stdlib-atom-is?
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [text : (& text str)]) : bool
  (if (= (- end start) (string-length text))
    (string.is-string-prefix-at src text start)
    false))

;; The index of the first byte at or after `start` that is not whitespace.
(define (compiler-embedded-stdlib-skip-space
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while (and keep (< j n))
      (if (lexer.is-space (__tl_string_ref src j))
        (set! j (+ j 1))
        (set! keep false)))
    j))

;; The end of the comment whose `;` precedes `start`: its line break, or `n`.
(define (compiler-embedded-stdlib-comment-end
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [newline : i64 (string.index-of-byte src start (cast 10 : u8))]
    (if (< newline 0)
      n
      newline)))

;; What the top-level form whose `(` precedes `start` is: 1 an inline
;; `(test ...)`, 2 a `(cfg test ...)` (blanked only with exactly one body), 0
;; anything else.
(define (compiler-embedded-stdlib-inline-test-head
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [head : i64 (compiler-embedded-stdlib-skip-space src start n)]
    [head-end : i64 (compiler-embedded-stdlib-atom-end src head n)]
    (cond
      [(compiler-embedded-stdlib-atom-is? src head head-end "test") 1]
      [(compiler-embedded-stdlib-atom-is? src head head-end "cfg")
        (let
          [predicate : i64 (compiler-embedded-stdlib-skip-space src head-end n)]
          (if (compiler-embedded-stdlib-atom-is?
            src
            predicate
            (compiler-embedded-stdlib-atom-end src predicate n)
            "test")
            2
            0))]
      [else 0])))

;; The top-level inline tests of a source, the forms the payload blanks: every
;; `(test ...)` form and every `(cfg test BODY)` form with exactly one body.
(defenum CompilerEmbeddedStdlibTestRanges
  ;; The lexer's scanners reject a string or character literal, or the
  ;; brackets do not balance: nothing is blanked.
  (Unscannable)
  ;; Each blanked form's first and last byte, flattened in source order, and
  ;; how many forms there are.
  (Ranges (__tl_dyn-array i64) i64))

(define (compiler-embedded-stdlib-ranges-push
  [ranges : (__tl_dyn-array i64)]
  [count : i64]
  [start : i64]
  [end : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64)
      (if (< (+ (* count 2) 1) (array-length ranges))
        ranges
        (let
          [grown : (__tl_dyn-array i64)
            (__tl_make-array i64 (* (array-length ranges) 2))]
          [k : i64 0]
          (while (< k (* count 2))
            (set! (array-ref grown k) (array-ref ranges k))
            (set! k (+ k 1)))
          grown))]
    (set! (array-ref out (* count 2)) start)
    (set! (array-ref out (+ (* count 2) 1)) end)
    out))

;; One pass over `src` that finds its inline tests. Strings, character
;; literals and comments are skipped with the lexer's own scanners, so a `(test`
;; inside one is not a form.
(define (compiler-embedded-stdlib-inline-test-ranges [src : (& src str)]) : CompilerEmbeddedStdlibTestRanges
  (let
    [n : i64 (string-length src)]
    [i : i64 0]
    [depth : i64 0]
    [start : i64 -1]
    [kind : i64 0]
    [elements : i64 0]
    [valid : bool true]
    [ranges : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [count : i64 0]
    (while (and valid (< i n))
      (let
        [c : char (__tl_string_ref src i)]
        (cond
          [(not (compiler-embedded-stdlib-delimiter? c))
            (if (= c '\'')
              (match (lexer.apostrophe-char-literal-result src i n)
                [(Ok _ end)
                  (when (= depth 1) (set! elements (+ elements 1)))
                  (set! i end)]
                [(No) (set! i (+ i 1))]
                [(Err _) (set! valid false)])
              (begin
                (when (= depth 1) (set! elements (+ elements 1)))
                (set! i (compiler-embedded-stdlib-atom-end src (+ i 1) n))))]
          [(lexer.is-space c)
            (set! i (compiler-embedded-stdlib-skip-space src (+ i 1) n))]
          [(= c ';')
            (set! i (compiler-embedded-stdlib-comment-end src (+ i 1) n))]
          [(= c '"')
            (when (= depth 1) (set! elements (+ elements 1)))
            (match (lexer.scan-str-end-result src (+ i 1) n)
              [(Ok end) (set! i (+ end 1))]
              [(Err _) (set! valid false)])]
          [(or (= c '(') (= c '['))
            (when (= depth 1) (set! elements (+ elements 1)))
            (when
              (and (= depth 0) (= c '('))
              (set! start i)
              (set!
                kind
                (compiler-embedded-stdlib-inline-test-head src (+ i 1) n))
              (set! elements 0))
            (set! depth (+ depth 1))
            (set! i (+ i 1))]
          [else
            (set! depth (- depth 1))
            (cond
              [(< depth 0) (set! valid false)]
              [(and (= depth 0) (>= start 0))
                (when
                  (or (= kind 1) (and (= kind 2) (= elements 3)))
                  (set!
                    ranges
                    (compiler-embedded-stdlib-ranges-push ranges count start i))
                  (set! count (+ count 1)))
                (set! start -1)]
              [else unit])
            (set! i (+ i 1))])))
    (if (and valid (= depth 0))
      (Ranges ranges count)
      (Unscannable))))

;; `src` with each top-level inline test blanked: every `(test ...)` form and
;; every `(cfg test BODY)` form with exactly one body is replaced by the line
;; breaks it contained. All other bytes are kept, so each remaining form keeps
;; its line and column. A source the lexer's scanners reject, or one whose
;; brackets do not balance, is returned unchanged.
(define (compiler-embedded-stdlib-source-without-inline-tests [src : String]) : String
  (match (compiler-embedded-stdlib-inline-test-ranges (& src))
    [(Unscannable) src]
    [(Ranges ranges count)
      (let
        [n : i64 (string-length (& src))]
        [out : text_buf.TextBuf (text_buf.empty)]
        [copied : i64 0]
        [k : i64 0]
        (while (< k count)
          (let
            [start : i64 (array-ref ranges (* k 2))]
            [end : i64 (array-ref ranges (+ (* k 2) 1))]
            [j : i64 start]
            (text_buf.append!
              out
              (string.substring (& src) copied (- start copied)))
            (while (<= j end)
              (let
                [b : char (__tl_string_ref (& src) j)]
                (when
                  (or (= b '\n') (= b '\r'))
                  (text_buf.append! out (string.substring (& src) j 1))))
              (set! j (+ j 1)))
            (set! copied (+ end 1)))
          (set! k (+ k 1)))
        (text_buf.append! out (string.substring (& src) copied (- n copied)))
        (text_buf.render out))]))

;; Whether `left[left-start, left-start + len)` equals `right[right-start,
;; right-start + len)`. The left span must lie inside `left`; a right span past
;; the end of `right` is unequal.
(define (compiler-embedded-stdlib-span-eq?
  [left : (& left str)]
  [left-start : i64]
  [right : (& right str)]
  [right-start : i64]
  [len : i64]) : bool
  (if (> (+ right-start len) (string-length right))
    false
    (unsafe
      (let
        [lp : (Ptr u8) (ptr-offset (string-data left) left-start)]
        [rp : (Ptr u8) (ptr-offset (string-data right) right-start)]
        (string.string-bytes-eq lp rp len)))))

;: Whether `src` with its inline tests blanked equals `blanked`, without
;: building the blanked text (#8731): each kept span of `src` is compared in
;: place against `blanked` a word at a time, and each blanked form's line breaks
;: byte by byte. It answers exactly what comparing
;: (compiler-embedded-stdlib-source-without-inline-tests src) with `blanked`
;: answers.
(define (compiler-embedded-stdlib-source-matches-blanked?
  [src : (& src str)]
  [blanked : (& blanked str)]) : bool
  (match (compiler-embedded-stdlib-inline-test-ranges src)
    [(Unscannable) (string.eq src blanked)]
    [(Ranges ranges count)
      (let
        [n : i64 (string-length src)]
        [m : i64 (string-length blanked)]
        [copied : i64 0]
        [at : i64 0]
        [k : i64 0]
        [ok : bool true]
        (while (and ok (< k count))
          (let
            [start : i64 (array-ref ranges (* k 2))]
            [end : i64 (array-ref ranges (+ (* k 2) 1))]
            [kept : i64 (- start copied)]
            [j : i64 start]
            (if (compiler-embedded-stdlib-span-eq? src copied blanked at kept)
              (set! at (+ at kept))
              (set! ok false))
            (while (and ok (<= j end))
              (let
                [b : char (__tl_string_ref src j)]
                (when
                  (or (= b '\n') (= b '\r'))
                  (if (< at m)
                    (if (= (__tl_string_ref blanked at) b)
                      (set! at (+ at 1))
                      (set! ok false))
                    (set! ok false))))
              (set! j (+ j 1)))
            (set! copied (+ end 1)))
          (set! k (+ k 1)))
        (if ok
          (and
            (= (+ at (- n copied)) m)
            (compiler-embedded-stdlib-span-eq?
              src
              copied
              blanked
              at
              (- n copied)))
          false))]))