;; Independent canonical, mutation, and resource coverage for #7265.
(import compiler_incremental_binary as binary)
(import compiler_incremental_identity as identity)
(import compiler_owned_view as owned_view)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.string)

(define (incremental-test-zero-digest) : sha256.Sha256Digest
  (sha256.Sha256Digest (init)))

(define (incremental-test-build [material-length : i64]) : identity.CompilerIncrementalChildIdentity
  (identity.CompilerIncrementalChildIdentity
    "typelisp.compiler-build"
    1
    material-length
    (incremental-test-zero-digest)))

(define (incremental-test-semantic [material-length : i64]) : identity.CompilerIncrementalSemanticOutputIdentity
  (identity.CompilerIncrementalSemanticOutputIdentity
    (identity.CompilerIncrementalChildIdentity
      "typelisp.semantic-output"
      1
      material-length
      (incremental-test-zero-digest))))

(define (incremental-test-source-content [length : i64]) : identity.CompilerIncrementalContentIdentity
  (identity.CompilerIncrementalContentIdentity
    "typelisp.source-content"
    1
    length
    (incremental-test-zero-digest)))

(define (incremental-test-package-content [length : i64]) : identity.CompilerIncrementalContentIdentity
  (identity.CompilerIncrementalContentIdentity
    "typelisp.package-content"
    1
    length
    (incremental-test-zero-digest)))

(define (incremental-test-stdlib-content [length : i64]) : identity.CompilerIncrementalContentIdentity
  (identity.CompilerIncrementalContentIdentity
    "typelisp.stdlib-content"
    1
    length
    (incremental-test-zero-digest)))

(define (incremental-test-empty-inputs) : (__tl_dyn-array
    identity.CompilerIncrementalInput)
  (__tl_make-array identity.CompilerIncrementalInput 0))

(define (incremental-test-minimal-query) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.Parse)
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (incremental-test-empty-inputs)))

(define (incremental-test-source-query [reverse? : bool]) : identity.CompilerIncrementalQuery
  (let
    [a : identity.CompilerIncrementalInput
      (identity.CompilerIncrementalInput.SourceContent
        "a.tl"
        (incremental-test-source-content 10))]
    [b : identity.CompilerIncrementalInput
      (identity.CompilerIncrementalInput.SourceContent
        "b.tl"
        (incremental-test-source-content 20))]
    [inputs : (__tl_dyn-array identity.CompilerIncrementalInput)
      (__tl_make-array identity.CompilerIncrementalInput 2)]
    (begin
      (if reverse?
        (begin
          (set! (array-ref inputs 0) b)
          (set! (array-ref inputs 1) a))
        (begin
          (set! (array-ref inputs 0) a)
          (set! (array-ref inputs 1) b)))
      (identity.CompilerIncrementalQuery
        (identity.CompilerIncrementalQueryKind.Typecheck)
        (identity.CompilerIncrementalBuildIdentity.Available
          (incremental-test-build 5))
        inputs))))

(define (incremental-test-logical-query
  [module : String]
  [declaration : String]) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.Typecheck)
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (__tl_make-array
      (identity.CompilerIncrementalInput.LogicalName module declaration))))

(define (incremental-test-config-query [reverse? : bool] [duplicate? : bool]) : identity.CompilerIncrementalQuery
  (let
    [fields : (__tl_dyn-array identity.CompilerIncrementalConfigField)
      (__tl_make-array identity.CompilerIncrementalConfigField 2)]
    [alpha : identity.CompilerIncrementalConfigField
      (identity.CompilerIncrementalConfigField "alpha" "1")]
    [beta : identity.CompilerIncrementalConfigField
      (identity.CompilerIncrementalConfigField
        (if duplicate?
          "alpha"
          "alphb")
        "2")]
    (begin
      (if reverse?
        (begin
          (set! (array-ref fields 0) beta)
          (set! (array-ref fields 1) alpha))
        (begin
          (set! (array-ref fields 0) alpha)
          (set! (array-ref fields 1) beta)))
      (identity.CompilerIncrementalQuery
        (identity.CompilerIncrementalQueryKind.Object)
        (identity.CompilerIncrementalBuildIdentity.Available
          (incremental-test-build 5))
        (__tl_make-array
          (identity.CompilerIncrementalInput.Configuration
            (identity.CompilerIncrementalConfiguration
              "linux-x86_64"
              "debug"
              "native"
              2
              true
              "workspace"
              "tracked"
              fields)))))))

