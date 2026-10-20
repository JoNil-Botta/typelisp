(import native_link_manifest_types as n)
(import native_link_manifest_core as core)
(import native_link_manifest_builder as builder)
(import native_link_manifest_profiles as profiles)
(import tests.native_link_manifest_test_support as support)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)
(import stdlib.byte_buf_core as buf)

(test
  native-link-builtin-target-output-matrix
  (test.assert-true
    (let
      [ok : bool true]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (for [target (iterator.range 0 2)]
        (let
          [profile : n.NativeToolchainProfile
            (profiles.freestanding-profile
              (if (= target 0)
                (n.LinuxX86_64)
                (n.WindowsX86_64)))]
          (for [i (iterator.range 0 3)]
            (let
              [events : builder.NativeEventBuilder (builder.event-builder 16)]
              [output : n.NativeOutputKind
                (clone (array-ref profile.outputs i))]
              (builder.append-profile-controls!
                (&mut events)
                (& profile)
                (& output))
              (match (builder.finish
                events
                (& profile)
                output
                "app"
                (__tl_make-array n.LogicalRoot 0)
                (n.HermeticInputs)
                (& limits))
                [(builder.BuiltManifest value)
                  (let
                    [input : n.NativeLinkSemanticInput
                      (n.NativeLinkSemanticInput value (clone profile))]
                    [checked : core.NativeLinkValidation
                      (core.validate (& input) (& limits))]
                    (when (not checked.ok) (set! ok false)))]
                [_ (set! ok false)])))))
      ok)
    "native-link-builtin-target-output-matrix"))

(test
  native-link-invalid-header-and-controls
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (set! input.manifest.schema-version (cast 99 : u32))
      (set! input.manifest.target-triple "x86_64-pc-windows-msvc")
      (set! input.manifest.output (n.PeDll))
      (set! (array-ref input.manifest.events 0).id "missing")
      (set! (array-ref input.manifest.events 1).ordinal (cast 90 : u64))
      (let
        [checked : core.NativeLinkValidation
          (core.validate (& input) (& limits))]
        (and
          (support.has-reason? (& checked) (core.InvalidVersion))
          (support.has-reason? (& checked) (core.InvalidTarget))
          (support.has-reason? (& checked) (core.InvalidOutput))
          (support.has-reason? (& checked) (core.InvalidEventIdentity)))))
    "native-link-invalid-header-and-controls"))

(test
  native-link-diagnostic-limit-retains-failure
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (set! limits.max-diagnostics 0)
      (set! input.manifest.schema-version (cast 99 : u32))
      (let
        [checked : core.NativeLinkValidation
          (core.validate (& input) (& limits))]
        (and (not checked.ok) (= checked.count 0) checked.truncated)))
    "native-link-diagnostic-limit-retains-failure"))

(test
  native-link-reserved-builtin-rejects-policy-tampering
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample true)]
      (set! input.profile.windows.stack-reserve (cast 134217728 : u64))
      (support.rebind-profile! (&mut input))
      (support.rejects? (& input)))
    "native-link-reserved-builtin-rejects-policy-tampering"))

(test
  native-link-profile-digest-is-required
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      (set!
        (array-ref input.manifest.profile.content.sha256 0)
        (bit-xor
          (array-ref input.manifest.profile.content.sha256 0)
          (cast 1 : u8)))
      (support.rejects? (& input)))
    "native-link-profile-digest-is-required"))

(test
  native-link-unknown-schema-and-helper-fail-closed
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (set!
        (array-ref input.profile.capabilities 0).schema-id
        "future.capabilities.v2")
      (set!
        (array-ref input.profile.capabilities 1).helper-id
        "unknown.runtime")
      (let
        [checked : core.NativeLinkValidation
          (core.validate (& input) (& limits))]
        (and
          (support.has-reason? (& checked) (core.InvalidVersion))
          (support.has-reason? (& checked) (core.MissingHelper)))))
    "native-link-unknown-schema-and-helper-fail-closed"))

