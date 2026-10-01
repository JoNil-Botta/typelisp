(import stdlib.byte_buf)
(import stdlib.net.url)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (expect [label : String] [actual : String] [expected : String]) : unit
  (test.assert-owned-string-eq actual expected label))

(define (error-text [error : (& error url.UrlError)]) : String
  (str_cat.str-cat
    (url.url-error-kind-name (& error.kind))
    "@"
    (string.int->string error.offset)))

(define (error-at [kind : String] [offset : i64]) : String
  (str_cat.str-cat kind "@" (string.int->string offset)))

;: The canonical spelling of an HTTP URL, or `kind@offset` for an error.
(define (http-text-with [text : (& text str)] [limits : url.UrlLimits]) : String
  (match (url.parse-http-url text limits)
    [(url.HttpUrlOk parsed) (url.http-url-to-string (& parsed))]
    [(url.HttpUrlErr error) (error-text (& error))]))

(define (http-text [text : (& text str)]) : String
  (http-text-with text (url.default-url-limits)))

(define (reference-text [text : (& text str)]) : String
  (match (url.parse-uri-reference text (url.default-url-limits))
    [(url.UriReferenceOk reference) (url.uri-reference-to-string (& reference))]
    [(url.UriReferenceErr error) (error-text (& error))]))

;: Assert the canonical spelling, or `kind@offset`, of TEXT.
(define (outcome [text : String] [expected : String]) : unit
  (let
    [actual : String (http-text text)]
    (expect text actual expected)))

;: TEXT with byte B inserted at INDEX.
(define (insert-byte [text : (& text str)] [index : i64] [b : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (+ n 1))]
    [i : i64 0]
    (begin
      (while (<= i n)
        (begin
          (when (= i index) (set! out (byte_buf.push out (cast b : u8))))
          (when
            (< i n)
            (set!
              out
              (byte_buf.push
                out
                (cast (cast (string.string-ref text i) : i64) : u8))))
          (set! i (+ i 1))))
      (byte_buf.to-string out))))

;: TEXT repeated COUNT times.
(define (repeat [text : (& text str)] [count : i64]) : String
  (let
    [out : String ""]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! out (str_cat.str-cat out text))
          (set! i (+ i 1))))
      out)))

;; --- RFC 3986 section 5.4 ----------------------------------------------------
(define (rfc-case
  [base : (& base url.UriReference)]
  [reference-text-in : String]
  [expected : String]) : unit
  (match (url.parse-uri-reference reference-text-in (url.default-url-limits))
    [(url.UriReferenceOk reference)
      (match (url.uri-reference-resolve base (& reference))
        [(url.UriReferenceOk resolved)
          (expect
            (str_cat.str-cat "resolve " reference-text-in)
            (url.uri-reference-to-string (& resolved))
            expected)]
        [(url.UriReferenceErr error)
          (fail
            (str_cat.str-cat
              "resolve "
              reference-text-in
              (error-text (& error))))])]
    [(url.UriReferenceErr error)
      (fail
        (str_cat.str-cat
          "parse reference "
          reference-text-in
          (error-text (& error))))]))

