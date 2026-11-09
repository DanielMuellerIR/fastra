#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <cmark-gfm.h>
#include <cmark-gfm-extension_api.h>
#include <cmark-gfm-core-extensions.h>
#include <parser.h>
#include <fastra_metadata.h>
#define SOURCE_LIMIT (16*1024*1024)
#define OUTPUT_LIMIT (16*1024*1024)
#define LINK_LIMIT 100000
#define STEP_LIMIT 500000

#include "markdown_autolinks.h"
static pthread_once_t initialized=PTHREAD_ONCE_INIT;
static void initialize(void) { cmark_gfm_core_extensions_ensure_registered(); }
void fastra_plan_free(fastra_plan *plan) {
  for(size_t i=0;i<plan->count;i++){free(plan->atoms[i].url);free(plan->atoms[i].text);free(plan->atoms[i].spans);}
  free(plan->atoms);plan->atoms=NULL;plan->count=0;
}
/* Status: 0 Erfolg, 1 Abbruch, 2 Grenze, 3 ungültige Provenienz. */
int fastra_plan_parse(const unsigned char *source,size_t length,int (*cancelled)(void *),void *context,fastra_plan *out) {
  memset(out,0,sizeof *out);
  if(length>SOURCE_LIMIT)return 2;
  if(memchr(source,0,length)||memchr(source,'\r',length))return 3;
  if(cancelled && cancelled(context))return 1;
  pthread_once(&initialized,initialize);
  cmark_parser *parser=cmark_parser_new(CMARK_OPT_FOOTNOTES);
  fastra_control control={.cancelled=cancelled,.context=context,.max_steps=STEP_LIMIT,.preserve_footnote_definitions=1};parser->fastra_control=&control;
  const char *extensions[]={"autolink","strikethrough","tagfilter","tasklist","table"};
  for(size_t i=0;i<5;i++)cmark_parser_attach_syntax_extension(parser,cmark_find_syntax_extension(extensions[i]));
  cmark_parser_feed(parser,(const char *)source,length);
  cmark_node *root=cmark_parser_finish(parser);int status=control.status;
  if(status){cmark_node_free(root);cmark_parser_free(parser);return status;}
  cmark_iter *iter=cmark_iter_new(root);cmark_event_type event;size_t capacity=0,total=0;
  while((event=cmark_iter_next(iter))!=CMARK_EVENT_DONE) {
    if(!fastra_parser_check(parser)){status=control.status;break;}
    cmark_node *node=cmark_iter_get_node(iter);
    if(event!=CMARK_EVENT_ENTER||cmark_node_get_type(node)!=CMARK_NODE_LINK)continue;
    int origin;size_t start,end;
    if(!fastra_node_link_metadata(node,&origin,&start,&end)||end>length){status=3;break;}
    if(origin>FASTRA_MAIL)continue;
    int image=0;
    for(cmark_node *parent=cmark_node_parent(node);parent;parent=cmark_node_parent(parent))if(cmark_node_get_type(parent)==CMARK_NODE_IMAGE)image=1;
    if(image)continue;
    cmark_node *child=cmark_node_first_child(node);
    if(!child||cmark_node_get_type(child)!=CMARK_NODE_TEXT||cmark_node_next(child)){status=3;break;}
    const fastra_span *spans;size_t span_count,span_length;
    if(!fastra_node_literal_metadata(child,&spans,&span_count,&span_length)){status=3;break;}
    const char *url=cmark_node_get_url(node),*text=cmark_node_get_literal(child);size_t a=strlen(url),b=strlen(text);
    if(out->count>=LINK_LIMIT||a>OUTPUT_LIMIT-total||b>OUTPUT_LIMIT-total-a){status=2;break;}
    if(span_length!=b||span_count>(OUTPUT_LIMIT-total-a-b)/sizeof(fastra_span)){status=2;break;}
    total+=a+b+span_count*sizeof(fastra_span);
    if(out->count==capacity){size_t next=capacity?capacity*2:16;fastra_atom *atoms=realloc(out->atoms,next*sizeof *atoms);if(!atoms){status=2;break;}out->atoms=atoms;capacity=next;}
    unsigned char *u=malloc(a?a:1),*t=malloc(b?b:1);if(!u||!t){free(u);free(t);status=2;break;}
    fastra_span *m=malloc(span_count*sizeof *m);if(span_count&&!m){free(u);free(t);status=2;break;}
    memcpy(u,url,a);memcpy(t,text,b);if(span_count)memcpy(m,spans,span_count*sizeof *m);out->atoms[out->count++]=(fastra_atom){start,end,origin,u,t,a,b,m,span_count};
  }
  cmark_iter_free(iter);cmark_node_free(root);cmark_parser_free(parser);
  if(status)fastra_plan_free(out);
  return status;
}
