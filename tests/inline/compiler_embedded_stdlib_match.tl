;; The trusted-source check compares a stdlib module's disk text with its
;; embedded copy in place, without building the payload text (#8731). It must
;; answer exactly what prepare-then-compare answered, so this file keeps that
;; preparation, verbatim from before #8731 (with #8764's comment cut), as the
;; reference.
(import compiler_embedded_stdlib as ces)
(import lex as lexer)
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.text_buf)

;; --- reference: prepare-then-compare before #8731 ---------------------------
;; The end of the atom starting at `start`: the first byte that is whitespace
;; or one of `()[]";`, or `n`.
(define (ref-atom-end [src : (& src str)] [start : i64] [n : i64]) : i64
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
(define (ref-atom-is?
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [text : (& text str)]) : bool
  (and
    (= (- end start) (string-length text))
    (string.eq (string.substring src start (- end start)) text)))

;; The index of the first byte at or after `start` that is not whitespace.
(define (ref-skip-space [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    (while (and (< j n) (lexer.is-space (__tl_string_ref src j)))
      (set! j (+ j 1)))
    j))

;; What the top-level form whose `(` precedes `start` is: 1 an inline
;; `(test ...)`, 2 a `(cfg test ...)` (blanked only with exactly one body), 0
;; anything else.
(define (ref-inline-test-head [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [head : i64 (ref-skip-space src start n)]
    [head-end : i64 (ref-atom-end src head n)]
    (cond
      [(ref-atom-is? src head head-end "test") 1]
      [(ref-atom-is? src head head-end "cfg")
        (let
          [predicate : i64 (ref-skip-space src head-end n)]
          (if (ref-atom-is? src predicate (ref-atom-end src predicate n) "test")
            2
            0))]
      [else 0])))

;; Whether the comment at `start..end` of `src` (from its first `;` to its
;; line break) is prose that nothing reads. A doc comment (`;:` or `;#`) and a
;; `name:` directive such as `lint-allow:` or `doctest-exit:` are not.
(define (ref-prose-comment? [src : (& src str)] [start : i64] [end : i64]) : bool
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

;; The source a module's payload embeds, as #8764 built it: each top-level
;; inline test replaced by its line breaks, and each prose comment outside
;; those forms cut to its first `;`.
(define (ref-payload-source [src : String]) : String
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
                  (ref-prose-comment? (& src) i cut))
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
              (set! kind (ref-inline-test-head (& src) (+ i 1) n))
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
            (set! i (ref-atom-end (& src) (+ i 1) n))])))
    (if (and valid (= depth 0))
      (begin
        (text_buf.append! out (string.substring (& src) copied (- n copied)))
        (text_buf.render out))
      src)))

;; --- agreement --------------------------------------------------------------
(define (match-agrees? [src : String] [blanked : String]) : bool
  (=
    (ces.compiler-embedded-stdlib-source-matches-blanked? (& src) (& blanked))
    (string.eq (ref-payload-source (string.copy src)) blanked)))

;; Both answers agree for `src` against its own blanked text, against `src`
;; itself, and against near misses of the blanked text; and the blanker built on
;; the shared scanner returns the reference's text.
(define (source-agrees? [src : String]) : bool
  (let
    [blanked : String (ref-payload-source (string.copy src))]
    (and
      (string.eq
        (ces.compiler-embedded-stdlib-payload-source (string.copy src))
        blanked)
      (match-agrees? (string.copy src) (string.copy blanked))
      (match-agrees? (string.copy src) (string.copy src))
      (match-agrees?
        (string.copy src)
        (str_cat.str-cat (string.copy blanked) "\n"))
      (match-agrees?
        (string.copy src)
        (str_cat.str-cat "\n" (string.copy blanked)))
      (match-agrees? (string.copy src) ""))))

;; `src` with `[start, end)` replaced by `text`.
(define (splice [src : (& src str)] [start : i64] [end : i64] [text : String]) : String
  (str_cat.str-cat
    (string.substring src 0 start)
    text
    (string.substring src end (- (string.string-length src) end))))

;; The index of the first range that is a blanked form rather than a cut
;; comment tail, or -1.
(define (first-form-range
  [src : (& src str)]
  [ranges : (& ranges (__tl_dyn-array i64))]
  [count : i64]) : i64
  (let
    [k : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< k count))
      (when
        (= (__tl_string_ref src (array-ref ranges (* k 2))) '(')
        (set! found k))
      (set! k (+ k 1)))
    found))

