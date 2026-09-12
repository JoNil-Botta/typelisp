;; Checked, source-derived inventory of IR and machine/ABI safety contracts.
;; The catalog describes obligations; production enum declarations own identity.
;; Refs #7271.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define bsm-header : String
  "domain\tidentity\ttargets\toptimizer_effect\tmemory\taccess\tprovenance\tordering\tfailure\tabi\tobligation\twitness\tdisposition\tsource_site\n")

(define (bsm-fail [identity : String] [reason : String]) : bool
  (begin
    (io.print-error
      (str_cat.str-cat "backend safety manifest: " identity ": " reason "\n"))
    false))

(define (bsm-find
  [source : (& source str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [cursor : i64 start]
    [found : i64 -1]
    [limit : i64
      (- (string.string-length source) (string.string-length needle))]
    (begin
      (while (and (< found 0) (<= cursor limit))
        (if (string.is-string-prefix-at source needle cursor)
          (set! found cursor)
          (set! cursor (+ cursor 1))))
      found)))

(define (bsm-line-end [source : (& source str)] [start : i64]) : i64
  (let
    [end : i64 (bsm-find source "\n" start)]
    (if (< end 0)
      (string.string-length source)
      end)))

(define (bsm-token-delimiter? [source : (& source str)] [index : i64]) : bool
  (if (>= index (string.string-length source))
    true
    (let
      [c : char (string.string-ref source index)]
      (or (= c ' ') (= c '\t') (= c '\n') (= c ')') (= c ']') (= c '(')))))

(define (bsm-find-token
  [source : (& source str)]
  [token : (& token str)]
  [start : i64]) : i64
  (let
    [cursor : i64 start]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [candidate : i64 (bsm-find source token cursor)]
          (if (< candidate 0)
            (set! done true)
            (if (bsm-token-delimiter?
              source
              (+ candidate (string.string-length token)))
              (begin
                (set! found candidate)
                (set! done true))
              (set! cursor (+ candidate (string.string-length token)))))))
      found)))

(define (bsm-token-end [source : (& source str)] [start : i64]) : i64
  (let
    [cursor : i64 start]
    [length : i64 (string.string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< cursor length))
        (let
          [c : char (string.string-ref source cursor)]
          (if (or (= c ' ') (= c '\t') (= c '\n') (= c ')') (= c ']') (= c '('))
            (set! done true)
            (set! cursor (+ cursor 1)))))
      cursor)))

(define (bsm-field [line : (& line str)] [wanted : i64]) : String
  (let
    [cursor : i64 0]
    [field : i64 0]
    [start : i64 0]
    [length : i64 (string.string-length line)]
    [found : bool false]
    [out : String ""]
    (begin
      (while (and (not found) (<= cursor length))
        (if (or (= cursor length) (= (string.string-ref line cursor) '\t'))
          (if (= field wanted)
            (begin
              (set! out (string.substring line start (- cursor start)))
              (set! found true))
            (begin
              (set! field (+ field 1))
              (set! start (+ cursor 1))
              (set! cursor (+ cursor 1))))
          (set! cursor (+ cursor 1))))
      out)))

(define (bsm-tab-count [line : (& line str)]) : i64
  (let
    [cursor : i64 0]
    [count : i64 0]
    (begin
      (while (< cursor (string.string-length line))
        (begin
          (when
            (= (string.string-ref line cursor) '\t')
            (set! count (+ count 1)))
          (set! cursor (+ cursor 1))))
      count)))

(define (bsm-index [items : (& items svec.Vec)] [key : (& key str)]) : i64
  (let
    [cursor : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< cursor (svec.len items)))
        (if (string.eq (svec.get items cursor "") key)
          (set! found cursor)
          (set! cursor (+ cursor 1))))
      found)))

(define (bsm-read [path : String]) : String
  (byte_buf.to-string (io.read-file path)))

;; Keep route and guard probes inside the owning production function. A token
;; elsewhere in the source file (including a smoke test) is not evidence that
;; the emitter/serializer still handles that identity.
(define (bsm-function-body [source : (& source str)] [name : (& name str)]) : String
  (let
    [multiline-marker : String (str_cat.str-cat "(define (" name "\n")]
    [inline-marker : String (str_cat.str-cat "(define (" name " ")]
    [multiline-start : i64 (bsm-find source (& multiline-marker) 0)]
    [start : i64
      (if (< multiline-start 0)
        (bsm-find source (& inline-marker) 0)
        multiline-start)]
    [next : i64
      (if (< start 0)
        -1
        (bsm-find source "\n(define " (+ start 1)))]
    [end : i64
      (if (< next 0)
        (string.string-length source)
        next)]
    (if (< start 0)
      ""
      (string.substring source start (- end start)))))

