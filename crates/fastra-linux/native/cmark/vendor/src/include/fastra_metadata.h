#ifndef FASTRA_METADATA_H
#define FASTRA_METADATA_H
#include "cmark-gfm.h"
#include <stddef.h>
typedef struct { size_t lo, hi, source_lo, source_hi; int identity; } fastra_span;
typedef struct fastra_control fastra_control;
typedef struct { fastra_span *spans; size_t count, capacity, length; int tracked, invalid; fastra_control *control; } fastra_map;
struct fastra_control {
  int (*cancelled)(void *);
  void *context;
  size_t steps, max_steps;
  int status;
  int preserve_footnote_definitions;
  size_t map_steps, mail_map_steps;
  int in_mail_map;
};
struct cmark_parser;
int fastra_parser_check(struct cmark_parser *);
int fastra_map_work(fastra_control *, size_t);
void fastra_consolidate_text_nodes(cmark_node *, struct cmark_parser *);
enum { FASTRA_HTTP=1, FASTRA_WWW=2, FASTRA_MAIL=3, FASTRA_ANGLE=4, FASTRA_EXPLICIT=5 };
void fastra_map_clear(cmark_mem *, fastra_map *);
void fastra_map_append(cmark_mem *, fastra_map *, size_t, size_t, size_t, int);
void fastra_map_slice(cmark_mem *, const fastra_map *, size_t, size_t, fastra_map *);
void fastra_map_join(cmark_mem *, fastra_map *, const fastra_map *);
void fastra_map_trim(cmark_mem *, fastra_map *, size_t, size_t);
int fastra_map_range(const fastra_map *, size_t, size_t, size_t *, size_t *);
void fastra_link_range(cmark_node *, const fastra_map *, size_t, size_t, int);
int fastra_node_literal_metadata(cmark_node *, const fastra_span **, size_t *, size_t *);
int fastra_node_link_metadata(cmark_node *, int *, size_t *, size_t *);
void fastra_inline_text(cmark_node *, void *, size_t, size_t);
void fastra_map_compose(cmark_mem *, const fastra_map *, const fastra_map *, fastra_map *);
void fastra_inline_link(cmark_node *, void *, size_t, size_t, int);
#endif
