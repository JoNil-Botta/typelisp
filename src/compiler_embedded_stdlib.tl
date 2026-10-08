;; compiler_embedded_stdlib.tl - Compressed stdlib source fallback: each module's
;; source with its inline tests blanked (#8713) and its prose comments cut to
;; their first `;` (#8659).
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

;; The end of the atom starting at `start`: the first byte that is whitespace
;; or one of `()[]";`, or `n`.
(define (compiler-embedded-stdlib-atom-end
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while (and keep (< j n))
      (let
        [c : char (__tl_string_ref src j)]
        (if (or
          (lexer.is-space c)
          (= c '(')
          (= c ')')
          (= c '[')
          (= c ']')
          (= c '"')
          (= c ';'))
          (set! keep false)
          (set! j (+ j 1)))))
    j))

;; Whether the atom at `start..end` of `src` is exactly `text`.
(define (compiler-embedded-stdlib-atom-is?
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [text : (& text str)]) : bool
  (and
    (= (- end start) (string-length text))
    (string.eq (string.substring src start (- end start)) text)))

;; The index of the first byte at or after `start` that is not whitespace.
(define (compiler-embedded-stdlib-skip-space
  [src : (& src str)]
  [start : i64]
  [n : i64]) : i64
  (let
    [j : i64 start]
    (while (and (< j n) (lexer.is-space (__tl_string_ref src j)))
      (set! j (+ j 1)))
    j))

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

;; Whether the comment at `start..end` of `src` (from its first `;` to its
;; line break) is prose that nothing reads. A doc comment (`;:` or `;#`) and a
;; `name:` directive such as `lint-allow:` or `doctest-exit:` are not.
(define (compiler-embedded-stdlib-prose-comment?
  [src : (& src str)]
  [start : i64]
  [end : i64]) : bool
  (let
    [j : i64 (+ start 1)]
    (if (and
      (< j end)
      (or (= (__tl_string_ref src j) ':') (= (__tl_string_ref src j) '#')))
      false
      (begin
        (while (and (< j end) (= (__tl_string_ref src j) ';'))
          (set! j (+ j 1)))
        (while (and (< j end) (= (__tl_string_ref src j) ' '))
          (set! j (+ j 1)))
        (let
          [k : i64 j]
          (while (and
            (< k end)
            (let
              [c : char (__tl_string_ref src k)]
              (or
                (and (>= c 'a') (<= c 'z'))
                (and (> k j) (>= c '0') (<= c '9'))
                (and (> k j) (= c '-')))))
            (set! k (+ k 1)))
          (not (and (> k j) (< k end) (= (__tl_string_ref src k) ':'))))))))

;; The source a module's payload embeds. Each top-level inline test is
;; replaced by the line breaks it contained: every `(test ...)` form and every
;; `(cfg test BODY)` form with exactly one body. Each prose comment outside
;; those forms keeps only its first `;`, so the line still reads as a comment;
;; doc comments and directives are kept whole. All other bytes are kept, so
;; each remaining form keeps its line and column. Strings, character literals
;; and comments are skipped with the lexer's own scanners; a source they
;; reject, or one whose brackets do not balance, is returned unchanged.
(define (compiler-embedded-stdlib-payload-source [src : String]) : String
  (let
    [n : i64 (string-length (& src))]
    [i : i64 0]
    [depth : i64 0]
    [start : i64 -1]
    [kind : i64 0]
    [elements : i64 0]
    [copied : i64 0]
    [valid : bool true]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (and valid (< i n))
      (let
        [c : char (__tl_string_ref (& src) i)]
        (cond
          [(= c ';')
            (let
              [end : i64 (lexer.scan-comment-end (& src) (+ i 1) n)]
              [cut : i64
                (if (and (> end i) (= (__tl_string_ref (& src) (- end 1)) '\r'))
                  (- end 1)
                  end)]
              (when
                (and
                  (or (= depth 0) (= kind 0))
                  (> cut (+ i 1))
                  (compiler-embedded-stdlib-prose-comment? (& src) i cut))
                (text_buf.append!
                  out
                  (string.substring (& src) copied (- (+ i 1) copied)))
                (set! copied cut))
              (set! i end))]
          [(= c '"')
            (when (= depth 1) (set! elements (+ elements 1)))
            (match (lexer.scan-str-end-result (& src) (+ i 1) n)
              [(Ok end) (set! i (+ end 1))]
              [(Err _) (set! valid false)])]
          [(= c '\'')
            (match (lexer.apostrophe-char-literal-result (& src) i n)
              [(Ok _ end)
                (when (= depth 1) (set! elements (+ elements 1)))
                (set! i end)]
              [(No) (set! i (+ i 1))]
              [(Err _) (set! valid false)])]
          [(or (= c '(') (= c '['))
            (when (= depth 1) (set! elements (+ elements 1)))
            (when
              (and (= depth 0) (= c '('))
              (set! start i)
              (set!
                kind
                (compiler-embedded-stdlib-inline-test-head (& src) (+ i 1) n))
              (set! elements 0))
            (set! depth (+ depth 1))
            (set! i (+ i 1))]
          [(or (= c ')') (= c ']'))
            (set! depth (- depth 1))
            (cond
              [(< depth 0) (set! valid false)]
              [(and (= depth 0) (>= start 0))
                (when
                  (or (= kind 1) (and (= kind 2) (= elements 3)))
                  (text_buf.append!
                    out
                    (string.substring (& src) copied (- start copied)))
                  (let
                    [j : i64 start]
                    (while (<= j i)
                      (let
                        [b : char (__tl_string_ref (& src) j)]
                        (when
                          (or (= b '\n') (= b '\r'))
                          (text_buf.append! out (string.substring (& src) j 1))))
                      (set! j (+ j 1))))
                  (set! copied (+ i 1)))
                (set! start -1)]
              [else unit])
            (set! i (+ i 1))]
          [(lexer.is-space c) (set! i (+ i 1))]
          [else
            (when (= depth 1) (set! elements (+ elements 1)))
            (set! i (compiler-embedded-stdlib-atom-end (& src) (+ i 1) n))])))
    (if (and valid (= depth 0))
      (begin
        (text_buf.append! out (string.substring (& src) copied (- n copied)))
        (text_buf.render out))
      src)))