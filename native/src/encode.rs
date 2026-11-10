// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 exliipso
// Originally developed by exliipso

//! The XNet wire format, written natively. Byte-for-byte compatible with the
//! Lua edition's encoder (see lua/autorun/xnet.lua for the format table).
//!
//! Two things here are shaped by Garry's Mod rather than by Lua:
//!
//! - Tables are told apart with `lua_rawequal` against their ancestors on the
//!   stack, never with `lua_topointer`: Garry's Mod scrambles the pointers it
//!   hands out, and the scrambled values are not unique.
//! - Numbers are classified from their bits, never with float arithmetic: the
//!   server process runs with denormals-are-zero, which would otherwise change
//!   what a comparison sees.

use gmod::lua::{State, LUA_REGISTRYINDEX};
use gmod::userdata::UserData;
use std::cell::Cell;
use std::collections::HashMap;

pub const FORMAT: u8 = 1;

const T_NIL: u8 = 192;
const T_FALSE: u8 = 193;
const T_TRUE: u8 = 194;
const T_U8: u8 = 195;
const T_N8: u8 = 199;
const T_F64: u8 = 203;
const T_S8: u8 = 204;
const T_R8: u8 = 207;
const T_TAB: u8 = 210;
const T_VEC: u8 = 211;
const T_ANG: u8 = 212;
const T_COL: u8 = 213;
const T_ENT: u8 = 214;

const FIXSTR: u8 = 128;
const FIXTAB: u8 = 160;
const MIN_INTERN: usize = 4;

// Stack slots one table level or one engine-type call can push at most, with
// margin. Reserved before each.
const SLOTS: i32 = 12;
const OUT_OF_STACK: &str = "XNet: out of Lua stack";

const LUA_TNIL: i32 = 0;
const LUA_TBOOLEAN: i32 = 1;
const LUA_TNUMBER: i32 = 3;
const LUA_TSTRING: i32 = 4;
const LUA_TTABLE: i32 = 5;
const LUA_TUSERDATA: i32 = 7;

// Metatables fetched from the registry on first need, kept in three stack
// slots reserved when encoding starts.
const META_COLOR: usize = 0;
const META_VECTOR: usize = 1;
const META_ANGLE: usize = 2;

// Strings seen in a message are found by scanning a short list; only a
// message with more distinct strings than this builds a hash map.
const LISTED: usize = 24;

// A buffer this big or smaller is kept between calls.
pub(crate) const KEEP_BYTES: usize = 1 << 20;
const KEEP_STRINGS: usize = 4096;

/// Buffers reused from one call to the next, so a small message allocates
/// nothing.
#[derive(Default)]
struct Scratch {
    out: Vec<u8>,
    path: Vec<i32>,
    map: HashMap<usize, u32>,
}

thread_local! {
    static SCRATCH: Cell<Option<Box<Scratch>>> = const { Cell::new(None) };
}

struct Encoder {
    scratch: Box<Scratch>,
    // Lua strings are interned, so the data pointer identifies the string.
    listed: [usize; LISTED],
    strings: u32,
    mapped: bool,
    max_depth: usize,
    metas: i32,
    have: [bool; 3],
}

thread_local! {
    // Pack's output buffer, kept between calls like the scratch.
    static PACKED: Cell<Vec<u8>> = const { Cell::new(Vec::new()) };
}

/// Encodes the stack values from `first` to the top, after `prefix` if there
/// is one, and pushes the result as a string. The rest of the stack is left
/// as it was found.
pub unsafe fn pack(lua: State, first: i32, prefix: Option<[u8; 2]>, max_depth: usize) -> Result<(), String> {
    let mut out = PACKED.with(|cell| cell.take());
    out.clear();

    let result = append(lua, first, prefix, max_depth, &mut out);

    if result.is_ok() {
        lua.push_binary_string(&out);
    }

    if out.capacity() <= KEEP_BYTES {
        PACKED.with(|cell| cell.set(out));
    }

    result
}

