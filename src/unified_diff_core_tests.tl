;; Executable unified diff renderer conformance, discovered by inline-test CI.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import unified_diff_core as unified_diff)

(define (assert [condition : bool] [message : String]) : unit
  (unless condition (io.panic (str_cat.str-cat message "\n"))))

;; --- capturing sink ---------------------------------------------------------
(define captured : String
  "")
(define sink-calls : i64
  0)
(define fail-call : i64
  0)
(define largest-chunk : i64
  0)

;; Fails its `fail-call`-th call with a broken-pipe-like status; 0 never fails.
(define (capture-sink [chunk : (& bytes)]) : i64
  (begin
    (set! sink-calls (+ sink-calls 1))
    (if (= sink-calls fail-call)
      32
      (begin
        (when
          (> (byte_buf.bytes-length chunk) largest-chunk)
          (set! largest-chunk (byte_buf.bytes-length chunk)))
        (set!
          captured
          (str_cat.str-cat
            (string.copy captured)
            (byte_buf.bytes-to-string chunk)))
        0))))

(defstruct Run
  (text String)
  (report unified_diff.UnifiedDiffReport)
  (calls i64)
  (largest i64))

(define (run-diff
  [path : String]
  [old : String]
  [new : String]
  [options : unified_diff.UnifiedDiffOptions]
  [fail-at : i64]) : Run
  (begin
    (set! captured "")
    (set! sink-calls 0)
    (set! fail-call fail-at)
    (set! largest-chunk 0)
    (let
      [report : unified_diff.UnifiedDiffReport
        (unified_diff.render (& path) (& old) (& new) options capture-sink)]
      (Run (string.copy captured) report sink-calls largest-chunk))))

(define (options [max-bytes : i64] [max-lines : i64] [chunk : i64]) : unified_diff.UnifiedDiffOptions
  (unified_diff.UnifiedDiffOptions max-bytes max-lines chunk))

(define (complete? [run : (& r Run)]) : bool
  (match run.report.outcome
    [(unified_diff.Complete) true]
    [_ false]))

(define (count-newlines [text : (& t str)]) : i64
  (let
    [count : i64 0]
    [cursor : i64 (string.index-of-byte text 0 (cast 10 : u8))]
    (begin
      (while (>= cursor 0)
        (set! count (+ count 1))
        (set! cursor (string.index-of-byte text (+ cursor 1) (cast 10 : u8))))
      count)))

(define (repeat [piece : String] [count : i64]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index count)
        (set! buf (byte_buf.append-string buf (clone piece)))
        (set! index (+ index 1)))
      (byte_buf.to-string buf))))

(define (from-bytes [values : (__tl_dyn-array i64)]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index (array-length values))
        (set! buf (byte_buf.push buf (cast (array-ref values index) : u8)))
        (set! index (+ index 1)))
      (byte_buf.to-string buf))))

;; --- independent patch application -----------------------------------------
(define (split-lines [text : (& t str)]) : svec.Vec
  (let
    [lines : svec.Vec (svec.new)]
    [start : i64 0]
    [next : i64 (string.index-of-byte text 0 (cast 10 : u8))]
    (begin
      (while (>= next 0)
        (svec.push-ref!
          (&mut lines)
          (string.substring text start (- next start)))
        (set! start (+ next 1))
        (set! next (string.index-of-byte text start (cast 10 : u8))))
      (svec.push-ref!
        (&mut lines)
        (string.substring text start (- (string.string-length text) start)))
      lines)))

(defstruct Number
  (value i64)
  (next i64))

(define (read-number [text : (& t str)] [start : i64]) : Number
  (let
    [value : i64 0]
    [index : i64 start]
    (begin
      (while (and
        (< index (string.string-length text))
        (>= (cast (string.string-ref text index) : i64) 48)
        (<= (cast (string.string-ref text index) : i64) 57))
        (set!
          value
          (+ (* value 10) (- (cast (string.string-ref text index) : i64) 48)))
        (set! index (+ index 1)))
      (assert
        (> index start)
        (str_cat.str-cat "expected a number in " (string.copy text)))
      (Number value index))))

