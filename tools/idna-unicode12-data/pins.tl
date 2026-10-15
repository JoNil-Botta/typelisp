;; Exact byte pins for the reviewed TypeLisp IDNA profile.
(define (schema) : String
  "typelisp-idna-unicode12-v1")

(define (unicode-version) : String
  "12.0.0")

(define (name [index : i64]) : String
  (match index
    [0 "idna-tables-context.csv"]
    [1 "idna-tables-properties.csv"]
    [2 "UnicodeData.txt"]
    [3 "DerivedNormalizationProps.txt"]
    [4 "NormalizationTest.txt"]
    [5 "Scripts.txt"]
    [6 "DerivedJoiningType.txt"]
    [7 "DerivedBidiClass.txt"]
    [_ ""]))

(define (sha256 [index : i64]) : String
  (match index
    [0 "b64e879aafb6a276b2ad445a100840a8911a80b6eeb94f401760d884d9d46a88"]
    [1 "160b72e33a377a84253393c572dc338879f39b93beccbb9cb9baebbf4d6dd743"]
    [2 "57913fdb1c1271fa9fd51dea08d49370f33d5bfda6bbaba348f44d90029ea11d"]
    [3 "8b4210273920c013e736332434222b73786e6c468a360710f6799eeace9b3d38"]
    [4 "10b685b33411135d4d2247b871380f1a62544db83f80f158f5421f479d18a3a1"]
    [5 "bd327cbb8bffd2e4b40b1e9842c9a7d641d1c4e91c34a41020cf174f3a1c86a1"]
    [6 "2a92a39d6713b8cc9a6d4eb808efaf93c52a4fcc01c149fec9892113838dae8b"]
    [7 "a50670c09adf9a7f6e7344bdef81d5c8a2c5d116191c6f141bd772f149d8ecdc"]
    [_ ""]))

(define (size [index : i64]) : i64
  (match index
    [0 2170]
    [1 161210]
    [2 1797715]
    [3 818907]
    [4 2559615]
    [5 171959]
    [6 35452]
    [7 161370]
    [_ 0]))

(define (url [index : i64]) : String
  (match index
    [0
      "https://www.iana.org/assignments/idna-tables-12.0.0/idna-tables-context.csv"]
    [1
      "https://www.iana.org/assignments/idna-tables-12.0.0/idna-tables-properties.csv"]
    [2 "https://www.unicode.org/Public/12.0.0/ucd/UnicodeData.txt"]
    [3
      "https://www.unicode.org/Public/12.0.0/ucd/DerivedNormalizationProps.txt"]
    [4 "https://www.unicode.org/Public/12.0.0/ucd/NormalizationTest.txt"]
    [5 "https://www.unicode.org/Public/12.0.0/ucd/Scripts.txt"]
    [6
      "https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedJoiningType.txt"]
    [7
      "https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedBidiClass.txt"]
    [_ ""]))