/// Encodes the stack values from `first` to the top onto the end of `out`,
/// after `prefix` if there is one. On an error `out` is left as it was. The
/// stack is left as it was found.
pub unsafe fn append(lua: State, first: i32, prefix: Option<[u8; 2]>, max_depth: usize, out: &mut Vec<u8>) -> Result<(), String> {
    let top = lua.get_top();
    let count = (top - first + 1).max(0) as u64;

    if !crate::reserve(lua, SLOTS) {
        return Err(OUT_OF_STACK.to_string());
    }

    // Three empty slots for the metatables.
    lua.set_top(top + 3);

    let mut scratch = SCRATCH.with(|cell| cell.take()).unwrap_or_default();

    scratch.path.clear();

    // The encoder writes to scratch.out; lend it the caller's buffer.
    std::mem::swap(&mut scratch.out, out);

    let start = scratch.out.len();

    let mut enc = Encoder { scratch, listed: [0; LISTED], strings: 0, mapped: false, max_depth, metas: top + 1, have: [false; 3] };

    if let Some(bytes) = prefix {
        enc.scratch.out.extend_from_slice(&bytes);
    }

    enc.scratch.out.push(FORMAT);
    enc.varint(count);

    let mut result = Ok(());

    for index in first..=top {
        result = enc.value(lua, index);

        if result.is_err() {
            break;
        }
    }

    lua.set_top(top);

    if result.is_err() {
        enc.scratch.out.truncate(start);
    }

    std::mem::swap(&mut enc.scratch.out, out);
    enc.release();

    result
}

impl Encoder {
    /// Hands the scratch back for the next call, unless a big message left
    /// its map oversized.
    fn release(mut self) {
        if self.mapped {
            if self.scratch.map.capacity() > KEEP_STRINGS {
                self.scratch.map = HashMap::new();
            } else {
                self.scratch.map.clear();
            }
        }

        SCRATCH.with(|cell| cell.set(Some(self.scratch)));
    }

    #[inline]
    fn push(&mut self, byte: u8) {
        self.scratch.out.push(byte);
    }

    #[inline]
    fn bytes(&mut self, bytes: &[u8]) {
        self.scratch.out.extend_from_slice(bytes);
    }

    fn varint(&mut self, mut x: u64) {
        while x >= 128 {
            self.push((x & 127) as u8 | 128);
            x >>= 7;
        }

        self.push(x as u8);
    }

    /// 1, 2, 4 or 7 little-endian bytes after a tag, as the Lua edition writes.
    fn uint(&mut self, v: u64, t8: u8) {
        if v < 256 {
            self.bytes(&[t8, v as u8]);
        } else if v < 65536 {
            self.push(t8 + 1);
            self.bytes(&(v as u16).to_le_bytes());
        } else if v < 1 << 32 {
            self.push(t8 + 2);
            self.bytes(&(v as u32).to_le_bytes());
        } else {
            self.push(t8 + 3);
            self.bytes(&v.to_le_bytes()[..7]);
        }
    }

    fn number(&mut self, v: f64) {
        let bits = v.to_bits();
        let negative = bits >> 63 != 0;
        let exponent = ((bits >> 52) & 0x7ff) as i32;
        let fraction = bits & ((1u64 << 52) - 1);

        if exponent == 0 && fraction == 0 && !negative {
            self.push(0);
            return;
        }

        // An exact integer below 2^53 in magnitude: the exponent leaves no
        // fraction bits set.
        let unbiased = exponent - 1023;

        if exponent != 0 && exponent != 0x7ff && (0..53).contains(&unbiased) {
            let shift = 52 - unbiased as u32;
            let mask = if shift == 0 { 0 } else { (1u64 << shift) - 1 };

            if fraction & mask == 0 {
                let magnitude = (fraction | (1u64 << 52)) >> shift;

                if !negative {
                    if magnitude < 128 {
                        self.push(magnitude as u8);
                    } else {
                        self.uint(magnitude, T_U8);
                    }
                } else if magnitude <= 32 {
                    self.push((256 - magnitude) as u8);
                } else {
                    self.uint(magnitude - 1, T_N8);
                }

                return;
            }
        }

        self.push(T_F64);
        self.bytes(&bits.to_le_bytes());
    }

    /// The reference number of a string already written in this message.
    fn find(&self, key: usize) -> Option<u32> {
        if self.mapped {
            return self.scratch.map.get(&key).copied();
        }

        self.listed[..self.strings as usize].iter().position(|&k| k == key).map(|i| i as u32)
    }