;; Every normal and abnormal example, resolved against http://a/b/c/d;p?q.
(define (assert-rfc3986-examples) : unit
  (match (url.parse-uri-reference "http://a/b/c/d;p?q" (url.default-url-limits))
    [(url.UriReferenceErr _) (fail "rfc base")]
    [(url.UriReferenceOk base)
      (begin
        (rfc-case (& base) "g:h" "g:h")
        (rfc-case (& base) "g" "http://a/b/c/g")
        (rfc-case (& base) "./g" "http://a/b/c/g")
        (rfc-case (& base) "g/" "http://a/b/c/g/")
        (rfc-case (& base) "/g" "http://a/g")
        (rfc-case (& base) "//g" "http://g")
        (rfc-case (& base) "?y" "http://a/b/c/d;p?y")
        (rfc-case (& base) "g?y" "http://a/b/c/g?y")
        (rfc-case (& base) "#s" "http://a/b/c/d;p?q#s")
        (rfc-case (& base) "g#s" "http://a/b/c/g#s")
        (rfc-case (& base) "g?y#s" "http://a/b/c/g?y#s")
        (rfc-case (& base) ";x" "http://a/b/c/;x")
        (rfc-case (& base) "g;x" "http://a/b/c/g;x")
        (rfc-case (& base) "g;x?y#s" "http://a/b/c/g;x?y#s")
        (rfc-case (& base) "" "http://a/b/c/d;p?q")
        (rfc-case (& base) "." "http://a/b/c/")
        (rfc-case (& base) "./" "http://a/b/c/")
        (rfc-case (& base) ".." "http://a/b/")
        (rfc-case (& base) "../" "http://a/b/")
        (rfc-case (& base) "../g" "http://a/b/g")
        (rfc-case (& base) "../.." "http://a/")
        (rfc-case (& base) "../../" "http://a/")
        (rfc-case (& base) "../../g" "http://a/g")
        (rfc-case (& base) "../../../g" "http://a/g")
        (rfc-case (& base) "../../../../g" "http://a/g")
        (rfc-case (& base) "/./g" "http://a/g")
        (rfc-case (& base) "/../g" "http://a/g")
        (rfc-case (& base) "g." "http://a/b/c/g.")
        (rfc-case (& base) ".g" "http://a/b/c/.g")
        (rfc-case (& base) "g.." "http://a/b/c/g..")
        (rfc-case (& base) "..g" "http://a/b/c/..g")
        (rfc-case (& base) "./../g" "http://a/b/g")
        (rfc-case (& base) "./g/." "http://a/b/c/g/")
        (rfc-case (& base) "g/./h" "http://a/b/c/g/h")
        (rfc-case (& base) "g/../h" "http://a/b/c/h")
        (rfc-case (& base) "g;x=1/./y" "http://a/b/c/g;x=1/y")
        (rfc-case (& base) "g;x=1/../y" "http://a/b/c/y")
        (rfc-case (& base) "g?y/./x" "http://a/b/c/g?y/./x")
        (rfc-case (& base) "g?y/../x" "http://a/b/c/g?y/../x")
        (rfc-case (& base) "g#s/./x" "http://a/b/c/g#s/./x")
        (rfc-case (& base) "g#s/../x" "http://a/b/c/g#s/../x")
        ;; The strict parser reads "http:g" as an absolute reference.
        (rfc-case (& base) "http:g" "http:g"))]))

;; --- canonical form ------------------------------------------------------------
;; Case, default ports, unreserved percent-encodings and dot segments are
;; normalized; reserved percent-encodings stay encoded with uppercase hex.
(define (assert-canonical) : unit
  (begin
    (outcome
      "HTTP://Example.COM:80/a/./b/../c?x=%7e%2f#f"
      "http://example.com/a/c?x=~%2F#f")
    (outcome "https://example.com:443" "https://example.com/")
    (outcome "https://example.com:8443/" "https://example.com:8443/")
    (outcome "http://EXAMPLE.com/%7Euser/%41%62" "http://example.com/~user/Ab")
    (outcome "http://h/%2fa%2F" "http://h/%2Fa%2F")
    (outcome "http://h/%c3%a9" "http://h/%C3%A9")
    (outcome "http://192.168.0.1:8080/x" "http://192.168.0.1:8080/x")
    (outcome "http://[2001:DB8:0:0:0:0:0:1]/" "http://[2001:db8::1]/")
    (outcome "http://h:/" "http://h/")
    (outcome "http://h:0080/" "http://h/")
    (outcome "http://h:65535/" "http://h:65535/")
    (outcome "http://h?q" "http://h/?q")
    (outcome "http://h#" "http://h/#")
    (outcome "http://h/p?" "http://h/p?")
    (outcome "http://h/a/%2e%2E/b" "http://h/b")
    (outcome "http://h/a/../../b" "http://h/b")
    (outcome
      "http://h/a:b@c!$&'()*+,;=/?q=/?#f/?"
      "http://h/a:b@c!$&'()*+,;=/?q=/?#f/?")
    (outcome "http://xn--bcher-kva.example/" "http://xn--bcher-kva.example/")
    (outcome "http://a-b.c0/" "http://a-b.c0/")
    (outcome "http://a.0xg/" "http://a.0xg/")
    (outcome "http://0x1g.example/" "http://0x1g.example/")))