(test
  native-link-ordered-opaque-argv-classification
  (test.assert-true
    (let
      [input : n.NativeLinkSemanticInput (support.sample false)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      [events : builder.NativeEventBuilder (builder.event-builder 17)]
      (builder.append-profile-controls!
        (&mut events)
        (& input.profile)
        (& input.manifest.output))
      (builder.append!
        (&mut events)
        (n.CommandLineOrigin (cast 3 : u64))
        (n.ExternalArgument
          (n.ExternalCompatibilityArg " @literal response ; $HOME -Wl,a,b ")))
      (match (builder.finish
        events
        (& input.profile)
        (clone input.manifest.output)
        "app"
        (__tl_make-array n.LogicalRoot 0)
        (n.ExplicitExternalCompatibility)
        (& limits))
        [(builder.BuiltManifest value)
          (set! input.manifest value)
          (let
            [internal : core.NativeCapabilityDecision
              (core.classify (& input) (core.InternalBackend) (& limits))]
            [external : core.NativeCapabilityDecision
              (core.classify (& input) (core.ExternalBackend) (& limits))]
            [automatic : core.NativeCapabilityDecision
              (core.classify (& input) (core.AutoBackend) (& limits))]
            (and
              (not internal.validation.ok)
              external.validation.ok
              external.opaque-external-closure
              external.requires-content-closure
              (not automatic.validation.ok)
              (support.has-reason? (& internal.validation) (core.ExternalOnly))
              (support.has-reason?
                (& automatic.validation)
                (core.AutoCannotPreserve))))]
        [_ false]))
    "native-link-ordered-opaque-argv-classification"))

(test
  native-link-normalized-logical-path-boundaries
  (test.assert-true
    (and
      (core.relative? "a/b.o")
      (core.relative? "unicode-\xc3\xa5.o")
      (not (core.relative? ""))
      (not (core.relative? "/a.o"))
      (not (core.relative? "C:/a.o"))
      (not (core.relative? "a\\b.o"))
      (not (core.relative? "../a.o"))
      (not (core.relative? "a/../b.o"))
      (not (core.relative? "a/./b.o"))
      (not (core.relative? "a//b.o"))
      (not (core.relative? "a/")))
    "native-link-normalized-logical-path-boundaries"))

(test
  native-link-builder-capacity-is-latched
  (test.assert-true
    (let
      [events : builder.NativeEventBuilder (builder.event-builder 1)]
      (builder.append!
        (&mut events)
        (n.CommandLineOrigin (cast 0 : u64))
        (n.ForcedUndefined "x"))
      (builder.append!
        (&mut events)
        (n.CommandLineOrigin (cast 1 : u64))
        (n.ForcedUndefined "x"))
      (and
        (not events.ok)
        (= events.count 1)
        (not (builder.event-builder -1).ok)
        (not (builder.event-builder 65537).ok)))
    "native-link-builder-capacity-is-latched"))

(test
  native-link-hardening-required-off-forbidden-matrix
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (for [windows (iterator.range 0 2)]
      (for [feature (iterator.range 0 9)]
        (for [requirement (iterator.range 0 3)]
          (let
            [input : n.NativeLinkSemanticInput (support.sample (= windows 1))]
            [row : n.HardeningRow
              (clone (array-ref input.profile.hardening feature))]
            (set!
              row.requirement
              (match requirement
                [0 (n.Off)]
                [1 (n.Forbidden)]
                [_ (n.Required)]))
            (when (= requirement 2) (set! row.helper-id "typelisp.runtime.v1"))
            (set!
              (array-ref input.manifest.events (+ feature 7)).payload
              (n.Control (n.HardeningControl row)))
            (let
              [checked : core.NativeLinkValidation
                (core.validate (& input) (& limits))]
              (test.assert-bool-eq
                checked.ok
                (!= requirement 2)
                "off/forbidden preserve absence; unsupported required policy rejects"))))))))

(test
  native-link-windows-import-rejection-retains-event
  (let
    [input : n.NativeLinkSemanticInput (support.sample true)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set!
      (array-ref input.manifest.events 0).payload
      (n.SystemImportRequest (n.SystemImport "socket" "ws2_32.dll")))
    (let
      [checked : core.NativeLinkValidation (core.validate (& input) (& limits))]
      [found : bool false]
      (for [i (iterator.range 0 checked.count)]
        (when
          (and
            (= (array-ref checked.diagnostics i).reason (core.InvalidImport))
            (= (array-ref checked.diagnostics i).event-ordinal 0))
          (set! found true)))
      (test.assert-true found "unknown function/DLL reports its original event"))))