    fn remember(&mut self, key: usize) {
        let index = self.strings as usize;

        if !self.mapped && index == LISTED {
            for (i, &k) in self.listed.iter().enumerate() {
                self.scratch.map.insert(k, i as u32);
            }

            self.mapped = true;
        }

        if self.mapped {
            self.scratch.map.insert(key, self.strings);
        } else {
            self.listed[index] = key;
        }

        self.strings += 1;
    }

    fn string(&mut self, s: &[u8]) {
        let len = s.len();

        if len >= MIN_INTERN {
            let key = s.as_ptr() as usize;

            if let Some(reference) = self.find(key) {
                self.uint(reference as u64, T_R8);
                return;
            }

            self.remember(key);
        }

        if len < 32 {
            self.push(FIXSTR + len as u8);
        } else {
            self.uint(len as u64, T_S8);
        }

        self.bytes(s);
    }

    unsafe fn value(&mut self, lua: State, index: i32) -> Result<(), String> {
        match lua.lua_type(index) {
            LUA_TNUMBER => self.number(lua.to_number(index)),
            LUA_TSTRING => {
                let s = lua.get_binary_string(index).unwrap_or(&[]);
                self.string(s);
            }
            LUA_TTABLE => self.table(lua, index)?,
            LUA_TBOOLEAN => self.push(if lua.get_boolean(index) { T_TRUE } else { T_FALSE }),
            LUA_TNIL | -1 => self.push(T_NIL),
            LUA_TUSERDATA => self.userdata(lua, index)?,
            other => return Err(format!("XNet: cannot send a {}", lua.lua_type_name(other))),
        }

        Ok(())
    }

    /// True when the metatable on top of the stack is the registry's `name`.
    unsafe fn top_is_meta(&mut self, lua: State, which: usize, name: gmod::lua::LuaString) -> bool {
        let slot = self.metas + which as i32;

        if !self.have[which] {
            lua.get_field(LUA_REGISTRYINDEX, name);
            lua.replace(slot);
            self.have[which] = true;
        }

        lua.raw_equal(-1, slot)
    }

    unsafe fn table(&mut self, lua: State, index: i32) -> Result<(), String> {
        if !crate::reserve(lua, SLOTS) {
            return Err(OUT_OF_STACK.to_string());
        }

        if lua.get_metatable(index) != 0 {
            let is_color = self.top_is_meta(lua, META_COLOR, lua_string!("Color"));
            lua.pop();

            if is_color && self.color(lua, index) {
                return Ok(());
            }
        }

        // A table that is its own ancestor would never end. Every ancestor
        // is still on the stack, at the index recorded for it.
        if self.scratch.path.iter().any(|&ancestor| lua.raw_equal(index, ancestor)) {
            return Err("XNet: a table contains itself".to_string());
        }

        if self.scratch.path.len() >= self.max_depth {
            return Err("XNet: tables nested too deeply".to_string());
        }

        self.scratch.path.push(index);

        let array = lua.len(index).max(0);

        if array < 32 {
            self.push(FIXTAB + array as u8);
        } else {
            self.push(T_TAB);
            self.varint(array as u64);
        }

        let slot = lua.get_top() + 1;

        for i in 1..=array {
            lua.raw_geti(index, i);
            self.value(lua, slot)?;
            lua.pop();
        }

        // Every other pair; keys 1..array were written above.
        lua.push_nil();

        while lua.next(index) != 0 {
            let key = slot;
            let value = slot + 1;

            let in_array = lua.lua_type(key) == LUA_TNUMBER && {
                let k = lua.to_number(key);
                k >= 1.0 && k <= array as f64 && k == k.trunc()
            };

            if !in_array {
                self.value(lua, key)?;
                self.value(lua, value)?;
            }

            lua.pop();
        }

        self.push(T_NIL);
        self.scratch.path.pop();

        Ok(())
    }