(define (parse-http-ok [text : (& text str)]) : url.HttpUrl
  (match (url.parse-http-url text (url.default-url-limits))
    [(url.HttpUrlOk parsed) parsed]
    [(url.HttpUrlErr error)
      (begin
        (fail
          (str_cat.str-cat
            (string.copy text)
            " did not parse: "
            (error-text (& error))))
        (parse-http-ok "http://fallback/"))]))

(define (target-of [text : (& text str)]) : String
  (let
    [u : url.HttpUrl (parse-http-ok text)]
    (url.http-url-request-target (& u))))

(define (origin-of [text : (& text str)]) : url.HttpOrigin
  (let
    [u : url.HttpUrl (parse-http-ok text)]
    (url.http-url-origin (& u))))

(define (identity-of [text : (& text str)]) : String
  (let
    [u : url.HttpUrl (parse-http-ok text)]
    (url.http-url-identity-key (& u))))

(define (key-of [text : (& text str)]) : String
  (let
    [u : url.HttpUrl (parse-http-ok text)]
    (url.http-url-key (& u))))

;; The request target is the path and exact query; the fragment never enters.
(define (assert-request-targets) : unit
  (begin
    (expect "empty path" (target-of "http://h") "/")
    (expect "query" (target-of "http://h/p?q#f") "/p?q")
    (expect "empty query" (target-of "http://h/p?#f") "/p?")
    (expect
      "reserved query bytes"
      (target-of "http://h/?a=%2F&b=/?")
      "/?a=%2F&b=/?")))

;; Origin, redirect identity and complete keys compare byte for byte with no
;; DNS: default ports are equivalent, schemes and ports are separate.
(define (assert-keys) : unit
  (let
    [plain : url.HttpOrigin (origin-of "http://a")]
    [default-port : url.HttpOrigin (origin-of "http://A:80/x")]
    [https-default : url.HttpOrigin (origin-of "https://a")]
    [https-explicit : url.HttpOrigin (origin-of "https://a:443/")]
    [http-on-443 : url.HttpOrigin (origin-of "http://a:443")]
    [other-port : url.HttpOrigin (origin-of "http://a:8080")]
    [ip-host : url.HttpOrigin (origin-of "http://127.0.0.1")]
    (begin
      (expect "origin key" (url.http-origin-key (& plain)) "http://a:80")
      (expect
        "ip origin key"
        (url.http-origin-key (& ip-host))
        "http://127.0.0.1:80")
      (unless
        (url.http-origin-eq? (& plain) (& default-port))
        (fail "default port origin"))
      (unless
        (url.http-origin-eq? (& https-default) (& https-explicit))
        (fail "https default port origin"))
      (when
        (url.http-origin-eq? (& http-on-443) (& https-default))
        (fail "scheme separation"))
      (when
        (url.http-origin-eq? (& plain) (& other-port))
        (fail "port separation"))
      (when
        (url.http-origin-eq? (& plain) (& ip-host))
        (fail "host separation"))
      (expect
        "identity drops fragment"
        (identity-of "http://a/x?q#1")
        "http://a:80/x?q")
      (expect
        "identity across fragments"
        (identity-of "http://a/x#1")
        (identity-of "http://A:80/x#2"))
      (expect "complete key" (key-of "http://a/x#1") "http://a:80/x#1")
      (when
        (string.eq (key-of "http://a/x#1") (key-of "http://a/x#2"))
        (fail "complete keys"))
      (when
        (string.eq (key-of "http://a/x") (key-of "http://a/x#"))
        (fail "empty fragment key"))
      (when
        (string.eq (key-of "http://a/x") (key-of "http://a/x?"))
        (fail "empty query key")))))

