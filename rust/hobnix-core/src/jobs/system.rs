//! The two questions that need the machine, behind a trait so that tests use a fake.

use super::shlex::shlex_split;
use super::timestamp::now_epoch_seconds;
use std::fs;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// How long `systemctl is-active` may take before it is killed.
const SYSTEMCTL_TIME_LIMIT: Duration = Duration::from_secs(20);

/// The two questions that need the machine.
pub trait System {
    /// True when systemd says the unit is active or activating; any other answer (or no systemctl) means it is gone.
    fn unit_alive(&self, unit: &str) -> bool;
    /// Boot time as seconds since the epoch, or None when unknown.
    fn boot_time(&self) -> Option<f64>;
}

/// The real machine: `HS_SYSTEMCTL` (split like shlex) and `HS_UPTIME_FILE` (default /proc/uptime) as in job-record.py.
#[derive(Debug)]
pub struct RealSystem;

impl System for RealSystem {
    fn unit_alive(&self, unit: &str) -> bool {
        if unit.is_empty() {
            return false;
        }
        let spec = env_nonempty("HS_SYSTEMCTL").unwrap_or_else(|| "systemctl".to_string());
        // mirrored: an unclosed quote is an uncaught error in Python (exit 1); here the unit counts as gone
        let Some(mut command_line) = shlex_split(&spec) else {
            return false;
        };
        command_line.push("is-active".to_string());
        command_line.push(unit.to_string());
        output_within(&command_line, SYSTEMCTL_TIME_LIMIT).is_some_and(|output| {
            matches!(
                String::from_utf8_lossy(&output).trim(),
                "active" | "activating"
            )
        })
    }

    fn boot_time(&self) -> Option<f64> {
        let path = env_nonempty("HS_UPTIME_FILE").unwrap_or_else(|| "/proc/uptime".to_string());
        let text = fs::read_to_string(path).ok()?;
        let uptime: f64 = text.split_whitespace().next()?.parse().ok()?;
        uptime.is_finite().then(|| now_epoch_seconds() - uptime)
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// The standard output of a program that ends within `limit`, whatever its exit status; None when it cannot start or takes longer.
fn output_within(command_line: &[String], limit: Duration) -> Option<Vec<u8>> {
    let (program, arguments) = command_line.split_first()?;
    let mut child = Command::new(program)
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if !has_ended_within(&mut child, limit) {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }
    let mut output = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_end(&mut output);
    }
    Some(output)
}

fn has_ended_within(child: &mut Child, limit: Duration) -> bool {
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) if start.elapsed() < limit => {
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => return false,
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn words(command_line: &[&str]) -> Vec<String> {
        command_line.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn the_output_counts_whatever_the_exit_status_is() {
        let limit = Duration::from_secs(10);
        let failing = words(&["sh", "-c", "echo inactive; exit 3"]);
        assert_eq!(output_within(&failing, limit), Some(b"inactive\n".to_vec()));
        assert_eq!(output_within(&[], limit), None);
        assert_eq!(
            output_within(&words(&["/nonexistent/program"]), limit),
            None
        );
    }

    #[test]
    fn a_program_over_the_time_limit_gives_nothing() {
        let sleeping = words(&["sleep", "30"]);
        assert_eq!(output_within(&sleeping, Duration::from_millis(50)), None);
    }
}
