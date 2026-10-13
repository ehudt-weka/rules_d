/**
 * Interface digests and compile-input pruning for the body-use cutoff.
 *
 * A D compile depends on the function bodies of an imported module only when it analyses them. The
 * digest of a module covers everything else an importer can see, so a compile whose time trace shows
 * no analysed body of an imported module depends on that module only through the module's digest.
 *
 *   ifc_digest digest --names-out=<file> [--names=<file>]... <out> <src> [<out> <src> ...]
 *       Writes each src's digest file to its out, and to --names-out the line-capturing names (see
 *       below) the srcs declare. --names: line-capturing names declared by the srcs' dependencies.
 *   ifc_digest prune --candidates=<file> --makedeps=<file> --trace=<file>|--body-use=<file> --out=<file>
 *       Run after a compile with -makedeps=<file> and either --ftime-trace --ftime-trace-granularity=0
 *       or, with a patched LDC (weka/ldc branch body-use), -body-use=<file> (not -deps, which makes the
 *       compiler analyse every imported body). Writes the inputs the compile did not depend on, one exec
 *       path per line (bazel's unused_inputs_list): for a candidate the compile never read, its source and
 *       its digest file; for one it read without analysing a body, its source. Each candidates line is
 *       "<input>\t<path the compiler sees>\t<digest file>". --trace is the compiler's stdout
 *       (--ftime-trace-file=-); what precedes the trace there is printed. With IFC_DIGEST_STATS set,
 *       prints the trace size and the candidate counts to stderr; with IFC_DIGEST_LIST set, each
 *       loaded input it pruned, and the first use that kept each other one.
 *   ifc_digest names [--why] [--out=<file>] <src>...   prints the names file lines for the srcs (--why:
 *       provenance)
 *   ifc_digest print [--names=<file>]... <src>...   prints each src's digest file
 *   ifc_digest explain [--names=<file>]... <src>... also prints each stripped body ("body <first line>
 *       <last line> <owner>"), each hashed line ("pos <line> <what>"), and each identifier token named
 *       like a line-capturing name that is not a use ("lex <line> <name>")
 *   An argument @<file> stands for the lines of <file>.
 *
 * A digest file holds:
 *   ifc_digest/3 <sha256>            see below
 *   module <name>
 *   locreader <qualified name>       a function whose stripped body evaluates __traits(getLocation)
 *   locanywhere                      __traits(getLocation) outside a stripped body
 *   unparsed                         the module did not parse; its sha256 covers the whole text
 *
 * The sha256 covers the exact text of every token outside a stripped body, so formatting and comments
 * do not count. Stripped bodies are those of named functions, whose analysis LDC's time trace records
 * ("Sema3: Func", "CTFE func:"), and those of constructors, destructors, postblits, invariants, static
 * constructors and unittests, which have no Sema3 event but which another module's compile analyses
 * only in CTFE (which has its event) -- except inside a template, or under pragma(inline) (LDC defines
 * those in every caller's object, even at -O0). Those stay in. Function literals and contracts stay in.
 * The cutoff assumes no cross-module inlining (-O, -enable-cross-module-inlining): with it, a compile
 * analyses imported constructors without an event.
 *
 * Token positions are not covered, except where a line can reach an importer's output:
 *   - __LINE__, except as a whole default argument (it then takes the line of each use)
 *   - the `mixin` of a string mixin: lines in the generated code count from it
 *   - every line of a body that stays in because it is in a template or under pragma(inline): an
 *     importer compiles it with its lines (debug info, assert and bounds-check messages)
 *   - bounds checks and asserts in default arguments, which each caller compiles
 *   - uses of line-capturing names: a function or template with a __LINE__ default argument, or an
 *     aggregate whose constructor or opCall has one, closed over aliases (and, for constructors, over
 *     template mixins). A use is a call, property access, `new`, template instance or initialized
 *     variable of the type, found in the AST; names are matched by identifier, which over-approximates.
 *
 * Built on DMD's standalone parser (dmd:parser, ASTBase), compiled with -version=LocOffset.
 */
module ifc_digest;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : free, getenv;
import core.sys.posix.stdlib : realpath;
import std.algorithm : canFind, endsWith, sort, startsWith, uniq;
import std.array : array, join;
import std.ascii : isAlphaNum, isDigit;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.file : readText;
static import std.file;
import std.path : baseName, stripExtension;
import std.stdio : File, writeln;
static import std.stdio;
import std.string : fromStringz, indexOf, lineSplitter, toStringz;

import dmd.astbase;
import dmd.errorsink;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.lexer;
import dmd.location;
import dmd.parse;
import dmd.parsetimevisitor;
import dmd.rootobject;
import dmd.tokens;
import dmd.transitivevisitor;

enum FORMAT_VERSION = "ifc_digest/3";

/// In a names file: every name may capture its line.
enum ANY_NAME = "*";

class CountingErrorSink : ErrorSinkNull {
  nothrow:
  extern (C++):
  override:
    void error(const ref Loc loc, const(char)* format, ...) { errors++; }
  extern (D):
    int errors;
}

struct Body {
    uint first;    // file offset of the body's first token
    uint last;     // file offset of the body's last token
    string owner;  // qualified name of the function, without the module
}

/// A reference that captures its line if `id` is a line-capturing name.
struct Use {
    uint line;
    Identifier id;
}

extern (C++) final class LineFinder : ParseTimeTransitiveVisitor!ASTBase {
    alias visit = ParseTimeTransitiveVisitor!ASTBase.visit;
    bool found;
    override void visit(ASTBase.LineInitExp e) { found = true; }
}

