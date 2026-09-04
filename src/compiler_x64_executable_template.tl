;; compiler_x64_executable_template.tl - Closed handwritten x86-64 template evidence.
;;
;; The registry records compiler-owned executable templates before final object
;; ranges and frame generations exist.  It deliberately exposes evidence, not
;; a compatibility Boolean: later policy must classify every typed event and
;; bind this identity to final range/frame facts.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defenum CompilerX64ExecutableTemplateId
  (CommonProfile)
  (CommonStartupProfile)
  (LinuxRuntimeMemcpy)
  (LinuxRuntimeMemchr)
  (LinuxRuntimeMemFill8)
  (LinuxRuntimeArrayZero)
  (LinuxRuntimeTlciImage)
  (LinuxRuntimeTlciMacro)
  (LinuxRuntimeBacktrace)
  (LinuxRuntimeArena)
  (LinuxRuntimeArenaDebug)
  (LinuxRuntimeArenaProfile)
  (LinuxRuntimeArenaProfileDebug)
  (LinuxRuntimeAlloc)
  (LinuxRuntimeAllocDebug)
  (LinuxRuntimeAllocProfile)
  (LinuxRuntimeAllocProfileDebug)
  (LinuxRuntimeRegionMark)
  (LinuxRuntimeRegionReset)
  (LinuxRuntimeRegionResetDebug)
  (LinuxRuntimeRegionResetProfile)
  (LinuxRuntimeRegionResetProfileDebug)
  (WindowsRuntimeMemcpy)
  (WindowsRuntimeMemchr)
  (WindowsRuntimeMemFill8)
  (WindowsRuntimeArrayZero)
  (WindowsRuntimeTlciImage)
  (WindowsRuntimeTlciMacro)
  (WindowsRuntimeBacktrace)
  (WindowsRuntimeArena)
  (WindowsRuntimeArenaDebug)
  (WindowsRuntimeArenaProfile)
  (WindowsRuntimeArenaProfileDebug)
  (WindowsRuntimeAlloc)
  (WindowsRuntimeAllocDebug)
  (WindowsRuntimeAllocProfile)
  (WindowsRuntimeAllocProfileDebug)
  (WindowsRuntimeRegionMark)
  (WindowsRuntimeRegionReset)
  (WindowsRuntimeRegionResetDebug)
  (WindowsRuntimeRegionResetProfile)
  (WindowsRuntimeRegionResetProfileDebug)
  (WindowsRuntimeThread)
  (WindowsRuntimeLibcShim)
  (WindowsRuntimeLibcShimStartupProfile)
  (LinuxStartupPrefix)
  (LinuxStartupPrefixStartupProfile)
  (LinuxStartupTail)
  (LinuxStartupTailBacktrace)
  (LinuxObjectTlciImageBytes)
  (LinuxObjectTlciMacroBytes)
  (LinuxObjectExitBytes)
  (WindowsObjectChkstkBytes)
  (WindowsObjectSetupPreGetcmdBytes)
  (WindowsObjectSetupAfterGetcmdBytes)
  (WindowsObjectSetupAfterBoot1Bytes)
  (WindowsObjectSetupAfterBoot2Bytes)
  (WindowsObjectSetupEpilogueBytes)
  (WindowsObjectAddRdxRaxBytes)
  (WindowsObjectRetBytes)
  (WindowsObjectTlciImageBytes)
  (WindowsObjectTlciMacroBytes)
  (WindowsObjectEntryGsClearBytes)
  (WindowsObjectConvertFiberArgsBytes)
  (WindowsObjectCreateFiberArgsBytes)
  (WindowsObjectCreateFiberTailBytes)
  (WindowsObjectStackGuaranteeArgsBytes)
  (WindowsObjectStderrHandleArgsBytes)
  (WindowsObjectWriteFailureTailBytes)
  (WindowsObjectWriteOverflowTailBytes)
  (WindowsObjectExit134ArgsBytes)
  (WindowsObjectOverflowFilterTestBytes)
  (WindowsObjectOverflowFilterReturnBytes)
  (LinuxObjectTlciImageContribution)
  (LinuxObjectTlciMacroContribution)
  (LinuxObjectStartContribution)
  (WindowsObjectTlciImageContribution)
  (WindowsObjectTlciMacroContribution)
  (WindowsObjectRuntimeSupportContribution)
  (WindowsObjectStartContribution)
  (WindowsObjectMainFiberContribution)
  (WindowsObjectOverflowFilterContribution))

(defenum CompilerX64TemplateTarget
  (AnyX64)
  (LinuxX64)
  (WindowsX64))

(defenum CompilerX64TemplateAbi
  (InternalX64)
  (SystemV)
  (Win64))

