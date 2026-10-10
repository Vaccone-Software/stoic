// Stoic: robustness primitives for Swift apps.
//
// The module has no public API yet. DESIGN.md is the plan, and design/
// holds one contract per primitive; code lands milestone by milestone,
// each primitive with its tests, its failure-mode table, and its docs.
//
// There is deliberately no type named `Stoic`: a type that shares its
// module's name shadows the module, and `Stoic.retry` could then never
// mean the module's function. Qualify with the module selector instead:
// `Stoic::retry`.
