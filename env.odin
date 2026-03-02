package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"
import os_old "core:os"
import "core:math"
import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"


EnvironmentLayer :: struct {
    id : int,
    returnFocusTo : int, // NOTE: which layer added this one (and to whom return focus after own deletion)

    root  : ^Element,
    focus : ^Element,

    // TODO: Does focus affect anything apart from receiving inputs?
    focused : bool,
}

Environment :: struct {
    quit : bool,

    availableLayerId : int,
    layers : [dynamic]EnvironmentLayer,
}

env_input :: proc (env : ^Environment, input : rune) {
    #reverse for layer in env.layers {
        if !layer.focused { continue }

        input_internal :: proc (e : ^Element, r : ^Element, input : rune) {
            if e != r { e->input(input) }
            for c in e.children {
                input_internal(c, r, input)
            }
        }

        input_internal(layer.root, layer.focus, input)

        if layer.focus != nil {
            layer.focus->inputFocus(input)
        }
    }
}

env_addLayer :: proc (env : ^Environment, root : ^Element, autofocus : bool, focused : bool = true, returnFocusTo : int = 0) -> (layerId : int) {
    env.availableLayerId += 1 // NOTE: 0 is thus not a valid id
    layer := EnvironmentLayer{
        id = env.availableLayerId,
        returnFocusTo = returnFocusTo,

        root = root,
        focus = nil,

        focused = focused,
    }
    append(&env.layers, layer)



    root.environment = env
    element_assignParentRecurse(root)
    if autofocus {
        element_focus(root)
    }



    return layer.id
}
