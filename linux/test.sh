#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
test_case=${1:-editor}
case "$test_case" in
  print|printing|printing-busy|printing-corrupt|startup|startup-mixed|startup-open|startup-disable|startup-missing|startup-corrupt|startup-busy|startup-last-close|startup-offscreen|startup-maximized|startup-interrupt-new|startup-interrupt-typing|startup-interrupt-file|startup-interrupt-home|startup-interrupt-project|startup-interrupt-peer|markdown-mode|markdown-mode-busy|markdown-mode-corrupt|markdown-mode-choice-source|markdown-mode-choice-visual|markdown-mode-choice-quit|markdown-preview|markdown-preview-busy|markdown-preview-corrupt|reading-font|reading-font-busy|reading-font-corrupt|reading-font-missing|source-font|source-font-busy|source-font-readonly|source-font-missing|readonly-source|readonly-source-options|readonly-source-print|readonly-source-preview|readonly-source-watch|readonly-source-metadata|readonly-source-metadata-limit|folding|folding-guards|folding-limits|diff|references|references-project|references-hardlinks|references-identity-guards|references-rich|references-guards|references-disk-guards|references-mac|references-unverified|fonts|external-diff-view|diff-interaction|diff-entrypoints|diff-entrypoints-rich|diff-saved|diff-saved-rich|diff-rich|diff-states|diff-guards|diff-palette|diff-export|diff-drop|diff-large|diff-budget|snippet-secondary|snippet-source|snippet-rich|snippet-big|chrome|home|folder-readonly|template-menu|search-sources|search-sources-project|selection-entry|inline-preview|inline-preview-open|single-replace-longer|search-groups|search-groups-open|search-groups-folder|search-groups-project|search-live|search-detail|single-replace|single-replace-secondary|single-replace-open|search-footer|search-footer-open|single-replace-guards|single-replace-guards-open|search-navigation|collection-navigation|markdown-formatting|rich-formatting|search-parity|rich-find|project-scope|linear-paste|git-pull|page-guide|rich-math|eol|eol-rich|eol-noop-close|save-as-eol|save-as-eol-rich|options-focus|options-focus-guards|application-lifecycle|application-quit|application-quit-asset-io|application-quit-folder|editor|markdown-inline|rich|rich-blank-lines|rich-blank-clipboard|rich-blank-typed-copy|rich-image-watch|rich-clipboard|rich-assets|rich-rtf-import|rich-outline|macro-runtime|macro-shell|git-branches|git-switch|git-commit|git-push|git-force-push|save-as|local-control|git-fetch|explanation|four-d-completion|four-d-macros|example|tab-close|tab-close-others|tab-file-drag|tab-file-drag-views|source-appearance|wrap-profiles|search-history|workflow-disk|git-history|desktop-open|goto|workflow-tabs|four-d-transform|titlecase|document|4d|hex|hex-routes|recent-projects|extended-text|options|format-profiles|profile-readiness|display|folder-compare|xpath|workflow|patterns|selection|tabs|folder|recovery|target|target-markdown|target-guards|navigation|outline-fallback|source-sync|code-copy|math-static|rectangle|rectangle-commands|viewer|session-readonly|session-readonly-optout|session-readonly-missing|session-readonly-only|session-optout|session-rich|session-rich-failure) ;;
  *) echo 'Usage: linux/test.sh [print|printing|printing-busy|printing-corrupt|startup|startup-MODE|markdown-mode|markdown-mode-busy|markdown-mode-corrupt|markdown-mode-choice-source|markdown-mode-choice-visual|markdown-mode-choice-quit|markdown-preview|markdown-preview-busy|markdown-preview-corrupt|reading-font|reading-font-busy|reading-font-corrupt|reading-font-missing|source-font|source-font-busy|source-font-readonly|source-font-missing|readonly-source|readonly-source-options|readonly-source-print|readonly-source-preview|readonly-source-watch|readonly-source-metadata|readonly-source-metadata-limit|folding|folding-guards|folding-limits|diff|references|references-project|references-hardlinks|references-identity-guards|references-rich|references-guards|references-disk-guards|references-mac|references-unverified|fonts|external-diff-view|diff-interaction|diff-entrypoints|diff-entrypoints-rich|diff-saved|diff-saved-rich|diff-rich|diff-states|diff-guards|diff-palette|diff-export|diff-drop|diff-large|diff-budget|snippet-secondary|snippet-source|snippet-rich|snippet-big|chrome|home|folder-readonly|template-menu|search-sources|search-sources-project|selection-entry|inline-preview|inline-preview-open|single-replace-longer|search-groups|search-groups-open|search-groups-folder|search-groups-project|search-live|search-detail|single-replace|single-replace-secondary|single-replace-open|search-footer|search-footer-open|single-replace-guards|single-replace-guards-open|search-navigation|collection-navigation|markdown-formatting|rich-formatting|search-parity|rich-find|project-scope|linear-paste|git-pull|page-guide|rich-math|eol|eol-rich|eol-noop-close|save-as-eol|save-as-eol-rich|options-focus|options-focus-guards|application-lifecycle|application-quit|application-quit-asset-io|application-quit-folder|editor|markdown-inline|rich|rich-blank-lines|rich-blank-clipboard|rich-blank-typed-copy|rich-image-watch|rich-clipboard|rich-assets|rich-rtf-import|rich-outline|macro-runtime|macro-shell|git-branches|git-switch|git-commit|git-push|git-force-push|save-as|local-control|git-fetch|explanation|four-d-completion|four-d-macros|example|tab-close|tab-close-others|tab-file-drag|tab-file-drag-views|source-appearance|wrap-profiles|search-history|workflow-disk|git-history|desktop-open|goto|workflow-tabs|four-d-transform|titlecase|document|4d|hex|hex-routes|recent-projects|extended-text|options|format-profiles|profile-readiness|display|folder-compare|xpath|workflow|patterns|selection|tabs|folder|recovery|target|target-markdown|target-guards|navigation|outline-fallback|source-sync|code-copy|math-static|rectangle|rectangle-commands|viewer|session-readonly|session-readonly-optout|session-readonly-missing|session-readonly-only|session-optout|session-rich|session-rich-failure]' >&2; exit 2 ;;