(defenum CompilerX64TemplateFeature
  (Always)
  (Alloc)
  (RegionMark)
  (RegionReset)
  (Profile)
  (StartupProfile)
  (TlciMacroEntry)
  (Backtrace)
  (ArenaDebug)
  (ProfileArenaDebug)
  (AllocProfile)
  (AllocArenaDebug)
  (AllocProfileArenaDebug)
  (RegionResetProfile)
  (RegionResetArenaDebug)
  (RegionResetProfileArenaDebug)
  (NativeEntryStartupProfile)
  (NativeEntryBacktrace)
  (NativeEntry))

(defenum CompilerX64TemplateRenderKind
  (Assembly)
  (OpaqueBytes)
  (StructuredObject))

(defenum CompilerX64TemplateContributionKind
  (RuntimeFunctions)
  (Startup)
  (TlciBridge)
  (ExternalFiberCallback)
  (ExternalExceptionCallback)
  (ByteFragment)
  (MixedRuntimeBundle))

(defenum CompilerX64TemplateTerminalBehavior
  (FallsThrough)
  (Returns)
  (TailTransfers)
  (TerminatesProcess)
  (SuspendsOrTerminates)
  (ReturnsOrTerminates)
  (Mixed)
  (Unknown))

;; Event codes in the checked transcript are parsed into this closed family.
;; `Unsupported` is intentionally explicit and fail-closed for later proof.
(defenum CompilerX64TemplateEventKind
  (DirectCall)
  (IndirectCall)
  (HardwareReturn)
  (DirectTailJump)
  (IndirectTailJump)
  (LocalBranch)
  (StackAdjust)
  (StackRebase)
  ;; ABI consumers distinguish nonvolatile saves from scratch preservation by
  ;; the named register and target ABI carried by the row.
  (SaveRegister)
  (RestoreRegister)
  (IncomingStackRead)
  (IncomingStackWrite)
  (TerminalProcessTransfer)
  (ExternalContextSwitch)
  (ExternalCallbackEntry)
  (Unsupported))

(defstruct CompilerX64TemplateEvent
  (kind CompilerX64TemplateEventKind)
  (detail String))

(defenum ResultCompilerX64TemplateEvent
  (Ok CompilerX64TemplateEvent)
  (Err String))

;; Newline-delimited canonical event tokens.  The transcript is authored by
;; the registry; assembly/disassembly parsing is only a test-side drift census.
(defstruct CompilerX64TemplateEventSeq
  (transcript String)
  (count i64))

(defstruct CompilerX64ExecutableTemplate
  (id CompilerX64ExecutableTemplateId)
  (schema i64)
  (producer String)
  (target CompilerX64TemplateTarget)
  (abi CompilerX64TemplateAbi)
  (feature CompilerX64TemplateFeature)
  (render-kind CompilerX64TemplateRenderKind)
  (contribution-kind CompilerX64TemplateContributionKind)
  (entry-anchor String)
  ;; Ordered newline-delimited interior anchors; empty means none.
  (interior-anchors String)
  (end-anchor String)
  ;; Data-only unwind/metadata rows that describe this executable contribution.
  (related-data String)
  (terminal CompilerX64TemplateTerminalBehavior)
  (events CompilerX64TemplateEventSeq)
  ;; -1 marks a structured/dynamic contribution whose exact payload is supplied
  ;; to the semantic-identity encoder by its owning producer.
  (expected-rendered-size i64)
  (expected-rendered-hash i64))

(defstruct CompilerX64TemplateFeatures
  (alloc bool)
  (region-mark bool)
  (region-reset bool)
  (profile bool)
  (startup-profile bool)
  (tlci-macro-entry bool)
  (arena-debug bool)
  (backtrace bool))

(defstruct CompilerX64ExecutableTemplateIdList
  (slots (__tl_dyn-array CompilerX64ExecutableTemplateId))
  (len i64))

