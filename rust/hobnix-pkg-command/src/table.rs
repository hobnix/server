//! The command table that [`command`](crate::command) and [`commands!`](crate::commands) build: the dispatch and the `commands.tsv` rows,
//! both from the same code.
//!
//! The rows are built by the compiler (const evaluation) into one byte string in the program, between [`TABLE_START`] and a NUL byte:
//! `python3 scripts/pkg.py validate` of the core reads it from the file of the `[[binary]]` without running the program and refuses a
//! `commands.tsv` whose rows for that program differ (`binary.drift`). The core needs the rows before it starts a program (ADR 0031).

use std::fmt;
use std::io::{self, BufRead, Write};
use std::process::ExitCode;

use hobnix_pkg::Ctx;

use crate::{Failure, Request, Success};

/// The bytes in front of the rows in the program file. Changing them is a breaking change of the file format the core reads.
pub const TABLE_START: &[u8] = b"\0hobnix-commands-tsv-1\0";

/// The handler of one command, as the dispatch calls it.
pub(crate) type Handler = fn(&Request, &dyn Ctx) -> Result<Success, Failure>;

/// One row of `commands.tsv` without the package name and the program, which [`commands!`](crate::commands) adds.
#[doc(hidden)]
#[derive(Debug, Clone, Copy)]
pub struct Row {
    sys: bool,
    help: &'static str,
    help_de: &'static str,
    flags: &'static str,
}

impl Row {
    /// A `user` row (`hs ext <package> <words>`).
    pub const fn user(help: &'static str, help_de: &'static str, flags: &'static str) -> Self {
        Row {
            sys: false,
            help,
            help_de,
            flags,
        }
    }
    /// A `sys` row (`hs sys ext <package> <words>`, what the web interface reads).
    pub const fn sys(help: &'static str, flags: &'static str) -> Self {
        Row {
            sys: true,
            help,
            help_de: "-",
            flags,
        }
    }
}

/// One command: its words, its rows, its argument schema and its handler.
#[derive(Clone, Copy)]
pub struct Command {
    words: &'static str,
    rows: &'static [Row],
    args: &'static [crate::ArgSpec],
    handler: Handler,
}

impl fmt::Debug for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Command")
            .field("words", &self.words)
            .field("args", &self.args)
            .finish_non_exhaustive()
    }
}

impl Command {
    #[doc(hidden)]
    pub const fn new(
        words: &'static str,
        rows: &'static [Row],
        args: &'static [crate::ArgSpec],
        handler: Handler,
    ) -> Self {
        Command {
            words,
            rows,
            args,
            handler,
        }
    }
    /// The command words (`status`, `record session`).
    pub fn words(&self) -> &'static str {
        self.words
    }
    /// The arguments it takes, in order.
    pub fn args(&self) -> &'static [crate::ArgSpec] {
        self.args
    }
}

/// The commands of a program, made by [`commands!`](crate::commands).
#[derive(Clone, Copy)]
pub struct Commands {
    list: &'static [Command],
    table: &'static [u8],
    script: &'static str,
}

impl fmt::Debug for Commands {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Commands")
            .field("list", &self.list)
            .field("script", &self.script)
            .finish_non_exhaustive()
    }
}

impl Commands {
    #[doc(hidden)]
    pub fn new(list: &'static [Command], table: &'static [u8], script: &'static str) -> Self {
        Commands {
            list,
            table,
            script,
        }
    }

    /// The commands in the order of [`commands!`](crate::commands).
    pub fn list(&self) -> &'static [Command] {
        self.list
    }

    /// The `commands.tsv` rows of these commands, one line each ending in `\n`: what the package's `commands.tsv` must contain for the program.
    pub fn tsv(&self) -> &'static str {
        let rows = self
            .table
            .get(TABLE_START.len()..self.table.len().saturating_sub(1))
            .unwrap_or_default();
        std::str::from_utf8(rows).unwrap_or_default()
    }

    /// Compare the rows of a `commands.tsv` text that start this program (third column) with [`tsv`](Self::tsv), in order; comment lines and
    /// rows of other programs are ignored. A test of the package calls it with `include_str!("../commands.tsv")` (the drift check of `cargo
    /// test`; `hs pkg validate` checks the same on the built program).
    ///
    /// # Errors
    /// [`Drift`] when the rows differ.
    pub fn check(&self, commands_tsv: &str) -> Result<(), Drift> {
        let found: Vec<&str> = commands_tsv
            .lines()
            .filter(|l| !l.starts_with('#') && l.split('\t').nth(2) == Some(self.script))
            .collect();
        let want: Vec<&str> = self.tsv().lines().collect();
        if found == want {
            Ok(())
        } else {
            Err(Drift {
                script: self.script,
                want: self.tsv().to_owned(),
                found: found.join("\n"),
            })
        }
    }

    /// Run the command the request names against stdin/stdout and return the exit code ([`run`](crate::run) with the generated dispatch).
    pub fn run(&self) -> ExitCode {
        let stdin = io::stdin();
        ExitCode::from(self.run_with(&mut stdin.lock(), io::stdout()))
    }

    /// [`run`](Self::run) over any reader and writer (for tests). Returns the exit code.
    pub fn run_with(&self, input: &mut impl BufRead, output: impl Write + Send + 'static) -> u8 {
        // the table is read here so that the linker keeps it in the program (validate reads it from the file)
        std::hint::black_box(self.table);
        crate::run_with(input, output, |req, ctx| self.dispatch(req, ctx))
    }

    fn dispatch(&self, req: &Request, ctx: &dyn Ctx) -> Result<Success, Failure> {
        let words = req.command.join(" ");
        match self.list.iter().find(|c| c.words == words) {
            Some(c) => (c.handler)(req, ctx),
            None => Err(Failure::not_found(format!("no such command: {words}"))),
        }
    }
}

