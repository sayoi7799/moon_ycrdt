// Structs as they appear on the wire (yjs/src/utils/encoding.js
// `readClientsStructRefs` and `Item.write`).

///|
/// Where an item lives when it carries no origin: either a root type
/// (`doc.get(name)`) or the nested type created by the item with this id.
pub(all) enum ParentRef {
  Root(String)
  Item(ID)
} derive(Eq, Debug)

///|
pub extend ParentRef with Eq::{equal, not_equal}

///|
pub(all) struct ItemRef {
  id : ID
  origin : ID?
  right_origin : ID?
  /// Only written when both origins are absent; otherwise the parent is
  /// inherited from the neighbour items during integration.
  parent : ParentRef?
  /// Value of the info byte's parentSub bit. Yjs sets the bit for map entries
  /// even when the key itself is omitted because origins are present.
  has_parent_sub : Bool
  /// The map key; only present on the wire when `parent` is present.
  parent_sub : String?
  content : Content
} derive(Eq, Debug)

///|
pub extend ItemRef with Eq::{equal, not_equal}

///|
pub(all) enum StructRef {
  /// Garbage-collected range: the content is gone, only the clocks remain.
  GC(ID, Int32)
  /// Gap in a merged update: these clocks are not part of this update.
  Skip(ID, Int32)
  Item(ItemRef)
} derive(Eq, Debug)

///|
pub extend StructRef with Eq::{equal, not_equal}

///|
pub fn StructRef::id(self : StructRef) -> ID {
  match self {
    GC(id, _) | Skip(id, _) => id
    Item(item) => item.id
  }
}

///|
pub fn StructRef::length(self : StructRef) -> Int32 {
  match self {
    GC(_, len) | Skip(_, len) => len
    Item(item) => item.content.length()
  }
}

// Bit layout of the info byte.

///|
pub const BIT_ORIGIN : Int32 = 0x80

///|
pub const BIT_RIGHT_ORIGIN : Int32 = 0x40

///|
pub const BIT_PARENT_SUB : Int32 = 0x20

///|
pub const BITS_CONTENT_REF : Int32 = 0x1F

///|
const REF_GC : Int32 = 0

///|
const REF_SKIP : Int32 = 10

///|
/// Writes one struct. A non-zero `offset` writes only the clocks from
/// `id.clock + offset` on; for items the origin then becomes the preceding
/// clock of the same item, as in `Item.write(encoder, offset)`.
pub fn StructRef::write(
  self : StructRef,
  e : UpdateEncoder,
  offset : Int32,
) -> Unit {
  match self {
    GC(_, len) => {
      e.write_info(REF_GC)
      e.write_len(len - offset)
    }
    Skip(_, len) => {
      // a skip's length is a plain varint in both formats
      e.write_info(REF_SKIP)
      e.rest.write_var_uint(len - offset)
    }
    Item(item) => {
      let origin = if offset > 0 {
        Some(ID::new(item.id.client, item.id.clock + offset - 1))
      } else {
        item.origin
      }
      let info = item.content.ref_number() |
        (if origin is Some(_) { BIT_ORIGIN } else { 0 }) |
        (if item.right_origin is Some(_) { BIT_RIGHT_ORIGIN } else { 0 }) |
        (if item.has_parent_sub { BIT_PARENT_SUB } else { 0 })
      e.write_info(info)
      if origin is Some(o) {
        e.write_left_id(o)
      }
      if item.right_origin is Some(ro) {
        e.write_right_id(ro)
      }
      if origin is None && item.right_origin is None {
        match item.parent {
          Some(Root(name)) => {
            e.write_parent_info(true)
            e.write_string(name)
          }
          Some(Item(id)) => {
            e.write_parent_info(false)
            e.write_left_id(id)
          }
          None => abort("item \{item.id} without origins needs a parent")
        }
        if item.has_parent_sub {
          match item.parent_sub {
            Some(key) => e.write_string(key)
            None => abort("item \{item.id} without origins needs its key")
          }
        }
      }
      item.content.write(e, offset)
    }
  }
}

///|
pub fn read_struct(
  d : UpdateDecoder,
  id : ID,
) -> StructRef raise @lib0.DecodeError {
  let info = d.read_info()
  match info & BITS_CONTENT_REF {
    REF_GC => GC(id, d.read_len())
    REF_SKIP => Skip(id, d.rest.read_var_uint())
    ref_number => {
      let origin = if (info & BIT_ORIGIN) != 0 {
        Some(d.read_left_id())
      } else {
        None
      }
      let right_origin = if (info & BIT_RIGHT_ORIGIN) != 0 {
        Some(d.read_right_id())
      } else {
        None
      }
      let has_parent_sub = (info & BIT_PARENT_SUB) != 0
      let mut parent = None
      let mut parent_sub = None
      if origin is None && right_origin is None {
        parent = Some(
          if d.read_parent_info() {
            ParentRef::Root(d.read_string())
          } else {
            ParentRef::Item(d.read_left_id())
          },
        )
        if has_parent_sub {
          parent_sub = Some(d.read_string())
        }
      }
      let content = read_content(d, ref_number)
      Item({
        id,
        origin,
        right_origin,
        parent,
        has_parent_sub,
        parent_sub,
        content,
      })
    }
  }
}

///|
/// The struct without its first `offset` clocks. For items the origin
/// becomes the preceding clock of the same item and the content is split
/// like `Content::split` (which yields the same bytes as Yjs' offset write).
pub fn StructRef::slice(self : StructRef, offset : Int32) -> StructRef {
  guard offset > 0 else { return self }
  match self {
    GC(id, len) => GC(ID::new(id.client, id.clock + offset), len - offset)
    Skip(id, len) => Skip(ID::new(id.client, id.clock + offset), len - offset)
    Item(r) =>
      Item({
        ..r,
        id: ID::new(r.id.client, r.id.clock + offset),
        origin: Some(ID::new(r.id.client, r.id.clock + offset - 1)),
        content: r.content.split(offset).1,
      })
  }
}

///|
/// The struct as Yjs sees it after reading it from an update. An item with an
/// origin does not carry its map key on the wire, only a bit in the info byte
/// that says "this is a map entry"; the reader forgets that (the key of the
/// item is `null`, so the bit is not written again). Everything that reads
/// structs and writes them again (merging and diffing updates, converting
/// between formats, the state of a document that holds pending structs)
/// therefore writes the bit cleared for every item with an origin. Items
/// without origins keep their key and the bit.
pub fn StructRef::normalized(self : StructRef) -> StructRef {
  match self {
    Item(r) =>
      if r.origin is None && r.right_origin is None && r.parent_sub is Some(_) {
        self
      } else {
        Item({ ..r, has_parent_sub: false, parent_sub: None, })
      }
    _ => self
  }
}