(define (incremental-test-config-material-query [variant : i64]) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.Object)
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (__tl_make-array
      (identity.CompilerIncrementalInput.Configuration
        (identity.CompilerIncrementalConfiguration
          (if (= variant 1)
            "windows-x86_64"
            "linux-x86_64")
          (if (= variant 2)
            "debug"
            "release")
          (if (= variant 3)
            "portable"
            "native")
          (if (= variant 4)
            1
            2)
          (= variant 5)
          (if (= variant 6)
            "checkout"
            "workspace")
          (if (= variant 7)
            "ephemeral"
            "tracked")
          (__tl_make-array
            (identity.CompilerIncrementalConfigField
              (if (= variant 8)
                "gamma"
                "alpha")
              (if (= variant 9)
                "2"
                "1"))))))))

(define (incremental-test-request-query [variant : i64]) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (cond
      [(= variant 1) (identity.CompilerIncrementalQueryKind.Object)]
      [(= variant 2) (identity.CompilerIncrementalQueryKind.IrSummary)]
      [(= variant 3)
        (identity.CompilerIncrementalQueryKind.IrDump "after-sccp")]
      [(= variant 4) (identity.CompilerIncrementalQueryKind.IrDump "after-dce")]
      [else (identity.CompilerIncrementalQueryKind.Assembly)])
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build
        (if (= variant 5)
          6
          5)))
    (__tl_make-array
      (identity.CompilerIncrementalInput.LogicalName
        (if (= variant 6)
          "app.other"
          "app.main")
        ""))))

(define (incremental-test-single-source-query) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.Assembly)
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (__tl_make-array
      (identity.CompilerIncrementalInput.SourceContent
        "src/main.tl"
        (incremental-test-source-content 100)))))

(define (incremental-test-ordered-query [duplicate-ordinal? : bool]) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.Lower)
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (__tl_make-array
      (identity.CompilerIncrementalInput.OrderedChild
        "declarations"
        0
        (identity.CompilerIncrementalChildIdentity
          "typelisp.declaration"
          1
          10
          (incremental-test-zero-digest)))
      (identity.CompilerIncrementalInput.OrderedChild
        "declarations"
        (if duplicate-ordinal?
          0
          1)
        (identity.CompilerIncrementalChildIdentity
          "typelisp.declaration"
          1
          20
          (incremental-test-zero-digest))))))

(define (incremental-test-child [domain : String] [material-length : i64]) : identity.CompilerIncrementalChildIdentity
  (identity.CompilerIncrementalChildIdentity
    domain
    1
    material-length
    (incremental-test-zero-digest)))

;; `variant` zero is the baseline.  Variants one through ten mutate exactly one
;; material field in the correspondingly tagged input family.
(define (incremental-test-all-input-query [variant : i64]) : identity.CompilerIncrementalQuery
  (identity.CompilerIncrementalQuery
    (identity.CompilerIncrementalQueryKind.IrDump "after-sccp")
    (identity.CompilerIncrementalBuildIdentity.Available
      (incremental-test-build 5))
    (__tl_make-array
      (identity.CompilerIncrementalInput.SourceContent
        (if (= variant 1)
          "src/other.tl"
          "src/main.tl")
        (incremental-test-source-content 100))
      (identity.CompilerIncrementalInput.LogicalName
        "app.main"
        (if (= variant 2)
          "other"
          "entry"))
      (identity.CompilerIncrementalInput.ImportedSurface
        "dep"
        "dep.core"
        (incremental-test-semantic
          (if (= variant 3)
            301
            300)))
      (identity.CompilerIncrementalInput.ImportedArtifact
        "dep"
        "target/dep.o"
        "typelisp.artifact.object"
        (incremental-test-child
          "typelisp.imported-artifact"
          (if (= variant 4)
            401
            400)))
      (identity.CompilerIncrementalInput.PackageProvenance
        "dep"
        "1.2.3"
        (incremental-test-package-content
          (if (= variant 5)
            501
            500)))
      (identity.CompilerIncrementalInput.StdlibProvenance
        "embedded-stage0"
        (incremental-test-stdlib-content
          (if (= variant 6)
            601
            600)))
      (identity.CompilerIncrementalInput.Configuration
        (identity.CompilerIncrementalConfiguration
          "linux-x86_64"
          "release"
          "native"
          (if (= variant 7)
            1
            2)
          false
          "workspace"
          "tracked"
          (__tl_make-array identity.CompilerIncrementalConfigField 0)))
      (identity.CompilerIncrementalInput.MacroComptime
        "typelisp.macro.expand"
        (incremental-test-child "typelisp.macro-request" 700)
        (incremental-test-child
          "typelisp.macro-result"
          (if (= variant 8)
            801
            800)))
      (identity.CompilerIncrementalInput.CodegenTarget
        (if (= variant 9)
          "windows-x86_64"
          "linux-x86_64")
        "native"
        "scalar")
      (identity.CompilerIncrementalInput.OrderedChild
        "declarations"
        0
        (incremental-test-child
          "typelisp.declaration"
          (if (= variant 10)
            901
            900))))))