;; --- HTTP resolution policy ----------------------------------------------------
(define (resolve-text [base : (& base str)] [reference : (& reference str)]) : String
  (let
    [u : url.HttpUrl (parse-http-ok base)]
    (match (url.http-url-resolve (& u) reference (url.default-url-limits))
      [(url.HttpUrlOk resolved) (url.http-url-to-string (& resolved))]
      [(url.HttpUrlErr error) (error-text (& error))])))

(define (assert-http-resolution) : unit
  (begin
    (expect "relative" (resolve-text "https://h/a/b?q" "../c") "https://h/c")
    (expect
      "network path"
      (resolve-text "https://h/a/b?q" "//other.example:8080/x")
      "https://other.example:8080/x")
    (expect
      "absolute path"
      (resolve-text "https://h/a/b?q" "/x/./y")
      "https://h/x/y")
    (expect
      "query only"
      (resolve-text "https://h/a/b?q" "?y")
      "https://h/a/b?y")
    (expect
      "fragment only"
      (resolve-text "https://h/a/b?q" "#f")
      "https://h/a/b?q#f")
    (expect "empty" (resolve-text "https://h/a/b?q" "") "https://h/a/b?q")
    (expect
      "explicit port kept"
      (resolve-text "http://h:8080/a" "b")
      "http://h:8080/b")
    (expect "absolute" (resolve-text "https://h/a" "http://h/b") "http://h/b")
    (expect
      "other scheme"
      (resolve-text "https://h/a" "g:h")
      "unsupported-scheme@0")
    (expect
      "ftp"
      (resolve-text "https://h/a" "ftp://x/")
      "unsupported-scheme@0")
    (expect "userinfo" (resolve-text "https://h/a" "//u@x/") "userinfo@3")
    (expect
      "zone"
      (resolve-text "https://h/a" "//[fe80::1%25en0]/")
      "ipv6-zone@10")
    (expect "bad reference" (resolve-text "https://h/a" "a b") "invalid-byte@1")))

