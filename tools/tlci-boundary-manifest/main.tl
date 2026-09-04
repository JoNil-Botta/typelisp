;; Generate the stable, address-free audit manifest for the native TLCI
;; admission and host-callback boundary. Callback rows are derived from the
;; production ABI constants and the production host registry: there is no
;; second callback-name catalog to keep in sync. Refs #7272.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define tlbm-manifest-header : String
  "kind\tidentity\tabi_version\ttrusted_data\tuntrusted_data\tvalidation_before_effect\tcapability\tresult_or_commit\tfailure_status\timplementation_binding\tproducer_or_caller\tsource_site\tsuccess_witness\tmalformed_witness\n")

(define (tlbm-fail [identity : String] [message : String]) : bool
  (begin
    (io.print-error
      (str_cat.str-cat "tlci boundary manifest: " identity ": " message "\n"))
    false))

(define (tlbm-fail-status [identity : String] [message : String]) : i64
  (if (tlbm-fail identity message)
    1
    1))

(define (tlbm-find
  [haystack : (& haystack str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [haystack-len : i64 (string.string-length haystack)]
    [needle-len : i64 (string.string-length needle)]
    [index : i64 start]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (<= index (- haystack-len needle-len)))
        (if (string.is-string-prefix-at haystack needle index)
          (set! found index)
          (set! index (+ index 1))))
      found)))

(define (tlbm-token-end [source : (& source str)] [start : i64]) : i64
  (let
    [length : i64 (string.string-length source)]
    [index : i64 start]
    [done : bool false]
    (begin
      (while (and (not done) (< index length))
        (let
          [c : char (string.string-ref source index)]
          (if (or
            (string.is-char-whitespace c)
            (= c '(')
            (= c ')')
            (= c '[')
            (= c ']'))
            (set! done true)
            (set! index (+ index 1)))))
      index)))

(define (tlbm-token-delimiter? [source : (& source str)] [index : i64]) : bool
  (if (>= index (string.string-length source))
    true
    (let
      [c : char (string.string-ref source index)]
      (or (string.is-char-whitespace c) (= c '(') (= c ')') (= c '[') (= c ']')))))

(define (tlbm-count-token [source : (& source str)] [token : (& token str)]) : i64
  (let
    [cursor : i64 0]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [found : i64 (tlbm-find source token cursor)]
          (if (< found 0)
            (set! done true)
            (let
              [end : i64 (+ found (string.string-length token))]
              (begin
                (when
                  (tlbm-token-delimiter? source end)
                  (set! count (+ count 1)))
                (set! cursor end))))))
      count)))

(define (tlbm-vec-contains?
  [items : (& items svec.Vec)]
  [value : (& value str)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index (svec.len items)))
        (if (string.eq (svec.get items index "") value)
          (set! found true)
          (set! index (+ index 1))))
      found)))

(define (tlbm-read [path : String]) : String
  (byte_buf.to-string (io.read-file path)))

(define (tlbm-extract-version [core : (& core str)] [name : String]) : String
  (let
    [marker : String (str_cat.str-cat "(define " name " : i64")]
    [marker-pos : i64 (tlbm-find core (& marker) 0)]
    (if (< marker-pos 0)
      ""
      (let
        [cursor : i64 (+ marker-pos (string.string-length marker))]
        [length : i64 (string.string-length core)]
        (begin
          (while (and
            (< cursor length)
            (string.is-char-whitespace (string.string-ref core cursor)))
            (set! cursor (+ cursor 1)))
          (string.substring core cursor (- (tlbm-token-end core cursor) cursor)))))))

