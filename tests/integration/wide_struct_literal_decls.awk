# Writes wide_struct_literal_decls.tl, the #7921 reproducer's declarations
# written out without macros; the gates that compile its importers generate it:
#   awk -f tests/integration/wide_struct_literal_decls.awk > tests/integration/wide_struct_literal_decls.tl
BEGIN {
    print ";; The #7921 reproducer's declarations, written out without macros: Wide has"
    print ";; fields f0..f1002 plus `tail`, and Next follows it with four bool fields, so"
    print ";; Wide's members past index 1000 used to resolve through Next. Imported by"
    print ";; tests/safety/wide_struct_literal_reject.tl and wide_struct_literal.tl."
    print "(defstruct Wide"
    for (i = 0; i <= 1002; i++) printf "  (f%d i64)\n", i
    print "  (tail i64))"
    print ""
    print "(defstruct Next"
    print "  (a bool)"
    print "  (b bool)"
    print "  (c bool)"
    print "  (d bool))"
    print ""
    print "(define (make) : Wide"
    print "  (Wide"
    for (i = 1; i <= 1003; i++) printf "    %d\n", i
    printf "    0))"
}
