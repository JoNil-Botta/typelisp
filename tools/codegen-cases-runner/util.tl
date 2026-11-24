;; Shared utilities for the native codegen-cases runner.
;; Zero external dependencies; works on Linux and Windows.
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as bbc)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)

(defstruct ParsedI64
  (ok bool)
  (value i64))

(defstruct ReadFileResult
  (ok bool)
  (text String))

(defstruct VarTable
  (keys svec.Vec)
  (values svec.Vec))

(define (host-is-windows?) : bool
  (cfg windows true false))

(define (host-name) : String
  (cfg windows "windows" "linux"))

(define (byte-at [text : (& text str)] [index : i64]) : i64
  (cast (string.string-ref text index) : i64))

(define (is-blank-byte? [b : i64]) : bool
  (or (= b 32) (= b 9)))

(define (is-space-byte? [b : i64]) : bool
  (or (= b 32) (= b 9) (= b 10) (= b 13) (= b 11) (= b 12)))

(define (is-digit-byte? [b : i64]) : bool
  (and (>= b 48) (<= b 57)))

(define (is-lower-byte? [b : i64]) : bool
  (and (>= b 97) (<= b 122)))

(define (is-upper-byte? [b : i64]) : bool
  (and (>= b 65) (<= b 90)))

(define (is-alpha-byte? [b : i64]) : bool
  (or (is-lower-byte? b) (is-upper-byte? b)))

(define (is-alnum-byte? [b : i64]) : bool
  (or (is-alpha-byte? b) (is-digit-byte? b)))

(define (is-xdigit-byte? [b : i64]) : bool
  (or (is-digit-byte? b) (and (>= b 97) (<= b 102)) (and (>= b 65) (<= b 70))))

(define (ascii-lower-byte [b : i64]) : i64
  (if (is-upper-byte? b)
    (+ b 32)
    b))

(define (ascii-upper-byte [b : i64]) : i64
  (if (is-lower-byte? b)
    (- b 32)
    b))

(define (starts-with? [text : (& text str)] [prefix : (& prefix str)]) : bool
  (let
    [tlen : i64 (string.string-length text)]
    [plen : i64 (string.string-length prefix)]
    (if (< tlen plen)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (while (and ok (< i plen))
          (if (!= (byte-at text i) (byte-at prefix i))
            (set! ok false)
            (set! i (+ i 1))))
        ok))))

(define (ends-with? [text : (& text str)] [suffix : (& suffix str)]) : bool
  (let
    [tlen : i64 (string.string-length text)]
    [slen : i64 (string.string-length suffix)]
    (if (< tlen slen)
      false
      (let
        [offset : i64 (- tlen slen)]
        [i : i64 0]
        [ok : bool true]
        (while (and ok (< i slen))
          (if (!= (byte-at text (+ offset i)) (byte-at suffix i))
            (set! ok false)
            (set! i (+ i 1))))
        ok))))

