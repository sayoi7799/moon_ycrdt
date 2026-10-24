///|
test "file names: plain room names stay readable" {
  assert_eq(file_name("room-1"), "room-1.ydoc")
  assert_eq(file_name("Notes2026"), "Notes2026.ydoc")
}

///|
test "file names: separators and dots cannot leave the data directory" {
  assert_eq(file_name("a/b"), "a_002fb.ydoc")
  assert_eq(file_name("../x"), "_002e_002e_002fx.ydoc")
  assert_eq(file_name("C:\\x"), "C_003a_005cx.ydoc")
}

///|
test "file names: other characters are written as UTF-16 code units" {
  assert_eq(file_name("é"), "_00e9.ydoc")
  assert_eq(file_name("房间"), "_623f_95f4.ydoc")
  // U+1F600 is the surrogate pair D83D DE00
  assert_eq(file_name("\u{1F600}"), "_d83d_de00.ydoc")
}

///|
test "file names: different rooms get different files" {
  // the escape character is escaped itself
  assert_eq(file_name("a_002fb"), "a_005f002fb.ydoc")
  assert_true(file_name("a/b") != file_name("a_002fb"))
}

///|
test "room name: the path of the request without its query" {
  assert_eq(room_name("/my-room"), "my-room")
  assert_eq(room_name("/my-room?token=1"), "my-room")
  assert_eq(room_name("/"), "default")
  assert_eq(room_name(""), "default")
}
