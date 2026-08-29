# Structural JSON hook editor for the POSIX Team Skills installer.
#
# Usage:
#   awk -v operation=check -f team-skills-json.awk hooks.json
#   TEAM_SKILLS_JSON_COMMAND='...' awk -v operation=add -v product=claude -f ... hooks.json
#   TEAM_SKILLS_JSON_COMMAND='...' awk -v operation=remove -v product=cursor -f ... hooks.json
#
# The implementation deliberately uses only POSIX awk. It parses the complete JSON document,
# rejects duplicate object keys, mutates only the supported hook array, and emits valid JSON.

function fail(message, status) {
    print "json editor: " message > "/dev/stderr"
    exit (status ? status : 2)
}

function skip_space(    character) {
    while (position <= length(document)) {
        character = substr(document, position, 1)
        if (character !~ /[ \t\r\n]/) break
        position++
    }
}

function new_node(kind, value,    id) {
    id = ++node_count
    node_kind[id] = kind
    node_value[id] = value
    node_size[id] = 0
    return id
}

function append_child(parent, child,    position_index) {
    position_index = ++node_size[parent]
    node_child[parent SUBSEP position_index] = child
}

function append_member(parent, name, raw_name, child,    position_index) {
    position_index = ++node_size[parent]
    node_name[parent SUBSEP position_index] = name
    node_name_raw[parent SUBSEP position_index] = raw_name
    node_child[parent SUBSEP position_index] = child
}

function hex_value(character) {
    character = tolower(character)
    if (character >= "0" && character <= "9") return character + 0
    return index("abcdef", character) + 9
}

function ascii_character(value) {
    if (!ascii_ready) {
        for (ascii_index = 1; ascii_index < 128; ascii_index++) {
            ascii_table[ascii_index] = sprintf("%c", ascii_index)
        }
        ascii_ready = 1
    }
    return ascii_table[value]
}

function decode_string(raw,    result, index_value, character, escape, hex, value) {
    result = ""
    for (index_value = 2; index_value < length(raw); index_value++) {
        character = substr(raw, index_value, 1)
        if (character != "\\") {
            result = result character
            continue
        }
        escape = substr(raw, ++index_value, 1)
        if (escape == "\"" || escape == "\\" || escape == "/") result = result escape
        else if (escape == "b") result = result ascii_character(8)
        else if (escape == "f") result = result ascii_character(12)
        else if (escape == "n") result = result "\n"
        else if (escape == "r") result = result "\r"
        else if (escape == "t") result = result "\t"
        else if (escape == "u") {
            hex = substr(raw, index_value + 1, 4)
            value = hex_value(substr(hex, 1, 1)) * 4096 + \
                    hex_value(substr(hex, 2, 1)) * 256 + \
                    hex_value(substr(hex, 3, 1)) * 16 + \
                    hex_value(substr(hex, 4, 1))
            if (value < 128) result = result ascii_character(value)
            else result = result "\\u" hex
            index_value += 4
        }
    }
    return result
}

function parse_string(    start, character, escape, hex) {
    start = position
    position++
    while (position <= length(document)) {
        character = substr(document, position, 1)
        if (character == "\"") {
            position++
            return new_node("string", substr(document, start, position - start))
        }
        if (character == "\n" || character == "\r") fail("unescaped control character in string")
        if (character == "\\") {
            position++
            escape = substr(document, position, 1)
            if (escape ~ /^["\\\/bfnrt]$/) {
                position++
                continue
            }
            if (escape == "u") {
                hex = substr(document, position + 1, 4)
                if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
                    fail("invalid Unicode escape")
                }
                position += 5
                continue
            }
            fail("invalid string escape")
        }
        position++
    }
    fail("unterminated string")
}

function parse_array(    id, child, character) {
    id = new_node("array", "")
    position++
    skip_space()
    if (substr(document, position, 1) == "]") {
        position++
        return id
    }
    while (1) {
        child = parse_value()
        append_child(id, child)
        skip_space()
        character = substr(document, position, 1)
        if (character == "]") {
            position++
            return id
        }
        if (character != ",") fail("expected comma or closing bracket")
        position++
        skip_space()
    }
}

