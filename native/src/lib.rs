// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 exliipso
// Originally developed by exliipso

//! XNet native edition: the server half of XNet's encoder in Rust.
//!
//! Loaded with `require("xnet")` (gmsv_xnet_<platform>.dll). It registers the
//! global `XNetNative`, which the Lua edition picks up on its own. The bytes
//! it writes are the Lua edition's, so clients keep decoding with Lua and
//! never need a binary.
//!
//!     XNetNative.Pack(h0, h1, maxDepth, ...) -> string
//!         The arguments encoded, after the two bytes h0 and h1 (a message
//!         header). h0 < 0 leaves the prefix out. Raises on values that
//!         can't be sent.
//!     XNetNative.Encode(maxDepth, ...) -> string
//!         Pack without a prefix.
//!     XNetNative.TryPack(h0, h1, maxDepth, ...) -> string | nil, error
//!     XNetNative.TryEncode(maxDepth, ...) -> string | nil, error
//!         The same, returning the error instead of raising it.
//!     XNetNative.Batch(slot, h0, h1, maxDepth, room, ...) -> size | nil, error
//!         TryPack, appended to batch buffer `slot` (1 to 65535) instead of
//!         returned. A message bigger than `room` is not kept and -size is
//!         returned.
//!     XNetNative.Take(slot, marker) -> string
//!         The buffer's messages, then empties it. marker >= 0 puts the three
//!         bytes marker, 0, 0 in front; marker < 0 leaves them out.
//!     XNetNative.Drop(slot)
//!         Empties the buffer and frees its memory.
//!     XNetNative.Format   the payload format written (the Lua edition
//!                         ignores a module whose format isn't its own)
//!     XNetNative.Version
//!
//! The native functions never raise a Lua error: one would unwind through
//! the Rust frames below it. Pack and Encode raise from small Lua wrappers
//! built in gmod13_open.

#![allow(clippy::missing_safety_doc)]

#[macro_use]
extern crate gmod;

mod encode;

use gmod::lua::{LuaShared, State};
use std::cell::{Cell, RefCell};
use std::sync::OnceLock;

const LUA_TNUMBER: i32 = 3;

type CheckStack = unsafe extern "C-unwind" fn(State, i32) -> i32;
type RawGet = unsafe extern "C-unwind" fn(State, i32);

/// lua_shared functions gmod-rs doesn't bind.
struct Extra {
    check_stack: CheckStack,
    raw_get: RawGet,
}

static EXTRA: OnceLock<Extra> = OnceLock::new();

/// True when at least `slots` more values can be pushed. The C API's
/// contract is that a function reserves what it pushes beyond the first 20.
pub(crate) unsafe fn reserve(lua: State, slots: i32) -> bool {
    match EXTRA.get() {
        Some(extra) => (extra.check_stack)(lua, slots) != 0,
        None => false,
    }
}

/// lua_rawget: replaces the key on top of the stack with t[key], without
/// metamethods.
pub(crate) unsafe fn raw_get(lua: State, t: i32) {
    if let Some(extra) = EXTRA.get() {
        (extra.raw_get)(lua, t);
    }
}

unsafe fn load_extra() {
    let (library, _) = LuaShared::find_lua_shared();

    let check_stack = library.get::<CheckStack>(b"lua_checkstack\0").map(|s| *s);
    let raw_get = library.get::<RawGet>(b"lua_rawget\0").map(|s| *s);

    if let (Ok(check_stack), Ok(raw_get)) = (check_stack, raw_get) {
        let _ = EXTRA.set(Extra { check_stack, raw_get });
    }

    // lua_shared stays loaded for the life of the process.
    std::mem::forget(library);
}

thread_local! {
    // Registry references to the Lua helpers the encoder calls, under
    // pcall, for entities and for Vector/Angle values it can't read itself.
    static HELPERS: Cell<Option<Helpers>> = const { Cell::new(None) };
}

#[derive(Clone, Copy)]
pub(crate) struct Helpers {
    pub entity: i32,
    pub unpack: i32,
}

pub(crate) fn helpers() -> Option<Helpers> {
    HELPERS.with(Cell::get)
}