(define (tlbm-parse-callback-constants
  [core : (& core str)]
  [symbols : (&mut symbols svec.Vec)]
  [abi-names : (&mut abi-names svec.Vec)]) : bool
  (let
    [marker : String "(define tlci-host-callback-name-"]
    [cursor : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and ok (not done))
        (let
          [found : i64 (tlbm-find core (& marker) cursor)]
          (if (< found 0)
            (set! done true)
            (let
              [symbol-start : i64 (+ found (string.string-length marker))]
              [symbol-end : i64 (tlbm-token-end core symbol-start)]
              [symbol : String
                (string.substring core symbol-start (- symbol-end symbol-start))]
              [type-marker : String ": String"]
              [type-pos : i64 (tlbm-find core (& type-marker) symbol-end)]
              [quote-pos : i64
                (if (< type-pos 0)
                  -1
                  (tlbm-find
                    core
                    "\""
                    (+ type-pos (string.string-length type-marker))))]
              [quote-end : i64
                (if (< quote-pos 0)
                  -1
                  (tlbm-find core "\"" (+ quote-pos 1)))]
              (if (or (< type-pos 0) (> type-pos (+ found 180)) (< quote-end 0))
                (set!
                  ok
                  (tlbm-fail
                    symbol
                    "malformed ABI name declaration in src/tlci_core.tl"))
                (let
                  [abi-name : String
                    (string.substring
                      core
                      (+ quote-pos 1)
                      (- (- quote-end quote-pos) 1))]
                  (cond
                    [(tlbm-vec-contains? symbols (& symbol))
                      (set!
                        ok
                        (tlbm-fail
                          symbol
                          "duplicate ABI name declaration in src/tlci_core.tl"))]
                    [(not (string.eq symbol abi-name))
                      (set!
                        ok
                        (tlbm-fail
                          symbol
                          (str_cat.str-cat
                            "ABI spelling skew: declared `"
                            abi-name
                            "`")))]
                    [else
                      (begin
                        (svec.push-ref! symbols symbol)
                        (svec.push-ref! abi-names abi-name)
                        (set! cursor (+ quote-end 1)))])))))))
      (if (and ok (= (svec.len symbols) 0))
        (tlbm-fail "callbacks" "no ABI name declarations found")
        ok))))

(define (tlbm-parse-host-registry
  [host : (& host str)]
  [symbols : (&mut symbols svec.Vec)]
  [implementations : (&mut implementations svec.Vec)]) : bool
  (let
    [marker : String "(compiler-comptime-host-registry-add!"]
    [view-marker : String "tlci.tlci-host-callback-name-shared-view"]
    [name-marker : String "tlci.tlci-host-callback-name-"]
    [implementation-marker : String "compiler-comptime-host-callback-"]
    [cursor : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and ok (not done))
        (let
          [found : i64 (tlbm-find host (& marker) cursor)]
          (if (< found 0)
            (set! done true)
            (let
              [next : i64
                (tlbm-find
                  host
                  (& marker)
                  (+ found (string.string-length marker)))]
              [limit : i64
                (if (< next 0)
                  (string.string-length host)
                  next)]
              [builder-pos : i64 (tlbm-find host "(&mut registry)" found)]
              (if (or (< builder-pos 0) (>= builder-pos limit))
                (set! cursor (+ found (string.string-length marker)))
                (let
                  [view-pos : i64 (tlbm-find host (& view-marker) builder-pos)]
                  [name-pos : i64
                    (if (< view-pos 0)
                      -1
                      (tlbm-find
                        host
                        (& name-marker)
                        (+ view-pos (string.string-length (& view-marker)))))]
                  [name-start : i64
                    (if (< name-pos 0)
                      -1
                      (+ name-pos (string.string-length name-marker)))]
                  [name-end : i64
                    (if (< name-start 0)
                      -1
                      (tlbm-token-end host name-start))]
                  [implementation-pos : i64
                    (if (< name-end 0)
                      -1
                      (tlbm-find host (& implementation-marker) name-end))]
                  [implementation-end : i64
                    (if (< implementation-pos 0)
                      -1
                      (tlbm-token-end host implementation-pos))]
                  (if (or
                    (< name-pos 0)
                    (>= name-pos limit)
                    (< implementation-pos 0)
                    (>= implementation-pos limit))
                    (set!
                      ok
                      (tlbm-fail
                        "host-registry"
                        "malformed or implementationless registration row"))
                    (let
                      [symbol : String
                        (string.substring
                          host
                          name-start
                          (- name-end name-start))]
                      [implementation : String
                        (string.substring
                          host
                          implementation-pos
                          (- implementation-end implementation-pos))]
                      [expected : String
                        (str_cat.str-cat implementation-marker symbol)]
                      (cond
                        [(tlbm-vec-contains? symbols (& symbol))
                          (set!
                            ok
                            (tlbm-fail symbol "duplicate host registry row"))]
                        [(not (string.eq implementation expected))
                          (set!
                            ok
                            (tlbm-fail
                              symbol
                              (str_cat.str-cat
                                "implementation binding skew: expected `"
                                expected
                                "`, found `"
                                implementation
                                "`")))]
                        [else
                          (begin
                            (svec.push-ref! symbols symbol)
                            (svec.push-ref! implementations implementation)
                            (set! cursor implementation-end))])))))))))
      (if (and ok (= (svec.len symbols) 0))
        (tlbm-fail "host-registry" "no production registration rows found")
        ok))))

