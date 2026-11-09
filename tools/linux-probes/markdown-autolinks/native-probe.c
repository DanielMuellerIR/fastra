#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cmark-gfm.h>
#include <cmark-gfm-extension_api.h>
#include <cmark-gfm-core-extensions.h>
#include <parser.h>
#include <fastra_metadata.h>
#include "markdown_autolinks.h"
typedef struct {size_t calls,stop;} owned_cancel;
static int owned_cancelled(void *context){owned_cancel *c=context;return ++c->calls==c->stop;}
static size_t cancel_at=0;
static int cancelled(void *context){fastra_control *c=context;return cancel_at && c->mail_map_steps>=cancel_at;}
int main(int argc,char **argv){
  (void)argc;cancel_at=argv[1]?strtoull(argv[1],NULL,10):0;
  size_t size=0,capacity=16*1024*1024;char *source=malloc(capacity+1);if(!source)return 4;size=fread(source,1,capacity+1,stdin);if(size>capacity||memchr(source,0,size))return 4;
  cmark_gfm_core_extensions_ensure_registered();cmark_parser *p=cmark_parser_new(CMARK_OPT_FOOTNOTES);fastra_control c={.cancelled=cancelled,.max_steps=20000000,.preserve_footnote_definitions=1};c.context=&c;p->fastra_control=&c;
  const char *names[]={"autolink","strikethrough","tagfilter","tasklist","table"};for(size_t i=0;i<5;i++)cmark_parser_attach_syntax_extension(p,cmark_find_syntax_extension(names[i]));
  cmark_parser_feed(p,source,size);cmark_node *root=cmark_parser_finish(p);size_t links=0;int valid=1;
  if(!c.status){cmark_iter *it=cmark_iter_new(root);cmark_event_type e;while((e=cmark_iter_next(it))!=CMARK_EVENT_DONE){cmark_node *n=cmark_iter_get_node(it);if(e==CMARK_EVENT_ENTER && cmark_node_get_type(n)==CMARK_NODE_LINK){int origin;size_t a,b;if(!fastra_node_link_metadata(n,&origin,&a,&b)||a>=b||b>size){valid=0;break;}if(origin<=FASTRA_MAIL){links++;if(size%18==0 && size>=18 && !memcmp(source,"a&#64;example.com ",18)){if(b-a!=17||memcmp(source+a,"a&#64;example.com",17))valid=0;}}}}cmark_iter_free(it);}
  printf("{\"status\":%d,\"links\":%zu,\"steps\":%zu,\"map_steps\":%zu,\"mail_map_steps\":%zu,\"valid\":%d}\n",c.status,links,c.steps,c.map_steps,c.mail_map_steps,valid);
  cmark_node_free(root);cmark_parser_free(p);
  if(!cancel_at){
    fastra_plan out={0};owned_cancel check={0};int status=fastra_plan_parse((const unsigned char *)source,size,owned_cancelled,&check,&out);
    if(status==0){for(size_t i=0;i<out.count;i++)if(out.atoms[i].start>=out.atoms[i].end||out.atoms[i].end>size)valid=0;}
    else if(out.count||out.atoms)valid=0;
    fastra_plan_free(&out);size_t total=check.calls;
    for(size_t i=0;i<3 && total>20;i++) {owned_cancel stop={.stop=i==0?1:(i==1?total/2:total-10)};int stopped=fastra_plan_parse((const unsigned char *)source,size,owned_cancelled,&stop,&out);if(stopped!=1||out.count||out.atoms)valid=0;fastra_plan_free(&out);}
  }
  free(source);return valid?0:3;
}