(define (hunk-header-row? [rows : (& r svec.Vec)] [row : i64]) : bool
  (let
    [line : String (svec.get rows row "")]
    (string.is-string-prefix-at (& line) "@@" 0)))

;; Apply a rendered diff to `old` and require exactly `new`, checking every
;; header count and context/removed line against the old text on the way.
(define (applies? [old : String] [new : String] [diff : String]) : bool
  (if (= (string.string-length diff) 0)
    (string.eq old new)
    (let
      [old-lines : svec.Vec (split-lines (& old))]
      [rows : svec.Vec (split-lines (& diff))]
      [result : svec.Vec (svec.new)]
      [cursor : i64 0]
      [row : i64 2]
      [ok : bool
        (and
          (string.is-string-prefix-at (& diff) "--- a/" 0)
          (string.eq (svec.get (& rows) (- (svec.len (& rows)) 1) "") ""))]
      (begin
        (while (and ok (< row (- (svec.len (& rows)) 1)))
          (let
            [header : String (svec.get (& rows) row "")]
            [old-first : Number (read-number (& header) 4)]
            [old-count : Number (read-number (& header) (+ old-first.next 1))]
            [new-first : Number (read-number (& header) (+ old-count.next 2))]
            [new-count : Number (read-number (& header) (+ new-first.next 1))]
            [old-seen : i64 0]
            [new-seen : i64 0]
            (begin
              (while (< cursor (- old-first.value 1))
                (svec.push-ref!
                  (&mut result)
                  (svec.get (& old-lines) cursor ""))
                (set! cursor (+ cursor 1)))
              (set! ok (and ok (= (svec.len (& result)) (- new-first.value 1))))
              (set! row (+ row 1))
              (while (and
                ok
                (< row (- (svec.len (& rows)) 1))
                (not (hunk-header-row? (& rows) row)))
                (let
                  [line : String (svec.get (& rows) row "")]
                  [marker : i64 (cast (string.string-ref line 0) : i64)]
                  [body : String
                    (string.substring line 1 (- (string.string-length line) 1))]
                  (begin
                    (when
                      (or (= marker 32) (= marker 45))
                      (set!
                        ok
                        (and
                          ok
                          (string.eq body (svec.get (& old-lines) cursor ""))))
                      (set! cursor (+ cursor 1))
                      (set! old-seen (+ old-seen 1)))
                    (when
                      (or (= marker 32) (= marker 43))
                      (svec.push-ref! (&mut result) body)
                      (set! new-seen (+ new-seen 1)))
                    (set!
                      ok
                      (and ok (or (= marker 32) (= marker 43) (= marker 45))))
                    (set! row (+ row 1)))))
              (set!
                ok
                (and
                  ok
                  (= old-seen old-count.value)
                  (= new-seen new-count.value))))))
        (while (< cursor (svec.len (& old-lines)))
          (svec.push-ref! (&mut result) (svec.get (& old-lines) cursor ""))
          (set! cursor (+ cursor 1)))
        (let
          [new-lines : svec.Vec (split-lines (& new))]
          [index : i64 0]
          (begin
            (set!
              ok
              (and ok (= (svec.len (& result)) (svec.len (& new-lines)))))
            (while (and ok (< index (svec.len (& result))))
              (set!
                ok
                (string.eq
                  (svec.get (& result) index "")
                  (svec.get (& new-lines) index "")))
              (set! index (+ index 1)))
            ok))))))

;; Every complete rendering must apply, and its report must count its bytes.
(define (check-run
  [name : String]
  [old : String]
  [new : String]
  [run : (& r Run)]) : unit
  (begin
    (assert
      (complete? run)
      (str_cat.str-cat (clone name) ": rendering did not complete"))
    (assert
      (= run.report.emitted-bytes (string.string-length run.text))
      (str_cat.str-cat (clone name) ": emitted bytes do not match the output"))
    (assert
      (= run.report.emitted-lines (count-newlines (& run.text)))
      (str_cat.str-cat (clone name) ": emitted lines do not match the output"))
    (assert
      (applies? old new (clone run.text))
      (str_cat.str-cat
        (clone name)
        ": diff does not apply:\n"
        (string.copy run.text)))))