;; A module's disk text against the reference's blanking of it, then the same
;; blanked text against edits of the module: inside its first inline test,
;; right before it, without it, with it moved to the end, and with a new test.
(define (module-agrees? [src : String]) : bool
  (let
    [blanked : String (ref-payload-source (string.copy src))]
    (and
      (source-agrees? (string.copy src))
      (match (ces.compiler-embedded-stdlib-inline-test-ranges (& src))
        [(Unscannable) true]
        [(Ranges ranges count)
          (if (< (first-form-range (& src) (& ranges) count) 0)
            (match-agrees?
              (str_cat.str-cat (string.copy src) "\n(test added (check 1))\n")
              (string.copy blanked))
            (let
              [k : i64 (first-form-range (& src) (& ranges) count)]
              [start : i64 (array-ref ranges (* k 2))]
              [end : i64 (+ (array-ref ranges (+ (* k 2) 1)) 1)]
              [form : String (string.substring (& src) start (- end start))]
              (and
                ;; One byte inside the form, past its head.
                (match-agrees?
                  (splice (& src) (+ start 1) (+ start 1) " ")
                  (string.copy blanked))
                ;; One byte just before the form.
                (match-agrees?
                  (splice (& src) start start "x")
                  (string.copy blanked))
                (match-agrees?
                  (splice (& src) start end "")
                  (string.copy blanked))
                (match-agrees?
                  (str_cat.str-cat
                    (splice (& src) start end "")
                    "\n"
                    (string.copy form))
                  (string.copy blanked))
                (match-agrees?
                  (str_cat.str-cat
                    (string.copy src)
                    "\n(test added (check 1))\n")
                  (string.copy blanked)))))]))))

;; #8765: a batch keeps a matching text as the spans its payload form drops.
;; With that payload form they must answer exactly whether `candidate` is the
;; proved text: an edit anywhere, inside a dropped test included, is a miss.
(define (dropped-exact? [proved : String] [candidate : String]) : bool
  (match (ces.compiler-embedded-stdlib-dropped-spans (& proved))
    [(NoDropped) true]
    [(SomeDropped dropped)
      (let
        [blanked : String (ref-payload-source (string.copy proved))]
        (=
          (ces.compiler-embedded-stdlib-source-matches-dropped?
            (& candidate)
            (& blanked)
            (& dropped))
          (string.eq (& candidate) (& proved))))]))

;; `src` against itself and against its edits: inside its first dropped form,
;; right before it, without it, with it moved to the end, a new test, one more
;; byte, one byte fewer, and nothing.
(define (module-dropped-exact? [src : String]) : bool
  (let
    [n : i64 (string.string-length (& src))]
    (and
      (dropped-exact? (string.copy src) (string.copy src))
      (dropped-exact?
        (string.copy src)
        (str_cat.str-cat (string.copy src) "\n(test added (check 1))\n"))
      (dropped-exact? (string.copy src) (str_cat.str-cat (string.copy src) " "))
      (dropped-exact? (string.copy src) "")
      (or
        (= n 0)
        (dropped-exact? (string.copy src) (string.substring (& src) 0 (- n 1))))
      (match (ces.compiler-embedded-stdlib-inline-test-ranges (& src))
        [(Unscannable) true]
        [(Ranges ranges count)
          (or
            (< (first-form-range (& src) (& ranges) count) 0)
            (let
              [k : i64 (first-form-range (& src) (& ranges) count)]
              [start : i64 (array-ref ranges (* k 2))]
              [end : i64 (+ (array-ref ranges (+ (* k 2) 1)) 1)]
              [form : String (string.substring (& src) start (- end start))]
              (and
                (dropped-exact?
                  (string.copy src)
                  (splice (& src) (+ start 1) (+ start 1) " "))
                (dropped-exact?
                  (string.copy src)
                  (splice (& src) start start "x"))
                (dropped-exact? (string.copy src) (splice (& src) start end ""))
                (dropped-exact?
                  (string.copy src)
                  (str_cat.str-cat
                    (splice (& src) start end "")
                    "\n"
                    (string.copy form))))))]))))

(define (stdlib-module-names) : String
  (fs.read-dir "stdlib"))