const HELPER_SOURCE: &str = "\
local tryPack, tryEncode, error = ...
local function entity(v)
    if IsValid(v) then return v:EntIndex() + 1 end
    if v == game.GetWorld() then return 1 end
    return 0
end
local function unpack(v) return v:Unpack() end
return function(...)
    local s, e = tryPack(...)
    if s == nil then error(e, 0) end
    return s
end, function(...)
    local s, e = tryEncode(...)
    if s == nil then error(e, 0) end
    return s
end, entity, unpack
";

/// An integer argument, or None for anything that isn't a number. The type
/// is only looked up for 0, which is also what anything else converts to.
unsafe fn int_arg(lua: State, index: i32) -> Option<isize> {
    let value = lua.to_integer(index);

    if value != 0 || lua.lua_type(index) == LUA_TNUMBER {
        Some(value)
    } else {
        None
    }
}

/// Returns nil and `message` to Lua.
unsafe fn fail(lua: State, message: &str) -> i32 {
    lua.push_nil();
    lua.push_string(message);
    2
}

/// Encodes the arguments from `first` on and returns the string, or nil and
/// the encoder's error.
unsafe fn finish(lua: State, first: i32, prefix: Option<[u8; 2]>, max_depth: isize) -> i32 {
    match encode::pack(lua, first, prefix, max_depth.max(1) as usize) {
        Ok(()) => 1,
        Err(message) => fail(lua, &message),
    }
}

#[lua_function]
unsafe fn xnet_try_pack(lua: State) -> i32 {
    let (Some(h0), Some(h1), Some(max_depth)) = (int_arg(lua, 1), int_arg(lua, 2), int_arg(lua, 3)) else {
        return fail(lua, "XNet: Pack(h0, h1, maxDepth, ...) takes numbers");
    };
    let prefix = if h0 < 0 { None } else { Some([h0 as u8, h1 as u8]) };

    finish(lua, 4, prefix, max_depth)
}

#[lua_function]
unsafe fn xnet_try_encode(lua: State) -> i32 {
    let Some(max_depth) = int_arg(lua, 1) else {
        return fail(lua, "XNet: Encode(maxDepth, ...) takes a number");
    };

    finish(lua, 2, None, max_depth)
}

// Batch buffers. Each starts with three bytes kept free for Take's marker.
const MARKER: usize = 3;
const MAX_SLOT: isize = 65535;

thread_local! {
    static BATCHES: RefCell<Vec<Vec<u8>>> = const { RefCell::new(Vec::new()) };
    // Set while Batch encodes. The encoder can run Lua (entity checks), and
    // a Batch from there would write to a buffer the outer call has taken.
    static BATCHING: Cell<bool> = const { Cell::new(false) };
}

/// Runs `f` on a slot's buffer, moved out of the table for the call.
fn with_slot<R>(slot: usize, f: impl FnOnce(&mut Vec<u8>) -> R) -> R {
    let mut buffer = BATCHES.with(|cell| {
        let mut slots = cell.borrow_mut();

        if slots.len() <= slot {
            slots.resize_with(slot + 1, Vec::new);
        }

        std::mem::take(&mut slots[slot])
    });

    let result = f(&mut buffer);

    BATCHES.with(|cell| cell.borrow_mut()[slot] = buffer);

    result
}

unsafe fn slot_arg(lua: State) -> Option<usize> {
    int_arg(lua, 1).filter(|slot| (1..=MAX_SLOT).contains(slot)).map(|slot| slot as usize)
}

