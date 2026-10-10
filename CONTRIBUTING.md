# Contributing to Stoic

Thank you for helping. Stoic is a robustness library, so the bar for a change
is evidence, not only code.

## Before you start

- Read [DESIGN.md](DESIGN.md) for the principles, and the contract in
  [`design/`](design) for the primitive you are touching. A change in
  behaviour changes the contract in the same pull request.
- [AGENTS.md](AGENTS.md) holds the working rules for people and coding
  agents alike: house style, events as API, contracts first.
- For anything larger than a fix, open an issue first so the design can be
  agreed before the code is written.

## What a pull request needs

- **A test for every behaviour**, on the virtual clock (`TestClock`) where
  time is involved, never real sleeps. A test that proves a row of a
  contract's failure-mode table says so with
  `@Test(.failureMode("design/NN", "row"))`.
- **A regression test that fails without the fix**, for a bug fix.
- **Concurrency stress:** new or changed concurrency tests pass
  `swift test --filter <Suite> --maximum-repetitions 200 --repeat-until fail`.
- **Events are API:** a new event goes in `EventCatalog`; never rename one.
- **`./scripts/check.sh` passes:** build with warnings as errors, every test
  suite, the lint rules and Stoic's own lint, the iOS build, and DocC with no
  warnings.

## License

Stoic is licensed under the [Apache License 2.0](LICENSE). By submitting a
contribution you agree it is licensed under the same terms (section 5 of the
license).