(define (tlbm-find-index [items : (& items svec.Vec)] [value : (& value str)]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index (svec.len items)))
        (if (string.eq (svec.get items index "") value)
          (set! found index)
          (set! index (+ index 1))))
      found)))

(define (tlbm-validate-producer-callbacks
  [producer : (& producer str)]
  [core-symbols : (& core-symbols svec.Vec)]) : bool
  (let
    [marker : String "tlci_core.tlci-host-callback-name-"]
    [cursor : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and ok (not done))
        (let
          [found : i64 (tlbm-find producer (& marker) cursor)]
          (if (< found 0)
            (set! done true)
            (let
              [start : i64 (+ found (string.string-length (& marker)))]
              [end : i64 (tlbm-token-end producer start)]
              [symbol : String (string.substring producer start (- end start))]
              (begin
                (when
                  (and
                    (not (string.eq symbol "shared-view"))
                    (< (tlbm-find-index core-symbols (& symbol)) 0))
                  (set!
                    ok
                    (tlbm-fail
                      symbol
                      "native producer references a callback with no ABI catalog row")))
                (set! cursor end))))))
      ok)))

(define (tlbm-capability [name : (& name str)]) : String
  (cond
    [(string.eq name "fuel-check") "execution-budget"]
    [(string.is-string-prefix-at name "diagnostic" 0) "diagnostics"]
    [(string.is-string-prefix-at name "scratch-" 0) "scratch-memory"]
    [(string.eq name "commit-result") "result-commit"]
    [(or
        (string.is-string-prefix-at name "expr-ptr-" 0)
        (string.eq name "expr-int-to-ptr")
        (string.eq name "expr-string-data")
        (string.eq name "expr-array-data")
        (string.eq name "expr-string-from-bytes")
        (string.eq name "expr-cast")
        (string.eq name "expr-unsafe"))
      "unsafe-syntax-build"]
    [(or
        (string.is-string-prefix-at name "type-var" 0)
        (string.eq name "type-scalar")
        (string.eq name "type-ptr")
        (string.eq name "type-box")
        (string.eq name "type-dyn-array")
        (string.eq name "type-array")
        (string.eq name "type-slice")
        (string.eq name "type-ref")
        (string.eq name "type-tuple"))
      "type-build"]
    [(or
        (string.is-string-prefix-at name "type-" 0)
        (string.is-string-prefix-at name "struct-field-" 0)
        (string.is-string-prefix-at name "enum-variant-" 0)
        (string.is-string-prefix-at name "array-" 0)
        (string.is-string-prefix-at name "array-element-" 0)
        (string.is-string-prefix-at name "box-element-" 0)
        (string.is-string-prefix-at name "tuple-element-" 0)
        (string.is-string-prefix-at name "function-" 0)
        (string.is-string-prefix-at name "reference-element-" 0)
        (string.is-string-prefix-at name "module-" 0))
      "reflection-read"]
    [(or
        (string.is-string-prefix-at name "local-" 0)
        (string.is-string-prefix-at name "operand-" 0)
        (string.is-string-prefix-at name "value-" 0)
        (string.eq name "push-operand"))
      "session-value-stack"]
    [(string.is-string-prefix-at name "syntax-name-" 0) "syntax-identity"]
    [(or
        (string.is-string-prefix-at name "string-" 0)
        (string.eq name "int->string"))
      "string-transform"]
    [(or
        (string.is-string-prefix-at name "expr-" 0)
        (string.is-string-prefix-at name "pattern-" 0)
        (string.is-string-prefix-at name "match-arm" 0)
        (string.is-string-prefix-at name "let-binding" 0))
      "syntax-build"]
    [else ""]))