/// The rows of a `commands.tsv` differ from the ones the code makes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Drift {
    script: &'static str,
    want: String,
    found: String,
}

impl Drift {
    /// The rows the code makes.
    pub fn want(&self) -> &str {
        &self.want
    }
}

impl fmt::Display for Drift {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the rows of commands.tsv for {} differ from the code; they must be:\n{}found:\n{}",
            self.script, self.want, self.found
        )
    }
}

impl std::error::Error for Drift {}

/// The pieces of one row of `commands.tsv`, in order.
const fn pieces(
    row: &Row,
    words: &'static str,
    package: &'static str,
    script: &'static str,
) -> [&'static str; 15] {
    let (kind, prefix) = if row.sys {
        ("sys", "sys ext ")
    } else {
        ("user", "ext ")
    };
    [
        kind,
        "\t",
        prefix,
        package,
        " ",
        words,
        "\t",
        script,
        "\t-\t",
        row.help,
        "\t",
        row.help_de,
        "\t",
        row.flags,
        "\n",
    ]
}

const fn same(a: &str, b: &str) -> bool {
    let (mut a, mut b) = (a.as_bytes(), b.as_bytes());
    loop {
        match (a, b) {
            ([x, more_a @ ..], [y, more_b @ ..]) if *x == *y => (a, b) = (more_a, more_b),
            ([], []) => return true,
            _ => return false,
        }
    }
}

/// The length of the table of `list`. Refuses (a compile error, it runs at build time) two commands with the same words.
#[doc(hidden)]
pub const fn table_len(list: &[Command], package: &'static str, script: &'static str) -> usize {
    let mut n = TABLE_START.len() + 1;
    let mut commands = list;
    while let [command, more_commands @ ..] = commands {
        let mut others = more_commands;
        while let [other, more_others @ ..] = others {
            assert!(
                !same(command.words, other.words),
                "two commands in commands! have the same words"
            );
            others = more_others;
        }
        let mut rows = command.rows;
        while let [row, more_rows @ ..] = rows {
            let pieces = pieces(row, command.words, package, script);
            let mut rest: &[&str] = &pieces;
            while let [piece, more @ ..] = rest {
                n += piece.len();
                rest = more;
            }
            rows = more_rows;
        }
        commands = more_commands;
    }
    n
}

/// The table of `list`: [`TABLE_START`], the rows, a NUL byte. `N` is [`table_len`]. The same walk as there (a const fn cannot take a
/// closure, so the two walks are not one).
#[doc(hidden)]
pub const fn table<const N: usize>(
    list: &[Command],
    package: &'static str,
    script: &'static str,
) -> [u8; N] {
    let mut out = [0u8; N];
    let mut free = put(&mut out, TABLE_START);
    let mut commands = list;
    while let [command, more_commands @ ..] = commands {
        let mut rows = command.rows;
        while let [row, more_rows @ ..] = rows {
            let pieces = pieces(row, command.words, package, script);
            let mut rest: &[&str] = &pieces;
            while let [piece, more @ ..] = rest {
                free = put(free, piece.as_bytes());
                rest = more;
            }
            rows = more_rows;
        }
        commands = more_commands;
    }
    out
}

/// `bytes` written to the front of `free`, the part of the table that is not written yet; returns what is still free after them. A table
/// that is too short stops the const evaluation at build time: a compile error, never a panic of the program.
const fn put<'table>(free: &'table mut [u8], bytes: &[u8]) -> &'table mut [u8] {
    let (written, still_free) = free.split_at_mut(bytes.len());
    written.copy_from_slice(bytes);
    still_free
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: Handler = |_, _| Ok(Success::text("ok"));

    const ROWS: &[Row] = &[
        Row::user("show it", "zeigt es", "topic:apps,reads,proto"),
        Row::sys("it as data", "reads,proto"),
    ];
    const LIST: &[Command] = &[
        Command::new("status", ROWS, &[], OK),
        Command::new(
            "sync now",
            &[Row::user("sync", "-", "changes,proto")],
            &[],
            OK,
        ),
    ];
    const LEN: usize = table_len(LIST, "demo", "@/bin/demo");
    static TABLE: [u8; LEN] = table(LIST, "demo", "@/bin/demo");

    const WANT: &str = "user\text demo status\t@/bin/demo\t-\tshow it\tzeigt es\ttopic:apps,reads,proto\n\
                        sys\tsys ext demo status\t@/bin/demo\t-\tit as data\t-\treads,proto\n\
                        user\text demo sync now\t@/bin/demo\t-\tsync\t-\tchanges,proto\n";

    #[test]
    fn the_table_holds_the_rows_between_the_markers() {
        assert!(TABLE.starts_with(TABLE_START));
        assert_eq!(TABLE.last(), Some(&0));
        assert_eq!(Commands::new(LIST, &TABLE, "@/bin/demo").tsv(), WANT);
    }

    #[test]
    fn check_ignores_comments_and_other_programs_and_sees_a_changed_row() {
        let c = Commands::new(LIST, &TABLE, "@/bin/demo");
        let file =
            format!("# kind\tpath\nuser\text demo other\t@/other.sh\t-\tx\t-\treads\n{WANT}");
        assert_eq!(c.check(&file), Ok(()));
        let changed = file.replace("show it", "show that");
        let e = c.check(&changed).unwrap_err();
        assert_eq!(e.want(), WANT);
        assert!(
            e.to_string()
                .starts_with("the rows of commands.tsv for @/bin/demo differ")
        );
        assert!(c.check(&file.replace("sync now", "sync later")).is_err());
    }
}
