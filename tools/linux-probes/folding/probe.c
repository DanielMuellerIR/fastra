#include <tree_sitter/api.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern const TSLanguage *tree_sitter_rust(void);
extern const TSLanguage *tree_sitter_python(void);
extern const TSLanguage *tree_sitter_markdown(void);
struct Range { uint32_t a,b; }; static struct Range ranges[256]; static size_t count;
static bool one_of(const char *kind,const char **set,size_t n){for(size_t i=0;i<n;i++)if(!strcmp(kind,set[i]))return true;return false;}
static void add(const char *text,uint32_t a,uint32_t b){if(a>=b)return;for(uint32_t i=a;i<b;i++)if(text[i]=='\r'||text[i]=='\n'){assert(count<256);ranges[count++]=(struct Range){a,b};return;}}
static void collect(TSNode node,const char *text,bool python){
 const char *kind=ts_node_type(node);if(!strcmp(kind,"ERROR")||ts_node_is_missing(node))return;
 if(ts_node_has_error(node)&&strcmp(kind,"source_file")&&strcmp(kind,"module")&&strcmp(kind,"document"))return;
 const char *bodies[]={"function_body","class_body","enum_class_body","compound_statement","field_declaration_list","statement_block","declaration_list","struct_body","impl_body","interface_body"};
 const char *controls[]={"if_statement","for_statement","while_statement","repeat_while_statement","do_statement","guard_statement","switch_statement","catch_block"};
 if(!ts_node_has_error(node)&&(one_of(kind,bodies,10)||one_of(kind,controls,9)||(!python&&!strcmp(kind,"block")))){
  uint32_t opening=UINT32_MAX;
  for(uint32_t i=0;i<ts_node_child_count(node);i++){TSNode child=ts_node_child(node,i);if(ts_node_is_missing(child))continue;const char *name=ts_node_type(child);if(!strcmp(name,"{"))opening=ts_node_end_byte(child);if(!strcmp(name,"}")&&opening!=UINT32_MAX){add(text,opening,ts_node_start_byte(child));opening=UINT32_MAX;}}
 }else if(python&&!strcmp(kind,"block")){
  TSNode parent=ts_node_parent(node);uint32_t start=ts_node_start_byte(parent);while(text[start]&&text[start]!='\n'&&text[start]!='\r')start++;add(text,start,ts_node_end_byte(node));
 }
 for(uint32_t i=0;i<ts_node_named_child_count(node);i++)collect(ts_node_named_child(node,i),text,python);
}
static int compare(const void *a,const void *b){const struct Range *x=a,*y=b;return x->a!=y->a?(x->a<y->a?-1:1):(x->b>y->b?-1:x->b<y->b);}
static void run(const char *name,const TSLanguage *language,const char *text,size_t expected,bool valid){
 TSParser *parser=ts_parser_new();assert(ts_parser_set_language(parser,language));TSTree *tree=ts_parser_parse_string(parser,NULL,text,(uint32_t)strlen(text));assert(tree);TSNode root=ts_tree_root_node(tree);assert(ts_node_has_error(root)!=valid);count=0;collect(root,text,!strcmp(name,"python"));qsort(ranges,count,sizeof(ranges[0]),compare);
 struct Range stack[256];size_t depth=0,kept=0;printf("{\"language\":\"%s\",\"grammar_abi\":%u,\"ranges\":[",name,ts_language_abi_version(language));
 for(size_t i=0;i<count;i++){struct Range r=ranges[i];while(depth&&r.a>=stack[depth-1].b)depth--;if(depth&&(r.a==stack[depth-1].a||r.b>stack[depth-1].b))continue;assert(r.b<=strlen(text));printf("%s[%u,%u,%zu]",kept?",":"",r.a,r.b,depth+1);stack[depth++]=r;kept++;}
 printf("],\"source_unchanged\":true}\n");assert(kept==expected);ts_tree_delete(tree);ts_parser_delete(parser);
}
int main(void){
 run("rust",tree_sitter_rust(),"fn run(x: bool) {\r\nif x {\r\nprintln!(\"😀 }\");\r\n} else {\r\nprintln!(\"no\");\r\n}\r\n}\r\n",3,true);
 run("python",tree_sitter_python(),"def run(x):\r\n    if x:\r\n        print('😀')\r\n    else:\r\n        print('no')\r\n",3,true);
 run("markdown",tree_sitter_markdown(),"# Heading\r\n\r\nText 😀\r\n\r\n```rust\r\nfn f() {}\r\n```\r\n",0,true);
 run("rust-broken",tree_sitter_rust(),"fn f() {\n if true {\n println!(\"}\");\n",0,false);
 puts("FOLD_SHARED_POLICY_LINUX_PASS fixtures=4 grammars=3");return 0;
}