(define (tlbm-validation-summary [body : (& body str)] [via-adapter : bool]) : String
  (let
    [summary : text_buf.TextBuf
      (text_buf.append
        (text_buf.empty)
        (if via-adapter
          "adapter:session-cookie+first-failure-latch"
          "session-cookie+first-failure-latch"))]
    (begin
      (when
        (string.contains body "compiler-comptime-host-stack-len")
        (text_buf.append! summary "+stack-bounds"))
      (when
        (or
          (string.contains body "(< arg-")
          (string.contains body "(<= arg-")
          (string.contains body "(> arg-")
          (string.contains body "(>= arg-"))
        (text_buf.append! summary "+argument-range"))
      (when
        (string.contains body "string-from-bytes")
        (text_buf.append! summary "+pointer-length"))
      (when
        (or
          (string.contains body "ast-node-pool-context")
          (string.contains body "CompilerCtfeValue"))
        (text_buf.append! summary "+typed-arena-handle"))
      (text_buf.render summary))))

(define (tlbm-callback-body-range
  [host : (& host str)]
  [implementation : (& implementation str)]) : String
  (let
    [marker : String (str_cat.str-cat "(define (" implementation)]
    [start : i64 (tlbm-find host (& marker) 0)]
    (if (< start 0)
      ""
      (let
        [end : i64 (tlbm-find host "\n(define " (+ start 1))]
        (string.substring
          host
          start
          (-
            (if (< end 0)
              (string.string-length host)
              end)
            start))))))

(define (tlbm-body-has-guard? [body : (& body str)]) : bool
  (and
    (string.contains body "compiler-comptime-host-session-cookie")
    (string.contains body "compiler-comptime-host-session-status")
    (string.contains body "tlci.tlci-host-callback-status-bad-request")))

(define (tlbm-adapter-body
  [host : (& host str)]
  [body : (& body str)]
  [implementation : (& implementation str)]) : String
  (let
    [prefix : String "compiler-comptime-host-callback-"]
    [signature-end : i64 (tlbm-find body ") : i64" 0)]
    [target-pos : i64
      (if (< signature-end 0)
        -1
        (tlbm-find body (& prefix) (+ signature-end 7)))]
    (if (< target-pos 0)
      ""
      (let
        [target-end : i64 (tlbm-token-end body target-pos)]
        [target : String
          (string.substring body target-pos (- target-end target-pos))]
        (if (string.eq target implementation)
          ""
          (tlbm-callback-body-range host (& target)))))))

(define (tlbm-callback-input-shape [body : (& body str)]) : String
  (let
    [signature-end : i64 (tlbm-find body ") : i64" 0)]
    [cursor : i64 0]
    [count : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    [ok : bool true]
    (begin
      (while (and ok (< count 4))
        (let
          [open : i64 (tlbm-find body "[" cursor)]
          (if (or (< open 0) (and (>= signature-end 0) (> open signature-end)))
            (set! ok false)
            (let
              [name-start : i64 (+ open 1)]
              [name-end : i64 (tlbm-token-end body name-start)]
              [type-marker : String " : i64]"]
              [type-pos : i64 (tlbm-find body (& type-marker) name-end)]
              (if (or (< type-pos 0) (> type-pos (+ name-end 3)))
                (set! ok false)
                (begin
                  (when (> count 0) (text_buf.append! out ","))
                  (text_buf.append!
                    out
                    (string.substring body name-start (- name-end name-start)))
                  (text_buf.append! out ":i64")
                  (set! count (+ count 1))
                  (set! cursor (+ type-pos (string.string-length type-marker)))))))))
      (if (and ok (= count 4))
        (text_buf.render out)
        ""))))

(define (tlbm-field [line : (& line str)] [wanted : i64]) : String
  (let
    [index : i64 0]
    [field : i64 0]
    [start : i64 0]
    [length : i64 (string.string-length line)]
    [done : bool false]
    [result : String ""]
    (begin
      (while (and (not done) (<= index length))
        (if (or (= index length) (= (string.string-ref line index) '\t'))
          (if (= field wanted)
            (begin
              (set! result (string.substring line start (- index start)))
              (set! done true))
            (begin
              (set! field (+ field 1))
              (set! start (+ index 1))
              (set! index (+ index 1))))
          (set! index (+ index 1))))
      result)))

(define (tlbm-tab-count [line : (& line str)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (string.string-length line))
        (begin
          (when
            (= (string.string-ref line index) '\t')
            (set! count (+ count 1)))
          (set! index (+ index 1))))
      count)))