(test
  native-link-independent-backend-reasons
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! input.manifest.schema-version (cast 2 : u32))
    (set! input.manifest.reproducibility (n.ExplicitExternalCompatibility))
    (set!
      (array-ref input.manifest.events 0).payload
      (n.ExternalArgument (n.ExternalCompatibilityArg "literal")))
    (let
      [decision : core.NativeCapabilityDecision
        (core.classify (& input) (core.InternalBackend) (& limits))]
      (test.assert-true
        (and
          (not decision.validation.ok)
          decision.validation.complete
          (support.has-reason? (& decision.validation) (core.InvalidVersion))
          (support.has-reason? (& decision.validation) (core.ExternalOnly)))
        "unrelated semantic error does not hide the external-only reason"))))

(test
  native-link-unselected-profile-input-rejects
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set!
      (array-ref input.manifest.events 0).payload
      (n.ProfileFileInput
        (n.StartupInput)
        (n.NativePathRef
          "unknown-root"
          "crt.o"
          (n.ObjectFile)
          (n.UnspecifiedContent))))
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (and
          (support.has-reason? (& validation) (core.UnknownRoot))
          (support.has-reason? (& validation) (core.ProfileMismatch)))
        "profile input must name the selected file and position"))))

(test
  native-link-nested-scope-order
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (for [crossing (iterator.range 0 2)]
      (let
        [input : n.NativeLinkSemanticInput (support.sample false)]
        [events : builder.NativeEventBuilder (builder.event-builder 20)]
        (builder.append-profile-controls!
          (&mut events)
          (& input.profile)
          (& input.manifest.output))
        (builder.append!
          (&mut events)
          (n.CommandLineOrigin (cast 0 : u64))
          (n.BeginGroup (cast 1 : u64)))
        (builder.append!
          (&mut events)
          (n.CommandLineOrigin (cast 1 : u64))
          (n.BeginWholeArchive (cast 2 : u64)))
        (builder.append!
          (&mut events)
          (n.CommandLineOrigin (cast 2 : u64))
          (if (= crossing 0)
            (n.EndWholeArchive (cast 2 : u64))
            (n.EndGroup (cast 1 : u64))))
        (builder.append!
          (&mut events)
          (n.CommandLineOrigin (cast 3 : u64))
          (if (= crossing 0)
            (n.EndGroup (cast 1 : u64))
            (n.EndWholeArchive (cast 2 : u64))))
        (match (builder.finish
          events
          (& input.profile)
          (clone input.manifest.output)
          "app"
          (__tl_make-array n.LogicalRoot 0)
          (n.HermeticInputs)
          (& limits))
          [(builder.BuiltManifest value)
            (set! input.manifest value)
            (let
              [validation : core.NativeLinkValidation
                (core.validate (& input) (& limits))]
              (test.assert-bool-eq
                validation.ok
                (= crossing 0)
                "proper nesting is accepted; crossing scopes reject"))]
          [_ (test.assert-true false "scope fixture builder capacity")])))))

(test
  native-link-generic-runtime-does-not-certify-hardening
  (let
    [input : n.NativeLinkSemanticInput (support.sealed-sample)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! (array-ref input.profile.hardening 6).requirement (n.Required))
    (set! (array-ref input.profile.hardening 6).helper-id "typelisp.runtime.v1")
    (set!
      (array-ref input.manifest.events 13).payload
      (n.Control
        (n.HardeningControl (clone (array-ref input.profile.hardening 6)))))
    (support.rebind-profile! (&mut input))
    (let
      [decision : core.NativeCapabilityDecision
        (core.classify (& input) (core.InternalBackend) (& limits))]
      (test.assert-true
        (and
          (not decision.validation.ok)
          (support.has-reason?
            (& decision.validation)
            (core.UnsupportedCapability)))
        "generic runtime availability is not a CET feature contract"))))

