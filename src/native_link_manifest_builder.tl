;# Builders preserve one provenance record per event, including duplicates.
;# Dependency requirements retain declaration order inside a single Linux
;# group. They do not import, parse or migrate legacy producer inputs.
(import native_link_manifest_types as n)
(import native_link_manifest_codec as codec)
(import native_link_manifest_core as core)
(import native_link_manifest_budget as budget)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.str_cat)

(defstruct NativeEventBuilder
  (slots (__tl_dyn-array n.NativeLinkEvent))
  (count i64)
  (ok bool)
  (error String))

(defenum NativeBuildResult
  (BuiltManifest n.NativeLinkManifest)
  (BuildRejected String))

(define (event-builder [capacity : i64]) : NativeEventBuilder
  (let
    [valid : bool (and (>= capacity 0) (<= capacity 65536))]
    (NativeEventBuilder
      (__tl_make-array
        n.NativeLinkEvent
        (if valid
          capacity
          0))
      0
      valid
      (if valid
        ""
        "builder capacity must be between zero and 65536"))))

(define (append!
  [builder : (&mut b NativeEventBuilder)]
  [origin : n.NativeLinkProvenance]
  [payload : n.NativeEventPayload]) : unit
  (when (not builder.ok) (return unit))
  (when
    (or (< builder.count 0) (>= builder.count (array-length builder.slots)))
    (set! builder.ok false)
    (set! builder.error "event builder capacity exceeded")
    (return unit))
  (let
    [ordinal : i64 builder.count]
    (set!
      (array-ref builder.slots ordinal)
      (n.NativeLinkEvent
        (cast ordinal : u64)
        (str_cat.str-cat "e" (string.int->string ordinal))
        origin
        payload))
    (set! builder.count (+ ordinal 1))
    unit))

;: Add every explicit control required by v1; callers choose the output before
;: generating controls. This introduces no hidden defaults in later consumers.
(define (append-profile-controls!
  [builder : (&mut b NativeEventBuilder)]
  [profile : (& p n.NativeToolchainProfile)]
  [output : (& o n.NativeOutputKind)]) : unit
  (let
    [executable : bool
      (match output
        [(or (n.FreestandingStaticExecutable) (n.StaticExecutable)
             (n.StaticPieExecutable) (n.PieExecutable))
          true]
        [_ false])]
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "entry" (cast 0 : u64))
      (n.Control
        (n.EntryControl
          (if executable
            (clone profile.entry)
            (n.NoEntry)))))
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "startup" (cast 0 : u64))
      (n.Control
        (n.StartupControl
          (if executable
            (clone profile.startup)
            (n.NoStartup)))))
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "unresolved" (cast 0 : u64))
      (n.Control (n.UnresolvedControl (n.RejectUnresolved))))
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "section-gc" (cast 0 : u64))
      (n.Control (n.SectionGcControl (n.KeepAllSections))))
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "exports" (cast 0 : u64))
      (n.Control (n.ExportsControl (n.ExplicitExports))))
    (append!
      builder
      (n.ProfileRowOrigin (clone profile.id) "debug" (cast 0 : u64))
      (n.Control (n.DebugControl (clone profile.debug))))
    (if (match profile.target
      [(n.WindowsX86_64) true]
      [_ false])
      (append!
        builder
        (n.ProfileRowOrigin (clone profile.id) "windows-image" (cast 0 : u64))
        (n.Control (n.WindowsImageControl (clone profile.windows))))
      (append!
        builder
        (n.ProfileRowOrigin (clone profile.id) "interpreter" (cast 0 : u64))
        (n.Control
          (n.InterpreterControl
            (if executable
              (clone profile.interpreter)
              (n.NoInterpreter))))))
    (for [i (iterator.range 0 (array-length (& profile.hardening)))]
      (append!
        builder
        (n.ProfileRowOrigin (clone profile.id) "hardening" (cast i : u64))
        (n.Control (n.HardeningControl (clone (array-ref profile.hardening i)))))
      unit)))

