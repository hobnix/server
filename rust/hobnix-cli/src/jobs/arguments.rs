//! The words after a command of `hobnix job-record`, read as Python's argparse reads them for job-record.py: positionals and
//! `--long value` / `--long=value` options (a unique start of a name is enough).
//! `-h` and `--help` are not answered (job-record.py prints its usage and exits 0): they are bad arguments here.

use hobnix_core::{Error, Result};

/// The one error of every word that cannot be read.
pub(super) fn bad() -> Error {
    Error::Failed("bad arguments".to_string())
}

/// Python's `int()`: surrounding white space, a sign, digits with single underscores between them.
pub(super) fn whole_number(text: &str) -> Result<i64> {
    let trimmed = text.trim();
    let digits = trimmed.strip_prefix(['+', '-']).unwrap_or(trimmed);
    let is_well_formed = !digits.is_empty()
        && !digits.starts_with('_')
        && !digits.ends_with('_')
        && !digits.contains("__")
        && digits.bytes().all(|b| b.is_ascii_digit() || b == b'_');
    if !is_well_formed {
        return Err(bad());
    }
    trimmed.replace('_', "").parse().map_err(|_| bad())
}

/// argparse's "looks like a negative number" (the parser has no option that does).
fn is_negative_number(word: &str) -> bool {
    let Some(number) = word.strip_prefix('-') else {
        return false;
    };
    let is_digits = |text: &str| text.bytes().all(|b| b.is_ascii_digit());
    let is_filled = |text: &str| !text.is_empty() && is_digits(text);
    match number.split_once('.') {
        Some((whole, fraction)) => is_digits(whole) && is_filled(fraction),
        None => is_filled(number),
    }
}

/// argparse's test for "this is an option, not a value".
fn is_option_like(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-') && !is_negative_number(word) && !word.contains(' ')
}

