;; Canonical semantic identity for compiler-owned x86-64 templates.
(import compiler_owned_view as owned_view)
(import compiler_x64_executable_template as x64)
(import compiler_x64_executable_template_catalog as catalog)
(import compiler_x64_executable_template_evidence as evidence)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (compiler-x64-template-enum-name-at
  [names : (& names str)]
  [index : i64]
  [count : i64]) : String
  (if (or (< index 0) (>= index count))
    (io.panic "x64 executable template: enum tag is out of range")
    (let
      [at : i64 0]
      [start : i64 0]
      (begin
        (while (< at index)
          (let
            [end : i64 (string.index-of-byte names start (cast '|' : u8))]
            (if (< end 0)
              (io.panic "x64 executable template: enum name is missing")
              (begin
                (set! start (+ end 1))
                (set! at (+ at 1))))))
        (let
          [separator : i64 (string.index-of-byte names start (cast '|' : u8))]
          [end : i64
            (if (< separator 0)
              (string.string-length names)
              separator)]
          (string.substring names start (- end start)))))))

(define (compiler-x64-template-target-name
  [target : x64.CompilerX64TemplateTarget]) : String
  (compiler-x64-template-enum-name-at
    "any-x86_64|linux-x86_64|windows-x86_64"
    (x64.compiler-x64-template-enum-tag target)
    3))

(define (compiler-x64-template-abi-name [abi : evidence.CompilerX64TemplateAbi]) : String
  (compiler-x64-template-enum-name-at
    "internal-x86_64|sysv-x86_64|win64"
    (x64.compiler-x64-template-enum-tag abi)
    3))

(define (compiler-x64-template-feature-name
  [feature : evidence.CompilerX64TemplateFeature]) : String
  (compiler-x64-template-enum-name-at
    "always|alloc|region-mark|region-reset|profile|startup-profile|tlci-macro-entry|backtrace|arena-debug|profile+arena-debug|alloc+profile|alloc+arena-debug|alloc+profile+arena-debug|region-reset+profile|region-reset+arena-debug|region-reset+profile+arena-debug|native-entry+startup-profile|native-entry+backtrace|native-entry"
    (x64.compiler-x64-template-enum-tag feature)
    19))

(define (compiler-x64-template-render-kind-name
  [kind : x64.CompilerX64TemplateRenderKind]) : String
  (compiler-x64-template-enum-name-at
    "assembly|opaque-bytes|structured-object"
    (x64.compiler-x64-template-enum-tag kind)
    3))

(define (compiler-x64-template-contribution-kind-name
  [kind : evidence.CompilerX64TemplateContributionKind]) : String
  (compiler-x64-template-enum-name-at
    "runtime-functions|startup|tlci-bridge|external-fiber-callback|external-exception-callback|byte-fragment|mixed-runtime-bundle"
    (x64.compiler-x64-template-enum-tag kind)
    7))

(define (compiler-x64-template-terminal-name
  [terminal : evidence.CompilerX64TemplateTerminalBehavior]) : String
  (compiler-x64-template-enum-name-at
    "falls-through|returns|tail-transfers|terminates-process|suspends-or-terminates|returns-or-terminates|mixed|unknown"
    (x64.compiler-x64-template-enum-tag terminal)
    8))

(define (compiler-x64-template-field [value : (& value str)]) : String
  (let
    [owned : String (string.substring value 0 (string.string-length value))]
    (str_cat.str-cat
      (string.int->string (string.string-length value))
      ":"
      owned
      ";")))

;; Collision-free canonical identity: every field and the exact rendered
;; executable payload is length-delimited.  It is deterministic without a hash
;; table, checkout path, worker order, or process-global registry state.
(define (compiler-x64-template-semantic-identity
  [template : evidence.CompilerX64ExecutableTemplate]
  [id-name : String]
  [rendered-executable : String]) : String
  (let
    [schema-name : String (string.int->string template.schema)]
    [target-name : String (compiler-x64-template-target-name template.target)]
    [abi-name : String (compiler-x64-template-abi-name template.abi)]
    [feature-name : String
      (compiler-x64-template-feature-name template.feature)]
    [render-name : String
      (compiler-x64-template-render-kind-name template.render-kind)]
    [contribution-name : String
      (compiler-x64-template-contribution-kind-name template.contribution-kind)]
    [terminal-name : String
      (compiler-x64-template-terminal-name template.terminal)]
    (str_cat.str-cat
      "typelisp-x64-executable-template-v1|"
      (compiler-x64-template-field (& id-name))
      (compiler-x64-template-field (& schema-name))
      (compiler-x64-template-field template.producer)
      (compiler-x64-template-field (& target-name))
      (str_cat.str-cat
        (compiler-x64-template-field (& abi-name))
        (compiler-x64-template-field (& feature-name))
        (compiler-x64-template-field (& render-name))
        (compiler-x64-template-field (& contribution-name)))
      (str_cat.str-cat
        (compiler-x64-template-field template.entry-anchor)
        (compiler-x64-template-field template.interior-anchors)
        (compiler-x64-template-field template.end-anchor)
        (compiler-x64-template-field template.related-data)
        (compiler-x64-template-field (& terminal-name))
        (compiler-x64-template-field template.events)
        (compiler-x64-template-field (& rendered-executable))))))

(define (compiler-x64-template-registry-semantic-identity
  [id : x64.CompilerX64ExecutableTemplateId]
  [target : x64.CompilerX64TemplateTarget]
  [render-kind : x64.CompilerX64TemplateRenderKind]
  [rendered : String]) : String
  (let
    [id-name : String
      (evidence.compiler-x64-template-id-name
        (owned_view.compiler-owned-shared-view id))]
    [row : evidence.CompilerX64ExecutableTemplate
      (evidence.compiler-x64-template-registry-row id)]
    [gate : catalog.CompilerX64ExecutableTemplateGate
      (catalog.compiler-x64-template-registry-gate id)]
    (begin
      (catalog.compiler-x64-template-require-kind!
        (owned_view.compiler-owned-shared-view gate)
        target
        render-kind)
      (catalog.compiler-x64-template-require-rendered-payload!
        (owned_view.compiler-owned-shared-view gate)
        (& rendered))
      (compiler-x64-template-semantic-identity row id-name rendered))))