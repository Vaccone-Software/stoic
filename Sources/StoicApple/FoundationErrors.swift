// StoicApple builds on StoicFoundation. Apple's frameworks report
// Foundation's errors (`URLError`, `POSIXError`, `CocoaError`), and an app
// that adopts StoicApple gets their retry classification with it: the
// conformances are linked through this import even where nothing here
// names them, so `retry` classifies a `URLError` the same way it did when
// the table lived in this module.
internal import StoicFoundation
