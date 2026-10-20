;# Bounded, pure native-link semantic validation. Consumers must obtain an
;# accepted result before opening inputs or outputs. Diagnostics follow header,
;# profile row and original event order; exact duplicate events remain distinct.
(import native_link_manifest_types as n)
(import native_link_manifest_binary as binary)
(import native_link_manifest_budget as budget)
(import native_link_manifest_codec as codec)
(import native_link_manifest_profiles as profiles)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.str_cat)

(defstruct NativeLinkLimits
  (wire binary.Limits)
  (max-events i64)
  (max-nesting i64)
  (max-diagnostics i64)
  (max-argv-bytes i64))

(define (default-limits) : NativeLinkLimits
  (NativeLinkLimits (binary.default-limits) 16384 64 256 16384))

(defenum NativeLinkReason
  (InvalidLimit)
  (ResourceLimit)
  (InvalidVersion)
  (InvalidTarget)
  (InvalidOutput)
  (InvalidIdentity)
  (InvalidName)
  (InvalidPath)
  (UnknownRoot)
  (DuplicateKey)
  (InvalidEventIdentity)
  (InvalidScope)
  (MissingControl)
  (ConflictingControl)
  (InvalidControl)
  (ProfileMismatch)
  (MissingCapability)
  (UnsupportedCapability)
  (MissingHelper)
  (InvalidHardening)
  (InvalidRuntime)
  (InvalidImport)
  (ExternalOnly)
  (OpaqueDependencyClosure)
  (AutoCannotPreserve))

(defstruct NativeLinkDiagnostic
  (reason NativeLinkReason)
  (field String)
  (event-ordinal i64)
  (detail String))

(defstruct NativeLinkValidation
  (ok bool)
  (diagnostics (__tl_dyn-array NativeLinkDiagnostic))
  (count i64)
  (truncated bool)
  (complete bool))

(define (diagnose!
  [v : (&mut v NativeLinkValidation)]
  [reason : NativeLinkReason]
  [field : String]
  [event : i64]
  [detail : String]) : unit
  (set! v.ok false)
  (when
    (match reason
      [(or (InvalidLimit) (ResourceLimit)) true]
      [_ false])
    (set! v.complete false))
  (if (< v.count (array-length v.diagnostics))
    (begin
      (set!
        (array-ref v.diagnostics v.count)
        (NativeLinkDiagnostic reason field event detail))
      (set! v.count (+ v.count 1)))
    (set! v.truncated true)))

(define (valid-limits? [l : (& l NativeLinkLimits)]) : bool
  (and
    (binary.valid-limits? (& l.wire))
    (>= l.max-events 0)
    (>= l.max-nesting 0)
    (<= l.max-nesting 64)
    (>= l.max-diagnostics 0)
    (<= l.max-diagnostics 4096)
    (>= l.max-argv-bytes 0)))

(define (new-validation [l : (& l NativeLinkLimits)]) : NativeLinkValidation
  (let
    [valid : bool (valid-limits? l)]
    [v : NativeLinkValidation
      (NativeLinkValidation
        true
        (__tl_make-array
          NativeLinkDiagnostic
          (if valid
            l.max-diagnostics
            1))
        0
        false
        true)]
    (when
      (not valid)
      (diagnose!
        (&mut v)
        (InvalidLimit)
        "limits"
        -1
        "nonnegative bounded limits required"))
    v))

(define (name? [text : (& s str)]) : bool
  (let
    [length : i64 (string.string-length text)]
    (when (= length 0) (return false))
    (for [i (iterator.range 0 length)]
      (let
        [c : i64 (cast (string.string-ref text i) : i64)]
        (when (or (< c 32) (= c 127)) (return false))))
    true))

(define (id? [text : (& s str)]) : bool
  (when (not (name? text)) (return false))
  (for [i (iterator.range 0 (string.string-length text))]
    (let
      [c : i64 (cast (string.string-ref text i) : i64)]
      (when
        (not
          (or
            (and (>= c 48) (<= c 57))
            (and (>= c 65) (<= c 90))
            (and (>= c 97) (<= c 122))
            (= c 45)
            (= c 46)
            (= c 58)
            (= c 95)))
        (return false))))
  true)

(define (relative? [text : (& s str)]) : bool
  (when (not (name? text)) (return false))
  (let
    [length : i64 (string.string-length text)]
    [start : i64 0]
    (for [i (iterator.range 0 (+ length 1))]
      (let
        [c : i64
          (if (= i length)
            47
            (cast (string.string-ref text i) : i64))]
        (when (or (= c 92) (= c 58)) (return false))
        (when
          (= c 47)
          (let
            [n : i64 (- i start)]
            (when (= n 0) (return false))
            (when
              (and
                (<= n 2)
                (= (cast (string.string-ref text start) : i64) 46)
                (or
                  (= n 1)
                  (= (cast (string.string-ref text (+ start 1)) : i64) 46)))
              (return false)))
          (set! start (+ i 1)))))
    true))

(define (leaf-name? [text : (& s str)]) : bool
  (and
    (name? text)
    (let
      [i : i64 0]
      [n : i64 (string.string-length text)]
      (while (< i n)
        (let
          [c : i64 (cast (string.string-ref text i) : i64)]
          (when (or (= c 47) (= c 92) (= c 58)) (return false)))
        (set! i (+ i 1)))
      true)))

(define (known-runtime? [name : (& s str)] [p : (& p n.NativeToolchainProfile)]) : bool
  (or
    (string.eq name "typelisp.runtime.v1")
    (if (= (target-index (& p.target)) 0)
      (string.eq name "typelisp.linux-syscalls.v1")
      (string.eq name "typelisp.windows-system-imports.v1"))
    (match p.runtime
      [(n.CompilerFreestanding) (string.eq name "typelisp.compiler-startup.v1")]
      [(n.GlibcRuntime) (string.eq name "typelisp.glibc-runtime.v1")]
      [(n.MuslRuntime) (string.eq name "typelisp.musl-runtime.v1")]
      [(n.MsvcRuntime) (string.eq name "typelisp.msvc-runtime.v1")]
      [(n.UcrtRuntime) (string.eq name "typelisp.ucrt-runtime.v1")])))

(define (profile-helper?
  [p : (& p n.NativeToolchainProfile)]
  [name : (& s str)]) : bool
  (when (not (known-runtime? name p)) (return false))
  (for [i (iterator.range 0 (array-length (& p.runtime-identities)))]
    (when (string.eq name (& (array-ref p.runtime-identities i))) (return true)))
  false)

(define (check-name!
  [v : (&mut v NativeLinkValidation)]
  [text : (& s str)]
  [field : String]
  [event : i64]) : unit
  (when
    (not (name? text))
    (diagnose!
      v
      (InvalidName)
      field
      event
      "nonempty bytes without NUL/control bytes required")))

(define (check-id!
  [v : (&mut v NativeLinkValidation)]
  [text : (& s str)]
  [field : String]
  [event : i64]) : unit
  (when
    (not (id? text))
    (diagnose!
      v
      (InvalidIdentity)
      field
      event
      "logical identity must use ASCII letters, digits, . _ : -")))

(define (content!
  [v : (&mut v NativeLinkValidation)]
  [identity : (& c n.ContentIdentity)]
  [field : String]
  [event : i64]) : unit
  (when
    (!= identity.algorithm-version (cast 1 : u32))
    (diagnose!
      v
      (InvalidVersion)
      field
      event
      "content identity algorithm is SHA-256 v1")))

(define (expected-content!
  [v : (&mut v NativeLinkValidation)]
  [identity : (& c n.ExpectedContent)]
  [field : String]
  [event : i64]) : unit
  (match identity
    [(n.ExactContent content) (content! v (& content) field event)]
    [_ unit]))

(define (target-abi?
  [target : n.NativeTarget]
  [abi : n.NativeAbi]
  [triple : (& s str)]) : bool
  (match target
    [(n.LinuxX86_64)
      (and
        (match abi
          [(n.SysVAMD64) true]
          [_ false])
        (or
          (string.eq triple "x86_64-unknown-linux-gnu")
          (string.eq triple "x86_64-unknown-linux-musl")))]
    [(n.WindowsX86_64)
      (and
        (match abi
          [(n.WindowsAMD64) true]
          [_ false])
        (string.eq triple "x86_64-pc-windows-msvc"))]))

