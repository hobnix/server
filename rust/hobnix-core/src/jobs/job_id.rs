//! Job ids: `<date>-<time>-<slug>-<four letters>`. They become file names, so an id from outside is checked.

use super::timestamp::format_id_time;
use std::fs;
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

/// `[0-9]{8}-[0-9]{6}-[A-Za-z0-9-]+-[a-z]{4}` as a full match.
pub fn valid_id(id: &str) -> bool {
    id_parts(id.as_bytes()).is_some_and(|[date, time, slug, suffix]| {
        date.iter().all(u8::is_ascii_digit)
            && time.iter().all(u8::is_ascii_digit)
            && !slug.is_empty()
            && slug
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
            && suffix.iter().all(u8::is_ascii_lowercase)
    })
}

/// Date, time, slug and suffix, cut by length from both ends; None when a `-` is not where it belongs.
fn id_parts(id: &[u8]) -> Option<[&[u8]; 4]> {
    let (date, rest) = id.split_at_checked(8)?;
    let (time, rest) = rest.strip_prefix(b"-")?.split_at_checked(6)?;
    let rest = rest.strip_prefix(b"-")?;
    let (rest, suffix) = rest.split_at_checked(rest.len().checked_sub(4)?)?;
    let slug = rest.strip_suffix(b"-")?;
    Some([date, time, slug, suffix])
}

/// The slug as it goes into an id: every run of other characters is one `-`, none at the ends, never empty.
pub(super) fn clean_slug(slug: &str) -> String {
    let mut clean = String::new();
    let mut in_run = false;
    for character in slug.chars() {
        if character.is_ascii_alphanumeric() {
            clean.push(character);
            in_run = false;
        } else if !in_run {
            clean.push('-');
            in_run = true;
        }
    }
    match clean.trim_matches('-') {
        "" => "job".to_string(),
        trimmed => trimmed.to_string(),
    }
}

/// A new id for a job queued at `queued` (seconds since the epoch) with a slug from `clean_slug`.
pub(super) fn new_id(queued: i64, slug: &str) -> String {
    format!("{}-{}-{}", format_id_time(queued), slug, random_suffix())
}

/// Four random lower-case letters: /dev/urandom, else the clock.
fn random_suffix() -> String {
    let mut letters = urandom_letters();
    add_clock_letters(&mut letters);
    letters
}

/// Up to four letters from /dev/urandom; none when it cannot be read.
fn urandom_letters() -> String {
    let mut bytes = [0u8; 32];
    let filled = fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut bytes));
    if filled.is_err() {
        return String::new();
    }
    bytes
        .iter()
        // 208 = 8 * 26: drop the bytes that would make some letters likelier
        .filter(|byte| **byte < 208)
        .take(4)
        .map(|byte| char::from(b'a' + byte % 26))
        .collect()
}

/// Fill up to four letters with a xorshift generator seeded by the clock and the process id.
fn add_clock_letters(letters: &mut String) {
    if letters.len() >= 4 {
        return;
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        // only the low 64 bits: they are the ones that change
        .and_then(|duration| u64::try_from(duration.as_nanos() & u128::from(u64::MAX)).ok())
        .unwrap_or(1);
    let mut state = nanos ^ (u64::from(std::process::id()) << 32) | 1;
    while letters.len() < 4 {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let offset = u8::try_from(state % 26).unwrap_or(0);
        letters.push(char::from(b'a' + offset));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids() {
        assert!(valid_id("20240101-120000-pool-sync-abcd"));
        assert!(valid_id("20240101-120000-a-abcd"));
        assert!(valid_id("20240101-120000----abcd"));
        for bad in [
            "",
            "20240101",
            "20240101-120000-",
            "20240101-120000-abcd",
            "20240101-120000--abcd",
            "20240101-120000-a-abcD",
            "20240101-120000-a-abc",
            "20240101-120000-aabcd",
            "2024010-120000-a-abcd",
            "20240101120000-a-abcd0",
            "20240101-12000-0-a-abcd",
            "20240101-120000a-b-abcd",
            "20240101-120000-a_b-abcd",
            "20240101-120000-é-abcd",
            "2024010é-120000-a-abcd",
            "20240101-120000-a-abéd",
            "../20240101-120000-a-abcd",
        ] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    #[test]
    fn slugs_are_made_safe() {
        assert_eq!(clean_slug("-- Pool/Sync!! --"), "Pool-Sync");
        assert_eq!(clean_slug("Café sync"), "Caf-sync");
        assert_eq!(clean_slug("!!!"), "job");
        assert_eq!(clean_slug(""), "job");
    }

    #[test]
    fn the_clock_fills_only_the_missing_letters() {
        let mut letters = "ab".to_string();
        add_clock_letters(&mut letters);
        assert_eq!(letters.len(), 4);
        assert!(letters.starts_with("ab"));
        assert!(letters.bytes().all(|byte| byte.is_ascii_lowercase()));
        let mut full = "wxyz".to_string();
        add_clock_letters(&mut full);
        assert_eq!(full, "wxyz");
        assert_eq!(random_suffix().len(), 4);
    }
}
