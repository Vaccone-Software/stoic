# 14 · Guidance

Two kinds of author write code against Stoic: people, and coding agents.
Agents are good at satisfying a compiler and following a worked example;
they are weak at global reasoning about ownership and concurrency, and when
stuck they reach for escape hatches. Research on agent code quality points
the same way: compilers are excellent verifiers (most compile errors in
LLM-written TypeScript are type errors, and constraining generation by types
cuts them by half or more), but models are measurably weaker in Swift than
in Python or JavaScript, and weakest on the newest features — exactly the
ones Stoic relies on. So Stoic ships its own knowledge, in the places agents
and people look.

## What ships

| Artifact                | Purpose                                                                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`             | The tour: one example per primitive.                                                                                                                    |
| `AGENTS.md`             | Checkable rules: the pattern-to-primitive table, eight rules, the compiler gotchas, and the conventions for working on Stoic. `CLAUDE.md` points to it. |
| `llms.txt`              | A compact API map for tools that read it: every public entry point in one place.                                                                        |
| `skills/stoic/SKILL.md` | An agent skill: when to reach for which primitive, and the mistakes to avoid.                                                                           |
| `design/`               | The contracts — the deepest answer to "what exactly happens if…".                                                                                       |
| Doc comments            | Every public symbol documents its semantics, cancellation behaviour and errors, with an example.                                                        |
| Diagnostics             | Compile errors that say how to fix the problem (an unbounded `retry` says "add `.attempts(n)`"), and lint findings with a suggested replacement.        |

## Principles

- **Teach only the gaps.** Agents already know Swift; guidance covers what
  is specific to Stoic and to robust concurrent code, not the basics.
- **Every rule is checkable.** If a rule cannot be checked by the compiler,
  the lint plugin or a test, it is phrased so a reviewer can check it in a
  diff.
- **Errors carry the fix.** The cheapest place to teach is the diagnostic
  the author is already looking at.
- **Examples compile.** Code in the README and doc comments mirrors code
  that the test suite compiles.
