;; Deterministic diagnostic serialization of validated ownership graphs.
;; Dense indices are body-relative. The scope line retains all three identity
;; components, so an old revision cannot be mistaken for a current dump.
(import compiler_ownership_core as own)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)

(defenum OwnershipDumpResult
  (Ok String)
  (Err own.OwnershipFailure))

(define (ownership-dump-identity-component [value : u64]) : String
  ;; Two unsigned 32-bit limbs round-trip even beyond signed i64's range.
  (str_cat.str-cat
    (string.int->string (cast (/ value (cast 4294967296 : u64)) : i64))
    "."
    (string.int->string (cast (% value (cast 4294967296 : u64)) : i64))))

(define (ownership-dump-source [source : (& source own.OwnershipSource)]) : String
  ;; Length framing preserves paths and expansion traces containing newlines,
  ;; colons, or other punctuation without an ambiguous escaping convention.
  (str_cat.str-cat
    " @"
    (string.int->string (string.string-length (& source.path)))
    ":"
    (string.copy (& source.path))
    ":"
    (string.int->string source.line)
    ":"
    (string.int->string source.column)
    " expansion="
    (string.int->string (string.string-length (& source.expansion)))
    ":"
    (string.copy (& source.expansion))))

(define (ownership-dump-place [place : (& place own.OwnershipPlaceId)]) : String
  (str_cat.str-cat "%p" (string.int->string place.index)))

(define (ownership-dump-block [block : (& block own.OwnershipBlockId)]) : String
  (str_cat.str-cat "bb" (string.int->string block.index)))

(define (ownership-dump-loan [loan : (& loan own.OwnershipLoanId)]) : String
  (str_cat.str-cat "%loan" (string.int->string loan.index)))

