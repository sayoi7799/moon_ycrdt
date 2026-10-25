// The two update formats behind one interface (yjs/src/utils/UpdateEncoder.js
// and UpdateDecoder.js: `UpdateEncoderV1` / `UpdateEncoderV2`).
//
// Both formats describe the same structs; they differ in how the fields are
// stored. Format v1 writes everything into one byte stream, field after
// field. Format v2 splits the fields over nine streams, one per kind (client
// ids, clocks, info bytes, strings, ...), each run-length encoded, and appends
// the remaining plain varints and `Any` values (`rest`).
//
//   v2 = varUint 0 (feature flag)
//        keyClock | client | leftClock | rightClock | info | string |
//        parentInfo | typeRef | len          (each a varUint8Array)
//        rest                                (appended, no length prefix)

///|
pub(all) enum UpdateFormat {
  V1
  V2
} derive(Eq, Debug)

///|
pub extend UpdateFormat with Eq::{equal, not_equal}

///|
pub struct UpdateEncoder {
  format : UpdateFormat
  /// Plain varints, `Any` values, byte arrays and (v1) everything else.
  mut rest : @lib0.Encoder
  priv mut key_clock : Int32
  priv key_clock_enc : @lib0.IntDiffOptRleEncoder
  priv client_enc : @lib0.UintOptRleEncoder
  priv left_clock_enc : @lib0.IntDiffOptRleEncoder
  priv right_clock_enc : @lib0.IntDiffOptRleEncoder
  priv info_enc : @lib0.RleEncoder
  priv string_enc : @lib0.StringEncoder
  priv parent_info_enc : @lib0.RleEncoder
  priv type_ref_enc : @lib0.UintOptRleEncoder
  priv len_enc : @lib0.UintOptRleEncoder
  /// v2 writes the clocks of a delete set as differences.
  priv mut ds_current : Int32
}

///|
pub fn UpdateEncoder::new(format : UpdateFormat) -> UpdateEncoder {
  {
    format,
    rest: @lib0.Encoder::new(),
    key_clock: 0,
    key_clock_enc: @lib0.IntDiffOptRleEncoder::new(),
    client_enc: @lib0.UintOptRleEncoder::new(),
    left_clock_enc: @lib0.IntDiffOptRleEncoder::new(),
    right_clock_enc: @lib0.IntDiffOptRleEncoder::new(),
    info_enc: @lib0.RleEncoder::new(),
    string_enc: @lib0.StringEncoder::new(),
    parent_info_enc: @lib0.RleEncoder::new(),
    type_ref_enc: @lib0.UintOptRleEncoder::new(),
    len_enc: @lib0.UintOptRleEncoder::new(),
    ds_current: 0,
  }
}

///|
pub fn UpdateEncoder::to_bytes(self : UpdateEncoder) -> Bytes {
  match self.format {
    V1 => self.rest.to_bytes()
    V2 => {
      let out = @lib0.Encoder::new()
      out.write_var_uint(0) // feature flag, unused
      out.write_var_bytes(self.key_clock_enc.to_bytes())
      out.write_var_bytes(self.client_enc.to_bytes())
      out.write_var_bytes(self.left_clock_enc.to_bytes())
      out.write_var_bytes(self.right_clock_enc.to_bytes())
      out.write_var_bytes(self.info_enc.to_bytes())
      out.write_var_bytes(self.string_enc.to_bytes())
      out.write_var_bytes(self.parent_info_enc.to_bytes())
      out.write_var_bytes(self.type_ref_enc.to_bytes())
      out.write_var_bytes(self.len_enc.to_bytes())
      // the rest follows without a length (`writeUint8Array`)
      out.write_raw_bytes(self.rest.to_bytes())
      out.to_bytes()
    }
  }
}

///|
pub fn UpdateEncoder::write_left_id(self : UpdateEncoder, id : ID) -> Unit {
  match self.format {
    V1 => write_id(self.rest, id)
    V2 => {
      self.client_enc.write(id.client)
      self.left_clock_enc.write(id.clock)
    }
  }
}

///|
pub fn UpdateEncoder::write_right_id(self : UpdateEncoder, id : ID) -> Unit {
  match self.format {
    V1 => write_id(self.rest, id)
    V2 => {
      self.client_enc.write(id.client)
      self.right_clock_enc.write(id.clock)
    }
  }
}

///|
pub fn UpdateEncoder::write_client(
  self : UpdateEncoder,
  client : UInt32,
) -> Unit {
  match self.format {
    V1 => self.rest.write_var_uint32(client)
    V2 => self.client_enc.write(client)
  }
}

///|
pub fn UpdateEncoder::write_info(self : UpdateEncoder, info : Int32) -> Unit {
  match self.format {
    V1 => self.rest.write_u8(info)
    V2 => self.info_enc.write(info)
  }
}

///|
pub fn UpdateEncoder::write_string(self : UpdateEncoder, s : String) -> Unit {
  match self.format {
    V1 => self.rest.write_var_string(s)
    V2 => self.string_enc.write(s)
  }
}

