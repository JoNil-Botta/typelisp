;# Typed canonical records. Callers use core validation for admission; these
;# codec primitives also preflight their borrowed input before any owned clone.
;# Only declared sets are normalized. Ordered events and profile input schedules
;# are serialized in their original order, including duplicates.
(import native_link_manifest_types as n)
(import native_link_manifest_wire as wire)
(import native_link_manifest_binary as binary)
(import native_link_manifest_budget as budget)
(import stdlib.serialize)
(import stdlib.vector)
(import stdlib.sort)
(import stdlib.iterator)
(import stdlib.crypto_sha256 as sha)
(import stdlib.byte_buf)
(import (serialize.serialize wire n.NativeLinkManifest) as manifest_codec)
(import (serialize.serialize wire n.NativeToolchainProfile) as profile_codec)
(import (serialize.serialize wire n.NativeLinkSemanticInput) as input_codec)

(defenum NativeCodecError
  (InputBudgetExceeded)
  (WireError binary.Error)
  (SchemaError String)
  (NonCanonicalRecord))

(defenum NativeBytesResult
  (NativeBytes (__tl_dyn-array u8))
  (NativeEncodeFailed NativeCodecError))

(defenum NativeManifestResult
  (NativeManifest n.NativeLinkManifest)
  (NativeManifestFailed NativeCodecError))

(defenum NativeProfileResult
  (NativeProfile n.NativeToolchainProfile)
  (NativeProfileFailed NativeCodecError))

(defenum NativeInputResult
  (NativeInput n.NativeLinkSemanticInput)
  (NativeInputFailed NativeCodecError))

(defenum NativeDigestResult
  (NativeDigest n.ContentIdentity)
  (NativeDigestFailed NativeCodecError))

(define (output-key [value : (& v n.NativeOutputKind)]) : String
  (match value
    [(n.Relocatable) "Relocatable"]
    [(n.FreestandingStaticExecutable) "FreestandingStaticExecutable"]
    [(n.StaticExecutable) "StaticExecutable"]
    [(n.StaticPieExecutable) "StaticPieExecutable"]
    [(n.PieExecutable) "PieExecutable"]
    [(n.StaticArchive) "StaticArchive"]
    [(n.ElfSharedObject) "ElfSharedObject"]
    [(n.PeDll) "PeDll"]
    [(n.MicrosoftImportLibrary) "MicrosoftImportLibrary"]))

(define (capability-key [value : (& v n.CapabilityKind)]) : String
  (match value
    [(n.ObjectInputs) "ObjectInputs"]
    [(n.ArchiveInputs) "ArchiveInputs"]
    [(n.SharedInputs) "SharedInputs"]
    [(n.ImportLibraryInputs) "ImportLibraryInputs"]
    [(n.LibrarySearch) "LibrarySearch"]
    [(n.Groups) "Groups"]
    [(n.WholeArchive) "WholeArchive"]
    [(n.StaticDynamicPreference) "StaticDynamicPreference"]
    [(n.DefaultLibraries) "DefaultLibraries"]
    [(n.Directives) "Directives"]
    [(n.Exports) "Exports"]
    [(n.DefinitionFiles) "DefinitionFiles"]
    [(n.VersionMaps) "VersionMaps"]
    [(n.Resources) "Resources"]
    [(n.Tls) "Tls"]
    [(n.Ifunc) "Ifunc"]
    [(n.Constructors) "Constructors"]
    [(n.Unwind) "Unwind"]
    [(n.Dwarf) "Dwarf"]
    [(n.CodeView) "CodeView"]
    [(n.Relocations) "Relocations"]
    [(n.DelayLoad) "DelayLoad"]
    [(n.ExternalArguments) "ExternalArguments"]
    [(n.RuntimeHelpers) "RuntimeHelpers"]
    [(n.SystemImports) "SystemImports"]
    [(n.OutputRelocatable) "OutputRelocatable"]
    [(n.OutputFreestandingStatic) "OutputFreestandingStatic"]
    [(n.OutputStatic) "OutputStatic"]
    [(n.OutputStaticPie) "OutputStaticPie"]
    [(n.OutputPie) "OutputPie"]
    [(n.OutputArchive) "OutputArchive"]
    [(n.OutputElfDso) "OutputElfDso"]
    [(n.OutputPeDll) "OutputPeDll"]
    [(n.OutputImportLibrary) "OutputImportLibrary"]))

