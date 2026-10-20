(import native_link_manifest_types as n)
(import native_link_manifest_core as core)
(import native_link_manifest_codec as codec)
(import tests.native_link_manifest_test_support as support)
(import stdlib.test)
(import stdlib.iterator)

(define (different?
  [a : (& a n.NativeLinkSemanticInput)]
  [b : (& b n.NativeLinkSemanticInput)]) : bool
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (match (codec.encode-input-record a (& limits.wire))
      [(codec.NativeBytes left)
        (match (codec.encode-input-record b (& limits.wire))
          [(codec.NativeBytes right)
            (not (codec.bytes-equal? (& left) (& right)))]
          [_ false])]
      [_ false])))

(define (payload? [a : n.NativeEventPayload] [b : n.NativeEventPayload]) : bool
  (let
    [left : n.NativeLinkSemanticInput (support.sample false)]
    [right : n.NativeLinkSemanticInput (clone left)]
    (set! (array-ref left.manifest.events 0).payload a)
    (set! (array-ref right.manifest.events 0).payload b)
    (different? (& left) (& right))))

(define (origin? [a : n.NativeLinkProvenance] [b : n.NativeLinkProvenance]) : bool
  (let
    [left : n.NativeLinkSemanticInput (support.sample false)]
    [right : n.NativeLinkSemanticInput (clone left)]
    (set! (array-ref left.manifest.events 0).provenance a)
    (set! (array-ref right.manifest.events 0).provenance b)
    (different? (& left) (& right))))

(define (path [name : String]) : n.NativePathRef
  (n.NativePathRef "root" name (n.ObjectFile) (n.UnspecifiedContent)))

(test
  native-link-every-event-payload-class-sensitive
  (test.assert-true
    (payload? (n.FileInput (path "a")) (n.FileInput (path "b")))
    "file path")
  (test.assert-true
    (payload? (n.LibraryLookup "a") (n.LibraryLookup "b"))
    "library")
  (test.assert-true
    (payload? (n.SearchRoot "a") (n.SearchRoot "b"))
    "search root")
  (test.assert-true
    (payload? (n.BeginGroup (cast 1 : u64)) (n.BeginGroup (cast 2 : u64)))
    "group begin")
  (test.assert-true
    (payload? (n.EndGroup (cast 1 : u64)) (n.EndGroup (cast 2 : u64)))
    "group end")
  (test.assert-true
    (payload?
      (n.BeginWholeArchive (cast 1 : u64))
      (n.BeginWholeArchive (cast 2 : u64)))
    "whole archive begin")
  (test.assert-true
    (payload?
      (n.EndWholeArchive (cast 1 : u64))
      (n.EndWholeArchive (cast 2 : u64)))
    "whole archive end")
  (test.assert-true
    (payload?
      (n.BeginPreference (cast 1 : u64) (n.PreferStatic))
      (n.BeginPreference (cast 2 : u64) (n.PreferStatic)))
    "preference scope id")
  (test.assert-true
    (payload?
      (n.BeginPreference (cast 1 : u64) (n.PreferStatic))
      (n.BeginPreference (cast 1 : u64) (n.PreferDynamic)))
    "preference kind")
  (test.assert-true
    (payload? (n.EndPreference (cast 1 : u64)) (n.EndPreference (cast 2 : u64)))
    "preference end")
  (test.assert-true
    (payload? (n.ForcedUndefined "a") (n.ForcedUndefined "b"))
    "undefined root")
  (test.assert-true
    (payload?
      (n.RetainedRoot (n.RetainSymbol) "a")
      (n.RetainedRoot (n.RetainSymbol) "b"))
    "retained name")
  (test.assert-true
    (payload?
      (n.RetainedRoot (n.RetainSymbol) "a")
      (n.RetainedRoot (n.RetainSection) "a"))
    "retention kind")
  (test.assert-true
    (payload?
      (n.DefaultLibrary (n.InsertDefaultLibrary) "a")
      (n.DefaultLibrary (n.SuppressDefaultLibrary) "a"))
    "default library action")
  (test.assert-true
    (payload?
      (n.DefaultLibrary (n.InsertDefaultLibrary) "a")
      (n.DefaultLibrary (n.InsertDefaultLibrary) "b"))
    "default library name")
  (test.assert-true
    (payload?
      (n.ProfileFileInput (n.StartupInput) (path "a"))
      (n.ProfileFileInput (n.EndInput) (path "a")))
    "profile input position")
  (test.assert-true
    (payload?
      (n.ProfileFileInput (n.StartupInput) (path "a"))
      (n.ProfileFileInput (n.StartupInput) (path "b")))
    "profile file")
  (test.assert-true
    (payload? (n.RuntimeRoot "a") (n.RuntimeRoot "b"))
    "runtime root")
  (test.assert-true
    (payload? (n.DefinitionInput (path "a")) (n.DefinitionInput (path "b")))
    "definition")
  (test.assert-true
    (payload? (n.VersionMapInput (path "a")) (n.VersionMapInput (path "b")))
    "version map")
  (test.assert-true
    (payload? (n.ResourceInput (path "a")) (n.ResourceInput (path "b")))
    "resource")
  (test.assert-true
    (payload?
      (n.ExternalArgument (n.ExternalCompatibilityArg "a"))
      (n.ExternalArgument (n.ExternalCompatibilityArg "b")))
    "opaque argv")
  (test.assert-true
    (payload?
      (n.SystemImportRequest (n.SystemImport "a" "x.dll"))
      (n.SystemImportRequest (n.SystemImport "b" "x.dll")))
    "import symbol")
  (test.assert-true
    (payload?
      (n.SystemImportRequest (n.SystemImport "a" "x.dll"))
      (n.SystemImportRequest (n.SystemImport "a" "y.dll")))
    "import DLL"))