(define (bsm-guard
  [identity : String]
  [source : (& source str)]
  [function-name : String]
  [before : String]
  [after : String]) : bool
  (let
    [body : String (bsm-function-body source (& function-name))]
    [first : i64 (bsm-find (& body) (& before) 0)]
    [second : i64
      (if (< first 0)
        -1
        (bsm-find
          (& body)
          (& after)
          (+ first (string.string-length (& before)))))]
    (if (and (>= first 0) (> second first))
      true
      (bsm-fail
        identity
        (str_cat.str-cat "missing or reordered guard in " function-name)))))

(define (bsm-collect-enum
  [root : (& root str)]
  [domain : (& domain str)]
  [enum-name : (& enum-name str)]
  [path : (& path str)]
  [keys : (&mut keys svec.Vec)]
  [sites : (&mut sites svec.Vec)]) : bool
  (let
    [full-path : String (str_cat.str-cat root "/" path)]
    [source : String (bsm-read full-path)]
    [marker : String (str_cat.str-cat "(defenum " enum-name "\n")]
    [start : i64 (bsm-find (& source) (& marker) 0)]
    [cursor : i64
      (if (< start 0)
        0
        (+ (bsm-line-end (& source) start) 1))]
    [count : i64 0]
    [done : bool false]
    [ok : bool (>= start 0)]
    (begin
      (while (and ok (not done) (< cursor (string.string-length (& source))))
        (let
          [end : i64 (bsm-line-end (& source) cursor)]
          [line : String (string.substring (& source) cursor (- end cursor))]
          (cond
            [(string.is-string-prefix-at (& line) "(" 0) (set! done true)]
            [(string.is-string-prefix-at (& line) "  (" 0)
              (let
                [token-end : i64 (bsm-token-end (& line) 3)]
                [identity : String
                  (string.substring (& line) 3 (- token-end 3))]
                [key : String (str_cat.str-cat domain "." identity)]
                (if (or
                  (= (string.string-length (& identity)) 0)
                  (>= (bsm-index keys (& key)) 0))
                  (set! ok (bsm-fail key "duplicate or empty enum identity"))
                  (begin
                    (svec.push-ref! keys key)
                    (svec.push-ref!
                      sites
                      (str_cat.str-cat path ":" enum-name "." identity))
                    (set! count (+ count 1)))))]
            [else unit])
          (set! cursor (+ end 1))))
      (cond
        [(< start 0)
          (bsm-fail
            (string.copy enum-name)
            "production enum declaration is missing")]
        [(not ok) false]
        [(= count 0)
          (bsm-fail (string.copy enum-name) "production enum has no variants")]
        [else true]))))

(define (bsm-collect-registries
  [root : (& root str)]
  [registry-text : (& registry-text str)]
  [keys : (&mut keys svec.Vec)]
  [sites : (&mut sites svec.Vec)]) : bool
  (let
    [cursor : i64 0]
    [line-number : i64 0]
    [ok : bool
      (string.is-string-prefix-at registry-text "domain\tenum\tsource\n" 0)]
    (begin
      (while (and ok (< cursor (string.string-length registry-text)))
        (let
          [end : i64 (bsm-line-end registry-text cursor)]
          [line : String (string.substring registry-text cursor (- end cursor))]
          (begin
            (when
              (> line-number 0)
              (if (not (= (bsm-tab-count (& line)) 2))
                (set! ok (bsm-fail "registries" "expected three TSV fields"))
                (set!
                  ok
                  (bsm-collect-enum
                    root
                    (bsm-field (& line) 0)
                    (bsm-field (& line) 1)
                    (bsm-field (& line) 2)
                    keys
                    sites))))
            (set! cursor (+ end 1))
            (set! line-number (+ line-number 1)))))
      (if (not ok)
        (bsm-fail "registries" "malformed header or registry row")
        (if (> line-number 1)
          true
          (bsm-fail "registries" "no production registries"))))))

