# Proposal: Packages and Namespace Isolation for Action

## Status

Discussion draft. The syntax and examples below are proposals, not features of
the current Action compiler.

## Summary

Action's current `import "file.act";` mechanism loads declarations from another
file into the same program-wide declaration namespace. This keeps small
programs simple, but makes independent components harder to compose: two files
cannot safely define the same top-level name, and a reader cannot tell from a
name which component owns it.

Add **packages** as named, separately scoped components. A package can consist
of multiple Action source files, exposes only declarations marked `pub`, and
is referenced through an import alias. Callers use qualified names such as
`watchdog.start()` or `watchdog.Task`. This provides namespace isolation
without changing Action's expression, type, or method-call model.

## Goals

- Let independently developed components reuse ordinary names without
  collisions.
- Make dependencies and ownership visible at the import and use sites.
- Allow a package to be implemented across multiple `.act` files.
- Preserve Action's existing type checking, function signatures, methods,
  ownership rules, and target-specific compilation.
- Provide an incremental migration path for existing programs.

## Non-goals

- Runtime loading, dynamic linking, or independently compiled binary
  libraries.
- New access-control levels beyond public and package-private declarations.
- Replacing Action's existing function and method syntax.
- Using a package as a new runtime or scheduling abstraction for tasks.

## Proposed source syntax

Every source file in a package starts with the same package declaration:

```c
package actor.watchdog;
```

Package names are dotted sequences of lowercase identifiers. A package may
contain one or more `.act` files. All files with the same package identity
form one compilation unit and share their package-private declarations.

### Visibility

Declarations are package-private by default. Put `pub` before a top-level
declaration to make it available to importers:

```c
package actor.watchdog;

pub type Task {
    u16 lc;
    bool ok;
}

pub void start(Task t) {
    t.ok = true;
}

u32 internalState;

void check(Task t) {
    // Package-private helper.
}
```

`pub` should apply to the existing top-level declaration forms: types and type
aliases, functions and prototypes, constants, enums, and globals. Members of a
public type remain accessible according to the existing type and field rules;
this proposal does not add per-field visibility. A public declaration that
mentions a package-private type in its externally visible signature should be
an error, so callers can name every type they need.

### Importing and qualifying names

Import a package by its logical name and give it a local alias:

```c
import actor.watchdog as watchdog;
import actor.logging as log;

void main() {
    watchdog.Task t;
    watchdog.start(t);
    log.write("watchdog started");
}
```

The alias is required in the initial design. It keeps dependency use explicit,
avoids implicit name injection, and gives a stable short name when a package's
full identity is long. An alias is visible only in the importing package's
source files.

Qualified names should work wherever a type or value name is accepted,
including:

```c
actor.watchdog.Task t;
actor.watchdog.start(t);
```

The alias form is preferred for normal code. A qualified expression can also
be used as a value, including a function value, when the referenced declaration
is public and its type is compatible.

There is no wildcard import and no implicit re-export. A package that wants to
expose a dependency's API should declare its own wrapper or alias explicitly.
Whether a future version should add a dedicated public type-alias form for
re-exports is an open question.

## Package discovery and compilation

Package names should be logical identities; source layout should not itself
define the language namespace. A project configuration maps package names to
directories. For example, extend the existing `action.json` project file:

```json
{
  "action": {
    "packages": {
      "actor.watchdog": ["firmware/parcore/actor/watchdog"],
      "actor.logging": ["firmware/parcore/actor/logging"]
    },
    "programs": [
      {
        "package": "firmware/parcore/conductor",
        "files": ["conductor.act"]
      }
    ]
  }
}
```

The program directory is the root package for that executable. An `import`
resolves a logical package name through the project's package map, loads all
`.act` files in its mapped directory, and validates that their `package`
declarations agree. The exact JSON shape should be checked against the
existing `action.json` schema and project conventions before implementation.

For command-line builds without `action.json`, provide a package search path
option (for example `-P path/to/packages`) and keep explicitly listed source
files as the root package. The spelling and interaction with the existing
`-I` include-path option should be settled before implementation; package
lookup must not silently fall back to treating a package name as an arbitrary
file path.

All packages used by one executable are still compiled together. This is
namespace and dependency organization, not a binary ABI or separate linker
step. Repeated imports load a package once. Package import cycles should be
diagnosed rather than relying on declaration-order accidents; type references
and function prototypes can be resolved across files in a package using the
compiler's existing whole-program declaration passes.

## Name lookup and isolation rules

For an unqualified identifier inside a package, lookup checks the current
lexical scope and then declarations in the current package, following Action's
existing shadowing and scope rules. Built-ins retain their current behavior.
An imported package's declarations are never considered by unqualified lookup.