;; --- rejection corpus ------------------------------------------------------------
;; Each malformed input fails with a stable kind and the offset of the first
;; offending byte.
(define (assert-malformed) : unit
  (begin
    (outcome "" "not-absolute@0")
    (outcome "//a/b" "not-absolute@0")
    (outcome "1a:b" "not-absolute@0")
    (outcome "ftp://a/" "unsupported-scheme@0")
    (outcome "http:g" "missing-authority@0")
    (outcome "http:/g" "missing-authority@0")
    (outcome "http:///g" "empty-host@7")
    (outcome "HTTPS://" "empty-host@8")
    (outcome "http://:80/" "empty-host@7")
    (outcome "http://user@a/" "userinfo@11")
    (outcome "http://user:pw@a/" "userinfo@14")
    (outcome "http://@a/" "userinfo@7")
    (outcome "http://a b/" "invalid-byte@8")
    (outcome "http:\\\\a/" "backslash@5")
    (outcome "http://a\\b/" "backslash@8")
    (outcome "http://a/%" "bad-percent-encoding@9")
    (outcome "http://a/%4" "bad-percent-encoding@9")
    (outcome "http://a/%GZ" "bad-percent-encoding@9")
    (outcome "http://a/%%41" "bad-percent-encoding@9")
    (outcome "http://a/%00" "encoded-control@9")
    (outcome "http://a/?%0a" "encoded-control@10")
    (outcome "http://a/#%7F" "encoded-control@10")
    (outcome "http://[::1" "invalid-ipv6@11")
    (outcome "http://[::1]x/" "invalid-host@12")
    (outcome "http://[[::1]]/" "invalid-ipv6@8")
    (outcome "http://[::1]]/" "invalid-host@12")
    (outcome "http://[]/" "invalid-ipv6@8")
    (outcome "http://[fe80::1%25eth0]/" "ipv6-zone@15")
    (outcome "http://[v1.x]/" "unsupported-ip-future@8")
    (outcome "http://a[::1]/" "invalid-host@8")
    (outcome "http://1.2.3/" "invalid-ipv4@12")
    (outcome "http://256.1.1.1/" "invalid-ipv4@9")
    (outcome "http://01.2.3.4/" "invalid-ipv4@8")
    (outcome "http://1.2.3.4.5/" "invalid-ipv4@14")
    (outcome "http://a.1/" "invalid-ipv4@7")
    (outcome "http://0x7f000001/" "invalid-ipv4@8")
    (outcome "http://0X7F000001/" "invalid-ipv4@8")
    (outcome "http://1.2.3.0x4/" "invalid-ipv4@14")
    (outcome "http://0x/" "invalid-ipv4@8")
    (outcome "http://a.0x10/" "invalid-ipv4@7")
    (outcome "http://a:65536/" "invalid-port@13")
    (outcome "http://a:99999999999999999999/" "invalid-port@13")
    (outcome "http://a:8a/" "invalid-port@10")
    (outcome "http://a:-1/" "invalid-port@9")
    (outcome "http://a:0/" "invalid-port@9")
    (outcome "http://a:1:2/" "invalid-port@10")
    (outcome "http://a_b/" "invalid-host@8")
    (outcome "http://a!b/" "invalid-host@8")
    (outcome "http://-a/" "invalid-host@7")
    (outcome "http://a-/" "invalid-host@8")
    (outcome "http://a-.b/" "invalid-host@8")
    (outcome "http://a..b/" "invalid-host@9")
    (outcome "http://.a/" "invalid-host@7")
    (outcome "http://a./" "invalid-host@9")
    (outcome "http://%61/" "invalid-host@7")
    (outcome "http://%C3%A9/" "internationalized-host@7")
    (outcome "http://%C/" "invalid-host@7")
    (outcome "http://%CG/" "invalid-host@7")
    (outcome "http://a/<" "invalid-byte@9")
    (outcome "http://a/\"" "invalid-byte@9")
    (outcome "http://a/{}" "invalid-byte@9")
    (outcome "http://a/^" "invalid-byte@9")
    (outcome "http://a/`" "invalid-byte@9")
    (outcome "http://a/b#c#d" "invalid-byte@12")
    (expect "relative colon" (reference-text "1a:b") "colon-in-first-segment@2")
    (expect "relative later colon" (reference-text "./a:b") "./a:b")))

;; Raw control bytes, NUL and DEL are rejected anywhere; a raw non-ASCII byte
;; is an internationalized host inside the host and invalid elsewhere. A
;; 63-byte DNS label is accepted and a 64-byte one is not.
(define (assert-byte-classes) : unit
  (let
    [label-63 : String (str_cat.str-cat "http://" (repeat "a" 63) "/")]
    [label-64 : String (str_cat.str-cat "http://" (repeat "a" 64) "/")]
    (begin
      (expect "nul" (http-text (insert-byte "http://a/b" 9 0)) "invalid-byte@9")
      (expect
        "nul at end"
        (http-text (insert-byte "http://a/b" 10 0))
        "invalid-byte@10")
      (expect
        "del"
        (http-text (insert-byte "http://a/b" 9 127))
        "invalid-byte@9")
      (expect "tab" (http-text (insert-byte "http://ab/" 8 9)) "invalid-byte@8")
      (expect
        "utf-8 host"
        (http-text (insert-byte (insert-byte "http://a/" 8 169) 8 195))
        "internationalized-host@8")
      (expect
        "utf-8 path"
        (http-text (insert-byte "http://a/b" 9 195))
        "invalid-byte@9")
      (expect "63-byte label" (http-text label-63) (string.copy label-63))
      (expect "64-byte label" (http-text label-64) "component-too-long@70"))))

