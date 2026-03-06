// Generated from the WAVS WIT interface definitions.
// Do not edit manually.

#![allow(clippy::too_many_arguments)]
#![allow(dead_code)]

wit_bindgen::generate!({
    world: "wavs-world",
    path: "../../../wit/operator.wit",
    pub_export_macro: true,
    generate_all,
});

/// Macro to export a WAVS trigger world component.
///
/// Usage:
/// ```rust
/// struct MyComponent;
/// impl Guest for MyComponent { ... }
/// export_layer_trigger_world!(MyComponent);
/// ```
#[macro_export]
macro_rules! export_layer_trigger_world {
    ($Component:ty) => {
        $crate::bindings::world::export!(Component with_types_in $crate::bindings::world);
    };
}