For `alias.name`, the compiler resolves `alias` as an import alias and requires
`name` to be public in that package. Import aliases cannot be shadowed by a
local declaration, and two imports cannot use the same alias in one package.
These restrictions make a qualified name unambiguous and simplify diagnostics.

The same qualification rules apply to names used in types, function
signatures, initializers, method receivers, and expressions. For example:

```c
watchdog.Task current;
watchdog.Handler callback = watchdog.onEvent;
```

Where Action syntax currently requires a declared type name, the qualified
form should be accepted in that position as well.

## Example: organizing the conductor

The existing conductor imports `lib/protokernel.act` and defines its
watchdog task alongside `main`. With packages, the watchdog component could
own its types and operations:

```c
package actor.watchdog;

pub type Task {
    u16 lc;
    bool ok;
}

pub void start(Task t) {
    t.ok = true;
}

pub bool healthy(Task t) {
    return t.ok;
}
```

The conductor then depends on that public API explicitly:

```c
package firmware.conductor;

import actor.watchdog as watchdog;

const bool NotDone = true;

watchdog.Task watchdogTask;

void main() {
    watchdog.start(watchdogTask);

    while (NotDone) {
        if (!watchdog.healthy(watchdogTask)) {
            // Handle an unhealthy watchdog.
        }
    }
}
```

This example is illustrative: the exact package mapping and the existing
`task` declaration/call conventions must be respected when migrating actual
conductor code.

## Interaction with existing Action features

- **Imports:** Existing `import "file.act";` remains supported in legacy mode
  and retains its current merged-namespace behavior. Mixing legacy imports
  with package imports in one compilation unit should initially be rejected
  with a clear diagnostic, rather than producing ambiguous lookup behavior.
- **Types and methods:** Public user-defined types can be used as qualified
  types. Existing method declarations remain attached to their type; callers
  use `value.method()` as today. A package-private type cannot appear in a
  public API.
- **Function types and values:** A public function can be referenced as
  `alias.function`; its existing signature checks still apply.
- **Globals and constants:** These are package-private unless marked `pub`.
  This discourages accidental shared state while allowing explicit APIs.
- **Tasks and traps:** These follow the same visibility rule as functions.
  Their existing context and calling restrictions do not change.
- **Targets and conditional behavior:** A package must be checked for the
  target or targets selected for its importing program. Package boundaries do
  not bypass existing target checks.
- **Methods and names:** Two packages may define the same type and method
  names. A method remains selected from the receiver's type; package
  qualification is used when naming a type or top-level declaration.

## Diagnostics to define

The compiler should report specific errors for:

- Missing package mapping or package source directory.
- A source file whose declared package does not match the package being built.
- Duplicate package identity or conflicting package declarations.
- Duplicate import alias.
- Use of an unqualified name that exists only in an imported package.
- Access to a package-private declaration from another package.
- A public declaration that exposes an inaccessible package-private type.
- A package cycle, if cycles are disallowed by the chosen dependency model.
- Mixing package and legacy file imports in a compilation unit.

Diagnostics should identify both the importing source and the package or
declaration that caused the error where possible.

## Migration strategy

1. Add package declarations and package grouping to the compiler and
   `action.json` schema, without changing legacy imports.
2. Add `pub`, package-private visibility, and qualified lookup for package
   sources.
3. Add package search-path support to command-line builds and editor tooling.
4. Migrate one isolated component, such as a new `actor.watchdog` package, and
   add compiler and language-server tests.
5. Migrate existing libraries and applications incrementally. Keep legacy
   import behavior until downstream programs have a practical migration path.
6. Consider deprecation only after the package workflow is documented and
   supported by the build tool, editor, and test harness.

The Action language server should use the same package resolver and visibility
rules as the compiler, including following qualified definitions and
completing public members after an import alias.

## Decisions to settle before implementation

1. Should package declarations be required in every file, or may a directory
   assignment in `action.json` determine a package implicitly?
2. Should package imports allow dependency cycles, or require an acyclic
   dependency graph?
3. Should existing string-path imports be prohibited when package syntax is
   used, as proposed, or remain available as explicitly private file imports?
4. Should command-line package lookup use `-P`, reuse `-I`, or rely entirely on
   `action.json`?
5. Should package-private visibility remain the only default, or should a
   future language version support `pub` on individual fields and methods?

## Recommendation

Adopt named packages, explicit import aliases, qualified external names, and
package-private-by-default visibility. Keep packages as source-level
compilation units rather than introducing a binary library format. This
addresses namespace collisions while aligning with Action's current explicit
types, whole-program compilation, and straightforward code-generation model.