#[lua_function]
unsafe fn xnet_batch(lua: State) -> i32 {
    let (Some(slot), Some(h0), Some(h1), Some(max_depth), Some(room)) =
        (slot_arg(lua), int_arg(lua, 2), int_arg(lua, 3), int_arg(lua, 4), int_arg(lua, 5))
    else {
        return fail(lua, "XNet: Batch(slot, h0, h1, maxDepth, room, ...) takes a slot from 1 to 65535 and numbers");
    };

    if BATCHING.with(|b| b.replace(true)) {
        return fail(lua, "XNet: Batch called while a batch is being encoded");
    }

    let result = with_slot(slot, |buffer| {
        if buffer.is_empty() {
            buffer.extend_from_slice(&[0; MARKER]);
        }

        let before = buffer.len();
        let result = encode::append(lua, 6, Some([h0 as u8, h1 as u8]), max_depth.max(1) as usize, buffer);
        let size = (buffer.len() - before) as isize;

        // Too big: not kept, so the caller can make room and try again.
        if size > room {
            buffer.truncate(before);
        }

        if buffer.len() == MARKER {
            buffer.clear();
        }

        result.map(|()| if size > room { -size } else { size })
    });

    BATCHING.with(|b| b.set(false));

    match result {
        Ok(size) => {
            lua.push_integer(size);
            1
        }
        Err(message) => fail(lua, &message),
    }
}

#[lua_function]
unsafe fn xnet_take(lua: State) -> i32 {
    let (Some(slot), Some(marker)) = (slot_arg(lua), int_arg(lua, 2)) else {
        return fail(lua, "XNet: Take(slot, marker) takes a slot from 1 to 65535 and a number");
    };

    with_slot(slot, |buffer| {
        if buffer.len() <= MARKER {
            lua.push_string("");
        } else if marker < 0 {
            lua.push_binary_string(&buffer[MARKER..]);
        } else {
            buffer[..MARKER].copy_from_slice(&[marker as u8, 0, 0]);
            lua.push_binary_string(buffer);
        }

        buffer.clear();

        if buffer.capacity() > encode::KEEP_BYTES {
            buffer.shrink_to_fit();
        }
    });

    1
}

#[lua_function]
unsafe fn xnet_drop(lua: State) -> i32 {
    if let Some(slot) = slot_arg(lua) {
        with_slot(slot, |buffer| {
            buffer.clear();
            buffer.shrink_to_fit();
        });
    }

    0
}

#[gmod13_open]
pub unsafe fn gmod13_open(lua: State) -> i32 {
    load_extra();

    // Without these the encoder doesn't run; XNetNative stays unset and the
    // Lua edition keeps encoding.
    if EXTRA.get().is_none() {
        return 0;
    }

    if lua.load_buffer(HELPER_SOURCE.as_bytes(), lua_string!("xnet")).is_err() {
        return 0;
    }

    lua.push_function(xnet_try_pack);
    lua.push_function(xnet_try_encode);
    lua.get_global(lua_string!("error"));

    if lua.pcall(3, 4, 0) != 0 {
        lua.pop();
        return 0;
    }

    // Stack: Pack, Encode, entity, unpack.
    let unpack = lua.reference();
    let entity = lua.reference();

    HELPERS.with(|cell| cell.set(Some(Helpers { entity, unpack })));

    lua.create_table(0, 10);
    lua.insert(-3);

    // Stack: XNetNative, Pack, Encode.
    lua.set_field(-3, lua_string!("Encode"));
    lua.set_field(-2, lua_string!("Pack"));

    lua.push_function(xnet_try_pack);
    lua.set_field(-2, lua_string!("TryPack"));

    lua.push_function(xnet_try_encode);
    lua.set_field(-2, lua_string!("TryEncode"));

    lua.push_function(xnet_batch);
    lua.set_field(-2, lua_string!("Batch"));

    lua.push_function(xnet_take);
    lua.set_field(-2, lua_string!("Take"));

    lua.push_function(xnet_drop);
    lua.set_field(-2, lua_string!("Drop"));

    lua.push_integer(encode::FORMAT as isize);
    lua.set_field(-2, lua_string!("Format"));

    lua.push_string(env!("CARGO_PKG_VERSION"));
    lua.set_field(-2, lua_string!("Version"));

    lua.set_global(lua_string!("XNetNative"));

    0
}

#[gmod13_close]
unsafe fn gmod13_close(lua: State) -> i32 {
    if let Some(helpers) = helpers() {
        lua.dereference(helpers.entity);
        lua.dereference(helpers.unpack);
        HELPERS.with(|cell| cell.set(None));
    }

    0
}
