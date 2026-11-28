//! Pairing of remote shares by code (docs/PLAN-remote-shares.md D3 to D6): the code, its derived id and key, the box, the code store and the rate
//! limit. The clock and the random source are parameters, so the tests need no sleeping and no real randomness. No terminal output.

mod caller;
mod code;
mod doors;
mod encoding;
mod inner;
mod keys;
mod store;

pub use caller::{claim_request, open_claim, push_body};
pub use code::{ALPHABET, CODE_LEN, format_code, new_code, normalize};
pub use doors::{Host, Refusal, Reply, accept, claim};
pub use encoding::{b64, fingerprint, unb64};
pub use inner::{Inner, valid_host, valid_login, valid_name, valid_share};
pub use keys::{Keys, derive, open, open_answer, seal, seal_answer};
pub use store::{
    BURN_FAILS, BURN_WINDOW, DEFAULT_MINUTES, Entry, Kind, Listed, MAX_MINUTES, MAX_OPEN, Made,
    RATE_FAILS, RATE_WINDOW, Store, Taken, default_store_path,
};

use crate::{Error, Result};
use std::fs::File;
use std::io::Read;

/// Seconds since the epoch; a parameter so tests do not sleep.
pub trait Clock {
    fn now(&self) -> u64;
}

#[derive(Debug)]
pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs())
    }
}

/// Where random bytes come from; a parameter so tests are repeatable.
pub trait Random {
    fn fill(&mut self, buf: &mut [u8]) -> Result<()>;
}