(define (compiler-x64-template-event-count-transcript [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [at : i64 0]
    [count : i64 0]
    (begin
      (while (< at n)
        (begin
          (when
            (or (= at 0) (= (string.string-ref text (- at 1)) '\n'))
            (set! count (+ count 1)))
          (set! at (+ at 1))))
      count)))

(define (compiler-x64-template-events [transcript : String]) : CompilerX64TemplateEventSeq
  (let
    [count : i64
      (if (= (string.string-length (& transcript)) 0)
        0
        (compiler-x64-template-event-count-transcript (& transcript)))]
    (CompilerX64TemplateEventSeq transcript count)))

(define (compiler-x64-template-event-kind-from-code [code : char]) : CompilerX64TemplateEventKind
  (cond
    [(= code 'C') (CompilerX64TemplateEventKind.DirectCall)]
    [(= code 'I') (CompilerX64TemplateEventKind.IndirectCall)]
    [(= code 'R') (CompilerX64TemplateEventKind.HardwareReturn)]
    [(= code 'T') (CompilerX64TemplateEventKind.DirectTailJump)]
    [(= code 'J') (CompilerX64TemplateEventKind.IndirectTailJump)]
    [(= code 'B') (CompilerX64TemplateEventKind.LocalBranch)]
    [(= code 'A') (CompilerX64TemplateEventKind.StackAdjust)]
    [(= code 'X') (CompilerX64TemplateEventKind.StackRebase)]
    [(= code 'S') (CompilerX64TemplateEventKind.SaveRegister)]
    [(= code 'U') (CompilerX64TemplateEventKind.RestoreRegister)]
    [(= code 'D') (CompilerX64TemplateEventKind.IncomingStackRead)]
    [(= code 'W') (CompilerX64TemplateEventKind.IncomingStackWrite)]
    [(= code 'P') (CompilerX64TemplateEventKind.TerminalProcessTransfer)]
    [(= code 'F') (CompilerX64TemplateEventKind.ExternalContextSwitch)]
    [(= code 'E') (CompilerX64TemplateEventKind.ExternalCallbackEntry)]
    [else (CompilerX64TemplateEventKind.Unsupported)]))

(define (compiler-x64-template-event-code-known? [code : char]) : bool
  (or
    (= code 'C')
    (= code 'I')
    (= code 'R')
    (= code 'T')
    (= code 'J')
    (= code 'B')
    (= code 'A')
    (= code 'X')
    (= code 'S')
    (= code 'U')
    (= code 'D')
    (= code 'W')
    (= code 'P')
    (= code 'F')
    (= code 'E')
    (= code 'O')))

(define (compiler-x64-template-event-ref
  [events : (& events CompilerX64TemplateEventSeq)]
  [index : i64]) : ResultCompilerX64TemplateEvent
  (if (or (< index 0) (>= index events.count))
    (ResultCompilerX64TemplateEvent.Err
      "x64 executable template: event index out of bounds")
    (let
      [text : String events.transcript]
      [n : i64 (string.string-length text)]
      [at : i64 0]
      [row : i64 0]
      [start : i64 0]
      [done : bool false]
      (begin
        (while (and (not done) (< at n))
          (if (= (string.string-ref text at) '\n')
            (if (= row index)
              (set! done true)
              (begin
                (set! row (+ row 1))
                (set! start (+ at 1))
                (set! at (+ at 1))))
            (set! at (+ at 1))))
        (let
          [end : i64
            (if done
              at
              n)]
          [code : char (string.string-ref text start)]
          [detail-start : i64
            (if (and
              (< (+ start 1) end)
              (= (string.string-ref text (+ start 1)) ':'))
              (+ start 2)
              end)]
          [detail : String
            (string.substring text detail-start (- end detail-start))]
          (if (not (compiler-x64-template-event-code-known? code))
            (ResultCompilerX64TemplateEvent.Err
              "x64 executable template: unknown event family")
            (if (and (= code 'O') (= (string.string-length detail) 0))
              (ResultCompilerX64TemplateEvent.Err
                "x64 executable template: unsupported event needs provenance")
              (ResultCompilerX64TemplateEvent.Ok
                (CompilerX64TemplateEvent
                  (compiler-x64-template-event-kind-from-code code)
                  detail)))))))))

(define (compiler-x64-template-target-name [target : CompilerX64TemplateTarget]) : String
  (match target
    [(CompilerX64TemplateTarget.AnyX64) "any-x86_64"]
    [(CompilerX64TemplateTarget.LinuxX64) "linux-x86_64"]
    [(CompilerX64TemplateTarget.WindowsX64) "windows-x86_64"]))

(define (compiler-x64-template-target-matches?
  [expected : CompilerX64TemplateTarget]
  [actual : CompilerX64TemplateTarget]) : bool
  (match expected
    [(CompilerX64TemplateTarget.AnyX64) true]
    [(CompilerX64TemplateTarget.LinuxX64)
      (match actual
        [(CompilerX64TemplateTarget.LinuxX64) true]
        [_ false])]
    [(CompilerX64TemplateTarget.WindowsX64)
      (match actual
        [(CompilerX64TemplateTarget.WindowsX64) true]
        [_ false])]))

(define (compiler-x64-template-abi-name [abi : CompilerX64TemplateAbi]) : String
  (match abi
    [(CompilerX64TemplateAbi.InternalX64) "internal-x86_64"]
    [(CompilerX64TemplateAbi.SystemV) "sysv-x86_64"]
    [(CompilerX64TemplateAbi.Win64) "win64"]))

(define (compiler-x64-template-feature-name
  [feature : CompilerX64TemplateFeature]) : String
  (match feature
    [(CompilerX64TemplateFeature.Always) "always"]
    [(CompilerX64TemplateFeature.Alloc) "alloc"]
    [(CompilerX64TemplateFeature.RegionMark) "region-mark"]
    [(CompilerX64TemplateFeature.RegionReset) "region-reset"]
    [(CompilerX64TemplateFeature.Profile) "profile"]
    [(CompilerX64TemplateFeature.StartupProfile) "startup-profile"]
    [(CompilerX64TemplateFeature.TlciMacroEntry) "tlci-macro-entry"]
    [(CompilerX64TemplateFeature.Backtrace) "backtrace"]
    [(CompilerX64TemplateFeature.ArenaDebug) "arena-debug"]
    [(CompilerX64TemplateFeature.ProfileArenaDebug) "profile+arena-debug"]
    [(CompilerX64TemplateFeature.AllocProfile) "alloc+profile"]
    [(CompilerX64TemplateFeature.AllocArenaDebug) "alloc+arena-debug"]
    [(CompilerX64TemplateFeature.AllocProfileArenaDebug)
      "alloc+profile+arena-debug"]
    [(CompilerX64TemplateFeature.RegionResetProfile) "region-reset+profile"]
    [(CompilerX64TemplateFeature.RegionResetArenaDebug)
      "region-reset+arena-debug"]
    [(CompilerX64TemplateFeature.RegionResetProfileArenaDebug)
      "region-reset+profile+arena-debug"]
    [(CompilerX64TemplateFeature.NativeEntryStartupProfile)
      "native-entry+startup-profile"]
    [(CompilerX64TemplateFeature.NativeEntryBacktrace) "native-entry+backtrace"]
    [(CompilerX64TemplateFeature.NativeEntry) "native-entry"]))

(define (compiler-x64-template-render-kind-name
  [kind : CompilerX64TemplateRenderKind]) : String
  (match kind
    [(CompilerX64TemplateRenderKind.Assembly) "assembly"]
    [(CompilerX64TemplateRenderKind.OpaqueBytes) "opaque-bytes"]
    [(CompilerX64TemplateRenderKind.StructuredObject) "structured-object"]))

(define (compiler-x64-template-contribution-kind-name
  [kind : CompilerX64TemplateContributionKind]) : String
  (match kind
    [(CompilerX64TemplateContributionKind.RuntimeFunctions) "runtime-functions"]
    [(CompilerX64TemplateContributionKind.Startup) "startup"]
    [(CompilerX64TemplateContributionKind.TlciBridge) "tlci-bridge"]
    [(CompilerX64TemplateContributionKind.ExternalFiberCallback)
      "external-fiber-callback"]
    [(CompilerX64TemplateContributionKind.ExternalExceptionCallback)
      "external-exception-callback"]
    [(CompilerX64TemplateContributionKind.ByteFragment) "byte-fragment"]
    [(CompilerX64TemplateContributionKind.MixedRuntimeBundle)
      "mixed-runtime-bundle"]))

(define (compiler-x64-template-terminal-name
  [terminal : CompilerX64TemplateTerminalBehavior]) : String
  (match terminal
    [(CompilerX64TemplateTerminalBehavior.FallsThrough) "falls-through"]
    [(CompilerX64TemplateTerminalBehavior.Returns) "returns"]
    [(CompilerX64TemplateTerminalBehavior.TailTransfers) "tail-transfers"]
    [(CompilerX64TemplateTerminalBehavior.TerminatesProcess)
      "terminates-process"]
    [(CompilerX64TemplateTerminalBehavior.SuspendsOrTerminates)
      "suspends-or-terminates"]
    [(CompilerX64TemplateTerminalBehavior.ReturnsOrTerminates)
      "returns-or-terminates"]
    [(CompilerX64TemplateTerminalBehavior.Mixed) "mixed"]
    [(CompilerX64TemplateTerminalBehavior.Unknown) "unknown"]))

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
  [template : CompilerX64ExecutableTemplate]
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
        (compiler-x64-template-field template.events.transcript)
        (compiler-x64-template-field (& rendered-executable))))))

(define (compiler-x64-template-id-list-ref
  [ids : (& ids CompilerX64ExecutableTemplateIdList)]
  [index : i64]) : CompilerX64ExecutableTemplateId
  (owned_view.compiler-owned-array-element-shared-view ids.slots index))