    /// A Color with whole-number channels in 0-255; anything else is sent
    /// as a plain table, as the Lua edition does.
    unsafe fn color(&mut self, lua: State, index: i32) -> bool {
        let mut channels = [0u8; 4];

        // Raw reads: no metamethod can run (or raise) from here.
        for (slot, field) in ["r", "g", "b", "a"].into_iter().enumerate() {
            lua.push_string(field);
            crate::raw_get(lua, index);

            let ok = lua.lua_type(-1) == LUA_TNUMBER && {
                let v = lua.to_number(-1);
                (0.0..=255.0).contains(&v) && v == v.trunc()
            };

            if ok {
                channels[slot] = lua.to_number(-1) as u8;
            }

            lua.pop();

            if !ok {
                return false;
            }
        }

        self.push(T_COL);
        self.bytes(&channels);

        true
    }

    unsafe fn userdata(&mut self, lua: State, index: i32) -> Result<(), String> {
        if !crate::reserve(lua, SLOTS) {
            return Err(OUT_OF_STACK.to_string());
        }

        if lua.get_metatable(index) == 0 {
            return Err("XNet: cannot send a userdata".to_string());
        }

        // The engine's own Vector and Angle are read straight from memory.
        let engine = if self.top_is_meta(lua, META_VECTOR, lua_string!("Vector")) {
            Some((T_VEC, UserData::Vector))
        } else if self.top_is_meta(lua, META_ANGLE, lua_string!("Angle")) {
            Some((T_ANG, UserData::Angle))
        } else {
            None
        };

        if let Some((tag, kind)) = engine {
            if let Some(components) = floats(lua, index, kind) {
                lua.pop();
                self.push(tag);

                for component in components {
                    self.bytes(&component.to_bits().to_le_bytes());
                }

                return Ok(());
            }
        }

        lua.push_string("MetaName");
        crate::raw_get(lua, -2);
        let name = lua.get_binary_string(-1).map(|s| String::from_utf8_lossy(s).into_owned()).unwrap_or_default();
        lua.pop_n(2);

        match name.as_str() {
            "Vector" | "Angle" => {
                let components = call_helper(lua, |h| h.unpack, index, 3).ok_or_else(|| format!("XNet: could not read a {name}"))?;

                self.push(if name == "Vector" { T_VEC } else { T_ANG });

                for slot in [-3, -2, -1] {
                    let component = lua.to_number(slot) as f32;
                    self.bytes(&component.to_bits().to_le_bytes());
                }

                lua.pop_n(components);
            }
            "Entity" | "Player" | "Weapon" | "NPC" | "Vehicle" | "NextBot" | "CSEnt" => {
                call_helper(lua, |h| h.entity, index, 1).ok_or("XNet: could not read an entity")?;

                let value = lua.to_number(-1);
                lua.pop();

                // Index + 1, 0 for NULL; anything out of range is sent as NULL,
                // as the Lua edition does.
                let entity = if (0.0..=65535.0).contains(&value) { value as u16 } else { 0 };

                self.push(T_ENT);
                self.bytes(&entity.to_le_bytes());
            }
            _ => return Err(format!("XNet: cannot send a {}", if name.is_empty() { "userdata" } else { &name })),
        }

        Ok(())
    }
}

/// Calls one of the Lua helpers on the value at `index` under pcall, leaving
/// its `results` on the stack. None when it raised (nothing is left then).
unsafe fn call_helper(lua: State, which: impl Fn(crate::Helpers) -> i32, index: i32, results: i32) -> Option<i32> {
    let helpers = crate::helpers()?;

    lua.raw_geti(LUA_REGISTRYINDEX, which(helpers));
    lua.push_value(index);

    if lua.pcall(1, results, 0) != 0 {
        lua.pop();
        return None;
    }

    Some(results)
}

