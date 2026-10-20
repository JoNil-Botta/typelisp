;# Compiler-owned freestanding data only. No probing, SDK paths, import
;# archives, libc or CRT defaults. A capability names an admitted semantic
;# contract; it does not certify a particular writer or final image.
(import native_link_manifest_types as n)

(define (freestanding-profile [target : n.NativeTarget]) : n.NativeToolchainProfile
  (let
    [windows : bool
      (match (& target)
        [(n.WindowsX86_64) true]
        [_ false])]
    [outputs : (__tl_dyn-array n.NativeOutputKind)
      (__tl_make-array n.NativeOutputKind 3)]
    [runtime : (__tl_dyn-array String) (__tl_make-array String 3)]
    [capabilities : (__tl_dyn-array n.CapabilityRow)
      (__tl_make-array n.CapabilityRow 34)]
    [hardening : (__tl_dyn-array n.HardeningRow)
      (__tl_make-array n.HardeningRow 9)]
    [imports : (__tl_dyn-array n.SystemImport)
      (__tl_make-array
        n.SystemImport
        (if windows
          12
          0))]
    (set! (array-ref outputs 0) (n.Relocatable))
    (set! (array-ref outputs 1) (n.StaticArchive))
    (set! (array-ref outputs 2) (n.FreestandingStaticExecutable))
    (set! (array-ref runtime 0) "typelisp.compiler-startup.v1")
    (set! (array-ref runtime 1) "typelisp.runtime.v1")
    (set!
      (array-ref runtime 2)
      (if windows
        "typelisp.windows-system-imports.v1"
        "typelisp.linux-syscalls.v1"))
    (set!
      (array-ref capabilities 0)
      (n.CapabilityRow
        (n.ObjectInputs)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 1)
      (n.CapabilityRow
        (n.ArchiveInputs)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 2)
      (n.CapabilityRow
        (n.SharedInputs)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 3)
      (n.CapabilityRow
        (n.ImportLibraryInputs)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 4)
      (n.CapabilityRow
        (n.LibrarySearch)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 5)
      (n.CapabilityRow
        (n.Groups)
        (if windows
          (n.Unsupported (n.TargetMismatch))
          (n.Supported (n.Implemented)))
        "typelisp.native-link.capability.v1"
        (if windows
          ""
          "typelisp.runtime.v1")))
    (set!
      (array-ref capabilities 6)
      (n.CapabilityRow
        (n.WholeArchive)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 7)
      (n.CapabilityRow
        (n.StaticDynamicPreference)
        (if windows
          (n.Unsupported (n.TargetMismatch))
          (n.Supported (n.Implemented)))
        "typelisp.native-link.capability.v1"
        (if windows
          ""
          "typelisp.runtime.v1")))
    (set!
      (array-ref capabilities 8)
      (n.CapabilityRow
        (n.DefaultLibraries)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 9)
      (n.CapabilityRow
        (n.Directives)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 10)
      (n.CapabilityRow
        (n.Exports)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 11)
      (n.CapabilityRow
        (n.DefinitionFiles)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 12)
      (n.CapabilityRow
        (n.VersionMaps)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 13)
      (n.CapabilityRow
        (n.Resources)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 14)
      (n.CapabilityRow
        (n.Tls)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 15)
      (n.CapabilityRow
        (n.Ifunc)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 16)
      (n.CapabilityRow
        (n.Constructors)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 17)
      (n.CapabilityRow
        (n.Unwind)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 18)
      (n.CapabilityRow
        (n.Dwarf)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 19)
      (n.CapabilityRow
        (n.CodeView)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 20)
      (n.CapabilityRow
        (n.Relocations)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 21)
      (n.CapabilityRow
        (n.DelayLoad)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 22)
      (n.CapabilityRow
        (n.ExternalArguments)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 23)
      (n.CapabilityRow
        (n.RuntimeHelpers)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 24)
      (n.CapabilityRow
        (n.SystemImports)
        (if windows
          (n.Supported (n.Implemented))
          (n.Unsupported (n.TargetMismatch)))
        "typelisp.native-link.capability.v1"
        (if windows
          "typelisp.windows-system-imports.v1"
          "")))
    (set!
      (array-ref capabilities 25)
      (n.CapabilityRow
        (n.OutputRelocatable)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 26)
      (n.CapabilityRow
        (n.OutputFreestandingStatic)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 27)
      (n.CapabilityRow
        (n.OutputStatic)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 28)
      (n.CapabilityRow
        (n.OutputStaticPie)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 29)
      (n.CapabilityRow
        (n.OutputPie)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 30)
      (n.CapabilityRow
        (n.OutputArchive)
        (n.Supported (n.Implemented))
        "typelisp.native-link.capability.v1"
        "typelisp.runtime.v1"))
    (set!
      (array-ref capabilities 31)
      (n.CapabilityRow
        (n.OutputElfDso)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 32)
      (n.CapabilityRow
        (n.OutputPeDll)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref capabilities 33)
      (n.CapabilityRow
        (n.OutputImportLibrary)
        (n.Unsupported (n.RequiresTargetConsumer))
        "typelisp.native-link.capability.v1"
        ""))
    (set!
      (array-ref hardening 0)
      (n.HardeningRow
        (n.PositionIndependent)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 1)
      (n.HardeningRow
        (n.AddressRandomization)
        (if windows
          (n.Forbidden)
          (n.Off))
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 2)
      (n.HardeningRow
        (n.NoExecute)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 3)
      (n.HardeningRow
        (n.NonExecutableStack)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 4)
      (n.HardeningRow (n.Relro) (n.Off) "typelisp.native-link.hardening.v1" ""))
    (set!
      (array-ref hardening 5)
      (n.HardeningRow
        (n.ControlFlowGuard)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 6)
      (n.HardeningRow (n.Cet) (n.Off) "typelisp.native-link.hardening.v1" ""))
    (set!
      (array-ref hardening 7)
      (n.HardeningRow
        (n.EhContinuation)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (set!
      (array-ref hardening 8)
      (n.HardeningRow
        (n.StackProtector)
        (n.Off)
        "typelisp.native-link.hardening.v1"
        ""))
    (when
      windows
      (set!
        (array-ref imports 0)
        (n.SystemImport "ConvertThreadToFiber" "kernel32.dll"))
      (set!
        (array-ref imports 1)
        (n.SystemImport "CreateFiberEx" "kernel32.dll"))
      (set! (array-ref imports 2) (n.SystemImport "ExitProcess" "kernel32.dll"))
      (set!
        (array-ref imports 3)
        (n.SystemImport "GetCommandLineA" "kernel32.dll"))
      (set!
        (array-ref imports 4)
        (n.SystemImport "GetStdHandle" "kernel32.dll"))
      (set!
        (array-ref imports 5)
        (n.SystemImport "SetThreadStackGuarantee" "kernel32.dll"))
      (set!
        (array-ref imports 6)
        (n.SystemImport "SetUnhandledExceptionFilter" "kernel32.dll"))
      (set!
        (array-ref imports 7)
        (n.SystemImport "SwitchToFiber" "kernel32.dll"))
      (set! (array-ref imports 8) (n.SystemImport "WriteFile" "kernel32.dll"))
      (set!
        (array-ref imports 9)
        (n.SystemImport "VirtualAlloc" "kernel32.dll"))
      (set!
        (array-ref imports 10)
        (n.SystemImport "VirtualFree" "kernel32.dll"))
      (set! (array-ref imports 11) (n.SystemImport "NtCreateFile" "ntdll.dll")))
    (n.NativeToolchainProfile
      (cast 1 : u32)
      (cast 0 : u32)
      (if windows
        "typelisp-freestanding-windows-x86_64-v1"
        "typelisp-freestanding-linux-x86_64-v1")
      (cast 1 : u32)
      target
      (if windows
        "x86_64-pc-windows-msvc"
        "x86_64-unknown-linux-gnu")
      (if windows
        (n.WindowsAMD64)
        (n.SysVAMD64))
      (n.CompilerFreestanding)
      (n.RuntimeVersion (cast 0 : u32) (cast 0 : u32) (cast 0 : u32))
      outputs
      (__tl_make-array n.LogicalRoot 0)
      (__tl_make-array n.ProfileFile 0)
      (__tl_make-array n.ProfileInput 0)
      runtime
      (n.CompilerEntry "_tl_start")
      (n.CompilerStartup "typelisp.compiler-startup.v1")
      (if windows
        (n.WindowsImagePolicy
          (n.ConsoleSubsystem)
          (cast 5368709120 : u64)
          (cast 4096 : u64)
          (cast 512 : u64)
          (cast 268435456 : u64)
          (cast 4096 : u64)
          (cast 1048576 : u64)
          (cast 4096 : u64))
        (n.WindowsImagePolicy
          (n.NoWindowsSubsystem)
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 0 : u64)))
      (n.NoInterpreter)
      imports
      (n.DebugPolicy (n.NoDebug) (n.NoBuildId) (n.NoPdb) true)
      capabilities
      hardening)))