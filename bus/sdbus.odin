// sd-bus, and what tray and notify share on top of it.
package kippbus

import "core:c"
import "core:strconv"
import "core:strings"

Bus :: struct {}
Bus_Message :: struct {}

// basu: sd-bus without systemd, built by download-deps.sh and linked in.
foreign import sdbus "system:basu"

@(default_calling_convention = "c", link_prefix = "sd_")
foreign sdbus {
	bus_default_user                 :: proc(bus: ^^Bus) -> c.int ---
	bus_default_system               :: proc(bus: ^^Bus) -> c.int ---
	bus_get_fd                       :: proc(bus: ^Bus) -> c.int ---
	bus_get_events                   :: proc(bus: ^Bus) -> c.int ---
	bus_process                      :: proc(bus: ^Bus, message: ^^Bus_Message) -> c.int ---
	bus_add_match                    :: proc(bus: ^Bus, slot: rawptr, rule: cstring, callback: rawptr, user: rawptr) -> c.int ---
	bus_request_name                 :: proc(bus: ^Bus, name: cstring, flags: u64) -> c.int ---
	bus_add_object_vtable            :: proc(bus: ^Bus, slot: rawptr, path, interface: cstring, vtable: [^]Vtable, user: rawptr) -> c.int ---
	bus_send                         :: proc(bus: ^Bus, message: ^Bus_Message, cookie: ^u64) -> c.int ---
	bus_call                         :: proc(bus: ^Bus, message: ^Bus_Message, timeout: u64, error: rawptr, reply: ^^Bus_Message) -> c.int ---
	// _strv, not the varargs form: see bus_message_new_method_return.
	bus_emit_properties_changed_strv :: proc(bus: ^Bus, path, interface: cstring, names: [^]cstring) -> c.int ---

	bus_message_unref                :: proc(message: ^Bus_Message) -> ^Bus_Message ---
	bus_message_get_path             :: proc(message: ^Bus_Message) -> cstring ---
	bus_message_get_interface        :: proc(message: ^Bus_Message) -> cstring ---
	bus_message_get_member           :: proc(message: ^Bus_Message) -> cstring ---
	bus_message_get_sender           :: proc(message: ^Bus_Message) -> cstring ---
	bus_message_get_type             :: proc(message: ^Bus_Message, type: ^u8) -> c.int ---
	bus_message_peek_type            :: proc(message: ^Bus_Message, type: ^u8, contents: ^cstring) -> c.int ---
	bus_message_read_basic           :: proc(message: ^Bus_Message, type: u8, value: rawptr) -> c.int ---
	bus_message_enter_container      :: proc(message: ^Bus_Message, type: u8, contents: cstring) -> c.int ---
	bus_message_exit_container       :: proc(message: ^Bus_Message) -> c.int ---
	bus_message_new_method_call      :: proc(bus: ^Bus, message: ^^Bus_Message, destination, path, interface, member: cstring) -> c.int ---
	bus_message_set_expect_reply     :: proc(message: ^Bus_Message, expect: c.int) -> c.int ---
	// sd_bus_reply_method_return and sd_bus_emit_signal are varargs in C.
	// Calling one through a non-varargs declaration leaves %al unset on
	// x86-64, which crashes. A reply is built from these instead.
	bus_message_new_method_return    :: proc(call: ^Bus_Message, message: ^^Bus_Message) -> c.int ---
	bus_message_new_signal           :: proc(bus: ^Bus, message: ^^Bus_Message, path, interface, member: cstring) -> c.int ---
	bus_message_append_basic         :: proc(message: ^Bus_Message, type: u8, value: rawptr) -> c.int ---
	bus_message_open_container       :: proc(message: ^Bus_Message, type: u8, contents: cstring) -> c.int ---
	bus_message_close_container      :: proc(message: ^Bus_Message) -> c.int ---
}

text_of :: proc(text: cstring) -> string {
	return text == nil ? "" : string(text)
}

cstr :: proc(text: string) -> cstring {
	return strings.clone_to_cstring(text, context.temp_allocator)
}

// ------------------------------------------------------------ the vtable
//
// basu's layout, 48 bytes. libsystemd's is 56, with parameter names and a
// format reference, and a mismatch shows only at run time.

Vtable_Start :: struct {
	element_size: uint,
}

Vtable_Method :: struct {
	member, signature, result: cstring,
	handler:                   Method_Handler,
	offset:                    uint,
}

Vtable_Signal :: struct {
	member, signature: cstring,
}

Vtable_Property :: struct {
	member, signature: cstring,
	get:               Property_Getter,
	set:               rawptr,
	offset:            uint,
}

Vtable :: struct {
	head: u64,   // type in the low 8 bits, flags in the 56 above
	body: struct #raw_union {
		start:    Vtable_Start,
		method:   Vtable_Method,
		signal:   Vtable_Signal,
		property: Vtable_Property,
	},
}

Method_Handler  :: #type proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int
Property_Getter :: #type proc "c" (bus: ^Bus, path, interface, property: cstring,
                                   reply: ^Bus_Message, user: rawptr, error: rawptr) -> c.int