(define (diff [old : String] [new : String]) : String
  (run-diff "t.tl" old new (unified_diff.unbounded) 0).text)

(define (expect-diff
  [name : String]
  [old : String]
  [new : String]
  [expected : String]) : unit
  (let
    [run : Run
      (run-diff "t.tl" (clone old) (clone new) (unified_diff.unbounded) 0)]
    (begin
      (assert
        (string.eq run.text expected)
        (str_cat.str-cat (clone name) ": unexpected diff:\n" run.text))
      (check-run (clone name) old new (& run)))))

;; --- goldens ----------------------------------------------------------------
(test
  unified-diff-goldens
  (begin
    (expect-diff
      "replacement"
      "(a)\n(b   c)\n(d)\n"
      "(a)\n(b c)\n(d)\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,4 +1,4 @@\n (a)\n-(b   c)\n+(b c)\n (d)\n \n")
    (expect-diff "identical" "(a)\n(b)\n" "(a)\n(b)\n" "")
    (expect-diff "both empty" "" "" "")
    (expect-diff
      "from empty"
      ""
      "x\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,1 +1,2 @@\n+x\n \n")
    (expect-diff
      "to empty"
      "x\n"
      ""
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,2 +1,1 @@\n-x\n \n")
    (expect-diff
      "distant hunks"
      "(a)\n(b   c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j   k)\n(l)\n(m)\n(n)\n"
      "(a)\n(b c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j k)\n(l)\n(m)\n(n)\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,5 +1,5 @@\n (a)\n-(b   c)\n+(b c)\n (c)\n (d)\n (e)\n@@ -7,8 +7,8 @@\n (g)\n (h)\n (i)\n-(j   k)\n+(j k)\n (l)\n (m)\n (n)\n \n")
    (expect-diff
      "insertion"
      "(a)\n(b)\n(c)\n(d)\n(e)\n"
      "(a)\n(b)\n(inserted)\n(c)\n(d)\n(e)\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,6 +1,7 @@\n (a)\n (b)\n+(inserted)\n (c)\n (d)\n (e)\n \n")
    (expect-diff
      "deletion"
      "(a)\n(b)\n(gone)\n(c)\n(d)\n(e)\n"
      "(a)\n(b)\n(c)\n(d)\n(e)\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,7 +1,6 @@\n (a)\n (b)\n-(gone)\n (c)\n (d)\n (e)\n \n")
    ;; Repeated delimiter lines are not a three-line anchor, so the insertion
    ;; resynchronizes on the first distinct run rather than the first `)`.
    (expect-diff
      "repeated anchors"
      "(a\n)\n)\n(b\n)\n)\n(c\n"
      "(a\n)\n)\n(new\n)\n)\n(b\n)\n)\n(c\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,8 +1,11 @@\n (a\n )\n )\n+(new\n+)\n+)\n (b\n )\n )\n (c\n \n")
    (expect-diff
      "added final newline"
      "a\nb"
      "a\nb\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,2 +1,3 @@\n a\n b\n+\n")
    (expect-diff
      "removed final newline"
      "a\nb\n"
      "a\nb"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,3 +1,2 @@\n a\n b\n-\n")
    (expect-diff
      "added blank line"
      "a\nb\n"
      "a\nb\n\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,3 +1,4 @@\n a\n b\n \n+\n")
    (expect-diff
      "crlf to lf"
      "a\r\nb\r\n"
      "a\nb\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,3 +1,3 @@\n-a\r\n-b\r\n+a\n+b\n \n")
    (expect-diff
      "non-ascii content"
      "(é)\n(日本)\n"
      "(ü)\n(日本)\n"
      "--- a/t.tl\n+++ b/t.tl\n@@ -1,3 +1,3 @@\n-(é)\n+(ü)\n (日本)\n \n")))

;; Equal-length lines that differ in any single byte must never compare
;; equal, across every word/half-word/byte width of the in-place comparison.
(test
  unified-diff-compares-every-byte-position
  (let
    [len : i64 0]
    (while (<= len 40)
      (let
        [line : String (repeat "x" len)]
        [position : i64 0]
        (begin
          (assert
            (=
              (string.string-length
                (diff
                  (str_cat.str-cat (clone line) "\n")
                  (str_cat.str-cat (clone line) "\n")))
              0)
            "equal lines rendered a diff")
          (while (< position len)
            (let
              [changed : String
                (str_cat.str-cat
                  (string.substring (& line) 0 position)
                  "y"
                  (string.substring
                    (& line)
                    (+ position 1)
                    (- len (+ position 1))))]
              [rendered : String
                (diff
                  (str_cat.str-cat (clone line) "\n")
                  (str_cat.str-cat (clone changed) "\n"))]
              [expected : String
                (str_cat.str-cat "\n-" (clone line) "\n+" changed "\n")]
              (begin
                (assert
                  (string.contains (& rendered) (& expected))
                  (str_cat.str-cat "byte change was not detected:\n" rendered))
                (set! position (+ position 1)))))
          (set! len (+ len 1)))))))

;; Replacements longer than the 64-line lookahead still resynchronize on the
;; equal tail instead of rendering it as removed and added text.
(define (long-replacement [prefix : String]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index 70)
        (set!
          buf
          (byte_buf.append-string
            buf
            (str_cat.str-cat (clone prefix) (string.int->string index) "\n")))
        (set! index (+ index 1)))
      (byte_buf.to-string (byte_buf.append-string buf "tail\n")))))