;: Finish binds the exact canonical profile digest. Semantic admission remains
;: explicit through core.validate, so unsupported requests retain diagnostics.
(define (finish
  [builder : NativeEventBuilder]
  [profile : (& p n.NativeToolchainProfile)]
  [output : n.NativeOutputKind]
  [artifact : String]
  [roots : (__tl_dyn-array n.LogicalRoot)]
  [reproducibility : n.ReproducibilityPolicy]
  [limits : (& l core.NativeLinkLimits)]) : NativeBuildResult
  (when
    (not (core.valid-limits? limits))
    (return (BuildRejected "invalid builder limits")))
  (when (not builder.ok) (return (BuildRejected (clone builder.error))))
  (when
    (or (< builder.count 0) (> builder.count (array-length builder.slots)))
    (return (BuildRejected "event builder count is outside its backing array")))
  (when
    (> builder.count limits.max-events)
    (return (BuildRejected "event count limit exceeded")))
  (let
    [check : budget.Budget (budget.new (& limits.wire))]
    [i : i64 0]
    (budget.observe n.NativeToolchainProfile profile (&mut check))
    (budget.observe (__tl_dyn-array n.LogicalRoot) (& roots) (&mut check))
    (while (and check.ok (< i builder.count))
      (budget.observe
        n.NativeLinkEvent
        (& (array-ref builder.slots i))
        (&mut check))
      (set! i (+ i 1)))
    (when
      (not check.ok)
      (return
        (BuildRejected
          "live builder data exceeds the typed work/retained budget"))))
  (match (codec.profile-identity profile (& limits.wire))
    [(codec.NativeDigest identity)
      (let
        [events : (__tl_dyn-array n.NativeLinkEvent)
          (__tl_make-array n.NativeLinkEvent builder.count)]
        (for [i (iterator.range 0 builder.count)]
          (set! (array-ref events i) (clone (array-ref builder.slots i))))
        (BuiltManifest
          (n.NativeLinkManifest
            (cast 1 : u32)
            (cast 0 : u32)
            (clone profile.target)
            (clone profile.target-triple)
            (clone profile.abi)
            output
            artifact
            (n.ProfileIdentity (clone profile.id) profile.version identity)
            reproducibility
            roots
            events)))]
    [_ (BuildRejected "profile canonical encoding exceeds explicit limits")]))

(defenum NativeRequirementValue
  (RequirementLibrary String)
  (RequirementSearchRoot String)
  (RequirementExternalArgument n.ExternalCompatibilityArg)
  (RequirementArchive n.NativePathRef))

(defstruct NativeDependencyRequirement
  (from-package String)
  (declaring-package String)
  (manifest n.NativePathRef)
  (field String)
  (declaration-index u64)
  (value NativeRequirementValue))

(define (append-dependency-requirements!
  [builder : (&mut b NativeEventBuilder)]
  [target : n.NativeTarget]
  [requirements : (& r (__tl_dyn-array NativeDependencyRequirement))]
  [group-id : u64]
  [group-origin : n.NativeLinkProvenance]
  [limits : (& l core.NativeLinkLimits)]) : unit
  (when (not builder.ok) (return unit))
  (when
    (not (core.valid-limits? limits))
    (set! builder.ok false)
    (set! builder.error "invalid dependency builder limits")
    (return unit))
  (when
    (or (< builder.count 0) (> builder.count (array-length builder.slots)))
    (set! builder.ok false)
    (set! builder.error "event builder count is outside its backing array")
    (return unit))
  (let
    [count : i64 (array-length requirements)]
    [linux : bool
      (match target
        [(n.LinuxX86_64) true]
        [_ false])]
    [extra : i64
      (if linux
        2
        0)]
    [remaining : i64 (- (array-length builder.slots) builder.count)]
    [allowed : i64 (- limits.max-events builder.count)]
    [i : i64 0]
    (when (= count 0) (return unit))
    (when
      (or
        (< remaining extra)
        (> count (- remaining extra))
        (< allowed extra)
        (> count (- allowed extra)))
      (set! builder.ok false)
      (set! builder.error "dependency section exceeds event capacity or limit")
      (return unit))
    (let
      [check : budget.Budget (budget.new (& limits.wire))]
      (budget.observe
        (__tl_dyn-array NativeDependencyRequirement)
        requirements
        (&mut check))
      (budget.observe n.NativeLinkProvenance (& group-origin) (&mut check))
      (when
        (not check.ok)
        (set! builder.ok false)
        (set!
          builder.error
          "dependency section exceeds typed work/retained budget")
        (return unit)))
    (when
      linux
      (append! builder (clone group-origin) (n.BeginGroup group-id))
      unit)
    (while (and builder.ok (< i count))
      (let
        [row : (& r NativeDependencyRequirement) (& (array-ref requirements i))]
        (match row.value
          [(RequirementArchive path)
            (when
              (not
                (match path.kind
                  [(n.StaticArchiveFile) true]
                  [_ false]))
              (set! builder.ok false)
              (set!
                builder.error
                "dependency archive requires StaticArchiveFile kind"))]
          [_ unit])
        (when (not builder.ok) (return unit))
        (append!
          builder
          (n.DependencyOrigin
            (clone row.from-package)
            (clone row.declaring-package)
            (clone row.manifest)
            (clone row.field)
            row.declaration-index)
          (match row.value
            [(RequirementLibrary name) (n.LibraryLookup (clone name))]
            [(RequirementSearchRoot root) (n.SearchRoot (clone root))]
            [(RequirementExternalArgument arg) (n.ExternalArgument (clone arg))]
            [(RequirementArchive path) (n.FileInput (clone path))])))
      (set! i (+ i 1)))
    (when linux (append! builder group-origin (n.EndGroup group-id)) unit)))

;: Artifact/export requirements use the same event stream and keep their
;: semantic identity even when a source or CLI event has identical payload.
(define (append-artifact!
  [builder : (&mut b NativeEventBuilder)]
  [artifact : String]
  [export : String]
  [index : u64]
  [payload : n.NativeEventPayload]) : unit
  (append! builder (n.ArtifactOrigin artifact export index) payload))