(define (incremental-test-copy [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (binary.compiler-incremental-binary-copy bytes))

(define (incremental-test-prefix
  [bytes : (& bytes (__tl_dyn-array u8))]
  [length : i64]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! (array-ref out index) (array-ref bytes index))
          (set! index (+ index 1))))
      out)))

(define (incremental-test-append-zero [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ (array-length bytes) 1))]
    [index : i64 0]
    (begin
      (while (< index (array-length bytes))
        (begin
          (set! (array-ref out index) (array-ref bytes index))
          (set! index (+ index 1))))
      (set! (array-ref out index) (cast 0 : u8))
      out)))

(define (incremental-test-encode [query : identity.CompilerIncrementalQuery]) : identity.ResultCompilerIncrementalIdentity
  (let
    [limits : identity.CompilerIncrementalIdentityLimits
      (identity.compiler-incremental-identity-default-limits)]
    (identity.compiler-incremental-identity-encode query (& limits))))

(define (incremental-test-decode-rejects?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [code : i64]) : bool
  (let
    [limits : identity.CompilerIncrementalIdentityLimits
      (identity.compiler-incremental-identity-default-limits)]
    (match (identity.compiler-incremental-identity-decode bytes (& limits))
      [(identity.ResultCompilerIncrementalDecodedQuery.Err error)
        (= error.code code)]
      [(identity.ResultCompilerIncrementalDecodedQuery.Ok _) false])))

(define (incremental-test-result-error-code?
  [result : identity.ResultCompilerIncrementalIdentity]
  [code : i64]) : bool
  (match result
    [(identity.ResultCompilerIncrementalIdentity.Err error) (= error.code code)]
    [(identity.ResultCompilerIncrementalIdentity.Ok _) false]))

(define (incremental-test-identities-eq?
  [left : (& left identity.CompilerIncrementalIdentity)]
  [right : (& right identity.CompilerIncrementalIdentity)]) : bool
  (and
    (binary.compiler-incremental-binary-bytes-eq?
      (& left.transcript)
      (& right.transcript))
    (sha256.digest-eq? (& left.fingerprint) (& right.fingerprint))))

(define (incremental-test-minimal-oracle?) : bool
  (match (incremental-test-encode (incremental-test-minimal-query))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (and
        (= (array-length encoded.transcript) 119)
        (= (array-ref encoded.transcript 0) (cast 35 : u8))
        (= (array-ref encoded.transcript 39) (cast 1 : u8))
        (= (array-ref encoded.transcript 43) (cast 1 : u8))
        (= (array-ref encoded.transcript 44) (cast 23 : u8))
        (= (array-ref encoded.transcript 71) (cast 1 : u8))
        (= (array-ref encoded.transcript 75) (cast 5 : u8))
        (= (array-ref encoded.transcript 115) (cast 0 : u8))
        (string.eq
          (sha256.to-hex (& encoded.fingerprint))
          "790328b355820f24bd991ca354a44cf7e5aa4d1a3874d0ef96d4944467ef8f91")
        (let
          [limits : identity.CompilerIncrementalIdentityLimits
            (identity.compiler-incremental-identity-default-limits)]
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& limits))
            [(identity.ResultCompilerIncrementalDecodedQuery.Ok decoded)
              (let
                [expected-build : identity.CompilerIncrementalChildIdentity
                  (incremental-test-build 5)]
                (and
                  (= (array-length decoded.inputs) 0)
                  (identity.compiler-incremental-child-eq?
                    (& decoded.compiler-build)
                    (& expected-build))))]
            [(identity.ResultCompilerIncrementalDecodedQuery.Err _) false])))]))

