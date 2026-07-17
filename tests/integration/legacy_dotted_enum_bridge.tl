;; A dotted dependency's public enum identity must survive a legacy path import
;; of this moduleless bridge.
(import legacy_dotted_enum_provider as provider)

(define (legacy-dotted-enum-roundtrip [value : provider.LegacyDottedEnum]) : provider.LegacyDottedEnum
  value)