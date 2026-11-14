# Agila Language Specification

**Agila** is a Pythonic syntax layer for **Swift**. It maps 1:1 to and from Swift, providing significant indentation, concise fixed-width and collection types, references/pointers without punctuation soup, Pythonic `f"..."` strings, and zero-overhead list/set/dict comprehensions while preserving 100% of Swift's type safety, value semantics, ARC memory management, and native compiler toolchain (`swiftc`).

Every line of Agila compiles deterministically to readable, standard Swift, and every canonical Swift construct maps cleanly back to Agila.

---

## Side-by-Side Comparison

| Feature | Agila (`.agila`) | Swift (`.swift`) |
| :--- | :--- | :--- |
| **Comments** | `# line comment` | `// line comment` |
| **Imports** | `import Foundation`<br>`from Foundation import *` | `import Foundation`<br>`import Foundation` |
| **Constants (Root)** | `MAX_ITEMS = 64` | `let MAX_ITEMS = 64` |
| **Immutable Variable** | `x: i32 = 10` | `let x: Int32 = 10` |
| **Mutable Variable** | `var x: i32 = 10` | `var x: Int32 = 10` |
| **Type Alias** | `type Byte = u8` | `typealias Byte = UInt8` |
| **Functions** | `def add(a: i32, b: i32) -> i32:` | `func add(_ a: Int32, _ b: Int32) -> Int32 {` |
| **Void Functions** | `def log(msg: str):` | `func log(_ msg: String) {` |
| **Mutating Methods** | `mut def reset(self):` | `mutating func reset() {` |
| **Initializers** | `def init(x: f64, y: f64):` | `init(_ x: Double, _ y: Double) {` |
| **Reference Type (`inout`)** | `s: ref[Shape]` | `_ s: inout Shape` |
| **Take Reference (`&`)** | `scale(s.ref, 2.0)` | `scale(&s, 2.0)` |
| **Address / Pointer Type** | `p: addr[i32]`<br>`mp: addr[mut i32]` | `_ p: UnsafePointer<Int32>`<br>`_ mp: UnsafeMutablePointer<Int32>` |
| **Dereference (`pointee`)** | `val(p)` / `val(2, pp)` | `p.pointee` / `pp.pointee.pointee` |
| **Type Cast** | `cast(Shape, raw)` | `(raw as! Shape)` |
| **Scalar Conversion** | `f64(x)`, `i32(n)`, `str(v)` | `Double(x)`, `Int32(n)`, `String(v)` |
| **Formatted Strings** | `f"Hello {name}!"` | `"Hello \(name)!"` |
| **Logical Operators** | `a and b or not c` | `a && b || !c` |
| **Booleans & Nil** | `true`, `false`, `nil` (`None`) | `true`, `false`, `nil` |
| **Conditionals** | `if c:` / `elif d:` / `else:` | `if c {` / `} else if d {` / `} else {` |
| **Guard Statements** | `guard x > 0:` | `guard x > 0 else {` |
| **Range Loops** | `for i in range(n):`<br>`for i in range(a, b):`<br>`for i in range(a, b, s):` | `for i in 0..<n {`<br>`for i in a..<b {`<br>`for i in stride(from: a, to: b, by: s) {` |
| **Collection Loops** | `for item in items:` | `for item in items {` |
| **List Comprehension** | `sq: list[isize] = [x * x for x in range(8) if x > 0]` | `var sq: [Int] = []` + `for` loop with `.append(...)` |
| **Set Comprehension** | `ev: set[isize] = {x for x in range(8) if x % 2 == 0}` | `var ev: Set<Int> = Set()` + `for` loop with `.insert(...)` |
| **Dict Comprehension** | `mp: dict[isize, isize] = {x: x * 10 for x in range(8) if x > 0}` | `var mp: [Int: Int] = [:]` + `for` loop with `mp[k] = v` |
| **Do-While Loop** | `do:` ... `while cond` | `repeat {` ... `} while cond` |
| **Switch / Match** | `switch k:` / `case .a:` / `default:` | `switch k {` / `case .a:` / `default:` |

---

## Core Design Principles

### 1. Significant Whitespace & Auto-Detected Indentation
Blocks start with a trailing colon (`:`) and are delimited by indentation rather than `{` and `}`.
- **Auto-Detected Indentation**: Agila automatically detects the file's indentation unit from the **first indented line of code**—whether 2 spaces, 4 spaces, 8 spaces, or a single tab (`\t`).
- Every subsequent indented line must be an exact multiple of that detected indentation unit, and block openings must increase indentation by exactly 1 level.
- Mixing spaces and tabs on the same indentation prefix or trailing whitespace at the end of a line is rejected with an exact `line:col` diagnostic.
- Output formatting (`--agila` or `--from-swift`) defaults to 4 spaces and can be configured via `--indent <1..63|tab>`.

### 2. Concise Types
Agila replaces verbose Swift type names with compact, unambiguous identifiers:

