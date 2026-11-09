use crate::{Cancellation, Comparison, Error};
fn append(output: &mut String, text: &str, limit: usize) -> Result<(), Error> {
    if output
        .len()
        .checked_add(text.len())
        .filter(|n| *n <= limit)
        .is_none()
    {
        return Err(Error::Limit("diff report bytes"));
    }
    output.push_str(text);
    Ok(())
}
impl Comparison {
    /// Vollständiger Textbericht der gebundenen logischen Vergleichsbasis; kein Patchformat.
    pub fn report(
        &self,
        left_label: &str,
        right_label: &str,
        cancel: &Cancellation,
    ) -> Result<String, Error> {
        cancel.check()?;
        if left_label
            .len()
            .checked_add(right_label.len())
            .filter(|n| *n <= self.limits.max_report_bytes)
            .is_none()
        {
            return Err(Error::Limit("diff report labels"));
        }
        let mut output = String::new();
        let limit = self.limits.max_report_bytes;
        append(&mut output, "Fastra difference report\n", limit)?;
        append(&mut output,&format!("Left: {left_label:?}\nRight: {right_label:?}\nOptions: {:?}\nLogical difference blocks: {}\nByte-identical: {}\nLine-ending differences: {}\n",self.options,self.blocks.len(),self.byte_identical(),self.rows.iter().any(|r|r.terminators_differ)),limit)?;
        if !self.byte_identical() && self.blocks.is_empty() {
            append(&mut output,"Original bytes differ, while the active logical comparison has no difference blocks.\n",limit)?;
        }
        for row in self.rows.iter().filter(|row| row.terminators_differ) {
            cancel.check()?;
            if let (Some(a), Some(b)) = (row.left_line, row.right_line) {
                append(
                    &mut output,
                    &format!(
                        "Line ending at left {a}/right {b}: {:?} -> {:?}\n",
                        &self.left.text[self.left_lines[a - 1].terminator.clone()],
                        &self.right.text[self.right_lines[b - 1].terminator.clone()]
                    ),
                    limit,
                )?;
            }
        }
        for block in &self.blocks {
            cancel.check()?;
            append(
                &mut output,
                &format!(
                    "\nBlock {} ({:?}, display rows {}–{})\n",
                    block.id + 1,
                    block.kind,
                    block.rows.start + 1,
                    block.rows.end
                ),
                limit,
            )?;
            for row in &self.rows[block.rows.clone()] {
                cancel.check()?;
                if let Some(number) = row.left_line {
                    append(
                        &mut output,
                        &format!(
                            "- {number} | {}\n",
                            self.content(true, number)
                                .ok_or(Error::Internal("report left line"))?
                        ),
                        limit,
                    )?;
                }
                if let Some(number) = row.right_line {
                    append(
                        &mut output,
                        &format!(
                            "+ {number} | {}\n",
                            self.content(false, number)
                                .ok_or(Error::Internal("report right line"))?
                        ),
                        limit,
                    )?;
                }
            }
        }
        append(
            &mut output,
            "\n- denotes the left source; + denotes the right source. Line numbers begin at 1.\n",
            limit,
        )?;
        Ok(output)
    }
}
