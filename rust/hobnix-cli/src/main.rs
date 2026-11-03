//! Adapter of the strangler: the only place that writes to the terminal.

fn main() {
    println!("hobnix {}", hobnix_core::version());
}