(define (tlbm-validate-stage-line [line : (& line str)]) : bool
  (if (not (= (tlbm-tab-count line) 13))
    (tlbm-fail
      "admission-stage"
      "catalog row must have exactly 14 tab-separated fields")
    (let
      [identity : String (tlbm-field line 1)]
      [source-path : String (tlbm-field line 11)]
      [separator : i64 (tlbm-find (& source-path) ":" 0)]
      (if (or
        (< separator 1)
        (= separator (- (string.string-length source-path) 1)))
        (tlbm-fail identity "source_site must be path:stable-token")
        (let
          [path : String (string.substring source-path 0 separator)]
          [site : String
            (string.substring
              source-path
              (+ separator 1)
              (- (- (string.string-length source-path) separator) 1))]
          (if (= (io.read-file-status (& path)) 0)
            (let
              [source : String (tlbm-read path)]
              (if (string.contains (& source) (& site))
                true
                (tlbm-fail
                  identity
                  (str_cat.str-cat "missing source site `" source-path "`"))))
            (tlbm-fail
              identity
              (str_cat.str-cat "cannot read source path `" path "`"))))))))

(define (tlbm-copy-stage-rows [catalog : String] [rows : (&mut rows svec.Vec)]) : bool
  (let
    [cursor : i64 0]
    [length : i64 (string.string-length (& catalog))]
    [ok : bool true]
    (begin
      (while (and ok (< cursor length))
        (let
          [end0 : i64 (tlbm-find (& catalog) "\n" cursor)]
          [end : i64
            (if (< end0 0)
              length
              end0)]
          [line : String (string.substring (& catalog) cursor (- end cursor))]
          [next : i64
            (if (< end0 0)
              length
              (+ end 1))]
          (begin
            (when
              (and
                (> (string.string-length (& line)) 0)
                (not (= (string.string-ref (& line) 0) '#')))
              (if (tlbm-validate-stage-line (& line))
                (svec.push-ref! rows line)
                (set! ok false)))
            (set! cursor next))))
      ok)))

(define (tlbm-result-contract [name : (& name str)]) : String
  (cond
    [(string.eq name "commit-result") "value-stack->session-result-slot-once"]
    [(and
        (> (string.string-length name) 0)
        (= (string.string-ref name (- (string.string-length name) 1)) '?'))
      "direct-i64-predicate;no-result-commit"]
    [else "status-i64;session-state-only;commit-result-publishes-value"]))