(define (target-output? [target : n.NativeTarget] [output : n.NativeOutputKind]) : bool
  (match target
    [(n.LinuxX86_64)
      (match output
        [(or (n.PeDll) (n.MicrosoftImportLibrary)) false]
        [_ true])]
    [(n.WindowsX86_64)
      (match output
        [(or (n.StaticPieExecutable) (n.ElfSharedObject)) false]
        [_ true])]))

(define (same-target? [a : n.NativeTarget] [b : n.NativeTarget]) : bool
  (= (target-index (& a)) (target-index (& b))))

(define (target-index [value : (& value n.NativeTarget)]) : i64
  (match value
    [(n.LinuxX86_64) 0]
    [(n.WindowsX86_64) 1]))

(define (output-index [value : (& value n.NativeOutputKind)]) : i64
  (match value
    [(n.Relocatable) 0]
    [(n.FreestandingStaticExecutable) 1]
    [(n.StaticExecutable) 2]
    [(n.StaticPieExecutable) 3]
    [(n.PieExecutable) 4]
    [(n.StaticArchive) 5]
    [(n.ElfSharedObject) 6]
    [(n.PeDll) 7]
    [(n.MicrosoftImportLibrary) 8]))

(define (capability-index [value : (& value n.CapabilityKind)]) : i64
  (match value
    [(n.ObjectInputs) 0]
    [(n.ArchiveInputs) 1]
    [(n.SharedInputs) 2]
    [(n.ImportLibraryInputs) 3]
    [(n.LibrarySearch) 4]
    [(n.Groups) 5]
    [(n.WholeArchive) 6]
    [(n.StaticDynamicPreference) 7]
    [(n.DefaultLibraries) 8]
    [(n.Directives) 9]
    [(n.Exports) 10]
    [(n.DefinitionFiles) 11]
    [(n.VersionMaps) 12]
    [(n.Resources) 13]
    [(n.Tls) 14]
    [(n.Ifunc) 15]
    [(n.Constructors) 16]
    [(n.Unwind) 17]
    [(n.Dwarf) 18]
    [(n.CodeView) 19]
    [(n.Relocations) 20]
    [(n.DelayLoad) 21]
    [(n.ExternalArguments) 22]
    [(n.RuntimeHelpers) 23]
    [(n.SystemImports) 33]
    [(n.OutputRelocatable) 24]
    [(n.OutputFreestandingStatic) 25]
    [(n.OutputStatic) 26]
    [(n.OutputStaticPie) 27]
    [(n.OutputPie) 28]
    [(n.OutputArchive) 29]
    [(n.OutputElfDso) 30]
    [(n.OutputPeDll) 31]
    [(n.OutputImportLibrary) 32]))

(define (hardening-index [value : (& value n.HardeningFeature)]) : i64
  (match value
    [(n.PositionIndependent) 0]
    [(n.AddressRandomization) 1]
    [(n.NoExecute) 2]
    [(n.NonExecutableStack) 3]
    [(n.Relro) 4]
    [(n.ControlFlowGuard) 5]
    [(n.Cet) 6]
    [(n.EhContinuation) 7]
    [(n.StackProtector) 8]))

(define (root-declared?
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [id : (& s str)]) : bool
  (for [i (iterator.range 0 (array-length (& m.roots)))]
    (when (string.eq (& (array-ref m.roots i).id) id) (return true)))
  (for [i (iterator.range 0 (array-length (& p.roots)))]
    (when (string.eq (& (array-ref p.roots i).id) id) (return true)))
  false)

(define (path!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [path : (& x n.NativePathRef)]
  [field : String]
  [event : i64]) : unit
  (check-id! v (& path.root-id) (clone field) event)
  (when
    (not (relative? (& path.relative)))
    (diagnose!
      v
      (InvalidPath)
      (clone field)
      event
      "normalized nonescaping relative bytes required"))
  (when
    (not (root-declared? m p (& path.root-id)))
    (diagnose!
      v
      (UnknownRoot)
      (clone field)
      event
      "logical root is not declared"))
  (expected-content! v (& path.content) field event))

