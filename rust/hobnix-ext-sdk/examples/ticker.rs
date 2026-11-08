//! Example service extension: publishes a snapshot with a counter on every tick and counts the events it is subscribed to.
//!
//!   cargo build --example ticker
//!   python3 ../../scripts/lib/ext_service.py run --name ticker --health-interval 1 --run-for 3 -- target/debug/examples/ticker
use hobnix_ext_sdk::service::{run, Ctx, EventRow, Health, Init, Service};
use serde_json::json;
use std::process::ExitCode;

#[derive(Default)]
struct Ticker {
    ticks: u64,
    seen: u64,
}

impl Service for Ticker {
    fn start(&mut self, init: &Init, _ctx: &Ctx) -> Result<(), String> {
        eprintln!("ticker starting as {} (subscribed to {:?})", init.name, init.subscribe);
        Ok(())
    }
    fn on_event(&mut self, _event: &EventRow, _ctx: &Ctx) -> Result<(), String> {
        // idempotent enough for an example: a repeated event only counts twice
        self.seen += 1;
        Ok(())
    }
    fn tick(&mut self, ctx: &Ctx) -> Health {
        self.ticks += 1;
        match ctx.snapshot("ticks", json!({ "ticks": self.ticks, "events_seen": self.seen })) {
            Ok(()) => Health::ok(),
            Err(e) => Health::degraded(format!("cannot publish: {e}")),
        }
    }
}

fn main() -> ExitCode {
    run(Ticker::default())
}