(define (tlbm-emit-callback-rows
  [core-symbols : (& core-symbols svec.Vec)]
  [abi-names : (& abi-names svec.Vec)]
  [registry-symbols : (& registry-symbols svec.Vec)]
  [implementations : (& implementations svec.Vec)]
  [host : (& host str)]
  [producer : (& producer str)]
  [abi-version : (& abi-version str)]
  [rows : (&mut rows svec.Vec)]) : bool
  (let
    [index : i64 0]
    [ok : bool (= (svec.len core-symbols) (svec.len registry-symbols))]
    (begin
      (when
        (not ok)
        (if (tlbm-fail
          "callbacks"
          (str_cat.str-cat
            "ABI/host row count skew: ABI="
            (string.int->string (svec.len core-symbols))
            ", host="
            (string.int->string (svec.len registry-symbols))))
          unit
          unit))
      (while (and ok (< index (svec.len registry-symbols)))
        (let
          [symbol : String (svec.get registry-symbols index "")]
          [implementation : String (svec.get implementations index "")]
          [core-index : i64 (tlbm-find-index core-symbols (& symbol))]
          [body : String (tlbm-callback-body-range host (& implementation))]
          [adapter-body : String
            (if (= (string.string-length (& body)) 0)
              ""
              (tlbm-adapter-body host (& body) (& implementation)))]
          [via-adapter : bool (> (string.string-length (& adapter-body)) 0)]
          [guard-body : String
            (if via-adapter
              adapter-body
              body)]
          [capability : String (tlbm-capability (& symbol))]
          [input-shape : String (tlbm-callback-input-shape (& body))]
          [producer-token : String
            (str_cat.str-cat "tlci_core.tlci-host-callback-name-" symbol)]
          [producer-count : i64 (tlbm-count-token producer (& producer-token))]
          [definition-token : String
            (str_cat.str-cat "(define (" implementation)]
          [row : text_buf.TextBuf (text_buf.empty)]
          (cond
            [(< core-index 0)
              (set!
                ok
                (tlbm-fail symbol "host row has no ABI name declaration"))]
            [(= (string.string-length (& body)) 0)
              (set!
                ok
                (tlbm-fail
                  symbol
                  (str_cat.str-cat
                    "missing implementation `"
                    implementation
                    "`")))]
            [(not (= (tlbm-count-token host (& definition-token)) 1))
              (set!
                ok
                (tlbm-fail
                  symbol
                  "implementation definition is missing or duplicated"))]
            [(not (tlbm-body-has-guard? (& guard-body)))
              (set!
                ok
                (tlbm-fail
                  symbol
                  "implementation has no direct or one-hop session/bounds failure guard"))]
            [(= (string.string-length (& capability)) 0)
              (set!
                ok
                (tlbm-fail
                  symbol
                  "callback is not assigned to an audited capability class"))]
            [(= (string.string-length (& input-shape)) 0)
              (set!
                ok
                (tlbm-fail
                  symbol
                  "implementation is not the four-i64 stable callback ABI"))]
            [else
              (begin
                (text_buf.append! row "callback\t")
                (text_buf.append! row (svec.get abi-names core-index ""))
                (text_buf.append! row "\t")
                (text_buf.append! row (string.copy abi-version))
                (text_buf.append!
                  row
                  "\tcatalog-name+abi-version;compiler-owned-active-session\t")
                (text_buf.append! row input-shape)
                (text_buf.append! row "\t")
                (text_buf.append!
                  row
                  (tlbm-validation-summary (& guard-body) via-adapter))
                (text_buf.append! row "\t")
                (text_buf.append! row capability)
                (text_buf.append! row "\t")
                (text_buf.append! row (tlbm-result-contract (& symbol)))
                (text_buf.append!
                  row
                  "\tbad-request=4;diagnostic=1;fuel=2;abort=3;first-failure-latched\t")
                (text_buf.append! row (string.copy (& implementation)))
                (text_buf.append! row "\t")
                (text_buf.append!
                  row
                  (if (> producer-count 0)
                    (str_cat.str-cat
                      "native-producer-direct-count="
                      (string.int->string producer-count))
                    "generic-loader-import-admission"))
                (text_buf.append! row "\tsrc/compiler_embedded_stdlib_tlci.tl:")
                (text_buf.append! row implementation)
                (text_buf.append!
                  row
                  "\tverify-embedded-stdlib-tlci:native-corpus\t")
                (text_buf.append!
                  row
                  "verify-tlci-boundary-manifest:invalid-session-guard")
                (svec.push-ref! rows (text_buf.render row))
                (set! index (+ index 1)))])))
      (when
        ok
        (let
          [core-index : i64 0]
          (while (and ok (< core-index (svec.len core-symbols)))
            (let
              [symbol : String (svec.get core-symbols core-index "")]
              (begin
                (when
                  (< (tlbm-find-index registry-symbols (& symbol)) 0)
                  (set!
                    ok
                    (tlbm-fail symbol "ABI name has no host registry row")))
                (set! core-index (+ core-index 1)))))))
      ok)))

(define (tlbm-render [rows : (& rows svec.Vec)]) : String
  (let
    [out : text_buf.TextBuf
      (text_buf.append (text_buf.empty) (string.copy (& tlbm-manifest-header)))]
    [index : i64 0]
    (begin
      (while (< index (svec.len rows))
        (begin
          (text_buf.append! out (svec.get rows index ""))
          (text_buf.append! out "\n")
          (set! index (+ index 1))))
      (text_buf.render out))))