(define (provenance!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [origin : (& o n.NativeLinkProvenance)]
  [event : i64]) : unit
  (match origin
    [(n.CommandLineOrigin _) unit]
    [(n.SourceOrigin module declaration span)
      (check-id! v (& module) "provenance.source.module" event)
      (check-name! v (& declaration) "provenance.source.declaration" event)
      (when
        (> span.length (- (cast -1 : u64) span.start))
        (diagnose!
          v
          (InvalidControl)
          "provenance.source.span"
          event
          "span end overflows u64"))]
    [(n.PackageOrigin manifest package field _)
      (path! v m p (& manifest) "provenance.package.manifest" event)
      (when
        (not
          (match manifest.kind
            [(n.PackageManifestFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "provenance.package.manifest.kind"
          event
          "package manifest file kind required"))
      (check-id! v (& package) "provenance.package.key" event)
      (check-name! v (& field) "provenance.package.field" event)]
    [(n.DependencyOrigin from to manifest field _)
      (check-id! v (& from) "provenance.dependency.from" event)
      (check-id! v (& to) "provenance.dependency.to" event)
      (path! v m p (& manifest) "provenance.dependency.manifest" event)
      (when
        (not
          (match manifest.kind
            [(n.PackageManifestFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "provenance.dependency.manifest.kind"
          event
          "package manifest file kind required"))
      (check-name! v (& field) "provenance.dependency.field" event)]
    [(n.ArtifactOrigin artifact export _)
      (check-id! v (& artifact) "provenance.artifact" event)
      (check-name! v (& export) "provenance.artifact.export" event)]
    [(n.ObjectDirectiveOrigin object _)
      (path! v m p (& object) "provenance.object" event)
      (when
        (not
          (match object.kind
            [(n.ObjectFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "provenance.object.kind"
          event
          "directive origin requires object file kind"))]
    [(n.ProfileRowOrigin profile row _)
      (when
        (not (string.eq (& profile) (& p.id)))
        (diagnose!
          v
          (ProfileMismatch)
          "provenance.profile.id"
          event
          "profile origin is not selected profile"))
      (check-id! v (& row) "provenance.profile.row" event)]
    [(n.CompilerRuntimeOrigin name _)
      (check-id! v (& name) "provenance.runtime" event)]))

(define (power-two? [n : u64]) : bool
  (and (> n (cast 0 : u64)) (= (bit-and n (- n (cast 1 : u64))) (cast 0 : u64))))

(define (windows!
  [v : (&mut v NativeLinkValidation)]
  [image : (& w n.WindowsImagePolicy)]
  [event : i64]) : unit
  (when
    (match image.subsystem
      [(n.NoWindowsSubsystem) true]
      [_ false])
    (diagnose!
      v
      (InvalidControl)
      "windows.subsystem"
      event
      "explicit Windows subsystem required"))
  (when
    (or
      (not (power-two? image.file-alignment))
      (< image.file-alignment (cast 512 : u64))
      (> image.file-alignment (cast 65536 : u64)))
    (diagnose!
      v
      (InvalidControl)
      "windows.file-alignment"
      event
      "power of two in [512,65536] required"))
  (when
    (or
      (not (power-two? image.section-alignment))
      (< image.section-alignment image.file-alignment))
    (diagnose!
      v
      (InvalidControl)
      "windows.section-alignment"
      event
      "power of two no smaller than file alignment required"))
  (when
    (> image.section-alignment (cast 4294967295 : u64))
    (diagnose!
      v
      (InvalidControl)
      "windows.section-alignment"
      event
      "section alignment exceeds the PE u32 field"))
  (when
    (and
      (< image.section-alignment (cast 4096 : u64))
      (!= image.section-alignment image.file-alignment))
    (diagnose!
      v
      (InvalidControl)
      "windows.section-alignment"
      event
      "subpage x64 image alignment requires equal file alignment"))
  (when
    (!= (bit-and image.image-base (cast 65535 : u64)) (cast 0 : u64))
    (diagnose!
      v
      (InvalidControl)
      "windows.image-base"
      event
      "64 KiB alignment required"))
  (when
    (or
      (= image.stack-reserve (cast 0 : u64))
      (> image.stack-commit image.stack-reserve))
    (diagnose!
      v
      (InvalidControl)
      "windows.stack"
      event
      "nonzero reserve must cover commit"))
  (when
    (> image.heap-commit image.heap-reserve)
    (diagnose!
      v
      (InvalidControl)
      "windows.heap"
      event
      "reserve must cover commit")))

(define (debug!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [debug : (& d n.DebugPolicy)]
  [event : i64]) : unit
  (match debug.form
    [(n.DwarfDebug)
      (require-capability! v p (n.Dwarf) event)
      (when
        (!= (target-index (& m.target)) 0)
        (diagnose!
          v
          (InvalidTarget)
          "debug.form"
          event
          "DWARF requires Linux v1"))]
    [(n.CodeViewDebug)
      (require-capability! v p (n.CodeView) event)
      (when
        (!= (target-index (& m.target)) 1)
        (diagnose!
          v
          (InvalidTarget)
          "debug.form"
          event
          "CodeView requires Windows v1"))]
    [_ unit])
  (match debug.build-id
    [(n.ExplicitBuildId text) (check-name! v (& text) "debug.build-id" event)]
    [_ unit])
  (match debug.pdb
    [(n.LogicalPdb path)
      (path! v m p (& path) "debug.pdb" event)
      (when
        (not
          (match path.kind
            [(n.DebugFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "debug.pdb.kind"
          event
          "PDB path requires DebugFile kind"))
      (when
        (or
          (!= (target-index (& m.target)) 1)
          (not
            (match debug.form
              [(n.CodeViewDebug) true]
              [_ false])))
        (diagnose!
          v
          (InvalidControl)
          "debug.pdb"
          event
          "PDB requires Windows CodeView"))]
    [_ unit]))

(define (hardening!
  [v : (&mut v NativeLinkValidation)]
  [row : (& r n.HardeningRow)]
  [event : i64]) : unit
  (when
    (not (string.eq (& row.schema-id) "typelisp.native-link.hardening.v1"))
    (diagnose!
      v
      (InvalidVersion)
      "hardening.schema-id"
      event
      "unknown hardening schema identity"))
  (when
    (match row.requirement
      [(n.Required) true]
      [_ false])
    (check-id! v (& row.helper-id) "hardening.helper-id" event)
    (diagnose!
      v
      (UnsupportedCapability)
      "hardening.helper-id"
      event
      "v1 runtime contracts do not attest required hardening; a dedicated admitted feature contract is required")))

(define (capability-supported?
  [p : (& p n.NativeToolchainProfile)]
  [kind : n.CapabilityKind]) : bool
  (let
    [wanted : i64 (capability-index (& kind))]
    (for [i (iterator.range 0 (array-length (& p.capabilities)))]
      (when
        (= (capability-index (& (array-ref p.capabilities i).kind)) wanted)
        (return
          (match (array-ref p.capabilities i).support
            [(n.Supported _) true]
            [_ false]))))
    false))

(define (require-capability!
  [v : (&mut v NativeLinkValidation)]
  [p : (& p n.NativeToolchainProfile)]
  [kind : n.CapabilityKind]
  [event : i64]) : unit
  (when
    (not (capability-supported? p kind))
    (diagnose!
      v
      (UnsupportedCapability)
      "event.capability"
      event
      "selected profile does not support this event feature")))

(define (output-capability [output : (& o n.NativeOutputKind)]) : n.CapabilityKind
  (match output
    [(n.Relocatable) (n.OutputRelocatable)]
    [(n.FreestandingStaticExecutable) (n.OutputFreestandingStatic)]
    [(n.StaticExecutable) (n.OutputStatic)]
    [(n.StaticPieExecutable) (n.OutputStaticPie)]
    [(n.PieExecutable) (n.OutputPie)]
    [(n.StaticArchive) (n.OutputArchive)]
    [(n.ElfSharedObject) (n.OutputElfDso)]
    [(n.PeDll) (n.OutputPeDll)]
    [(n.MicrosoftImportLibrary) (n.OutputImportLibrary)]))

(define (windows-import? [symbol : (& s str)] [dll : (& d str)]) : bool
  (if (string.eq dll "ntdll.dll")
    (string.eq symbol "NtCreateFile")
    (and
      (string.eq dll "kernel32.dll")
      (or
        (string.eq symbol "ConvertThreadToFiber")
        (string.eq symbol "CreateFiberEx")
        (string.eq symbol "ExitProcess")
        (string.eq symbol "GetCommandLineA")
        (string.eq symbol "GetStdHandle")
        (string.eq symbol "SetThreadStackGuarantee")
        (string.eq symbol "SetUnhandledExceptionFilter")
        (string.eq symbol "SwitchToFiber")
        (string.eq symbol "WriteFile")
        (string.eq symbol "VirtualAlloc")
        (string.eq symbol "VirtualFree")))))

(define (startup-policy!
  [v : (&mut v NativeLinkValidation)]
  [p : (& p n.NativeToolchainProfile)]
  [policy : (& s n.StartupPolicy)]
  [event : i64]) : unit
  (match policy
    [(n.CompilerStartup name)
      (check-id! v (& name) "startup.compiler" event)
      (when
        (not (profile-helper? p (& name)))
        (diagnose!
          v
          (MissingHelper)
          "startup.compiler"
          event
          "compiler startup contract is not selected"))]
    [(n.CrtStartup name)
      (check-id! v (& name) "startup.crt" event)
      (when
        (match p.runtime
          [(n.CompilerFreestanding) true]
          [_ false])
        (diagnose!
          v
          (InvalidRuntime)
          "startup.crt"
          event
          "CRT startup is incompatible with compiler freestanding profile"))
      (let
        [found : bool false]
        (for [i (iterator.range 0 (array-length (& p.inputs)))]
          (when
            (and
              (string.eq (& name) (& (array-ref p.inputs i).file-id))
              (match (array-ref p.inputs i).position
                [(n.StartupInput) true]
                [_ false]))
            (set! found true)))
        (when
          (not found)
          (diagnose!
            v
            (ProfileMismatch)
            "startup.crt"
            event
            "CRT startup file is not in the profile startup schedule")))]
    [(n.ProfileStartup)
      (let
        [found : bool false]
        (for [i (iterator.range 0 (array-length (& p.inputs)))]
          (when
            (match (array-ref p.inputs i).position
              [(n.StartupInput) true]
              [_ false])
            (set! found true)))
        (when
          (not found)
          (diagnose!
            v
            (ProfileMismatch)
            "startup.profile"
            event
            "profile has no startup inputs")))]
    [_ unit]))

(define (input-file!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [path : (& f n.NativePathRef)]
  [field : String]
  [event : i64]) : unit
  (path! v m p path (clone field) event)
  (require-capability! v p (file-kind-capability (& path.kind)) event)
  (when
    (not
      (match path.kind
        [(or (n.ObjectFile) (n.StaticArchiveFile) (n.SharedObjectFile)
             (n.ImportLibraryFile))
          true]
        [_ false]))
    (diagnose!
      v
      (InvalidControl)
      (clone field)
      event
      "v1 ordered file inputs require object/archive/shared/import-library kind; scripts need a future typed contract"))
  (when
    (and
      (match path.kind
        [(n.ImportLibraryFile) true]
        [_ false])
      (!= (target-index (& m.target)) 1))
    (diagnose!
      v
      (InvalidTarget)
      (clone field)
      event
      "Microsoft import library requires Windows"))
  (when
    (and
      (= (target-index (& m.target)) 0)
      (match path.kind
        [(n.SharedObjectFile) true]
        [_ false])
      (match m.output
        [(or (n.FreestandingStaticExecutable) (n.StaticExecutable)
             (n.StaticPieExecutable))
          true]
        [_ false]))
    (diagnose!
      v
      (InvalidOutput)
      field
      event
      "static ELF executable cannot bind a shared-object input")))

(define (profile!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]) : (__tl_dyn-array i64)
  (let
    [indices : (__tl_dyn-array i64)
      (__tl_make-array i64 (array-length (& p.inputs)))]
    (when
      (or
        (!= p.schema-version (cast 1 : u32))
        (!= p.extension-version (cast 0 : u32)))
      (diagnose!
        v
        (InvalidVersion)
        "profile.version"
        -1
        "v1 has no extension records; future extension requires an explicit schema version"))
    (check-id! v (& p.id) "profile.id" -1)
    (when
      (= p.version (cast 0 : u32))
      (diagnose!
        v
        (InvalidVersion)
        "profile.identity.version"
        -1
        "profile version must be nonzero"))
    (when
      (not (target-abi? (clone p.target) (clone p.abi) (& p.target-triple)))
      (diagnose!
        v
        (InvalidTarget)
        "profile.target"
        -1
        "target triple/ABI disagreement"))
    (when
      (not
        (match p.runtime
          [(n.CompilerFreestanding) true]
          [(or (n.GlibcRuntime) (n.MuslRuntime))
            (= (target-index (& p.target)) 0)]
          [(or (n.MsvcRuntime) (n.UcrtRuntime))
            (= (target-index (& p.target)) 1)]))
      (diagnose!
        v
        (InvalidRuntime)
        "profile.runtime"
        -1
        "runtime family is incompatible with target"))
    (when
      (and
        (match p.runtime
          [(n.MuslRuntime) true]
          [_ false])
        (not (string.eq (& p.target-triple) "x86_64-unknown-linux-musl")))
      (diagnose!
        v
        (InvalidTarget)
        "profile.target-triple"
        -1
        "musl runtime requires musl target triple"))
    (when
      (and
        (match p.runtime
          [(n.GlibcRuntime) true]
          [_ false])
        (not (string.eq (& p.target-triple) "x86_64-unknown-linux-gnu")))
      (diagnose!
        v
        (InvalidTarget)
        "profile.target-triple"
        -1
        "glibc runtime requires GNU target triple"))
    (let
      [seen : i64 0]
      (for [i (iterator.range 0 (array-length (& p.outputs)))]
        (let
          [output : n.NativeOutputKind (clone (array-ref p.outputs i))]
          [bit : i64 (shl 1 (output-index (& output)))]
          (when
            (!= (bit-and seen bit) 0)
            (diagnose!
              v
              (DuplicateKey)
              "profile.outputs"
              -1
              "duplicate output kind"))
          (set! seen (bit-or seen bit))
          (when
            (and
              (match output
                [(n.FreestandingStaticExecutable) true]
                [_ false])
              (not
                (match p.runtime
                  [(n.CompilerFreestanding) true]
                  [_ false])))
            (diagnose!
              v
              (InvalidRuntime)
              "profile.outputs"
              -1
              "freestanding output requires compiler-owned runtime"))
          (when
            (not (target-output? (clone p.target) (clone output)))
            (diagnose!
              v
              (InvalidOutput)
              "profile.outputs"
              -1
              "output kind is incompatible with target"))
          (when
            (not (capability-supported? p (output-capability (& output))))
            (diagnose!
              v
              (UnsupportedCapability)
              "profile.outputs"
              -1
              "output lacks supported capability row"))))
      (when
        (= (bit-and seen (shl 1 (output-index (& m.output)))) 0)
        (diagnose!
          v
          (InvalidOutput)
          "manifest.output"
          -1
          "output is not in selected profile")))
    (for [i (iterator.range 0 (array-length (& p.roots)))]
      (check-id! v (& (array-ref p.roots i).id) "profile.roots.id" -1)
      (expected-content!
        v
        (& (array-ref p.roots i).identity)
        "profile.roots.identity"
        -1)
      (for [j (iterator.range 0 i)]
        (when
          (string.eq (& (array-ref p.roots i).id) (& (array-ref p.roots j).id))
          (diagnose! v (DuplicateKey) "profile.roots" -1 "duplicate root id"))))
    (for [i (iterator.range 0 (array-length (& p.files)))]
      (check-id! v (& (array-ref p.files i).id) "profile.files.id" -1)
      (path! v m p (& (array-ref p.files i).path) "profile.files.path" -1)
      (for [j (iterator.range 0 i)]
        (when
          (string.eq (& (array-ref p.files i).id) (& (array-ref p.files j).id))
          (diagnose! v (DuplicateKey) "profile.files" -1 "duplicate file id"))))
    (for [i (iterator.range 0 (array-length (& p.inputs)))]
      (set! (array-ref indices i) -1)
      (provenance! v m p (& (array-ref p.inputs i).provenance) -1)
      (for [j (iterator.range 0 (array-length (& p.files)))]
        (when
          (and
            (< (array-ref indices i) 0)
            (string.eq
              (& (array-ref p.inputs i).file-id)
              (& (array-ref p.files j).id)))
          (set! (array-ref indices i) j)))
      (let
        [file : i64 (array-ref indices i)]
        (if (< file 0)
          (diagnose!
            v
            (InvalidIdentity)
            "profile.inputs.file-id"
            -1
            "ordered input references unknown file")
          (input-file!
            v
            m
            p
            (& (array-ref p.files file).path)
            "profile.inputs.file"
            -1))))
    (for [i (iterator.range 0 (array-length (& p.runtime-identities)))]
      (check-id!
        v
        (& (array-ref p.runtime-identities i))
        "profile.runtime-identities"
        -1)
      (when
        (not (known-runtime? (& (array-ref p.runtime-identities i)) p))
        (diagnose!
          v
          (MissingHelper)
          "profile.runtime-identities"
          -1
          "unknown v1 runtime contract identity"))
      (for [j (iterator.range 0 i)]
        (when
          (string.eq
            (& (array-ref p.runtime-identities i))
            (& (array-ref p.runtime-identities j)))
          (diagnose!
            v
            (DuplicateKey)
            "profile.runtime-identities"
            -1
            "duplicate runtime identity"))))
    (when
      (= (array-length (& p.runtime-identities)) 0)
      (diagnose!
        v
        (MissingHelper)
        "profile.runtime-identities"
        -1
        "resolved profile must identify its runtime contracts"))
    (for [i (iterator.range 0 (array-length (& p.imports)))]
      (check-name!
        v
        (& (array-ref p.imports i).symbol)
        "profile.imports.symbol"
        -1)
      (when
        (not (leaf-name? (& (array-ref p.imports i).dll)))
        (diagnose!
          v
          (InvalidName)
          "profile.imports.dll"
          -1
          "DLL identity is a leaf name, not an operational path"))
      (when
        (!= (target-index (& p.target)) 1)
        (diagnose!
          v
          (InvalidTarget)
          "profile.imports"
          -1
          "system DLL imports require Windows"))
      (for [j (iterator.range 0 i)]
        (when
          (string.eq
            (& (array-ref p.imports i).symbol)
            (& (array-ref p.imports j).symbol))
          (diagnose!
            v
            (DuplicateKey)
            "profile.imports"
            -1
            "symbol has multiple DLL mappings"))))
    (let
      [seen : i64 0]
      (for [i (iterator.range 0 (array-length (& p.capabilities)))]
        (let
          [row : n.CapabilityRow (clone (array-ref p.capabilities i))]
          [bit : i64 (shl 1 (capability-index (& row.kind)))]
          (when
            (!= (bit-and seen bit) 0)
            (diagnose!
              v
              (DuplicateKey)
              "profile.capabilities"
              -1
              "duplicate capability row"))
          (set! seen (bit-or seen bit))
          (when
            (not
              (string.eq (& row.schema-id) "typelisp.native-link.capability.v1"))
            (diagnose!
              v
              (InvalidVersion)
              "profile.capabilities.schema-id"
              -1
              "unknown capability schema identity"))
          (when
            (match row.support
              [(n.Unsupported (n.Implemented)) true]
              [_ false])
            (diagnose!
              v
              (InvalidControl)
              "profile.capabilities.reason"
              -1
              "unsupported rows cannot use Implemented reason"))
          (when
            (or
              (match row.support
                [(n.Supported _) true]
                [_ false])
              (> (string.string-length (& row.helper-id)) 0))
            (when
              (not (profile-helper? p (& row.helper-id)))
              (diagnose!
                v
                (MissingHelper)
                "profile.capabilities.helper-id"
                -1
                "supported row requires a known selected runtime contract"))
            (when
              (and
                (match row.support
                  [(n.Supported _) true]
                  [_ false])
                (not
                  (match row.support
                    [(n.Supported (n.Implemented)) true]
                    [_ false])))
              (diagnose!
                v
                (InvalidControl)
                "profile.capabilities.reason"
                -1
                "supported rows require Implemented reason")))))
      (when
        (!= seen (- (shl 1 34) 1))
        (diagnose!
          v
          (MissingCapability)
          "profile.capabilities"
          -1
          "every v1 capability requires exactly one row")))
    (let
      [seen : i64 0]
      (for [i (iterator.range 0 (array-length (& p.hardening)))]
        (let
          [row : n.HardeningRow (clone (array-ref p.hardening i))]
          [bit : i64 (shl 1 (hardening-index (& row.feature)))]
          (when
            (!= (bit-and seen bit) 0)
            (diagnose!
              v
              (DuplicateKey)
              "profile.hardening"
              -1
              "duplicate hardening row"))
          (set! seen (bit-or seen bit))
          (hardening! v (& row) -1)
          (when
            (and
              (or
                (match row.requirement
                  [(n.Required) true]
                  [_ false])
                (> (string.string-length (& row.helper-id)) 0))
              (not (profile-helper? p (& row.helper-id))))
            (diagnose!
              v
              (MissingHelper)
              "profile.hardening.helper-id"
              -1
              "required hardening has no known selected helper contract"))))
      (when
        (!= seen 511)
        (diagnose!
          v
          (MissingCapability)
          "profile.hardening"
          -1
          "all nine hardening rows required")))
    (startup-policy! v p (& p.startup) -1)
    (debug! v m p (& p.debug) -1)
    (when (= (target-index (& p.target)) 1) (windows! v (& p.windows) -1))
    (match p.runtime
      [(n.CompilerFreestanding)
        (when
          (or
            (!= (array-length (& p.roots)) 0)
            (!= (array-length (& p.files)) 0)
            (!= (array-length (& p.inputs)) 0))
          (diagnose!
            v
            (InvalidRuntime)
            "profile.freestanding.files"
            -1
            "compiler freestanding profile has no ambient roots or toolchain files"))
        (when
          (not
            (match p.startup
              [(n.CompilerStartup name)
                (string.eq (& name) "typelisp.compiler-startup.v1")]
              [_ false]))
          (diagnose!
            v
            (InvalidRuntime)
            "profile.freestanding.startup"
            -1
            "compiler startup identity required"))
        (when
          (not
            (match p.entry
              [(n.CompilerEntry name) (string.eq (& name) "_tl_start")]
              [_ false]))
          (diagnose!
            v
            (InvalidRuntime)
            "profile.freestanding.entry"
            -1
            "compiler entry is _tl_start"))
        (when
          (not
            (match p.interpreter
              [(n.NoInterpreter) true]
              [_ false]))
          (diagnose!
            v
            (InvalidRuntime)
            "profile.freestanding.interpreter"
            -1
            "freestanding has no interpreter"))
        (for [i (iterator.range 0 (array-length (& p.outputs)))]
          (when
            (not
              (match (array-ref p.outputs i)
                [(or (n.Relocatable) (n.StaticArchive)
                     (n.FreestandingStaticExecutable))
                  true]
                [_ false]))
            (diagnose!
              v
              (InvalidOutput)
              "profile.freestanding.outputs"
              -1
              "freestanding v1 admits relocatable, archive and freestanding static executable")))
        (if (= (target-index (& p.target)) 0)
          (when
            (!= (array-length (& p.imports)) 0)
            (diagnose!
              v
              (InvalidImport)
              "profile.freestanding.imports"
              -1
              "Linux freestanding has no system imports"))
          (begin
            (when
              (!= (array-length (& p.imports)) 12)
              (diagnose!
                v
                (InvalidImport)
                "profile.freestanding.imports"
                -1
                "Windows freestanding requires exact twelve-function map"))
            (for [i (iterator.range 0 (array-length (& p.imports)))]
              (when
                (not
                  (windows-import?
                    (& (array-ref p.imports i).symbol)
                    (& (array-ref p.imports i).dll)))
                (diagnose!
                  v
                  (InvalidImport)
                  "profile.freestanding.imports"
                  -1
                  "function/DLL is outside compiler freestanding map")))))]
      [_
        (when
          (or
            (= p.runtime-floor.major (cast 0 : u32))
            (= (array-length (& p.files)) 0))
          (diagnose!
            v
            (InvalidRuntime)
            "profile.runtime-floor"
            -1
            "non-freestanding runtime requires sealed files and nonzero version floor"))
        (for [i (iterator.range 0 (array-length (& p.files)))]
          (when
            (not
              (match (array-ref p.files i).path.content
                [(n.ExactContent _) true]
                [_ false]))
            (diagnose!
              v
              (InvalidRuntime)
              "profile.files.content"
              -1
              "sealed runtime file requires an exact content identity")))])
    indices))

(define (interpreter!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [policy : (& i n.InterpreterPolicy)]
  [event : i64]) : unit
  (when
    (!= (target-index (& m.target)) 0)
    (diagnose!
      v
      (InvalidTarget)
      "control.interpreter"
      event
      "interpreter is an ELF control"))
  (match policy
    [(n.ExplicitInterpreter path)
      (path! v m p (& path) "control.interpreter" event)]
    [(n.ProfileInterpreter)
      (when
        (match p.interpreter
          [(n.NoInterpreter) true]
          [_ false])
        (diagnose!
          v
          (InvalidControl)
          "control.interpreter"
          event
          "selected profile has no interpreter"))]
    [_ unit])
  (when
    (and
      (match m.output
        [(or (n.FreestandingStaticExecutable) (n.StaticExecutable)
             (n.StaticPieExecutable) (n.StaticArchive) (n.Relocatable))
          true]
        [_ false])
      (not
        (match policy
          [(n.NoInterpreter) true]
          [_ false])))
    (diagnose!
      v
      (InvalidOutput)
      "control.interpreter"
      event
      "output does not admit an interpreter")))

(define (control-index [control : (& c n.NativeControl)]) : i64
  (match control
    [(n.EntryControl _) 0]
    [(n.StartupControl _) 1]
    [(n.UnresolvedControl _) 2]
    [(n.SectionGcControl _) 3]
    [(n.ExportsControl _) 4]
    [(n.SonameControl _) 5]
    [(n.InterpreterControl _) 6]
    [(n.WindowsImageControl _) 7]
    [(n.DebugControl _) 8]
    [(n.HardeningControl row) (+ 9 (hardening-index (& row.feature)))]
    [_ -1]))

(define (control!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [control : (& c n.NativeControl)]
  [event : i64]) : unit
  (match control
    [(n.EntryControl entry)
      (match entry
        [(or (n.CompilerEntry name) (n.RuntimeEntry name) (n.NamedEntry name))
          (check-name! v (& name) "control.entry" event)]
        [_ unit])
      (when
        (and
          (match m.output
            [(or (n.StaticArchive) (n.Relocatable) (n.ElfSharedObject)
                 (n.MicrosoftImportLibrary))
              true]
            [_ false])
          (not
            (match entry
              [(n.NoEntry) true]
              [_ false])))
        (diagnose!
          v
          (InvalidOutput)
          "control.entry"
          event
          "non-executable output requires NoEntry"))
      (when
        (and
          (match m.output
            [(n.FreestandingStaticExecutable) true]
            [_ false])
          (not
            (match entry
              [(n.CompilerEntry name) (string.eq (& name) "_tl_start")]
              [_ false])))
        (diagnose!
          v
          (InvalidRuntime)
          "control.entry"
          event
          "freestanding executable uses compiler _tl_start"))]
    [(n.StartupControl startup)
      (when
        (and
          (match m.output
            [(or (n.StaticArchive) (n.Relocatable) (n.MicrosoftImportLibrary))
              true]
            [_ false])
          (not
            (match startup
              [(n.NoStartup) true]
              [_ false])))
        (diagnose!
          v
          (InvalidOutput)
          "control.startup"
          event
          "non-executable output requires NoStartup"))
      (startup-policy! v p (& startup) event)]
    [(n.UnresolvedControl policy)
      (when
        (and
          (not
            (match policy
              [(n.RejectUnresolved) true]
              [_ false]))
          (match m.output
            [(or (n.FreestandingStaticExecutable) (n.StaticExecutable)
                 (n.StaticPieExecutable))
              true]
            [_ false]))
        (diagnose!
          v
          (InvalidOutput)
          "control.unresolved"
          event
          "static executable requires resolved symbols"))]
    [(n.ExportsControl policy)
      (when
        (not
          (match policy
            [(n.ExplicitExports) true]
            [_ false]))
        (require-capability! v p (n.Exports) event))]
    [(n.SonameControl name)
      (check-name! v (& name) "control.soname" event)
      (when
        (not
          (match m.output
            [(n.ElfSharedObject) true]
            [_ false]))
        (diagnose!
          v
          (InvalidOutput)
          "control.soname"
          event
          "soname requires ELF shared object"))]
    [(n.InterpreterControl policy) (interpreter! v m p (& policy) event)]
    [(or (n.RpathControl path) (n.RunpathControl path))
      (path! v m p (& path) "control.runtime-path" event)
      (when
        (or
          (!= (target-index (& m.target)) 0)
          (not
            (match m.output
              [(or (n.PieExecutable) (n.ElfSharedObject)) true]
              [_ false])))
        (diagnose!
          v
          (InvalidOutput)
          "control.runtime-path"
          event
          "runtime search path requires dynamic ELF output"))]
    [(n.WindowsImageControl image)
      (when
        (!= (target-index (& m.target)) 1)
        (diagnose!
          v
          (InvalidTarget)
          "control.windows"
          event
          "Windows image policy on Linux"))
      (windows! v (& image) event)]
    [(n.DebugControl debug) (debug! v m p (& debug) event)]
    [(n.HardeningControl row)
      (hardening! v (& row) event)
      (when
        (and
          (> (string.string-length (& row.helper-id)) 0)
          (not (profile-helper? p (& row.helper-id))))
        (diagnose!
          v
          (MissingHelper)
          "control.hardening.helper-id"
          event
          "hardening helper is not a known selected contract"))
      (let
        [found : bool false]
        (for [i (iterator.range 0 (array-length (& p.hardening)))]
          (when
            (=
              (hardening-index (& row.feature))
              (hardening-index (& (array-ref p.hardening i).feature)))
            (set! found true)
            (when
              (not
                (match row.requirement
                  [(n.Required)
                    (match (array-ref p.hardening i).requirement
                      [(n.Required) true]
                      [_ false])]
                  [(n.Off)
                    (match (array-ref p.hardening i).requirement
                      [(or (n.Off) (n.Forbidden)) true]
                      [_ false])]
                  [(n.Forbidden)
                    (match (array-ref p.hardening i).requirement
                      [(or (n.Off) (n.Forbidden)) true]
                      [_ false])]))
              (diagnose!
                v
                (InvalidHardening)
                "control.hardening"
                event
                "request conflicts with profile hardening support"))))
        (when
          (not found)
          (diagnose!
            v
            (MissingCapability)
            "control.hardening"
            event
            "profile hardening row missing")))]
    [_ unit]))

(defstruct Scope
  (kind i64)
  (id u64))

(define (scope-event!
  [v : (&mut v NativeLinkValidation)]
  [stack : (&mut s (__tl_dyn-array Scope))]
  [depth : i64]
  [kind : i64]
  [id : u64]
  [begin : bool]
  [event : i64]) : i64
  (cond
    [begin
      (if (>= depth (array-length stack))
        (begin
          (diagnose! v (InvalidScope) "event.scope" event "scope nesting limit")
          depth)
        (begin
          (for [i (iterator.range 0 depth)]
            (when
              (= (array-ref stack i).id id)
              (diagnose!
                v
                (InvalidScope)
                "event.scope"
                event
                "active scope id reused")))
          (set! (array-ref stack depth) (Scope kind id))
          (+ depth 1)))]
    [(= depth 0)
      (diagnose! v (InvalidScope) "event.scope" event "scope end without begin")
      depth]
    [(or
      (!= (array-ref stack (- depth 1)).kind kind)
      (!= (array-ref stack (- depth 1)).id id))
      (diagnose!
        v
        (InvalidScope)
        "event.scope"
        event
        "crossing scope or mismatched id")
      depth]
    [else (- depth 1)]))

(define (file-kind-capability [kind : (& k n.NativeFileKind)]) : n.CapabilityKind
  (match kind
    [(n.StaticArchiveFile) (n.ArchiveInputs)]
    [(n.SharedObjectFile) (n.SharedInputs)]
    [(n.ImportLibraryFile) (n.ImportLibraryInputs)]
    [_ (n.ObjectInputs)]))

(define (same-position? [a : (& a n.InputPosition)] [b : (& b n.InputPosition)]) : bool
  (match a
    [(n.StartupInput)
      (match b
        [(n.StartupInput) true]
        [_ false])]
    [(n.EndInput)
      (match b
        [(n.EndInput) true]
        [_ false])]
    [(n.DefaultInput)
      (match b
        [(n.DefaultInput) true]
        [_ false])]
    [(n.RuntimeInput)
      (match b
        [(n.RuntimeInput) true]
        [_ false])]))

(define (same-content?
  [a : (& a n.ExpectedContent)]
  [b : (& b n.ExpectedContent)]) : bool
  (match a
    [(n.UnspecifiedContent)
      (match b
        [(n.UnspecifiedContent) true]
        [_ false])]
    [(n.ExactContent left)
      (match b
        [(n.ExactContent right)
          (when
            (!= left.algorithm-version right.algorithm-version)
            (return false))
          (for [i (iterator.range 0 32)]
            (when
              (!= (array-ref left.sha256 i) (array-ref right.sha256 i))
              (return false)))
          true]
        [_ false])]))

(define (same-path? [a : (& a n.NativePathRef)] [b : (& b n.NativePathRef)]) : bool
  (and
    (string.eq (& a.root-id) (& b.root-id))
    (string.eq (& a.relative) (& b.relative))
    (= a.kind b.kind)
    (same-content? (& a.content) (& b.content))))

(define (selected-profile-input?
  [p : (& p n.NativeToolchainProfile)]
  [indices : (& j (__tl_dyn-array i64))]
  [position : (& i n.InputPosition)]
  [path : (& f n.NativePathRef)]) : bool
  (for [i (iterator.range 0 (array-length (& p.inputs)))]
    (let
      [file : i64 (array-ref indices i)]
      (when
        (and
          (>= file 0)
          (same-position? position (& (array-ref p.inputs i).position))
          (same-path? path (& (array-ref p.files file).path)))
        (return true))))
  false)

(define (event!
  [v : (&mut v NativeLinkValidation)]
  [m : (& m n.NativeLinkManifest)]
  [p : (& p n.NativeToolchainProfile)]
  [payload : (& e n.NativeEventPayload)]
  [ordinal : i64]
  [limits : (& l NativeLinkLimits)]
  [profile-indices : (& j (__tl_dyn-array i64))]) : unit
  (match payload
    [(n.FileInput path) (input-file! v m p (& path) "event.input" ordinal)]
    [(n.LibraryLookup name)
      (when
        (not (leaf-name? (& name)))
        (diagnose!
          v
          (InvalidName)
          "event.library"
          ordinal
          "library lookup requires a leaf name"))
      (require-capability! v p (n.LibrarySearch) ordinal)]
    [(n.SearchRoot root)
      (check-id! v (& root) "event.search-root" ordinal)
      (when
        (not (root-declared? m p (& root)))
        (diagnose!
          v
          (UnknownRoot)
          "event.search-root"
          ordinal
          "search root not declared"))
      (require-capability! v p (n.LibrarySearch) ordinal)]
    [(or (n.BeginGroup _) (n.EndGroup _))
      (require-capability! v p (n.Groups) ordinal)]
    [(or (n.BeginWholeArchive _) (n.EndWholeArchive _))
      (require-capability! v p (n.WholeArchive) ordinal)]
    [(or (n.BeginPreference _ _) (n.EndPreference _))
      (require-capability! v p (n.StaticDynamicPreference) ordinal)]
    [(n.ForcedUndefined name)
      (check-name! v (& name) "event.undefined" ordinal)]
    [(n.RetainedRoot _ name) (check-name! v (& name) "event.retain" ordinal)]
    [(n.DefaultLibrary action name)
      (when
        (not
          (match action
            [(n.SuppressAllDefaultLibraries) true]
            [_ false]))
        (check-name! v (& name) "event.default-library" ordinal))
      (when
        (and
          (match action
            [(n.SuppressAllDefaultLibraries) true]
            [_ false])
          (!= (string.string-length (& name)) 0))
        (diagnose!
          v
          (InvalidControl)
          "event.default-library"
          ordinal
          "suppress-all has an empty library name"))
      (require-capability! v p (n.DefaultLibraries) ordinal)]
    [(n.ProfileFileInput position path)
      (input-file! v m p (& path) "event.profile-input" ordinal)
      (when
        (not (selected-profile-input? p profile-indices (& position) (& path)))
        (diagnose!
          v
          (ProfileMismatch)
          "event.profile-input"
          ordinal
          "file and position are not in the selected profile schedule"))]
    [(n.RuntimeRoot identity)
      (let
        [found : bool false]
        (for [i (iterator.range 0 (array-length (& p.runtime-identities)))]
          (when
            (string.eq (& identity) (& (array-ref p.runtime-identities i)))
            (set! found true)))
        (when
          (not found)
          (diagnose!
            v
            (MissingHelper)
            "event.runtime"
            ordinal
            "runtime identity not selected in profile")))]
    [(n.Directive directive)
      (match directive
        [(n.IncludeDirective name)
          (check-name! v (& name) "event.directive.name" ordinal)]
        [(or (n.AliasDirective name value) (n.AlternateNameDirective name value)
             (n.MergeSectionDirective name value))
          (check-name! v (& name) "event.directive.name" ordinal)
          (check-name! v (& value) "event.directive.value" ordinal)]
        [(n.SectionAttributesDirective name _)
          (check-name! v (& name) "event.directive.section" ordinal)])
      (require-capability! v p (n.Directives) ordinal)]
    [(n.Export export)
      (check-name! v (& export.name) "event.export.name" ordinal)
      (when
        (> (string.string-length (& export.alias)) 0)
        (check-name! v (& export.alias) "event.export.alias" ordinal))
      (when
        (> export.ordinal (cast 65535 : u32))
        (diagnose!
          v
          (InvalidControl)
          "event.export.ordinal"
          ordinal
          "PE export ordinal exceeds u16"))
      (when
        (and
          (= (target-index (& m.target)) 0)
          (!= export.ordinal (cast 0 : u32)))
        (diagnose!
          v
          (InvalidTarget)
          "event.export.ordinal"
          ordinal
          "explicit export ordinal is a PE field"))
      (when
        (and
          (= (target-index (& m.target)) 1)
          (not
            (match export.visibility
              [(n.ExportDefault) true]
              [_ false])))
        (diagnose!
          v
          (InvalidTarget)
          "event.export.visibility"
          ordinal
          "ELF symbol visibility is not representable in PE exports"))
      (require-capability! v p (n.Exports) ordinal)]
    [(n.DefinitionInput path)
      (path! v m p (& path) "event.def" ordinal)
      (require-capability! v p (n.DefinitionFiles) ordinal)
      (when
        (not
          (match path.kind
            [(n.DefinitionFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "event.def.kind"
          ordinal
          "DEF file kind required"))]
    [(n.VersionMapInput path)
      (path! v m p (& path) "event.version-map" ordinal)
      (require-capability! v p (n.VersionMaps) ordinal)
      (when
        (not
          (match path.kind
            [(n.VersionMapFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "event.version-map.kind"
          ordinal
          "version-map file kind required"))]
    [(n.ResourceInput path)
      (path! v m p (& path) "event.resource" ordinal)
      (require-capability! v p (n.Resources) ordinal)
      (when
        (not
          (match path.kind
            [(n.ResourceFile) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "event.resource.kind"
          ordinal
          "resource file kind required"))]
    [(n.SystemImportRequest request)
      (require-capability! v p (n.SystemImports) ordinal)
      (let
        [found : bool false]
        (for [i (iterator.range 0 (array-length (& p.imports)))]
          (when
            (and
              (string.eq (& request.symbol) (& (array-ref p.imports i).symbol))
              (string.eq (& request.dll) (& (array-ref p.imports i).dll)))
            (set! found true)))
        (when
          (not found)
          (diagnose!
            v
            (InvalidImport)
            "event.system-import"
            ordinal
            "symbol/DLL is outside selected profile map")))]
    [(n.ExternalArgument arg)
      (if (> (string.string-length (& arg.argv-element)) limits.max-argv-bytes)
        (diagnose!
          v
          (ResourceLimit)
          "event.external-argument"
          ordinal
          "single argv element exceeds byte limit")
        (for [i (iterator.range 0 (string.string-length (& arg.argv-element)))]
          (when
            (= (cast (string.string-ref (& arg.argv-element) i) : i64) 0)
            (diagnose!
              v
              (InvalidName)
              "event.external-argument"
              ordinal
              "argv element contains NUL"))))
      (when
        (not
          (match m.reproducibility
            [(n.ExplicitExternalCompatibility) true]
            [_ false]))
        (diagnose!
          v
          (InvalidControl)
          "manifest.reproducibility"
          ordinal
          "opaque argv requires explicit external compatibility policy"))]
    [(n.Control control) (control! v m p (& control) ordinal)]))

(define (validate-structure
  [input : (& i n.NativeLinkSemanticInput)]
  [limits : (& l NativeLinkLimits)]) : NativeLinkValidation
  (let
    [v : NativeLinkValidation (new-validation limits)]
    (when (not v.ok) (return v))
    (let
      [preflight : budget.Budget (budget.new (& limits.wire))]
      (budget.observe n.NativeLinkSemanticInput input (&mut preflight))
      (when
        (not preflight.ok)
        (diagnose!
          (&mut v)
          (ResourceLimit)
          "input"
          -1
          "typed input exceeds preflight work or retained budget")
        (return v))
      ;; Quadratic name/identity cross-checks are bounded before traversal;
      ;; byte comparisons additionally account for the full stored text size.
      (let
        [remaining : i64 (- limits.wire.max-work preflight.work)]
        [width : i64 (+ preflight.nodes preflight.strings)]
        (when
          (and (> width 0) (> preflight.nodes (/ remaining width)))
          (diagnose!
            (&mut v)
            (ResourceLimit)
            "validation.work"
            -1
            "identity cross-check budget exceeded")
          (return v))))
    (when
      (> (array-length (& input.manifest.events)) limits.max-events)
      (diagnose!
        (&mut v)
        (ResourceLimit)
        "manifest.events"
        -1
        "event count exceeds explicit limit")
      (return v))
    (let
      [m : (& i n.NativeLinkManifest) (& input.manifest)]
      [p : (& i n.NativeToolchainProfile) (& input.profile)]
      (when
        (or
          (!= m.schema-version (cast 1 : u32))
          (!= m.extension-version (cast 0 : u32)))
        (diagnose!
          (&mut v)
          (InvalidVersion)
          "manifest.version"
          -1
          "v1 accepts no extension records"))
      (when
        (not (target-abi? (clone m.target) (clone m.abi) (& m.target-triple)))
        (diagnose!
          (&mut v)
          (InvalidTarget)
          "manifest.target"
          -1
          "target triple/ABI disagreement"))
      (when
        (not (target-output? (clone m.target) (clone m.output)))
        (diagnose!
          (&mut v)
          (InvalidOutput)
          "manifest.output"
          -1
          "output kind incompatible with target"))
      (check-id! (&mut v) (& m.artifact-id) "manifest.artifact-id" -1)
      (check-id! (&mut v) (& m.profile.id) "manifest.profile.id" -1)
      (content! (&mut v) (& m.profile.content) "manifest.profile.content" -1)
      (when
        (or
          (!= (target-index (& m.target)) (target-index (& p.target)))
          (not (string.eq (& m.target-triple) (& p.target-triple)))
          (not (string.eq (& m.profile.id) (& p.id)))
          (!= m.profile.version p.version))
        (diagnose!
          (&mut v)
          (ProfileMismatch)
          "manifest.profile"
          -1
          "selected profile identity/target differs from resolved profile"))
      (for [i (iterator.range 0 (array-length (& m.roots)))]
        (check-id! (&mut v) (& (array-ref m.roots i).id) "manifest.roots.id" -1)
        (expected-content!
          (&mut v)
          (& (array-ref m.roots i).identity)
          "manifest.roots.identity"
          -1)
        (for [j (iterator.range 0 i)]
          (when
            (string.eq
              (& (array-ref m.roots i).id)
              (& (array-ref m.roots j).id))
            (diagnose!
              (&mut v)
              (DuplicateKey)
              "manifest.roots"
              -1
              "duplicate root id")))
        (for [j (iterator.range 0 (array-length (& p.roots)))]
          (when
            (string.eq
              (& (array-ref m.roots i).id)
              (& (array-ref p.roots j).id))
            (diagnose!
              (&mut v)
              (DuplicateKey)
              "manifest.roots"
              -1
              "root id duplicates profile root"))))
      (let
        [profile-indices : (__tl_dyn-array i64) (profile! (&mut v) m p)]
        [stack : (__tl_dyn-array Scope)
          (__tl_make-array Scope limits.max-nesting)]
        [depth : i64 0]
        [controls : i64 0]
        (for [i (iterator.range 0 (array-length (& m.events)))]
          (when
            (!= (array-ref m.events i).ordinal (cast i : u64))
            (diagnose!
              (&mut v)
              (InvalidEventIdentity)
              "event.ordinal"
              i
              "ordinal differs from ordered vector index"))
          (let
            [expected : String (str_cat.str-cat "e" (string.int->string i))]
            (when
              (not (string.eq (& (array-ref m.events i).id) (& expected)))
              (diagnose!
                (&mut v)
                (InvalidEventIdentity)
                "event.id"
                i
                "event id must be e followed by decimal ordinal")))
          (provenance! (&mut v) m p (& (array-ref m.events i).provenance) i)
          (match (array-ref m.events i).payload
            [(n.BeginGroup id)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 0 id true i))]
            [(n.EndGroup id)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 0 id false i))]
            [(n.BeginWholeArchive id)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 1 id true i))]
            [(n.EndWholeArchive id)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 1 id false i))]
            [(n.BeginPreference id _)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 2 id true i))]
            [(n.EndPreference id)
              (set!
                depth
                (scope-event! (&mut v) (&mut stack) depth 2 id false i))]
            [(n.Control control)
              (let
                [index : i64 (control-index (& control))]
                (when
                  (>= index 0)
                  (let
                    [bit : i64 (shl 1 index)]
                    (when
                      (!= (bit-and controls bit) 0)
                      (diagnose!
                        (&mut v)
                        (ConflictingControl)
                        "event.control"
                        i
                        "unique control or hardening row specified more than once"))
                    (set! controls (bit-or controls bit)))))]
            [_ unit])
          (event!
            (&mut v)
            m
            p
            (& (array-ref m.events i).payload)
            i
            limits
            (& profile-indices)))
        (when
          (!= depth 0)
          (diagnose!
            (&mut v)
            (InvalidScope)
            "manifest.events"
            -1
            "scope remains open at end of event stream"))
        (let
          [required : i64 (bit-or 287 (shl 511 9))]
          (set!
            required
            (bit-or
              required
              (if (= (target-index (& m.target)) 1)
                128
                64)))
          (when
            (match m.output
              [(n.ElfSharedObject) true]
              [_ false])
            (set! required (bit-or required 32)))
          (for [i (iterator.range 0 18)]
            (let
              [bit : i64 (shl 1 i)]
              (when
                (and (!= (bit-and required bit) 0) (= (bit-and controls bit) 0))
                (diagnose!
                  (&mut v)
                  (MissingControl)
                  "manifest.controls"
                  -1
                  (str_cat.str-cat
                    "missing explicit control row "
                    (string.int->string i)))))))))
    v))

;: Profile content identity binds the selected resolved record, not its display
;: id alone. Canonical bytes are a link projection; file/tool content closure
;: observations are admitted separately by the consumers of #7494.
(define (validate
  [input : (& i n.NativeLinkSemanticInput)]
  [limits : (& l NativeLinkLimits)]) : NativeLinkValidation
  (let
    [result : NativeLinkValidation (validate-structure input limits)]
    (when
      result.ok
      (match (codec.profile-identity (& input.profile) (& limits.wire))
        [(codec.NativeDigest identity)
          (let
            [same : bool
              (=
                identity.algorithm-version
                input.manifest.profile.content.algorithm-version)]
            (for [i (iterator.range 0 32)]
              (when
                (!=
                  (array-ref identity.sha256 i)
                  (array-ref input.manifest.profile.content.sha256 i))
                (set! same false)))
            (when
              (not same)
              (diagnose!
                (&mut result)
                (ProfileMismatch)
                "manifest.profile.content"
                -1
                "selected profile digest differs from resolved canonical profile")))
          (when
            (or
              (string.eq
                (& input.profile.id)
                "typelisp-freestanding-linux-x86_64-v1")
              (string.eq
                (& input.profile.id)
                "typelisp-freestanding-windows-x86_64-v1"))
            (let
              [expected : n.NativeToolchainProfile
                (profiles.freestanding-profile
                  (if (string.eq
                    (& input.profile.id)
                    "typelisp-freestanding-linux-x86_64-v1")
                    (n.LinuxX86_64)
                    (n.WindowsX86_64)))]
              (match (codec.profile-identity (& expected) (& limits.wire))
                [(codec.NativeDigest builtin)
                  (let
                    [same : bool true]
                    (for [i (iterator.range 0 32)]
                      (when
                        (!=
                          (array-ref identity.sha256 i)
                          (array-ref builtin.sha256 i))
                        (set! same false)))
                    (when
                      (not same)
                      (diagnose!
                        (&mut result)
                        (ProfileMismatch)
                        "profile.builtin"
                        -1
                        "reserved builtin identity requires the exact v1 profile record")))]
                [_
                  (diagnose!
                    (&mut result)
                    (ResourceLimit)
                    "profile.builtin"
                    -1
                    "builtin profile encoding exceeds explicit limits")])))]
        [_
          (diagnose!
            (&mut result)
            (ResourceLimit)
            "profile.canonical"
            -1
            "profile cannot be encoded within explicit limits")]))
    result))

(defenum NativeBackendChoice
  (InternalBackend)
  (ExternalBackend)
  (AutoBackend))

(defenum NativeRepresentation
  (InternalRepresentationAvailable)
  (ExternalAdapterAdmissionRequired)
  (UnsupportedRepresentation))

(defstruct NativeCapabilityDecision
  (representation NativeRepresentation)
  (validation NativeLinkValidation)
  (requires-content-closure bool)
  (opaque-external-closure bool))

(define (classify
  [input : (& i n.NativeLinkSemanticInput)]
  [choice : NativeBackendChoice]
  [limits : (& l NativeLinkLimits)]) : NativeCapabilityDecision
  (let
    [result : NativeLinkValidation (validate input limits)]
    [opaque : bool false]
    (when
      result.complete
      (for [i (iterator.range 0 (array-length (& input.manifest.events)))]
        (when
          (match (array-ref input.manifest.events i).payload
            [(n.ExternalArgument _) true]
            [_ false])
          (set! opaque true)
          (match choice
            [(InternalBackend)
              (diagnose!
                (&mut result)
                (ExternalOnly)
                "event.external-argument"
                i
                "opaque argv has no internal representation")]
            [(AutoBackend)
              (diagnose!
                (&mut result)
                (AutoCannotPreserve)
                "event.external-argument"
                i
                "auto cannot preserve opaque external semantics")]
            [_ unit]))))
    (NativeCapabilityDecision
      (if (not result.ok)
        (UnsupportedRepresentation)
        (match choice
          [(ExternalBackend) (ExternalAdapterAdmissionRequired)]
          [_ (InternalRepresentationAvailable)]))
      result
      true
      opaque)))