bool capturesLine(ASTBase.Expression e) {
    if (!e) {
        return false;
    }
    scope finder = new LineFinder();
    e.accept(finder);
    return finder.found;
}

extern (C++) final class BareLine : ParseTimeVisitor!ASTBase {
    alias visit = ParseTimeVisitor!ASTBase.visit;
    bool found;
    override void visit(ASTBase.Expression) {}
    override void visit(ASTBase.LineInitExp e) { found = true; }
}

/// A default argument that is just __LINE__: it takes the line of each use, not its own.
bool isBareLine(ASTBase.Expression e) {
    if (!e) {
        return false;
    }
    scope finder = new BareLine();
    e.accept(finder);
    return finder.found;
}

/// Lines of the bounds checks and asserts in an expression: they pass their line to the runtime.
extern (C++) final class CheckFinder : ParseTimeTransitiveVisitor!ASTBase {
    alias visit = ParseTimeTransitiveVisitor!ASTBase.visit;
    uint[] lines;
    override void visit(ASTBase.ArrayExp e) { lines ~= e.loc.linnum; super.visit(e); }  // also slices
    override void visit(ASTBase.AssertExp e) { lines ~= e.loc.linnum; super.visit(e); }
}

extern (C++) final class InlinePragmaFinder : ParseTimeTransitiveVisitor!ASTBase {
    alias visit = ParseTimeTransitiveVisitor!ASTBase.visit;
    bool found;
    override void visit(ASTBase.PragmaStatement s) { found |= s.ident == Id.Pinline; super.visit(s); }
}

bool hasInlinePragma(ASTBase.Statement s) {
    if (!s) {
        return false;
    }
    scope finder = new InlinePragmaFinder();
    s.accept(finder);
    return finder.found;
}

/// The name a call goes through: `f(...)`, `a.f(...)`, `f!x(...)`, `a.f!x(...)`, `T(...)`.
extern (C++) final class CalleeName : ParseTimeVisitor!ASTBase {
    alias visit = ParseTimeVisitor!ASTBase.visit;
    Identifier id;
    override void visit(ASTBase.Expression) {}
    override void visit(ASTBase.IdentifierExp e) { id = e.ident; }
    override void visit(ASTBase.DotIdExp e) { id = e.ident; }
    override void visit(ASTBase.DotTemplateInstanceExp e) { id = e.ti.name; }
    override void visit(ASTBase.TypeExp e) { id = lastIdent(e.type); }
    override void visit(ASTBase.ScopeExp e) {
        if (auto ti = e.sds.isTemplateInstance()) {
            id = ti.name;
        }
    }
}

/// Finds a type's class by dispatch: ASTBase's TypeTraits also has `ty == Tident`, so `isTypeIdentifier()` misreads it.
extern (C++) final class TypeKind : ParseTimeVisitor!ASTBase {
    alias visit = ParseTimeVisitor!ASTBase.visit;
    ASTBase.TypeIdentifier ident;
    ASTBase.TypeInstance inst;

    override void visit(ASTBase.Type) {}
    override void visit(ASTBase.TypeIdentifier t) { ident = t; }
    override void visit(ASTBase.TypeInstance t) { inst = t; }
}

Identifier lastIdent(ASTBase.Type t) {
    if (!t) {
        return null;
    }
    scope kind = new TypeKind();
    t.accept(kind);
    if (auto ti = kind.ident) {
        if (ti.idents.length) {
            RootObject o = ti.idents[$ - 1];
            if (o.dyncast() == DYNCAST.identifier) {
                return cast(Identifier) o;
            }
            if (o.dyncast() == DYNCAST.dsymbol) {
                return (cast(ASTBase.TemplateInstance) o).name;
            }
            return null;
        }
        return ti.ident;
    }
    if (auto tinst = kind.inst) {
        return tinst.tempinst.name;
    }
    return null;
}

string lastName(ASTBase.Type t) {
    auto id = lastIdent(t);
    return id ? id.toString().idup : null;
}

