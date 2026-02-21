package tui

import "core:slice"

element :: proc (value : $ty, allocator := context.allocator) -> ^Element {
    return cast(^Element)new_clone(value, allocator)
}

label :: proc (text : string, allocator := context.allocator) -> ^Element {
    e := new(Element_Label, allocator)
    e^ = Element_Label_default

    e.text = text

    return e
}

linear :: proc (orientation : Element_Linear_Orientation, gap : Maybe(BoxType), s : LinearStretching, children : []^Element, allocator := context.allocator) -> ^Element {
    e := new(Element_Linear, allocator)
    e^ = Element_Linear_default
    e.children = slice.clone(children, allocator)

    e.stretching = s
    e.gap = gap
    e.isHorizontal = (orientation == .Horizontal)

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

table :: proc (size : Pos, gap : [2]Maybe(BoxType), stretching : [2]LinearStretching, children : []^Element, allocator := context.allocator) -> ^Element {
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
    e.gap = gap

    return e
}