(test
  unified-diff-resynchronizes-beyond-lookahead
  (let
    [old : String (long-replacement "old-")]
    [new : String (long-replacement "new-")]
    [run : Run
      (run-diff "long.tl" (clone old) (clone new) (unified_diff.unbounded) 0)]
    (begin
      (check-run "long replacement" old new (& run))
      (assert
        (and
          (string.contains (& run.text) "\n tail\n")
          (not (string.contains (& run.text) "-tail\n"))
          (not (string.contains (& run.text) "+tail\n")))
        run.text))))

(define (sparse-fixture [formatted : bool] [lines : i64]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index lines)
        (set!
          buf
          (byte_buf.append-string
            buf
            (if (and (not formatted) (or (= index 8) (= index (- lines 8))))
              (str_cat.str-cat
                "(define  value-"
                (string.int->string index)
                "  0)\n")
              (str_cat.str-cat
                "(define value-"
                (string.int->string index)
                " 0)\n"))))
        (set! index (+ index 1)))
      (byte_buf.to-string buf))))

(test
  unified-diff-output-is-bounded-by-changes-not-distance
  (let
    [old : String (sparse-fixture false 4096)]
    [new : String (sparse-fixture true 4096)]
    [run : Run
      (run-diff "large.tl" (clone old) (clone new) (unified_diff.unbounded) 0)]
    (begin
      (check-run "sparse" old new (& run))
      (assert
        (and
          (< (string.string-length run.text) 4096)
          (string.contains (& run.text) "-(define  value-8  0)\n")
          (string.contains (& run.text) "-(define  value-4088  0)\n")
          (not (string.contains (& run.text) "value-2048")))
        run.text))))

;; --- randomized property ------------------------------------------------------
(define rng-state : i64
  88172645463325252)

(define (rng-below [bound : i64]) : i64
  (begin
    (set! rng-state (bit-xor rng-state (shl rng-state 13)))
    (set! rng-state (bit-xor rng-state (shr rng-state 7)))
    (set! rng-state (bit-xor rng-state (shl rng-state 17)))
    (% (bit-and rng-state 9223372036854775807) bound)))

;; A small alphabet makes repeated anchors, blank lines, CRLF and non-ASCII
;; lines common, and edits are local so hunks resynchronize.
(define (random-line) : String
  (match (rng-below 7)
    [0 "(a)"]
    [1 "(b)"]
    [2 ""]
    [3 ")"]
    [4 "x\r"]
    [5 "(é)"]
    [_ (str_cat.str-cat "(v " (string.int->string (rng-below 1000)) ")")]))

(define (random-text [lines : svec.Vec]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index (svec.len (& lines)))
        (when (> index 0) (set! buf (byte_buf.push buf (cast 10 : u8))))
        (set! buf (byte_buf.append-string buf (svec.get (& lines) index "")))
        (set! index (+ index 1)))
      (byte_buf.to-string buf))))