(define (incremental-test-order-and-framing?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok forward)
      (match (incremental-test-encode (incremental-test-source-query true))
        [(identity.ResultCompilerIncrementalIdentity.Err _) false]
        [(identity.ResultCompilerIncrementalIdentity.Ok reverse)
          (match (incremental-test-encode
            (incremental-test-logical-query "ab" "c"))
            [(identity.ResultCompilerIncrementalIdentity.Err _) false]
            [(identity.ResultCompilerIncrementalIdentity.Ok split-left)
              (match (incremental-test-encode
                (incremental-test-logical-query "a" "bc"))
                [(identity.ResultCompilerIncrementalIdentity.Err _) false]
                [(identity.ResultCompilerIncrementalIdentity.Ok split-right)
                  (and
                    (incremental-test-identities-eq? (& forward) (& reverse))
                    (not
                      (incremental-test-identities-eq?
                        (& split-left)
                        (& split-right))))])])])]))

(define (incremental-test-config-and-sequence-canonical?) : bool
  (match (incremental-test-encode (incremental-test-config-query false false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok forward)
      (match (incremental-test-encode
        (incremental-test-config-query true false))
        [(identity.ResultCompilerIncrementalIdentity.Err _) false]
        [(identity.ResultCompilerIncrementalIdentity.Ok reverse)
          (and
            (incremental-test-identities-eq? (& forward) (& reverse))
            (incremental-test-result-error-code?
              (incremental-test-encode
                (incremental-test-config-query false true))
              identity.compiler-incremental-error-order)
            (incremental-test-result-error-code?
              (incremental-test-encode (incremental-test-ordered-query true))
              identity.compiler-incremental-error-order)
            (match (incremental-test-encode
              (incremental-test-ordered-query false))
              [(identity.ResultCompilerIncrementalIdentity.Ok _) true]
              [(identity.ResultCompilerIncrementalIdentity.Err _) false]))])]))

(define (incremental-test-config-duplicate-name-decode?) : bool
  (match (incremental-test-encode (incremental-test-config-query false false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (let
        [mutated : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [index : i64 0]
        [found : i64 -1]
        (begin
          (while (and (< index (- (array-length mutated) 4)) (< found 0))
            (if (and
              (= (array-ref mutated index) (cast 97 : u8))
              (= (array-ref mutated (+ index 1)) (cast 108 : u8))
              (= (array-ref mutated (+ index 2)) (cast 112 : u8))
              (= (array-ref mutated (+ index 3)) (cast 104 : u8))
              (= (array-ref mutated (+ index 4)) (cast 98 : u8)))
              (set! found index)
              (set! index (+ index 1))))
          (if (< found 0)
            false
            (begin
              (set! (array-ref mutated (+ found 4)) (cast 97 : u8))
              (incremental-test-decode-rejects?
                (& mutated)
                identity.compiler-incremental-error-order)))))]))

(define (incremental-test-config-materiality?) : bool
  (match (incremental-test-encode (incremental-test-config-material-query 0))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok baseline)
      (let
        [variant : i64 1]
        [all-differ? : bool true]
        (begin
          (while (and all-differ? (<= variant 9))
            (match (incremental-test-encode
              (incremental-test-config-material-query variant))
              [(identity.ResultCompilerIncrementalIdentity.Err _)
                (set! all-differ? false)]
              [(identity.ResultCompilerIncrementalIdentity.Ok changed)
                (if (sha256.digest-eq?
                  (& baseline.fingerprint)
                  (& changed.fingerprint))
                  (set! all-differ? false)
                  (set! variant (+ variant 1)))]))
          all-differ?))]))