| Agila Type | Swift Type | Description |
| :--- | :--- | :--- |
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` | Signed fixed-width integers |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` | Unsigned fixed-width integers |
| `isize`, `usize` | `Int`, `UInt` | Pointer-sized integers |
| `f32`, `f64` | `Float`, `Double` | IEEE-754 floating-point numbers |
| `bool` | `Bool` | Boolean (`true` / `false`) |
| `char`, `rune` | `Character` | Extended grapheme cluster character |
| `str` | `String` | UTF-8 string value type |
| `cstr` | `StaticString` | Static string literal |
| `any` | `Any` | Existential any type |
| `void` | `Void` | Empty return type |
| `list[T]` | `[T]` | Dynamic array (`Array<T>`) |
| `set[T]` / `unordered_set[T]` | `Set<T>` | Hash set (`Set<T>`) |
| `dict[K, V]` / `unordered_map[K, V]` | `[K: V]` | Dictionary (`Dictionary<K, V>`) |
| `T?` | `T?` | Optional type (`Optional<T>`) |

### 3. References, Pointers & Type Casts
Agila eliminates prefix `&` and unsafe pointer verbosity with explicit, readable syntax:
- **Inout References**:
  - `ref[T]` (or `mut_ref[T]`) in parameter types maps to `inout T`.
  - `x.ref` (or `x.mut_ref`, `x.addr`) in expressions maps to `&x` (including member/subscript chains like `items[i].ref` -> `&items[i]`).
- **Unsafe Pointers**:
  - `addr[T]` maps to `UnsafePointer<T>`.
  - `addr[mut T]` maps to `UnsafeMutablePointer<T>`.
  - `val(p)` dereferences a pointer to `p.pointee`.
  - `val(2, pp)` (or any depth `1..16`) dereferences multi-level pointers to `pp.pointee.pointee`.
- **Casts & Scalar Conversions**:
  - `cast(TargetType, expr)` maps to `(expr as! TargetType)`.
  - Functional scalar conversions `i32(x)`, `f64(x)`, `isize(x)`, `str(x)` map directly to `Int32(x)`, `Double(x)`, `Int(x)`, `String(x)`.

### 4. Comprehensions (List, Set, and Dict)
Agila provides Pythonic comprehensions that transpile 1:1 to pre-initialized Swift collections and native loops (and fold back into comprehensions when converting Swift to Agila):

```python
# List comprehension -> Swift `[Int]`
squares: list[isize] = [x * x for x in range(1, 7) if x % 2 == 0]

# Set comprehension -> Swift `Set<Int>`
evens: set[isize] = {x for x in range(8) if x % 2 == 0}

# Dict comprehension -> Swift `[Int: Int]`
scaled: dict[isize, isize] = {x: x * 10 for x in squares if x > 0}
```

---

## Complete Example

**Agila (`examples/shapes.agila`):**
```python
# Structs, enums, references (`ref[T]`), type casts (`cast`), and switch/case in Agila
import Foundation

enum ShapeKind(i32):
    circle = 0
    rectangle = 1

struct Vec2:
    x: f64
    y: f64

struct Shape:
    kind: ShapeKind
    origin: Vec2
    width: f64
    height: f64

def scale_shape(s: ref[Shape], factor: f64):
    s.width *= factor
    s.height *= factor

def area(s: Shape) -> f64:
    switch s.kind:
        case .circle:
            return 3.141592653589793 * s.width * s.width
        case .rectangle:
            return s.width * s.height

def main():
    radii: list[f64] = [f64(i + 1) * 2.5 for i in range(3)]
    for i in range(3):
        var c: Shape = Shape(kind: .circle, origin: Vec2(x: 0.0, y: 0.0), width: radii[i], height: radii[i])
        scale_shape(c.ref, 1.0)
        raw: any = c
        unpacked: Shape = cast(Shape, raw)
        print(str(format: "Circle area (r=%.1f): %.4f", unpacked.width, area(unpacked)))
```

**Generated Swift (`./agila examples/shapes.agila`):**
```swift
// Structs, enums, references (`ref[T]`), type casts (`cast`), and switch/case in Agila
import Foundation

enum ShapeKind: Int32 {
    case circle = 0
    case rectangle = 1
}

struct Vec2 {
    var x: Double
    var y: Double
}

struct Shape {
    var kind: ShapeKind
    var origin: Vec2
    var width: Double
    var height: Double
}

func scale_shape(_ s: inout Shape, _ factor: Double) {
    s.width *= factor
    s.height *= factor
}

func area(_ s: Shape) -> Double {
    switch s.kind {
    case .circle:
        return 3.141592653589793 * s.width * s.width
    case .rectangle:
        return s.width * s.height
    }
}

func main() {
    var radii: [Double] = []
    for i in 0..<3 {
        radii.append(Double(i + 1) * 2.5)
    }
    for i in 0..<3 {
        var c: Shape = Shape(kind: .circle, origin: Vec2(x: 0.0, y: 0.0), width: radii[i], height: radii[i])
        scale_shape(&c, 1.0)
        let raw: Any = c
        let unpacked: Shape = (raw as! Shape)
        print(String(format: "Circle area (r=%.1f): %.4f", unpacked.width, area(unpacked)))
    }
}
```

