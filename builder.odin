package tui

import "core:slice"

stretching :: proc (s : Stretching, o : []LinearStretchingOverride = {}) -> LinearStretching {
    return { single = s, overrides = o }
}

label :: proc (text : string, allocator := context.allocator) -> ^Element {
    e := new(Element_Label, allocator)
    e^ = Element_Label_default

    e.text = text

    return e
}

linear :: proc (s : Stretching, isHorizontal : bool, children : []^Element, allocator := context.allocator) -> ^Element {
    e := new(Element_Linear, allocator)
    e^ = Element_Linear_default
    e.children = slice.clone(children, allocator)

    e.stretching = LinearStretching{ single = s }
    e.isHorizontal = isHorizontal

    return e
}

scroll :: proc (scroll : [2]bool, scrollbar : [2]bool, targetFocus : bool, child : ^Element, allocator := context.allocator) -> ^Element {
    e := new(Element_Scroll, allocator)
    e^ = Element_Scroll_default
    e.children = slice.clone([]^Element{ child }, allocator)

    e.scroll = scroll
    e.scrollbar = scrollbar
    e.targetFocus = targetFocus

    return e
}

box :: proc (border : BoxType, margin : Rect, padding : Rect, child : ^Element, allocator := context.allocator) -> ^Element {
    e := new(Element_Box, allocator)
    e^ = Element_Box_default
    e.children = slice.clone([]^Element{ child }, allocator)

    e.border = border

    return e
}

table :: proc (size : Pos, stretching : [2]LinearStretching, children : []^Element, allocator := context.allocator) -> ^Element {
    e := new(Element_Table, allocator)
    e^ = Element_Table_default
    e.children = slice.clone(children, allocator)

    buffer, _ := buffer_create(Rect{ 0, 0, size.x, size.y }, int, allocator)
    e.configuration = buffer

    index := 0
    for y in 0..<size.y {
        for x in 0..<size.x {
            buffer_set(buffer, { x, y }, index)
            index += 1
        }
    }

    // TODO: array and overrides need to be copied to allocator
    e.stretchingCols = stretching[0]
    e.stretchingRows = stretching[1]

    return e
}