(test
  native-link-pe-field-width-and-subpage-boundaries
  (let
    [input : n.NativeLinkSemanticInput (support.sample true)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (for [i (iterator.range 0 3)]
      (let
        [image : n.WindowsImagePolicy (clone input.profile.windows)]
        [validation : core.NativeLinkValidation
          (core.new-validation (& limits))]
        (match i
          [0 (set! image.section-alignment (cast 4294967296 : u64))]
          [1 (set! image.section-alignment (cast 1024 : u64))]
          [_ (set! image.section-alignment (cast 512 : u64))])
        (core.windows! (&mut validation) (& image) 0)
        (test.assert-bool-eq
          validation.ok
          (= i 2)
          "u32 width and subpage equality are checked before PE layout")))))

(test
  native-link-off-hardening-does-not-admit-unknown-helper
  (let
    [input : n.NativeLinkSemanticInput (support.sample true)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [row : n.HardeningRow (clone (array-ref input.profile.hardening 0))]
    (set! row.helper-id "unknown.helper")
    (set!
      (array-ref input.manifest.events 7).payload
      (n.Control (n.HardeningControl row)))
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (support.has-reason? (& validation) (core.MissingHelper))
        "unknown helpers reject even when the requested policy is off"))))

(test
  native-link-argv-bound-stops-before-content-scan
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! input.manifest.reproducibility (n.ExplicitExternalCompatibility))
    (let
      [bytes : buf.ByteBufBuilder (buf.byte-buf-builder-with-capacity 3)]
      (buf.byte-buf-builder-push (&mut bytes) (cast 65 : u8))
      (buf.byte-buf-builder-push (&mut bytes) (cast 0 : u8))
      (buf.byte-buf-builder-push (&mut bytes) (cast 66 : u8))
      (set!
        (array-ref input.manifest.events 0).payload
        (n.ExternalArgument
          (n.ExternalCompatibilityArg
            (buf.byte-buf-builder-to-string (& bytes))))))
    (set! limits.max-argv-bytes 2)
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (and
          (not validation.complete)
          (support.has-reason? (& validation) (core.ResourceLimit)))
        "oversized argv stops content scanning")
      (test.assert-false
        (support.has-reason? (& validation) (core.InvalidName))
        "resource stop does not continue scanning the oversized payload"))
    (set! limits.max-argv-bytes 3)
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (support.has-reason? (& validation) (core.InvalidName))
        "NUL still rejects at the exact size limit"))))

(define (output [index : i64]) : n.NativeOutputKind
  (match index
    [0 (n.Relocatable)]
    [1 (n.FreestandingStaticExecutable)]
    [2 (n.StaticExecutable)]
    [3 (n.StaticPieExecutable)]
    [4 (n.PieExecutable)]
    [5 (n.StaticArchive)]
    [6 (n.ElfSharedObject)]
    [7 (n.PeDll)]
    [_ (n.MicrosoftImportLibrary)]))

(test
  native-link-every-output-kind-fails-closed
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (for [target (iterator.range 0 2)]
      (let
        [profile : n.NativeToolchainProfile
          (profiles.freestanding-profile
            (if (= target 0)
              (n.LinuxX86_64)
              (n.WindowsX86_64)))]
        (for [mode (iterator.range 0 9)]
          (let
            [kind : n.NativeOutputKind (output mode)]
            [events : builder.NativeEventBuilder (builder.event-builder 16)]
            (builder.append-profile-controls!
              (&mut events)
              (& profile)
              (& kind))
            (match (builder.finish
              events
              (& profile)
              kind
              "output.matrix"
              (__tl_make-array n.LogicalRoot 0)
              (n.HermeticInputs)
              (& limits))
              [(builder.BuiltManifest value)
                (let
                  [input : n.NativeLinkSemanticInput
                    (n.NativeLinkSemanticInput value (clone profile))]
                  [validation : core.NativeLinkValidation
                    (core.validate (& input) (& limits))]
                  (test.assert-bool-eq
                    validation.ok
                    (or (= mode 0) (= mode 1) (= mode 5))
                    "only the three declared freestanding output modes admit"))]
              [_ (test.assert-true false "output matrix builder")])))))))

(test
  native-link-every-capability-row-is-required
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (for [i (iterator.range 0 34)]
      (let
        [input : n.NativeLinkSemanticInput (support.sample false)]
        (set!
          (array-ref input.profile.capabilities i).kind
          (clone (array-ref input.profile.capabilities (% (+ i 1) 34)).kind))
        (let
          [validation : core.NativeLinkValidation
            (core.validate (& input) (& limits))]
          (test.assert-true
            (and
              (support.has-reason? (& validation) (core.DuplicateKey))
              (support.has-reason? (& validation) (core.MissingCapability)))
            "each closed capability needs one unique row"))))))

