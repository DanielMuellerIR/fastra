use fastra_diff::*;
use serde::Deserialize;
fn snapshot(id: &str, text: &str) -> TextSnapshot {
    TextSnapshot {
        document_id: id.into(),
        revision: 7,
        text: text.into(),
    }
}
fn compare(left: &str, right: &str, options: Options) -> Comparison {
    Comparison::compare(
        snapshot("left", left),
        snapshot("right", right),
        9,
        options,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
}
#[derive(Deserialize)]
struct ReferenceRow {
    left: Option<usize>,
    right: Option<usize>,
    kind: String,
    ignored: bool,
}
#[derive(Deserialize)]
struct ReferenceBlock {
    start: usize,
    end: usize,
    kind: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReferenceTransfer {
    block: usize,
    to_left: bool,
    output: String,
    replacement: String,
    location: usize,
    length: usize,
}
#[derive(Deserialize)]
struct Vector {
    left: String,
    right: String,
    options: [bool; 4],
    rows: Vec<ReferenceRow>,
    blocks: Vec<ReferenceBlock>,
    transfers: Vec<ReferenceTransfer>,
}
#[test]
fn actual_swift_rows_blocks_and_exact_transfers() {
    let vectors: Vec<Vector> =
        serde_json::from_str(include_str!("fixtures/swift-diff-reference.json")).unwrap();
    assert_eq!(vectors.len(), 252);
    for (index, v) in vectors.iter().enumerate() {
        let options = Options {
            ignore_trailing_whitespace: v.options[0],
            ignore_all_whitespace: v.options[1],
            ignore_blank_lines: v.options[2],
            ignore_case: v.options[3],
        };
        let comparison = compare(&v.left, &v.right, options);
        assert_eq!(
            comparison.rows().len(),
            v.rows.len(),
            "vector {index} {:?} {:?}",
            v.left,
            v.right
        );
        for (row, reference) in comparison.rows().iter().zip(&v.rows) {
            assert_eq!(
                (row.left_line, row.right_line, row.ignored_blank),
                (reference.left, reference.right, reference.ignored),
                "vector {index}"
            );
            let kind = match row.kind {
                RowKind::Unchanged => "unchanged",
                RowKind::Changed => "changed",
                RowKind::Removed => "removed",
                RowKind::Added => "added",
            };
            assert_eq!(kind, reference.kind, "vector {index}");
        }
        assert_eq!(comparison.blocks().len(), v.blocks.len(), "vector {index}");
        for (block, reference) in comparison.blocks().iter().zip(&v.blocks) {
            assert_eq!(block.rows, reference.start..reference.end, "vector {index}");
            let kind = match block.kind {
                BlockKind::Changed => "changed",
                BlockKind::OnlyLeft => "onlyLeft",
                BlockKind::OnlyRight => "onlyRight",
            };
            assert_eq!(kind, reference.kind, "vector {index}");
        }
        for reference in &v.transfers {
            let left = snapshot("left", &v.left);
            let right = snapshot("right", &v.right);
            let plan = comparison
                .prepare_transfer(
                    &left,
                    &right,
                    9,
                    &[reference.block],
                    if reference.to_left {
                        Direction::ToLeft
                    } else {
                        Direction::ToRight
                    },
                    &Cancellation::default(),
                )
                .unwrap();
            assert_eq!(
                plan.output().as_bytes(),
                reference.output.as_bytes(),
                "vector {index} left {}",
                reference.to_left
            );
            assert_eq!(
                plan.replacements()[0].text.as_bytes(),
                reference.replacement.as_bytes(),
                "vector {index}"
            );
            assert_eq!(
                plan.replacements()[0].utf16,
                Utf16Range {
                    location: reference.location,
                    length: reference.length
                },
                "vector {index}"
            );
            let result = plan
                .apply(&left, &right, 9, &Cancellation::default())
                .unwrap();
            assert_eq!(result.text, reference.output);
        }
    }
}
#[test]
fn plan_binds_both_sources_ids_revisions_bytes_and_generation() {
    let left = snapshot("left", "é\nold");
    let right = snapshot("right", "new\nnew");
    let diff = compare(&left.text, &right.text, Options::default());
    let plan = diff
        .prepare_transfer(
            &left,
            &right,
            9,
            &[0],
            Direction::ToLeft,
            &Cancellation::default(),
        )
        .unwrap();
    for axis in 0..7 {
        let mut a = left.clone();
        let mut b = right.clone();
        let mut generation = 9;
        match axis {
            0 => a.document_id.push('x'),
            1 => a.revision += 1,
            2 => a.text = "e\u{301}\nold".into(),
            3 => b.document_id.push('x'),
            4 => b.revision += 1,
            5 => b.text.push('x'),
            _ => generation += 1,
        }
        assert!(matches!(
            plan.apply(&a, &b, generation, &Cancellation::default()),
            Err(Error::Stale)
        ));
    }
}
#[test]
fn multiblock_transfer_keeps_every_outside_byte_and_rejects_duplicate_ids() {
    let left = snapshot("left", "start\r\nold1\r\nkeep\r\nold2\r\nend");
    let right = snapshot("right", "start\nnew1\nkeep\nnew2\nend");
    let diff = compare(&left.text, &right.text, Options::default());
    assert_eq!(diff.blocks().len(), 2);
    let plan = diff
        .prepare_transfer(
            &left,
            &right,
            9,
            &[0, 1],
            Direction::ToLeft,
            &Cancellation::default(),
        )
        .unwrap();
    assert_eq!(plan.output(), "start\r\nnew1\nkeep\r\nnew2\nend");
    let single = diff
        .prepare_transfer(
            &left,
            &right,
            9,
            &[1],
            Direction::ToLeft,
            &Cancellation::default(),
        )
        .unwrap();
    let edit = &single.replacements()[0];
    assert_eq!(
        &single.output()[..edit.bytes.start],
        &left.text[..edit.bytes.start]
    );
    assert!(single.output().ends_with(&left.text[edit.bytes.end..]));
    for ids in [&[0, 0][..], &[1, 0][..], &[99][..]] {
        assert!(matches!(
            diff.prepare_transfer(
                &left,
                &right,
                9,
                ids,
                Direction::ToLeft,
                &Cancellation::default()
            ),
            Err(Error::InvalidBlock)
        ));
    }
}
#[test]
fn line_endings_are_visible_metadata_without_silent_text_normalization() {
    let diff = compare("a\r\nb\r\n", "a\nb\n", Options::default());
    assert!(diff.blocks().is_empty());
    assert!(!diff.byte_identical());
    assert!(diff.rows()[0].terminators_differ);
    let diff = compare("é", "e\u{301}", Options::default());
    assert!(diff.blocks().is_empty());
    assert!(!diff.byte_identical());
}
#[test]
fn declared_work_memory_line_and_output_limits_never_yield_partial_results() {
    for limits in [
        Limits {
            max_work: 2,
            ..Limits::default()
        },
        Limits {
            max_memory_bytes: 1,
            ..Limits::default()
        },
        Limits {
            max_lines: 1,
            ..Limits::default()
        },
    ] {
        assert!(matches!(
            Comparison::compare(
                snapshot("a", "a\nb"),
                snapshot("b", "b\na"),
                1,
                Options::default(),
                limits,
                &Cancellation::default()
            ),
            Err(Error::Limit(_))
        ));
    }
    let left = snapshot("left", "a\nz");
    let right = snapshot("right", "a\nlong\nz");
    let diff = Comparison::compare(
        left.clone(),
        right.clone(),
        9,
        Options::default(),
        Limits {
            max_output_bytes: 3,
            ..Limits::default()
        },
        &Cancellation::default(),
    )
    .unwrap();
    assert!(matches!(
        diff.prepare_transfer(
            &left,
            &right,
            9,
            &[0],
            Direction::ToLeft,
            &Cancellation::default()
        ),
        Err(Error::Limit(_))
    ));
}
#[test]
fn huge_anchored_and_repetitive_cases_are_bounded() {
    let left = (0..40_000)
        .map(|i| format!("line {i}\n"))
        .collect::<String>();
    let right = left.replace("line 20000\n", "changed\n");
    let diff = compare(&left, &right, Options::default());
    assert_eq!(diff.blocks().len(), 1);
    let left = "a\n".repeat(20_000);
    let right = "b\n".repeat(20_000);
    assert!(matches!(
        Comparison::compare(
            snapshot("a", &left),
            snapshot("b", &right),
            1,
            Options::default(),
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::Limit(_))
    ));
}
#[test]
fn active_computation_responds_to_cancellation() {
    let cancel = Cancellation::default();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        Comparison::compare(
            snapshot("a", &"a\n".repeat(14_000)),
            snapshot("b", &"b\n".repeat(14_000)),
            1,
            Options::default(),
            Limits::default(),
            &worker_cancel,
        )
    });
    std::thread::sleep(std::time::Duration::from_millis(5));
    cancel.cancel();
    assert!(matches!(worker.join().unwrap(), Err(Error::Cancelled)));
}

