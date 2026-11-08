//! Example command extension: `hs ext hello greet [name]` and `hs ext hello count <n>`.
//!
//! Try it without the core, with the reference runner:
//!   cargo build --example hello
//!   python3 ../../scripts/lib/ext_proto.py call --command greet --arg Ada -- target/debug/examples/hello
use hobnix_ext_sdk::command::{run, Ctx, Failure, Request, Success};
use hobnix_ext_sdk::{Event, LogLevel};
use serde_json::json;
use std::process::ExitCode;

fn handle(req: &Request, ctx: &Ctx) -> Result<Success, Failure> {
    match req.words().as_slice() {
        ["greet"] => {
            let name = req.argv.first().map(String::as_str).unwrap_or("world");
            let _ = ctx.log(LogLevel::Info, "greeting");
            let _ = ctx.event(&Event::new("pkg.hello.greeted", name));
            let greeting = format!("hello {name}");
            Ok(Success::data(json!({ "greeting": greeting })).with_text(greeting))
        }
        ["count"] => {
            let n: u32 = req
                .argv
                .first()
                .and_then(|a| a.parse().ok())
                .filter(|n| (1..=10).contains(n))
                .ok_or_else(|| Failure::bad_request("count needs a number from 1 to 10"))?;
            for i in 1..=n {
                let fraction = f64::from(i) / f64::from(n);
                let _ = ctx.progress(Some(fraction), &format!("step {i} of {n}"));
            }
            Ok(Success::data(json!({ "counted": n })))
        }
        _ => Err(Failure::not_found("no such command")),
    }
}

fn main() -> ExitCode {
    run(handle)
}