(define (bsm-collect-catalog
  [catalog : (& catalog str)]
  [keys : (&mut keys svec.Vec)]
  [rows : (&mut rows svec.Vec)]) : bool
  (let
    [cursor : i64 0]
    [line-number : i64 0]
    [ok : bool
      (string.is-string-prefix-at
        catalog
        "domain\tidentity\tcontract\twitness\tdisposition\n"
        0)]
    (begin
      (while (and ok (< cursor (string.string-length catalog)))
        (let
          [end : i64 (bsm-line-end catalog cursor)]
          [line : String (string.substring catalog cursor (- end cursor))]
          (begin
            (when
              (> line-number 0)
              (let
                [key : String
                  (str_cat.str-cat
                    (bsm-field (& line) 0)
                    "."
                    (bsm-field (& line) 1))]
                [field : i64 0]
                (cond
                  [(not (= (bsm-tab-count (& line)) 4))
                    (set! ok (bsm-fail key "expected five TSV fields"))]
                  [(>= (bsm-index keys (& key)) 0)
                    (set! ok (bsm-fail key "duplicate contract row"))]
                  [else
                    (begin
                      (while (and ok (< field 5))
                        (begin
                          (when
                            (=
                              (string.string-length (bsm-field (& line) field))
                              0)
                            (set!
                              ok
                              (bsm-fail
                                (string.copy (& key))
                                "empty contract field")))
                          (set! field (+ field 1))))
                      (when
                        ok
                        (begin
                          (svec.push-ref! keys key)
                          (svec.push-ref! rows line))))])))
            (set! cursor (+ end 1))
            (set! line-number (+ line-number 1)))))
      (if (not ok)
        (bsm-fail "catalog" "malformed header or catalog row")
        (if (> line-number 1)
          true
          (bsm-fail "catalog" "no identity rows"))))))

(define (bsm-collect-contracts
  [contracts : (& contracts str)]
  [keys : (&mut keys svec.Vec)]
  [rows : (&mut rows svec.Vec)]) : bool
  (let
    [cursor : i64 0]
    [line-number : i64 0]
    [ok : bool
      (string.is-string-prefix-at
        contracts
        "contract\ttargets\toptimizer_effect\tmemory\taccess\tprovenance\tordering\tfailure\tabi\tobligation\n"
        0)]
    (begin
      (while (and ok (< cursor (string.string-length contracts)))
        (let
          [end : i64 (bsm-line-end contracts cursor)]
          [line : String (string.substring contracts cursor (- end cursor))]
          (begin
            (when
              (> line-number 0)
              (let
                [key : String (bsm-field (& line) 0)]
                [field : i64 0]
                (cond
                  [(not (= (bsm-tab-count (& line)) 9))
                    (set! ok (bsm-fail key "expected ten contract fields"))]
                  [(>= (bsm-index keys (& key)) 0)
                    (set! ok (bsm-fail key "duplicate contract definition"))]
                  [else
                    (begin
                      (while (and ok (< field 10))
                        (begin
                          (when
                            (=
                              (string.string-length (bsm-field (& line) field))
                              0)
                            (set!
                              ok
                              (bsm-fail
                                (string.copy (& key))
                                "empty contract definition field")))
                          (set! field (+ field 1))))
                      (when
                        ok
                        (begin
                          (svec.push-ref! keys key)
                          (svec.push-ref! rows line))))])))
            (set! cursor (+ end 1))
            (set! line-number (+ line-number 1)))))
      (if (not ok)
        (bsm-fail "contracts" "malformed header or contract row")
        (if (> line-number 1)
          true
          (bsm-fail "contracts" "no contract definitions"))))))

(define (bsm-verify-ir-effect
  [ir-source : (& ir-source str)]
  [identity : (& identity str)]
  [expected : (& expected str)]) : bool
  (let
    [function-start : i64
      (bsm-find ir-source "(define (compiler-ir-instr-effect" 0)]
    [function-end : i64
      (if (< function-start 0)
        -1
        (bsm-find ir-source ";; Source provenance side table" function-start))]
    [marker : String (str_cat.str-cat "[(CompilerIrInstr." identity)]
    [start : i64
      (if (< function-start 0)
        -1
        (bsm-find-token ir-source (& marker) function-start))]
    [next : i64
      (if (< start 0)
        -1
        (bsm-find ir-source "[(CompilerIrInstr." (+ start 2)))]
    [end : i64
      (if (< next 0)
        function-end
        next)]
    (if (or (< start 0) (< end 0) (>= start function-end))
      (bsm-fail (string.copy identity) "missing optimizer-effect match arm")
      (let
        [arm : String (string.substring ir-source start (- end start))]
        [tag-start : i64 (bsm-find (& arm) "CompilerIrEffect." 0)]
        [actual : String
          (if (< tag-start 0)
            (if (string.contains (& arm) "compiler-ir-direct-call-effect-id")
              "DynamicCall"
              "")
            (string.substring
              (& arm)
              (+ tag-start 17)
              (- (bsm-token-end (& arm) (+ tag-start 17)) (+ tag-start 17))))]
        (if (string.eq actual expected)
          true
          (bsm-fail
            (string.copy identity)
            (str_cat.str-cat
              "optimizer effect differs: expected "
              expected
              " found "
              actual)))))))