/// Collects a module's strippable bodies, the references whose lines can reach an importer's output,
/// and the line-capturing names the module declares.
extern (C++) class Collector : ParseTimeTransitiveVisitor!ASTBase {
    alias visit = ParseTimeTransitiveVisitor!ASTBase.visit;

    // Per module:
    Body[] bodies;
    Body[] lineBodies;     // kept bodies whose every token line is hashed
    Use[] uses;
    uint[] checkLines;     // bounds checks and asserts in default arguments
    bool[uint] useSiteLines;  // offsets of __LINE__ tokens that are whole default arguments
    string[] scopes;       // enclosing aggregates, templates and functions
    int keep;              // > 0 inside a body that stays in the digest
    int templates;         // > 0 inside a template declaration
    int inlines;           // > 0 under pragma(inline)
    bool ctorLike;         // the next visitFuncBody is a constructor-like or unittest body
    string file;

    // Across the action's modules:
    string[] lineNames;
    string[] ctorOwners;   // aggregates and mixin templates with a line-capturing constructor or opCall
    string[2][] mixins;    // [aggregate, mixed-in template]
    string[2][] aliases;   // [alias, aliased name]
    string[string] why;    // name -> where a rule first added it (names --why)

    extern (D) final void addName(string name, Loc loc, string rule) {
        lineNames ~= name;
        if (name !in why) {
            why[name] = file ~ ":" ~ loc.linnum.to!string ~ " " ~ rule;
        }
    }

    extern (D) final void use(Identifier id, const ref Loc loc) {
        if (id) {
            uses ~= Use(loc.linnum, id);
        }
    }

    extern (D) final void enter(Identifier id) { scopes ~= id ? id.toString().idup : "__anonymous"; }
    extern (D) final void leave() { scopes = scopes[0 .. $ - 1]; }

    extern (D) final string qualified(Identifier id) {
        string name = id ? id.toString().idup : "__anonymous";
        auto chain = scopes.dup;
        if (!chain.length || chain[$ - 1] != name) {
            chain ~= name;
        }
        return chain.join(".");
    }

    extern (D) final void noteLineParams(ASTBase.FuncDeclaration f) {
        auto tf = f.type ? f.type.isTypeFunction() : null;
        if (!tf || !tf.parameterList.parameters) {
            return;
        }
        bool captures = false;
        foreach (p; *tf.parameterList.parameters) {
            if (!p.defaultArg) {
                continue;
            }
            // A default argument is evaluated at each call, in the caller's compile.
            scope checks = new CheckFinder();
            p.defaultArg.accept(checks);
            checkLines ~= checks.lines;
            captures |= capturesLine(p.defaultArg);
            if (isBareLine(p.defaultArg)) {
                useSiteLines[p.defaultArg.loc.fileOffset] = true;
            }
        }
        if (!captures) {
            return;
        }
        // A constructor or opCall is called by its aggregate's name.
        if ((f.isCtorDeclaration() || f.ident == Id.call) && scopes.length) {
            addName(scopes[$ - 1], f.loc, "ctor/opCall owner");
            ctorOwners ~= scopes[$ - 1];
        }
        if (f.ident) {
            addName(f.ident.toString().idup, f.loc, "function");
        }
    }

    override void visit(ASTBase.StructDeclaration d) { enter(d.ident); super.visit(d); leave(); }
    override void visit(ASTBase.UnionDeclaration d) { enter(d.ident); super.visit(d); leave(); }
    override void visit(ASTBase.ClassDeclaration d) { enter(d.ident); super.visit(d); leave(); }
    override void visit(ASTBase.InterfaceDeclaration d) { enter(d.ident); super.visit(d); leave(); }

    override void visit(ASTBase.TemplateDeclaration d) {
        enter(d.ident);
        templates++;
        super.visit(d);
        templates--;
        leave();
    }

    // References. A __LINE__ default argument resolves at the call's `(`, or for a property call at its
    // `.`; a template's at the instance.
    override void visit(ASTBase.IdentifierExp e) { use(e.ident, e.loc); super.visit(e); }
    override void visit(ASTBase.DotIdExp e) { use(e.ident, e.loc); super.visit(e); }
    override void visit(ASTBase.NewExp e) { use(lastIdent(e.newtype), e.loc); super.visit(e); }
    override void visit(ASTBase.TemplateInstance ti) { use(ti.name, ti.loc); useTypeArgs(ti.tiargs); super.visit(ti); }

    // A template argument `a.f` parses as a type, but can be a property call.
    extern (D) final void useTypeArgs(ASTBase.Objects* tiargs) {
        if (!tiargs) {
            return;
        }
        foreach (o; *tiargs) {
            if (o && o.dyncast() == DYNCAST.type) {
                scope kind = new TypeKind();
                (cast(ASTBase.Type) o).accept(kind);
                if (kind.ident) {
                    use(lastIdent(kind.ident), kind.ident.loc);
                }
            }
        }
    }

    override void visit(ASTBase.CallExp e) {
        scope callee = new CalleeName();
        e.e1.accept(callee);
        use(callee.id, e.loc);
        super.visit(e);
    }

    override void visit(ASTBase.VarDeclaration d) {
        // `S s = x;` can call a constructor of S.
        if (d._init) {
            use(lastIdent(d.type), d.loc);
        }
        super.visit(d);
    }

    override void visit(ASTBase.TemplateValueParameter tp) {
        if (capturesLine(tp.defaultValue) && scopes.length) {
            addName(scopes[$ - 1], tp.loc, "template value parameter");
        }
        if (isBareLine(tp.defaultValue)) {
            useSiteLines[tp.defaultValue.loc.fileOffset] = true;
        }
        super.visit(tp);
    }

    override void visit(ASTBase.TemplateMixin tm) {
        use(lastIdent(tm.tqual), tm.loc);
        useTypeArgs(tm.tiargs);
        if (scopes.length) {
            if (auto name = lastName(tm.tqual)) {
                mixins ~= [scopes[$ - 1], name];
                why.require("mixin:" ~ scopes[$ - 1] ~ "<-" ~ name, file ~ ":" ~ tm.loc.linnum.to!string);
            }
        }
        super.visit(tm);
    }

    override void visit(ASTBase.AliasDeclaration d) {
        if (d.ident) {
            if (auto name = lastName(d.type)) {
                aliases ~= [d.ident.toString().idup, name];
                why.require("alias:" ~ d.ident.toString().idup ~ "<-" ~ name, file ~ ":" ~ d.loc.linnum.to!string);
            }
        }
        super.visit(d);
    }

    override void visit(ASTBase.PragmaDeclaration d) {
        const inline = d.ident == Id.Pinline;
        inlines += inline;
        super.visit(d);
        inlines -= inline;
    }

    // LDC's time trace has no event for the analysis of constructor-like and unittest bodies. A compile
    // analyses one of another module only inside a template it instantiates, for one under
    // pragma(inline) (defined in every caller's object, even at -O0), and in CTFE, which has its own
    // event; cross-module inlining (-O) would add any constructor. Those first two stay in the digest,
    // with their lines (debug info, assert and bounds-check messages); the rest are stripped. The
    // parameters are visited here: the transitive visitor goes straight to the body.
    extern (D) final void ctorLikeBody(ASTBase.FuncDeclaration d, void delegate() visitBody) {
        if (d.type) {
            d.type.accept(this);
        }
        ctorLike = true;
        visitBody();
    }

    override void visit(ASTBase.CtorDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.DtorDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.PostBlitDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.StaticCtorDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.StaticDtorDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.InvariantDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }
    override void visit(ASTBase.UnitTestDeclaration d) { ctorLikeBody(d, () => super.visit(d)); }

    override void visitFuncBody(ASTBase.FuncDeclaration f) {
        // A templated constructor reaches here directly, as its template's eponymous member.
        const isCtorLike = ctorLike || f.isCtorDeclaration();
        ctorLike = false;
        noteLineParams(f);
        const lineBody = isCtorLike && f.fbody && (templates || inlines || hasInlinePragma(f.fbody));
        if (lineBody) {
            lineBodies ~= Body(f.fbody.loc.fileOffset, f.endloc.fileOffset, qualified(f.ident));
        }
        if (keep || lineBody || f.isFuncLiteralDeclaration() || !f.fbody ||
                f.endloc.fileOffset < f.fbody.loc.fileOffset) {
            keep++;
            enter(f.ident);
            super.visitFuncBody(f);
            leave();
            keep--;
            return;
        }
        if (f.frequires) {
            foreach (r; *f.frequires) {
                r.accept(this);
            }
        }
        if (f.fensures) {
            foreach (e; *f.fensures) {
                e.ensure.accept(this);
            }
        }
        bodies ~= Body(f.fbody.loc.fileOffset, f.endloc.fileOffset, qualified(f.ident));
    }
}