(define (incremental-test-request-materiality?) : bool
  (match (incremental-test-encode (incremental-test-request-query 0))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok baseline)
      (let
        [variant : i64 1]
        [all-differ? : bool true]
        (begin
          (while (and all-differ? (<= variant 6))
            (match (incremental-test-encode
              (incremental-test-request-query variant))
              [(identity.ResultCompilerIncrementalIdentity.Err _)
                (set! all-differ? false)]
              [(identity.ResultCompilerIncrementalIdentity.Ok changed)
                (if (sha256.digest-eq?
                  (& baseline.fingerprint)
                  (& changed.fingerprint))
                  (set! all-differ? false)
                  (set! variant (+ variant 1)))]))
          all-differ?))]))

(define (incremental-test-compare-category?
  [left-query : identity.CompilerIncrementalQuery]
  [right-query : identity.CompilerIncrementalQuery]
  [expected : i64]) : bool
  (match (incremental-test-encode left-query)
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok left)
      (match (incremental-test-encode right-query)
        [(identity.ResultCompilerIncrementalIdentity.Err _) false]
        [(identity.ResultCompilerIncrementalIdentity.Ok right)
          (let
            [limits : identity.CompilerIncrementalIdentityLimits
              (identity.compiler-incremental-identity-default-limits)]
            (match (identity.compiler-incremental-identity-compare
              (& left)
              (& right)
              (& limits))
              [(identity.CompilerIncrementalCompareResult.Miss miss)
                (and
                  (= miss.category expected)
                  (<= (string.string-length (& miss.explanation)) 96))]
              [_ false]))])]))

(define (incremental-test-typed-miss-categories?) : bool
  (and
    (incremental-test-compare-category?
      (incremental-test-request-query 0)
      (incremental-test-request-query 1)
      identity.compiler-incremental-miss-query-kind)
    (incremental-test-compare-category?
      (incremental-test-request-query 0)
      (incremental-test-request-query 5)
      identity.compiler-incremental-miss-compiler-build)
    (incremental-test-compare-category?
      (incremental-test-request-query 0)
      (incremental-test-single-source-query)
      identity.compiler-incremental-miss-input-kind)
    (incremental-test-compare-category?
      (incremental-test-request-query 0)
      (incremental-test-request-query 6)
      identity.compiler-incremental-miss-input-value)))

(define (incremental-test-all-input-families?) : bool
  (match (incremental-test-encode (incremental-test-all-input-query 0))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok baseline)
      (let
        [limits : identity.CompilerIncrementalIdentityLimits
          (identity.compiler-incremental-identity-default-limits)]
        [variant : i64 1]
        [mutations-differ? : bool true]
        [round-trip? : bool
          (match (identity.compiler-incremental-identity-decode
            (& baseline.transcript)
            (& limits))
            [(identity.ResultCompilerIncrementalDecodedQuery.Err _) false]
            [(identity.ResultCompilerIncrementalDecodedQuery.Ok decoded)
              (let
                [index : i64 0]
                [tags? : bool (= (array-length decoded.inputs) 10)]
                (begin
                  (while (and tags? (< index 10))
                    (let
                      [input : identity.CompilerIncrementalInput
                        (owned_view.compiler-owned-array-element-shared-view
                          decoded.inputs
                          index)]
                      (if (=
                        (identity.compiler-incremental-input-tag (& input))
                        (+ index 1))
                        (set! index (+ index 1))
                        (set! tags? false))))
                  tags?))])]
        (begin
          (while (and mutations-differ? (<= variant 10))
            (match (incremental-test-encode
              (incremental-test-all-input-query variant))
              [(identity.ResultCompilerIncrementalIdentity.Err _)
                (set! mutations-differ? false)]
              [(identity.ResultCompilerIncrementalIdentity.Ok changed)
                (if (sha256.digest-eq?
                  (& baseline.fingerprint)
                  (& changed.fingerprint))
                  (set! mutations-differ? false)
                  (set! variant (+ variant 1)))]))
          (and round-trip? mutations-differ?)))]))