;; --- every byte at each component boundary -----------------------------------
(define (alnum? [b : i64]) : bool
  (or
    (and (>= b 48) (<= b 57))
    (and (>= b 65) (<= b 90))
    (and (>= b 97) (<= b 122))))

;: RFC 3986 pchar without pct-encoded, written out independently of the
;: module under test.
(define (pchar? [b : i64]) : bool
  (or
    (alnum? b)
    (and
      (< b 128)
      (>= (string.index-of-byte "-._~!$&'()*+,;=:@" 0 (cast b : u8)) 0))))

(define (lower [b : i64]) : i64
  (if (and (>= b 65) (<= b 90))
    (+ b 32)
    b))

;: The outcome of B inserted at index 10 of "http://h/ab", inside a path.
(define (path-byte-expected [b : i64]) : String
  (cond
    [(or (<= b 32) (= b 127)) (error-at "invalid-byte" 10)]
    [(= b 92) (error-at "backslash" 10)]
    [(= b 37) (error-at "bad-percent-encoding" 10)]
    [(= b 35) "http://h/a#b"]
    [(= b 63) "http://h/a?b"]
    [(or (pchar? b) (= b 47)) (insert-byte "http://h/ab" 10 b)]
    [else (error-at "invalid-byte" 10)]))

;: The outcome of B inserted at index 11 of "http://h/?ab" (QUERY? true) or
;: "http://h/#ab", inside the query or fragment.
(define (suffix-byte-expected [b : i64] [query? : bool]) : String
  (cond
    [(or (<= b 32) (= b 127)) (error-at "invalid-byte" 11)]
    [(= b 92) (error-at "backslash" 11)]
    [(= b 37) (error-at "bad-percent-encoding" 11)]
    [(and query? (= b 35)) "http://h/?a#b"]
    [(or (pchar? b) (= b 47) (= b 63))
      (insert-byte
        (if query?
          "http://h/?ab"
          "http://h/#ab")
        11
        b)]
    [else (error-at "invalid-byte" 11)]))

;: The outcome of B inserted at index 8 of "http://ab/", inside a DNS name.
(define (host-byte-expected [b : i64]) : String
  (cond
    [(or (<= b 32) (= b 127)) (error-at "invalid-byte" 8)]
    [(= b 92) (error-at "backslash" 8)]
    [(>= b 128) (error-at "internationalized-host" 8)]
    [(= b 64) (error-at "userinfo" 8)]
    [(= b 58) (error-at "invalid-port" 9)]
    [(= b 47) "http://a/b/"]
    [(= b 63) "http://a/?b/"]
    [(= b 35) "http://a/#b/"]
    [(or (alnum? b) (= b 45) (= b 46)) (insert-byte "http://ab/" 8 (lower b))]
    [else (error-at "invalid-host" 8)]))

(define (assert-every-byte) : unit
  (let
    [b : i64 0]
    (while (< b 256)
      (let
        [label : String (str_cat.str-cat "byte " (string.int->string b))]
        (begin
          (expect
            (str_cat.str-cat label " in path")
            (http-text (insert-byte "http://h/ab" 10 b))
            (path-byte-expected b))
          (expect
            (str_cat.str-cat label " in query")
            (http-text (insert-byte "http://h/?ab" 11 b))
            (suffix-byte-expected b true))
          (expect
            (str_cat.str-cat label " in fragment")
            (http-text (insert-byte "http://h/#ab" 11 b))
            (suffix-byte-expected b false))
          (expect
            (str_cat.str-cat label " in host")
            (http-text (insert-byte "http://ab/" 8 b))
            (host-byte-expected b))
          (set! b (+ b 1)))))))