@(private = "file") VTABLE_START    :: 0x3c   // '<'
@(private = "file") VTABLE_END      :: 0x3e   // '>'
@(private = "file") VTABLE_METHOD   :: 0x4d   // 'M'
@(private = "file") VTABLE_SIGNAL   :: 0x53   // 'S'
@(private = "file") VTABLE_PROPERTY :: 0x50   // 'P'
@(private = "file") UNPRIVILEGED    :: u64(1) << 2

PROPERTY_EMITS_CHANGE :: u64(1) << 5

@(private = "file")
vtable_head :: proc(type: u64, flags: u64) -> u64 {
	return type | (flags << 8)
}

vtable_start :: proc() -> (entry: Vtable) {
	entry.head = vtable_head(VTABLE_START, 0)
	entry.body.start.element_size = size_of(Vtable)
	return
}

vtable_method :: proc(member, signature, result: cstring, handler: Method_Handler) -> (entry: Vtable) {
	entry.head = vtable_head(VTABLE_METHOD, UNPRIVILEGED)
	entry.body.method = {member = member, signature = signature, result = result, handler = handler}
	return
}

vtable_signal :: proc(member, signature: cstring) -> (entry: Vtable) {
	entry.head = vtable_head(VTABLE_SIGNAL, 0)
	entry.body.signal = {member = member, signature = signature}
	return
}

vtable_property :: proc(member, signature: cstring, get: Property_Getter, flags: u64) -> (entry: Vtable) {
	entry.head = vtable_head(VTABLE_PROPERTY, flags)
	entry.body.property = {member = member, signature = signature, get = get}
	return
}

vtable_end :: proc() -> Vtable {
	return {head = vtable_head(VTABLE_END, 0)}
}

// ---------------------------------------------------------------- calling

reply_empty :: proc(call: ^Bus_Message) {
	reply: ^Bus_Message
	if bus_message_new_method_return(call, &reply) < 0 do return
	defer bus_message_unref(reply)
	bus_send(connection, reply, nil)
}

// One argument, from text, as the signature character says.
@(private = "file")
append_argument :: proc(message: ^Bus_Message, type: u8, text: string) -> bool {
	switch type {
	case 's', 'o', 'g':
		// append_basic takes the string itself for these, not its address.
		return bus_message_append_basic(message, type, rawptr(cstr(text))) >= 0
	case 'b':
		value := b32(text == "true" || text == "1")
		return bus_message_append_basic(message, type, &value) >= 0
	case 'y':
		number, _ := strconv.parse_u64(text)
		value := u8(number)
		return bus_message_append_basic(message, type, &value) >= 0
	case 'i':
		number, _ := strconv.parse_i64(text)
		value := i32(number)
		return bus_message_append_basic(message, type, &value) >= 0
	case 'u':
		number, _ := strconv.parse_u64(text)
		value := u32(number)
		return bus_message_append_basic(message, type, &value) >= 0
	case 'x':
		value, _ := strconv.parse_i64(text)
		return bus_message_append_basic(message, type, &value) >= 0
	case 't':
		value, _ := strconv.parse_u64(text)
		return bus_message_append_basic(message, type, &value) >= 0
	case 'd':
		value, _ := strconv.parse_f64(text)
		return bus_message_append_basic(message, type, &value) >= 0
	}
	return false   // a container needs a shape, and text carries none
}

@(private = "file")
new_call :: proc(destination, path, interface, member, signature: string,
                 arguments: []string) -> (message: ^Bus_Message, ok: bool) {
	if destination == "" || path == "" || interface == "" || member == "" do return nil, false
	if len(signature) != len(arguments) do return nil, false

	if bus_message_new_method_call(connection, &message, cstr(destination), cstr(path),
	                               cstr(interface), cstr(member)) < 0 {
		return nil, false
	}
	for argument, index in arguments {
		if !append_argument(message, signature[index], argument) {
			bus_message_unref(message)
			return nil, false
		}
	}
	return message, true
}

// No reply is asked for: the facts that follow show what the call did, and a
// slow application cannot stall the loop.
call_method :: proc(destination, path, interface, member, signature: string,
                    arguments: []string) -> bool {
	message := new_call(destination, path, interface, member, signature, arguments) or_return
	defer bus_message_unref(message)
	bus_message_set_expect_reply(message, 0)
	return bus_send(connection, message, nil) >= 0
}

// The reply arrives through the loop, like a signal. sd_bus_send marks a
// message sent without a cookie as wanting no reply.
call_method_with_reply :: proc(destination, path, interface, member, signature: string,
                               arguments: []string) -> bool {
	message := new_call(destination, path, interface, member, signature, arguments) or_return
	defer bus_message_unref(message)
	cookie: u64
	return bus_send(connection, message, &cookie) >= 0
}

// Blocks until the reply, so for start-up only.
call_method_and_wait :: proc(destination, path, interface, member, signature: string,
                             arguments: []string) -> (reply: ^Bus_Message, ok: bool) {
	message := new_call(destination, path, interface, member, signature, arguments) or_return
	defer bus_message_unref(message)
	if bus_call(connection, message, 0, nil, &reply) < 0 do return nil, false
	return reply, true
}
