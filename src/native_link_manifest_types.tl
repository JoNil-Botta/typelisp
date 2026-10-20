;# Native-link v1 semantic records, consumed next by #7367/#7368 and the
;# object/link pipeline. Operational paths and tools belong to Invocation only.
;# Adding a field or variant changes the wire schema and requires a version
;# decision, golden update, validation and a named consumer.
(defenum NativeTarget
  (LinuxX86_64)
  (WindowsX86_64))

(defenum NativeAbi
  (SysVAMD64)
  (WindowsAMD64))

(defenum NativeOutputKind
  (Relocatable)
  (FreestandingStaticExecutable)
  (StaticExecutable)
  (StaticPieExecutable)
  (PieExecutable)
  (StaticArchive)
  (ElfSharedObject)
  (PeDll)
  (MicrosoftImportLibrary))

(defenum NativeFileKind
  (ObjectFile)
  (StaticArchiveFile)
  (SharedObjectFile)
  (ImportLibraryFile)
  (LinkerScriptFile)
  (DefinitionFile)
  (VersionMapFile)
  (ResourceFile)
  (DebugFile)
  (PackageManifestFile)
  (RuntimeFile))

(defstruct ContentIdentity
  (algorithm-version u32)
  (sha256 (Array u8 32)))

(defenum ExpectedContent
  (UnspecifiedContent)
  (ExactContent ContentIdentity))

(defstruct NativePathRef
  (root-id String)
  (relative String)
  (kind NativeFileKind)
  (content ExpectedContent))

(defstruct LogicalRoot
  (id String)
  (identity ExpectedContent))

(defstruct ProfileIdentity
  (id String)
  (version u32)
  (content ContentIdentity))

(defstruct SourceSpan
  (start u64)
  (length u64))

(defenum NativeLinkProvenance
  (CommandLineOrigin u64)
  (SourceOrigin String String SourceSpan)
  (PackageOrigin NativePathRef String String u64)
  (DependencyOrigin String String NativePathRef String u64)
  (ArtifactOrigin String String u64)
  (ObjectDirectiveOrigin NativePathRef u64)
  (ProfileRowOrigin String String u64)
  (CompilerRuntimeOrigin String u64))

(defenum InputPosition
  (StartupInput)
  (EndInput)
  (DefaultInput)
  (RuntimeInput))

(defenum LibraryPreference
  (PreferStatic)
  (PreferDynamic))

(defenum RetentionKind
  (RetainSymbol)
  (RetainSection))

(defenum DefaultLibraryAction
  (InsertDefaultLibrary)
  (SuppressDefaultLibrary)
  (SuppressAllDefaultLibraries))

(defstruct NativeSectionAttributes
  (read bool)
  (write bool)
  (execute bool)
  (shared bool)
  (discardable bool))

(defenum NativeDirective
  (IncludeDirective String)
  (AliasDirective String String)
  (AlternateNameDirective String String)
  (MergeSectionDirective String String)
  (SectionAttributesDirective String NativeSectionAttributes))

(defenum ExportVisibility
  (ExportDefault)
  (ExportHidden)
  (ExportProtected))

(defstruct NativeExport
  (name String)
  (alias String)
  (ordinal u32)
  (data bool)
  (visibility ExportVisibility))

(defstruct ExternalCompatibilityArg
  (argv-element String))

(defenum EntryPolicy
  (NoEntry)
  (CompilerEntry String)
  (RuntimeEntry String)
  (NamedEntry String))

(defenum StartupPolicy
  (NoStartup)
  (CompilerStartup String)
  (ProfileStartup)
  (CrtStartup String))

(defenum UnresolvedPolicy
  (RejectUnresolved)
  (AllowSharedUnresolved)
  (AllowAllUnresolved))

(defenum SectionGcPolicy
  (KeepAllSections)
  (CollectUnusedSections))

(defenum ExportPolicy
  (ExplicitExports)
  (ExportAllGlobals)
  (ExportDynamicGlobals))

(defenum InterpreterPolicy
  (NoInterpreter)
  (ProfileInterpreter)
  (ExplicitInterpreter NativePathRef))

(defenum WindowsSubsystem
  (NoWindowsSubsystem)
  (ConsoleSubsystem)
  (GuiSubsystem)
  (NativeSubsystem))

(defstruct WindowsImagePolicy
  (subsystem WindowsSubsystem)
  (image-base u64)
  (section-alignment u64)
  (file-alignment u64)
  (stack-reserve u64)
  (stack-commit u64)
  (heap-reserve u64)
  (heap-commit u64))

(defenum DebugForm
  (NoDebug)
  (DwarfDebug)
  (CodeViewDebug))

(defenum BuildIdPolicy
  (NoBuildId)
  (ContentBuildId)
  (ExplicitBuildId String))

(defenum PdbPolicy
  (NoPdb)
  (LogicalPdb NativePathRef))

(defstruct DebugPolicy
  (form DebugForm)
  (build-id BuildIdPolicy)
  (pdb PdbPolicy)
  (deterministic bool))

(defenum HardeningFeature
  (PositionIndependent)
  (AddressRandomization)
  (NoExecute)
  (NonExecutableStack)
  (Relro)
  (ControlFlowGuard)
  (Cet)
  (EhContinuation)
  (StackProtector))

(defenum HardeningRequirement
  (Required)
  (Off)
  (Forbidden))

(defstruct HardeningRow
  (feature HardeningFeature)
  (requirement HardeningRequirement)
  (schema-id String)
  (helper-id String))