(define (ownership-dump-operation [op : (& op own.OwnershipOperation)]) : String
  ;; The output names each operation's value transfer, rather than relying on
  ;; the frontend spelling or a backend storage address.
  (match op
    [(own.OwnershipOperation.Read place)
      (str_cat.str-cat "read " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.Initialize place)
      (str_cat.str-cat "initialize " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.Assign place)
      (str_cat.str-cat "assign " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.RequireEmpty place)
      (str_cat.str-cat "require-empty " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.BeginConstruction owner)
      (str_cat.str-cat
        "begin-construction %owner"
        (string.int->string owner.index))]
    [(own.OwnershipOperation.BindComplete owner)
      (str_cat.str-cat "bind-complete %owner" (string.int->string owner.index))]
    [(own.OwnershipOperation.CleanupFailure code)
      (str_cat.str-cat "cleanup-failure " (string.int->string code))]
    [(own.OwnershipOperation.CleanupPlace place cleanup)
      (str_cat.str-cat
        "cleanup-place "
        (ownership-dump-place (& place))
        " %cleanup"
        (string.int->string cleanup.index))]
    [(own.OwnershipOperation.BindFresh owner)
      (str_cat.str-cat "bind-fresh %owner" (string.int->string owner.index))]
    [(own.OwnershipOperation.BindMove place owner)
      (str_cat.str-cat
        "bind-move "
        (ownership-dump-place (& place))
        " %owner"
        (string.int->string owner.index))]
    [(own.OwnershipOperation.Leave owner)
      (str_cat.str-cat "leave %owner" (string.int->string owner.index))]
    [(own.OwnershipOperation.Cleanup owner cleanup)
      (str_cat.str-cat
        "cleanup %owner"
        (string.int->string owner.index)
        " %cleanup"
        (string.int->string cleanup.index))]
    [(own.OwnershipOperation.Consume place)
      (str_cat.str-cat "consume " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.Invalidate place)
      (str_cat.str-cat "invalidate " (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.Copy source dest)
      (str_cat.str-cat
        "copy "
        (ownership-dump-place (& source))
        " -> "
        (ownership-dump-place (& dest)))]
    [(own.OwnershipOperation.Move source dest)
      (str_cat.str-cat
        "move "
        (ownership-dump-place (& source))
        " -> "
        (ownership-dump-place (& dest)))]
    [(own.OwnershipOperation.Borrow loan)
      (str_cat.str-cat "borrow " (ownership-dump-loan (& loan)))]
    [(own.OwnershipOperation.Reborrow loan)
      (str_cat.str-cat "reborrow " (ownership-dump-loan (& loan)))]
    [(own.OwnershipOperation.UseLoan loan)
      (str_cat.str-cat "retain " (ownership-dump-loan (& loan)))]
    [(own.OwnershipOperation.MayUseLoan loan holder)
      (str_cat.str-cat
        "may-retain "
        (ownership-dump-loan (& loan))
        " via "
        (ownership-dump-place (& holder)))]
    [(own.OwnershipOperation.EndLoan loan)
      (str_cat.str-cat "end " (ownership-dump-loan (& loan)))]
    [(own.OwnershipOperation.AccessThrough loan place access)
      (str_cat.str-cat
        (match access
          [(own.OwnershipAccess.Read) "read-through "]
          [(own.OwnershipAccess.Write) "write-through "])
        (ownership-dump-loan (& loan))
        " "
        (ownership-dump-place (& place)))]
    [(own.OwnershipOperation.Unsupported _) "unsupported"]))

(define (ownership-dump-terminator [term : (& term own.OwnershipTerminator)]) : String
  (match term
    [(own.OwnershipTerminator.Goto target)
      (str_cat.str-cat "goto " (ownership-dump-block (& target)))]
    [(own.OwnershipTerminator.Branch condition yes no)
      (str_cat.str-cat
        "branch "
        (ownership-dump-place (& condition))
        " "
        (ownership-dump-block (& yes))
        " "
        (ownership-dump-block (& no)))]
    [(own.OwnershipTerminator.Return operands)
      (let
        [out : text_buf.TextBuf (text_buf.append (text_buf.empty) "return")]
        [i : i64 0]
        (while (< i (array-length operands.items))
          (begin
            (text_buf.append!
              out
              (str_cat.str-cat
                " "
                (ownership-dump-place (& (array-ref operands.items i)))))
            (set! i (+ i 1))))
        (text_buf.render out))]
    [(own.OwnershipTerminator.ReturnOwned operands)
      (let
        [out : text_buf.TextBuf
          (text_buf.append (text_buf.empty) "return-owned")]
        [i : i64 0]
        (while (< i (array-length operands.items))
          (begin
            (text_buf.append!
              out
              (str_cat.str-cat
                " "
                (ownership-dump-place (& (array-ref operands.items i)))))
            (set! i (+ i 1))))
        (text_buf.render out))]
    [(own.OwnershipTerminator.Abort) "abort"]
    [(own.OwnershipTerminator.Unsupported _) "unsupported"]))

(define (ownership-dump
  [body : (& body own.OwnershipBody)]
  [limits : own.OwnershipLimits]) : OwnershipDumpResult
  (match (own.ownership-validate body limits)
    [(own.OwnershipResult.Err error) (OwnershipDumpResult.Err error)]
    [(own.OwnershipResult.Ok)
      (let
        [out : text_buf.TextBuf (text_buf.empty)]
        [i : i64 0]
        (text_buf.append! out "typelisp-ownership v3\nscope ")
        (text_buf.append! out (ownership-dump-identity-component body.id.owner))
        (text_buf.append! out ":")
        (text_buf.append!
          out
          (ownership-dump-identity-component body.id.generation))
        (text_buf.append! out ":")
        (text_buf.append!
          out
          (ownership-dump-identity-component body.id.revision))
        (text_buf.append!
          out
          (str_cat.str-cat " entry=" (ownership-dump-block (& body.entry)) "\n"))
        (while (< i (array-length body.types))
          (begin
            (text_buf.append!
              out
              (str_cat.str-cat "%t" (string.int->string i) " = "))
            (match (& (array-ref body.types i).kind)
              [(own.OwnershipTypeKind.Scalar) (text_buf.append! out "scalar")]
              [(own.OwnershipTypeKind.Boolean) (text_buf.append! out "bool")]
              [(own.OwnershipTypeKind.Product fields)
                (let
                  [j : i64 0]
                  (text_buf.append! out "product")
                  (while (< j (array-length fields.items))
                    (begin
                      (text_buf.append!
                        out
                        (str_cat.str-cat
                          " %t"
                          (string.int->string (array-ref fields.items j).index)))
                      (set! j (+ j 1)))))])
            (text_buf.append!
              out
              (if (array-ref body.types i).copy?
                " copy\n"
                " move\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.locals))
          (begin
            (text_buf.append!
              out
              (str_cat.str-cat
                "%l"
                (string.int->string i)
                " : %t"
                (string.int->string (array-ref body.locals i).type.index)
                (if (array-ref body.locals i).parameter?
                  " parameter"
                  " local")
                (ownership-dump-source (& (array-ref body.locals i).source))
                "\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.places))
          (begin
            (text_buf.append!
              out
              (str_cat.str-cat
                "%p"
                (string.int->string i)
                " : %t"
                (string.int->string (array-ref body.places i).type.index)
                " = %l"
                (string.int->string (array-ref body.places i).local.index)))
            (match (& (array-ref body.places i).projection)
              [(own.OwnershipProjection.Root) (text_buf.append! out " root")]
              [(own.OwnershipProjection.Field parent ordinal)
                (text_buf.append!
                  out
                  (str_cat.str-cat
                    " field "
                    (ownership-dump-place (& parent))
                    " "
                    (string.int->string ordinal)))])
            (text_buf.append!
              out
              (str_cat.str-cat
                (ownership-dump-source (& (array-ref body.places i).source))
                "\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.loans))
          (let
            [loan : (& body own.OwnershipLoan) (& (array-ref body.loans i))]
            (text_buf.append!
              out
              (str_cat.str-cat
                "%loan"
                (string.int->string i)
                " = "
                (if (own.ownership-loan-exclusive? loan)
                  "exclusive "
                  "shared ")
                (ownership-dump-place (& loan.place))
                (match (& loan.origin)
                  [(own.OwnershipLoanOrigin.Direct) " direct"]
                  [(own.OwnershipLoanOrigin.Parent parent)
                    (str_cat.str-cat
                      " parent "
                      (ownership-dump-loan (& parent)))])
                (ownership-dump-source (& loan.source))
                "\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.cleanups))
          (let
            [cleanup : (& body own.OwnershipCleanup)
              (& (array-ref body.cleanups i))]
            (text_buf.append!
              out
              (str_cat.str-cat
                "%cleanup"
                (string.int->string i)
                " = %t"
                (string.int->string cleanup.type.index)
                (if cleanup.type-owned?
                  " type-owned"
                  " context-only")))
            (match (& cleanup.kind)
              [(own.OwnershipCleanupKind.Intrinsic)
                (text_buf.append! out " intrinsic")]
              [(own.OwnershipCleanupKind.Product fields)
                (let
                  [j : i64 0]
                  (text_buf.append! out " product")
                  (while (< j (array-length fields.items))
                    (begin
                      (text_buf.append!
                        out
                        (str_cat.str-cat
                          " field"
                          (string.int->string
                            (array-ref fields.items j).ordinal)
                          ":%cleanup"
                          (string.int->string
                            (array-ref fields.items j).cleanup.index)))
                      (set! j (+ j 1)))))])
            (text_buf.append!
              out
              (str_cat.str-cat (ownership-dump-source (& cleanup.source)) "\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.obligations))
          (let
            [owner : (& body own.OwnershipObligation)
              (& (array-ref body.obligations i))]
            (text_buf.append!
              out
              (str_cat.str-cat
                "%owner"
                (string.int->string i)
                " = "
                (ownership-dump-place (& owner.place))
                " %cleanup"
                (string.int->string owner.cleanup.index)
                (match (& owner.mode)
                  [(own.OwnershipObligationMode.AutomaticRequired)
                    " automatic-required"]
                  [(own.OwnershipObligationMode.Discharge) " discharge"])
                (match (& owner.parent)
                  [(own.OwnershipObligationParent.Root) " root"]
                  [(own.OwnershipObligationParent.Parent parent)
                    (str_cat.str-cat
                      " parent %owner"
                      (string.int->string parent.index))])))
            (let
              [j : i64 0]
              (while (< j (array-length owner.retained))
                (begin
                  (text_buf.append!
                    out
                    (match (& (array-ref owner.retained j))
                      [(own.OwnershipCleanupUse.Read place)
                        (str_cat.str-cat
                          " retain-read "
                          (ownership-dump-place (& place)))]
                      [(own.OwnershipCleanupUse.Through loan place)
                        (str_cat.str-cat
                          " retain-through "
                          (ownership-dump-loan (& loan))
                          " "
                          (ownership-dump-place (& place)))]))
                  (set! j (+ j 1)))))
            (text_buf.append!
              out
              (str_cat.str-cat (ownership-dump-source (& owner.source)) "\n"))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i (array-length body.blocks))
          (let
            [block : (& body own.OwnershipBlock) (& (array-ref body.blocks i))]
            [j : i64 0]
            (text_buf.append!
              out
              (str_cat.str-cat "bb" (string.int->string i) ":\n"))
            (while (< j (array-length block.instructions))
              (begin
                (text_buf.append!
                  out
                  (str_cat.str-cat
                    "  "
                    (ownership-dump-operation
                      (& (array-ref block.instructions j).operation))
                    (ownership-dump-source
                      (& (array-ref block.instructions j).source))
                    "\n"))
                (set! j (+ j 1))))
            (text_buf.append!
              out
              (str_cat.str-cat
                "  "
                (ownership-dump-terminator (& block.terminator))
                (ownership-dump-source (& block.source))
                "\n"))
            (set! i (+ i 1))))
        (OwnershipDumpResult.Ok (text_buf.render out)))]))