(import native_link_manifest_types as n)
(import native_link_manifest_builder as builder)
(import native_link_manifest_core as core)
(import tests.native_link_manifest_test_support as support)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)

(define (path [kind : n.NativeFileKind] [relative : String]) : n.NativePathRef
  (n.NativePathRef "workspace" relative kind (n.UnspecifiedContent)))

(test
  native-link-identical-payloads-retain-all-origin-classes
  (let
    [input : n.NativeLinkSemanticInput (support.sample false)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [events : builder.NativeEventBuilder (builder.event-builder 23)]
    [origins : (__tl_dyn-array n.NativeLinkProvenance)
      (__tl_make-array n.NativeLinkProvenance 7)]
    [roots : (__tl_dyn-array n.LogicalRoot) (__tl_make-array n.LogicalRoot 1)]
    (set!
      (array-ref roots 0)
      (n.LogicalRoot "workspace" (n.UnspecifiedContent)))
    (set! (array-ref origins 0) (n.CommandLineOrigin (cast 0 : u64)))
    (set!
      (array-ref origins 1)
      (n.SourceOrigin
        "src.main"
        "foreign"
        (n.SourceSpan (cast 1 : u64) (cast 2 : u64))))
    (set!
      (array-ref origins 2)
      (n.PackageOrigin
        (path (n.PackageManifestFile) "typelisp.pkg")
        "app"
        "objects"
        (cast 0 : u64)))
    (set!
      (array-ref origins 3)
      (n.DependencyOrigin
        "app"
        "dep"
        (path (n.PackageManifestFile) "dep/typelisp.pkg")
        "objects"
        (cast 0 : u64)))
    (set!
      (array-ref origins 4)
      (n.ArtifactOrigin "artifact" "export" (cast 0 : u64)))
    (set!
      (array-ref origins 5)
      (n.ObjectDirectiveOrigin
        (path (n.ObjectFile) "directive.o")
        (cast 0 : u64)))
    (set!
      (array-ref origins 6)
      (n.CompilerRuntimeOrigin "typelisp.runtime.v1" (cast 0 : u64)))
    (builder.append-profile-controls!
      (&mut events)
      (& input.profile)
      (& input.manifest.output))
    (for [i (iterator.range 0 7)]
      (builder.append!
        (&mut events)
        (clone (array-ref origins i))
        (n.FileInput (path (n.ObjectFile) "same.o"))))
    (match (builder.finish
      events
      (& input.profile)
      (clone input.manifest.output)
      "app"
      roots
      (n.HermeticInputs)
      (& limits))
      [(builder.BuiltManifest value)
        (set! input.manifest value)
        (let
          [validation : core.NativeLinkValidation
            (core.validate (& input) (& limits))]
          (test.assert-true
            validation.ok
            "all seven provenance classes admitted")
          (test.assert-i64-eq
            (array-length input.manifest.events)
            23
            "duplicates remain seven distinct ordered events")
          (for [i (iterator.range 0 7)]
            (let
              [event : (& i n.NativeLinkEvent)
                (& (array-ref input.manifest.events (+ i 16)))]
              (test.assert-true
                (= event.ordinal (cast (+ i 16) : u64))
                "deterministic original ordinal")
              (test.assert-true
                (match event.payload
                  [(n.FileInput p) (string.eq (& p.relative) "same.o")]
                  [_ false])
                "equal file payload retained"))))]
      [_ (test.assert-true false "builder must finish")])))

(test
  native-link-dependency-requirements-one-linux-group
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [rows : (__tl_dyn-array builder.NativeDependencyRequirement)
      (__tl_make-array builder.NativeDependencyRequirement 4)]
    [linux : builder.NativeEventBuilder (builder.event-builder 6)]
    [windows : builder.NativeEventBuilder (builder.event-builder 4)]
    (for [i (iterator.range 0 4)]
      (set!
        (array-ref rows i)
        (builder.NativeDependencyRequirement
          "app"
          "dep"
          (path (n.PackageManifestFile) "dep/typelisp.pkg")
          "linux-libraries"
          (cast i : u64)
          (match i
            [0 (builder.RequirementLibrary "m")]
            [1 (builder.RequirementSearchRoot "sdk")]
            [2
              (builder.RequirementExternalArgument
                (n.ExternalCompatibilityArg "-Wl,--literal @x"))]
            [_
              (builder.RequirementArchive
                (path (n.StaticArchiveFile) "dep/libdep.a"))]))))
    (builder.append-dependency-requirements!
      (&mut linux)
      (n.LinuxX86_64)
      (& rows)
      (cast 9 : u64)
      (n.CompilerRuntimeOrigin "dependency-group" (cast 0 : u64))
      (& limits))
    (builder.append-dependency-requirements!
      (&mut windows)
      (n.WindowsX86_64)
      (& rows)
      (cast 9 : u64)
      (n.CompilerRuntimeOrigin "dependency-group" (cast 0 : u64))
      (& limits))
    (test.assert-true
      (and linux.ok windows.ok (= linux.count 6) (= windows.count 4))
      "Linux has exactly one surrounding group")
    (test.assert-true
      (match (array-ref linux.slots 0).payload
        [(n.BeginGroup id) (= id (cast 9 : u64))]
        [_ false])
      "begin group")
    (test.assert-true
      (match (array-ref linux.slots 5).payload
        [(n.EndGroup id) (= id (cast 9 : u64))]
        [_ false])
      "end group")
    (test.assert-true
      (match (array-ref linux.slots 4).payload
        [(n.FileInput p)
          (match p.kind
            [(n.StaticArchiveFile) true]
            [_ false])]
        [_ false])
      "archive has its own typed input class")
    (for [i (iterator.range 0 4)]
      (test.assert-true
        (match (array-ref linux.slots (+ i 1)).provenance
          [(n.DependencyOrigin from to manifest field index)
            (and
              (string.eq (& from) "app")
              (string.eq (& to) "dep")
              (string.eq (& manifest.relative) "dep/typelisp.pkg")
              (string.eq (& field) "linux-libraries")
              (= index (cast i : u64)))]
          [_ false])
        "each input retains the declaring package, manifest, field and index"))))

(test
  native-link-dependency-archive-cannot-change-input-class
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [rows : (__tl_dyn-array builder.NativeDependencyRequirement)
      (__tl_make-array builder.NativeDependencyRequirement 1)]
    [events : builder.NativeEventBuilder (builder.event-builder 3)]
    (set!
      (array-ref rows 0)
      (builder.NativeDependencyRequirement
        "app"
        "dep"
        (path (n.PackageManifestFile) "typelisp.pkg")
        "archives"
        (cast 0 : u64)
        (builder.RequirementArchive (path (n.ObjectFile) "not-an-archive.o"))))
    (builder.append-dependency-requirements!
      (&mut events)
      (n.LinuxX86_64)
      (& rows)
      (cast 1 : u64)
      (n.CompilerRuntimeOrigin "dependency-group" (cast 0 : u64))
      (& limits))
    (test.assert-false
      events.ok
      "archive requirement cannot silently become an object input")
    (test.assert-true
      (string.eq
        (& events.error)
        "dependency archive requires StaticArchiveFile kind")
      "builder retains the first precise error")))