;; --- size caps -------------------------------------------------------------------
;; Inputs and components past their limits are rejected at the first byte past
;; the limit, before any component is copied.
(define (assert-limits) : unit
  (let
    [small : url.UrlLimits (url.UrlLimits 40 12 10 6 4)]
    [long-input : String (str_cat.str-cat "http://a/" (repeat "b" 32))]
    [label : String (str_cat.str-cat (repeat "a" 62) ".")]
    [long-host : String (str_cat.str-cat "http://" (repeat label 4) "com/")]
    (begin
      (expect "input" (http-text-with long-input small) "too-long@40")
      (expect
        "host"
        (http-text-with "http://aaaaaaa.bbbbbb/" small)
        "component-too-long@19")
      (expect
        "path"
        (http-text-with "http://a/0123456789x" small)
        "component-too-long@18")
      (expect
        "query"
        (http-text-with "http://a/?0123456" small)
        "component-too-long@16")
      (expect
        "fragment"
        (http-text-with "http://a/#01234" small)
        "component-too-long@14")
      (expect
        "at every limit"
        (http-text-with "http://a/012345678?q#f" small)
        "http://a/012345678?q#f")
      (expect
        "default host limit"
        (http-text long-host)
        "component-too-long@260"))))

;; --- whole-input properties ------------------------------------------------------
;; For one valid URL:
;; - every prefix either parses or fails at an offset inside the prefix;
;; - a control byte, a space or a backslash inserted at any position is
;;   reported at exactly that position;
;; - the canonical spelling parses back to itself with the same keys.
(define (assert-valid-url [text : (& text str)]) : unit
  (let
    [n : i64 (string.string-length text)]
    [k : i64 0]
    [first : url.HttpUrl (parse-http-ok text)]
    [spelled : String (url.http-url-to-string (& first))]
    [second : url.HttpUrl (parse-http-ok spelled)]
    (begin
      (expect
        "round trip"
        (url.http-url-to-string (& second))
        (string.copy spelled))
      (expect
        "round trip key"
        (url.http-url-key (& second))
        (url.http-url-key (& first)))
      (while (<= k n)
        (let
          [at : String
            (str_cat.str-cat (string.copy text) " at " (string.int->string k))]
          [prefix : String (string.substring text 0 k)]
          (begin
            (match (url.parse-http-url prefix (url.default-url-limits))
              [(url.HttpUrlOk _) unit]
              [(url.HttpUrlErr error)
                (when
                  (or (< error.offset 0) (> error.offset k))
                  (fail (str_cat.str-cat "prefix offset " at)))])
            (expect
              (str_cat.str-cat "control " at)
              (http-text (insert-byte text k 1))
              (error-at "invalid-byte" k))
            (expect
              (str_cat.str-cat "space " at)
              (http-text (insert-byte text k 32))
              (error-at "invalid-byte" k))
            (expect
              (str_cat.str-cat "backslash " at)
              (http-text (insert-byte text k 92))
              (error-at "backslash" k))
            (set! k (+ k 1))))))))

(define (assert-valid-corpus) : unit
  (begin
    (assert-valid-url "http://example.com/")
    (assert-valid-url "HTTPS://Example.COM:443/a/../b?x=%7e%2f#frag")
    (assert-valid-url "http://192.168.0.1:8080/x?y")
    (assert-valid-url "http://[2001:db8::1]:8443/p")
    (assert-valid-url "http://h/%41/%2F?%3F#%23")
    (assert-valid-url "https://xn--bcher-kva.example/a/./b/")
    (assert-valid-url "http://a:/")
    (assert-valid-url "http://h?q")
    (assert-valid-url "http://h#f")
    (assert-valid-url "http://a/b;c=d/e,f")))

(define (main) : i64
  (begin
    (assert-rfc3986-examples)
    (assert-canonical)
    (assert-request-targets)
    (assert-keys)
    (assert-http-resolution)
    (assert-malformed)
    (assert-byte-classes)
    (assert-every-byte)
    (assert-limits)
    (assert-valid-corpus)
    42))