(define (incremental-test-content-domains?) : bool
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array 1 2 3)]
    [limits : identity.CompilerIncrementalIdentityLimits
      (identity.compiler-incremental-identity-default-limits)]
    (match (identity.compiler-incremental-content-identity
      "typelisp.source-content"
      (& bytes)
      (& limits))
      [(identity.ResultCompilerIncrementalContentIdentity.Err _) false]
      [(identity.ResultCompilerIncrementalContentIdentity.Ok source)
        (match (identity.compiler-incremental-content-identity
          "typelisp.package-content"
          (& bytes)
          (& limits))
          [(identity.ResultCompilerIncrementalContentIdentity.Err _) false]
          [(identity.ResultCompilerIncrementalContentIdentity.Ok package)
            (and
              (= source.schema 1)
              (= source.exact-length 3)
              (= package.exact-length 3)
              (string.eq
                (sha256.to-hex (& source.fingerprint))
                "0b8e9d0727abc25da9f42fea7ae3ba555a3c4b1d6bb89404e757a3d1be5bdda4")
              (not
                (sha256.digest-eq?
                  (& source.fingerprint)
                  (& package.fingerprint))))])])))

(define (incremental-test-mutations?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (let
        [truncated : (__tl_dyn-array u8)
          (incremental-test-prefix
            (& encoded.transcript)
            (- (array-length encoded.transcript) 1))]
        [trailing : (__tl_dyn-array u8)
          (incremental-test-append-zero (& encoded.transcript))]
        [schema : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [query-tag : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [input-tag : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [utf8 : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [path : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [out-of-order : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [duplicate : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [overlength : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        [overflow : (__tl_dyn-array u8)
          (incremental-test-copy (& encoded.transcript))]
        (begin
          (set! (array-ref schema 39) (cast 2 : u8))
          (set! (array-ref query-tag 43) (cast 99 : u8))
          (set! (array-ref input-tag 119) (cast 99 : u8))
          (set! (array-ref utf8 4) (cast 0xff : u8))
          (set! (array-ref path 128) (cast 47 : u8))
          (set! (array-ref out-of-order 128) (cast 122 : u8))
          ;; The second same-sized source record begins at byte 203.
          (set! (array-ref duplicate 212) (cast 97 : u8))
          (set! (array-ref duplicate 247) (cast 10 : u8))
          (set! (array-ref overlength 120) (cast 0xff : u8))
          (set! (array-ref overlength 121) (cast 0xff : u8))
          (set! (array-ref overlength 122) (cast 0xff : u8))
          (set! (array-ref overlength 123) (cast 0xff : u8))
          ;; First source content exact-length high byte: checked u64->i64.
          (set! (array-ref overflow 170) (cast 0xff : u8))
          (and
            (incremental-test-decode-rejects?
              (& truncated)
              identity.compiler-incremental-error-truncated)
            (incremental-test-decode-rejects?
              (& trailing)
              identity.compiler-incremental-error-trailing)
            (incremental-test-decode-rejects?
              (& schema)
              identity.compiler-incremental-error-schema)
            (incremental-test-decode-rejects?
              (& query-tag)
              identity.compiler-incremental-error-unknown-tag)
            (incremental-test-decode-rejects?
              (& input-tag)
              identity.compiler-incremental-error-unknown-tag)
            (incremental-test-decode-rejects?
              (& utf8)
              identity.compiler-incremental-error-utf8)
            (incremental-test-decode-rejects?
              (& path)
              identity.compiler-incremental-error-path)
            (incremental-test-decode-rejects?
              (& out-of-order)
              identity.compiler-incremental-error-order)
            (incremental-test-decode-rejects?
              (& duplicate)
              identity.compiler-incremental-error-order)
            (incremental-test-decode-rejects?
              (& overlength)
              identity.compiler-incremental-error-input-limit)
            (incremental-test-decode-rejects?
              (& overflow)
              identity.compiler-incremental-error-value))))]))

(define (incremental-test-source-length?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (let
        [limits : identity.CompilerIncrementalIdentityLimits
          (identity.compiler-incremental-identity-default-limits)]
        (and
          (= (array-length encoded.transcript) 287)
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& limits))
            [(identity.ResultCompilerIncrementalDecodedQuery.Ok decoded)
              (= (array-length decoded.inputs) 2)]
            [(identity.ResultCompilerIncrementalDecodedQuery.Err _) false])))]))

(define (incremental-test-truncated-only?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (let
        [truncated : (__tl_dyn-array u8)
          (incremental-test-prefix
            (& encoded.transcript)
            (- (array-length encoded.transcript) 1))]
        (incremental-test-decode-rejects?
          (& truncated)
          identity.compiler-incremental-error-truncated))]))

(define (incremental-test-limits-and-invalid-values?) : bool
  (let
    [tiny-owned : identity.CompilerIncrementalIdentityLimits
      (identity.CompilerIncrementalIdentityLimits 4096 16 1024 128 8 1 4096)]
    [tiny-work : identity.CompilerIncrementalIdentityLimits
      (identity.CompilerIncrementalIdentityLimits 4096 16 1024 128 8 4096 1)]
    [invalid : identity.CompilerIncrementalIdentityLimits
      (identity.CompilerIncrementalIdentityLimits -1 16 1024 128 8 4096 4096)]
    [bad-path : identity.CompilerIncrementalQuery
      (identity.CompilerIncrementalQuery
        (identity.CompilerIncrementalQueryKind.Typecheck)
        (identity.CompilerIncrementalBuildIdentity.Available
          (incremental-test-build 5))
        (__tl_make-array
          (identity.CompilerIncrementalInput.SourceContent
            "../escape.tl"
            (incremental-test-source-content 1))))]
    [no-build : identity.CompilerIncrementalQuery
      (identity.CompilerIncrementalQuery
        (identity.CompilerIncrementalQueryKind.Parse)
        (identity.CompilerIncrementalBuildIdentity.Unavailable "not generated")
        (incremental-test-empty-inputs))]
    (and
      (incremental-test-result-error-code?
        (identity.compiler-incremental-identity-encode
          (incremental-test-minimal-query)
          (& tiny-owned))
        identity.compiler-incremental-error-owned-limit)
      (incremental-test-result-error-code?
        (identity.compiler-incremental-identity-encode bad-path (& tiny-work))
        identity.compiler-incremental-error-path)
      (incremental-test-result-error-code?
        (identity.compiler-incremental-identity-encode no-build (& tiny-work))
        identity.compiler-incremental-error-build-unavailable)
      (incremental-test-result-error-code?
        (identity.compiler-incremental-identity-encode
          (incremental-test-minimal-query)
          (& invalid))
        identity.compiler-incremental-error-invalid-limits))))

(define (incremental-test-decoder-ceilings?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok encoded)
      (let
        [count-limit : identity.CompilerIncrementalIdentityLimits
          (identity.CompilerIncrementalIdentityLimits
            4096
            1
            1024
            128
            8
            4096
            4096)]
        [string-limit : identity.CompilerIncrementalIdentityLimits
          (identity.CompilerIncrementalIdentityLimits
            4096
            16
            1024
            10
            8
            4096
            4096)]
        [owned-limit : identity.CompilerIncrementalIdentityLimits
          (identity.CompilerIncrementalIdentityLimits
            4096
            16
            1024
            128
            8
            100
            4096)]
        [work-limit : identity.CompilerIncrementalIdentityLimits
          (identity.CompilerIncrementalIdentityLimits
            4096
            16
            1024
            128
            8
            4096
            10)]
        [depth-limit : identity.CompilerIncrementalIdentityLimits
          (identity.CompilerIncrementalIdentityLimits
            4096
            16
            1024
            128
            2
            4096
            4096)]
        (and
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& count-limit))
            [(identity.ResultCompilerIncrementalDecodedQuery.Err error)
              (= error.code identity.compiler-incremental-error-record-limit)]
            [_ false])
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& string-limit))
            [(identity.ResultCompilerIncrementalDecodedQuery.Err error)
              (= error.code identity.compiler-incremental-error-string-limit)]
            [_ false])
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& owned-limit))
            [(identity.ResultCompilerIncrementalDecodedQuery.Err error)
              (= error.code identity.compiler-incremental-error-owned-limit)]
            [_ false])
          (match (identity.compiler-incremental-identity-decode
            (& encoded.transcript)
            (& work-limit))
            [(identity.ResultCompilerIncrementalDecodedQuery.Err error)
              (= error.code identity.compiler-incremental-error-work-limit)]
            [_ false])
          (incremental-test-result-error-code?
            (identity.compiler-incremental-identity-encode
              (incremental-test-source-query false)
              (& depth-limit))
            identity.compiler-incremental-error-depth-limit)))]))

