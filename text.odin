package tui

import "core:fmt"

import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:math"

import "core:log"



TextTokenType :: enum {
    EOF,
    Invalid,

    Word,
    Whitespace,
    ParagraphBreak,
}


TextToken :: struct {
    type : TextTokenType,
    value : string,
    n : int, // TODO: ugly but also idk about using union here
}

Tokenizer :: struct {
    text : string,

    peek : Maybe(TextToken),
}

text_isWhitespace :: proc (r : rune) -> bool {
    return r == ' ' || r == '\n' || r == '\t'
}

text_pop :: proc (t : ^Tokenizer) -> TextToken {
    if peek, ok := t.peek.?; ok {
        t.peek = {}
        return peek
    }

    if len(t.text) == 0 { return TextToken{ type = .EOF } }
    pc, _ := str_index(t.text, 0)

    if false {}
    else if text_isWhitespace(pc) {
        left := 0
        newLines := 0
        for c in t.text {
            if !text_isWhitespace(c) { break }

            if c == '\n' {
                newLines += 1
            }

            cs := utf8.rune_size(c)
            left += cs
        }

        if newLines <= 1 {
            token := TextToken{ type = .Whitespace, value = t.text[:left] }
            t.text = t.text[left:]
            return token
        }
        else {
            token := TextToken{ type = .ParagraphBreak, value = t.text[:left], n = newLines }
            t.text = t.text[left:]
            return token
        }

    }
    else {
        left := 0
        for c in t.text {
            if text_isWhitespace(c) { break }

            cs := utf8.rune_size(c)
            left += cs
        }

        token := TextToken{ type = .Word, value = t.text[:left] }
        t.text = t.text[left:]
        return token
    }

    return TextToken{ type = .Invalid }
}

text_peek :: proc (t : ^Tokenizer) -> TextToken {
    if peek, ok := t.peek.?; ok {
        return peek
    }

    p := text_pop(t)
    t.peek = p
    return p
}

drawTextBetterer :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true) -> (actualRect : Rect, truncated : bool) {
    t := Tokenizer{
        text = text
    }

    line := str.builder_make_none()

    line_index : i16 = 0
    line_index_actual : i16 = -1

    len_actual := i16(0)
    len_max := rect.z

    truncated = true

    nextEnsureWhitespace := false
    ensureWhitespace := false

    // TODO: this won't be able to support making stuff bold/changing colors mid-line. We probably need a
    // dynamic array storing styles and indexes they're changed at, and dump line accordingly by segments
    // We could just dump tokens immediately instead of accumulating, but then we wouldn't be able to align
    // reliably. I am perplexed

    // NOTE: for some reason append(&line.buf) is faster than sbprint(&line) (without aggressive optimizations)

    for true {
        token := text_pop(&t)
        if token.type == .EOF { truncated = false }

        if line_index >= rect.w { break }



        ensureWhitespace = nextEnsureWhitespace
        nextEnsureWhitespace = false


        if token.type == .Word {
            len_current := cast(i16)len(line.buf)
            len_ws      := ensureWhitespace ? i16(1) : 0
            len_word    := cast(i16)str_length(token.value)

            if len_current + len_ws + len_word <= len_max {
                if ensureWhitespace {
                    append(&line.buf, " ")
                }

                append(&line.buf, token.value)

                len_actual = math.max(len_actual, cast(i16)len(line.buf))
                line_index_actual = line_index
            }
            else {
                if len_word <= len_max {
                    t.peek = token
                }
                else {
                    remaining := len_max - (len_current + len_ws)

                    fit, rest, _ := substring_to(token.value, cast(int)remaining)
                    t.peek = TextToken{ type = .Word, value = rest }

                    if fit != "" && ensureWhitespace {
                        append(&line.buf, " ")
                    }

                    append(&line.buf, fit)

                    len_actual = math.max(len_actual, cast(i16)len(line.buf))
                    line_index_actual = line_index
                }


                lhs := rect.x // TODO: potential for aligning
                if rendering {
                    c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                    c_appendString(ctx.commandBuffer, str.to_string(line))
                }
                str.builder_reset(&line)

                line_index += 1
            }
        }
        else if token.type == .Whitespace {
            nextEnsureWhitespace = true
        }
        else if token.type == .ParagraphBreak {
            // It makes me think, in some sense having closures is a
            // convenient way to sugarize a state machine conveniently
            // contained in a single for loop, instead of being forced to
            // explicitly define the state and pass it to functions

            // NOTE: verbatim copypaste from .Word branch

            lhs := rect.x
            if rendering {
                c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                c_appendString(ctx.commandBuffer, str.to_string(line))
            }
            str.builder_reset(&line)

            line_index += 1



            // We are currently on the line below last text, if we have 2 new
            // lines it should translate into a single line gap
            line_index += i16(token.n - 1)
        }
        else if token.type == .EOF {
            // NOTE: verbatim copypaste from .Word branch
            lhs := rect.x
            if rendering {
                c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                c_appendString(ctx.commandBuffer, str.to_string(line))
            }
            str.builder_reset(&line)

            line_index += 1

            break
        }
        else {
            panic("bad")
        }
    }

    actualRect = { rect.x, rect.y, len_actual, line_index_actual + 1 }
    return
}
