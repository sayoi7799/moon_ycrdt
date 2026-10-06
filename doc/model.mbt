// In-memory document model (yjs/src/structs/Item.js, GC.js,
// types/AbstractType.js).

///|
/// An inserted run of content. Items of one parent form a doubly linked list
/// (`left` / `right`); `origin` and `right_origin` are the neighbours at the
/// time of insertion and never change — they drive conflict resolution.
pub struct Item {
  id : @update.ID
  mut length : Int
  /// Id of the last element of the left neighbour at insertion time.
  origin : @update.ID?
  /// Id of the first element of the right neighbour at insertion time.
  right_origin : @update.ID?
  mut left : Item?
  mut right : Item?
  parent : YType
  /// Map key for entries of map-like types.
  parent_sub : String?
  mut content : @update.Content
  mut deleted : Bool
  /// The shared type created by `Content::Type` items.
  mut nested : YType?
}

///|
/// Id of the last clock covered by the item.
pub fn Item::last_id(self : Item) -> @update.ID {
  @update.ID::new(self.id.client, self.id.clock + self.length - 1)
}

///|
pub fn Item::is_countable(self : Item) -> Bool {
  self.content.is_countable()
}

///|
/// A garbage-collected range: content is gone, only the clocks remain.
pub struct GCRange {
  id : @update.ID
  mut length : Int
}

///|
/// What the struct store holds for each clock: an item or a GC range.
pub enum Struct {
  GC(GCRange)
  Item(Item)
}

///|
pub fn Struct::id(self : Struct) -> @update.ID {
  match self {
    GC(g) => g.id
    Item(i) => i.id
  }
}

///|
pub fn Struct::length(self : Struct) -> Int {
  match self {
    GC(g) => g.length
    Item(i) => i.length
  }
}

///|
pub fn Struct::deleted(self : Struct) -> Bool {
  match self {
    GC(_) => true
    Item(i) => i.deleted
  }
}

///|
/// Type ref of a root type that was created by a remote update before the
/// application asked for it with a concrete type.
pub const TYPE_REF_UNKNOWN : Int = -1

///|
/// A shared type (Y.Text, Y.Map, ...). All shared types store their content
/// the same way: sequence items in a linked list starting at `start`, map
/// entries in `map` (key -> the newest item for that key). The `type_ref`
/// only matters to the typed API, so unknown or unsupported types (XML, ...)
/// are handled by the same code and survive re-encoding unchanged.
pub struct YType {
  mut type_ref : Int
  /// Node name of XmlElement / hook name of XmlHook.
  name : String?
  /// Name under which a root type is registered in the document.
  root_name : String?
  /// The item that created a nested type; None for root types.
  item : Item?
  mut start : Item?
  map : Map[String, Item]
  /// Sum of the lengths of countable, non-deleted sequence items.
  mut length : Int
}

///|
fn YType::new(
  type_ref : Int,
  name? : String? = None,
  root_name? : String? = None,
  item? : Item? = None,
) -> YType {
  { type_ref, name, root_name, item, start: None, map: {}, length: 0, }
}

///|
/// Physical identity of two optional items.
fn same_item(a : Item?, b : Item?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => physical_equal(x, y)
    _ => false
  }
}