struct Parsed {
    string path;
    string text;
    string moduleName;
    bool unparsed;
    Body[] bodies;
    Body[] lineBodies;
    Use[] uses;
    uint[] checkLines;
    bool[uint] useSiteLines;
}

Parsed parseModule(string path, Collector collector) {
    Parsed r;
    r.path = path;
    r.text = readText(path);
    r.moduleName = baseName(path).stripExtension;
    const(char)[] input = r.text ~ '\0';
    auto sink = new CountingErrorSink();
    auto m = new ASTBase.Module((path ~ '\0').ptr, Identifier.idPool(path), false, false);
    scope p = new Parser!ASTBase(m, input, false, sink, null, true);
    p.nextToken();
    m.members = p.parseModule();
    if (sink.errors) {
        r.unparsed = true;
        return r;
    }
    if (p.md) {
        string[] parts;
        foreach (pkg; p.md.packages) {
            parts ~= pkg.toString().idup;
        }
        parts ~= p.md.id.toString().idup;
        r.moduleName = parts.join(".");
    }
    collector.bodies = null;
    collector.lineBodies = null;
    collector.uses = null;
    collector.checkLines = null;
    collector.useSiteLines = null;
    collector.scopes = null;
    collector.file = path;
    m.accept(collector);
    r.bodies = collector.bodies;
    r.bodies.sort!((a, b) => a.first < b.first);
    r.lineBodies = collector.lineBodies;
    r.lineBodies.sort!((a, b) => a.first < b.first);
    r.uses = collector.uses;
    r.checkLines = collector.checkLines;
    r.useSiteLines = collector.useSiteLines;
    return r;
}

