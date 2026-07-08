package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import "core:os"
import "core:math"
import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"

FontModeOption :: enum {
    Bold = 1,
    Dim = 2,
    Italic = 3,
    Underline = 4,
    Blinking = 5,
    Inverse = 7,
    Hidden = 8,
    Strikethrough = 9,
}

FontMode :: bit_set[FontModeOption]

FontColor_Standard :: enum {
    Black = 30,
    Red = 31,
    Green = 32,
    Yellow = 33,
    Blue = 34,
    Magenta = 35,
    Cyan = 36,
    White = 37,
    Default = 39,
}

FontColor_Bright :: enum {
    Black = 90,
    Red = 91,
    Green = 92,
    Yellow = 93,
    Blue = 94,
    Magenta = 95,
    Cyan = 96,
    White = 97,
}

FontColor_256 :: struct {
    id : u8,
}

FontColor_RGB :: struct {
    r : u8,
    g : u8,
    b : u8,
}

FontColor :: union {
    FontColor_Standard,
    FontColor_Bright,
    FontColor_256,
    FontColor_RGB,
}


FontStyle :: struct {
    bg : FontColor,
    fg : FontColor,

    mode : FontMode,
}

// TODO: wouldn't it make more sense to use buffers for everything and
// stdout only for the very final step? I guess it is kinda more efficient
// in some cases, but idk. Probably doesn't matter either way tbh

// TODO: Is default just no mode and Standard.Default color?
// NOTE: how the fuck is this not a compile time constant
FontStyle_default := FontStyle{
    mode = FontMode{},
    fg = FontColor_Standard.Default,
    bg = FontColor_Standard.Default,
}

write_FontColor :: proc (c : FontColor, bg : bool, buffer : []u8) -> string {
    switch color in c {
    case FontColor_Standard:
        bgi := bg ? 10 : 0
        return fmt.bprintf(buffer, "\e[%vm", int(color) + bgi)
    case FontColor_Bright:
        bgi := bg ? 10 : 0
        return fmt.bprintf(buffer, "\e[%vm", int(color) + bgi)
    case FontColor_256:
        bgi := bg ? 48 : 38
        return fmt.bprintf(buffer, "\e[%v;5;%vm", bgi, color.id)
    case FontColor_RGB:
        bgi := bg ? 48 : 38
        return fmt.bprintf(buffer, "\e[%v;2;%v;%v;%v", bgi, color.r, color.g, color.b)
    }

    panic("bad")
}

write_FontMode :: proc (m : FontMode, buffer : []u8) -> string {
    sb := str.builder_from_bytes(buffer)

    str.write_string(&sb, "\e[")

    for mode, i in FontModeOption {
        if i != 0 { str.write_rune(&sb, ';') }

        inc := mode in m ? 0 : (20 + (mode == .Bold ? 1 : 0))
        fmt.sbprintf(&sb, "%v", int(mode) + inc)
    }

    str.write_rune(&sb, 'm')
    return str.to_string(sb)
}




// TODO: i still have very little clue on how we're going to handle wide characters (japanese and chinese), if at all

CommandBuffer :: union {
    CommandBuffer_Stdout,
    CommandBuffer_Buffer,
}


CommandBuffer_Stdout :: struct {
    builder : str.Builder,

    style : FontStyle,
}

CellData :: struct {
    r : rune,
    style : FontStyle,
}

BoxCellData :: struct {
    masks : [4]BoxTypeMask,
    style : FontStyle,
    layer : int,
}

// NOTE: there is no latency to copying into user memory as compared to writing to stdout, so we just immediately execute all commands
CommandBuffer_Buffer :: struct {
    buffer : Buffer(CellData),

    pos : Pos,
    style : FontStyle,
}



// NOTE: 
// c_   : fundamental command (needs to be implemented for both Stdout and Buffer)
// cc_  : derived command (is defined in terms of other c_ or cc_ commands)

