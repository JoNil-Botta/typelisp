;; Raw codec sensitivity is distinct from semantic admission: this fixture
;; populates sealed-profile fields that the builtin deliberately leaves empty.
(import native_link_manifest_types as n)
(import tests.native_link_manifest_test_support as support)
(import tests.native_link_manifest_mutation_tests as mutations)
(import stdlib.iterator)
(import stdlib.format)
(import stdlib.test)

(define (content) : n.ContentIdentity
  (let
    [bytes : (Array u8 32) (make-array u8 32)]
    (for [i (iterator.range 0 32)]
      (set! (array-ref bytes i) (cast 0 : u8)))
    (n.ContentIdentity (cast 1 : u32) bytes)))

(define (path) : n.NativePathRef
  (n.NativePathRef
    "profile-root"
    "crt.o"
    (n.ObjectFile)
    (n.ExactContent (content))))

(define (fixture) : n.NativeLinkSemanticInput
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    (set! input.manifest.roots (__tl_make-array n.LogicalRoot 1))
    (set!
      (array-ref input.manifest.roots 0)
      (n.LogicalRoot "manifest-root" (n.ExactContent (content))))
    (set! input.profile.roots (__tl_make-array n.LogicalRoot 1))
    (set!
      (array-ref input.profile.roots 0)
      (n.LogicalRoot "profile-root" (n.ExactContent (content))))
    (set! input.profile.files (__tl_make-array n.ProfileFile 1))
    (set! (array-ref input.profile.files 0) (n.ProfileFile "startup" (path)))
    (set! input.profile.inputs (__tl_make-array n.ProfileInput 1))
    (set!
      (array-ref input.profile.inputs 0)
      (n.ProfileInput
        (n.StartupInput)
        "startup"
        (n.ProfileRowOrigin (clone input.profile.id) "startup" (cast 0 : u64))))
    (set! input.profile.imports (__tl_make-array n.SystemImport 1))
    (set!
      (array-ref input.profile.imports 0)
      (n.SystemImport "ExitProcess" "kernel32.dll"))
    input))

