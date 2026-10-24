// Keeping the rooms on disk: one file per room, holding the whole document as
// a Yjs update (`encode_state_as_update`). Loading is applying that update to
// an empty document, so the file is also readable by `Y.applyUpdate`.

///|
/// The file name of a room. Letters, digits and `-` stay as they are and
/// every other UTF-16 code unit becomes `_` and four hex digits, so that
/// different rooms never share a file and a room name cannot escape the data
/// directory (`../x`, `a/b`, `C:` ...).
fn file_name(room : String) -> String {
  let out = StringBuilder()
  for c in room {
    if c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-') {
      out.write_char(c)
    } else {
      // characters outside the BMP are written as their surrogate pair
      let units = c.to_int()
      if units >= 0x10000 {
        let v = units - 0x10000
        out.write_string(hex4(0xD800 + (v >> 10)))
        out.write_string(hex4(0xDC00 + (v & 0x3FF)))
      } else {
        out.write_string(hex4(units))
      }
    }
  }
  out.write_string(".ydoc")
  out.to_string()
}

///|
fn hex4(n : Int32) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  out.write_char('_')
  for shift in [12, 8, 4, 0] {
    out.write_char(digits[(n >> shift) & 0xF].unsafe_to_char())
  }
  out.to_string()
}

///|
struct Store {
  dir : String
}

///|
fn Store::path(self : Store, room : String) -> String {
  "\{self.dir}/\{file_name(room)}"
}

///|
async fn Store::init(self : Store) -> Unit {
  @fs.mkdir(self.dir, recursive=true, allow_exist=true)
}

///|
/// The saved document of a room, if there is one.
async fn Store::load(self : Store, room : String) -> Bytes? {
  let path = self.path(room)
  if @fs.exists(path) {
    Some(@fs.read_file(path).binary())
  } else {
    None
  }
}

///|
/// Writes the document next to its final place and renames it over the old
/// file, so that a crash in the middle never leaves a half-written room.
async fn Store::save(self : Store, room : String, doc : @doc.Doc) -> Unit {
  let path = self.path(room)
  let tmp = path + ".tmp"
  @fs.write_file(
    tmp,
    @doc.encode_state_as_update(doc),
    create_mode=CreateOrTruncate,
  )
  @fs.rename(tmp, path, replace=true)
}