///|
/// Whether the parent of an item without origins is a root type (`true`, by
/// name) or an item (`false`, by id).
pub fn UpdateEncoder::write_parent_info(
  self : UpdateEncoder,
  is_root : Bool,
) -> Unit {
  let v = if is_root { 1 } else { 0 }
  match self.format {
    V1 => self.rest.write_var_uint(v)
    V2 => self.parent_info_enc.write(v)
  }
}

///|
pub fn UpdateEncoder::write_type_ref(
  self : UpdateEncoder,
  type_ref : Int32,
) -> Unit {
  match self.format {
    V1 => self.rest.write_var_uint(type_ref)
    V2 => self.type_ref_enc.write(type_ref.reinterpret_as_uint())
  }
}

///|
pub fn UpdateEncoder::write_len(self : UpdateEncoder, len : Int32) -> Unit {
  match self.format {
    V1 => self.rest.write_var_uint(len)
    V2 => self.len_enc.write(len.reinterpret_as_uint())
  }
}

///|
pub fn UpdateEncoder::write_any(
  self : UpdateEncoder,
  value : @lib0.Any,
) -> Unit {
  self.rest.write_any(value)
}

///|
pub fn UpdateEncoder::write_buf(self : UpdateEncoder, b : Bytes) -> Unit {
  self.rest.write_var_bytes(b)
}

///|
/// A JSON value (embeds and formatting attributes), held as JSON text. v1
/// writes the text; v2 writes the value as an `Any`.
pub fn UpdateEncoder::write_json(self : UpdateEncoder, json : String) -> Unit {
  match self.format {
    V1 => self.rest.write_var_string(json)
    V2 =>
      self.rest.write_any(
        @lib0.any_from_json_string(json) catch {
          e => abort("content holds invalid JSON \{json}: \{e}")
        },
      )
  }
}

///|
/// An attribute key or node name. Yjs v2 would reuse the clock of a key it has
/// written before, but the line that remembers keys is commented out, so every
/// key is written as a new one.
pub fn UpdateEncoder::write_key(self : UpdateEncoder, key : String) -> Unit {
  match self.format {
    V1 => self.rest.write_var_string(key)
    V2 => {
      self.key_clock_enc.write(self.key_clock)
      self.key_clock += 1
      self.string_enc.write(key)
    }
  }
}

///|
/// Starts the clocks of the next client of a delete set.
pub fn UpdateEncoder::reset_ds_current(self : UpdateEncoder) -> Unit {
  self.ds_current = 0
}

///|
pub fn UpdateEncoder::write_ds_clock(
  self : UpdateEncoder,
  clock : Int32,
) -> Unit {
  match self.format {
    V1 => self.rest.write_var_uint(clock)
    V2 => {
      self.rest.write_var_uint(clock - self.ds_current)
      self.ds_current = clock
    }
  }
}

///|
pub fn UpdateEncoder::write_ds_len(self : UpdateEncoder, len : Int32) -> Unit {
  match self.format {
    V1 => self.rest.write_var_uint(len)
    V2 => {
      guard len > 0 else { abort("a delete range cannot be empty") }
      self.rest.write_var_uint(len - 1)
      self.ds_current += len
    }
  }
}

///|
pub struct UpdateDecoder {
  format : UpdateFormat
  rest : @lib0.Decoder
  priv keys : Array[String]
  priv key_clock_dec : @lib0.IntDiffOptRleDecoder
  priv client_dec : @lib0.UintOptRleDecoder
  priv left_clock_dec : @lib0.IntDiffOptRleDecoder
  priv right_clock_dec : @lib0.IntDiffOptRleDecoder
  priv info_dec : @lib0.RleDecoder
  priv string_dec : @lib0.StringDecoder
  priv parent_info_dec : @lib0.RleDecoder
  priv type_ref_dec : @lib0.UintOptRleDecoder
  priv len_dec : @lib0.UintOptRleDecoder
  priv mut ds_current : Int32
}

