// Stoic: robustness primitives for Swift apps.
//
// DESIGN.md is the plan and design/ holds one contract per primitive. Each
// primitive ships with its tests, its failure-mode table and its docs.
//
// There is deliberately no type named `Stoic`: a type that shares its
// module's name shadows the module, and `Stoic.retry` could then never
// mean the module's function. Qualify with the module selector instead:
// `Stoic::retry`.
