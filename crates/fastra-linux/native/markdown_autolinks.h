#ifndef FASTRA_MARKDOWN_AUTOLINKS_H
#define FASTRA_MARKDOWN_AUTOLINKS_H
#include <stddef.h>
#include "cmark/vendor/src/include/fastra_metadata.h"
typedef struct { size_t start,end; int origin; unsigned char *url,*text; size_t url_length,text_length; fastra_span *spans; size_t span_count; } fastra_atom;
typedef struct { fastra_atom *atoms; size_t count; } fastra_plan;
int fastra_plan_parse(const unsigned char *,size_t,int (*)(void *),void *,fastra_plan *);
void fastra_plan_free(fastra_plan *);
#endif
