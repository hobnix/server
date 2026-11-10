//! `hobnix secrets plan|start ...`: reads the words, calls hobnix-core and writes the lines vault-change.sh wrote.

use hobnix_core::secrets::{self, Action, Paths, Plan, SecretName, SystemHost};
use hobnix_core::{Error, Result, EXIT_OK, EXIT_REFUSED};
use std::io::Write;

const USAGE: &str =
    "usage: vault-change.sh plan|start header-backup|move [<name>...]|close|secrets-fix\n";

fn refused(reason: &str) -> String {
    format!("status\trefused\nreason\t{reason}\n")
}

fn plan_lines(p: &Plan) -> String {
    let mut o = format!("status\tok\nheading\t{}\n", p.heading);
    for s in &p.steps {
        o.push_str(&format!("step\t{s}\n"));
    }
    for d in &p.dangers {
        o.push_str(&format!("danger\t{d}\n"));
    }
    if let Some(n) = p.note {
        o.push_str(&format!("note\t{n}\n"));
    }
    o.push_str(&format!("command\t{}\n", p.command));
    if let Some(c) = p.confirm_name {
        o.push_str(&format!("confirm_name\t{c}\n"));
    }
    o.push_str(&format!("long\t{}\n", if p.long { "yes" } else { "no" }));
    o
}

fn write_out(text: &str) -> Result<()> {
    let mut out = std::io::stdout().lock();
    out.write_all(text.as_bytes())
        .and_then(|()| out.flush())
        .map_err(|_| Error::Failed("cannot write the answer".into()))
}

/// The action (with its names) and the typed word, or the reason to refuse.
fn parse(args: &[String]) -> std::result::Result<(Action, Option<String>), String> {
    let mut action = Action::parse(args.get(1).map_or("", String::as_str))
        .ok_or_else(|| "unknown action (header-backup, move, close or secrets-fix)".to_string())?;
    let mut names: Vec<SecretName> = Vec::new();
    let mut confirm = None;
    let mut i = 2;
    while i < args.len() {
        let a = &args[i];
        if a == "--confirm" {
            let v = args
                .get(i + 1)
                .ok_or_else(|| "--confirm needs a value".to_string())?;
            confirm = Some(v.clone());
            i += 2;
        } else if a.starts_with('-') {
            return Err(format!("unknown option {a}"));
        } else {
            if !matches!(action, Action::Move(_)) {
                return Err("unexpected extra arguments".into());
            }
            let n =
                SecretName::parse(a).ok_or_else(|| format!("'{a}' is not a name of a secret"))?;
            names.push(n);
            i += 1;
        }
    }
    if matches!(action, Action::Move(_)) {
        action = Action::Move(names);
    }
    Ok((action, confirm))
}

/// `args` = everything after `secrets`. Returns the exit code.
pub fn run(args: &[String]) -> Result<u8> {
    let verb = args.first().map_or("", String::as_str);
    if verb != "plan" && verb != "start" {
        eprint!("{USAGE}");
        return Ok(EXIT_REFUSED);
    }
    let (action, confirm) = match parse(args) {
        Ok(v) => v,
        Err(reason) => {
            write_out(&refused(&reason))?;
            return Ok(EXIT_REFUSED);
        }
    };
    let paths = Paths::from_env()?;
    let host = SystemHost::from_env();
    let answer = if verb == "plan" {
        secrets::plan(&action, &paths, &host).map(|p| plan_lines(&p))
    } else {
        secrets::start(&action, confirm.as_deref(), &paths, &host)
            .map(|unit| format!("status\tstarted\nunit\t{unit}\n"))
    };
    match answer {
        Ok(text) => {
            write_out(&text)?;
            Ok(EXIT_OK)
        }
        Err(Error::Refused(m) | Error::Failed(m)) => {
            write_out(&refused(&m))?;
            Ok(EXIT_REFUSED)
        }
        Err(e) => Err(e),
    }
}