esac
if [[ $test_case == rich-rtf-import && ! -x ${FASTRA_POORMANS_TEXT:-} ]]; then
  echo 'Set FASTRA_POORMANS_TEXT to the verified local PMT launcher for the real RTF import test.' >&2
  exit 2
fi
source "$repo/linux/common.sh"
icu=${FASTRA_ICU_PREFIX:-}
prepare_icu
export_icu
"$repo/linux/build.sh"
if [[ -z ${FASTRA_IO_TEST_ROOT:-} && ${FASTRA_UI_TEST_ROOT:-} == /* && -d ${FASTRA_UI_TEST_ROOT:-} ]]; then
  export FASTRA_IO_TEST_ROOT=$FASTRA_UI_TEST_ROOT
fi
cargo test --locked -p fastra-linux -p fastra-workflow -p fastra-control -p fastra-diff-helper -p fastra-core -p fastra-io -p fastra-search
cargo clippy --locked -p fastra-linux -p fastra-workflow -p fastra-search --all-targets -- -D warnings
# Auf einem eigenen Xvfb-Display starten, niemals ungefragt auf dem Benutzerdesktop.
if [[ ${FASTRA_ISOLATED_DISPLAY:-} != 1 ]]; then
  echo 'Set FASTRA_ISOLATED_DISPLAY=1 with DISPLAY pointing to your isolated Xvfb server to run window tests.' >&2
  exit 2
fi
if [[ ${FASTRA_UI_TEST_ROOT:-} != /* || ! -d ${FASTRA_UI_TEST_ROOT:-} ]]; then
  echo 'Set FASTRA_UI_TEST_ROOT to a temporary test directory on Btrfs or ext4.' >&2
  exit 2
fi
test_home=$(mktemp -d "${TMPDIR:-/tmp}/fastra-linux-ui-test.XXXXXX")
fixture_root=$(mktemp -d "$FASTRA_UI_TEST_ROOT/fastra-linux-ui-fixture.XXXXXX")
trap 'rm -rf -- "$test_home" "$fixture_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$test_home/config" "$test_home/data" "$test_home/cache" "$test_home/runtime" "$test_home/state"
chmod 700 "$test_home/runtime"
# Die eigenständigen Draft-Recovery-Prüfungen sollen nicht zusätzlich die
# automatische Pfadwiederherstellung aus einem vorigen Testprozess erben.
if [[ $test_case != startup && $test_case != startup-* ]]; then
  mkdir -m 700 -p "$test_home/config/fastra-editor"
  printf '%s\n' '{"version":1,"restore":false,"windows":[]}' > "$test_home/config/fastra-editor/startup.json"
  chmod 600 "$test_home/config/fastra-editor/startup.json"
fi

if [[ $test_case == print ]]; then
  printf '%s\n' '{"version":1,"visual":false}' > "$test_home/config/fastra-editor/markdown-mode.json"
  chmod 600 "$test_home/config/fastra-editor/markdown-mode.json"
fi
case "$test_case" in
  print) test_env=(FASTRA_PRINT_SELFTEST=1 "FASTRA_PRINT_TEST_ROOT=${FASTRA_PRINT_TEST_ROOT:-$fixture_root}") ;;
  printing) test_env=(FASTRA_PRINT_PREFERENCES_SELFTEST=normal) ;;
  printing-*) test_env=("FASTRA_PRINT_PREFERENCES_SELFTEST=${test_case#printing-}") ;;
  startup) test_env=(FASTRA_STARTUP_SELFTEST=normal) ;;
  startup-*) test_env=("FASTRA_STARTUP_SELFTEST=${test_case#startup-}") ;;
  references) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=document) ;;
  references-hardlinks) test_env=(FASTRA_REFERENCES_SELFTEST=project-hardlink) ;;
  references-identity-guards) test_env=(FASTRA_REFERENCES_SELFTEST=disk-identity-guards) ;;
  references-project) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=project) ;;
  references-rich) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=rich) ;;
  references-disk-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=disk-guards) ;;
  folding) test_env=(G_DEBUG=fatal-criticals FASTRA_FOLDING_SELFTEST=basic) ;;
  folding-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_FOLDING_SELFTEST=guards) ;;
  folding-limits) test_env=(G_DEBUG=fatal-criticals FASTRA_FOLDING_SELFTEST=limits) ;;
  references-mac) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=mac-reference) ;;
  references-unverified) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=unverified) ;;
  references-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_REFERENCES_SELFTEST=guards) ;;
  fonts) test_env=(G_DEBUG=fatal-criticals FASTRA_FONTS_SELFTEST=1) ;;
  external-diff-view) test_env=(G_DEBUG=fatal-criticals FASTRA_EXTERNAL_DIFF_SELFTEST=1 "FASTRA_EXTERNAL_HELPER=${CARGO_TARGET_DIR:-$repo/target}/debug/fastra-diff") ;;
  diff) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff) ;;
  diff-interaction) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_INTERACTION_SELFTEST=1) ;;
  diff-entrypoints) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_ENTRYPOINTS_SELFTEST=tabs) ;;
  diff-entrypoints-rich) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_ENTRYPOINTS_SELFTEST=tabs-rich) ;;
  diff-saved) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_ENTRYPOINTS_SELFTEST=saved) ;;
  diff-saved-rich) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_ENTRYPOINTS_SELFTEST=saved-rich) ;;
  diff-rich) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_RICH_SELFTEST=1 "FASTRA_DIFF_RICH_VARIANT=${FASTRA_DIFF_RICH_VARIANT:-basic}") ;;
  diff-states) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_STATES_SELFTEST=1) ;;
  diff-palette) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_PALETTE_SELFTEST=1) ;;
  diff-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_GUARDS_SELFTEST=1) ;;
  diff-export) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_EXPORT_SELFTEST=1) ;;
  diff-large) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_LARGE_SELFTEST=1 "FASTRA_DIFF_LARGE_ROWS=${FASTRA_DIFF_LARGE_ROWS:-40000}") ;;
  diff-budget) test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_LARGE_SELFTEST=1 FASTRA_DIFF_LARGE_ROWS=200000 FASTRA_DIFF_LARGE_BUDGET=1) ;;
  diff-drop)
    python3 - "$repo/crates/fastra-linux/src/diff_view/drag_producer.c" "$test_home/comparison-drag-producer" <<'PY_DIFF_FIXTURE'
import shlex, subprocess, sys
flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "gtk4"], text=True))
subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", sys.argv[1], "-o", sys.argv[2], *flags], check=True)
PY_DIFF_FIXTURE
    test_env=(G_DEBUG=fatal-criticals FASTRA_TOOL_SELFTEST=diff FASTRA_DIFF_DROP_SELFTEST=1 "FASTRA_DIFF_DROP_PRODUCER=$test_home/comparison-drag-producer") ;;
  snippet-secondary) test_env=(G_DEBUG=fatal-criticals FASTRA_WORKFLOW_SELFTEST=1 FASTRA_SNIPPET_SELFTEST=secondary) ;;
  snippet-source) test_env=(G_DEBUG=fatal-criticals FASTRA_WORKFLOW_SELFTEST=1 FASTRA_SNIPPET_SELFTEST=1) ;;
  snippet-rich) test_env=(G_DEBUG=fatal-criticals FASTRA_WORKFLOW_SELFTEST=1 FASTRA_SNIPPET_SELFTEST=rich) ;;
  snippet-big) test_env=(G_DEBUG=fatal-criticals FASTRA_WORKFLOW_SELFTEST=1 FASTRA_SNIPPET_SELFTEST=big) ;;
  folder-readonly) test_env=(G_DEBUG=fatal-criticals FASTRA_FOLDER_READONLY_SELFTEST=1) ;;
  template-menu) test_env=(G_DEBUG=fatal-criticals FASTRA_TEMPLATE_MENU_SELFTEST=1) ;;
  search-sources) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_SOURCES_SELFTEST=folder) ;;
  search-sources-project) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_SOURCES_SELFTEST=project) ;;
  selection-entry) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_SELECTION_SELFTEST=1) ;;
  inline-preview) test_env=(G_DEBUG=fatal-criticals FASTRA_INLINE_PREVIEW_SELFTEST=file) ;;
  inline-preview-open) test_env=(G_DEBUG=fatal-criticals FASTRA_INLINE_PREVIEW_SELFTEST=open) ;;
  single-replace-longer) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=longer) ;;
  search-groups) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_GROUPS_SELFTEST=0) ;;
  search-groups-open) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_GROUPS_SELFTEST=1) ;;
  search-groups-folder) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_GROUPS_SELFTEST=2) ;;
  search-groups-project) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_GROUPS_SELFTEST=3) ;;
  chrome) test_env=(FASTRA_CHROME_SELFTEST=1) ;;
  home) test_env=(FASTRA_HOME_SELFTEST=1) ;;
  search-footer) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=footer) ;;
  search-footer-open) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=footer-open) ;;
  single-replace-secondary) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=secondary) ;;
  single-replace) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=file) ;;
  single-replace-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=guards) ;;
  single-replace-guards-open) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=guards-open) ;;
  single-replace-open) test_env=(G_DEBUG=fatal-criticals FASTRA_SINGLE_REPLACE_SELFTEST=open) ;;
  search-detail) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_DETAIL_SELFTEST=1) ;;
  search-live) test_env=(G_DEBUG=fatal-criticals FASTRA_SEARCH_LIVE_SELFTEST=1) ;;
  search-navigation) test_env=(FASTRA_SEARCH_NAVIGATION_SELFTEST=1) ;;
  collection-navigation) test_env=(FASTRA_COLLECTION_NAVIGATION_SELFTEST=1) ;;
  markdown-formatting) test_env=(FASTRA_MARKDOWN_INLINE_SELFTEST=1 FASTRA_MARKDOWN_FORMATTING_SELFTEST=1) ;;
  rich-formatting) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_FORMATTING_SELFTEST=1) ;;
  project-scope) test_env=(FASTRA_PROJECT_SCOPE_SELFTEST=1 "FASTRA_PROJECT_FIXTURE=$fixture_root") ;;
  search-parity) test_env=(FASTRA_SEARCH_PARITY_SELFTEST=1) ;;
  rich-find) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_FIND_SELFTEST=1) ;;
  tab-file-drag|tab-file-drag-views)
    python3 - "$repo/crates/fastra-linux/src/tab_close/drag_receiver.c" "$test_home/tab-file-drag-receiver" <<'PY_FIXTURE'
import shlex, subprocess, sys
flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "gtk4"], text=True))
subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", sys.argv[1], "-o", sys.argv[2], *flags], check=True)
PY_FIXTURE
    test_env=(FASTRA_TAB_CLOSE_SELFTEST=1 "FASTRA_TAB_FILE_DRAG_RECEIVER=$test_home/tab-file-drag-receiver")
    if [[ $test_case == tab-file-drag-views ]]; then
      test_env+=(FASTRA_TAB_FILE_DRAG_VIEWS_SELFTEST=1 "FASTRA_TAB_FILE_DRAG_VIEWS_CASE=${FASTRA_TAB_FILE_DRAG_VIEWS_CASE:-png}")
    else
      test_env+=(FASTRA_TAB_FILE_DRAG_SELFTEST=1)
    fi ;;
  source-appearance) test_env=(FASTRA_SOURCE_APPEARANCE_SELFTEST=1 "FASTRA_SOURCE_APPEARANCE_EXPECT=${FASTRA_SOURCE_APPEARANCE_EXPECT:-light}") ;;
  wrap-profiles) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_WRAP_PROFILE_SELFTEST=1 "FASTRA_WRAP_EXPECT_CAPABLE=${FASTRA_WRAP_EXPECT_CAPABLE:-0}") ;;
  linear-paste) test_env=(FASTRA_LINEAR_PASTE_SELFTEST=1 FASTRA_LINEAR_PASTE_CASE=line) ;;
  git-pull) test_env=(FASTRA_GIT_PULL_SELFTEST=basic) ;;
  page-guide) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_PAGE_GUIDE_SELFTEST=1 "FASTRA_TOOL_WIDTH=${FASTRA_TOOL_WIDTH:-760}") ;;
  rich-math) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_MATH_SELFTEST=1) ;;
  eol) test_env=(FASTRA_EOL_SELFTEST=1 FASTRA_QUIT_TEST_DELAY_SAVE_MS=800) ;;
  eol-rich) test_env=(FASTRA_EOL_SELFTEST=1 FASTRA_EOL_RICH_SELFTEST=1 FASTRA_QUIT_TEST_DELAY_SAVE_MS=1500) ;;
  eol-noop-close) test_env=(FASTRA_EOL_SELFTEST=1 FASTRA_EOL_NOOP_CLOSE_SELFTEST=1) ;;
  save-as-eol) test_env=(FASTRA_SAVE_AS_SELFTEST=1 FASTRA_SAVE_AS_EOL_SELFTEST=1) ;;
  save-as-eol-rich) test_env=(FASTRA_SAVE_AS_SELFTEST=1 FASTRA_SAVE_AS_EOL_SELFTEST=1 FASTRA_SAVE_AS_EOL_RICH=1) ;;
  options-focus) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_OPTIONS_FOCUS_SELFTEST=1) ;;
  options-focus-guards) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_OPTIONS_FOCUS_SELFTEST=1 FASTRA_OPTIONS_FOCUS_GUARDS_SELFTEST=1) ;;
  application-quit-folder) test_env=("FASTRA_LIFECYCLE_SELFTEST_DIR=$fixture_root" "FASTRA_FOLDER_QUIT_TEST_DIR=$fixture_root" FASTRA_QUIT_FOLDER_SELFTEST=1 FASTRA_FOLDER_GUARD_FIXED=1) ;;
  application-quit-asset-io) test_env=("FASTRA_LIFECYCLE_SELFTEST_DIR=$fixture_root" "FASTRA_QUIT_ASSET_IO_TEST_DIR=$fixture_root" FASTRA_QUIT_ASSET_IO_SELFTEST=1 FASTRA_ASSET_GUARD_FIXED=1 FASTRA_ASSET_MAIN_POSTCHECK=1) ;;
  application-quit) test_env=("FASTRA_LIFECYCLE_SELFTEST_DIR=$fixture_root" FASTRA_QUIT_SELFTEST=1 FASTRA_QUIT_TEST_DELAY_SAVE_MS=700) ;;
  application-lifecycle) test_env=("FASTRA_LIFECYCLE_SELFTEST_DIR=$fixture_root") ;;
  editor) test_env=(FASTRA_UI_SELFTEST=1) ;;
  markdown-inline) test_env=(FASTRA_MARKDOWN_INLINE_SELFTEST=1 "FASTRA_INLINE_PANE=${FASTRA_INLINE_PANE:-0}") ;;
  git-force-push) test_env=(FASTRA_GIT_PUSH_SELFTEST=1 FASTRA_GIT_FORCE_PUSH_SELFTEST=1) ;;
  save-as) test_env=(FASTRA_SAVE_AS_SELFTEST=1) ;;
  git-commit) test_env=(FASTRA_GIT_COMMIT_SELFTEST=1) ;;
  rich) test_env=(FASTRA_RICH_SELFTEST=1) ;;
  rich-blank-lines) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_BLANK_LINES_SELFTEST=1) ;;
  rich-blank-clipboard) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_BLANK_CLIPBOARD_SELFTEST=1) ;;
  rich-blank-typed-copy) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_BLANK_CLIPBOARD_SELFTEST=1 FASTRA_BLANK_TYPED_COPY_SELFTEST=1) ;;
  rich-image-watch) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_IMAGE_WATCH_SELFTEST=1) ;;
  rich-clipboard) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_CLIPBOARD_SELFTEST=1) ;;
  rich-rtf-import) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_ASSET_SELFTEST=1 FASTRA_RTF_REAL_IMPORT=1) ;;
  rich-assets) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_ASSET_SELFTEST=1) ;;
  rich-outline) test_env=(FASTRA_RICH_SELFTEST=1 FASTRA_RICH_OUTLINE_SELFTEST=1) ;;
  macro-runtime) test_env=(FASTRA_4D_MACRO_RUNTIME_SELFTEST=1 "FASTRA_MACRO_FIXTURE=$fixture_root") ;;
  macro-shell) test_env=(FASTRA_4D_MACRO_SHELL_SELFTEST=1 "FASTRA_MACRO_FIXTURE=$fixture_root" "FASTRA_MACRO_TEST_ENGINE=$repo/crates/fastra-linux/tests/tool4d/macro-shell") ;;
  git-switch) test_env=(FASTRA_GIT_SWITCH_SELFTEST=1) ;;
  git-push) test_env=(FASTRA_GIT_PUSH_SELFTEST=1) ;;
  git-branches) test_env=(FASTRA_GIT_BRANCHES_SELFTEST=1) ;;
  git-fetch) test_env=(FASTRA_GIT_FETCH_SELFTEST=1) ;;
  local-control) test_env=(FASTRA_LOCAL_CONTROL_SELFTEST=1 "FASTRA_CONTROL_BINARY=${CARGO_TARGET_DIR:-$repo/target}/debug/fastra-control") ;;
  explanation) test_env=(FASTRA_EXPLANATION_SELFTEST=1) ;;
  four-d-completion) test_env=(FASTRA_4D_COMPLETION_SELFTEST=1) ;;
  four-d-macros) test_env=(FASTRA_4D_MACROS_SELFTEST=1 "FASTRA_MACRO_FIXTURE=$fixture_root") ;;
  example) test_env=(FASTRA_EXAMPLE_SELFTEST=1) ;;
  tab-close-others) test_env=(FASTRA_TAB_CLOSE_SELFTEST=1 FASTRA_TAB_CLOSE_OTHERS_SELFTEST=minimal "FASTRA_TOOL_WIDTH=${FASTRA_TOOL_WIDTH:-760}") ;;
  tab-close) test_env=(FASTRA_TAB_CLOSE_SELFTEST=1) ;;
  search-history) test_env=(FASTRA_SEARCH_HISTORY_SELFTEST=1) ;;
  git-history) test_env=(FASTRA_GIT_HISTORY_SELFTEST=1) ;;
  desktop-open) test_env=(FASTRA_DESKTOP_OPEN_SELFTEST=1) ;;
  goto) test_env=(FASTRA_GOTO_SELFTEST=1) ;;
  document) test_env=(FASTRA_DOCUMENT_SELFTEST=1) ;;
  4d) test_env=(FASTRA_4D_SELFTEST=1) ;;
  recent-projects) test_env=(FASTRA_RECENT_PROJECTS_SELFTEST=1) ;;
  hex-routes) test_env=(FASTRA_HEX_ROUTES_SELFTEST=1) ;;
  hex) test_env=(FASTRA_HEX_SELFTEST=1) ;;
  format-profiles) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_PROFILE_SELFTEST=1 "FASTRA_TOOL_WIDTH=${FASTRA_TOOL_WIDTH:-760}") ;;
  profile-readiness) test_env=(FASTRA_OPTIONS_SELFTEST=1 FASTRA_PROFILE_READINESS_SELFTEST=1 "FASTRA_TOOL_WIDTH=${FASTRA_TOOL_WIDTH:-760}") ;;
  options) test_env=(FASTRA_OPTIONS_SELFTEST=1) ;;
  display) test_env=(FASTRA_DISPLAY_SELFTEST=1) ;;
  folder-compare) test_env=(FASTRA_FOLDER_COMPARE_SELFTEST=1) ;;
  xpath) test_env=(FASTRA_XPATH_SELFTEST=1) ;;
  extended-text) test_env=(FASTRA_EXTENDED_TEXT_SELFTEST=1) ;;
  titlecase) test_env=(FASTRA_TITLECASE_SELFTEST=1) ;;
  four-d-transform) test_env=(FASTRA_4D_TRANSFORM_SELFTEST=1) ;;
  workflow-tabs) test_env=(FASTRA_WORKFLOW_SELFTEST=1 FASTRA_WORKFLOW_TABS_SELFTEST=1) ;;
  workflow-disk) test_env=(FASTRA_WORKFLOW_SELFTEST=1 FASTRA_WORKFLOW_DISK_SELFTEST=1) ;;
  workflow) test_env=(FASTRA_WORKFLOW_SELFTEST=1) ;;
  patterns) test_env=(FASTRA_PATTERN_SELFTEST=1) ;;
  selection) test_env=(FASTRA_SELECTION_SELFTEST=1) ;;
  tabs) test_env=(FASTRA_TABS_SELFTEST=1) ;;
  folder) test_env=(FASTRA_FOLDER_SELFTEST=1) ;;
  recovery) test_env=(FASTRA_RECOVERY_SELFTEST=1) ;;
  target) test_env=(G_DEBUG=fatal-criticals FASTRA_TARGET_SELFTEST=1) ;;
  target-markdown) test_env=(G_DEBUG=fatal-criticals FASTRA_TARGET_SELFTEST=markdown) ;;
  target-guards) test_env=(G_DEBUG=fatal-criticals FASTRA_TARGET_SELFTEST=guards) ;;
  navigation) test_env=(FASTRA_NAVIGATION_SELFTEST=1) ;;
  outline-fallback) test_env=(FASTRA_NAVIGATION_SELFTEST=1 FASTRA_OUTLINE_FALLBACK_SELFTEST=1) ;;
  source-sync) test_env=(FASTRA_NAVIGATION_SELFTEST=1 FASTRA_SOURCE_SYNC_SELFTEST=1) ;;
  math-static) test_env=(FASTRA_CODE_COPY_SELFTEST=1 FASTRA_MATH_STATIC_SELFTEST=1 FASTRA_MATH_STATIC_REVIEW_SELFTEST=1) ;;
  code-copy) test_env=(FASTRA_CODE_COPY_SELFTEST=1) ;;
  rectangle-commands) test_env=(FASTRA_RECTANGLE_SELFTEST=1 FASTRA_RECTANGLE_COMMANDS_SELFTEST=1) ;;
  rectangle) test_env=(FASTRA_RECTANGLE_SELFTEST=1) ;;
  readonly-source-metadata|readonly-source-metadata-limit)
    cc -std=c11 -Wall -Wextra -Werror -shared -fPIC "$repo/crates/fastra-linux/tests/fixtures/deny-readonly-xattrs.c" -ldl -o "$test_home/readonly-deny-xattr.so"
    test_env=("LD_PRELOAD=$test_home/readonly-deny-xattr.so")
    if [[ $test_case == readonly-source-metadata-limit ]]; then
      test_env+=(FASTRA_READONLY_SOURCE_SELFTEST=metadata-limit FASTRA_TEST_XATTR_LIMIT=1)
    else
      test_env+=(FASTRA_READONLY_SOURCE_SELFTEST=metadata)
    fi ;;
  markdown-mode) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=normal) ;;
  markdown-mode-busy) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=busy) ;;
  markdown-mode-corrupt) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=corrupt) ;;
  markdown-mode-choice-source) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=choice-source) ;;
  markdown-mode-choice-visual) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=choice-visual) ;;
  markdown-mode-choice-quit) test_env=(FASTRA_MARKDOWN_MODE_SELFTEST=choice-quit) ;;
  markdown-preview) test_env=(FASTRA_MARKDOWN_PREVIEW_SELFTEST=normal) ;;
  markdown-preview-busy) test_env=(FASTRA_MARKDOWN_PREVIEW_SELFTEST=busy) ;;
  markdown-preview-corrupt) test_env=(FASTRA_MARKDOWN_PREVIEW_SELFTEST=corrupt) ;;
  reading-font) test_env=(FASTRA_READING_FONT_SELFTEST=normal) ;;
  reading-font-busy) test_env=(FASTRA_READING_FONT_SELFTEST=busy) ;;
  reading-font-corrupt) test_env=(FASTRA_READING_FONT_SELFTEST=corrupt) ;;
  reading-font-missing) test_env=(FASTRA_READING_FONT_SELFTEST=missing) ;;
  source-font-busy) test_env=(FASTRA_SOURCE_FONT_SELFTEST=busy) ;;
  source-font) test_env=(FASTRA_SOURCE_FONT_SELFTEST=normal) ;;
  source-font-readonly) test_env=(FASTRA_SOURCE_FONT_SELFTEST=readonly) ;;
  source-font-missing) test_env=(FASTRA_SOURCE_FONT_SELFTEST=missing) ;;
  readonly-source-options) test_env=(FASTRA_READONLY_SOURCE_SELFTEST=options) ;;
  readonly-source-print) test_env=(FASTRA_READONLY_SOURCE_SELFTEST=print) ;;
  readonly-source-preview) test_env=(FASTRA_READONLY_SOURCE_SELFTEST=preview) ;;
  readonly-source-watch) test_env=(FASTRA_READONLY_SOURCE_SELFTEST=watch) ;;
  readonly-source) test_env=(FASTRA_READONLY_SOURCE_SELFTEST=1) ;;
  viewer) test_env=(FASTRA_VIEWER_SELFTEST=1) ;;
  session-*) test_env=("FASTRA_SESSION_SELFTEST=${test_case#session-}" "FASTRA_SESSION_FIXTURE=$fixture_root") ;;
esac
case "$test_case" in
  folder-readonly|template-menu|search-groups*|search-sources*|search-live|search-detail|inline-preview*|single-replace*|search-footer*|selection-entry|selection)
    [[ -z ${FASTRA_SEARCH_LAYOUT_WIDTH:-} ]] || test_env+=("FASTRA_SEARCH_LAYOUT_WIDTH=$FASTRA_SEARCH_LAYOUT_WIDTH") ;;
esac
case "$test_case" in
  search-groups*) [[ -z ${FASTRA_CAPTURE_STRESS:-} ]] || test_env+=("FASTRA_CAPTURE_STRESS=$FASTRA_CAPTURE_STRESS") ;;
esac
test_unset=()
for name in FASTRA_PRINT_PREFERENCES_SELFTEST FASTRA_STARTUP_SELFTEST FASTRA_DIFF_PALETTE_SELFTEST FASTRA_SOURCE_FONT_SELFTEST FASTRA_SOURCE_FONT_PHASE FASTRA_REFERENCES_SELFTEST FASTRA_FONTS_SELFTEST FASTRA_EXTERNAL_DIFF_SELFTEST FASTRA_EXTERNAL_HELPER FASTRA_DIFF_ENTRYPOINTS_SELFTEST FASTRA_DIFF_INTERACTION_SELFTEST FASTRA_DIFF_INTERACTION_PHASE FASTRA_DIFF_LARGE_BUDGET FASTRA_DIFF_RICH_VARIANT FASTRA_DIFF_LARGE_ROWS FASTRA_DIFF_LARGE_SELFTEST FASTRA_DIFF_DROP_PRODUCER FASTRA_DIFF_DROP_SELFTEST FASTRA_DIFF_EXPORT_SELFTEST FASTRA_DIFF_GUARDS_SELFTEST FASTRA_DIFF_STATES_SELFTEST FASTRA_DIFF_RICH_SELFTEST FASTRA_TARGET_SELFTEST FASTRA_OUTLINE_FALLBACK_SELFTEST FASTRA_FOLDER_READONLY_SELFTEST FASTRA_TEMPLATE_MENU_SELFTEST FASTRA_GROUP_LAYOUT_ONLY FASTRA_SEARCH_SOURCES_SELFTEST FASTRA_SEARCH_SELECTION_SELFTEST FASTRA_INLINE_PREVIEW_SELFTEST FASTRA_CAPTURE_STRESS FASTRA_SEARCH_GROUPS_SELFTEST FASTRA_SINGLE_REPLY_DELAY_MS FASTRA_SINGLE_REPLACE_SELFTEST FASTRA_SEARCH_DETAIL_SELFTEST FASTRA_SEARCH_LAYOUT_WIDTH FASTRA_SEARCH_LIVE_SELFTEST FASTRA_SEARCH_NAVIGATION_SELFTEST FASTRA_COLLECTION_NAVIGATION_SELFTEST FASTRA_MARKDOWN_FORMATTING_SELFTEST FASTRA_RICH_FORMATTING_SELFTEST FASTRA_HOME_SELFTEST FASTRA_SEARCH_PARITY_SELFTEST FASTRA_RICH_FIND_SELFTEST FASTRA_CHROME_SELFTEST FASTRA_AUTOINDENT_GATE_CASE FASTRA_INLINE_PANE FASTRA_MARKDOWN_INLINE_SELFTEST FASTRA_TAB_FILE_DRAG_VIEWS_SELFTEST FASTRA_TAB_FILE_DRAG_VIEWS_CASE FASTRA_TAB_FILE_DRAG_SELFTEST FASTRA_TAB_FILE_DRAG_RECEIVER FASTRA_SOURCE_APPEARANCE_SELFTEST FASTRA_SOURCE_APPEARANCE_EXPECT FASTRA_WRAP_PROFILE_SELFTEST FASTRA_WRAP_EXPECT_CAPABLE FASTRA_LINEAR_PASTE_SELFTEST FASTRA_LINEAR_PASTE_CASE FASTRA_LINEAR_PASTE_DELAY_MS FASTRA_GIT_PULL_SELFTEST FASTRA_GIT_PULL_RECEIPT_TEST_DIR FASTRA_PAGE_GUIDE_SELFTEST FASTRA_GUIDE_DELAY_SELFTEST FASTRA_GUIDE_RESTART_SELFTEST FASTRA_EOL_RICH_MATH_SELFTEST FASTRA_SAVE_AS_EOL_MATH_SELFTEST FASTRA_RICH_MATH_SELFTEST FASTRA_EOL_SELFTEST FASTRA_EOL_RICH_SELFTEST FASTRA_EOL_NOOP_CLOSE_SELFTEST FASTRA_EOL_CLOSE_SCOPE FASTRA_EOL_CLOSE_RICH FASTRA_SESSION_EOL_SELFTEST FASTRA_SAVE_AS_EOL_SELFTEST FASTRA_SAVE_AS_EOL_RICH FASTRA_OPTIONS_FOCUS_SELFTEST FASTRA_OPTIONS_FOCUS_GUARDS_SELFTEST FASTRA_PROFILE_SELFTEST FASTRA_PROFILE_READINESS_SELFTEST FASTRA_PROFILE_RESTART_SELFTEST FASTRA_PROFILE_WRITE_TEST_DIR FASTRA_MATH_STATIC_SELFTEST FASTRA_MATH_STATIC_REVIEW_SELFTEST FASTRA_MATH_EOL FASTRA_RECTANGLE_COMMANDS_SELFTEST FASTRA_RECTANGLE_COMMAND_EOL FASTRA_RECTANGLE_COMMAND_UNICODE FASTRA_RECTANGLE_COMMAND_WRAP FASTRA_TAB_CLOSE_OTHERS_SELFTEST FASTRA_SOURCE_SYNC_SELFTEST FASTRA_CODE_COPY_SELFTEST FASTRA_RICH_BLANK_CLIPBOARD_SELFTEST FASTRA_BLANK_TYPED_COPY_SELFTEST FASTRA_RICH_BLANK_LINES_SELFTEST FASTRA_QUIT_FOLDER_SELFTEST FASTRA_FOLDER_QUIT_TEST_DIR FASTRA_FOLDER_GUARD_FIXED FASTRA_QUIT_ASSET_IO_SELFTEST FASTRA_QUIT_ASSET_IO_TEST_DIR FASTRA_ASSET_GUARD_FIXED FASTRA_ASSET_MAIN_POSTCHECK FASTRA_GIT_FORCE_PUSH_SELFTEST FASTRA_SAVE_AS_SELFTEST FASTRA_QUIT_SELFTEST FASTRA_QUIT_TEST_DELAY_SAVE_MS FASTRA_QUIT_TEST_DELAY_SESSION_MS FASTRA_QUIT_TEST_DELAY_RICH_MS FASTRA_GIT_COMMIT_SELFTEST FASTRA_RICH_IMAGE_WATCH_SELFTEST FASTRA_RTF_REAL_IMPORT FASTRA_RICH_ASSET_SELFTEST FASTRA_GIT_SWITCH_SELFTEST FASTRA_LIFECYCLE_SELFTEST_DIR FASTRA_GIT_PUSH_SELFTEST FASTRA_RICH_CLIPBOARD_SELFTEST FASTRA_RICH_OUTLINE_SELFTEST FASTRA_4D_MACRO_SHELL_SELFTEST FASTRA_4D_MACRO_RUNTIME_SELFTEST FASTRA_GIT_BRANCHES_SELFTEST FASTRA_LOCAL_CONTROL_SELFTEST FASTRA_GIT_FETCH_SELFTEST FASTRA_EXPLANATION_SELFTEST FASTRA_4D_COMPLETION_SELFTEST FASTRA_4D_MACROS_SELFTEST FASTRA_TAB_CLOSE_SELFTEST FASTRA_EXAMPLE_SELFTEST FASTRA_SEARCH_HISTORY_SELFTEST FASTRA_WORKFLOW_DISK_SELFTEST FASTRA_GIT_HISTORY_SELFTEST FASTRA_DESKTOP_OPEN_SELFTEST FASTRA_GOTO_SELFTEST FASTRA_WORKFLOW_TABS_SELFTEST FASTRA_WORKFLOW_TABS_LOCALE_SELFTEST FASTRA_4D_RUNTIME_SELFTEST FASTRA_TITLECASE_SELFTEST FASTRA_TITLECASE_EXPECT_LOCALE FASTRA_4D_TRANSFORM_SELFTEST FASTRA_DOCUMENT_SELFTEST FASTRA_RECENT_PROJECTS_SELFTEST FASTRA_HEX_ROUTES_SELFTEST FASTRA_HEX_SELFTEST FASTRA_4D_SELFTEST FASTRA_EXTENDED_TEXT_SELFTEST FASTRA_XPATH_SELFTEST FASTRA_DESKTOP_SMOKE FASTRA_DISPLAY_SELFTEST FASTRA_FOLDER_COMPARE_SELFTEST FASTRA_SELECTION_SELFTEST FASTRA_OPTIONS_SELFTEST FASTRA_PRINT_SELFTEST FASTRA_PROJECT_SCOPE_SELFTEST FASTRA_PATTERN_SELFTEST FASTRA_WORKFLOW_SELFTEST FASTRA_UI_SELFTEST FASTRA_TABS_SELFTEST FASTRA_FOLDER_SELFTEST FASTRA_RECOVERY_SELFTEST FASTRA_NAVIGATION_SELFTEST FASTRA_RECTANGLE_SELFTEST FASTRA_VIEWER_SELFTEST FASTRA_SESSION_SELFTEST FASTRA_PROJECT_SELFTEST FASTRA_TOOL_SELFTEST FASTRA_RICH_SELFTEST; do
  test_unset+=(-u "$name")
done
test_command=("${CARGO_TARGET_DIR:-$repo/target}/debug/fastra-linux")
if [[ $test_case == external-diff-view ]]; then
  cargo build --locked -p fastra-diff-helper
  test_command+=(--external-diff-service)
fi
if [[ $test_case == printing || $test_case == printing-* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/printing.py" "${test_command[0]}")
fi
if [[ $test_case == startup || $test_case == startup-* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/startup.py" "${test_command[0]}")
fi
if [[ $test_case == application-lifecycle || $test_case == application-quit || $test_case == application-quit-asset-io || $test_case == application-quit-folder ]]; then
  test_command=(python3 "$repo/tools/linux-probes/local-control/application-lifecycle.py" "${test_command[0]}")
fi
if [[ $test_case == markdown-mode* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/markdown-mode.py" "${test_command[0]}")
fi
if [[ $test_case == markdown-preview* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/markdown-preview.py" "${test_command[0]}")
fi
if [[ $test_case == reading-font* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/reading-font.py" "${test_command[0]}")
fi
if [[ $test_case == source-font* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/source-font.py" "${test_command[0]}")
fi
if [[ $test_case == session-readonly* ]]; then
  test_command=(python3 "$repo/tools/linux-probes/session-readonly.py" "${test_command[0]}")
fi
timeout 120s env "${test_unset[@]}" -u FASTRA_MACRO_FIXTURE -u WAYLAND_DISPLAY -u WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS \
  "${test_env[@]}" "FASTRA_UI_TEST_ROOT=$fixture_root" "FASTRA_DOCUMENT_TEST_ROOT=$fixture_root" "FASTRA_RICH_TEST_ROOT=$fixture_root" "FASTRA_SAVE_AS_TEST_ROOT=$fixture_root" \
  "HOME=$test_home" "XDG_STATE_HOME=$test_home/state" "XDG_CONFIG_HOME=$test_home/config" \
  "XDG_DATA_HOME=$test_home/data" "XDG_CACHE_HOME=$test_home/cache" \
  "XDG_RUNTIME_DIR=$test_home/runtime" GSETTINGS_BACKEND=memory \
  GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GIO_USE_VFS=local QT_QPA_PLATFORM=xcb \
  dbus-run-session --config-file="$repo/linux/test-dbus.conf" -- "${test_command[@]}"