/// explain, if given, receives a line per stripped body and per token whose line is hashed.
string digestFile(ref Parsed p, const bool[string] lineNames, string[]* explain = null) {
    SHA256 sha;
    sha.start();
    sha.put(cast(const(ubyte)[]) FORMAT_VERSION);
    string hex() { return toHexString!(LetterCase.lower)(sha.finish()).idup; }
    if (p.unparsed) {
        sha.put(cast(const(ubyte)[]) "\0unparsed\0");
        sha.put(cast(const(ubyte)[]) p.text);
        return FORMAT_VERSION ~ " " ~ hex() ~ "\nmodule " ~ p.moduleName ~ "\nunparsed\n";
    }

    void putLine(uint line, const(char)[] what) {
        sha.put(cast(const(ubyte)[]) "@");
        sha.put(cast(const(ubyte)[]) line.to!string);
        sha.put(0);
        if (explain && what.length) {
            *explain ~= "pos " ~ line.to!string ~ " " ~ what.idup;
        }
    }

    if (explain) {
        uint lineAt(uint off) {
            uint n = 1;
            foreach (c; p.text[0 .. off]) {
                n += c == '\n';
            }
            return n;
        }
        foreach (b; p.bodies) {
            *explain ~= "body " ~ lineAt(b.first).to!string ~ " " ~ lineAt(b.last).to!string ~ " " ~ b.owner;
        }
    }

    const(char)[] input = p.text ~ '\0';
    auto sink = new CountingErrorSink();
    scope lexer = new Lexer((p.path ~ '\0').ptr, input.ptr, 0, input.length, false, false, sink, null);
    auto bodies = p.bodies;
    size_t next = 0;      // first body that may still contain the current token
    uint skipUntil = 0;   // inside a body until this offset (inclusive)
    bool skipping = false;
    string owner;         // the body being skipped
    string[] locReaders;
    bool locAnywhere = false;
    TOK prev1 = TOK.reserved, prev2 = TOK.reserved;
    uint prevLine = 0;
    auto lineBodies = p.lineBodies;
    size_t lnext = 0;
    uint lineBodyUntil = 0;   // inside a line-hashed body until this offset (inclusive); 0: not inside
    uint lineBodyLine = 0;    // the last line hashed in it
    string lineBodyOwner;
    bool[string] useKeys;     // explain: "<line> <name>" of each use
    if (explain) {
        foreach (u; p.uses) {
            useKeys[u.line.to!string ~ " " ~ u.id.toString().idup] = true;
        }
    }
    while (lexer.nextToken() != TOK.endOfFile) {
        const off = lexer.token.loc.fileOffset;
        const line = lexer.token.loc.linnum;
        const value = lexer.token.value;
        if (skipping && off > skipUntil) {
            skipping = false;
        }
        while (next < bodies.length && bodies[next].first <= off) {
            if (bodies[next].last >= off) {
                if (!skipping) {
                    skipping = true;
                    skipUntil = bodies[next].last;
                    owner = bodies[next].owner;
                } else if (bodies[next].last > skipUntil) {
                    skipUntil = bodies[next].last;
                }
            }
            next++;
        }
        if (value == TOK.identifier && prev1 == TOK.leftParenthesis && prev2 == TOK.traits &&
                lexer.token.ident.toString() == "getLocation") {
            if (skipping) {
                locReaders ~= p.moduleName ~ "." ~ owner;
            } else {
                locAnywhere = true;
            }
        }
        if (lineBodyUntil && off > lineBodyUntil) {
            lineBodyUntil = 0;
        }
        while (lnext < lineBodies.length && lineBodies[lnext].first <= off) {
            if (lineBodies[lnext].last >= off && lineBodies[lnext].last > lineBodyUntil) {
                if (!lineBodyUntil) {
                    lineBodyLine = 0;
                    lineBodyOwner = lineBodies[lnext].owner;
                }
                lineBodyUntil = lineBodies[lnext].last;
            }
            lnext++;
        }
        if (!skipping) {
            sha.put(cast(const(ubyte)[]) lexer.token.ptr[0 .. lexer.p - lexer.token.ptr]);
            sha.put(0);
            if (value == TOK.line && off !in p.useSiteLines) {
                putLine(line, "__LINE__");
            } else if (value == TOK.leftParenthesis && prev1 == TOK.mixin_) {
                putLine(prevLine, "mixin(");
            }
            if (lineBodyUntil && line != lineBodyLine) {
                putLine(line, lineBodyLine ? null : "{" ~ lineBodyOwner ~ "}");
                lineBodyLine = line;
            }
            if (explain && value == TOK.identifier) {
                const name = cast(string) lexer.token.ident.toString();
                if (name in lineNames && (line.to!string ~ " " ~ name) !in useKeys) {
                    *explain ~= "lex " ~ line.to!string ~ " " ~ name;
                }
            }
        }
        prev2 = prev1;
        prev1 = value;
        prevLine = line;
    }
    const anyName = (ANY_NAME in lineNames) !is null;
    foreach (u; p.uses) {
        const name = cast(string) u.id.toString();
        if (anyName || name in lineNames) {
            sha.put(cast(const(ubyte)[]) name);
            putLine(u.line, name);
        }
    }
    foreach (l; p.checkLines) {
        putLine(l, "{check}");
    }
    if (sink.errors) {
        sha.put(cast(const(ubyte)[]) "\0unlexed\0");
        sha.put(cast(const(ubyte)[]) p.text);
    }
    string result = FORMAT_VERSION ~ " " ~ hex() ~ "\nmodule " ~ p.moduleName ~ "\n";
    foreach (r; locReaders.sort.uniq) {
        result ~= "locreader " ~ r ~ "\n";
    }
    if (locAnywhere) {
        result ~= "locanywhere\n";
    }
    return result;
}

/// Line-capturing names: functions and templates with a __LINE__ default, and the owners of a constructor
/// or opCall with one (also in ctors). A names file has a line per name, "<name>" or "<name> ctor";
/// ANY_NAME stands for every name (an unparsed module with a __LINE__ token declares it).
struct Names {
    bool[string] all;
    bool[string] ctors;
}

/// Parses srcs and returns the names file lines for the line-capturing names they declare, given those
/// their dependencies declare. why, if given, receives each own name's provenance.
string[] collectNames(ref Parsed[] parsed, string[] srcs, ref Names names, string[string]* why = null) {
    auto collector = new Collector();
    const first = parsed.length;
    foreach (src; srcs) {
        parsed ~= parseModule(src, collector);
    }
    bool[string] own;
    void add(string n, bool ctor) {
        own[n] = true;
        names.all[n] = true;
        if (ctor) {
            names.ctors[n] = true;
        }
    }
    foreach (n; collector.lineNames) {
        add(n, false);
    }
    foreach (n; collector.ctorOwners) {
        add(n, true);
    }
    // The names an unparsed module declares are unknown.
    foreach (ref p; parsed[first .. $]) {
        if (p.unparsed && p.text.canFind("__LINE__")) {
            add(ANY_NAME, true);
        }
    }
    // An alias of a name is a name. An aggregate that mixes in a constructor owner is one.
    void propagate(string kind, string[2] pair, bool ctor) {
        if (why) {
            const key = kind ~ ":" ~ pair[0] ~ "<-" ~ pair[1];
            (*why)[pair[0]] = collector.why.get(key, "?") ~ " " ~ kind ~ " of " ~ pair[1];
        }
        add(pair[0], ctor);
    }
    for (bool changed = true; changed;) {
        changed = false;
        foreach (pair; collector.aliases) {
            if (pair[1] in names.all && pair[0] !in names.all) {
                propagate("alias", pair, (pair[1] in names.ctors) !is null);
                changed = true;
            } else if (pair[1] in names.ctors && pair[0] !in names.ctors) {
                propagate("alias", pair, true);
                changed = true;
            }
        }
        foreach (pair; collector.mixins) {
            if (pair[1] in names.ctors && pair[0] !in names.ctors) {
                propagate("mixin", pair, true);
                changed = true;
            }
        }
    }
    if (why) {
        foreach (n; own.byKey) {
            if (n !in *why) {
                (*why)[n] = collector.why.get(n, "(dependency)");
            }
        }
    }
    string[] lines;
    foreach (n; own.keys.sort) {
        lines ~= n in names.ctors ? n ~ " ctor" : n;
    }
    return lines;
}