(define (bsm-route-present?
  [source : (& source str)]
  [enum-name : String]
  [identity : (& identity str)]) : bool
  (let
    [token : String (str_cat.str-cat enum-name "." identity)]
    (>= (bsm-find-token source (& token) 0) 0)))

(define (bsm-verify-route
  [domain : (& domain str)]
  [identity : (& identity str)]
  [backend : (& backend str)]
  [object-asm : (& object-asm str)]
  [object-elf : (& object-elf str)]
  [object-coff : (& object-coff str)]) : bool
  (cond
    [(string.eq domain "ir_instr")
      (if (bsm-route-present?
        (bsm-function-body backend "compiler-backend-emit-instr")
        "CompilerIrInstr"
        identity)
        true
        (bsm-fail (string.copy identity) "missing backend IR dispatch route"))]
    [(string.eq domain "object_instr")
      (if (and
        (bsm-route-present?
          (bsm-function-body object-asm "compiler-object-asm-render-instr!")
          "CompilerObjectX64Instr"
          identity)
        (bsm-route-present?
          (bsm-function-body object-elf "compiler-object-elf-render-instr!")
          "CompilerObjectX64Instr"
          identity)
        (bsm-route-present?
          (bsm-function-body object-coff "compiler-object-coff-render-instr!")
          "CompilerObjectX64Instr"
          identity))
        true
        (bsm-fail
          (string.copy identity)
          "missing assembly/ELF/COFF instruction route"))]
    [(string.eq domain "object_data")
      (if (and
        (bsm-route-present?
          (bsm-function-body
            object-asm
            "compiler-object-asm-render-data-record!")
          "CompilerObjectDataRecord"
          identity)
        (bsm-route-present?
          (bsm-function-body
            object-elf
            "compiler-object-elf-render-data-record!")
          "CompilerObjectDataRecord"
          identity)
        (bsm-route-present?
          (bsm-function-body
            object-coff
            "compiler-object-coff-render-data-record!")
          "CompilerObjectDataRecord"
          identity))
        true
        (bsm-fail (string.copy identity) "missing assembly/ELF/COFF data route"))]
    [(string.eq domain "object_reloc")
      (if (and
        (bsm-route-present?
          (bsm-function-body object-coff "compiler-object-coff-relocation-type")
          "CompilerObjectRelocationKind"
          identity)
        (or
          (string.eq identity "Addr32Nb")
          (bsm-route-present?
            (bsm-function-body object-elf "compiler-object-elf-relocation-type")
            "CompilerObjectRelocationKind"
            identity)))
        true
        (bsm-fail (string.copy identity) "missing ELF/COFF relocation route"))]
    [else true]))