#[derive(Debug)]
pub struct OsRandom;
impl Random for OsRandom {
    fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
        File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(buf))
            .map_err(|_| Error::Failed("no random source".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::encoding::{b64_with, hex, unhex};
    use super::store::ct_eq;
    use super::*;
    use crate::Secret;
    use hkdf::Hkdf;
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::cell::{Cell, RefCell};
    use std::path::PathBuf;

    struct FakeClock(Cell<u64>);
    impl Clock for FakeClock {
        fn now(&self) -> u64 {
            self.0.get()
        }
    }

    /// Counts up: repeatable "random" bytes.
    struct Counter(u8);
    impl Random for Counter {
        fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
            for b in buf.iter_mut() {
                self.0 = self.0.wrapping_mul(31).wrapping_add(7);
                *b = self.0;
            }
            Ok(())
        }
    }

    struct FakeHost {
        events: RefCell<Vec<(String, String)>>,
        taken: bool,
        down: bool,
    }
    impl FakeHost {
        fn new() -> FakeHost {
            FakeHost {
                events: RefCell::new(vec![]),
                taken: false,
                down: false,
            }
        }
        fn kinds(&self) -> Vec<String> {
            self.events.borrow().iter().map(|e| e.0.clone()).collect()
        }
    }
    impl Host for FakeHost {
        fn grant(
            &self,
            server: &str,
            share: &str,
            _fp: &str,
            _bound: bool,
        ) -> std::result::Result<Inner, Refusal> {
            if self.taken {
                return Err(Refusal::Unknown);
            }
            if self.down {
                return Err(Refusal::Unavailable);
            }
            Ok(Inner {
                server: "alpha".into(),
                host: "alpha.local".into(),
                share: share.into(),
                login: format!("remote-{server}"),
                domain: "HOME".into(),
                password: Secret::new("pw-secret-123"),
                hostkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA".into(),
            })
        }
        fn mount(&self, inner: &Inner) -> std::result::Result<(), Refusal> {
            if self.down {
                Err(Refusal::Unavailable)
            } else {
                assert_eq!(inner.password.expose(), "pw-secret-123");
                Ok(())
            }
        }
        fn event(&self, kind: &str, subject: &str, _level: &str, payload: &Value) {
            let t = payload.to_string();
            assert!(!t.contains("pw-secret"), "no secret in an event");
            self.events.borrow_mut().push((kind.into(), subject.into()));
        }
    }

    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hobnix-pair-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d.join("codes.json")
    }

    #[test]
    fn code_alphabet_and_shape() {
        let c = new_code(&mut Counter(1)).unwrap();
        assert_eq!(c.len(), 19);
        assert!(normalize(&c).is_some());
        assert_eq!(format_code(&normalize(&c).unwrap()), c);
        assert_eq!(
            normalize("abcd efgh-jklm npqr"),
            Some("ABCDEFGHJKLMNPQR".into())
        );
        assert_eq!(normalize("ABCD-EFGH-JKLM-NPQ0"), None); // 0 is not in the alphabet
        assert_eq!(normalize("ABCD"), None);
        assert_eq!(normalize(&"A".repeat(100)), None);
    }

    #[test]
    fn derive_is_stable_and_apart() {
        let a = derive("ABCDEFGHJKLMNPQR").unwrap();
        let b = derive("ABCDEFGHJKLMNPQR").unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(a.id.len(), 64);
        assert_ne!(hex(&a.key), a.id);
        assert_ne!(derive("ABCDEFGHJKLMNPQS").unwrap().id, a.id);
    }

    #[test]
    fn hkdf_known_answer() {
        // RFC 5869 test case 3 (no salt, no info) pins the HKDF-SHA256 construction used here
        let ikm = [0x0bu8; 22];
        let h = Hkdf::<Sha256>::new(None, &ikm);
        let mut okm = [0u8; 42];
        h.expand(b"", &mut okm).unwrap();
        assert_eq!(
            hex(&okm),
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
        );
    }

    #[test]
    fn base64_roundtrip_and_fingerprint() {
        for n in 0..9u8 {
            let v: Vec<u8> = (0..n).map(|x| x.wrapping_mul(37)).collect();
            assert_eq!(unb64(&b64(&v)).unwrap(), v);
        }
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        let fp = fingerprint(KEY).unwrap();
        assert!(fp.starts_with("SHA256:") && !fp.contains('='));
        assert!(fingerprint("nonsense").is_none());
    }

    #[test]
    fn box_opens_only_with_key_and_same_aad() {
        let k = derive("ABCDEFGHJKLMNPQR").unwrap();
        let ans = seal_answer(&k, &mut Counter(3), b"request", b"{\"a\":1}").unwrap();
        assert_eq!(open_answer(&k, b"request", &ans).unwrap(), b"{\"a\":1}");
        assert!(open_answer(&k, b"other", &ans).is_none());
        assert!(open_answer(&derive("ABCDEFGHJKLMNPQS").unwrap(), b"request", &ans).is_none());
        assert!(!ans.to_string().contains("\"a\":1"));
    }

    #[test]
    fn debug_does_not_show_the_derived_key() {
        let clock = FakeClock(Cell::new(1000));
        let st = Store::new(tmp("debug"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(1))
            .unwrap();
        let keys = derive(&normalize(m.code.expose()).unwrap()).unwrap();
        let key = hex(&keys.key);
        let taken = st.take(Kind::Offer, &keys.id, "10.0.0.2").unwrap();
        let Taken::Found(entry) = &taken else {
            panic!("the code was not found");
        };
        assert_eq!(entry.key, key);
        let shown = format!("{keys:?}");
        assert!(!shown.contains(&key) && shown.contains(&keys.id), "{shown}");
        for shown in [format!("{entry:?}"), format!("{taken:?}")] {
            assert!(!shown.contains(&key), "{shown}");
            assert!(
                shown.contains(&keys.id) && shown.contains("media"),
                "{shown}"
            );
        }
    }

    #[test]
    fn expiry_one_use_and_list() {
        let clock = FakeClock(Cell::new(1000));
        let st = Store::new(tmp("expiry"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(1))
            .unwrap();
        let id = derive(&normalize(m.code.expose()).unwrap()).unwrap().id;
        let l = st.list().unwrap();
        assert_eq!(
            (l.len(), l[0].expires_in, l[0].share.as_str()),
            (1, 600, "media")
        );
        // the file holds only derived values
        let text = std::fs::read_to_string(&st.path).unwrap();
        assert!(
            !text.contains(m.code.expose()) && !text.contains(&normalize(m.code.expose()).unwrap())
        );
        assert!(matches!(
            st.take(Kind::Offer, &id, "10.0.0.2").unwrap(),
            Taken::Found(_)
        ));
        assert!(matches!(
            st.take(Kind::Offer, &id, "10.0.0.2").unwrap(),
            Taken::Unknown { .. }
        ));
        let m = st
            .make(Kind::Offer, "media", "-", 1, &mut Counter(9))
            .unwrap();
        let id2 = derive(&normalize(m.code.expose()).unwrap()).unwrap().id;
        clock.0.set(1000 + 61);
        assert!(matches!(
            st.take(Kind::Offer, &id2, "10.0.0.2").unwrap(),
            Taken::Unknown { .. }
        ));
        assert!(st.list().unwrap().is_empty());
    }

    #[test]
    fn kind_must_match_and_limits() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("kind"), &clock);
        let mut rng = Counter(5);
        let m = st.make(Kind::Receive, "-", "-", 5, &mut rng).unwrap();
        let id = derive(&normalize(m.code.expose()).unwrap()).unwrap().id;
        assert!(matches!(
            st.take(Kind::Offer, &id, "a").unwrap(),
            Taken::Unknown { .. }
        ));
        assert!(matches!(
            st.take(Kind::Receive, &id, "a").unwrap(),
            Taken::Found(_)
        ));
        for _ in 0..MAX_OPEN {
            st.make(Kind::Offer, "s", "-", 5, &mut rng).unwrap();
        }
        assert!(matches!(
            st.make(Kind::Offer, "s", "-", 5, &mut rng),
            Err(Error::Refused(_))
        ));
        assert!(matches!(
            st.make(Kind::Offer, "s", "-", 61, &mut rng),
            Err(Error::Refused(_))
        ));
        assert_eq!(st.cancel_all().unwrap(), MAX_OPEN);
    }

    #[test]
    fn rate_limit_per_source_then_window_passes() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("rate"), &clock);
        for _ in 0..RATE_FAILS {
            assert_eq!(
                st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
                Taken::Unknown { burned: false }
            );
        }
        assert_eq!(
            st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
            Taken::RateLimited
        );
        // another source is not limited
        assert_eq!(
            st.take(Kind::Offer, "x", "2.2.2.2").unwrap(),
            Taken::Unknown { burned: false }
        );
        clock.0.set(RATE_WINDOW + 1);
        assert_eq!(
            st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
            Taken::Unknown { burned: false }
        );
    }

    #[test]
    fn twenty_failures_burn_every_code() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("burn"), &clock);
        let mut rng = Counter(2);
        st.make(Kind::Offer, "s", "-", 10, &mut rng).unwrap();
        let mut burned = false;
        for i in 0..BURN_FAILS {
            clock.0.set((i as u64) * 20); // 20 s apart: no single source reaches 5 in a minute
            let src = format!("10.0.0.{i}");
            burned = matches!(
                st.take(Kind::Offer, "x", &src).unwrap(),
                Taken::Unknown { burned: true }
            );
        }
        assert!(burned);
        assert!(st.list().unwrap().is_empty());
    }

    fn offer_flow(name: &str, host: &FakeHost, bound: &str) -> (Reply, String, Vec<u8>) {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp(name), &clock);
        let m = st
            .make(Kind::Offer, "media", bound, 10, &mut Counter(4))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let req = claim_request(&norm, "beta", KEY).unwrap();
        let r = claim(&st, host, &mut Counter(8), req.as_bytes(), "10.0.0.5");
        (r, norm, req.into_bytes())
    }

    #[test]
    fn claim_end_to_end() {
        let host = FakeHost::new();
        let (r, norm, req) = offer_flow("f1", &host, "-");
        assert!(r.error.is_none());
        let inner = open_claim(&norm, &req, &r.body).unwrap();
        assert_eq!(inner["login"], "remote-beta");
        assert_eq!(inner["password"], "pw-secret-123");
        assert!(!r.body.to_string().contains("pw-secret"));
        assert_eq!(host.kinds(), vec!["remote.claimed"]);
        // a different request body does not open the box (the body is associated data)
        assert!(open_claim(&norm, b"{}", &r.body).is_none());
    }

    #[test]
    fn claim_refusals_have_one_shape() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("refuse"), &clock);
        let host = FakeHost::new();
        let bad = claim_request("ABCDEFGHJKLMNPQR", "beta", KEY).unwrap();
        let r = claim(&st, &host, &mut Counter(1), bad.as_bytes(), "10.0.0.5");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let r = claim(&st, &host, &mut Counter(1), b"not json", "10.0.0.5");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let taken = FakeHost {
            taken: true,
            ..FakeHost::new()
        };
        let (r, _, _) = offer_flow("f2", &taken, "-");
        assert_eq!(r.error, Some(Refusal::Unknown));
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let down = FakeHost {
            down: true,
            ..FakeHost::new()
        };
        let (r, _, _) = offer_flow("f3", &down, "-");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unavailable"}));
    }

    #[test]
    fn claim_is_one_use_even_when_the_account_step_fails() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("once"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(4))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let req = claim_request(&norm, "beta", KEY).unwrap();
        let down = FakeHost {
            down: true,
            ..FakeHost::new()
        };
        assert_eq!(
            claim(&st, &down, &mut Counter(1), req.as_bytes(), "s").error,
            Some(Refusal::Unavailable)
        );
        let ok = FakeHost::new();
        assert_eq!(
            claim(&st, &ok, &mut Counter(1), req.as_bytes(), "s").error,
            Some(Refusal::Unknown)
        );
    }

    #[test]
    fn rate_limited_claim_answers_429_shape_and_events() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("rate429"), &clock);
        let host = FakeHost::new();
        let bad = claim_request("ABCDEFGHJKLMNPQR", "beta", KEY).unwrap();
        let mut last = None;
        for _ in 0..=RATE_FAILS {
            last = Some(claim(
                &st,
                &host,
                &mut Counter(1),
                bad.as_bytes(),
                "10.0.0.9",
            ));
        }
        assert_eq!(last.unwrap().error, Some(Refusal::Rate));
        assert!(host.kinds().iter().all(|k| k == "remote.claim.refused"));
    }

    #[test]
    fn push_end_to_end_and_wrong_code() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("push"), &clock);
        let m = st
            .make(Kind::Receive, "-", "-", 10, &mut Counter(6))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let inner = Inner {
            server: "alpha".into(),
            host: "alpha.local".into(),
            share: "media".into(),
            login: "remote-beta".into(),
            domain: "HOME".into(),
            password: Secret::new("pw-secret-123"),
            hostkey: String::new(),
        };
        let body = push_body(&norm, &inner, &mut Counter(2)).unwrap();
        assert!(!body.contains("pw-secret"));
        let host = FakeHost::new();
        // a push sealed with another code is refused, and it uses up B's code only by id (unknown id: a failure)
        let other = push_body("ABCDEFGHJKLMNPQR", &inner, &mut Counter(2)).unwrap();
        assert_eq!(
            accept(&st, &host, other.as_bytes(), "10.0.0.7").error,
            Some(Refusal::Unknown)
        );
        let r = accept(&st, &host, body.as_bytes(), "10.0.0.7");
        assert!(r.error.is_none());
        assert_eq!(
            accept(&st, &host, body.as_bytes(), "10.0.0.7").error,
            Some(Refusal::Unknown)
        );
    }

    #[test]
    fn constant_time_compare() {
        assert!(ct_eq(b"abc", b"abc"));
        assert!(!ct_eq(b"abc", b"abd"));
        assert!(!ct_eq(b"abc", b"abcd"));
        assert!(ct_eq(b"", b""));
        assert!(!ct_eq(b"", b"a") && !ct_eq(b"a", b""));
    }

    #[test]
    fn lengths_that_differ_by_256_are_not_equal() {
        assert!(!ct_eq(b"", &[0u8; 256]));
        let id = [b'a'; 64];
        let mut longer = id.to_vec();
        longer.resize(320, b'b');
        assert!(!ct_eq(&id, &longer) && !ct_eq(&longer, &id));
    }

    // ------------------------------------------------------------ fixed bytes: both sides of a pairing must keep agreeing

    /// Gives the byte values in order, 0 to 255 and round again.
    struct EveryByte(u8);
    impl Random for EveryByte {
        fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
            for b in buf.iter_mut() {
                *b = self.0;
                self.0 = self.0.wrapping_add(1);
            }
            Ok(())
        }
    }

    const FIXED_CODE: &str = "ABCDEFGHJKLMNPQR";
    const FIXED_ID: &str = "c361cfe86e4334a632f730f999a0e54a7ea292c89817aebfbd0bfecd94b34aba";

    #[test]
    fn every_random_byte_maps_to_a_fixed_letter() {
        assert_eq!(new_code(&mut Counter(1)).unwrap(), "GBGB-GBGB-GBGB-GBGB");
        let mut rng = EveryByte(0);
        for _ in 0..8 {
            assert_eq!(new_code(&mut rng).unwrap(), "ABCD-EFGH-JKLM-NPQR");
            assert_eq!(new_code(&mut rng).unwrap(), "STUV-WXYZ-2345-6789");
        }
    }

    #[test]
    fn derived_values_and_boxes_have_fixed_bytes() {
        let keys = derive(FIXED_CODE).unwrap();
        assert_eq!(keys.id, FIXED_ID);
        assert_eq!(
            hex(&keys.key),
            "89268a6620ce1063d07cd77223673a44d31e7a45b3e1373e756d2438a9c3ccc6"
        );
        assert_eq!(
            hex(&seal(&keys, &[7u8; 12], b"aad", b"plain text").unwrap()),
            "48e291c70d1afb85782920621ea8e260660547305cd05b9dad48"
        );
        let answer = seal_answer(&keys, &mut Counter(3), b"request", b"{\"a\":1}").unwrap();
        assert_eq!(
            answer.to_string(),
            r#"{"v":1,"nonce":"ZCNEQyRjBIPko8TD","box":"w2+GPH2FhVCaMnmYkcY63f1lQtfnlZg="}"#
        );
    }

    #[test]
    fn request_push_and_fingerprint_have_fixed_text() {
        let inner = Inner {
            server: "alpha".into(),
            host: "alpha.local".into(),
            share: "media".into(),
            login: "remote-beta".into(),
            domain: "HOME".into(),
            password: Secret::new("pw-secret-123"),
            hostkey: String::new(),
        };
        let sealed = "8uxCtxEBpZVlNEEAS9Ms1QUYvGn3JxKy0LNxc0ojT0aWorIQFZyAJunqVfFOxTMgKxgPTMVB6+oJ1lKyD4TSi2c5tkebpb8eHiKmRHOT4YKPNWxDvpmUH8veV+9hLDBNTlxMZiFNgvFwXAxqDbQbIKV6K/cUzm6wJ4zdn+mozjZcOgIcduATbUsry17TuA6SWZFf2Dw=";
        assert_eq!(
            push_body(FIXED_CODE, &inner, &mut Counter(2)).unwrap(),
            format!(r#"{{"v":1,"nonce":"RWLlwoUiJYLF4mVC","box":"{sealed}","id":"{FIXED_ID}"}}"#)
        );
        assert_eq!(
            claim_request(FIXED_CODE, "beta", KEY).unwrap(),
            format!(r#"{{"v":1,"id":"{FIXED_ID}","name":"beta","hostkey":"{KEY}"}}"#)
        );
        assert_eq!(
            fingerprint(KEY).unwrap(),
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
        );
    }

    #[test]
    fn base64_has_fixed_text() {
        let data = [0xfbu8, 0xff, 0xbf, 0x00, 0x10, 0x83, 0xfe];
        let expected = [
            ("", ""),
            ("+w==", "+w"),
            ("+/8=", "+/8"),
            ("+/+/", "+/+/"),
            ("+/+/AA==", "+/+/AA"),
            ("+/+/ABA=", "+/+/ABA"),
            ("+/+/ABCD", "+/+/ABCD"),
            ("+/+/ABCD/g==", "+/+/ABCD/g"),
        ];
        for (length, (padded, bare)) in expected.into_iter().enumerate() {
            assert_eq!(b64(&data[..length]), padded);
            assert_eq!(b64_with(&data[..length], false), bare);
        }
        let every: Vec<u8> = (0..=255).collect();
        assert_eq!(unb64(&b64(&every)).unwrap(), every);
        assert_eq!(
            hex(&Sha256::digest(b64(&every).as_bytes())),
            "ab7727e21f4bbba6508dd72804d97435a78eb44a1e277af1c0f65a8522de382e"
        );
    }

    #[test]
    fn decoding_accepts_and_refuses_the_same_text() {
        let base64: [(&str, Option<&[u8]>); 16] = [
            ("", Some(b"")),
            ("=", Some(b"")),
            ("====", Some(b"")),
            ("Z", Some(b"")),
            ("Zg", Some(b"f")),
            ("Zg==", Some(b"f")),
            ("Zg=====", Some(b"f")),
            ("Zh==", Some(b"f")),
            ("Zm9", Some(b"fo")),
            ("Zm9vY", Some(b"foo")),
            ("+/+/", Some(&[251, 255, 191])),
            ("Zm=9v", None),
            ("Zm9v!", None),
            ("Zm 9v", None),
            ("-_", None),
            ("\u{e4}\u{e4}", None),
        ];
        for (text, bytes) in base64 {
            assert_eq!(unb64(text).as_deref(), bytes, "{text:?}");
        }
        // u8::from_str_radix takes a leading "+"
        let hexadecimal: [(&str, Option<&[u8]>); 14] = [
            ("", Some(b"")),
            ("00", Some(&[0])),
            ("0aFf", Some(&[10, 255])),
            ("+f", Some(&[15])),
            ("0", None),
            ("-1", None),
            ("f+", None),
            (" 1", None),
            ("zz", None),
            ("abc", None),
            ("0g", None),
            ("++", None),
            ("\u{e4}\u{e4}", None),
            ("a\u{e4}", None),
        ];
        for (text, bytes) in hexadecimal {
            assert_eq!(unhex(text).as_deref(), bytes, "{text:?}");
        }
    }

    #[test]
    fn names_are_checked() {
        assert!(valid_name("beta") && valid_name("a-1"));
        assert!(
            !valid_name("Beta")
                && !valid_name("-a")
                && !valid_name(&"a".repeat(21))
                && !valid_name("a_b")
        );
        assert!(valid_share("My.Share_1") && !valid_share("a/b"));
        assert!(valid_host("alpha.local:8480") && !valid_host("a b"));
    }
}