(test
  native-link-semantic-event-boundaries-and-diagnostic-order
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! limits.max-events 16)
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true validation.ok "exact event limit"))
    (set! limits.max-events 15)
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (support.has-reason? (& validation) (core.ResourceLimit))
        "one-below event limit"))
    (set! limits.max-events 16)
    (set! input.manifest.schema-version (cast 2 : u32))
    (set! input.manifest.target-triple "invalid.triple")
    (set! input.manifest.output (n.PeDll))
    (set! input.manifest.artifact-id "invalid identity")
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      (test.assert-true
        (>= validation.count 4)
        "independent header reasons retained")
      (test.assert-true
        (= (array-ref validation.diagnostics 0).reason (core.InvalidVersion))
        "version first")
      (test.assert-true
        (= (array-ref validation.diagnostics 1).reason (core.InvalidTarget))
        "target next")
      (test.assert-true
        (= (array-ref validation.diagnostics 2).reason (core.InvalidOutput))
        "output next")
      (test.assert-true
        (= (array-ref validation.diagnostics 3).reason (core.InvalidIdentity))
        "logical identity next"))))

(test
  native-link-profile-input-index-preserves-path-aliases
  (let
    [input : n.NativeLinkSemanticInput (support.sealed-sample)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [validation : core.NativeLinkValidation (core.new-validation (& limits))]
    (set!
      (array-ref input.profile.files 1).path
      (clone (array-ref input.profile.files 0).path))
    (let
      [indices : (__tl_dyn-array i64)
        (core.profile! (&mut validation) (& input.manifest) (& input.profile))]
      [position : n.InputPosition (n.EndInput)]
      [missing : n.InputPosition (n.DefaultInput)]
      (test.assert-true
        validation.ok
        "distinct declared file IDs may identify the same logical path")
      (test.assert-i64-eq (array-ref indices 0) 0 "startup file index")
      (test.assert-i64-eq
        (array-ref indices 1)
        1
        "end file retains its own declaration identity")
      (test.assert-true
        (core.selected-profile-input?
          (& input.profile)
          (& indices)
          (& position)
          (& (array-ref input.profile.files 0).path))
        "same path is selected at end through its declared alias")
      (test.assert-false
        (core.selected-profile-input?
          (& input.profile)
          (& indices)
          (& missing)
          (& (array-ref input.profile.files 0).path))
        "a missing insertion position cannot match"))))

(test
  native-link-glibc-cannot-use-musl-triple
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! input.profile.runtime (n.GlibcRuntime))
    (set! input.profile.target-triple "x86_64-unknown-linux-musl")
    (set! input.manifest.target-triple "x86_64-unknown-linux-musl")
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      [found : bool false]
      (for [i (iterator.range 0 validation.count)]
        (when
          (and
            (= (array-ref validation.diagnostics i).reason (core.InvalidTarget))
            (stdlib.string.eq
              (& (array-ref validation.diagnostics i).field)
              "profile.target-triple"))
          (set! found true)))
      (test.assert-true
        found
        "runtime family and target triple must agree in both directions"))))

(test
  native-link-profile-diagnostics-survive-independent-errors
  (let
    [input : n.NativeLinkSemanticInput (support.sample true)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (set! input.manifest.artifact-id "invalid identity")
    (set! input.profile.windows.stack-reserve (cast 134217728 : u64))
    (set! (array-ref input.manifest.events 0).id "invalid")
    (let
      [validation : core.NativeLinkValidation
        (core.validate (& input) (& limits))]
      [header : i64 -1]
      [binding : i64 -1]
      [builtin : i64 -1]
      [event : i64 -1]
      (for [i (iterator.range 0 validation.count)]
        (let
          [field (& (array-ref validation.diagnostics i).field)]
          (when (string.eq field "manifest.artifact-id") (set! header i))
          (when (string.eq field "manifest.profile.content") (set! binding i))
          (when (string.eq field "profile.builtin") (set! builtin i))
          (when (string.eq field "event.id") (set! event i))))
      (test.assert-true
        (and
          (not validation.ok)
          validation.complete
          (>= header 0)
          (> binding header)
          (> builtin binding)
          (> event builtin))
        "header, profile binding, reserved builtin and event errors are independently ordered"))))