(define (bsm-verify-core-guards
  [backend : (& backend str)]
  [lower : (& lower str)]
  [abi : (& abi str)]
  [regalloc : (& regalloc str)]
  [object-asm : (& object-asm str)]
  [object-elf : (& object-elf str)]
  [object-coff : (& object-coff str)]) : bool
  (and
    (bsm-guard
      "bounds-variable-dominance"
      backend
      "compiler-backend-bounds-check-asm"
      "\"    cmpq \""
      "(compiler-backend-bounds-check-tail")
    (bsm-guard
      "bounds-constant-dominance"
      backend
      "compiler-backend-bounds-check-const-index-asm"
      "\"    cmpq \""
      "(compiler-backend-bounds-check-tail")
    (bsm-guard
      "bounds-abort-routing"
      backend
      "compiler-backend-bounds-check-tail"
      "tl_oob_abort_at"
      "cbi.compiler-builtin-id-tl-oob-abort")
    (bsm-guard
      "sysv-sse-aggregate-class"
      lower
      "lower-c-abi-sysv-merge-sse"
      "lower-c-abi-sysv-pack-f32-sse?"
      "(ast.AstType.F64)")
    (bsm-guard
      "win64-shadow-space"
      abi
      "compiler-abi-outgoing-shadow-space"
      "[(CompilerRegTargetAbi.Linux) 0]"
      "[(CompilerRegTargetAbi.Windows) 32]")
    (bsm-guard
      "avx512-masked-read"
      backend
      "compiler-backend-emit-avx512-predicated-load"
      "compiler-backend-avx512-mask-register-use"
      "\"}{z}")
    (bsm-guard
      "avx2-masked-read"
      backend
      "compiler-backend-emit-avx2-predicated-load"
      "\"load mask\""
      "compiler-backend-avx2-masked-move-mnemonic")
    (bsm-guard
      "object-target-format"
      backend
      "compiler-backend-target-policy-new"
      "CompilerBackendObjectFormatPolicy.Elf"
      "CompilerBackendObjectFormatPolicy.Coff")
    (bsm-guard
      "object-abi-reject"
      backend
      "compiler-backend-object-abi-type-supported?"
      "(define (compiler-backend-object-abi-type-supported?"
      "compiler-backend-intlike-scalar-type?")
    (bsm-guard
      "scratch-live-home"
      regalloc
      "compiler-reg-scratch-assign-items-with-hulls!"
      "compiler-reg-scratch-tail-mask-count-role?"
      "compiler-reg-scratch-pick-register-with-siblings")
    (bsm-guard
      "raw-asm-reject"
      object-asm
      "compiler-object-asm-render-instr!"
      "[(cobj.CompilerObjectX64Instr.Raw _)"
      "false])")
    (bsm-guard
      "raw-coff-reject"
      object-coff
      "compiler-object-coff-instrs-supported?"
      "[(cobj.CompilerObjectX64Instr.Raw _)"
      "(set! ok false)")
    (bsm-guard
      "raw-elf-admit"
      object-elf
      "compiler-object-elf-render-instr!"
      "[(cobj.CompilerObjectX64Instr.Raw bytes)"
      "(compiler-object-elf-push-string-bytes! out bytes)")))

(define (bsm-render
  [expected-keys : (& expected-keys svec.Vec)]
  [sites : (& sites svec.Vec)]
  [catalog-keys : (& catalog-keys svec.Vec)]
  [catalog-rows : (& catalog-rows svec.Vec)]
  [contract-keys : (& contract-keys svec.Vec)]
  [contract-rows : (& contract-rows svec.Vec)]
  [ir-source : (& ir-source str)]
  [backend : (& backend str)]
  [object-asm : (& object-asm str)]
  [object-elf : (& object-elf str)]
  [object-coff : (& object-coff str)]) : String
  (let
    [out : text_buf.TextBuf
      (text_buf.append (text_buf.empty) (string.copy (& bsm-header)))]
    [cursor : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< cursor (svec.len expected-keys)))
        (let
          [key : String (svec.get expected-keys cursor "")]
          [index : i64 (bsm-index catalog-keys (& key))]
          (if (< index 0)
            (set! ok (bsm-fail key "missing contract row"))
            (let
              [row : String (svec.get catalog-rows index "")]
              [domain : String (bsm-field (& row) 0)]
              [identity : String (bsm-field (& row) 1)]
              [contract-id : String (bsm-field (& row) 2)]
              [contract-index : i64 (bsm-index contract-keys (& contract-id))]
              (if (< contract-index 0)
                (set! ok (bsm-fail key "unknown contract identity"))
                (let
                  [contract : String (svec.get contract-rows contract-index "")]
                  [effect : String (bsm-field (& contract) 2)]
                  [field : i64 1]
                  (if (or
                    (and
                      (string.eq domain "ir_instr")
                      (not
                        (bsm-verify-ir-effect ir-source (& identity) (& effect))))
                    (not
                      (bsm-verify-route
                        (& domain)
                        (& identity)
                        backend
                        object-asm
                        object-elf
                        object-coff)))
                    (set! ok false)
                    (begin
                      (text_buf.append! out (string.copy (& domain)))
                      (text_buf.append! out "\t")
                      (text_buf.append! out (string.copy (& identity)))
                      (while (< field 10)
                        (begin
                          (text_buf.append! out "\t")
                          (text_buf.append! out (bsm-field (& contract) field))
                          (set! field (+ field 1))))
                      (text_buf.append! out "\t")
                      (text_buf.append! out (bsm-field (& row) 3))
                      (text_buf.append! out "\t")
                      (text_buf.append! out (bsm-field (& row) 4))
                      (text_buf.append! out "\t")
                      (text_buf.append! out (svec.get sites cursor ""))
                      (text_buf.append! out "\n"))))))))
        (set! cursor (+ cursor 1)))
      (when
        ok
        (begin
          (set! cursor 0)
          (while (and ok (< cursor (svec.len catalog-keys)))
            (let
              [key : String (svec.get catalog-keys cursor "")]
              (when
                (< (bsm-index expected-keys (& key)) 0)
                (set!
                  ok
                  (bsm-fail key "contract has no production enum identity"))))
            (set! cursor (+ cursor 1)))))
      (when
        ok
        (begin
          (set! cursor 0)
          (while (and ok (< cursor (svec.len contract-keys)))
            (let
              [key : String (svec.get contract-keys cursor "")]
              [catalog-index : i64 0]
              [used : bool false]
              (begin
                (while (and
                  (not used)
                  (< catalog-index (svec.len catalog-rows)))
                  (let
                    [row : String (svec.get catalog-rows catalog-index "")]
                    (if (string.eq (bsm-field (& row) 2) (& key))
                      (set! used true)
                      (set! catalog-index (+ catalog-index 1)))))
                (when
                  (not used)
                  (set! ok (bsm-fail key "unused contract definition")))))
            (set! cursor (+ cursor 1)))))
      (if ok
        (text_buf.render out)
        ""))))

