//! Word splitting like Python's `shlex.split`, for `HS_SYSTEMCTL`.

use std::str::Chars;

/// shlex.split (POSIX mode, no comments); None for an unclosed quote or a trailing backslash.
pub fn shlex_split(s: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    // Some from the first character of a word on, so that `''` is a word too
    let mut word: Option<String> = None;
    let mut characters = s.chars();
    while let Some(character) = characters.next() {
        if matches!(character, ' ' | '\t' | '\r' | '\n') {
            words.extend(word.take());
            continue;
        }
        let current = word.get_or_insert_with(String::new);
        match character {
            '\\' => current.push(characters.next()?),
            '\'' => read_single_quoted(&mut characters, current)?,
            '"' => read_double_quoted(&mut characters, current)?,
            other => current.push(other),
        }
    }
    words.extend(word);
    Some(words)
}

/// Everything up to the closing `'` is taken as it is.
fn read_single_quoted(characters: &mut Chars<'_>, word: &mut String) -> Option<()> {
    loop {
        match characters.next()? {
            '\'' => return Some(()),
            other => word.push(other),
        }
    }
}

/// Up to the closing `"`; a backslash escapes only `"` and itself, before anything else it stays.
fn read_double_quoted(characters: &mut Chars<'_>, word: &mut String) -> Option<()> {
    loop {
        match characters.next()? {
            '"' => return Some(()),
            '\\' => {
                let escaped = characters.next()?;
                if escaped != '"' && escaped != '\\' {
                    word.push('\\');
                }
                word.push(escaped);
            }
            other => word.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_like_shlex() {
        assert_eq!(
            shlex_split("sudo  -n 'a b' \"c\\\"d\" e\\ f"),
            Some(vec![
                "sudo".into(),
                "-n".into(),
                "a b".into(),
                "c\"d".into(),
                "e f".into()
            ])
        );
        assert_eq!(shlex_split("a ''"), Some(vec!["a".into(), String::new()]));
        assert_eq!(shlex_split("'open"), None);
        assert_eq!(shlex_split("end\\"), None);
        assert_eq!(shlex_split("  "), Some(vec![]));
    }

    #[test]
    fn a_backslash_in_double_quotes_escapes_only_quote_and_backslash() {
        assert_eq!(
            shlex_split(r#""a\b\\c" 'd\e'f"#),
            Some(vec![r"a\b\c".into(), r"d\ef".into()])
        );
        assert_eq!(shlex_split("\"open"), None);
        assert_eq!(shlex_split("\"end\\"), None);
    }
}