(test
  native-link-every-provenance-field-sensitive
  (let
    [one : u64 (cast 1 : u64)]
    [two : u64 (cast 2 : u64)]
    [span : n.SourceSpan (n.SourceSpan (cast 1 : u64) (cast 2 : u64))]
    (test.assert-true
      (origin? (n.CommandLineOrigin one) (n.CommandLineOrigin two))
      "CLI ordinal")
    (test.assert-true
      (origin? (n.SourceOrigin "a" "d" span) (n.SourceOrigin "b" "d" span))
      "source module")
    (test.assert-true
      (origin? (n.SourceOrigin "a" "d" span) (n.SourceOrigin "a" "e" span))
      "source declaration")
    (test.assert-true
      (origin?
        (n.SourceOrigin "a" "d" span)
        (n.SourceOrigin "a" "d" (n.SourceSpan two two)))
      "span start")
    (test.assert-true
      (origin?
        (n.SourceOrigin "a" "d" span)
        (n.SourceOrigin "a" "d" (n.SourceSpan one one)))
      "span length")
    (test.assert-true
      (origin?
        (n.PackageOrigin (path "a") "p" "f" one)
        (n.PackageOrigin (path "b") "p" "f" one))
      "package manifest")
    (test.assert-true
      (origin?
        (n.PackageOrigin (path "a") "p" "f" one)
        (n.PackageOrigin (path "a") "q" "f" one))
      "package key")
    (test.assert-true
      (origin?
        (n.PackageOrigin (path "a") "p" "f" one)
        (n.PackageOrigin (path "a") "p" "g" one))
      "package field")
    (test.assert-true
      (origin?
        (n.PackageOrigin (path "a") "p" "f" one)
        (n.PackageOrigin (path "a") "p" "f" two))
      "package index")
    (test.assert-true
      (origin?
        (n.DependencyOrigin "a" "b" (path "m") "f" one)
        (n.DependencyOrigin "c" "b" (path "m") "f" one))
      "dependency from")
    (test.assert-true
      (origin?
        (n.DependencyOrigin "a" "b" (path "m") "f" one)
        (n.DependencyOrigin "a" "c" (path "m") "f" one))
      "dependency to")
    (test.assert-true
      (origin?
        (n.DependencyOrigin "a" "b" (path "m") "f" one)
        (n.DependencyOrigin "a" "b" (path "n") "f" one))
      "dependency manifest")
    (test.assert-true
      (origin?
        (n.DependencyOrigin "a" "b" (path "m") "f" one)
        (n.DependencyOrigin "a" "b" (path "m") "g" one))
      "dependency field")
    (test.assert-true
      (origin?
        (n.DependencyOrigin "a" "b" (path "m") "f" one)
        (n.DependencyOrigin "a" "b" (path "m") "f" two))
      "dependency index")
    (test.assert-true
      (origin? (n.ArtifactOrigin "a" "e" one) (n.ArtifactOrigin "b" "e" one))
      "artifact")
    (test.assert-true
      (origin? (n.ArtifactOrigin "a" "e" one) (n.ArtifactOrigin "a" "f" one))
      "artifact export")
    (test.assert-true
      (origin? (n.ArtifactOrigin "a" "e" one) (n.ArtifactOrigin "a" "e" two))
      "artifact index")
    (test.assert-true
      (origin?
        (n.ObjectDirectiveOrigin (path "a") one)
        (n.ObjectDirectiveOrigin (path "b") one))
      "directive object")
    (test.assert-true
      (origin?
        (n.ObjectDirectiveOrigin (path "a") one)
        (n.ObjectDirectiveOrigin (path "a") two))
      "directive index")
    (test.assert-true
      (origin?
        (n.ProfileRowOrigin "a" "r" one)
        (n.ProfileRowOrigin "b" "r" one))
      "profile id")
    (test.assert-true
      (origin?
        (n.ProfileRowOrigin "a" "r" one)
        (n.ProfileRowOrigin "a" "s" one))
      "profile row")
    (test.assert-true
      (origin?
        (n.ProfileRowOrigin "a" "r" one)
        (n.ProfileRowOrigin "a" "r" two))
      "profile index")
    (test.assert-true
      (origin?
        (n.CompilerRuntimeOrigin "a" one)
        (n.CompilerRuntimeOrigin "b" one))
      "compiler runtime")
    (test.assert-true
      (origin?
        (n.CompilerRuntimeOrigin "a" one)
        (n.CompilerRuntimeOrigin "a" two))
      "runtime synthesis index")))