(define (bsm-run
  [root : String]
  [registries-path : String]
  [catalog-path : String]
  [contracts-path : String]
  [output-path : String]) : i64
  (let
    [registries : String (bsm-read registries-path)]
    [catalog : String (bsm-read catalog-path)]
    [contracts : String (bsm-read contracts-path)]
    [ir-path : String (str_cat.str-cat root "/src/compiler_ir_types.tl")]
    [ir-source : String (bsm-read ir-path)]
    [backend : String
      (bsm-read (str_cat.str-cat root "/src/compiler_backend.tl"))]
    [lower : String (bsm-read (str_cat.str-cat root "/src/compiler_lower.tl"))]
    [abi : String (bsm-read (str_cat.str-cat root "/src/compiler_abi.tl"))]
    [regalloc : String
      (bsm-read (str_cat.str-cat root "/src/compiler_regalloc.tl"))]
    [object-asm : String
      (bsm-read (str_cat.str-cat root "/src/compiler_object_asm.tl"))]
    [object-elf : String
      (bsm-read (str_cat.str-cat root "/src/compiler_object_elf.tl"))]
    [object-coff : String
      (bsm-read (str_cat.str-cat root "/src/compiler_object_coff.tl"))]
    [expected-keys : svec.Vec (svec.new)]
    [sites : svec.Vec (svec.new)]
    [catalog-keys : svec.Vec (svec.new)]
    [catalog-rows : svec.Vec (svec.new)]
    [contract-keys : svec.Vec (svec.new)]
    [contract-rows : svec.Vec (svec.new)]
    (if (and
      (bsm-collect-registries
        (& root)
        (& registries)
        (&mut expected-keys)
        (&mut sites))
      (bsm-collect-catalog (& catalog) (&mut catalog-keys) (&mut catalog-rows))
      (bsm-collect-contracts
        (& contracts)
        (&mut contract-keys)
        (&mut contract-rows))
      (bsm-verify-core-guards
        (& backend)
        (& lower)
        (& abi)
        (& regalloc)
        (& object-asm)
        (& object-elf)
        (& object-coff)))
      (let
        [rendered : String
          (bsm-render
            (& expected-keys)
            (& sites)
            (& catalog-keys)
            (& catalog-rows)
            (& contract-keys)
            (& contract-rows)
            (& ir-source)
            (& backend)
            (& object-asm)
            (& object-elf)
            (& object-coff))]
        (if (= (string.string-length (& rendered)) 0)
          1
          (begin
            (io.write-file output-path (byte_buf.str-as-bytes (& rendered)))
            0)))
      1)))

(define (main) : i64
  (if (= (io.arg-count) 6)
    (bsm-run (io.arg 1) (io.arg 2) (io.arg 3) (io.arg 4) (io.arg 5))
    (begin
      (io.print-error
        "usage: backend-safety-manifest <source-root> <registries.tsv> <catalog.tsv> <contracts.tsv> <output.tsv>\n")
      2)))

(test
  backend-safety-manifest-tsv-fields
  (let
    [line : String "ir_instr\tLoad\tboth\tMemoryRead"]
    [expected : String "Load"]
    [actual : String (bsm-field (& line) 1)]
    (begin
      (test.assert-string-eq (& actual) (& expected) "field extraction")
      (test.assert-i64-eq (bsm-tab-count (& line)) 3 "tab count"))))