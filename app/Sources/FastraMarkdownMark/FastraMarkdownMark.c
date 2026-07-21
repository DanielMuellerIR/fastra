#include "FastraMarkdownMark.h"

#include <stdint.h>
#include <string.h>

/// Liest einen vollständigen Lauf von Gleichheitszeichen. Nur exakt zwei
/// Zeichen werden zum Delimiter; längere Läufe bleiben normaler Text.
static cmark_node *match_mark(cmark_syntax_extension *extension,
                              cmark_parser *parser,
                              cmark_node *parent,
                              unsigned char character,
                              cmark_inline_parser *inline_parser) {
    (void)extension;
    (void)parser;
    (void)parent;

    if (character != '=') {
        return NULL;
    }

    int left_flanking = 0;
    int right_flanking = 0;
    int punctuation_before = 0;
    int punctuation_after = 0;
    char buffer[101];
    int delimiters = cmark_inline_parser_scan_delimiters(
        inline_parser,
        sizeof(buffer) - 1,
        '=',
        &left_flanking,
        &right_flanking,
        &punctuation_before,
        &punctuation_after
    );
    (void)punctuation_before;
    (void)punctuation_after;

    memset(buffer, '=', delimiters);
    buffer[delimiters] = '\0';

    cmark_node *text = cmark_node_new(CMARK_NODE_TEXT);
    if (text == NULL || !cmark_node_set_literal(text, buffer)) {
        cmark_node_free(text);
        return NULL;
    }

    if (delimiters == 2 && (left_flanking || right_flanking)) {
        cmark_inline_parser_push_delimiter(
            inline_parser,
            character,
            left_flanking,
            right_flanking,
            text
        );
    }
    return text;
}

/// Wandelt den Öffner in einen kontrollierten Custom-Inline-Knoten um und
/// verschiebt alle bereits von cmark geparsten Kinder hinein. Dadurch bleiben
/// Fett, Kursiv, Links und Softbreaks innerhalb der Markierung vollwertiges
/// Markdown; der Nutzer kann trotzdem kein eigenes HTML einschleusen.
static delimiter *insert_mark(cmark_syntax_extension *extension,
                              cmark_parser *parser,
                              cmark_inline_parser *inline_parser,
                              delimiter *opener,
                              delimiter *closer) {
    (void)extension;
    (void)parser;

    delimiter *result = closer->next;
    cmark_node *mark = opener->inl_text;

    if (!cmark_node_set_type(mark, CMARK_NODE_CUSTOM_INLINE)
        || !cmark_node_set_on_enter(mark, "<mark>")
        || !cmark_node_set_on_exit(mark, "</mark>")) {
        goto remove_delimiters;
    }

    cmark_node *node = cmark_node_next(mark);
    while (node != NULL && node != closer->inl_text) {
        cmark_node *next = cmark_node_next(node);
        if (!cmark_node_append_child(mark, node)) {
            goto remove_delimiters;
        }
        node = next;
    }
    cmark_node_free(closer->inl_text);

remove_delimiters:
    {
        delimiter *item = closer;
        while (item != NULL && item != opener) {
            delimiter *previous = item->previous;
            cmark_inline_parser_remove_delimiter(inline_parser, item);
            item = previous;
        }
        cmark_inline_parser_remove_delimiter(inline_parser, opener);
    }
    return result;
}

cmark_syntax_extension *fastra_mark_extension_new(void) {
    cmark_syntax_extension *extension = cmark_syntax_extension_new("fastra-mark");
    if (extension == NULL) {
        return NULL;
    }

    cmark_mem *memory = cmark_get_default_mem_allocator();
    cmark_llist *special_characters = cmark_llist_append(
        memory,
        NULL,
        (void *)(uintptr_t)'='
    );
    if (special_characters == NULL) {
        cmark_syntax_extension_free(memory, extension);
        return NULL;
    }

    cmark_syntax_extension_set_match_inline_func(extension, match_mark);
    cmark_syntax_extension_set_inline_from_delim_func(extension, insert_mark);
    cmark_syntax_extension_set_special_inline_chars(extension, special_characters);
    cmark_syntax_extension_set_emphasis(extension, 1);
    return extension;
}

void fastra_mark_extension_free(cmark_syntax_extension *extension) {
    if (extension != NULL) {
        cmark_syntax_extension_free(cmark_get_default_mem_allocator(), extension);
    }
}