///|
pub fn UpdateDecoder::new(
  format : UpdateFormat,
  data : Bytes,
) -> UpdateDecoder raise @lib0.DecodeError {
  let d = @lib0.Decoder::new(data)
  match format {
    V1 => {
      // the column decoders are not used in v1
      let none : Bytes = b""
      {
        format,
        rest: d,
        keys: [],
        key_clock_dec: @lib0.IntDiffOptRleDecoder::new(none),
        client_dec: @lib0.UintOptRleDecoder::new(none),
        left_clock_dec: @lib0.IntDiffOptRleDecoder::new(none),
        right_clock_dec: @lib0.IntDiffOptRleDecoder::new(none),
        info_dec: @lib0.RleDecoder::new(none),
        string_dec: @lib0.StringDecoder::new(b"\x00"),
        parent_info_dec: @lib0.RleDecoder::new(none),
        type_ref_dec: @lib0.UintOptRleDecoder::new(none),
        len_dec: @lib0.UintOptRleDecoder::new(none),
        ds_current: 0,
      }
    }
    V2 => {
      d.read_var_uint() |> ignore // feature flag, unused
      let key_clock_dec = @lib0.IntDiffOptRleDecoder::new(d.read_var_bytes())
      let client_dec = @lib0.UintOptRleDecoder::new(d.read_var_bytes())
      let left_clock_dec = @lib0.IntDiffOptRleDecoder::new(d.read_var_bytes())
      let right_clock_dec = @lib0.IntDiffOptRleDecoder::new(d.read_var_bytes())
      let info_dec = @lib0.RleDecoder::new(d.read_var_bytes())
      let string_dec = @lib0.StringDecoder::new(d.read_var_bytes())
      let parent_info_dec = @lib0.RleDecoder::new(d.read_var_bytes())
      let type_ref_dec = @lib0.UintOptRleDecoder::new(d.read_var_bytes())
      let len_dec = @lib0.UintOptRleDecoder::new(d.read_var_bytes())
      {
        format,
        rest: @lib0.Decoder::new(d.read_raw_bytes(d.remaining())),
        keys: [],
        key_clock_dec,
        client_dec,
        left_clock_dec,
        right_clock_dec,
        info_dec,
        string_dec,
        parent_info_dec,
        type_ref_dec,
        len_dec,
        ds_current: 0,
      }
    }
  }
}

///|
pub fn UpdateDecoder::read_left_id(
  self : UpdateDecoder,
) -> ID raise @lib0.DecodeError {
  match self.format {
    V1 => read_id(self.rest)
    V2 => {
      let client = self.client_dec.read()
      ID::new(client, self.left_clock_dec.read())
    }
  }
}

///|
pub fn UpdateDecoder::read_right_id(
  self : UpdateDecoder,
) -> ID raise @lib0.DecodeError {
  match self.format {
    V1 => read_id(self.rest)
    V2 => {
      let client = self.client_dec.read()
      ID::new(client, self.right_clock_dec.read())
    }
  }
}

///|
pub fn UpdateDecoder::read_client(
  self : UpdateDecoder,
) -> UInt32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint32()
    V2 => self.client_dec.read()
  }
}

///|
pub fn UpdateDecoder::read_info(
  self : UpdateDecoder,
) -> Int32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_u8()
    V2 => self.info_dec.read()
  }
}

///|
pub fn UpdateDecoder::read_string(
  self : UpdateDecoder,
) -> String raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_string()
    V2 => self.string_dec.read()
  }
}

///|
pub fn UpdateDecoder::read_parent_info(
  self : UpdateDecoder,
) -> Bool raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint() == 1
    V2 => self.parent_info_dec.read() == 1
  }
}

///|
pub fn UpdateDecoder::read_type_ref(
  self : UpdateDecoder,
) -> Int32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint()
    V2 => self.type_ref_dec.read().reinterpret_as_int()
  }
}

///|
pub fn UpdateDecoder::read_len(
  self : UpdateDecoder,
) -> Int32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint()
    V2 => {
      let n = self.len_dec.read().reinterpret_as_int()
      if n < 0 {
        raise @lib0.IntegerOutOfRange
      }
      n
    }
  }
}

///|
pub fn UpdateDecoder::read_any(
  self : UpdateDecoder,
) -> @lib0.Any raise @lib0.DecodeError {
  self.rest.read_any()
}

///|
pub fn UpdateDecoder::read_buf(
  self : UpdateDecoder,
) -> Bytes raise @lib0.DecodeError {
  self.rest.read_var_bytes()
}

///|
/// The JSON text of an embed or a formatting attribute value (see
/// `UpdateEncoder::write_json`).
pub fn UpdateDecoder::read_json(
  self : UpdateDecoder,
) -> String raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_string()
    V2 => self.rest.read_any().to_json_string()
  }
}

///|
/// An attribute key or node name; v2 may refer back to a key that came
/// earlier (other implementations reuse keys, Yjs does not).
pub fn UpdateDecoder::read_key(
  self : UpdateDecoder,
) -> String raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_string()
    V2 => {
      let clock = self.key_clock_dec.read()
      if clock >= 0 && clock < self.keys.length() {
        self.keys[clock]
      } else {
        let key = self.string_dec.read()
        self.keys.push(key)
        key
      }
    }
  }
}

///|
pub fn UpdateDecoder::reset_ds_current(self : UpdateDecoder) -> Unit {
  self.ds_current = 0
}

///|
pub fn UpdateDecoder::read_ds_clock(
  self : UpdateDecoder,
) -> Int32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint()
    V2 => {
      self.ds_current += self.rest.read_var_uint()
      self.ds_current
    }
  }
}

///|
pub fn UpdateDecoder::read_ds_len(
  self : UpdateDecoder,
) -> Int32 raise @lib0.DecodeError {
  match self.format {
    V1 => self.rest.read_var_uint()
    V2 => {
      let diff = self.rest.read_var_uint() + 1
      self.ds_current += diff
      diff
    }
  }
}