#[test]
fn report_is_bound_escaped_and_bounded_without_writing_sources() {
    let diff = compare("old\nkeep", "new\nkeep", Options::default());
    let report = diff
        .report("left\nlabel", "right", &Cancellation::default())
        .unwrap();
    assert!(report.contains("Left: \"left\\nlabel\""));
    assert!(report.contains("- 1 | old\n+ 1 | new\n"));
    assert!(report.contains("Logical difference blocks: 1"));
    let diff = compare("a\r\n", "a\n", Options::default());
    let report = diff
        .report("left", "right", &Cancellation::default())
        .unwrap();
    assert!(report.contains("Original bytes differ"));
    assert!(report.contains("Line-ending differences: true"));
    let diff = Comparison::compare(
        snapshot("a", "old"),
        snapshot("b", "new"),
        1,
        Options::default(),
        Limits {
            max_report_bytes: 16,
            ..Limits::default()
        },
        &Cancellation::default(),
    )
    .unwrap();
    assert!(matches!(
        diff.report("left", "right", &Cancellation::default()),
        Err(Error::Limit(_))
    ));
}
#[test]
fn many_selected_blocks_use_precomputed_utf16_boundaries() {
    let mut left = String::new();
    let mut right = String::new();
    for i in 0..2000 {
        left.push_str(&format!("😀{i}\nold\n"));
        right.push_str(&format!("😀{i}\nnew\n"));
    }
    let a = snapshot("left", &left);
    let b = snapshot("right", &right);
    let diff = compare(&left, &right, Options::default());
    assert_eq!(diff.blocks().len(), 2000);
    let ids = (0..diff.blocks().len()).collect::<Vec<_>>();
    let plan = diff
        .prepare_transfer(&a, &b, 9, &ids, Direction::ToLeft, &Cancellation::default())
        .unwrap();
    assert_eq!(plan.output(), right);
}

