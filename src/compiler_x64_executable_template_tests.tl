;; compiler_x64_executable_template_tests.tl - Registry, identity, and drift tests.
(import compiler_x64_executable_template as x64)
(import compiler_x64_executable_template_catalog as catalog)
(import compiler_backend_runtime_common as runtime_common)
(import compiler_backend_runtime_linux as runtime_linux)
(import compiler_backend_runtime_windows as runtime_windows)
(import stdlib.string)
(import stdlib.test)

(define (compiler-x64-template-test-kind-eq?
  [left : x64.CompilerX64TemplateEventKind]
  [right : x64.CompilerX64TemplateEventKind]) : bool
  (match left
    [(x64.CompilerX64TemplateEventKind.DirectCall)
      (match right
        [(x64.CompilerX64TemplateEventKind.DirectCall) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.IndirectCall)
      (match right
        [(x64.CompilerX64TemplateEventKind.IndirectCall) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.HardwareReturn)
      (match right
        [(x64.CompilerX64TemplateEventKind.HardwareReturn) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.DirectTailJump)
      (match right
        [(x64.CompilerX64TemplateEventKind.DirectTailJump) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.IndirectTailJump)
      (match right
        [(x64.CompilerX64TemplateEventKind.IndirectTailJump) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.LocalBranch)
      (match right
        [(x64.CompilerX64TemplateEventKind.LocalBranch) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.StackAdjust)
      (match right
        [(x64.CompilerX64TemplateEventKind.StackAdjust) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.StackRebase)
      (match right
        [(x64.CompilerX64TemplateEventKind.StackRebase) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.SaveRegister)
      (match right
        [(x64.CompilerX64TemplateEventKind.SaveRegister) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.RestoreRegister)
      (match right
        [(x64.CompilerX64TemplateEventKind.RestoreRegister) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.IncomingStackRead)
      (match right
        [(x64.CompilerX64TemplateEventKind.IncomingStackRead) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.IncomingStackWrite)
      (match right
        [(x64.CompilerX64TemplateEventKind.IncomingStackWrite) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.TerminalProcessTransfer)
      (match right
        [(x64.CompilerX64TemplateEventKind.TerminalProcessTransfer) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.ExternalContextSwitch)
      (match right
        [(x64.CompilerX64TemplateEventKind.ExternalContextSwitch) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.ExternalCallbackEntry)
      (match right
        [(x64.CompilerX64TemplateEventKind.ExternalCallbackEntry) true]
        [_ false])]
    [(x64.CompilerX64TemplateEventKind.Unsupported)
      (match right
        [(x64.CompilerX64TemplateEventKind.Unsupported) true]
        [_ false])]))

(define (compiler-x64-template-test-event-count-kind
  [events : (& events x64.CompilerX64TemplateEventSeq)]
  [expected : x64.CompilerX64TemplateEventKind]) : i64
  (let
    [at : i64 0]
    [count : i64 0]
    (begin
      (while (< at events.count)
        (begin
          (match (x64.compiler-x64-template-event-ref events at)
            [(x64.ResultCompilerX64TemplateEvent.Ok event)
              (when
                (compiler-x64-template-test-kind-eq? event.kind expected)
                (set! count (+ count 1)))]
            [(x64.ResultCompilerX64TemplateEvent.Err _) unit])
          (set! at (+ at 1))))
      count)))

(define (compiler-x64-template-test-custom-row
  [target : x64.CompilerX64TemplateTarget]
  [entry : String]
  [events : String]) : x64.CompilerX64ExecutableTemplate
  (catalog.compiler-x64-template-row
    (x64.CompilerX64ExecutableTemplateId.LinuxObjectStartContribution)
    "test:producer"
    target
    (x64.CompilerX64TemplateAbi.SystemV)
    (x64.CompilerX64TemplateFeature.NativeEntry)
    (x64.CompilerX64TemplateRenderKind.StructuredObject)
    (x64.CompilerX64TemplateContributionKind.Startup)
    entry
    ""
    "end"
    (x64.CompilerX64TemplateTerminalBehavior.TerminatesProcess)
    events
    -1
    -1))

(define (compiler-x64-template-test-runtime-variants
  [profile : bool]
  [arena-debug : bool]
  [startup-profile : bool]
  [extra-features : bool]) : unit
  (let
    [features : runtime_common.CompilerBackendRuntimeFeatures
      (runtime_common.CompilerBackendRuntimeFeatures
        true
        extra-features
        true
        arena-debug
        profile
        extra-features
        extra-features
        startup-profile
        extra-features)]
    [linux : String
      (runtime_linux.compiler-backend-runtime-functions (& features))]
    [windows : String
      (runtime_windows.compiler-backend-runtime-functions (& features))]
    (begin
      (test.assert-true
        (> (string.string-length (& linux)) 0)
        "Linux runtime variant passes its registered payload ratchet")
      (test.assert-true
        (> (string.string-length (& windows)) 0)
        "Windows runtime variant passes its registered payload ratchet"))))

(define (compiler-x64-template-tests-main) : i64
  (let
    [ids : x64.CompilerX64ExecutableTemplateIdList
      (catalog.compiler-x64-template-all-ids)]
    [at : i64 0]
    [event-count : i64 0]
    [event-bytes : i64 0]
    [pinned-payloads : i64 0]
    [unpinned-assembly : i64 0]
    [unpinned-structured : i64 0]
    [events-valid : bool true]
    (begin
      (while (and events-valid (< at ids.len))
        (let
          [id : x64.CompilerX64ExecutableTemplateId
            (x64.compiler-x64-template-id-list-ref (& ids) at)]
          [row : x64.CompilerX64ExecutableTemplate
            (catalog.compiler-x64-template-registry-row id)]
          [event-at : i64 0]
          (begin
            (set! event-count (+ event-count row.events.count))
            (set!
              event-bytes
              (+ event-bytes (string.string-length (& row.events.transcript))))
            (if (>= row.expected-rendered-size 0)
              (begin
                (set! pinned-payloads (+ pinned-payloads 1))
                (when
                  (< row.expected-rendered-hash 0)
                  (set! events-valid false)))
              (match row.render-kind
                [(x64.CompilerX64TemplateRenderKind.Assembly)
                  (set! unpinned-assembly (+ unpinned-assembly 1))]
                [(x64.CompilerX64TemplateRenderKind.StructuredObject)
                  (set! unpinned-structured (+ unpinned-structured 1))]
                [(x64.CompilerX64TemplateRenderKind.OpaqueBytes)
                  (set! events-valid false)]))
            (while (and events-valid (< event-at row.events.count))
              (begin
                (match (x64.compiler-x64-template-event-ref
                  (& row.events)
                  event-at)
                  [(x64.ResultCompilerX64TemplateEvent.Ok _) unit]
                  [(x64.ResultCompilerX64TemplateEvent.Err _)
                    (set! events-valid false)])
                (set! event-at (+ event-at 1))))
            (set! at (+ at 1)))))
      (test.assert-i64-eq ids.len 82 "closed executable-template row count")
      (test.assert-i64-eq
        (array-length ids.slots)
        96
        "bounded all-row construction capacity")
      (test.assert-i64-eq
        event-count
        2499
        "reviewed ordered control/frame event count")
      (test.assert-i64-eq
        event-bytes
        15042
        "reviewed event-transcript byte count")
      (test.assert-i64-eq
        pinned-payloads
        69
        "fixed assembly and opaque payloads are pinned")
      (test.assert-i64-eq
        unpinned-assembly
        4
        "dynamic compiler entry fragments remain caller-identified")
      (test.assert-i64-eq
        unpinned-structured
        9
        "structured object contributions are caller-identified")
      (test.assert-true
        events-valid
        "every event token parses into a closed event kind")
      (test.assert-true
        (catalog.compiler-x64-template-selection-unique? (& ids))
        "closed registry ids are unique")
      (let
        [minimal : x64.CompilerX64TemplateFeatures
          (x64.CompilerX64TemplateFeatures
            false
            false
            false
            false
            false
            false
            false
            false)]
        [full : x64.CompilerX64TemplateFeatures
          (x64.CompilerX64TemplateFeatures
            true
            true
            true
            true
            true
            true
            true
            true)]
        [linux-min : x64.CompilerX64ExecutableTemplateIdList
          (catalog.compiler-x64-runtime-template-selection
            (x64.CompilerX64TemplateTarget.LinuxX64)
            (& minimal))]
        [linux-full : x64.CompilerX64ExecutableTemplateIdList
          (catalog.compiler-x64-runtime-template-selection
            (x64.CompilerX64TemplateTarget.LinuxX64)
            (& full))]
        [windows-min : x64.CompilerX64ExecutableTemplateIdList
          (catalog.compiler-x64-runtime-template-selection
            (x64.CompilerX64TemplateTarget.WindowsX64)
            (& minimal))]
        [windows-full : x64.CompilerX64ExecutableTemplateIdList
          (catalog.compiler-x64-runtime-template-selection
            (x64.CompilerX64TemplateTarget.WindowsX64)
            (& full))]
        (begin
          (test.assert-i64-eq
            linux-min.len
            6
            "minimal Linux template selection")
          (test.assert-i64-eq linux-full.len 13 "full Linux template selection")
          (test.assert-i64-eq
            windows-min.len
            8
            "minimal Windows template selection")
          (test.assert-i64-eq
            windows-full.len
            15
            "full Windows template selection")
          (test.assert-i64-eq
            (array-length linux-full.slots)
            20
            "runtime selection uses fixed reviewed capacity")
          (test.assert-true
            (and
              (catalog.compiler-x64-template-selection-unique? (& linux-full))
              (catalog.compiler-x64-template-selection-unique? (& windows-full)))
            "feature selection cannot render a template id twice")))
      (cfg
        (any compiler-arena-debug test)
        (begin
          (compiler-x64-template-test-runtime-variants false false false false)
          (compiler-x64-template-test-runtime-variants false true false false)
          (compiler-x64-template-test-runtime-variants true false false false)
          (compiler-x64-template-test-runtime-variants true true true true))
        (begin
          (compiler-x64-template-test-runtime-variants false false false false)
          (compiler-x64-template-test-runtime-variants true false true true)))
      (let
        [windows-bundle : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeLibcShim))]
        [windows-start : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.WindowsObjectStartContribution))]
        [windows-fiber : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.WindowsObjectMainFiberContribution))]
        [windows-filter : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterContribution))]
        (begin
          (test.assert-i64-eq
            (compiler-x64-template-test-event-count-kind
              (& windows-bundle.events)
              (x64.CompilerX64TemplateEventKind.ExternalContextSwitch))
            1
            "assembly startup records SwitchToFiber as context transfer")
          (test.assert-i64-eq
            (compiler-x64-template-test-event-count-kind
              (& windows-bundle.events)
              (x64.CompilerX64TemplateEventKind.ExternalCallbackEntry))
            2
            "assembly startup records both external callbacks")
          (test.assert-i64-eq
            (compiler-x64-template-test-event-count-kind
              (& windows-start.events)
              (x64.CompilerX64TemplateEventKind.ExternalContextSwitch))
            1
            "direct-object startup records SwitchToFiber")
          (test.assert-i64-eq
            (compiler-x64-template-test-event-count-kind
              (& windows-fiber.events)
              (x64.CompilerX64TemplateEventKind.ExternalCallbackEntry))
            1
            "direct-object fiber has external entry origin")
          (test.assert-i64-eq
            (compiler-x64-template-test-event-count-kind
              (& windows-filter.events)
              (x64.CompilerX64TemplateEventKind.HardwareReturn))
            1
            "overflow callback records canonical hardware return")
          (test.assert-true
            (and
              (string.contains
                (& windows-bundle.interior-anchors)
                ".L_tl_main_fiber")
              (string.eq windows-bundle.end-anchor "tl_boot_off"))
            "Windows assembly bundle pins its local callback range anchors")
          (test.assert-true
            (string.contains
              (& windows-start.related-data)
              "xdata-size=8|xdata-hash=2141552412")
            "Windows object range pins its shared unwind-data relation")))
      (let
        [base : String
          (x64.compiler-x64-template-semantic-identity
            (compiler-x64-template-test-custom-row
              (x64.CompilerX64TemplateTarget.LinuxX64)
              "entry"
              "C:main\nR")
            "fixture"
            "bytes-a")]
        [payload-change : String
          (x64.compiler-x64-template-semantic-identity
            (compiler-x64-template-test-custom-row
              (x64.CompilerX64TemplateTarget.LinuxX64)
              "entry"
              "C:main\nR")
            "fixture"
            "bytes-b")]
        [event-change : String
          (x64.compiler-x64-template-semantic-identity
            (compiler-x64-template-test-custom-row
              (x64.CompilerX64TemplateTarget.LinuxX64)
              "entry"
              "T:main")
            "fixture"
            "bytes-a")]
        [target-change : String
          (x64.compiler-x64-template-semantic-identity
            (compiler-x64-template-test-custom-row
              (x64.CompilerX64TemplateTarget.WindowsX64)
              "entry"
              "C:main\nR")
            "fixture"
            "bytes-a")]
        [anchor-change : String
          (x64.compiler-x64-template-semantic-identity
            (compiler-x64-template-test-custom-row
              (x64.CompilerX64TemplateTarget.LinuxX64)
              "other"
              "C:main\nR")
            "fixture"
            "bytes-a")]
        [identity-prefix : String "typelisp-x64-executable-template-v1|"]
        (begin
          (test.assert-true
            (and
              (not (string.eq base payload-change))
              (not (string.eq base event-change))
              (not (string.eq base target-change))
              (not (string.eq base anchor-change)))
            "identity changes on executable, event, target, and anchor mutation")
          (test.assert-true
            (string.contains (& base) (& identity-prefix))
            "identity pins the versioned producer schema")))
      (let
        [schema-one : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        [schema-two : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        [terminal-change : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        [abi-change : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        [feature-change : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        [related-data-change : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            "entry"
            "C:main\nR")]
        (begin
          (set! schema-two.schema 2)
          (set!
            terminal-change.terminal
            (x64.CompilerX64TemplateTerminalBehavior.Returns))
          (set! abi-change.abi (x64.CompilerX64TemplateAbi.Win64))
          (set!
            feature-change.feature
            (x64.CompilerX64TemplateFeature.Backtrace))
          (set! related-data-change.related-data "unwind-record-v2")
          (let
            [identity-one : String
              (x64.compiler-x64-template-semantic-identity
                schema-one
                "fixture"
                "bytes")]
            [identity-two : String
              (x64.compiler-x64-template-semantic-identity
                schema-two
                "fixture"
                "bytes")]
            [identity-terminal : String
              (x64.compiler-x64-template-semantic-identity
                terminal-change
                "fixture"
                "bytes")]
            [identity-abi : String
              (x64.compiler-x64-template-semantic-identity
                abi-change
                "fixture"
                "bytes")]
            [identity-feature : String
              (x64.compiler-x64-template-semantic-identity
                feature-change
                "fixture"
                "bytes")]
            [identity-related-data : String
              (x64.compiler-x64-template-semantic-identity
                related-data-change
                "fixture"
                "bytes")]
            (test.assert-true
              (and
                (not (string.eq identity-one identity-two))
                (not (string.eq identity-one identity-terminal))
                (not (string.eq identity-one identity-abi))
                (not (string.eq identity-one identity-feature))
                (not (string.eq identity-one identity-related-data)))
              "schema, terminal, ABI, feature, and related-data mutations change identity"))))
      (let
        [payload : String
          (runtime_linux.compiler-backend-runtime-memcpy-functions)]
        [matching : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        [changed : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        [same-size-change : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        [mutated : String
          (string.replace
            (runtime_linux.compiler-backend-runtime-memcpy-functions)
            "tl_memcpy_fwd:"
            "xl_memcpy_fwd:")]
        (begin
          (set!
            changed.expected-rendered-size
            (+ changed.expected-rendered-size 1))
          (test.assert-true
            (catalog.compiler-x64-template-rendered-payload-valid?
              matching
              (& payload))
            "registered payload size and hash accept the reviewed renderer")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-rendered-payload-valid?
                changed
                (& payload)))
            "payload size drift fails the reviewed ratchet")
          (test.assert-i64-eq
            (string.string-length (& mutated))
            (string.string-length (& payload))
            "same-size payload mutation fixture")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-rendered-payload-valid?
                same-size-change
                (& mutated)))
            "same-size payload byte drift fails the reviewed hash")))
      (let
        [linux-row : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        [linux-row-wrong-target : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        [linux-row-wrong-kind : x64.CompilerX64ExecutableTemplate
          (catalog.compiler-x64-template-registry-row
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))]
        (begin
          (test.assert-true
            (catalog.compiler-x64-template-row-valid-for?
              linux-row
              (x64.CompilerX64TemplateTarget.LinuxX64)
              (x64.CompilerX64TemplateRenderKind.Assembly))
            "matching target and render kind admit the row")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-row-valid-for?
                linux-row-wrong-target
                (x64.CompilerX64TemplateTarget.WindowsX64)
                (x64.CompilerX64TemplateRenderKind.Assembly)))
            "target mismatch fails closed")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-row-valid-for?
                linux-row-wrong-kind
                (x64.CompilerX64TemplateTarget.LinuxX64)
                (x64.CompilerX64TemplateRenderKind.OpaqueBytes)))
            "data/code render confusion fails closed")))
      (let
        [missing-anchor : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.LinuxX64)
            ""
            "C:main\nR")]
        [wrong-abi : x64.CompilerX64ExecutableTemplate
          (compiler-x64-template-test-custom-row
            (x64.CompilerX64TemplateTarget.WindowsX64)
            "entry"
            "C:main\nR")]
        [duplicates : x64.CompilerX64ExecutableTemplateIdList
          (x64.CompilerX64ExecutableTemplateIdList
            (__tl_make-array x64.CompilerX64ExecutableTemplateId 2)
            2)]
        (begin
          (set!
            (array-ref duplicates.slots 0)
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))
          (set!
            (array-ref duplicates.slots 1)
            (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))
          (test.assert-true
            (not
              (catalog.compiler-x64-template-row-valid-for?
                missing-anchor
                (x64.CompilerX64TemplateTarget.LinuxX64)
                (x64.CompilerX64TemplateRenderKind.StructuredObject)))
            "unmatched contribution anchors fail closed")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-row-valid-for?
                wrong-abi
                (x64.CompilerX64TemplateTarget.WindowsX64)
                (x64.CompilerX64TemplateRenderKind.StructuredObject)))
            "target and ABI must agree")
          (test.assert-true
            (not
              (catalog.compiler-x64-template-selection-unique? (& duplicates)))
            "duplicate selected template ids fail closed")))
      (let
        [unknown : x64.CompilerX64TemplateEventSeq
          (x64.compiler-x64-template-events "Q:context-restore")]
        [unsupported-empty : x64.CompilerX64TemplateEventSeq
          (x64.compiler-x64-template-events "O")]
        [unsupported-named : x64.CompilerX64TemplateEventSeq
          (x64.compiler-x64-template-events "O:RtlRestoreContext")]
        (begin
          (match (x64.compiler-x64-template-event-ref (& unknown) 0)
            [(x64.ResultCompilerX64TemplateEvent.Err _) unit]
            [_ (test.assert-true false "unknown event family must fail")])
          (match (x64.compiler-x64-template-event-ref (& unsupported-empty) 0)
            [(x64.ResultCompilerX64TemplateEvent.Err _) unit]
            [_
              (test.assert-true
                false
                "unsupported event requires exact provenance")])
          (match (x64.compiler-x64-template-event-ref (& unsupported-named) 0)
            [(x64.ResultCompilerX64TemplateEvent.Ok event)
              (test.assert-true
                (compiler-x64-template-test-kind-eq?
                  event.kind
                  (x64.CompilerX64TemplateEventKind.Unsupported))
                "named unsupported operation remains explicitly unknown")]
            [_ (test.assert-true false "named unsupported event must parse")])))
      42)))

(test
  compiler-x64-executable-template-registry
  (test.assert-i64-eq
    (compiler-x64-template-tests-main)
    42
    "x64 executable template registry self-test"))