(test
  native-link-export-and-directive-fields-sensitive
  (test.assert-true
    (payload?
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportDefault)))
      (n.Export (n.NativeExport "c" "b" (cast 1 : u32) false (n.ExportDefault))))
    "export name")
  (test.assert-true
    (payload?
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportDefault)))
      (n.Export (n.NativeExport "a" "c" (cast 1 : u32) false (n.ExportDefault))))
    "export alias")
  (test.assert-true
    (payload?
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportDefault)))
      (n.Export (n.NativeExport "a" "b" (cast 2 : u32) false (n.ExportDefault))))
    "export ordinal")
  (test.assert-true
    (payload?
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportDefault)))
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) true (n.ExportDefault))))
    "export data")
  (test.assert-true
    (payload?
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportDefault)))
      (n.Export (n.NativeExport "a" "b" (cast 1 : u32) false (n.ExportHidden))))
    "export visibility")
  (test.assert-true
    (payload?
      (n.Directive (n.IncludeDirective "a"))
      (n.Directive (n.IncludeDirective "b")))
    "include symbol")
  (test.assert-true
    (payload?
      (n.Directive (n.AliasDirective "a" "b"))
      (n.Directive (n.AliasDirective "c" "b")))
    "alias source")
  (test.assert-true
    (payload?
      (n.Directive (n.AliasDirective "a" "b"))
      (n.Directive (n.AliasDirective "a" "c")))
    "alias target")
  (test.assert-true
    (payload?
      (n.Directive (n.AlternateNameDirective "a" "b"))
      (n.Directive (n.AlternateNameDirective "c" "b")))
    "alternate source")
  (test.assert-true
    (payload?
      (n.Directive (n.AlternateNameDirective "a" "b"))
      (n.Directive (n.AlternateNameDirective "a" "c")))
    "alternate target")
  (test.assert-true
    (payload?
      (n.Directive (n.MergeSectionDirective "a" "b"))
      (n.Directive (n.MergeSectionDirective "c" "b")))
    "merge source")
  (test.assert-true
    (payload?
      (n.Directive (n.MergeSectionDirective "a" "b"))
      (n.Directive (n.MergeSectionDirective "a" "c")))
    "merge destination")
  (let
    [attributes : n.NativeSectionAttributes
      (n.NativeSectionAttributes false false false false false)]
    (test.assert-true
      (payload?
        (n.Directive (n.SectionAttributesDirective "a" attributes))
        (n.Directive (n.SectionAttributesDirective "b" attributes)))
      "section name")
    (for [i (iterator.range 0 5)]
      (let
        [after : n.NativeSectionAttributes (clone attributes)]
        (match i
          [0 (set! after.read true)]
          [1 (set! after.write true)]
          [2 (set! after.execute true)]
          [3 (set! after.shared true)]
          [_ (set! after.discardable true)])
        (test.assert-true
          (payload?
            (n.Directive (n.SectionAttributesDirective "a" attributes))
            (n.Directive (n.SectionAttributesDirective "a" after)))
          "section attributes")))))