(define (random-edit [lines : (& l svec.Vec)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [index : i64 0]
    (begin
      (while (< index (svec.len lines))
        (match (rng-below 12)
          [0 unit]
          [1
            (begin
              (svec.push-ref! (&mut out) (random-line))
              (svec.push-ref! (&mut out) (svec.get lines index "")))]
          [2 (svec.push-ref! (&mut out) (random-line))]
          [_ (svec.push-ref! (&mut out) (svec.get lines index ""))])
        (set! index (+ index 1)))
      (when (= (rng-below 3) 0) (svec.push-ref! (&mut out) (random-line)))
      out)))

(test
  unified-diff-random-edits-apply
  (let
    [case : i64 0]
    (while (< case 400)
      (let
        [old-lines : svec.Vec (svec.new)]
        [count : i64
          (rng-below
            (if (< case 200)
              12
              160))]
        (begin
          (while (> count 0)
            (svec.push-ref! (&mut old-lines) (random-line))
            (set! count (- count 1)))
          (let
            [new-lines : svec.Vec (random-edit (& old-lines))]
            [old : String (random-text old-lines)]
            [new : String (random-text new-lines)]
            [run : Run
              (run-diff
                "r.tl"
                (clone old)
                (clone new)
                (unified_diff.unbounded)
                0)]
            (check-run
              (str_cat.str-cat "random case " (string.int->string case))
              old
              new
              (& run)))
          (set! case (+ case 1)))))))

;; --- header quoting -----------------------------------------------------------
(define (expect-headers [path : String] [expected : String]) : unit
  (let
    [run : Run
      (run-diff (clone path) "(a)\n" "(b)\n" (unified_diff.unbounded) 0)]
    (assert
      (string.is-string-prefix-at (& run.text) (& expected) 0)
      (str_cat.str-cat "unexpected headers:\n" run.text))))

(define (octal-digit [text : (& t str)] [index : i64]) : i64
  (- (cast (string.string-ref text index) : i64) 48))

;; Reverse the documented C-style quoting of one header name.
(define (unquote-name [text : String]) : String
  (if (not (string.is-string-prefix-at (& text) "\"" 0))
    text
    (let
      [buf : byte_buf.ByteBuf (byte_buf.new)]
      [index : i64 1]
      [end : i64 (- (string.string-length text) 1)]
      (begin
        (while (< index end)
          (let
            [byte : i64 (cast (string.string-ref text index) : i64)]
            (if (!= byte 92)
              (begin
                (set! buf (byte_buf.push buf (cast byte : u8)))
                (set! index (+ index 1)))
              (let
                [code : i64 (cast (string.string-ref text (+ index 1)) : i64)]
                [letter : i64
                  (string.index-of-byte "abtnvfr" 0 (cast code : u8))]
                (cond
                  [(>= letter 0)
                    (begin
                      (set! buf (byte_buf.push buf (cast (+ letter 7) : u8)))
                      (set! index (+ index 2)))]
                  [(or (= code 34) (= code 92))
                    (begin
                      (set! buf (byte_buf.push buf (cast code : u8)))
                      (set! index (+ index 2)))]
                  [else
                    (begin
                      (set!
                        buf
                        (byte_buf.push
                          buf
                          (cast
                            (+
                              (* 64 (octal-digit (& text) (+ index 1)))
                              (* 8 (octal-digit (& text) (+ index 2)))
                              (octal-digit (& text) (+ index 3)))
                            : u8)))
                      (set! index (+ index 4)))])))))
        (byte_buf.to-string buf)))))

(test
  unified-diff-quotes-unsafe-header-paths
  (let
    [every-byte : (__tl_dyn-array i64) (__tl_make-array i64 256)]
    [index : i64 0]
    (begin
      (expect-headers "src/a.tl" "--- a/src/a.tl\n+++ b/src/a.tl\n@@ ")
      (expect-headers
        "é/日本.tl"
        "--- a/é/日本.tl\n+++ b/é/日本.tl\n@@ ")
      (expect-headers
        "tab\there.tl"
        "--- \"a/tab\\there.tl\"\n+++ \"b/tab\\there.tl\"\n")
      (expect-headers
        "dir\\x.tl"
        "--- \"a/dir\\\\x.tl\"\n+++ \"b/dir\\\\x.tl\"\n")
      (expect-headers "say \"hi\".tl" "--- \"a/say \\\"hi\\\".tl\"\n")
      (expect-headers "line\nbreak\r" "--- \"a/line\\nbreak\\r\"\n")
      (expect-headers
        (from-bytes (__tl_make-array 1 127 27 0))
        "--- \"a/\\001\\177\\033\\000\"\n+++ \"b/\\001\\177\\033\\000\"\n")
      (while (< index 256)
        (set! (array-ref every-byte index) index)
        (set! index (+ index 1)))
      (let
        [path : String (from-bytes every-byte)]
        [run : Run
          (run-diff (clone path) "(a)\n" "(b)\n" (unified_diff.unbounded) 0)]
        [first-end : i64 (string.index-of-byte (& run.text) 0 (cast 10 : u8))]
        [name : String (string.substring (& run.text) 4 (- first-end 4))]
        (assert
          (string.eq (unquote-name (clone name)) (str_cat.str-cat "a/" path))
          (str_cat.str-cat "header quoting is not reversible: " name))))))

;; --- sink failures, chunking and caps -------------------------------------------
(define (distant-old) : String
  "(a)\n(b   c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j   k)\n(l)\n(m)\n(n)\n")

(define (distant-new) : String
  "(a)\n(b c)\n(c)\n(d)\n(e)\n(f)\n(g)\n(h)\n(i)\n(j k)\n(l)\n(m)\n(n)\n")

(define (min-i64 [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(test
  unified-diff-sink-failure-at-every-boundary
  (let
    [full : Run
      (run-diff "t.tl" (distant-old) (distant-new) (unified_diff.unbounded) 0)]
    [total : i64 (string.string-length full.text)]
    [chunks : (Array i64 5) (array 1 2 5 64 65536)]
    [slot : i64 0]
    (while (< slot (array-length chunks))
      (let
        [chunk : i64 (array-ref chunks slot)]
        [whole : Run
          (run-diff
            "t.tl"
            (distant-old)
            (distant-new)
            (options unified_diff.no-limit unified_diff.no-limit chunk)
            0)]
        [call : i64 1]
        (begin
          (assert
            (string.eq whole.text full.text)
            "chunk size changed the rendering")
          (assert (<= whole.largest chunk) "a sink call exceeded chunk-bytes")
          (assert
            (= whole.calls (/ (+ total (- chunk 1)) chunk))
            "chunks were not filled before flushing")
          (while (<= call whole.calls)
            (let
              [run : Run
                (run-diff
                  "t.tl"
                  (distant-old)
                  (distant-new)
                  (options unified_diff.no-limit unified_diff.no-limit chunk)
                  call)]
              [delivered : i64 (min-i64 (* (- call 1) chunk) total)]
              (begin
                (assert
                  (match run.report.outcome
                    [(unified_diff.SinkFailed status) (= status 32)]
                    [_ false])
                  "sink failure was not reported")
                (assert
                  (= run.calls call)
                  "the sink was called after it failed")
                (assert
                  (and
                    (= run.report.emitted-bytes delivered)
                    (= (string.string-length run.text) delivered)
                    (string.eq
                      run.text
                      (string.substring (& full.text) 0 delivered)))
                  "emitted bytes after a failure are wrong")
                (assert
                  (= run.report.emitted-lines (count-newlines (& run.text)))
                  "emitted lines after a failure are wrong")
                (set! call (+ call 1)))))
          (set! slot (+ slot 1)))))))

;; Every line cap and every byte cap yields exactly the longest whole-line
;; prefix within the cap, with exact omitted counts, at any chunk size.
(define (check-cap
  [path : (& p str)]
  [full : (& f Run)]
  [max-bytes : i64]
  [max-lines : i64]
  [chunk : i64]) : unit
  (let
    [run : Run
      (run-diff
        (string.copy path)
        (distant-old)
        (distant-new)
        (options max-bytes max-lines chunk)
        0)]
    [total-bytes : i64 (string.string-length full.text)]
    [total-lines : i64 (count-newlines (& full.text))]
    [kept : i64 0]
    [lines : i64 0]
    [next : i64 (string.index-of-byte (& full.text) 0 (cast 10 : u8))]
    (begin
      (while (and (>= next 0) (< lines max-lines) (<= (+ next 1) max-bytes))
        (set! kept (+ next 1))
        (set! lines (+ lines 1))
        (set!
          next
          (string.index-of-byte (& full.text) (+ next 1) (cast 10 : u8))))
      (assert
        (string.eq run.text (string.substring (& full.text) 0 kept))
        (str_cat.str-cat
          "capped output is not the whole-line prefix:\n"
          run.text))
      (assert
        (and
          (= run.report.emitted-bytes kept)
          (= run.report.emitted-lines lines))
        "capped emitted counts are wrong")
      (assert
        (match run.report.outcome
          [(unified_diff.Complete) (= kept total-bytes)]
          [(unified_diff.Truncated omitted-bytes omitted-lines)
            (and
              (< kept total-bytes)
              (= omitted-bytes (- total-bytes kept))
              (= omitted-lines (- total-lines lines)))]
          [_ false])
        (str_cat.str-cat
          "capped outcome is wrong for bytes="
          (string.int->string max-bytes)
          " lines="
          (string.int->string max-lines)
          " chunk="
          (string.int->string chunk)
          " kept="
          (string.int->string kept)
          (match run.report.outcome
            [(unified_diff.Complete) " complete"]
            [(unified_diff.Truncated omitted-bytes omitted-lines)
              (str_cat.str-cat
                " omitted-bytes="
                (string.int->string omitted-bytes)
                " omitted-lines="
                (string.int->string omitted-lines))]
            [_ " other"]))))))

(define (check-every-cap [path : String]) : unit
  (let
    [full : Run
      (run-diff
        (clone path)
        (distant-old)
        (distant-new)
        (unified_diff.unbounded)
        0)]
    [limit : i64 0]
    (begin
      (while (<= limit (+ (count-newlines (& full.text)) 1))
        (check-cap (& path) (& full) unified_diff.no-limit limit 65536)
        (check-cap (& path) (& full) unified_diff.no-limit limit 3)
        (set! limit (+ limit 1)))
      (set! limit 0)
      (while (<= limit (+ (string.string-length full.text) 1))
        (check-cap (& path) (& full) limit unified_diff.no-limit 65536)
        (check-cap (& path) (& full) limit unified_diff.no-limit 1)
        (set! limit (+ limit 1)))
      (check-cap (& path) (& full) 60 4 7)
      (check-cap
        (& path)
        (& full)
        (- unified_diff.no-limit 1)
        (- unified_diff.no-limit 1)
        65536)
      (check-cap
        (& path)
        (& full)
        unified_diff.no-limit
        unified_diff.no-limit
        1))))

(test
  unified-diff-caps-stop-on-line-boundaries
  (begin
    (check-every-cap "t.tl")
    (check-every-cap
      (str_cat.str-cat "q\t\\" (from-bytes (__tl_make-array 1 127 27 0))))))

(test
  unified-diff-rejects-invalid-options-before-output
  (let
    [invalid : (Array unified_diff.UnifiedDiffOptions 5)
      (array
        (options -1 unified_diff.no-limit 64)
        (options unified_diff.no-limit -1 64)
        (options unified_diff.no-limit unified_diff.no-limit 0)
        (options unified_diff.no-limit unified_diff.no-limit -9)
        (options -9223372036854775807 5 64))]
    [index : i64 0]
    (while (< index (array-length invalid))
      (let
        [run : Run
          (run-diff
            "t.tl"
            (distant-old)
            (distant-new)
            (array-ref invalid index)
            0)]
        (begin
          (assert
            (match run.report.outcome
              [(unified_diff.InvalidOptions) true]
              [_ false])
            "invalid options were accepted")
          (assert
            (and
              (= run.calls 0)
              (= run.report.emitted-bytes 0)
              (= run.report.emitted-lines 0))
            "invalid options reached the sink")
          (set! index (+ index 1)))))))

;; A cap and a failing sink together report the failure, not the truncation.
(test
  unified-diff-sink-failure-outranks-truncation
  (let
    [run : Run
      (run-diff
        "t.tl"
        (distant-old)
        (distant-new)
        (options unified_diff.no-limit 5 1)
        3)]
    (assert
      (match run.report.outcome
        [(unified_diff.SinkFailed status)
          (and (= status 32) (= run.report.emitted-bytes 2))]
        [_ false])
      "a failing capped rendering was not reported as a sink failure")))

;; --- large inputs -----------------------------------------------------------------
(test
  unified-diff-streams-an-enormous-single-line
  (let
    [old : String (repeat "a" 200000)]
    [new : String (repeat "b" 200000)]
    [expected : String
      (str_cat.str-cat
        "--- a/t.tl\n+++ b/t.tl\n@@ -1,1 +1,1 @@\n-"
        (clone old)
        "\n+"
        (clone new)
        "\n")]
    [run : Run
      (run-diff "t.tl" (clone old) (clone new) (unified_diff.unbounded) 0)]
    (begin
      (assert (string.eq run.text expected) "enormous line diff differs")
      (assert
        (and
          (= run.largest unified_diff.default-chunk-bytes)
          (= run.calls (/ (+ (string.string-length expected) 65535) 65536))
          (= run.report.emitted-lines 5))
        "enormous line was not streamed in bounded chunks")
      (let
        [huge : Run
          (run-diff
            "t.tl"
            (clone old)
            (clone new)
            (options
              unified_diff.no-limit
              unified_diff.no-limit
              unified_diff.no-limit)
            0)]
        (assert
          (and
            (string.eq huge.text expected)
            (= huge.largest unified_diff.default-chunk-bytes))
          "an oversized chunk-bytes was not clamped to the staging buffer")))))

(test
  unified-diff-full-replacement-of-many-tiny-lines
  (let
    [old : String (repeat "x\n" 20000)]
    [new : String (repeat "y\n" 20000)]
    [run : Run
      (run-diff "t.tl" (clone old) (clone new) (unified_diff.unbounded) 0)]
    (begin
      (check-run "tiny lines" old new (& run))
      (assert
        (and
          (string.is-string-prefix-at
            (& run.text)
            "--- a/t.tl\n+++ b/t.tl\n@@ -1,20001 +1,20001 @@\n-x\n"
            0)
          (= run.report.emitted-lines 40004)
          (<= run.largest unified_diff.default-chunk-bytes))
        "tiny-line replacement is wrong"))))

;; --- allocation bound -------------------------------------------------------------
(define counted-bytes : i64
  0)

(define (counting-sink [chunk : (& bytes)]) : i64
  (begin
    (set! counted-bytes (+ counted-bytes (byte_buf.bytes-length chunk)))
    0))

(define (wide-fixture [marker : String]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [line : String (str_cat.str-cat "(" (repeat marker 96) ")\n")]
    [index : i64 0]
    (begin
      (while (< index 4096)
        (set! buf (byte_buf.append-string buf (clone line)))
        (set! index (+ index 1)))
      (byte_buf.to-string buf))))

;; Rendering allocates the two line indexes and one staging chunk, never
;; storage proportional to its output.
(test
  unified-diff-allocation-is-independent-of-output-size
  (let
    [old : String (wide-fixture "o")]
    [new : String (wide-fixture "n")]
    [path : String "wide.tl"]
    [before : i64 (profile.alloc-total)]
    [report : unified_diff.UnifiedDiffReport
      (unified_diff.render
        (& path)
        (& old)
        (& new)
        (unified_diff.unbounded)
        counting-sink)]
    [allocated : i64 (- (profile.alloc-total) before)]
    [bound : i64 (+ (* 16 (+ 4097 2)) unified_diff.default-chunk-bytes 4096)]
    (begin
      (assert
        (> counted-bytes (* 4 bound))
        "fixture output is too small to discriminate the allocation bound")
      (assert
        (= counted-bytes report.emitted-bytes)
        "counting sink disagrees with the report")
      (assert
        (<= allocated bound)
        (str_cat.str-cat
          "render allocated "
          (string.int->string allocated)
          " bytes; bound "
          (string.int->string bound))))))