function parse_object(    id, key_node, key_name, child, character, duplicate_key) {
    id = new_node("object", "")
    position++
    skip_space()
    if (substr(document, position, 1) == "}") {
        position++
        return id
    }
    while (1) {
        if (substr(document, position, 1) != "\"") fail("object key must be a string")
        key_node = parse_string()
        key_name = decode_string(node_value[key_node])
        duplicate_key = id SUBSEP key_name
        if (object_seen[duplicate_key]) fail("duplicate object key")
        object_seen[duplicate_key] = 1
        skip_space()
        if (substr(document, position, 1) != ":") fail("expected colon after object key")
        position++
        skip_space()
        child = parse_value()
        append_member(id, key_name, node_value[key_node], child)
        skip_space()
        character = substr(document, position, 1)
        if (character == "}") {
            position++
            return id
        }
        if (character != ",") fail("expected comma or closing brace")
        position++
        skip_space()
    }
}

function parse_value(    character, remaining, matched) {
    skip_space()
    character = substr(document, position, 1)
    if (character == "{") return parse_object()
    if (character == "[") return parse_array()
    if (character == "\"") return parse_string()
    remaining = substr(document, position)
    if (substr(remaining, 1, 4) == "true") {
        position += 4
        return new_node("literal", "true")
    }
    if (substr(remaining, 1, 5) == "false") {
        position += 5
        return new_node("literal", "false")
    }
    if (substr(remaining, 1, 4) == "null") {
        position += 4
        return new_node("literal", "null")
    }
    if (match(remaining, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
        matched = substr(remaining, 1, RLENGTH)
        position += RLENGTH
        return new_node("number", matched)
    }
    fail("invalid JSON value")
}

function quote_string(value,    result, index_value, character) {
    result = "\""
    for (index_value = 1; index_value <= length(value); index_value++) {
        character = substr(value, index_value, 1)
        if (character == "\"" || character == "\\") result = result "\\" character
        else if (character == "\n") result = result "\\n"
        else if (character == "\r") result = result "\\r"
        else if (character == "\t") result = result "\\t"
        else result = result character
    }
    return result "\""
}

function object_index(id, wanted,    index_value) {
    if (node_kind[id] != "object") return 0
    for (index_value = 1; index_value <= node_size[id]; index_value++) {
        if (node_name[id SUBSEP index_value] == wanted) return index_value
    }
    return 0
}

function object_value(id, wanted,    index_value) {
    index_value = object_index(id, wanted)
    return index_value ? node_child[id SUBSEP index_value] : 0
}

function add_named_value(id, name, child) {
    append_member(id, name, quote_string(name), child)
}

function ensure_named_container(id, name, kind,    child) {
    child = object_value(id, name)
    if (!child) {
        child = new_node(kind, "")
        add_named_value(id, name, child)
    } else if (node_kind[child] != kind) {
        fail(name " must be a JSON " kind)
    }
    return child
}

function string_equals(id, value) {
    return node_kind[id] == "string" && decode_string(node_value[id]) == value
}

function literal_equals(id, value) {
    return (node_kind[id] == "literal" || node_kind[id] == "number") && node_value[id] == value
}

function owned_handler(id,    type_id, command_id, async_id) {
    if (node_kind[id] != "object" || node_size[id] != 3) return 0
    type_id = object_value(id, "type")
    command_id = object_value(id, "command")
    async_id = object_value(id, "async")
    return string_equals(type_id, "command") && string_equals(command_id, command) && \
           literal_equals(async_id, "true")
}

function owned_group(id,    matcher_id, handlers_id, handler_id) {
    if (node_kind[id] != "object" || node_size[id] != 2) return 0
    matcher_id = object_value(id, "matcher")
    handlers_id = object_value(id, "hooks")
    if (!string_equals(matcher_id, "startup|clear") || node_kind[handlers_id] != "array" || \
        node_size[handlers_id] != 1) return 0
    handler_id = node_child[handlers_id SUBSEP 1]
    return owned_handler(handler_id)
}

function owned_cursor_hook(id,    command_id) {
    if (node_kind[id] != "object" || node_size[id] != 1) return 0
    command_id = object_value(id, "command")
    return string_equals(command_id, command)
}

function make_lifecycle_group(    group, matcher_node, handlers, handler) {
    group = new_node("object", "")
    matcher_node = new_node("string", quote_string("startup|clear"))
    add_named_value(group, "matcher", matcher_node)
    handlers = new_node("array", "")
    handler = new_node("object", "")
    add_named_value(handler, "type", new_node("string", quote_string("command")))
    add_named_value(handler, "command", new_node("string", quote_string(command)))
    add_named_value(handler, "async", new_node("literal", "true"))
    append_child(handlers, handler)
    add_named_value(group, "hooks", handlers)
    return group
}

function make_cursor_hook(    hook) {
    hook = new_node("object", "")
    add_named_value(hook, "command", new_node("string", quote_string(command)))
    return hook
}

function add_hook(root,    hooks, event, version, index_value, child) {
    hooks = ensure_named_container(root, "hooks", "object")
    if (product == "cursor") {
        version = object_value(root, "version")
        if (!version) add_named_value(root, "version", new_node("number", "1"))
        else if (!literal_equals(version, "1")) fail("Cursor hook version must be 1")
        event = ensure_named_container(hooks, "sessionStart", "array")
        for (index_value = 1; index_value <= node_size[event]; index_value++) {
            child = node_child[event SUBSEP index_value]
            if (owned_cursor_hook(child)) return
        }
        append_child(event, make_cursor_hook())
        return
    }
    event = ensure_named_container(hooks, "SessionStart", "array")
    for (index_value = 1; index_value <= node_size[event]; index_value++) {
        child = node_child[event SUBSEP index_value]
        if (owned_group(child)) return
    }
    append_child(event, make_lifecycle_group())
}

function remove_array_index(id, removed_index,    index_value) {
    for (index_value = removed_index; index_value < node_size[id]; index_value++) {
        node_child[id SUBSEP index_value] = node_child[id SUBSEP (index_value + 1)]
    }
    delete node_child[id SUBSEP node_size[id]]
    node_size[id]--
}

function remove_hook(root,    hooks, event, index_value, child, matches, matched_index) {
    hooks = object_value(root, "hooks")
    if (!hooks || node_kind[hooks] != "object") fail("owned hook container is missing", 3)
    event = object_value(hooks, product == "cursor" ? "sessionStart" : "SessionStart")
    if (!event || node_kind[event] != "array") fail("owned hook event is missing", 3)
    for (index_value = 1; index_value <= node_size[event]; index_value++) {
        child = node_child[event SUBSEP index_value]
        if ((product == "cursor" && owned_cursor_hook(child)) || \
            (product != "cursor" && owned_group(child))) {
            matches++
            matched_index = index_value
        }
    }
    if (matches != 1) fail(matches ? "owned hook entry is ambiguous" : "owned hook entry changed or is missing", 3)
    remove_array_index(event, matched_index)
}

function indent(level,    result, index_value) {
    result = ""
    for (index_value = 0; index_value < level; index_value++) result = result "  "
    return result
}

function render(id, level,    kind, result, index_value, child) {
    kind = node_kind[id]
    if (kind == "string" || kind == "literal" || kind == "number") return node_value[id]
    if (kind == "array") {
        if (!node_size[id]) return "[]"
        result = "[\n"
        for (index_value = 1; index_value <= node_size[id]; index_value++) {
            child = node_child[id SUBSEP index_value]
            result = result indent(level + 1) render(child, level + 1)
            result = result (index_value < node_size[id] ? ",\n" : "\n")
        }
        return result indent(level) "]"
    }
    if (kind == "object") {
        if (!node_size[id]) return "{}"
        result = "{\n"
        for (index_value = 1; index_value <= node_size[id]; index_value++) {
            child = node_child[id SUBSEP index_value]
            result = result indent(level + 1) node_name_raw[id SUBSEP index_value] ": " \
                     render(child, level + 1)
            result = result (index_value < node_size[id] ? ",\n" : "\n")
        }
        return result indent(level) "}"
    }
    fail("internal node type is invalid")
}

BEGIN {
    document = ""
}

{
    document = document (NR == 1 ? "" : "\n") $0
}

END {
    if (document == "") document = "{}"
    position = 1
    root_node = parse_value()
    skip_space()
    if (position <= length(document)) fail("trailing content after JSON document")
    if (node_kind[root_node] != "object") fail("top-level JSON value must be an object")

    if (operation == "check") exit 0
    if (operation != "add" && operation != "remove") fail("unsupported operation")
    if (product != "claude" && product != "codex" && product != "cursor") fail("unsupported product")
    if (command == "") command = ENVIRON["TEAM_SKILLS_JSON_COMMAND"]
    if (command == "") fail("command must not be blank")

    if (operation == "add") add_hook(root_node)
    else remove_hook(root_node)
    print render(root_node, 0)
}