(define (index-of-byte-from [text : (& text str)] [start : i64] [target : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [found : i64 -1]
    (while (and (= found -1) (< i n))
      (if (= (byte-at text i) target)
        (set! found i)
        (set! i (+ i 1))))
    found))

(define (index-of-str-from
  [haystack : (& haystack str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [hlen : i64 (string.string-length haystack)]
    [nlen : i64 (string.string-length needle)]
    (cond
      [(= nlen 0)
        (if (<= start hlen)
          start
          -1)]
      [(> (+ start nlen) hlen) -1]
      [else
        (let
          [first : i64 (byte-at needle 0)]
          [limit : i64 (- hlen nlen)]
          [i : i64 start]
          [found : i64 -1]
          (while (and (= found -1) (<= i limit))
            (if (= (byte-at haystack i) first)
              (let
                [j : i64 1]
                [eq : bool true]
                (while (and eq (< j nlen))
                  (if (!= (byte-at haystack (+ i j)) (byte-at needle j))
                    (set! eq false)
                    (set! j (+ j 1))))
                (if eq
                  (set! found i)
                  (set! i (+ i 1))))
              (set! i (+ i 1))))
          found)])))

(define (strip-cr [line : (& line str)]) : String
  (let
    [n : i64 (string.string-length line)]
    (if (and (> n 0) (= (byte-at line (- n 1)) 13))
      (string.substring line 0 (- n 1))
      (string.copy line))))

(define (trim-leading-blanks [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    (while (and (< i n) (is-blank-byte? (byte-at text i)))
      (set! i (+ i 1)))
    (string.substring text i (- n i))))

(define (trim-blanks [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [start : i64 0]
    [end : i64 n]
    (while (and (< start end) (is-blank-byte? (byte-at text start)))
      (set! start (+ start 1)))
    (while (and (> end start) (is-blank-byte? (byte-at text (- end 1))))
      (set! end (- end 1)))
    (string.substring text start (- end start))))

(define (split-lines [text : (& text str)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (string.string-length text)]
    [start : i64 0]
    [i : i64 0]
    (while (< i n)
      (if (= (byte-at text i) 10)
        (begin
          (svec.push-ref! (&mut out) (string.substring text start (- i start)))
          (set! start (+ i 1))
          (set! i (+ i 1)))
        (set! i (+ i 1))))
    (when
      (< start n)
      (svec.push-ref! (&mut out) (string.substring text start (- n start))))
    out))

(define (split-words-blank [text : (& text str)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (string.string-length text)]
    [i : i64 0]
    (while (< i n)
      (while (and (< i n) (is-blank-byte? (byte-at text i)))
        (set! i (+ i 1)))
      (let
        [start : i64 i]
        (while (and (< i n) (not (is-blank-byte? (byte-at text i))))
          (set! i (+ i 1)))
        (when
          (> i start)
          (svec.push-ref! (&mut out) (string.substring text start (- i start))))))
    out))

(define (split-by-sep [text : (& text str)] [sep : (& sep str)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (string.string-length text)]
    [slen : i64 (string.string-length sep)]
    [start : i64 0]
    [done : bool false]
    (while (not done)
      (let
        [pos : i64 (index-of-str-from text sep start)]
        (if (< pos 0)
          (begin
            (svec.push-ref!
              (&mut out)
              (string.substring text start (- n start)))
            (set! done true))
          (begin
            (svec.push-ref!
              (&mut out)
              (string.substring text start (- pos start)))
            (set! start (+ pos slen))))))
    out))

(define (parse-u64-strict [text : (& text str)]) : ParsedI64
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      (ParsedI64 false 0)
      (let
        [i : i64 0]
        [acc : i64 0]
        [ok : bool true]
        (while (and ok (< i n))
          (let
            [b : i64 (byte-at text i)]
            (if (is-digit-byte? b)
              (begin
                (set! acc (+ (* acc 10) (- b 48)))
                (set! i (+ i 1)))
              (set! ok false))))
        (ParsedI64 ok acc)))))

(define (parse-i64-strict [text : (& text str)]) : ParsedI64
  (let
    [n : i64 (string.string-length text)]
    (cond
      [(= n 0) (ParsedI64 false 0)]
      [(= (byte-at text 0) 45)
        (let
          [rest : String (string.substring text 1 (- n 1))]
          [p : ParsedI64 (parse-u64-strict (& rest))]
          (ParsedI64 p.ok (- 0 p.value)))]
      [else (parse-u64-strict text)])))

;; Glob matching (*, ?, [...], \x) matching POSIX sh case patterns.
(define (glob-match-at
  [pat : (& pat str)]
  [pi : i64]
  [plen : i64]
  [text : (& text str)]
  [ti : i64]
  [tlen : i64]) : bool
  (cond
    [(>= pi plen) (= ti tlen)]
    [(= (byte-at pat pi) 42)
      ;; '*'
      (let
        [next-pi : i64 (+ pi 1)]
        (while (and (< next-pi plen) (= (byte-at pat next-pi) 42))
          (set! next-pi (+ next-pi 1)))
        (if (>= next-pi plen)
          true
          (let
            [k : i64 ti]
            [matched : bool false]
            (while (and (not matched) (<= k tlen))
              (if (glob-match-at pat next-pi plen text k tlen)
                (set! matched true)
                (set! k (+ k 1))))
            matched)))]
    [(>= ti tlen) false]
    [(= (byte-at pat pi) 63)
      ;; '?'
      (glob-match-at pat (+ pi 1) plen text (+ ti 1) tlen)]
    [(= (byte-at pat pi) 92)
      ;; '\x'
      (if (< (+ pi 1) plen)
        (if (= (byte-at pat (+ pi 1)) (byte-at text ti))
          (glob-match-at pat (+ pi 2) plen text (+ ti 1) tlen)
          false)
        (if (= 92 (byte-at text ti))
          (glob-match-at pat (+ pi 1) plen text (+ ti 1) tlen)
          false))]
    [(= (byte-at pat pi) 91)
      ;; '[...]'
      (let
        [j : i64 (+ pi 1)]
        [neg : bool false]
        [tb : i64 (byte-at text ti)]
        [hit : bool false]
        [closed : bool false]
        (when
          (and (< j plen) (or (= (byte-at pat j) 33) (= (byte-at pat j) 94)))
          (set! neg true)
          (set! j (+ j 1)))
        (when
          (and (< j plen) (= (byte-at pat j) 93))
          (when (= tb 93) (set! hit true))
          (set! j (+ j 1)))
        (while (and (< j plen) (not closed))
          (if (= (byte-at pat j) 93)
            (set! closed true)
            (if (and
              (< (+ j 2) plen)
              (= (byte-at pat (+ j 1)) 45)
              (!= (byte-at pat (+ j 2)) 93))
              (begin
                (when
                  (and (>= tb (byte-at pat j)) (<= tb (byte-at pat (+ j 2))))
                  (set! hit true))
                (set! j (+ j 3)))
              (begin
                (when (= tb (byte-at pat j)) (set! hit true))
                (set! j (+ j 1))))))
        (if closed
          (let
            [ok : bool
              (if neg
                (not hit)
                hit)]
            (if ok
              (glob-match-at pat (+ j 1) plen text (+ ti 1) tlen)
              false))
          (if (= 91 tb)
            (glob-match-at pat (+ pi 1) plen text (+ ti 1) tlen)
            false)))]
    [else
      (if (= (byte-at pat pi) (byte-at text ti))
        (glob-match-at pat (+ pi 1) plen text (+ ti 1) tlen)
        false)]))

(define (glob-match? [pat : (& pat str)] [text : (& text str)]) : bool
  (glob-match-at
    pat
    0
    (string.string-length pat)
    text
    0
    (string.string-length text)))

;; Sanitize --only glob for workdir suffix (equivalent to tr -c 'A-Za-z0-9._-' '_').
(define (sanitize-only-suffix [glob : (& glob str)]) : String
  (let
    [n : i64 (string.string-length glob)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (byte-at glob i)]
        [keep : bool (or (is-alnum-byte? b) (= b 46) (= b 95) (= b 45))]
        (bbc.byte-buf-builder-push
          (&mut out)
          (cast
            (if keep
              b
              95)
            : u8)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

;; Convert backslashes to forward slashes.
(define (slashes-to-forward [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (byte-at path i)]
        (bbc.byte-buf-builder-push
          (&mut out)
          (cast
            (if (= b 92)
              47
              b)
            : u8)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

;; Convert forward slashes to backslashes (for Windows lld-link / cygpath -aw).
(define (slashes-to-back [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (byte-at path i)]
        (bbc.byte-buf-builder-push
          (&mut out)
          (cast
            (if (= b 47)
              92
              b)
            : u8)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

;; Pure-string equivalent of `cygpath -m` on Windows, identity on Linux.
;; Uses root -> native-root prefix mapping first so MSYS2 mounts match exactly.
(define (to-native-path
  [path : (& path str)]
  [root : (& root str)]
  [native-root : (& native-root str)]) : String
  (if (not (host-is-windows?))
    (string.copy path)
    (let
      [rlen : i64 (string.string-length root)]
      [plen : i64 (string.string-length path)]
      (cond
        [(and
            (> rlen 0)
            (starts-with? path root)
            (or
              (= plen rlen)
              (= (byte-at path rlen) 47)
              (= (byte-at path rlen) 92)))
          (let
            [tail : String (string.substring path rlen (- plen rlen))]
            [norm-tail : String (slashes-to-forward (& tail))]
            (str_cat.str-cat (string.copy native-root) norm-tail))]
        [(and
            (>= plen 2)
            (= (byte-at path 0) 47)
            (is-alpha-byte? (byte-at path 1))
            (or (= plen 2) (= (byte-at path 2) 47)))
          ;; /d/a/... -> D:/a/...
          (let
            [out : bbc.ByteBufBuilder
              (bbc.byte-buf-builder-with-capacity (+ plen 1))]
            [drive : i64 (ascii-upper-byte (byte-at path 1))]
            (bbc.byte-buf-builder-push (&mut out) (cast drive : u8))
            (bbc.byte-buf-builder-push (&mut out) (cast 58 : u8))
            (if (= plen 2)
              (bbc.byte-buf-builder-push (&mut out) (cast 47 : u8))
              (let
                [i : i64 2]
                (while (< i plen)
                  (let
                    [b : i64 (byte-at path i)]
                    (bbc.byte-buf-builder-push
                      (&mut out)
                      (cast
                        (if (= b 92)
                          47
                          b)
                        : u8)))
                  (set! i (+ i 1)))))
            (bbc.byte-buf-builder-finish-string (& out)))]
        [(and
            (>= plen 2)
            (is-alpha-byte? (byte-at path 0))
            (= (byte-at path 1) 58))
          ;; D:\a\... -> D:/a/...
          (slashes-to-forward path)]
        [else (slashes-to-forward path)]))))

(define (to-win-backslash-path
  [path : (& path str)]
  [root : (& root str)]
  [native-root : (& native-root str)]) : String
  (let
    [mixed : String (to-native-path path root native-root)]
    (slashes-to-back (& mixed))))

;; Pure-string conversion from Windows drive path (`D:/a/...` or `D:\a\...`) to
;; MSYS2 POSIX path (`/d/a/...`). Leaves already-POSIX and relative paths intact.
(define (to-msys-posix-path [path : (& path str)]) : String
  (let
    [plen : i64 (string.string-length path)]
    (if (and
      (>= plen 2)
      (is-alpha-byte? (byte-at path 0))
      (= (byte-at path 1) 58)
      (or (= plen 2) (= (byte-at path 2) 47) (= (byte-at path 2) 92)))
      (let
        [out : bbc.ByteBufBuilder
          (bbc.byte-buf-builder-with-capacity (+ plen 1))]
        [drive : i64 (ascii-lower-byte (byte-at path 0))]
        [i : i64 2]
        (bbc.byte-buf-builder-push (&mut out) (cast 47 : u8))
        (bbc.byte-buf-builder-push (&mut out) (cast drive : u8))
        (while (< i plen)
          (let
            [b : i64 (byte-at path i)]
            (bbc.byte-buf-builder-push
              (&mut out)
              (cast
                (if (= b 92)
                  47
                  b)
                : u8)))
          (set! i (+ i 1)))
        (bbc.byte-buf-builder-finish-string (& out)))
      (slashes-to-forward path))))

;; Normalize a POSIX-style PATH override (e.g. `D:/a/bin:$PATH` or `/d/a/bin:$PATH`)
;; into a valid Windows `;`-separated PATH, preserving Windows drive colons (`C:\`, `D:/`).
(define (normalize-windows-path-env [raw : (& raw str)]) : String
  (let
    [n : i64 (string.string-length raw)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity (+ n 4))]
    [seg-start : bool true]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (byte-at raw i)]
        (cond
          [(and
            seg-start
            (< (+ i 1) n)
            (= b 47)
            (is-alpha-byte? (byte-at raw (+ i 1)))
            (or (= (+ i 2) n) (= (byte-at raw (+ i 2)) 47)))
            ;; MSYS2 `/d/...` at segment start -> `D:/...`
            (bbc.byte-buf-builder-push
              (&mut out)
              (cast (ascii-upper-byte (byte-at raw (+ i 1))) : u8))
            (bbc.byte-buf-builder-push (&mut out) (cast 58 : u8))
            (when
              (= (+ i 2) n)
              (bbc.byte-buf-builder-push (&mut out) (cast 47 : u8)))
            (set! seg-start false)
            (set! i (+ i 2))]
          [(and
            seg-start
            (< (+ i 2) n)
            (is-alpha-byte? b)
            (= (byte-at raw (+ i 1)) 58)
            (or (= (byte-at raw (+ i 2)) 47) (= (byte-at raw (+ i 2)) 92)))
            ;; Windows drive prefix `C:\` or `D:/` at segment start: keep colon.
            (bbc.byte-buf-builder-push (&mut out) (cast b : u8))
            (bbc.byte-buf-builder-push (&mut out) (cast 58 : u8))
            (bbc.byte-buf-builder-push
              (&mut out)
              (cast (byte-at raw (+ i 2)) : u8))
            (set! seg-start false)
            (set! i (+ i 3))]
          [(= b 59)
            ;; Existing `;` separator.
            (bbc.byte-buf-builder-push (&mut out) (cast 59 : u8))
            (set! seg-start true)
            (set! i (+ i 1))]
          [(= b 58)
            ;; Non-drive `:` is a POSIX PATH separator -> `;`.
            (bbc.byte-buf-builder-push (&mut out) (cast 59 : u8))
            (set! seg-start true)
            (set! i (+ i 1))]
          [else
            (bbc.byte-buf-builder-push (&mut out) (cast b : u8))
            (set! seg-start false)
            (set! i (+ i 1))])))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (win-fs-path [path : (& path str)]) : String
  (cfg windows (to-native-path path "" "") (string.copy path)))

(define (is-absolute-path? [path : (& path str)]) : bool
  (let
    [n : i64 (string.string-length path)]
    (cond
      [(and (>= n 1) (= (byte-at path 0) 47)) true]
      [(and
          (>= n 3)
          (is-alpha-byte? (byte-at path 0))
          (= (byte-at path 1) 58)
          (or (= (byte-at path 2) 47) (= (byte-at path 2) 92)))
        true]
      [else false])))

(define (resolve-path [path : (& path str)] [base : (& base str)]) : String
  (if (is-absolute-path? path)
    (string.copy path)
    (str_cat.str-cat (string.copy base) "/" (string.copy path))))

(define (path-dirname [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [end : i64 n]
    (while (and
      (> end 1)
      (or (= (byte-at path (- end 1)) 47) (= (byte-at path (- end 1)) 92)))
      (set! end (- end 1)))
    (let
      [i : i64 (- end 1)]
      [slash : i64 -1]
      (while (and (= slash -1) (>= i 0))
        (if (or (= (byte-at path i) 47) (= (byte-at path i) 92))
          (set! slash i)
          (set! i (- i 1))))
      (cond
        [(< slash 0) "."]
        [(= slash 0) "/"]
        [(and (= slash 2) (= (byte-at path 1) 58)) (string.substring path 0 3)]
        [else (string.substring path 0 slash)]))))

(define (path-basename-strip-cases [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [i : i64 (- n 1)]
    [slash : i64 -1]
    (while (and (= slash -1) (>= i 0))
      (if (or (= (byte-at path i) 47) (= (byte-at path i) 92))
        (set! slash i)
        (set! i (- i 1))))
    (let
      [base : String (string.substring path (+ slash 1) (- n (+ slash 1)))]
      [blen : i64 (string.string-length (& base))]
      (if (ends-with? (& base) ".cases")
        (string.substring (& base) 0 (- blen 6))
        base))))

;; Filesystem helpers (zero external process forks).
(define (mkdir-all! [dir : (& dir str)]) : bool
  (let
    [ndir : String (win-fs-path dir)]
    [n : i64 (string.string-length (& ndir))]
    (if (= n 0)
      true
      (match (fs.try-file-kind (& ndir))
        [(fs.OkFsFileKind kind) (fs.file-kind-directory? kind)]
        [(fs.ErrFsFileKind _)
          (let
            [parent : String (path-dirname (& ndir))]
            (if (or
              (string.eq (& parent) (& ndir))
              (string.eq (& parent) ".")
              (string.eq (& parent) "/"))
              (match (fs.try-mkdir-if-missing (& ndir))
                [(io.OkIoUnit) true]
                [(io.ErrIoUnit _) false])
              (if (mkdir-all! (& parent))
                (match (fs.try-mkdir-if-missing (& ndir))
                  [(io.OkIoUnit) true]
                  [(io.ErrIoUnit _) false])
                false)))]))))

(define (rm-rf! [path : (& path str)]) : unit
  (let
    [npath : String (win-fs-path path)]
    (match (fs.try-file-kind-no-follow (& npath))
      [(fs.ErrFsFileKind _) unit]
      [(fs.OkFsFileKind kind)
        (if (fs.file-kind-directory? kind)
          (begin
            (match (fs.try-read-dir (& npath))
              [(fs.OkIoStringVector entries)
                (let
                  [i : i64 0]
                  [count : i64 (svec.len (& entries.items))]
                  (while (< i count)
                    (let
                      [name : String (svec.get (& entries.items) i "")]
                      [child : String
                        (str_cat.str-cat (string.copy (& npath)) "/" name)]
                      (rm-rf! (& child)))
                    (set! i (+ i 1))))]
              [(fs.ErrIoStringVector _) unit])
            (fs.try-remove-dir-if-exists (& npath))
            unit)
          (begin
            ;; On Windows, NTFS directory junctions report as FsFileOther and
            ;; require RemoveDirectoryA rather than DeleteFileA.
            (match (fs.try-remove-file-if-exists (& npath))
              [(io.OkIoUnit) unit]
              [(io.ErrIoUnit _)
                (when
                  (host-is-windows?)
                  (match (fs.try-remove-dir-if-exists (& npath))
                    [(io.OkIoUnit) unit]
                    [(io.ErrIoUnit _) unit]))])
            unit))])))

(define (file-exists? [path : (& path str)]) : bool
  (let
    [npath : String (win-fs-path path)]
    (match (fs.try-file-kind (& npath))
      [(fs.OkFsFileKind _) true]
      [(fs.ErrFsFileKind _) false])))

(define (is-regular-file? [path : (& path str)]) : bool
  (let
    [npath : String (win-fs-path path)]
    (match (fs.try-file-kind (& npath))
      [(fs.OkFsFileKind kind) (fs.file-kind-regular? kind)]
      [(fs.ErrFsFileKind _) false])))

(define (is-dir? [path : (& path str)]) : bool
  (let
    [npath : String (win-fs-path path)]
    (match (fs.try-file-kind (& npath))
      [(fs.OkFsFileKind kind) (fs.file-kind-directory? kind)]
      [(fs.ErrFsFileKind _) false])))

(define (file-nonempty? [path : (& path str)]) : bool
  (let
    [npath : String (win-fs-path path)]
    (if (is-regular-file? (& npath))
      (> (fs.file-size (& npath)) 0)
      false)))

(define (is-executable? [path : (& path str)]) : bool
  (cfg
    windows
    (is-regular-file? path)
    (if (not (file-exists? path))
      false
      (let
        [cpath : (__tl_dyn-array u8) (io.c-string (string.copy path))]
        [res : i64
          (unsafe
            (syscall
              21
              (cast (ptr->int (io.array-const-ptr cpath)) : i64)
              1
              0
              0
              0
              0))]
        (= res 0)))))

(define (read-file-result [path : (& path str)]) : ReadFileResult
  (let
    [npath : String (win-fs-path path)]
    (match (io.try-read-file (& npath))
      [(io.OkIoBytes buf) (ReadFileResult true (byte_buf.to-string buf))]
      [(io.ErrIoBytes _) (ReadFileResult false "")])))

(define (write-file-ok? [path : (& path str)] [content : (& content str)]) : bool
  (let
    [npath : String (win-fs-path path)]
    [parent : String (path-dirname (& npath))]
    (when
      (not (string.eq (& parent) "."))
      (let
        [_ok : bool (mkdir-all! (& parent))]
        unit))
    (match (io.try-write-file (& npath) (byte_buf.str-as-bytes content))
      [(io.OkIoUnit) true]
      [(io.ErrIoUnit _) false])))

(define (ensure-dir! [dir : (& dir str)]) : unit
  (let
    [_ok : bool (mkdir-all! dir)]
    unit))

(define (write-file! [path : (& path str)] [content : (& content str)]) : unit
  (let
    [_ok : bool (write-file-ok? path content)]
    unit))

(define (rename-ignore! [src : (& src str)] [dst : (& dst str)]) : unit
  (let
    [nsrc : String (win-fs-path src)]
    [ndst : String (win-fs-path dst)]
    (match (fs.try-rename (& nsrc) (& ndst))
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit _) unit])))

(define (remove-file-ignore! [path : (& path str)]) : unit
  (let
    [npath : String (win-fs-path path)]
    (match (fs.try-remove-file-if-exists (& npath))
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit _) unit])))

(define (append-file-ignore! [path : (& path str)] [content : (& content str)]) : unit
  (let
    [npath : String (win-fs-path path)]
    (match (io.try-append-file (& npath) (byte_buf.str-as-bytes content))
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit _) unit])))

(define (copy-file-ok? [src : (& src str)] [dst : (& dst str)]) : bool
  (let
    [r : ReadFileResult (read-file-result src)]
    (if r.ok
      (write-file-ok? dst (& r.text))
      false)))

(define (copy-recursive-ok? [src : (& src str)] [dst : (& dst str)]) : bool
  (let
    [nsrc : String (win-fs-path src)]
    [ndst : String (win-fs-path dst)]
    (match (fs.try-file-kind (& nsrc))
      [(fs.ErrFsFileKind _) false]
      [(fs.OkFsFileKind kind)
        (if (fs.file-kind-directory? kind)
          (if (not (mkdir-all! (& ndst)))
            false
            (match (fs.try-read-dir (& nsrc))
              [(fs.ErrIoStringVector _) false]
              [(fs.OkIoStringVector entries)
                (let
                  [i : i64 0]
                  [count : i64 (svec.len (& entries.items))]
                  [ok : bool true]
                  (while (and ok (< i count))
                    (let
                      [name : String (svec.get (& entries.items) i "")]
                      [csrc : String
                        (str_cat.str-cat
                          (string.copy (& nsrc))
                          "/"
                          (string.copy (& name)))]
                      [cdst : String
                        (str_cat.str-cat (string.copy (& ndst)) "/" name)]
                      (when
                        (not (copy-recursive-ok? (& csrc) (& cdst)))
                        (set! ok false)))
                    (set! i (+ i 1)))
                  ok)]))
          (copy-file-ok? (& nsrc) (& ndst)))])))

(define (files-equal? [a : (& a str)] [b : (& b str)]) : bool
  (let
    [ra : ReadFileResult (read-file-result a)]
    [rb : ReadFileResult (read-file-result b)]
    (and ra.ok rb.ok (string.eq (& ra.text) (& rb.text)))))

;; Resolve an executable name along PATH (or return as-is if it contains a path separator).
(define (probe-executable-candidate [candidate : (& candidate str)]) : String
  (if (host-is-windows?)
    (let
      [nc : String (win-fs-path candidate)]
      (cond
        [(is-regular-file? (str_cat.str-cat (string.copy (& nc)) ".exe"))
          (str_cat.str-cat nc ".exe")]
        [(is-regular-file? (& nc)) nc]
        [(is-regular-file? (str_cat.str-cat (string.copy (& nc)) ".cmd"))
          (str_cat.str-cat nc ".cmd")]
        [(is-regular-file? (str_cat.str-cat (string.copy (& nc)) ".bat"))
          (str_cat.str-cat nc ".bat")]
        [else ""]))
    (if (and (is-regular-file? candidate) (is-executable? candidate))
      (string.copy candidate)
      "")))

(define (resolve-executable-in-path
  [name : (& name str)]
  [path-env : (& path-env str)]) : String
  (if (or
    (>= (index-of-byte-from name 0 47) 0)
    (>= (index-of-byte-from name 0 92) 0)
    (and (>= (string.string-length name) 2) (= (byte-at name 1) 58)))
    (let
      [direct : String (probe-executable-candidate name)]
      (if (> (string.string-length (& direct)) 0)
        direct
        (string.copy name)))
    (let
      [sep : String
        (if (host-is-windows?)
          ";"
          ":")]
      [dirs : svec.Vec (env.path-split-with-separator-vec path-env (& sep))]
      [n : i64 (svec.len (& dirs))]
      [i : i64 0]
      [found : String ""]
      (while (and (= (string.string-length (& found)) 0) (< i n))
        (let
          [d : String (svec.get (& dirs) i "")]
          (when
            (> (string.string-length (& d)) 0)
            (let
              [cand : String (str_cat.str-cat d "/" (string.copy name))]
              [hit : String (probe-executable-candidate (& cand))]
              (when (> (string.string-length (& hit)) 0) (set! found hit)))))
        (set! i (+ i 1)))
      found)))

(define (resolve-executable [name : (& name str)]) : String
  (let
    [path-val : String
      (match (env.get "PATH")
        [(env.EnvSomeString v) v]
        [(env.EnvNoString) ""])]
    (resolve-executable-in-path name (& path-val))))

;; FNV-1a 64-bit hex hash (replaces cksum for compile cache keys).
(define (fnv1a-hex [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [h : u64 (cast 14695981039346656037 : u64)]
    [prime : u64 (cast 1099511628211 : u64)]
    [i : i64 0]
    (while (< i n)
      (set! h (* (bit-xor h (cast (byte-at text i) : u64)) prime))
      (set! i (+ i 1)))
    (let
      [hex : String "0123456789abcdef"]
      [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity 16)]
      [shift : i64 60]
      (while (>= shift 0)
        (let
          [nib : i64
            (cast (bit-and (shr h (cast shift : u64)) (cast 15 : u64)) : i64)]
          (bbc.byte-buf-builder-push
            (&mut out)
            (cast (byte-at (& hex) nib) : u8)))
        (set! shift (- shift 4)))
      (bbc.byte-buf-builder-finish-string (& out)))))

;; VarTable: CCV_* variable store with '-' normalized to '_'.
(define (normalize-var-name [name : (& name str)]) : String
  (let
    [n : i64 (string.string-length name)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (byte-at name i)]
        (bbc.byte-buf-builder-push
          (&mut out)
          (cast
            (if (= b 45)
              95
              b)
            : u8)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (valid-var-name? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (= n 0)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (while (and ok (< i n))
          (let
            [b : i64 (byte-at name i)]
            (if (or (is-alnum-byte? b) (= b 95) (= b 45))
              (set! i (+ i 1))
              (set! ok false))))
        ok))))

(define (var-table-new) : VarTable
  (VarTable (svec.new) (svec.new)))

(define (var-table-set!
  [vars : (&mut vars VarTable)]
  [name : (& name str)]
  [value : (& value str)]) : unit
  (let
    [key : String (normalize-var-name name)]
    [n : i64 (svec.len (& vars.keys))]
    [i : i64 0]
    [found : bool false]
    (while (and (not found) (< i n))
      (if (string.eq (svec.get (& vars.keys) i "") (& key))
        (begin
          (svec.set-ref! (&mut vars.values) i (string.copy value))
          (set! found true))
        (set! i (+ i 1))))
    (when
      (not found)
      (svec.push-ref! (&mut vars.keys) key)
      (svec.push-ref! (&mut vars.values) (string.copy value)))))

(define (var-table-get [vars : (& vars VarTable)] [name : (& name str)]) : String
  (let
    [key : String (normalize-var-name name)]
    [n : i64 (svec.len (& vars.keys))]
    [i : i64 0]
    [found : String ""]
    [done : bool false]
    (while (and (not done) (< i n))
      (if (string.eq (svec.get (& vars.keys) i "") (& key))
        (begin
          (set! found (svec.get (& vars.values) i ""))
          (set! done true))
        (set! i (+ i 1))))
    found))

;; Expand {{name}} placeholders (matching cc_expand in verify-codegen-cases.sh).
(define (expand-vars [vars : (& vars VarTable)] [text : (& text str)]) : String
  (let
    [first : i64 (index-of-str-from text "{{" 0)]
    (if (< first 0)
      (string.copy text)
      (let
        [n : i64 (string.string-length text)]
        [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
        [pos : i64 0]
        [done : bool false]
        (while (not done)
          (let
            [open : i64 (index-of-str-from text "{{" pos)]
            (if (< open 0)
              (begin
                (bbc.byte-buf-builder-append-string
                  (&mut out)
                  (string.substring text pos (- n pos)))
                (set! done true))
              (let
                [close : i64 (index-of-str-from text "}}" (+ open 2))]
                (if (< close 0)
                  (begin
                    (bbc.byte-buf-builder-append-string
                      (&mut out)
                      (string.substring text pos (- n pos)))
                    (set! done true))
                  (begin
                    (when
                      (> open pos)
                      (bbc.byte-buf-builder-append-string
                        (&mut out)
                        (string.substring text pos (- open pos))))
                    (let
                      [name : String
                        (string.substring text (+ open 2) (- close (+ open 2)))]
                      (when
                        (valid-var-name? (& name))
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (var-table-get vars (& name)))))
                    (set! pos (+ close 2))))))))
        (bbc.byte-buf-builder-finish-string (& out))))))

;; Convert {{name}} -> ${CCV_name} for shell-fallback commands (matching shellify).
(define (shellify-vars [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [pos : i64 0]
    [done : bool false]
    (while (not done)
      (let
        [open : i64 (index-of-str-from text "{{" pos)]
        (if (< open 0)
          (begin
            (bbc.byte-buf-builder-append-string
              (&mut out)
              (string.substring text pos (- n pos)))
            (set! done true))
          (let
            [close : i64 (index-of-str-from text "}}" (+ open 2))]
            (if (< close 0)
              (begin
                (bbc.byte-buf-builder-append-string
                  (&mut out)
                  (string.substring text pos (- n pos)))
                (set! done true))
              (let
                [name : String
                  (string.substring text (+ open 2) (- close (+ open 2)))]
                (if (valid-var-name? (& name))
                  (begin
                    (when
                      (> open pos)
                      (bbc.byte-buf-builder-append-string
                        (&mut out)
                        (string.substring text pos (- open pos))))
                    (bbc.byte-buf-builder-append-string (&mut out) "${CCV_")
                    (bbc.byte-buf-builder-append-string
                      (&mut out)
                      (normalize-var-name (& name)))
                    (bbc.byte-buf-builder-append-string (&mut out) "}")
                    (set! pos (+ close 2)))
                  (begin
                    (bbc.byte-buf-builder-append-string
                      (&mut out)
                      (string.substring text pos (- (+ close 2) pos)))
                    (set! pos (+ close 2))))))))))
    (bbc.byte-buf-builder-finish-string (& out))))