---

## Formal Grammar (EBNF)

```ebnf
module          = { statement | COMMENT | NEWLINE } ;

statement       = simple_stmt NEWLINE
                | compound_stmt ;

simple_stmt     = import_stmt
                | type_alias
                | var_decl
                | comprehension_decl
                | root_const_decl
                | return_stmt
                | expr_stmt
                | "break" | "continue" | "fallthrough" | "pass" ;

import_stmt     = "import" module_path
                | "from" module_path "import" ( "*" | ident_list ) ;

type_alias      = "type" IDENT "=" type_spec ;

var_decl        = [ qualifiers ] IDENT ":" type_spec [ "=" expr ]
                | "var" IDENT "=" expr ;

comprehension_decl
                = [ qualifiers ] IDENT ":" type_spec "=" ( list_comp | set_comp | dict_comp ) ;

list_comp       = "[" expr "for" IDENT "in" iterable [ "if" expr ] "]" ;
set_comp        = "{" expr "for" IDENT "in" iterable [ "if" expr ] "}" ;
dict_comp       = "{" expr ":" expr "for" IDENT "in" iterable [ "if" expr ] "}" ;

root_const_decl = IDENT "=" expr ;

compound_stmt   = func_def
                | type_def
                | if_stmt
                | guard_stmt
                | for_stmt
                | while_stmt
                | do_while_stmt
                | switch_stmt
                | try_stmt
                | defer_stmt ;

func_def        = [ qualifiers ] ( "def" | "fn" ) ( IDENT | "init" ) "(" [ param_list ] ")"
                  [ "async" ] [ "throws" ] [ "->" type_spec ] ":" suite ;

type_def        = ( "struct" | "class" | "protocol" | "extension" | "actor" ) IDENT [ "(" type_list ")" ] ":" suite
                | "enum" IDENT [ "(" type_spec ")" ] ":" suite ;

if_stmt         = "if" expr ":" suite
                  { "elif" expr ":" suite }
                  [ "else" ":" suite ] ;

guard_stmt      = "guard" expr ":" suite ;

for_stmt        = "for" IDENT "in" iterable ":" suite ;
iterable        = "range" "(" expr [ "," expr [ "," expr ] ] ")" | expr ;

while_stmt      = "while" expr ":" suite ;
do_while_stmt   = "do" ":" suite "while" expr NEWLINE ;

switch_stmt     = ( "switch" | "match" ) expr ":" INDENT { case_clause } DEDENT ;
case_clause     = ( "case" expr_list | "default" ) ":" suite ;

suite           = NEWLINE INDENT { statement } DEDENT ;

type_spec       = "i8" | "i16" | "i32" | "i64"
                | "u8" | "u16" | "u32" | "u64"
                | "isize" | "usize" | "f32" | "f64"
                | "bool" | "char" | "rune" | "str" | "cstr" | "any" | "void"
                | "ref" "[" type_spec "]"
                | "addr" "[" [ "mut" ] type_spec "]"
                | "list" "[" type_spec "]"
                | "set" "[" type_spec "]"
                | "dict" "[" type_spec "," type_spec "]"
                | type_spec "?"
                | IDENT ;
```

---

## Reference CLI (`agila`)

Agila is implemented as a zero-dependency, single-file native Swift compiler & formatter (`agila.swift`).

### Building & Installing

```sh
# Build optimized binary
make

# Run the 18-test conformance suite
make test

# Run the transpilation and code-size benchmark
make bench

# Install to /usr/local/bin (or custom PREFIX)
make install
```

### CLI Usage

```sh
# 1. Transpile Agila -> Swift (stdout)
./agila examples/shapes.agila

# 2. Transpile and execute directly via swiftc
./agila examples/hello.agila --run
./agila examples/shapes.agila --run
./agila examples/tabs.agila --run
./agila examples/comprehensions.agila --run

# 3. Compile Agila -> native binary
./agila examples/shapes.agila --compile -o shapes

# 4. Canonicalize / reformat Agila source (4 spaces or tabs)
./agila --agila examples/shapes.agila
./agila --agila --indent tab examples/shapes.agila

# 5. Transpile Swift -> Agila
./agila --from-swift input.swift
./agila --from-swift --indent 2 input.swift
```

---

## Benchmark

Measured on a 250-function synthetic systems & collections workload (`./agila --bench`):

| Metric | Result |
| :--- | :--- |
| **Swift Source Size** | `99,650 bytes` (`97.3 KiB`) |
| **Agila (4-space) Size** | `90,373 bytes` (`88.3 KiB`, **-9.3%** vs Swift) |
| **Agila (tab `\t`) Size** | `79,361 bytes` (`77.5 KiB`, **-20.4%** vs Swift) |
| **Agila (4-sp) → Swift** | `~138 files/s` (`11.9 MiB/s`) |
| **Agila (tab) → Swift** | `~144 files/s` (`10.9 MiB/s`) |
| **Swift → Agila (4-sp)** | `~132 files/s` (`12.6 MiB/s`) |
