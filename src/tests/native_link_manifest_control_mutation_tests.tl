(import native_link_manifest_types as n)
(import tests.native_link_manifest_mutation_tests as mutations)
(import stdlib.iterator)
(import stdlib.test)

(define (different? [left : n.NativeControl] [right : n.NativeControl]) : bool
  (mutations.payload? (n.Control left) (n.Control right)))

(test
  native-link-every-control-class-sensitive
  (test.assert-true
    (different?
      (n.EntryControl (n.NamedEntry "a"))
      (n.EntryControl (n.NamedEntry "b")))
    "entry")
  (test.assert-true
    (different?
      (n.StartupControl (n.CompilerStartup "a"))
      (n.StartupControl (n.CompilerStartup "b")))
    "startup")
  (test.assert-true
    (different?
      (n.UnresolvedControl (n.RejectUnresolved))
      (n.UnresolvedControl (n.AllowSharedUnresolved)))
    "unresolved policy")
  (test.assert-true
    (different?
      (n.SectionGcControl (n.KeepAllSections))
      (n.SectionGcControl (n.CollectUnusedSections)))
    "section GC")
  (test.assert-true
    (different?
      (n.ExportsControl (n.ExplicitExports))
      (n.ExportsControl (n.ExportAllGlobals)))
    "export policy")
  (test.assert-true
    (different? (n.SonameControl "a") (n.SonameControl "b"))
    "soname")
  (test.assert-true
    (different?
      (n.InterpreterControl (n.ExplicitInterpreter (mutations.path "a")))
      (n.InterpreterControl (n.ExplicitInterpreter (mutations.path "b"))))
    "interpreter path")
  (test.assert-true
    (different?
      (n.RpathControl (mutations.path "a"))
      (n.RpathControl (mutations.path "b")))
    "rpath")
  (test.assert-true
    (different?
      (n.RunpathControl (mutations.path "a"))
      (n.RunpathControl (mutations.path "b")))
    "runpath")
  (let
    [before : n.WindowsImagePolicy
      (n.WindowsImagePolicy
        (n.ConsoleSubsystem)
        (cast 0 : u64)
        (cast 0 : u64)
        (cast 0 : u64)
        (cast 0 : u64)
        (cast 0 : u64)
        (cast 0 : u64)
        (cast 0 : u64))]
    (for [i (iterator.range 0 8)]
      (let
        [after : n.WindowsImagePolicy (clone before)]
        (match i
          [0 (set! after.subsystem (n.GuiSubsystem))]
          [1 (set! after.image-base (cast 1 : u64))]
          [2 (set! after.section-alignment (cast 1 : u64))]
          [3 (set! after.file-alignment (cast 1 : u64))]
          [4 (set! after.stack-reserve (cast 1 : u64))]
          [5 (set! after.stack-commit (cast 1 : u64))]
          [6 (set! after.heap-reserve (cast 1 : u64))]
          [_ (set! after.heap-commit (cast 1 : u64))])
        (test.assert-true
          (different?
            (n.WindowsImageControl before)
            (n.WindowsImageControl after))
          "each image policy field"))))
  (let
    [before : n.DebugPolicy
      (n.DebugPolicy (n.NoDebug) (n.NoBuildId) (n.NoPdb) true)]
    (for [i (iterator.range 0 4)]
      (let
        [after : n.DebugPolicy (clone before)]
        (match i
          [0 (set! after.form (n.DwarfDebug))]
          [1 (set! after.build-id (n.ExplicitBuildId "id"))]
          [2 (set! after.pdb (n.LogicalPdb (mutations.path "a")))]
          [_ (set! after.deterministic false)])
        (test.assert-true
          (different? (n.DebugControl (clone before)) (n.DebugControl after))
          "each debug control field"))))
  (let
    [before : n.HardeningRow
      (n.HardeningRow (n.NoExecute) (n.Off) "schema" "helper")]
    (for [i (iterator.range 0 4)]
      (let
        [after : n.HardeningRow (clone before)]
        (match i
          [0 (set! after.feature (n.Cet))]
          [1 (set! after.requirement (n.Required))]
          [2 (set! after.schema-id "other")]
          [_ (set! after.helper-id "other")])
        (test.assert-true
          (different?
            (n.HardeningControl (clone before))
            (n.HardeningControl after))
          "each hardening control field")))))

(test
  native-link-every-path-content-field-sensitive
  (let
    [before : n.NativePathRef (mutations.path "a")]
    (for [i (iterator.range 0 3)]
      (let
        [after : n.NativePathRef (clone before)]
        (match i
          [0 (set! after.root-id "other")]
          [1 (set! after.relative "other")]
          [_ (set! after.kind (n.StaticArchiveFile))])
        (test.assert-true
          (mutations.payload? (n.FileInput (clone before)) (n.FileInput after))
          "each logical path field"))))
  (let
    [bytes : (Array u8 32) (make-array u8 32)]
    (for [i (iterator.range 0 32)]
      (set! (array-ref bytes i) (cast 0 : u8)))
    (let
      [before : n.ContentIdentity (n.ContentIdentity (cast 1 : u32) bytes)]
      (for [i (iterator.range 0 2)]
        (let
          [after : n.ContentIdentity (clone before)]
          (if (= i 0)
            (set! after.algorithm-version (cast 2 : u32))
            (set! (array-ref after.sha256 31) (cast 1 : u8)))
          (test.assert-true
            (mutations.payload?
              (n.FileInput
                (n.NativePathRef
                  "root"
                  "a"
                  (n.ObjectFile)
                  (n.ExactContent (clone before))))
              (n.FileInput
                (n.NativePathRef
                  "root"
                  "a"
                  (n.ObjectFile)
                  (n.ExactContent after))))
            "each exact path content field"))))))