void readNames(string path, ref Names names) {
    foreach (line; readText(path).lineSplitter) {
        if (line.endsWith(" ctor")) {
            const n = line[0 .. $ - " ctor".length].idup;
            names.all[n] = true;
            names.ctors[n] = true;
        } else if (line.length) {
            names.all[line.idup] = true;
        }
    }
}

int digestCommand(string[] args) {
    string namesOut;
    Names names;
    string[] rest;
    foreach (a; args) {
        if (a.startsWith("--names-out=")) {
            namesOut = a["--names-out=".length .. $];
        } else if (a.startsWith("--names=")) {
            readNames(a["--names=".length .. $], names);
        } else {
            rest ~= a;
        }
    }
    if (!namesOut.length || rest.length % 2 != 0) {
        fprintf(stderr, "usage: ifc_digest digest --names-out=<file> [--names=<file>]... <out> <src> ...\n");
        return 2;
    }
    string[] outs, srcs;
    for (size_t i = 0; i < rest.length; i += 2) {
        outs ~= rest[i];
        srcs ~= rest[i + 1];
    }
    Parsed[] parsed;
    auto own = collectNames(parsed, srcs, names);
    foreach (i, ref p; parsed) {
        std.file.write(outs[i], digestFile(p, names.all));
    }
    std.file.write(namesOut, own.length ? own.join("\n") ~ "\n" : "");
    return 0;
}

