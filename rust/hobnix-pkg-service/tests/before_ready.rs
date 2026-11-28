//! Nothing but `ready` may come before `ready` (ADR 0011 rule 6): what is written during `start` is held back (#1353). The tests use no
//! sleeps: `start` joins its thread or waits on a channel.

#[cfg(test)]
mod tests {
    use std::io::{Cursor, ErrorKind, Write};
    use std::panic::{AssertUnwindSafe, catch_unwind};
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};
    use std::thread;

    use hobnix_pkg::{Ctx, Error, Event, LogLevel};
    use hobnix_pkg_service::{self as service, Init, Service};
    use serde_json::{Value, json};

    #[derive(Clone, Default)]
    struct Buf(Arc<Mutex<Vec<u8>>>);

    impl Write for Buf {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Buf {
        fn lines(&self) -> Vec<Value> {
            let text = String::from_utf8(self.0.lock().unwrap().clone()).unwrap();
            text.lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    /// A service whose `start` is the closure.
    struct OnStart<F>(F);

    impl<F: FnMut(&dyn Ctx) -> Result<(), Error>> Service for OnStart<F> {
        fn start(&mut self, _init: &Init, ctx: &dyn Ctx) -> Result<(), Error> {
            (self.0)(ctx)
        }
    }

    fn run(output: Buf, start: impl FnMut(&dyn Ctx) -> Result<(), Error>) -> u8 {
        let init = json!({"v":1,"type":"init","name":"demo","lang":"en","subscribe":[],"health_interval":30});
        let input = Cursor::new(format!("{init}\n").into_bytes());
        service::run_with(input, output, OnStart(start))
    }

    /// What the service wrote without the runner's own `health` lines.
    fn without_health(output: &Buf) -> Vec<Value> {
        let mut lines = output.lines();
        lines.retain(|line| line["type"] != "health");
        lines
    }

    #[test]
    fn what_a_thread_and_start_write_is_sent_after_ready_in_order() {
        let output = Buf::default();
        let seen_in_start = output.clone();
        let code = run(output.clone(), move |ctx| {
            ctx.log(LogLevel::Info, "from start")?;
            let shared = ctx.shared();
            // start waits for its thread: a held write must not block it
            let poller = thread::spawn(move || {
                shared.log(LogLevel::Warn, "from the thread").unwrap();
                shared.snapshot("t", json!(1)).unwrap();
                shared.emit(&Event::new("pkg.demo.seen", "x")).unwrap();
                shared.rollup("pkg.demo.watch", "anna", 1.0, 2.0).unwrap();
            });
            poller.join().unwrap();
            assert!(seen_in_start.lines().is_empty(), "nothing before ready");
            Ok(())
        });
        assert_eq!(code, 0);
        let lines = without_health(&output);
        let types: Vec<&str> = lines.iter().map(|l| l["type"].as_str().unwrap()).collect();
        assert_eq!(types, ["ready", "log", "log", "snapshot", "emit", "rollup"]);
        assert_eq!(lines[1]["text"], "from start");
        assert_eq!(lines[2]["text"], "from the thread");
    }

    /// The log lines `0` to `499`; `first_written` hears when the first one is written.
    fn log_500_numbers(ctx: &dyn Ctx, first_written: &mpsc::Sender<()>) {
        for number in 0..500 {
            ctx.log(LogLevel::Info, &number.to_string()).unwrap();
            if number == 0 {
                first_written.send(()).unwrap();
            }
        }
    }

    #[test]
    fn a_thread_that_writes_across_ready_keeps_its_order() {
        let output = Buf::default();
        let (first_written, wait_for_first) = mpsc::channel();
        let (done, wait_for_done) = mpsc::channel();
        run(output.clone(), move |ctx| {
            let (shared, first_written, done) = (ctx.shared(), first_written.clone(), done.clone());
            thread::spawn(move || {
                log_500_numbers(shared.as_ref(), &first_written);
                done.send(()).unwrap();
            });
            wait_for_first.recv().unwrap();
            Ok(())
        });
        wait_for_done.recv().unwrap();
        let lines = without_health(&output);
        assert_eq!(lines[0]["type"], "ready");
        let numbers: Vec<String> = lines[1..]
            .iter()
            .map(|l| l["text"].as_str().unwrap().to_owned())
            .collect();
        let expected: Vec<String> = (0..500).map(|n| n.to_string()).collect();
        assert_eq!(numbers, expected);
    }

    #[test]
    fn more_than_1000_messages_are_dropped_and_counted_after_ready() {
        let output = Buf::default();
        run(output.clone(), |ctx| {
            for number in 0..1000 {
                ctx.log(LogLevel::Info, &number.to_string())?;
            }
            for _ in 0..500 {
                ctx.log(LogLevel::Info, "too many")?;
            }
            Ok(())
        });
        let lines = without_health(&output);
        assert_eq!(lines.len(), 1002);
        assert_eq!(lines[1000]["text"], "999");
        assert_eq!(lines[1001]["level"], "warn");
        assert_eq!(
            lines[1001]["text"],
            "500 messages written before ready were dropped (at most 1000 messages or 4 MiB are held)"
        );
    }

    #[test]
    fn more_than_4_mib_are_dropped_and_counted_after_ready() {
        let output = Buf::default();
        run(output.clone(), |ctx| {
            let data = json!("x".repeat(250 << 10));
            for _ in 0..30 {
                ctx.snapshot("big", data.clone())?;
            }
            // a small message still fits
            ctx.log(LogLevel::Info, "small")?;
            Ok(())
        });
        let lines = without_health(&output);
        assert_eq!(lines.len(), 1 + 16 + 1 + 1);
        assert_eq!(lines[17]["text"], "small");
        assert!(
            lines[18]["text"]
                .as_str()
                .unwrap()
                .starts_with("14 messages")
        );
    }

    #[test]
    fn a_failed_start_writes_nothing_and_closes_the_output() {
        let output = Buf::default();
        let mut kept = None;
        let code = run(output.clone(), |ctx| {
            ctx.log(LogLevel::Error, "why it failed")?;
            kept = Some(ctx.shared());
            Err(Error::failed("no device"))
        });
        assert_eq!(code, 1);
        let late = kept.unwrap().log(LogLevel::Info, "late").unwrap_err();
        assert_eq!(late.kind(), ErrorKind::NotConnected);
        assert!(output.lines().is_empty());
    }

    #[test]
    fn a_panicking_start_writes_nothing_and_closes_the_output() {
        let output = Buf::default();
        let mut kept = None;
        let result = catch_unwind(AssertUnwindSafe(|| {
            run(output.clone(), |ctx| {
                ctx.log(LogLevel::Error, "last words")?;
                kept = Some(ctx.shared());
                panic!("start panics");
            })
        }));
        assert!(result.is_err());
        let late = kept.unwrap().log(LogLevel::Info, "late").unwrap_err();
        assert_eq!(late.kind(), ErrorKind::NotConnected);
        assert!(output.lines().is_empty());
    }
}
