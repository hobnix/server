//! The 0.13 API through the deprecated re-export, against the wire format of ADR 0010 and 0011, with in-memory pipes (no processes).
//! This file is the test of 0.13; new are this comment, the attribute below and the `#[cfg(test)]` module around the code. The code that
//! calls the 0.13 API is unchanged.
#![expect(deprecated, reason = "the 0.13 entry points it calls are deprecated")]

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};
    use std::sync::{Arc, Mutex};

    use hobnix_ext_sdk::command::{self, ErrorCode, Failure, Success};
    use hobnix_ext_sdk::service::{self, EventRow, Health, Init, Service};
    use hobnix_ext_sdk::testing::{Call, FakeCtx};
    use hobnix_ext_sdk::{Ctx, Event, LogLevel};
    use serde_json::{Value, json};

    #[derive(Clone, Default)]
    struct Buf(Arc<Mutex<Vec<u8>>>);
    impl Write for Buf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl Buf {
        fn lines(&self) -> Vec<Value> {
            let s = String::from_utf8(self.0.lock().unwrap().clone()).unwrap();
            s.lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect()
        }
    }

    fn request(command: &[&str], argv: &[&str]) -> String {
        format!(
            "{}\n",
            json!({"v":1,"type":"request","id":"0123456789abcdef","command":command,"argv":argv,"lang":"de","caller":"web","timeout_ms":30000})
        )
    }

    fn call<F>(input: &str, h: F) -> (u8, Vec<Value>)
    where
        F: FnOnce(&command::Request, &dyn Ctx) -> Result<Success, Failure>,
    {
        let buf = Buf::default();
        let code = command::run_with(&mut Cursor::new(input.as_bytes().to_vec()), buf.clone(), h);
        (code, buf.lines())
    }

    #[test]
    fn command_ok_with_messages_then_one_result() {
        let (code, out) = call(&request(&["echo"], &["a", "b c"]), |req, ctx| {
            assert_eq!(req.argv, ["a", "b c"]);
            assert_eq!(req.words(), ["echo"]);
            ctx.progress(Some(7.0), "x").unwrap(); // clamped
            ctx.log(LogLevel::Warn, "hi").unwrap();
            ctx.event(&Event::new("pkg.demo.said", "s").text("t"))
                .unwrap();
            Ok(Success::data(json!({"n": 1})).with_text("done"))
        });
        assert_eq!(code, 0);
        let types: Vec<_> = out.iter().map(|m| m["type"].as_str().unwrap()).collect();
        assert_eq!(types, ["progress", "log", "event", "result"]);
        assert!(out.iter().all(|m| m["v"] == 1));
        assert_eq!(out[0]["fraction"], 1.0);
        assert_eq!(
            out[3],
            json!({"v":1,"type":"result","ok":true,"data":{"n":1},"text":"done"})
        );
    }

    #[test]
    fn command_failure_has_error_and_exit_1_and_no_data() {
        let (code, out) = call(&request(&["x"], &[]), |_, _| {
            Err(Failure::not_found("no\nsuch thing"))
        });
        assert_eq!(code, 1);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["ok"], false);
        assert_eq!(
            out[0]["error"],
            json!({"code":"not_found","message":"no such thing"})
        );
        assert!(out[0].get("data").is_none());
        let req = request(&["x"], &[]);
        let (_, out) = call(&req, |_, _| Err(Failure::new(ErrorCode::Cancelled, "stop")));
        assert_eq!(out[0]["error"]["code"], "cancelled");
    }

    #[test]
    fn command_unknown_version_answers_unsupported_version() {
        let line = format!("{}\n", json!({"v":2,"type":"request"}));
        let (code, out) = call(&line, |_, _| panic!("must not run"));
        assert_eq!(code, 1);
        let want = json!({
            "code": "unsupported_version",
            "message": "this extension speaks protocol version 1 only",
            "supported": [1]
        });
        assert_eq!(out[0]["error"], want);
    }

    #[test]
    fn command_bad_input_is_bad_request() {
        let wrong_type = "{\"v\":1,\"type\":\"progress\"}\n";
        let missing_fields = "{\"v\":1,\"type\":\"request\",\"id\":\"x\"}\n";
        for input in ["", "not json\n", wrong_type, missing_fields] {
            let (code, out) = call(input, |_, _| panic!("must not run"));
            assert_eq!(code, 1, "{input:?}");
            assert_eq!(out.len(), 1);
            assert_eq!(out[0]["error"]["code"], "bad_request", "{input:?}");
        }
    }

    #[test]
    fn command_panic_is_failed() {
        let (code, out) = call(&request(&["x"], &[]), |_, _| panic!("boom"));
        assert_eq!(code, 1);
        assert_eq!(out[0]["error"]["code"], "failed");
    }

    #[test]
    fn command_rejects_bad_kind_and_oversize_result() {
        let (_, out) = call(&request(&["x"], &[]), |_, ctx| {
            assert!(ctx.event(&Event::new("core.disk", "x")).is_err());
            assert!(ctx.event(&Event::new("pkg.demo.Said", "x")).is_err());
            Ok(Success::text("x".repeat(2 << 20)))
        });
        // the too-long result is replaced by a failure the core can read
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["ok"], false);
    }

    #[test]
    fn log_and_progress_text_are_cut_to_schema_limits() {
        let (_, out) = call(&request(&["x"], &[]), |_, ctx| {
            ctx.log(LogLevel::Info, &"é".repeat(2000)).unwrap();
            ctx.progress(None, &"p".repeat(500)).unwrap();
            Ok(Success::default())
        });
        assert_eq!(out[0]["text"].as_str().unwrap().chars().count(), 1000);
        assert_eq!(out[1]["text"].as_str().unwrap().chars().count(), 200);
        assert!(out[1].get("fraction").is_none());
        assert_eq!(out[2], json!({"v":1,"type":"result","ok":true}));
    }

    // ---- service ----

    #[derive(Default)]
    struct Probe {
        events: Vec<u64>,
        started: Option<String>,
    }
    impl Service for Probe {
        fn start(&mut self, init: &Init, _: &dyn Ctx) -> Result<(), String> {
            self.started = Some(format!("{} {:?}", init.name, init.subscribe));
            Ok(())
        }
        fn on_event(&mut self, ev: &EventRow, ctx: &dyn Ctx) -> Result<(), String> {
            self.events.push(ev.id);
            if ev.subject == "bad" {
                return Err("cannot".into());
            }
            ctx.emit(&Event::new("pkg.demo.seen", &ev.subject))
                .map_err(|e| e.to_string())
        }
        fn tick(&mut self, ctx: &dyn Ctx) -> Health {
            ctx.snapshot("t", json!({"n": self.events.len()})).unwrap();
            Health::ok()
        }
    }

    fn svc_input(lines: &[Value]) -> Cursor<Vec<u8>> {
        let mut s = String::new();
        for l in lines {
            s.push_str(&l.to_string());
            s.push('\n');
        }
        Cursor::new(s.into_bytes())
    }

    fn init() -> Value {
        json!({"v":1,"type":"init","name":"demo","lang":"en","subscribe":["job.*"],"health_interval":30})
    }
    fn ev(id: u64, subject: &str) -> Value {
        json!({"v":1,"type":"event","id":id,"time":1,"source":"s","kind":"job.done","subject":subject,"level":"info","text":null,"payload":null})
    }

    #[test]
    fn service_ready_first_acks_handled_events_and_stops_on_shutdown() {
        let buf = Buf::default();
        let input = svc_input(&[
            init(),
            ev(1, "a"),
            json!({"v":1,"type":"future-thing"}), // unknown type: ignored
            ev(2, "bad"),                         // handler fails: no ack
            ev(3, "c"),
            json!({"v":1,"type":"shutdown","grace_ms":1000}),
        ]);
        let code = service::run_with(input, buf.clone(), Probe::default());
        assert_eq!(code, 0);
        let out = buf.lines();
        assert_eq!(out[0], json!({"v":1,"type":"ready"}));
        assert!(out.iter().all(|m| m["v"] == 1));
        let acks: Vec<u64> = out
            .iter()
            .filter(|m| m["type"] == "ack")
            .map(|m| m["id"].as_u64().unwrap())
            .collect();
        assert_eq!(acks, [1, 3]);
        assert!(
            out.iter()
                .any(|m| m["type"] == "log" && m["level"] == "error")
        );
        assert!(
            out.iter()
                .any(|m| m["type"] == "emit" && m["kind"] == "pkg.demo.seen")
        );
        assert!(out.iter().any(|m| m["type"] == "health" && m["ok"] == true));
        assert!(
            out.iter()
                .any(|m| m["type"] == "snapshot" && m["topic"] == "t")
        );
    }

    #[test]
    fn service_exits_0_when_stdin_closes_and_1_on_protocol_error() {
        let buf = Buf::default();
        assert_eq!(
            service::run_with(svc_input(&[init()]), buf.clone(), Probe::default()),
            0
        );
        let buf = Buf::default();
        let mut bad = svc_input(&[init()]).into_inner();
        bad.extend_from_slice(b"garbage\n");
        assert_eq!(
            service::run_with(Cursor::new(bad), buf.clone(), Probe::default()),
            1
        );
    }

    #[test]
    fn service_writes_nothing_when_init_is_wrong() {
        let wrong_version = json!({"v": 2, "type": "init"});
        for input in [
            svc_input(&[]),
            svc_input(&[ev(1, "a")]),
            svc_input(&[wrong_version]),
        ] {
            let buf = Buf::default();
            assert_eq!(service::run_with(input, buf.clone(), Probe::default()), 1);
            assert!(buf.lines().is_empty(), "only `ready` may come first");
        }
    }

    #[test]
    fn service_degraded_health_and_topic_checks() {
        struct Sick;
        impl Service for Sick {
            fn tick(&mut self, ctx: &dyn Ctx) -> Health {
                assert!(ctx.snapshot("Bad Topic", json!(1)).is_err());
                assert!(ctx.snapshot("big", json!("x".repeat(300 << 10))).is_err());
                Health::degraded("device gone")
            }
        }
        let buf = Buf::default();
        service::run_with(svc_input(&[init()]), buf.clone(), Sick);
        let h = buf
            .lines()
            .into_iter()
            .find(|m| m["type"] == "health")
            .unwrap();
        assert_eq!(
            h,
            json!({"v":1,"type":"health","ok":false,"text":"device gone"})
        );
    }

    #[test]
    fn service_rollup_message_and_credential() {
        struct Roll;
        impl Service for Roll {
            fn tick(&mut self, ctx: &dyn Ctx) -> Health {
                ctx.rollup("pkg.t.watch", "anna", 2.0, 90.5).unwrap();
                assert!(ctx.rollup("pkg.t.watch", "a b", 1.0, 0.0).is_err());
                assert!(ctx.rollup("pkg.t.watch", "-time", 1.0, 0.0).is_err());
                Health::ok()
            }
        }
        let buf = Buf::default();
        service::run_with(svc_input(&[init()]), buf.clone(), Roll);
        let lines = buf.lines();
        let m = lines
            .iter()
            .find(|m| m["type"] == "rollup")
            .expect("a rollup line");
        assert_eq!(m["kind"], "pkg.t.watch");
        assert_eq!(m["user"], "anna");
        assert_eq!(m["n"], 2.0);
        assert_eq!(m["sum"], 90.5);
        assert_eq!(m["v"], 1);
        assert!(service::credential_for("Bad Name", "jellyfin").is_none());
        assert!(service::credential_for("media", "../x").is_none());
        assert!(service::credential_for("media", "").is_none());
        // the old one-name form is tested until it goes
        assert!(service::credential("Bad Name").is_none());
    }

    // ---- Ctx as a trait ----

    fn greet(req: &command::Request, ctx: &dyn Ctx) -> Result<Success, Failure> {
        let failed = |e: std::io::Error| Failure::failed(e.to_string());
        ctx.progress(Some(0.5), "half").map_err(failed)?;
        ctx.emit(&Event::new("pkg.demo.greeted", req.argv.first().unwrap()))
            .map_err(failed)?;
        Ok(Success::text("done"))
    }

    #[test]
    fn a_handler_runs_against_the_fake_and_the_wire_alike() {
        let req = command::Request {
            id: "0123456789abcdef".into(),
            command: vec!["greet".into()],
            argv: vec!["Ada".into()],
            lang: command::Lang::En,
            caller: command::Caller::Cli,
            timeout_ms: 1000,
        };
        let fake = FakeCtx::new();
        assert_eq!(greet(&req, &fake).unwrap(), Success::text("done"));
        assert_eq!(
            fake.calls(),
            [
                Call::Progress(Some(0.5), "half".into()),
                Call::Emit(Event::new("pkg.demo.greeted", "Ada"))
            ]
        );
        let (code, out) = call(&request(&["greet"], &["Ada"]), greet);
        assert_eq!(code, 0);
        let types: Vec<_> = out.iter().map(|m| m["type"].as_str().unwrap()).collect();
        assert_eq!(types, ["progress", "event", "result"]);
    }
}