/// The three floats of an engine Vector or Angle, read through the module
/// ABI's userdata layout: `GarrysMod::Lua::UserData { void* data; unsigned
/// char type; }` from gmod-module-base, which `ILuaBase::GetUserType` reads
/// the same way. The caller has checked the value's metatable is the
/// engine's own; the size, type tag and pointer are checked here. Anything
/// else returns None and takes the slow path through Lua.
unsafe fn floats(lua: State, index: i32, kind: UserData) -> Option<[f32; 3]> {
    // The tag is read as a plain byte: memory that isn't what it should be
    // must not be interpreted as an enum.
    #[repr(C)]
    struct Tagged {
        data: *const [f32; 3],
        kind: u8,
    }

    if (lua.len(index) as usize) < std::mem::size_of::<Tagged>() {
        return None;
    }

    let tagged = lua.to_userdata(index) as *const Tagged;

    if tagged.is_null() || (*tagged).kind != kind as u8 {
        return None;
    }

    // The engine allocates the value itself, so a pointer that is null or not
    // aligned for f32 means this isn't the layout described above.
    let data = (*tagged).data;

    if data.is_null() || !(data as usize).is_multiple_of(std::mem::align_of::<f32>()) {
        return None;
    }

    Some(std::ptr::read(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoder() -> Encoder {
        Encoder { scratch: Box::default(), listed: [0; LISTED], strings: 0, mapped: false, max_depth: 64, metas: 0, have: [false; 3] }
    }

    fn number(v: f64) -> Vec<u8> {
        let mut enc = encoder();
        enc.number(v);
        enc.scratch.out.clone()
    }

    #[test]
    fn small_integers() {
        assert_eq!(number(0.0), [0]);
        assert_eq!(number(127.0), [127]);
        assert_eq!(number(128.0), [T_U8, 128]);
        assert_eq!(number(255.0), [T_U8, 255]);
        assert_eq!(number(256.0), [T_U8 + 1, 0, 1]);
        assert_eq!(number(65536.0), [T_U8 + 2, 0, 0, 1, 0]);
        assert_eq!(number(4294967296.0), [T_U8 + 3, 0, 0, 0, 0, 1, 0, 0]);
        assert_eq!(number(-1.0), [255]);
        assert_eq!(number(-32.0), [224]);
        assert_eq!(number(-33.0), [T_N8, 32]);
        assert_eq!(number(-257.0), [T_N8 + 1, 0, 1]);
    }

    #[test]
    fn integer_limit() {
        let below = 9007199254740991.0; // 2^53 - 1
        assert_eq!(number(below), [T_U8 + 3, 255, 255, 255, 255, 255, 255, 31]);
        assert_eq!(number(-below)[0], T_N8 + 3);

        // From 2^53 on, a double: not every integer there is representable.
        assert_eq!(number(9007199254740992.0)[0], T_F64);
        assert_eq!(number(-9007199254740992.0)[0], T_F64);
    }

    #[test]
    fn doubles_keep_their_bits() {
        for v in [-0.0, 0.5, -0.1, f64::INFINITY, f64::NEG_INFINITY, f64::MIN_POSITIVE, 5e-324, f64::MAX, f64::NAN] {
            let out = number(v);
            assert_eq!(out[0], T_F64, "{v}");
            assert_eq!(out[1..], v.to_bits().to_le_bytes(), "{v}");
        }
    }

    #[test]
    fn varints() {
        let mut enc = encoder();
        enc.varint(0);
        enc.varint(127);
        enc.varint(128);
        enc.varint(16384);
        assert_eq!(enc.scratch.out, [0, 127, 128, 1, 128, 128, 1]);
    }

    #[test]
    fn strings_and_references() {
        let mut enc = encoder();
        let a = b"abcd".to_vec();
        let b = vec![0u8, 1, 2];
        let long = vec![b'x'; 40];

        enc.string(&a);
        enc.string(&b);
        enc.string(&a);
        enc.string(&long);
        enc.string(&long);

        let mut want = vec![FIXSTR + 4, b'a', b'b', b'c', b'd', FIXSTR + 3, 0, 1, 2, T_R8, 0, T_S8, 40];
        want.extend_from_slice(&long);
        want.extend_from_slice(&[T_R8, 1]);

        assert_eq!(enc.scratch.out, want);
    }

    #[test]
    fn many_strings_switch_to_the_map() {
        let mut enc = encoder();
        let strings: Vec<Vec<u8>> = (0..LISTED + 10).map(|i| format!("string{i:03}").into_bytes()).collect();

        for s in &strings {
            enc.string(s);
        }

        assert!(enc.mapped);

        for (i, s) in strings.iter().enumerate() {
            enc.scratch.out.clear();
            enc.string(s);
            assert_eq!(enc.scratch.out, [T_R8, i as u8]);
        }
    }
}