#[test]
fn forty_thousand_line_patience_paths_match_actual_swift_block_summaries() {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Summary {
        mode: String,
        row_count: usize,
        left_count: usize,
        right_count: usize,
        blocks: Vec<ReferenceBlock>,
    }
    let summaries: Vec<Summary> =
        serde_json::from_str(include_str!("fixtures/swift-diff-large.json")).unwrap();
    assert_eq!(summaries.len(), 2);
    let left = (0..40_000)
        .map(|i| format!("line {i}\n"))
        .collect::<String>();
    for summary in summaries {
        let order: Vec<_> = if summary.mode == "rotation" {
            (20_000..40_000).chain(0..20_000).collect()
        } else {
            (0..40_000).collect()
        };
        let right = order
            .into_iter()
            .map(|i| {
                if summary.mode == "spread" && i % 1000 == 0 {
                    format!("changed {i}\n")
                } else {
                    format!("line {i}\n")
                }
            })
            .collect::<String>();
        let diff = compare(&left, &right, Options::default());
        assert_eq!(diff.rows().len(), summary.row_count);
        assert_eq!(
            diff.line_counts(),
            (summary.left_count, summary.right_count)
        );
        assert_eq!(diff.blocks().len(), summary.blocks.len());
        for (block, expected) in diff.blocks().iter().zip(summary.blocks) {
            assert_eq!(block.rows, expected.start..expected.end);
            let kind = match block.kind {
                BlockKind::Changed => "changed",
                BlockKind::OnlyLeft => "onlyLeft",
                BlockKind::OnlyRight => "onlyRight",
            };
            assert_eq!(kind, expected.kind);
        }
    }
}

#[test]
fn pathological_combining_runs_have_an_explicit_normalization_budget() {
    let text = "a".to_owned() + &"\u{301}".repeat(10_000);
    assert!(matches!(
        Comparison::compare(
            snapshot("a", &text),
            snapshot("b", &text),
            1,
            Options::default(),
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::Limit("normalization combining run"))
    ));
}
