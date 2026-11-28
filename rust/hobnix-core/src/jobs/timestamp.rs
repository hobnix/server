//! Clock times: UTC dates by hand (std only).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Seconds from `earlier` to `later`, negative when `later` is the earlier one.
pub(super) fn seconds_between(earlier: SystemTime, later: SystemTime) -> f64 {
    match later.duration_since(earlier) {
        Ok(duration) => duration.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    }
}

pub(super) fn now_epoch_seconds() -> f64 {
    seconds_between(UNIX_EPOCH, SystemTime::now())
}

/// The whole second at or before `seconds` (floor), clamped to the range of `i64`; 0 for "not a number".
pub(super) fn floor_seconds(seconds: f64) -> i64 {
    if seconds.is_nan() {
        return 0;
    }
    let whole = seconds.floor();
    let magnitude = Duration::try_from_secs_f64(whole.abs())
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok());
    match magnitude {
        Some(magnitude) if whole < 0.0 => -magnitude,
        Some(magnitude) => magnitude,
        None if whole < 0.0 => i64::MIN,
        None => i64::MAX,
    }
}

/// Whole seconds as a float; exact for every time `parse_iso` can return.
pub(super) fn seconds_as_float(seconds: i64) -> f64 {
    let magnitude = Duration::from_secs(seconds.unsigned_abs()).as_secs_f64();
    if seconds < 0 { -magnitude } else { magnitude }
}

pub(super) fn now_whole_seconds() -> i64 {
    floor_seconds(now_epoch_seconds())
}

pub(super) fn now_iso() -> String {
    format_iso(now_whole_seconds())
}

/// A point in time as UTC calendar fields.
#[derive(Debug)]
struct CalendarTime {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
}

impl CalendarTime {
    fn from_epoch_seconds(seconds: i64) -> Self {
        let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
        let of_day = seconds.rem_euclid(86_400);
        CalendarTime {
            year,
            month,
            day,
            hour: of_day / 3600,
            minute: of_day % 3600 / 60,
            second: of_day % 60,
        }
    }
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    // counted from 0000-03-01, so that a leap day is the last day of its year; an era is 400 years
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_from_march = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_from_march + 2) / 5 + 1;
    let month = if month_from_march < 10 {
        month_from_march + 3
    } else {
        month_from_march - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let month_from_march = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_from_march + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// `%Y-%m-%dT%H:%M:%SZ`.
pub fn format_iso(secs: i64) -> String {
    let CalendarTime {
        year,
        month,
        day,
        hour,
        minute,
        second,
    } = CalendarTime::from_epoch_seconds(secs);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// `%Y%m%d-%H%M%S`.
pub(super) fn format_id_time(seconds: i64) -> String {
    let CalendarTime {
        year,
        month,
        day,
        hour,
        minute,
        second,
    } = CalendarTime::from_epoch_seconds(seconds);
    format!("{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}")
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        _ => 28,
    }
}

/// The number made of the `min` to `max` digits at the start of `text`, and the text after them.
fn leading_number(text: &str, min: usize, max: usize) -> Option<(i64, &str)> {
    let length = text
        .bytes()
        .take(max)
        .take_while(u8::is_ascii_digit)
        .count();
    if length < min {
        return None;
    }
    let (digits, rest) = text.split_at_checked(length)?;
    Some((digits.parse().ok()?, rest))
}

/// strptime("%Y-%m-%dT%H:%M:%SZ") as seconds since the epoch; like Python the numbers need not be zero padded.
pub fn parse_iso(s: &str) -> Option<i64> {
    let (year, rest) = leading_number(s, 4, 4)?;
    let (month, rest) = leading_number(rest.strip_prefix('-')?, 1, 2)?;
    let (day, rest) = leading_number(rest.strip_prefix('-')?, 1, 2)?;
    let (hour, rest) = leading_number(rest.strip_prefix('T')?, 1, 2)?;
    let (minute, rest) = leading_number(rest.strip_prefix(':')?, 1, 2)?;
    let (second, rest) = leading_number(rest.strip_prefix(':')?, 1, 2)?;
    if rest != "Z" {
        return None;
    }
    if year < 1 || !(1..=12).contains(&month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    if day < 1 || day > days_in_month(year, month) {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates() {
        assert_eq!(format_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_iso(-1), "1969-12-31T23:59:59Z");
        assert_eq!(format_iso(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(format_iso(1_709_210_096), "2024-02-29T12:34:56Z");
        assert_eq!(format_id_time(1_709_210_096), "20240229-123456");
        for seconds in [0, 86_399, 951_782_400, 1_709_210_096, 4_102_444_799] {
            assert_eq!(parse_iso(&format_iso(seconds)), Some(seconds));
        }
    }

    #[test]
    fn parse_iso_is_strict_about_shape() {
        assert_eq!(parse_iso("2024-1-5T1:2:3Z"), Some(1_704_416_523));
        for bad in [
            "",
            "2024-02-30T00:00:00Z",
            "2024-13-01T00:00:00Z",
            "2024-01-01T24:00:00Z",
            "2024-01-01T00:00:60Z",
            "2024-01-01 00:00:00Z",
            "2024-01-01T00:00:00",
            "2024-01-01T00:00:00Zx",
            "0000-01-01T00:00:00Z",
            "202-01-01T00:00:00Z",
            "20244-01-01T00:00:00Z",
            "2024-001-01T00:00:00Z",
            "202é-01-01T00:00:00Z",
            "2024é-01-01T00:00:00Z",
            "2024-1é-01T00:00:00Z",
        ] {
            assert_eq!(parse_iso(bad), None, "{bad}");
        }
    }

    #[test]
    fn floats_and_whole_seconds_convert_both_ways() {
        assert_eq!(floor_seconds(12.9), 12);
        assert_eq!(floor_seconds(-12.1), -13);
        assert_eq!(floor_seconds(-0.0), 0);
        assert_eq!(floor_seconds(f64::NAN), 0);
        assert_eq!(floor_seconds(1e300), i64::MAX);
        assert_eq!(floor_seconds(f64::INFINITY), i64::MAX);
        assert_eq!(floor_seconds(-1e300), i64::MIN);
        assert_eq!(floor_seconds(f64::NEG_INFINITY), i64::MIN);
        for seconds in [-86_400_i32, 0, 1, 1_709_210_096] {
            let float = seconds_as_float(i64::from(seconds));
            assert!((float - f64::from(seconds)).abs() < f64::EPSILON);
        }
    }
}