(defenum NativeControl
  (EntryControl EntryPolicy)
  (StartupControl StartupPolicy)
  (UnresolvedControl UnresolvedPolicy)
  (SectionGcControl SectionGcPolicy)
  (ExportsControl ExportPolicy)
  (SonameControl String)
  (InterpreterControl InterpreterPolicy)
  (RpathControl NativePathRef)
  (RunpathControl NativePathRef)
  (WindowsImageControl WindowsImagePolicy)
  (DebugControl DebugPolicy)
  (HardeningControl HardeningRow))

(defenum NativeEventPayload
  (FileInput NativePathRef)
  (LibraryLookup String)
  (SearchRoot String)
  (BeginGroup u64)
  (EndGroup u64)
  (BeginWholeArchive u64)
  (EndWholeArchive u64)
  (BeginPreference u64 LibraryPreference)
  (EndPreference u64)
  (ForcedUndefined String)
  (RetainedRoot RetentionKind String)
  (DefaultLibrary DefaultLibraryAction String)
  (ProfileFileInput InputPosition NativePathRef)
  (RuntimeRoot String)
  (Directive NativeDirective)
  (Export NativeExport)
  (DefinitionInput NativePathRef)
  (VersionMapInput NativePathRef)
  (ResourceInput NativePathRef)
  (SystemImportRequest SystemImport)
  (ExternalArgument ExternalCompatibilityArg)
  (Control NativeControl))

(defstruct NativeLinkEvent
  (ordinal u64)
  (id String)
  (provenance NativeLinkProvenance)
  (payload NativeEventPayload))

(defenum ReproducibilityPolicy
  (HermeticInputs)
  (ExplicitExternalCompatibility))

(defstruct NativeLinkManifest
  (schema-version u32)
  (extension-version u32)
  (target NativeTarget)
  (target-triple String)
  (abi NativeAbi)
  (output NativeOutputKind)
  (artifact-id String)
  (profile ProfileIdentity)
  (reproducibility ReproducibilityPolicy)
  (roots (__tl_dyn-array LogicalRoot))
  (events (__tl_dyn-array NativeLinkEvent)))

(defenum RuntimeFamily
  (CompilerFreestanding)
  (GlibcRuntime)
  (MuslRuntime)
  (MsvcRuntime)
  (UcrtRuntime))

(defstruct RuntimeVersion
  (major u32)
  (minor u32)
  (patch u32))

(defenum CapabilityKind
  (ObjectInputs)
  (ArchiveInputs)
  (SharedInputs)
  (ImportLibraryInputs)
  (LibrarySearch)
  (Groups)
  (WholeArchive)
  (StaticDynamicPreference)
  (DefaultLibraries)
  (Directives)
  (Exports)
  (DefinitionFiles)
  (VersionMaps)
  (Resources)
  (Tls)
  (Ifunc)
  (Constructors)
  (Unwind)
  (Dwarf)
  (CodeView)
  (Relocations)
  (DelayLoad)
  (ExternalArguments)
  (RuntimeHelpers)
  (SystemImports)
  (OutputRelocatable)
  (OutputFreestandingStatic)
  (OutputStatic)
  (OutputStaticPie)
  (OutputPie)
  (OutputArchive)
  (OutputElfDso)
  (OutputPeDll)
  (OutputImportLibrary))

(defenum CapabilityReason
  (Implemented)
  (CompilerFreestandingOnly)
  (TargetMismatch)
  (RequiresSealedRuntime)
  (RequiresTargetConsumer)
  (NotImplemented)
  (ExternalAdapterOnly)
  (UnsupportedHardening))

(defenum CapabilitySupport
  (Supported CapabilityReason)
  (Unsupported CapabilityReason))

(defstruct CapabilityRow
  (kind CapabilityKind)
  (support CapabilitySupport)
  (schema-id String)
  (helper-id String))

(defstruct ProfileFile
  (id String)
  (path NativePathRef))

(defstruct ProfileInput
  (position InputPosition)
  (file-id String)
  (provenance NativeLinkProvenance))

(defstruct SystemImport
  (symbol String)
  (dll String))

(defstruct NativeToolchainProfile
  (schema-version u32)
  (extension-version u32)
  (id String)
  (version u32)
  (target NativeTarget)
  (target-triple String)
  (abi NativeAbi)
  (runtime RuntimeFamily)
  (runtime-floor RuntimeVersion)
  (outputs (__tl_dyn-array NativeOutputKind))
  (roots (__tl_dyn-array LogicalRoot))
  (files (__tl_dyn-array ProfileFile))
  (inputs (__tl_dyn-array ProfileInput))
  (runtime-identities (__tl_dyn-array String))
  (entry EntryPolicy)
  (startup StartupPolicy)
  (windows WindowsImagePolicy)
  (interpreter InterpreterPolicy)
  (imports (__tl_dyn-array SystemImport))
  (debug DebugPolicy)
  (capabilities (__tl_dyn-array CapabilityRow))
  (hardening (__tl_dyn-array HardeningRow)))

(defstruct NativeLinkSemanticInput
  (manifest NativeLinkManifest)
  (profile NativeToolchainProfile))

(defstruct NativeRootBinding
  (root-id String)
  (host-path String))

(defstruct NativeLinkInvocation
  (roots (__tl_dyn-array NativeRootBinding))
  (output-host-path String)
  (tool-host-path String)
  (worker-count u32))

(defstruct PresentationOptions
  (show-content-identities bool))