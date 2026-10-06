// Cross-package interop and convergence tests live in this package; see the
// *_test.mbt files. This file only holds shared helpers.

///|
pub fn hex_bytes(s : String) -> Bytes {
  @lib0.from_hex(s) catch {
    e => abort(e.to_string())
  }
}