(define (hardening-feature-key [value : (& v n.HardeningFeature)]) : String
  (match value
    [(n.PositionIndependent) "PositionIndependent"]
    [(n.AddressRandomization) "AddressRandomization"]
    [(n.NoExecute) "NoExecute"]
    [(n.NonExecutableStack) "NonExecutableStack"]
    [(n.Relro) "Relro"]
    [(n.ControlFlowGuard) "ControlFlowGuard"]
    [(n.Cet) "Cet"]
    [(n.EhContinuation) "EhContinuation"]
    [(n.StackProtector) "StackProtector"]))

(import (vector.vector n.NativeOutputKind) as outputs_vec)
(import (sort.vec n.NativeOutputKind) as outputs_sort)

(define (outputs-key [value : n.NativeOutputKind]) : String
  (output-key (& value)))

(define (outputs-less? [a : n.NativeOutputKind] [b : n.NativeOutputKind]) : bool
  (let
    [ak : String (outputs-key a)]
    [bk : String (outputs-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-outputs [items : (__tl_dyn-array n.NativeOutputKind)]) : (__tl_dyn-array
    n.NativeOutputKind)
  (let
    [n : i64 (array-length items)]
    [v : outputs_vec.Vec (outputs_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (outputs_vec.push! v (clone (array-ref items i))))
    (outputs_sort.sort! (&mut v) outputs-less?)
    (let
      [out : (__tl_dyn-array n.NativeOutputKind)
        (__tl_make-array n.NativeOutputKind n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (outputs_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector n.LogicalRoot) as roots_vec)
(import (sort.vec n.LogicalRoot) as roots_sort)

(define (roots-key [value : n.LogicalRoot]) : String
  (clone value.id))

(define (roots-less? [a : n.LogicalRoot] [b : n.LogicalRoot]) : bool
  (let
    [ak : String (roots-key a)]
    [bk : String (roots-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-roots [items : (__tl_dyn-array n.LogicalRoot)]) : (__tl_dyn-array
    n.LogicalRoot)
  (let
    [n : i64 (array-length items)]
    [v : roots_vec.Vec (roots_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (roots_vec.push! v (clone (array-ref items i))))
    (roots_sort.sort! (&mut v) roots-less?)
    (let
      [out : (__tl_dyn-array n.LogicalRoot) (__tl_make-array n.LogicalRoot n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (roots_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector n.ProfileFile) as files_vec)
(import (sort.vec n.ProfileFile) as files_sort)

(define (files-key [value : n.ProfileFile]) : String
  (clone value.id))

(define (files-less? [a : n.ProfileFile] [b : n.ProfileFile]) : bool
  (let
    [ak : String (files-key a)]
    [bk : String (files-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-files [items : (__tl_dyn-array n.ProfileFile)]) : (__tl_dyn-array
    n.ProfileFile)
  (let
    [n : i64 (array-length items)]
    [v : files_vec.Vec (files_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (files_vec.push! v (clone (array-ref items i))))
    (files_sort.sort! (&mut v) files-less?)
    (let
      [out : (__tl_dyn-array n.ProfileFile) (__tl_make-array n.ProfileFile n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (files_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector String) as identities_vec)
(import (sort.vec String) as identities_sort)

(define (identities-key [value : String]) : String
  (clone value))

(define (identities-less? [a : String] [b : String]) : bool
  (let
    [ak : String (identities-key a)]
    [bk : String (identities-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-identities [items : (__tl_dyn-array String)]) : (__tl_dyn-array
    String)
  (let
    [n : i64 (array-length items)]
    [v : identities_vec.Vec (identities_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (identities_vec.push! v (clone (array-ref items i))))
    (identities_sort.sort! (&mut v) identities-less?)
    (let
      [out : (__tl_dyn-array String) (__tl_make-array String n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (identities_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector n.SystemImport) as imports_vec)
(import (sort.vec n.SystemImport) as imports_sort)

(define (imports-key [value : n.SystemImport]) : String
  (clone value.symbol))

(define (imports-less? [a : n.SystemImport] [b : n.SystemImport]) : bool
  (let
    [ak : String (imports-key a)]
    [bk : String (imports-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-imports [items : (__tl_dyn-array n.SystemImport)]) : (__tl_dyn-array
    n.SystemImport)
  (let
    [n : i64 (array-length items)]
    [v : imports_vec.Vec (imports_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (imports_vec.push! v (clone (array-ref items i))))
    (imports_sort.sort! (&mut v) imports-less?)
    (let
      [out : (__tl_dyn-array n.SystemImport) (__tl_make-array n.SystemImport n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (imports_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector n.CapabilityRow) as capabilities_vec)
(import (sort.vec n.CapabilityRow) as capabilities_sort)

(define (capabilities-key [value : n.CapabilityRow]) : String
  (capability-key (& value.kind)))

(define (capabilities-less? [a : n.CapabilityRow] [b : n.CapabilityRow]) : bool
  (let
    [ak : String (capabilities-key a)]
    [bk : String (capabilities-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-capabilities [items : (__tl_dyn-array n.CapabilityRow)]) : (__tl_dyn-array
    n.CapabilityRow)
  (let
    [n : i64 (array-length items)]
    [v : capabilities_vec.Vec (capabilities_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (capabilities_vec.push! v (clone (array-ref items i))))
    (capabilities_sort.sort! (&mut v) capabilities-less?)
    (let
      [out : (__tl_dyn-array n.CapabilityRow)
        (__tl_make-array n.CapabilityRow n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (capabilities_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(import (vector.vector n.HardeningRow) as hardening_vec)
(import (sort.vec n.HardeningRow) as hardening_sort)

(define (hardening-key [value : n.HardeningRow]) : String
  (hardening-feature-key (& value.feature)))

(define (hardening-less? [a : n.HardeningRow] [b : n.HardeningRow]) : bool
  (let
    [ak : String (hardening-key a)]
    [bk : String (hardening-key b)]
    (wire.key-less? (& ak) (& bk))))

(define (sort-hardening [items : (__tl_dyn-array n.HardeningRow)]) : (__tl_dyn-array
    n.HardeningRow)
  (let
    [n : i64 (array-length items)]
    [v : hardening_vec.Vec (hardening_vec.with-capacity n)]
    (for [i (iterator.range 0 n)]
      (hardening_vec.push! v (clone (array-ref items i))))
    (hardening_sort.sort! (&mut v) hardening-less?)
    (let
      [out : (__tl_dyn-array n.HardeningRow) (__tl_make-array n.HardeningRow n)]
      (for [i (iterator.range 0 n)]
        (set!
          (array-ref out i)
          (hardening_vec.get (& v) i (clone (array-ref items i)))))
      out)))

(define (normalize-manifest [value : n.NativeLinkManifest]) : n.NativeLinkManifest
  (set! value.roots (sort-roots value.roots))
  value)

(define (normalize-profile [value : n.NativeToolchainProfile]) : n.NativeToolchainProfile
  (set! value.outputs (sort-outputs value.outputs))
  (set! value.roots (sort-roots value.roots))
  (set! value.files (sort-files value.files))
  (set! value.runtime-identities (sort-identities value.runtime-identities))
  (set! value.imports (sort-imports value.imports))
  (set! value.capabilities (sort-capabilities value.capabilities))
  (set! value.hardening (sort-hardening value.hardening))
  value)

(define (normalize-input [value : n.NativeLinkSemanticInput]) : n.NativeLinkSemanticInput
  (set! value.manifest (normalize-manifest value.manifest))
  (set! value.profile (normalize-profile value.profile))
  value)

(define (bytes-equal?
  [a : (& a (__tl_dyn-array u8))]
  [b : (& b (__tl_dyn-array u8))]) : bool
  (when (!= (array-length a) (array-length b)) (return false))
  (for [i (iterator.range 0 (array-length a))]
    (when (!= (array-ref a i) (array-ref b i)) (return false)))
  true)

(define (encode-manifest-record
  [value : (& v n.NativeLinkManifest)]
  [limits : (& l binary.Limits)]) : NativeBytesResult
  (let
    [check : budget.Budget (budget.new limits)]
    (budget.observe n.NativeLinkManifest value (&mut check))
    (when (not check.ok) (return (NativeEncodeFailed (InputBudgetExceeded))))
    (let
      [tree : wire.Value
        (manifest_codec.encode (normalize-manifest (clone (deref value))))]
      (match (binary.encode (& tree) (binary.ManifestDocument) limits)
        [(binary.Encoded data) (NativeBytes data)]
        [(binary.EncodeFailed error) (NativeEncodeFailed (WireError error))]))))

(define (decode-manifest-record
  [data : (& b (__tl_dyn-array u8))]
  [limits : (& l binary.Limits)]) : NativeManifestResult
  (match (binary.decode data (binary.ManifestDocument) limits)
    [(binary.DecodeFailed error) (NativeManifestFailed (WireError error))]
    [(binary.Decoded tree)
      (match (manifest_codec.decode tree)
        [(manifest_codec.Err error) (NativeManifestFailed (SchemaError error))]
        [(manifest_codec.Ok value)
          (match (encode-manifest-record (& value) limits)
            [(NativeEncodeFailed error) (NativeManifestFailed error)]
            [(NativeBytes canonical)
              (if (bytes-equal? data (& canonical))
                (NativeManifest value)
                (NativeManifestFailed (NonCanonicalRecord)))])])]))

(define (encode-profile-record
  [value : (& v n.NativeToolchainProfile)]
  [limits : (& l binary.Limits)]) : NativeBytesResult
  (let
    [check : budget.Budget (budget.new limits)]
    (budget.observe n.NativeToolchainProfile value (&mut check))
    (when (not check.ok) (return (NativeEncodeFailed (InputBudgetExceeded))))
    (let
      [tree : wire.Value
        (profile_codec.encode (normalize-profile (clone (deref value))))]
      (match (binary.encode (& tree) (binary.ProfileDocument) limits)
        [(binary.Encoded data) (NativeBytes data)]
        [(binary.EncodeFailed error) (NativeEncodeFailed (WireError error))]))))

(define (decode-profile-record
  [data : (& b (__tl_dyn-array u8))]
  [limits : (& l binary.Limits)]) : NativeProfileResult
  (match (binary.decode data (binary.ProfileDocument) limits)
    [(binary.DecodeFailed error) (NativeProfileFailed (WireError error))]
    [(binary.Decoded tree)
      (match (profile_codec.decode tree)
        [(profile_codec.Err error) (NativeProfileFailed (SchemaError error))]
        [(profile_codec.Ok value)
          (match (encode-profile-record (& value) limits)
            [(NativeEncodeFailed error) (NativeProfileFailed error)]
            [(NativeBytes canonical)
              (if (bytes-equal? data (& canonical))
                (NativeProfile value)
                (NativeProfileFailed (NonCanonicalRecord)))])])]))

(define (encode-input-record
  [value : (& v n.NativeLinkSemanticInput)]
  [limits : (& l binary.Limits)]) : NativeBytesResult
  (let
    [check : budget.Budget (budget.new limits)]
    (budget.observe n.NativeLinkSemanticInput value (&mut check))
    (when (not check.ok) (return (NativeEncodeFailed (InputBudgetExceeded))))
    (let
      [tree : wire.Value
        (input_codec.encode (normalize-input (clone (deref value))))]
      (match (binary.encode (& tree) (binary.SemanticInputDocument) limits)
        [(binary.Encoded data) (NativeBytes data)]
        [(binary.EncodeFailed error) (NativeEncodeFailed (WireError error))]))))

(define (decode-input-record
  [data : (& b (__tl_dyn-array u8))]
  [limits : (& l binary.Limits)]) : NativeInputResult
  (match (binary.decode data (binary.SemanticInputDocument) limits)
    [(binary.DecodeFailed error) (NativeInputFailed (WireError error))]
    [(binary.Decoded tree)
      (match (input_codec.decode tree)
        [(input_codec.Err error) (NativeInputFailed (SchemaError error))]
        [(input_codec.Ok value)
          (match (encode-input-record (& value) limits)
            [(NativeEncodeFailed error) (NativeInputFailed error)]
            [(NativeBytes canonical)
              (if (bytes-equal? data (& canonical))
                (NativeInput value)
                (NativeInputFailed (NonCanonicalRecord)))])])]))

(define (digest-bytes [data : (__tl_dyn-array u8)]) : NativeDigestResult
  (let
    [count : i64 (array-length data)]
    [bytes : byte_buf.ByteBuf (byte_buf.ByteBuf data count)]
    (match (sha.digest (byte_buf.as-bytes (& bytes)))
      [(sha.Sha256FinalizeOk digest)
        (NativeDigest
          (n.ContentIdentity (cast 1 : u32) (sha.digest-bytes (& digest))))]
      [_ (NativeDigestFailed (InputBudgetExceeded))])))

(define (profile-identity
  [profile : (& p n.NativeToolchainProfile)]
  [limits : (& l binary.Limits)]) : NativeDigestResult
  (match (encode-profile-record profile limits)
    [(NativeEncodeFailed error) (NativeDigestFailed error)]
    [(NativeBytes data) (digest-bytes data)]))