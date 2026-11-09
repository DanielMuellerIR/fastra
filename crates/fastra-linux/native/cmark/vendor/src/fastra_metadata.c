#include "node.h"
#include "fastra_metadata.h"
#include <string.h>
void fastra_map_clear(cmark_mem *mem, fastra_map *m) { mem->free(m->spans); memset(m,0,sizeof *m); }
void fastra_map_append(cmark_mem *mem, fastra_map *m, size_t length, size_t a, size_t b, int identity) {
  m->tracked=1;
  if (!length) return;
  if (m->invalid || a>b || (identity && b-a!=length) || m->count>=500000) { m->invalid=1; return; }
  if (m->count && identity) {
    fastra_span *last=&m->spans[m->count-1];
    if (last->identity && last->hi==m->length && last->source_hi==a) { if(m->length/4096!=(m->length+length)/4096 && !fastra_map_work(m->control,0)){m->invalid=1;return;} last->hi+=length;last->source_hi=b;m->length+=length;return; }
  }
  if (!fastra_map_work(m->control,1)) {m->invalid=1;return;}
  if (m->count==m->capacity) {
    if (!fastra_map_work(m->control,m->count)) {m->invalid=1;return;}
    size_t n=m->capacity?m->capacity*2:4;
    fastra_span *p=mem->calloc(n,sizeof *p);
    if (!p) { m->invalid=1;return; }
    if (m->count) memcpy(p,m->spans,m->count*sizeof *p);
    mem->free(m->spans);m->spans=p;m->capacity=n;
  }
  m->spans[m->count++]=(fastra_span){m->length,m->length+length,a,b,identity};m->length+=length;
}
static int boundary(const fastra_span *s,size_t at,size_t *out) {
  if(at==s->lo) *out=s->source_lo;
  else if(at==s->hi) *out=s->source_hi;
  else if(s->identity && at>s->lo && at<s->hi) *out=s->source_lo+at-s->lo;
  else return 0;
  return 1;
}
static size_t first_span(const fastra_map *m,size_t at) {
  size_t lo=0,hi=m->count;while(lo<hi){size_t mid=lo+(hi-lo)/2;if(m->spans[mid].hi<=at)lo=mid+1;else hi=mid;}return lo;
}
void fastra_map_slice(cmark_mem *mem,const fastra_map *src,size_t a,size_t b,fastra_map *dst) {
  dst->tracked=1;
  dst->control=src->control;
  if(!src->tracked || src->invalid || a>b || b>src->length){dst->invalid=1;return;}
  for(size_t i=first_span(src,a);i<src->count;i++) {
    if(!fastra_map_work(src->control,1)){dst->invalid=1;return;}
    const fastra_span *s=&src->spans[i];if(s->hi<=a)continue;if(s->lo>=b)break;
    size_t lo=s->lo>a?s->lo:a,hi=s->hi<b?s->hi:b,x,y;
    if(!boundary(s,lo,&x)||!boundary(s,hi,&y)){dst->invalid=1;return;}
    fastra_map_append(mem,dst,hi-lo,x,y,s->identity);
  }
}
void fastra_map_join(cmark_mem *mem,fastra_map *dst,const fastra_map *src) {
  if(!dst->control)dst->control=src->control;
  if(!src->tracked || src->invalid){dst->invalid=1;return;}
  for(size_t i=0;i<src->count;i++){if(!fastra_map_work(dst->control,1)){dst->invalid=1;return;}const fastra_span *s=&src->spans[i];fastra_map_append(mem,dst,s->hi-s->lo,s->source_lo,s->source_hi,s->identity);}
}
void fastra_map_trim(cmark_mem *mem,fastra_map *m,size_t a,size_t b) {
  fastra_map out={0};fastra_map_slice(mem,m,a,b,&out);fastra_map_clear(mem,m);*m=out;
}
int fastra_map_range(const fastra_map *m,size_t a,size_t b,size_t *x,size_t *y) {
  if(!m->tracked||m->invalid||a>=b||b>m->length)return 0;
  int found=0;
  for(size_t i=first_span(m,a);i<m->count;i++) {if(!fastra_map_work(m->control,1))return 0;const fastra_span *s=&m->spans[i];if(s->hi<=a)continue;if(s->lo>=b)break;
    if(!found){if(!boundary(s,a,x))return 0;found=1;}
    if(b<=s->hi)return boundary(s,b,y);
  }
  return 0;
}
void fastra_link_range(cmark_node *n,const fastra_map *m,size_t a,size_t b,int origin) {
  n->fastra_origin=origin;n->fastra_valid=fastra_map_range(m,a,b,&n->fastra_start,&n->fastra_end);
}

int fastra_node_link_metadata(cmark_node *node,int *origin,size_t *start,size_t *end) {
  if (!node || node->type!=CMARK_NODE_LINK || !node->fastra_valid || !node->fastra_origin || node->fastra_start>=node->fastra_end) return 0;
  *origin=node->fastra_origin;*start=node->fastra_start;*end=node->fastra_end;return 1;
}
void fastra_map_compose(cmark_mem *mem,const fastra_map *local,const fastra_map *source,fastra_map *out) {
  if (!local->tracked || local->invalid || !source->tracked || source->invalid){out->invalid=1;return;}
  out->tracked=1;
  out->control=source->control?source->control:local->control;
  for(size_t i=0;i<local->count;i++) {
    if(!fastra_map_work(out->control,1)){out->invalid=1;return;}
    const fastra_span *s=&local->spans[i];size_t a,b;
    if(s->identity){fastra_map part={0};fastra_map_slice(mem,source,s->source_lo,s->source_hi,&part);fastra_map_join(mem,out,&part);fastra_map_clear(mem,&part);}
    else if(fastra_map_range(source,s->source_lo,s->source_hi,&a,&b))fastra_map_append(mem,out,s->hi-s->lo,a,b,0);
    else out->invalid=1;
  }
}

#include "parser.h"
static int control_work(fastra_control *control,size_t amount,int maps) {
  if (!control) return 1;
  if (control->status) return 0;
  if (amount > SIZE_MAX-control->steps || (maps && amount > SIZE_MAX-control->map_steps) ||
      (control->max_steps && amount > control->max_steps-control->steps)) {control->status=2;return 0;}
  control->steps+=amount;
  if(maps){control->map_steps+=amount;if(control->in_mail_map)control->mail_map_steps+=amount;}
  if(control->cancelled && control->cancelled(control->context)){control->status=1;return 0;}
  return 1;
}
int fastra_parser_check(cmark_parser *parser) {return !parser || control_work(parser->fastra_control,1,0);}
int fastra_map_work(fastra_control *control,size_t amount){return control_work(control,amount,1);}

int fastra_node_literal_metadata(cmark_node *node,const fastra_span **spans,size_t *count,size_t *length) {
  if(!node||node->type!=CMARK_NODE_TEXT||!node->fastra_source.tracked||node->fastra_source.invalid||node->fastra_source.length!=(size_t)node->as.literal.len)return 0;
  *spans=node->fastra_source.spans;*count=node->fastra_source.count;*length=node->fastra_source.length;return 1;
}