(test
  native-link-every-manifest-and-profile-field-sensitive
  (let
    [before : n.NativeLinkSemanticInput (fixture)]
    (for [i (iterator.range 0 64)]
      (let
        [after : n.NativeLinkSemanticInput (clone before)]
        (match i
          [0 (set! after.manifest.schema-version (cast 2 : u32))]
          [1 (set! after.manifest.extension-version (cast 1 : u32))]
          [2 (set! after.manifest.target (n.WindowsX86_64))]
          [3 (set! after.manifest.target-triple "x86_64-unknown-linux-musl")]
          [4 (set! after.manifest.abi (n.WindowsAMD64))]
          [5 (set! after.manifest.output (n.Relocatable))]
          [6 (set! after.manifest.artifact-id "another.app")]
          [7 (set! after.manifest.profile.id "another.profile")]
          [8 (set! after.manifest.profile.version (cast 2 : u32))]
          [9
            (set!
              after.manifest.profile.content.algorithm-version
              (cast 2 : u32))]
          [10
            (set!
              (array-ref after.manifest.profile.content.sha256 31)
              (cast 255 : u8))]
          [11
            (set!
              after.manifest.reproducibility
              (n.ExplicitExternalCompatibility))]
          [12 (set! (array-ref after.manifest.roots 0).id "other-root")]
          [13
            (set!
              (array-ref after.manifest.roots 0).identity
              (n.UnspecifiedContent))]
          [14
            (set! (array-ref after.manifest.events 0).ordinal (cast 100 : u64))]
          [15 (set! (array-ref after.manifest.events 0).id "different-id")]
          [16 (set! after.profile.schema-version (cast 2 : u32))]
          [17 (set! after.profile.extension-version (cast 1 : u32))]
          [18 (set! after.profile.id "sealed.profile")]
          [19 (set! after.profile.version (cast 2 : u32))]
          [20 (set! after.profile.target (n.WindowsX86_64))]
          [21 (set! after.profile.target-triple "x86_64-unknown-linux-musl")]
          [22 (set! after.profile.abi (n.WindowsAMD64))]
          [23 (set! after.profile.runtime (n.GlibcRuntime))]
          [24 (set! after.profile.runtime-floor.major (cast 1 : u32))]
          [25 (set! after.profile.runtime-floor.minor (cast 1 : u32))]
          [26 (set! after.profile.runtime-floor.patch (cast 1 : u32))]
          [27 (set! (array-ref after.profile.outputs 0) (n.PeDll))]
          [28 (set! (array-ref after.profile.roots 0).id "different-root")]
          [29
            (set!
              (array-ref after.profile.roots 0).identity
              (n.UnspecifiedContent))]
          [30 (set! (array-ref after.profile.files 0).id "other-file")]
          [31
            (set! (array-ref after.profile.files 0).path.root-id "another-root")]
          [32
            (set! (array-ref after.profile.files 0).path.relative "another.o")]
          [33
            (set! (array-ref after.profile.files 0).path.kind (n.RuntimeFile))]
          [34
            (set!
              (array-ref after.profile.files 0).path.content
              (n.UnspecifiedContent))]
          [35 (set! (array-ref after.profile.inputs 0).position (n.EndInput))]
          [36 (set! (array-ref after.profile.inputs 0).file-id "another-file")]
          [37
            (set!
              (array-ref after.profile.inputs 0).provenance
              (n.CompilerRuntimeOrigin "crt" (cast 1 : u64)))]
          [38
            (set!
              (array-ref after.profile.runtime-identities 0)
              "another-runtime")]
          [39 (set! after.profile.entry (n.CompilerEntry "another-entry"))]
          [40
            (set! after.profile.startup (n.CompilerStartup "another-startup"))]
          [41 (set! after.profile.windows.subsystem (n.ConsoleSubsystem))]
          [42 (set! after.profile.windows.image-base (cast 1 : u64))]
          [43 (set! after.profile.windows.section-alignment (cast 1 : u64))]
          [44 (set! after.profile.windows.file-alignment (cast 1 : u64))]
          [45 (set! after.profile.windows.stack-reserve (cast 1 : u64))]
          [46 (set! after.profile.windows.stack-commit (cast 1 : u64))]
          [47 (set! after.profile.windows.heap-reserve (cast 1 : u64))]
          [48 (set! after.profile.windows.heap-commit (cast 1 : u64))]
          [49 (set! after.profile.interpreter (n.ExplicitInterpreter (path)))]
          [50 (set! (array-ref after.profile.imports 0).symbol "WriteFile")]
          [51 (set! (array-ref after.profile.imports 0).dll "ntdll.dll")]
          [52 (set! after.profile.debug.form (n.DwarfDebug))]
          [53 (set! after.profile.debug.build-id (n.ExplicitBuildId "id"))]
          [54 (set! after.profile.debug.pdb (n.LogicalPdb (path)))]
          [55 (set! after.profile.debug.deterministic false)]
          [56
            (set!
              (array-ref after.profile.capabilities 0).kind
              (n.SharedInputs))]
          [57
            (set!
              (array-ref after.profile.capabilities 0).support
              (n.Unsupported (n.NotImplemented)))]
          [58
            (set!
              (array-ref after.profile.capabilities 0).schema-id
              "another-schema")]
          [59
            (set!
              (array-ref after.profile.capabilities 0).helper-id
              "another-helper")]
          [60 (set! (array-ref after.profile.hardening 0).feature (n.Cet))]
          [61
            (set!
              (array-ref after.profile.hardening 0).requirement
              (n.Required))]
          [62
            (set!
              (array-ref after.profile.hardening 0).schema-id
              "another-schema")]
          [_
            (set!
              (array-ref after.profile.hardening 0).helper-id
              "another-helper")])
        (test.assert-true
          (mutations.different? (& before) (& after))
          (format.format "record field {} must affect canonical bytes" i))))))