c_reset :: proc (cbb : ^CommandBuffer) {
    switch &cb in cbb {
    case CommandBuffer_Stdout:
        str.builder_reset(&cb.builder)
    case CommandBuffer_Buffer:
        buffer_reset(cb.buffer, CellData{ r = '\x00' })
    }
}

c_appendRune :: proc (cbb : ^CommandBuffer, r : rune) {
    switch &cb in cbb {
    case CommandBuffer_Stdout:
        str.write_rune(&cb.builder, r)
    case CommandBuffer_Buffer:
        buffer_set(cb.buffer, cb.pos, CellData{ r = r, style = cb.style })
        cb.pos.x += 1
        if cb.pos.x >= cb.buffer.rect.x + cb.buffer.rect.z {
            cb.pos.x = cb.buffer.rect.x
            cb.pos.y += 1
        }
    }
}

c_appendString :: proc (cbb : ^CommandBuffer, s : string) {
    switch &cb in cbb {
    case CommandBuffer_Stdout:
        str.write_string(&cb.builder, s)
    case CommandBuffer_Buffer:
        for c in s {
            c_appendRune(cbb, c)
        }
    }
}

c_clear :: proc (cbb : ^CommandBuffer) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        c_appendString(cbb, "\e[2J")
    case CommandBuffer_Buffer:
        buffer_reset(cb.buffer, CellData{ r = '\x00' })
    }
}

c_goto :: proc (cbb : ^CommandBuffer, p : Pos) {
    switch &cb in cbb {
    case CommandBuffer_Stdout:
        buffer : [32]u8
        s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y + 1, p.x + 1)
        c_appendString(cbb, s)
    case CommandBuffer_Buffer:
        cb.pos = p
    }
}

c_styleClear :: proc (cbb : ^CommandBuffer) {
    switch &cb in cbb {
    case CommandBuffer_Stdout:
        c_appendString(cbb, "\e[0m")
        cb.style = FontStyle_default
    case CommandBuffer_Buffer:
        cb.style = FontStyle_default
    }
}

c_style :: proc (cbb : ^CommandBuffer, style : FontStyle) -> (previous : FontStyle) {
    previous = c_styleGet(cbb)
    if style == previous { return }

    switch &cb in cbb {
    case CommandBuffer_Stdout:
        c_styleClear(cbb)

        buffer : [64]u8
        c_appendString(cbb, write_FontMode(style.mode, buffer[:]))
        c_appendString(cbb, write_FontColor(style.fg, false, buffer[:]))
        c_appendString(cbb, write_FontColor(style.bg, true, buffer[:]))

        cb.style = style
    case CommandBuffer_Buffer:
        cb.style = style
    }
    
    return
}

c_styleGet :: proc (cbb : ^CommandBuffer) -> (style : FontStyle) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        return cb.style
    case CommandBuffer_Buffer:
        return cb.style
    }

    panic("bad")
}

cc_bufferPresentCool :: proc (cb : ^CommandBuffer, buffer : Buffer(CellData), dstOffset : Pos, selection : Rect) {
    consecutive := true
    c_goto(cb, dstOffset)

    lastStyle := c_styleGet(cb)

    for y in 0..<selection.w {
        for x in 0..<selection.z {
            c := buffer_get(buffer, { x, y } + selection.xy) or_continue
            if c.r == '\x00' {
                consecutive = false
                continue
            }

            if c.style != {} && c.style != lastStyle {
                c_style(cb, c.style)
                lastStyle = c.style
            }

            if !consecutive {
                c_goto(cb, { x, y } + dstOffset)
                consecutive = true
            }

            c_appendRune(cb, c.r)
        }

        // NOTE: unless buffer is the width of the screen
        consecutive = false
    }
}

cc_fill :: proc (cb : ^CommandBuffer, rect : Rect, char : rune = ' ') {
    for y in rect.y ..= (rect.y + rect.w - 1) {
        c_goto(cb, { rect.x, y })
        for x in rect.x ..= (rect.x + rect.z - 1) {
            c_appendRune(cb, char)
        }
    }
}