(define (incremental-test-miss-and-corruption?) : bool
  (match (incremental-test-encode (incremental-test-source-query false))
    [(identity.ResultCompilerIncrementalIdentity.Err _) false]
    [(identity.ResultCompilerIncrementalIdentity.Ok left)
      (match (incremental-test-encode
        (incremental-test-logical-query "main" "entry"))
        [(identity.ResultCompilerIncrementalIdentity.Err _) false]
        [(identity.ResultCompilerIncrementalIdentity.Ok right)
          (let
            [limits : identity.CompilerIncrementalIdentityLimits
              (identity.compiler-incremental-identity-default-limits)]
            [collision : identity.CompilerIncrementalIdentity
              (identity.CompilerIncrementalIdentity
                right.schema
                right.query-kind-tag
                right.record-count
                (incremental-test-copy (& right.transcript))
                (owned_view.compiler-owned-shared-view left.fingerprint))]
            [bad-metadata : identity.CompilerIncrementalIdentity
              (identity.CompilerIncrementalIdentity
                left.schema
                left.query-kind-tag
                (+ left.record-count 1)
                (incremental-test-copy (& left.transcript))
                (owned_view.compiler-owned-shared-view left.fingerprint))]
            [bad-fingerprint : identity.CompilerIncrementalIdentity
              (identity.CompilerIncrementalIdentity
                left.schema
                left.query-kind-tag
                left.record-count
                (incremental-test-copy (& left.transcript))
                (incremental-test-zero-digest))]
            (and
              (match (identity.compiler-incremental-identity-compare
                (& left)
                (& left)
                (& limits))
                [(identity.CompilerIncrementalCompareResult.Hit) true]
                [_ false])
              (match (identity.compiler-incremental-identity-compare
                (& left)
                (& right)
                (& limits))
                [(identity.CompilerIncrementalCompareResult.Miss miss)
                  (=
                    miss.category
                    identity.compiler-incremental-miss-record-count)]
                [_ false])
              (match (identity.compiler-incremental-identity-compare
                (& left)
                (& collision)
                (& limits))
                [(identity.CompilerIncrementalCompareResult.Miss miss)
                  (and
                    (=
                      miss.category
                      identity.compiler-incremental-miss-fingerprint-collision)
                    (<= (string.string-length (& miss.explanation)) 96))]
                [_ false])
              (match (identity.compiler-incremental-identity-compare
                (& left)
                (& bad-metadata)
                (& limits))
                [(identity.CompilerIncrementalCompareResult.Corrupt error)
                  (= error.code identity.compiler-incremental-error-fingerprint)]
                [_ false])
              (match (identity.compiler-incremental-identity-compare
                (& left)
                (& bad-fingerprint)
                (& limits))
                [(identity.CompilerIncrementalCompareResult.Corrupt error)
                  (= error.code identity.compiler-incremental-error-fingerprint)]
                [_ false])
              (let
                [store-key : (Array u8 32)
                  (identity.compiler-incremental-identity-store-fingerprint
                    (& left))]
                (=
                  (array-ref store-key 0)
                  (sha256.digest-byte (& left.fingerprint) 0)))))])]))

(test
  compiler-incremental-identity-independent-minimal-oracle
  (if (incremental-test-minimal-oracle?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-order-and-frame-ambiguity
  (if (incremental-test-order-and-framing?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-configuration-and-sequence-order
  (if (incremental-test-config-and-sequence-canonical?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-configuration-field-materiality
  (if (incremental-test-config-materiality?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-configuration-duplicate-name-decode
  (if (incremental-test-config-duplicate-name-decode?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-request-materiality
  (if (incremental-test-request-materiality?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-typed-miss-categories
  (if (incremental-test-typed-miss-categories?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-all-input-families
  (if (incremental-test-all-input-families?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-content-domain-separation
  (if (incremental-test-content-domains?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-mutations
  (if (incremental-test-mutations?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-source-fixture-length
  (if (incremental-test-source-length?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-truncated-only
  (if (incremental-test-truncated-only?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-limits-and-invalid-values
  (if (incremental-test-limits-and-invalid-values?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-decoder-ceilings
  (if (incremental-test-decoder-ceilings?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-incremental-identity-misses-and-corruption
  (if (incremental-test-miss-and-corruption?)
    unit
    (string.tl_oob_abort)))