int printCommand(string[] args, bool namesOnly, bool explain = false) {
    Names names;
    string[] srcs;
    bool withWhy = false;
    string outPath;
    foreach (a; args) {
        if (a.startsWith("--names=")) {
            readNames(a["--names=".length .. $], names);
        } else if (a == "--why") {
            withWhy = true;
        } else if (a.startsWith("--out=")) {
            outPath = a["--out=".length .. $];
        } else {
            srcs ~= a;
        }
    }
    auto output = outPath.length ? File(outPath, "w") : std.stdio.stdout;
    Parsed[] parsed;
    string[string] why;
    auto own = collectNames(parsed, srcs, names, withWhy ? &why : null);
    if (namesOnly) {
        foreach (n; own) {
            output.writeln(withWhy ? n ~ "\t" ~ why.get(n.endsWith(" ctor") ? n[0 .. $ - 5] : n, "?") : n);
        }
        return 0;
    }
    foreach (ref p; parsed) {
        string[] lines;
        const d = digestFile(p, names.all, explain ? &lines : null);
        output.write(p.path, ":\n", d);
        foreach (l; lines) {
            output.writeln(l);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------------
// prune

string resolved(const(char)[] path) {
    auto r = realpath(path.toStringz, null);
    if (!r) {
        return null;
    }
    scope (exit) free(r);
    return fromStringz(r).idup;
}

/// The path on a dependency line of -makedeps output ("  <path> \"), with dmd's make escapes
/// ("$$", "\#", "\ ", "\:") undone.
string makeDepsPath(const(char)[] line) {
    while (line.length && (line[0] == ' ' || line[0] == '\t')) {
        line = line[1 .. $];
    }
    if (line.endsWith(" \\")) {
        line = line[0 .. $ - 2];
    }
    char[] path;
    for (size_t i = 0; i < line.length; i++) {
        if (line[i] == '$' && i + 1 < line.length && line[i + 1] == '$') {
            i++;
        } else if (line[i] == '\\' && i + 1 < line.length && " \t#:".canFind(line[i + 1])) {
            i++;
        }
        path ~= line[i];
    }
    return path.idup;
}

/// The JSON string value that follows `key` in `line` (LDC writes one trace event per line).
string jsonField(const(char)[] line, string key) {
    auto start = line.indexOf(key);
    if (start < 0) {
        return null;
    }
    char[] value;
    for (size_t i = start + key.length; i < line.length; i++) {
        const c = line[i];
        if (c == '"') {
            return value.idup;
        }
        if (c == '\\' && i + 1 < line.length) {
            const e = line[++i];
            switch (e) {
                case 'n': value ~= '\n'; break;
                case 't': value ~= '\t'; break;
                case 'r': value ~= '\r'; break;
                case 'b': value ~= '\b'; break;
                case 'f': value ~= '\f'; break;
                case 'u':
                    if (i + 4 < line.length) {
                        value ~= cast(char) line[i + 1 .. i + 5].to!uint(16);
                        i += 4;
                    }
                    break;
                default: value ~= e;
            }
        } else {
            value ~= c;
        }
    }
    return null;
}

/// At most the first 200 characters of s.
string clip(const(char)[] s) {
    return (s.length > 200 ? s[0 .. 200] : s).idup;
}

/// "dir/foo.d:12" or "dir/foo.d-mixin-34:12" -> "dir/foo.d"
string locFile(string loc) {
    auto colon = loc.length;
    while (colon > 0 && isDigit(loc[colon - 1])) {
        colon--;
    }
    if (colon < loc.length && colon > 0 && loc[colon - 1] == ':') {
        loc = loc[0 .. colon - 1];
    }
    for (;;) {
        auto m = loc.length;
        while (m > 0 && isDigit(loc[m - 1])) {
            m--;
        }
        if (m < loc.length && loc[0 .. m].endsWith("-mixin-")) {
            loc = loc[0 .. m - "-mixin-".length];
        } else {
            return loc;
        }
    }
}

int pruneCommand(string[] args) {
    string candidatesPath, depsPath, tracePath, bodyUsePath, outPath;
    foreach (a; args) {
        if (a.startsWith("--candidates=")) candidatesPath = a["--candidates=".length .. $];
        else if (a.startsWith("--makedeps=")) depsPath = a["--makedeps=".length .. $];
        else if (a.startsWith("--trace=")) tracePath = a["--trace=".length .. $];
        else if (a.startsWith("--body-use=")) bodyUsePath = a["--body-use=".length .. $];
        else if (a.startsWith("--out=")) outPath = a["--out=".length .. $];
    }
    if (!candidatesPath.length || !depsPath.length || !outPath.length || !tracePath.length == !bodyUsePath.length) {
        fprintf(stderr, "usage: ifc_digest prune --candidates=<file> --makedeps=<file> "
            ~ "--trace=<file>|--body-use=<file> --out=<file>\n");
        return 2;
    }

    struct Candidate {
        string input, digest;
        bool loaded, bodyUsed;
        string moduleName;
        string reason;  // why bodyUsed, with IFC_DIGEST_LIST
    }
    const listing = getenv("IFC_DIGEST_LIST") !is null;
    Candidate[] cands;
    size_t[][string] byReal;  // real path -> candidates (two libraries can export one file)
    bool[size_t] unresolved;
    foreach (line; readText(candidatesPath).lineSplitter) {
        auto f1 = line.indexOf('\t');
        if (f1 < 0) {
            continue;
        }
        auto rest = line[f1 + 1 .. $];
        auto f2 = rest.indexOf('\t');
        if (f2 < 0) {
            continue;
        }
        const i = cands.length;
        cands ~= Candidate(line[0 .. f1].idup, rest[f2 + 1 .. $].idup);
        auto ri = resolved(line[0 .. f1]);
        if (!ri) {
            unresolved[i] = true;
            continue;
        }
        byReal[ri] ~= i;
        if (auto rv = resolved(rest[0 .. f2])) {
            if (rv != ri) {
                byReal[rv] ~= i;
            }
        }
    }

    // Prune nothing when the compile's dependencies cannot be mapped to inputs.
    void giveUp(string why) {
        fprintf(stderr, "ifc_digest prune: %.*s; pruning nothing\n", cast(int) why.length, why.ptr);
        std.file.write(outPath, "");
    }

    // -makedeps lists every file the compile read, modules and string imports alike, once per read: a
    // candidate read twice, or with no "Sema1: Module" event, may have been string-imported.
    bool keepAll = false;
    auto reads = new uint[cands.length];
    bool targetLine = true;  // "<output>: \"
    foreach (line; File(depsPath).byLine) {
        if (targetLine) {
            targetLine = false;
            continue;
        }
        auto path = makeDepsPath(line);
        if (!path.length) {
            continue;
        }
        auto r = resolved(path);
        if (!r) {
            giveUp("unresolved dependency " ~ path);
            return 0;
        }
        foreach (ci; byReal.get(r, null)) {
            cands[ci].loaded = true;
            reads[ci]++;
        }
    }

    void markCandidate(size_t ci, lazy string why) {
        if (!cands[ci].bodyUsed) {
            cands[ci].bodyUsed = true;
            if (listing) {
                cands[ci].reason = why;
            }
        }
    }

    string[] readers;
    size_t[string] byModule;
    foreach (i, ref c; cands) {
        if (!c.loaded) {
            continue;
        }
        foreach (line; readText(c.digest).lineSplitter) {
            if (line.startsWith("module ")) {
                c.moduleName = line["module ".length .. $].idup;
                byModule[c.moduleName] = i;
            } else if (line.startsWith("locreader ")) {
                readers ~= line["locreader ".length .. $].idup;
            } else if (line == "locanywhere" && tracePath.length) {
                keepAll = true;
            } else if (line == "unparsed") {
                markCandidate(i, "unparsed");
            }
        }
    }

    // Marks the modules named in a location reader's template arguments: their declarations' lines
    // reach the output.
    void markNamedModules(const(char)[] s, lazy string why) {
        size_t i = 0;
        while (i < s.length) {
            if (!(isAlphaNum(s[i]) || s[i] == '_')) {
                i++;
                continue;
            }
            auto j = i;
            while (j < s.length && (isAlphaNum(s[j]) || s[j] == '_' || s[j] == '.')) {
                j++;
            }
            auto path = s[i .. j];
            for (auto k = path.length; k > 0; k--) {
                if (k == path.length || path[k] == '.') {
                    if (auto ci = (cast(string) path[0 .. k]) in byModule) {
                        markCandidate(*ci, why);
                        break;
                    }
                }
            }
            i = j;
        }
    }

    // Marks the candidates of the file of a body or location ("dir/foo.d:12", "dir/foo.d-mixin-34").
    // False, after giving up, if no input holds that file.
    bool markUsed(string loc, lazy string why) {
        auto r = resolved(locFile(loc));
        if (!r) {
            giveUp("unresolved body location " ~ loc);
            return false;
        }
        foreach (ci; byReal.get(r, null)) {
            markCandidate(ci, why);
        }
        return true;
    }

    bool[string] analysedModules;
    ulong traceBytes = 0;
    if (bodyUsePath.length) {
        // -body-use reports __traits(getLocation) reads itself, so the location readers play no part.
        foreach (line; File(bodyUsePath).byLine) {
            if (line.startsWith("module ")) {
                analysedModules[line["module ".length .. $].idup] = true;
            } else if (line.startsWith("body ") || line.startsWith("location ")) {
                if (!markUsed(line[line.indexOf(' ') + 1 .. $].idup, line[0 .. line.indexOf(' ')].idup)) {
                    return 0;
                }
            }
        }
    } else {
        bool inTrace = false;
        foreach (line; File(tracePath).byLine) {
            traceBytes += line.length + 1;
            if (!inTrace) {
                inTrace = line == "{";
                if (!inTrace) {
                    writeln(line);
                }
                continue;
            }
            if (line.canFind(`"name": "Sema1: Module `)) {
                analysedModules[jsonField(line, `"name": "`)["Sema1: Module ".length .. $]] = true;
                continue;
            }
            if (!line.canFind(`"name": "Sema3: Func `) && !line.canFind(`"name": "CTFE func: `)) {
                continue;
            }
            auto loc = jsonField(line, `"loc":"`);
            if (!loc.length || loc == "<no file>") {
                continue;
            }
            if (!markUsed(loc, clip(jsonField(line, `"name": "`)) ~ " @ " ~ loc)) {
                return 0;
            }
            if (readers.length) {
                auto detail = jsonField(line, `"detail": "`);
                foreach (reader; readers) {
                    if (detail.startsWith(reader) &&
                            (detail.length == reader.length || "!(.".canFind(detail[reader.length]))) {
                        markNamedModules(detail[reader.length .. $], "locreader " ~ clip(detail));
                    }
                }
            }
        }
        if (!inTrace) {
            giveUp("no time trace on the compiler's stdout");
            return 0;
        }
    }

    foreach (i, ref c; cands) {
        if (c.loaded && (reads[i] > 1 || c.moduleName !in analysedModules)) {
            markCandidate(i, reads[i] > 1 ? "read " ~ reads[i].to!string ~ " times" : "module not analysed");
        }
    }

    if (getenv("IFC_DIGEST_STATS")) {
        size_t notLoaded, unused;
        foreach (i, ref c; cands) {
            if (i in unresolved) {
                continue;
            }
            notLoaded += !c.loaded;
            unused += c.loaded && !c.bodyUsed && !keepAll;
        }
        fprintf(stderr, "ifc_digest prune: trace %llu MiB; %zu candidates: %zu not loaded, "
            ~ "%zu loaded with no body used\n", traceBytes >> 20, cands.length, notLoaded, unused);
    }
    // Bench only: bazel keeps no unused_inputs_list file on disk, so the build log carries the list,
    // and why each other loaded input was kept (the inputs not loaded follow from -makedeps alone).
    if (listing) {
        foreach (i, ref c; cands) {
            if (i in unresolved || !c.loaded) {
                continue;
            }
            if (!c.bodyUsed && !keepAll) {
                fprintf(stderr, "ifc_digest pruned %.*s %.*s\n", cast(int) outPath.length, outPath.ptr,
                    cast(int) c.input.length, c.input.ptr);
            } else {
                const why = c.bodyUsed ? c.reason : "locanywhere";
                fprintf(stderr, "ifc_digest kept %.*s %.*s %.*s\n", cast(int) outPath.length, outPath.ptr,
                    cast(int) c.input.length, c.input.ptr, cast(int) why.length, why.ptr);
            }
        }
    }

    auto output = File(outPath, "w");
    foreach (i, ref c; cands) {
        if (i in unresolved) {
            continue;
        }
        if (!c.loaded) {
            output.writeln(c.input);
            output.writeln(c.digest);
        } else if (!c.bodyUsed && !keepAll) {
            output.writeln(c.input);
        }
    }
    return 0;
}

string[] expandArgFiles(string[] args) {
    string[] result;
    foreach (a; args) {
        if (a.startsWith("@")) {
            foreach (line; readText(a[1 .. $]).lineSplitter) {
                if (line.length) {
                    result ~= line.idup;
                }
            }
        } else {
            result ~= a;
        }
    }
    return result;
}

int main(string[] argv) {
    Id.initialize();
    global._init();
    global.params.useUnitTests = true;
    ASTBase.Type._init();

    auto args = expandArgFiles(argv[1 .. $]);
    if (args.length >= 1) {
        switch (args[0]) {
            case "digest": return digestCommand(args[1 .. $]);
            case "prune": return pruneCommand(args[1 .. $]);
            case "names": return printCommand(args[1 .. $], true);
            case "print": return printCommand(args[1 .. $], false);
            case "explain": return printCommand(args[1 .. $], false, true);
            default: break;
        }
    }
    fprintf(stderr, "usage: ifc_digest digest|prune|names|print ...\n");
    return 2;
}
