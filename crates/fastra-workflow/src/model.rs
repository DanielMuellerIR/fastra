use crate::{Error, Template};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;
pub const MAX_ARCHIVE_BYTES: usize = 1024 * 1024;
type Extra = BTreeMap<String, serde_json::Value>;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub id: String,
    pub kind: String,
    pub enabled: bool,
    pub argument: String,
    pub find: String,
    pub replacement: String,
    pub regex: bool,
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub literal_wildcard: bool,
    pub tab_width: usize,
    pub indent_width: usize,
    pub uses_tabs: bool,
    pub wrap_column: usize,
    #[serde(flatten)]
    pub extra: Extra,
}
impl Step {
    pub fn new(kind: &str) -> Result<Self, Error> {
        Ok(Self {
            id: new_id()?,
            kind: kind.into(),
            enabled: true,
            argument: String::new(),
            find: String::new(),
            replacement: String::new(),
            regex: false,
            case_sensitive: false,
            whole_word: false,
            literal_wildcard: false,
            tab_width: 4,
            indent_width: 4,
            uses_tabs: false,
            wrap_column: 72,
            extra: Extra::new(),
        })
    }
    pub fn uses_text_locale(&self) -> bool {
        matches!(self.kind.as_str(), "titlecase" | "uppercase" | "lowercase" | "sortAscending" | "sortDescending")
    }
    pub fn supported(&self) -> bool {
        matches!(
            self.kind.as_str(),
            "replace"
                | "sortAscending"
                | "sortDescending"
                | "removeDuplicateLines"
                | "keepDuplicateLines"
                | "removeAllDuplicatedLines"
                | "uppercase"
                | "lowercase"
                | "titlecase"
                | "trimTrailing"
                | "zapGremlins"
                | "reverseLines"
                | "removeBlankLines"
                | "joinLines"
                | "joinLinesTight"
                | "prefixLines"
                | "suffixLines"
                | "addLineNumbers"
                | "removeLineNumbers"
                | "keepLinesMatching"
                | "deleteLinesMatching"
                | "normalizeSpaces"
                | "precomposeUnicode"
                | "fourDDetokenize"
                | "fourDTokenizeCommands"
                | "decomposeUnicode"
                | "detab"
                | "entab"
                | "shiftRight"
                | "shiftLeft"
                | "hardWrap"
                | "straightenQuotes"
                | "educateQuotes"
                | "convertEscapeSequences"
                | "exchangeCharacters"
                | "exchangeWords"
                | "stripDiacriticals"
                | "addEmojiPresentation"
                | "removeEmojiPresentation"
        )
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Workflow {
    pub id: String,
    pub revision: String,
    pub name: String,
    pub steps: Vec<Step>,
    #[serde(flatten)]
    pub extra: Extra,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Snippet {
    pub id: String,
    pub revision: String,
    pub name: String,
    pub template: String,
    #[serde(flatten)]
    pub extra: Extra,
}
pub trait Definition: Clone + Serialize + for<'de> Deserialize<'de> {
    fn id(&self) -> &str;
    fn validate(&self) -> Result<(), Error>;
}
fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
impl Definition for Workflow {
    fn id(&self) -> &str {
        &self.id
    }
    fn validate(&self) -> Result<(), Error> {
        let mut unsupported = Vec::new();
        if self.name.contains('\0') {
            unsupported.push("workflow.name: U+0000".into());
        }
        for (index, step) in self.steps.iter().enumerate() {
            for (field, value) in [
                ("kind", &step.kind),
                ("argument", &step.argument),
                ("find", &step.find),
                ("replacement", &step.replacement),
            ] {
                if value.contains('\0') {
                    unsupported.push(format!("{}.{}: U+0000", index + 1, field));
                }
            }
        }
        if !unsupported.is_empty() {
            return Err(Error::Unsupported(unsupported));
        }
        if !uuid(&self.id)
            || !uuid(&self.revision)
            || self.name.trim().is_empty()
            || self.name.len() > 256
            || self.steps.is_empty()
            || self.steps.len() > 32
            || !self.steps.iter().any(|s| s.enabled)
        {
            return Err(Error::Invalid("workflow".into()));
        }
        let mut ids = HashSet::new();
        for step in &self.steps {
            if step.kind.is_empty()
                || step.kind.len() > 128
                || !uuid(&step.id)
                || !ids.insert(&step.id)
                || [&step.argument, &step.find, &step.replacement]
                    .iter()
                    .any(|s| s.len() > 4096)
                || !(1..=16).contains(&step.tab_width)
                || !(1..=16).contains(&step.indent_width)
                || !(1..=10000).contains(&step.wrap_column)
            {
                return Err(Error::Invalid("step parameters".into()));
            }
        }
        Ok(())
    }
}
impl Definition for Snippet {
    fn id(&self) -> &str {
        &self.id
    }
    fn validate(&self) -> Result<(), Error> {
        if !uuid(&self.id)
            || !uuid(&self.revision)
            || self.name.trim().is_empty()
            || self.name.graphemes(true).count() > 80
            || self.name.chars().any(crate::unicode::control)
            || self.template.is_empty()
        {
            return Err(Error::Invalid("snippet".into()));
        }
        Template::parse(&self.template)?;
        Ok(())
    }
}
// Die Hüllobjekte behalten fremde Zusatzfelder. Ein Export entfernt keine
// Einstellungen neuerer Versionen; aktivierte unbekannte Schritte bleiben gesperrt.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowArchive {
    pub schema_version: u32,
    pub workflows: Vec<Workflow>,
    #[serde(flatten)]
    pub extra: Extra,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnippetArchive {
    pub schema_version: u32,
    pub snippets: Vec<Snippet>,
    #[serde(flatten)]
    pub extra: Extra,
}
fn validate<T: Definition>(version: u32, values: &[T]) -> Result<(), Error> {
    if version != 1 || values.len() > 50 {
        return Err(Error::Invalid("archive version/count".into()));
    }
    let mut ids = HashSet::new();
    for value in values {
        value.validate()?;
        if !ids.insert(value.id()) {
            return Err(Error::Invalid("duplicate id".into()));
        }
    }
    Ok(())
}
macro_rules! archive_impl {
    ($type:ty,$field:ident) => {
        impl $type {
            pub fn decode(data: &[u8]) -> Result<Self, Error> {
                if data.len() > MAX_ARCHIVE_BYTES {
                    return Err(Error::Limit);
                }
                let result: Self = serde_json::from_slice(data)?;
                validate(result.schema_version, &result.$field)?;
                Ok(result)
            }
            pub fn encode(&self) -> Result<Vec<u8>, Error> {
                validate(self.schema_version, &self.$field)?;
                let data = serde_json::to_vec_pretty(self)?;
                if data.len() > MAX_ARCHIVE_BYTES {
                    return Err(Error::Limit);
                }
                Ok(data)
            }
            pub fn empty() -> Self {
                Self {
                    schema_version: 1,
                    $field: Vec::new(),
                    extra: Extra::new(),
                }
            }
        }
    };
}
archive_impl!(WorkflowArchive, workflows);
archive_impl!(SnippetArchive, snippets);
pub fn new_id() -> Result<String, Error> {
    let mut bytes = [0u8; 16];
    loop {
        if unsafe { libc::getentropy(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
            break;
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.into());
        }
    }
    bytes[6] = (bytes[6] & 15) | 0x40;
    bytes[8] = (bytes[8] & 63) | 0x80;
    Ok(format!("{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
}
fn merge_extra(target: &mut Extra, incoming: &Extra) -> Result<(), Error> {
    for (key, value) in incoming {
        if target.get(key).is_some_and(|existing| existing != value) {
            return Err(Error::Invalid(format!("archive field conflict: {key}")));
        }
        target.insert(key.clone(), value.clone());
    }
    Ok(())
}
fn available_name(name: &str, names: &mut Vec<String>, max: usize, graphemes: bool) -> String {
    let base = if graphemes { name.trim() } else { name };
    let mut result = base.to_string();
    let mut suffix = 2;
    while names
        .iter()
        .any(|other| other.to_lowercase() == result.to_lowercase())
    {
        let end = format!(" ({suffix})");
        let limit = max.saturating_sub(end.len());
        let prefix: String = if graphemes {
            base.graphemes(true).take(limit).collect()
        } else {
            base.to_string()
        };
        result = format!("{prefix}{end}");
        suffix += 1;
    }
    names.push(result.clone());
    result
}
impl WorkflowArchive {
    pub fn merged(&self, incoming: &Self) -> Result<Self, Error> {
        self.encode()?;
        incoming.encode()?;
        if self.workflows.len() + incoming.workflows.len() > 50 {
            return Err(Error::Limit);
        }
        let mut merged = self.clone();
        merge_extra(&mut merged.extra, &incoming.extra)?;
        let mut names = self.workflows.iter().map(|v| v.name.clone()).collect();
        for workflow in &incoming.workflows {
            let mut workflow = workflow.clone();
            workflow.id = new_id()?;
            workflow.revision = new_id()?;
            workflow.name = available_name(&workflow.name, &mut names, 256, false);
            for step in &mut workflow.steps {
                step.id = new_id()?;
            }
            merged.workflows.push(workflow);
        }
        merged.encode()?;
        Ok(merged)
    }
}
impl SnippetArchive {
    pub fn merged(&self, incoming: &Self) -> Result<Self, Error> {
        self.encode()?;
        incoming.encode()?;
        if self.snippets.len() + incoming.snippets.len() > 50 {
            return Err(Error::Limit);
        }
        let mut merged = self.clone();
        merge_extra(&mut merged.extra, &incoming.extra)?;
        let mut names = self.snippets.iter().map(|v| v.name.clone()).collect();
        for snippet in &incoming.snippets {
            let mut snippet = snippet.clone();
            snippet.id = new_id()?;
            snippet.revision = new_id()?;
            snippet.name = available_name(&snippet.name, &mut names, 80, true);
            merged.snippets.push(snippet);
        }
        merged.encode()?;
        Ok(merged)
    }
}
