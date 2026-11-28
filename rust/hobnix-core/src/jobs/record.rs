//! The layout of one job record, as it is in its file.

use serde::{Deserialize, Serialize};

/// `step` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Step {
    pub n: i64,
    pub of: i64,
    pub text: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `progress` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Progress {
    pub done: i64,
    pub total: i64,
    pub unit: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `error` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub category: String,
    pub message: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `cancel` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cancel {
    pub requested_by: Option<String>,
    pub at: String,
    pub safe: bool,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `waiting` of a record (ADR 0018): the pending question. Never an answer, never a default for a secret.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)] // a reader takes what is there: a record from another writer may lack fields
pub struct Waiting {
    pub seq: i64,
    pub key: String,
    pub label: String,
    pub kind: String,
    pub default: Option<String>,
    pub pattern: Option<String>,
    pub choices: Option<Vec<String>>,
    pub error: Option<String>,
    pub attempt: i64,
    pub asked: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// One job record. The field order is the order in the file (ADR 0004 decision 3); every key is always written, absent = null.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: Option<String>,
    pub slug: Option<String>,
    pub description: Option<String>,
    pub source: Option<String>,
    pub initiator: Option<String>,
    pub unit: Option<String>,
    pub queued: Option<String>,
    pub started: Option<String>,
    pub ended: Option<String>,
    pub state: Option<String>,
    pub exit: Option<i64>,
    pub step: Option<Step>,
    pub progress: Option<Progress>,
    pub error: Option<ErrorInfo>,
    pub result: Option<serde_json::Value>,
    pub cancel: Option<Cancel>,
    pub version: Option<i64>,
    /// ADR 0018: id of the orchestration job this one belongs to.
    pub parent: Option<String>,
    /// ADR 0018: `orchestration` or `step`.
    pub kind: Option<String>,
    /// ADR 0018: the pending question while the state is `waiting`.
    pub waiting: Option<Waiting>,
    /// The row key (web/src/jobkey.js: area and arguments, "apps remove nextcloud"); set by the Python writer, kept by every rewrite here.
    #[serde(default)]
    pub key: Option<String>,
}

impl Record {
    pub(super) fn is_active(&self) -> bool {
        matches!(
            self.state.as_deref(),
            Some("queued" | "running" | "waiting")
        )
    }
}

/// An argument left empty is an absent field.
pub(super) fn non_empty(text: &str) -> Option<String> {
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_nested_keys_survive_a_round_trip() {
        let json = r#"{"id":"x","error":{"category":"exit","message":"m","hint":"keep me"},"cancel":{"requested_by":null,"at":"t","safe":true,"why":1},"result":{"b":2,"a":[1,2]}}"#;
        let record: Record = serde_json::from_str(json).unwrap();
        let out = serde_json::to_string(&record).unwrap();
        assert!(out.contains(r#""hint":"keep me""#));
        assert!(out.contains(r#""why":1"#));
        assert!(out.contains(r#""a":[1,2]"#));
    }
}