(test
  embedded-stdlib-match-every-stdlib-module
  (let
    [listing : String (stdlib-module-names)]
    [n : i64 (string.string-length (& listing))]
    [start : i64 0]
    [checked : i64 0]
    (while (< start n)
      (let
        [end : i64 (string.index-of-byte (& listing) start (cast 10 : u8))]
        [stop : i64
          (if (< end 0)
            n
            end)]
        [name : String (string.substring (& listing) start (- stop start))]
        (when
          (and
            (> (string.string-length (& name)) 3)
            (string.is-string-prefix-at
              (& name)
              ".tl"
              (- (string.string-length (& name)) 3)))
          (match (io.try-read-file
            (& (str_cat.str-cat "stdlib/" (string.copy name))))
            [(OkIoBytes bytes)
              (let
                [text : String (byte_buf.to-string bytes)]
                (test.assert-true
                  (module-agrees? (string.copy text))
                  (str_cat.str-cat "stdlib/" (string.copy name) " disagrees"))
                (test.assert-true
                  (module-dropped-exact? text)
                  (str_cat.str-cat
                    "stdlib/"
                    name
                    " dropped spans are not exact")))
              (set! checked (+ checked 1))]
            [(ErrIoBytes _) (test.assert-true false name)]))
        (set! start (+ stop 1))))
    (test.assert-true (> checked 50) "every stdlib module was read")))

(test
  embedded-stdlib-match-edge-cases
  ;; The blanking rule's own cases, and strings, comments and character
  ;; literals holding `(test`, unbalanced brackets, CRLF and empty text.
  (test.assert-true
    (source-agrees? "(define a 1)\n(test t\n  (check a))\n(define b 2)\n")
    "edge case 0")
  (test.assert-true
    (source-agrees? "(cfg\r\n  test\r\n  (define h 1))\r\n(define b 2)")
    "edge case 1")
  (test.assert-true
    (source-agrees? "(cfg test (define a 1) (define a 2))")
    "edge case 2")
  (test.assert-true
    (source-agrees? "(cfg (not test) (define a 1))")
    "edge case 3")
  (test.assert-true
    (source-agrees? "(testing 1)(test-foo 2)(define (f) (test 3))")
    "edge case 4")
  (test.assert-true
    (source-agrees? "(define s \"(test x)\")\n(test t (check 1))")
    "edge case 5")
  (test.assert-true
    (source-agrees? "; (test commented)\n(test t (check 1))\n")
    "edge case 6")
  (test.assert-true
    (source-agrees? "(define c '(')\n(test t (check 1))")
    "edge case 7")
  (test.assert-true (source-agrees? "(test t (check 1)") "edge case 8")
  (test.assert-true (source-agrees? "(test t (check 1)))") "edge case 9")
  (test.assert-true
    (source-agrees? "(define s \"unterminated)\n(test t)")
    "edge case 10")
  (test.assert-true
    (source-agrees? "(test t)(test u)(define a 1)")
    "edge case 11")
  (test.assert-true
    (source-agrees? "\r\n(test t\r\n (check 1))\r\n\r\n")
    "edge case 12")
  (test.assert-true (source-agrees? "") "edge case 13")
  ;; The prose-comment cut (#8659): full-line and trailing prose, doc comments
  ;; and directives kept, CRLF, a comment inside a kept form, inside a blanked
  ;; test and in a kept two-body `cfg test`, and a comment at end of text.
  (test.assert-true
    (source-agrees?
      ";; Why.\n(define a 1) ; note\n(test t ; inside\n (check))\n")
    "edge case 14")
  (test.assert-true
    (source-agrees?
      ";# Module.\n;: Item.\n;; lint-allow: unused-import\n(define a 1)\n")
    "edge case 15")
  (test.assert-true
    (source-agrees? ";; prose\r\n(define a\r\n  ; inside\r\n  1)")
    "edge case 16")
  (test.assert-true
    (source-agrees? "(cfg test (define a 1) ; kept\n (define a 2)) ;; end")
    "edge case 17")
  (test.assert-true
    (match-agrees? ";; one\n(define a 1)\n" ";\n(define a 1)\n")
    "edge case 18")
  (test.assert-true
    (match-agrees? ";; one\n(define a 1)\n" ";; one\n(define a 1)\n")
    "edge case 19")
  ;; The dropped-span proof over the same shapes, CRLF and prose included.
  (test.assert-true
    (module-dropped-exact?
      "(define a 1)\n(test t\n  (check a))\n(define b 2)\n")
    "dropped case 0")
  (test.assert-true
    (module-dropped-exact? "(cfg\r\n  test\r\n  (define h 1))\r\n(define b 2)")
    "dropped case 1")
  (test.assert-true
    (module-dropped-exact?
      ";; Why.\n(define a 1) ; note\n(test t ; inside\n (check))\n")
    "dropped case 2")
  (test.assert-true
    (module-dropped-exact? "(test t)(test u)(define a 1)")
    "dropped case 3")
  (test.assert-true (module-dropped-exact? "(define a 1)") "dropped case 4")
  (test.assert-true (module-dropped-exact? "") "dropped case 5")
  (test.assert-true
    (module-dropped-exact? "(test t (check 1)")
    "dropped case 6"))