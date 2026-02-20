package tui

import "core:slice"

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

    e.stretching = s
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