(define (tlbm-run
  [core-path : String]
  [host-path : String]
  [producer-path : String]
  [stage-catalog-path : String]
  [output-path : String]) : i64
  (let
    [core : String (tlbm-read core-path)]
    [host : String (tlbm-read host-path)]
    [producer : String (tlbm-read producer-path)]
    [stage-catalog : String (tlbm-read stage-catalog-path)]
    [core-symbols : svec.Vec (svec.new)]
    [abi-names : svec.Vec (svec.new)]
    [registry-symbols : svec.Vec (svec.new)]
    [implementations : svec.Vec (svec.new)]
    [host-version : String
      (tlbm-extract-version (& core) "tlci-host-abi-version")]
    [callback-version : String
      (tlbm-extract-version (& core) "tlci-callback-abi-version")]
    [rows : svec.Vec (svec.new)]
    (cond
      [(or
          (= (string.string-length (& host-version)) 0)
          (= (string.string-length (& callback-version)) 0))
        (tlbm-fail-status
          "ABI-version"
          "missing host or callback ABI version declaration")]
      [(not (string.eq host-version callback-version))
        (tlbm-fail-status
          "ABI-version"
          (str_cat.str-cat
            "host/callback version skew: host="
            host-version
            ", callback="
            callback-version))]
      [else
        (if (and
          (tlbm-parse-callback-constants
            (& core)
            (&mut core-symbols)
            (&mut abi-names))
          (tlbm-validate-producer-callbacks (& producer) (& core-symbols))
          (tlbm-parse-host-registry
            (& host)
            (&mut registry-symbols)
            (&mut implementations))
          (tlbm-copy-stage-rows stage-catalog (&mut rows))
          (tlbm-emit-callback-rows
            (& core-symbols)
            (& abi-names)
            (& registry-symbols)
            (& implementations)
            (& host)
            (& producer)
            (& host-version)
            (&mut rows)))
          (begin
            (let
              [rendered : String (tlbm-render (& rows))]
              (io.write-file output-path (byte_buf.str-as-bytes (& rendered))))
            0)
          1)])))

(define (main) : i64
  (if (= (io.arg-count) 6)
    (tlbm-run (io.arg 1) (io.arg 2) (io.arg 3) (io.arg 4) (io.arg 5))
    (begin
      (io.print-error
        "usage: tlci-boundary-manifest <tlci-core> <host> <producer> <stage-catalog> <output>\n")
      2)))

(test
  boundary-manifest-token-scanning
  (let
    [source : String "alpha beta beta-extra beta)"]
    [needle : String "beta"]
    (begin
      (test.assert-i64-eq
        (tlbm-find (& source) (& needle) 0)
        6
        "find returns the first byte offset")
      (test.assert-i64-eq
        (tlbm-count-token (& source) (& needle))
        2
        "token counts reject a longer identifier prefix"))))

(test
  boundary-manifest-capability-audit
  (let
    [unsafe-name : String "expr-ptr-read"]
    [type-name : String "type-array"]
    [unknown-name : String "new-unaudited-callback"]
    [unsafe-expected : String "unsafe-syntax-build"]
    [type-expected : String "type-build"]
    [unknown-expected : String ""]
    [unsafe-actual : String (tlbm-capability (& unsafe-name))]
    [type-actual : String (tlbm-capability (& type-name))]
    [unknown-actual : String (tlbm-capability (& unknown-name))]
    (begin
      (test.assert-string-eq
        (& unsafe-actual)
        (& unsafe-expected)
        "unsafe syntax builders have a dedicated capability")
      (test.assert-string-eq
        (& type-actual)
        (& type-expected)
        "type builders have a dedicated capability")
      (test.assert-string-eq
        (& unknown-actual)
        (& unknown-expected)
        "unknown callback names fail capability admission"))))

(test
  boundary-manifest-wire-shape
  (let
    [body : String
      "(define (callback\n  [session : i64]\n  [arg-a : i64]\n  [_arg-b : i64]\n  [_arg-c : i64]) : i64\n  0)"]
    [expected : String "session:i64,arg-a:i64,_arg-b:i64,_arg-c:i64"]
    [actual : String (tlbm-callback-input-shape (& body))]
    (test.assert-string-eq
      (& actual)
      (& expected)
      "callback wire shape is derived from the implementation signature")))