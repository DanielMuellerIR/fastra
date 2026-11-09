#include "regex-syntax/runtime/include/tree_sitter/api.h"
#include <time.h>

typedef bool (*Emit)(void *, int32_t, const char *, uint32_t, uint32_t, bool);
typedef bool (*Cancelled)(void *);
extern const TSLanguage *tree_sitter_regex(void);
struct Parse {
    const char *text;
    uint32_t length;
    uint32_t count;
    uint64_t deadline;
    Emit emit;
    Cancelled cancelled;
    void *context;
};
static uint64_t now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return UINT64_MAX;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
static const char *read_text(void *payload, uint32_t byte, TSPoint point, uint32_t *length) {
    (void)point;
    struct Parse *p = payload;
    *length = byte < p->length ? p->length - byte : 0;
    return *length ? p->text + byte : "";
}
static bool stop(TSParseState *state) {
    struct Parse *p = state->payload;
    return p->cancelled(p->context) || now() >= p->deadline;
}
static bool visit(struct Parse *p, TSNode node, int32_t parent, uint32_t depth) {
    if (depth > 256 || p->count >= 65536 || p->cancelled(p->context)) return false;
    int32_t index = (int32_t)p->count++;
    if (!p->emit(p->context, parent, ts_node_type(node), ts_node_start_byte(node),
                 ts_node_end_byte(node), ts_node_is_named(node))) return false;
    for (uint32_t i = 0; i < ts_node_child_count(node); i++) {
        if (!visit(p, ts_node_child(node, i), index, depth + 1)) return false;
    }
    return true;
}
// 1: gültiger Baum, 2: Syntaxfehler, 0: Budget/Abbruch/Allokation.
int32_t fastra_regex_syntax(const char *text, uint32_t length, Emit emit, Cancelled cancelled, void *context) {
    if (length > 65536) return 0;
    TSParser *parser = ts_parser_new();
    if (!parser) return 0;
    if (!ts_parser_set_language(parser, tree_sitter_regex())) { ts_parser_delete(parser); return 0; }
    struct Parse p = { text, length, 0, now() + 200000000, emit, cancelled, context };
    TSInput input = { &p, read_text, TSInputEncodingUTF8, NULL };
    TSParseOptions options = { &p, stop };
    TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, options);
    int32_t result = 0;
    if (tree) {
        TSNode root = ts_tree_root_node(tree);
        result = ts_node_has_error(root) ? 2 : visit(&p, root, -1, 0) ? 1 : 0;
        ts_tree_delete(tree);
    }
    ts_parser_delete(parser);
    return result;
}