/// The option that a name (without its `--`) stands for: the one with that full name, else the only one that starts with it.
fn find_option(name: &str, known: &[&'static str]) -> Option<&'static str> {
    let long_names = || {
        known
            .iter()
            .filter_map(|&option| Some((option, option.strip_prefix("--")?)))
    };
    if let Some((option, _)) = long_names().find(|&(_, long)| long == name) {
        return Some(option);
    }
    let mut starting = long_names().filter(|(_, long)| long.starts_with(name));
    match (starting.next(), starting.next()) {
        (Some((option, _)), None) => Some(option),
        _ => None,
    }
}

#[derive(Debug, Default)]
pub(super) struct Arguments {
    positionals: Vec<String>,
    options: Vec<(&'static str, String)>,
}

impl Arguments {
    /// Reads the words of a command that knows the options in `known` (each written with its `--`). Fails with [`bad`].
    pub(super) fn parse(words: &[String], known: &[&'static str]) -> Result<Self> {
        let mut arguments = Self::default();
        let mut following = words.iter();
        while let Some(word) = following.next() {
            if word == "--" {
                arguments.positionals.extend(following.by_ref().cloned());
            } else if word.starts_with("--") {
                arguments.read_long(word, known, &mut following)?;
            } else if is_option_like(word) {
                return Err(bad());
            } else {
                arguments.positionals.push(word.clone());
            }
        }
        Ok(arguments)
    }

    /// A word that starts with `--`: an option and its value, or a positional when it names no option and holds a space.
    fn read_long(
        &mut self,
        word: &str,
        known: &[&'static str],
        following: &mut std::slice::Iter<'_, String>,
    ) -> Result<()> {
        let body = word.strip_prefix("--").ok_or_else(bad)?;
        let (name, attached) = match body.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (body, None),
        };
        let Some(option) = find_option(name, known) else {
            if !word.contains(' ') {
                return Err(bad());
            }
            self.positionals.push(word.to_string());
            return Ok(());
        };
        let value = match attached {
            Some(value) => value.to_string(),
            None => following
                .next()
                .filter(|next| !is_option_like(next))
                .ok_or_else(bad)?
                .clone(),
        };
        self.options.push((option, value));
        Ok(())
    }

    /// The value of an option; the last one counts when it is repeated.
    pub(super) fn option(&self, name: &str) -> Option<&str> {
        self.options
            .iter()
            .rev()
            .find(|(option, _)| *option == name)
            .map(|(_, value)| value.as_str())
    }

    /// The value of an option that must be there.
    pub(super) fn required(&self, name: &str) -> Result<&str> {
        self.option(name).ok_or_else(bad)
    }

    /// The positionals, when there are exactly `N` of them.
    pub(super) fn positionals<const N: usize>(&self) -> Result<&[String; N]> {
        self.positionals.as_slice().try_into().map_err(|_| bad())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type Split = (Vec<String>, Vec<(String, String)>);

    const LONGS: &[&str] = &["--slug", "--source", "--desc"];

    fn owned(words: &[&str]) -> Vec<String> {
        words.iter().map(ToString::to_string).collect()
    }

    /// The positionals and the options of the words, or None when they are refused.
    fn split(words: &[&str], known: &[&'static str]) -> Option<Split> {
        match Arguments::parse(&owned(words), known) {
            Ok(arguments) => Some((
                arguments.positionals,
                arguments
                    .options
                    .into_iter()
                    .map(|(n, v)| (n.to_string(), v))
                    .collect(),
            )),
            Err(e) => {
                assert_eq!(e, Error::Failed("bad arguments".into()), "{words:?}");
                None
            }
        }
    }

    fn expected(positionals: &[&str], options: &[(&str, &str)]) -> Split {
        (
            owned(positionals),
            options
                .iter()
                .map(|(n, v)| ((*n).to_string(), (*v).to_string()))
                .collect(),
        )
    }

    #[test]
    fn words_that_are_positionals() {
        let table: &[(&[&str], &[&str])] = &[
            (&[], &[]),
            (&["a", "b"], &["a", "b"]),
            (&[""], &[""]),
            (&["-"], &["-"]),
            (&["-5"], &["-5"]),
            (&["-5.5"], &["-5.5"]),
            (&["-.5"], &["-.5"]),
            (&["-x y"], &["-x y"]),
            (&["--nope x"], &["--nope x"]),
            (&["--s x"], &["--s x"]),
            // an ambiguous prefix in a word with a space
            (&["--s=a b"], &["--s=a b"]),
            (&["--"], &[]),
            (&["--", "--slug", "--", "-x"], &["--slug", "--", "-x"]),
            (&["a", "--", "-q"], &["a", "-q"]),
        ];
        for (words, positionals) in table {
            assert_eq!(
                split(words, LONGS),
                Some(expected(positionals, &[])),
                "{words:?}"
            );
        }
    }

    /// Words and the options they give.
    type OptionCase<'a> = (&'a [&'a str], &'a [(&'a str, &'a str)]);

    #[test]
    fn words_that_are_options() {
        let table: &[OptionCase<'_>] = &[
            (&["--slug", "v"], &[("--slug", "v")]),
            (&["--slug=v"], &[("--slug", "v")]),
            (&["--slug="], &[("--slug", "")]),
            (&["--slug=a=b"], &[("--slug", "a=b")]),
            (&["--slug=-x"], &[("--slug", "-x")]),
            (&["--slug=--desc"], &[("--slug", "--desc")]),
            (&["--sl", "v"], &[("--slug", "v")]),
            (&["--d=v"], &[("--desc", "v")]),
            (&["--slug", "-"], &[("--slug", "-")]),
            (&["--slug", "-3"], &[("--slug", "-3")]),
            (&["--slug", "-3.5"], &[("--slug", "-3.5")]),
            (&["--slug", "-a b"], &[("--slug", "-a b")]),
            (&["--slug", ""], &[("--slug", "")]),
            (
                &["--slug", "a", "--desc", "d", "--slug", "b"],
                &[("--slug", "a"), ("--desc", "d"), ("--slug", "b")],
            ),
        ];
        for (words, options) in table {
            assert_eq!(
                split(words, LONGS),
                Some(expected(&[], options)),
                "{words:?}"
            );
        }
    }

    #[test]
    fn words_that_are_refused() {
        let table: &[&[&str]] = &[
            &["-a"],
            &["-h"],
            &["--help"],
            &["-5."],
            &["-5.5.5"],
            &["-é"],
            &["--é"],
            &["--nope", "v"],
            &["--slugs", "v"],
            &["--s", "v"],
            &["--=v"],
            &["--slug"],
            &["--slug", "--desc"],
            &["--slug", "--"],
            &["--slug", "-x"],
            &["a", "--slug"],
        ];
        for words in table {
            assert_eq!(split(words, LONGS), None, "{words:?}");
        }
        assert_eq!(split(&["--x"], &[]), None);
        assert_eq!(split(&["--=v"], &[]), None);
    }

    #[test]
    fn a_full_name_wins_over_a_longer_one_and_an_empty_name_matches_a_single_option() {
        assert_eq!(
            split(&["--de", "v"], &["--desc", "--de"]),
            Some(expected(&[], &[("--de", "v")]))
        );
        assert_eq!(
            split(&["--=v"], &["--json"]),
            Some(expected(&[], &[("--json", "v")]))
        );
    }

    #[test]
    fn the_last_of_a_repeated_option_counts() {
        let words = owned(&["--slug", "a", "--slug", "b"]);
        let arguments = Arguments::parse(&words, LONGS).expect("parsed");
        assert_eq!(arguments.option("--slug"), Some("b"));
        assert_eq!(arguments.option("--desc"), None);
    }

    #[test]
    fn whole_numbers_as_python_reads_them() {
        for (text, number) in [
            ("0", 0),
            ("1", 1),
            (" 7 ", 7),
            ("\t8\n", 8),
            ("+5", 5),
            ("-5", -5),
            ("007", 7),
            ("1_000", 1000),
            ("-1_0", -10),
            ("9223372036854775807", i64::MAX),
            ("-9223372036854775808", i64::MIN),
        ] {
            assert_eq!(whole_number(text), Ok(number), "{text:?}");
        }
        for text in [
            "",
            " ",
            "+",
            "-",
            "_1",
            "+_1",
            "1_",
            "1__0",
            "x",
            "1x",
            "1.5",
            "+-1",
            "- 1",
            "1 0",
            "0x10",
            "\u{663}",
            "9223372036854775808",
            "99999999999999999999999999",
        ] {
            assert_eq!(
                whole_number(text),
                Err(Error::Failed("bad arguments".into())),
                "{text:?}"
            );
        }
    }
}
