#include "folding_catalog.h"
#include <string.h>
typedef bool (*Stopped)(void *);
typedef bool (*Emit)(void *, uint32_t, uint32_t);
struct Input {
    const char *text;
    uint32_t size;
    Stopped stop;
    void *context;
    bool failed;
};

static const char *read_input(void *payload,uint32_t at,TSPoint point,uint32_t *length) {
    (void)point;
    struct Input *input=payload;
    if (input->stop(input->context)) input->failed=true;
    *length=input->failed||at>=input->size?0:input->size-at;
    if (*length>4096) *length=4096;
    return input->text+(at<input->size?at:input->size);
}

static bool progress(TSParseState *state) {
    struct Input *input=state->payload;
    return input->failed=input->stop(input->context);
}

static bool in_set(const char *kind,const char *const *set,size_t count) {
    for(size_t i=0;i<count;i++)if(!strcmp(kind,set[i]))return true;
    return false;
}

static uint32_t header_end(const char *text,uint32_t size,uint32_t at) {
    while(at<size) {
        const unsigned char *p=(const unsigned char *)text+at;
        if(*p=='\r'||*p=='\n'||(at+1<size&&p[0]==0xc2&&p[1]==0x85)||(at+2<size&&p[0]==0xe2&&p[1]==0x80&&(p[2]==0xa8||p[2]==0xa9)))break;
        at++;
    }
    return at;
}

/* Kein rekursiver AST-Walk: defekte/tiefe Eingaben bleiben abbrechbar. */
int fastra_folding_ranges(unsigned grammar,bool python,const char *text,uint32_t size,Stopped stop,Emit emit,void *context) {
    const TSLanguage *language=fold_language(grammar);
    if(!language)return 2;
    TSParser *parser=ts_parser_new();
    if(!parser)return 2;
    if(!ts_parser_set_language(parser,language)) {
        ts_parser_delete(parser);
        return 2;
    }
    struct Input input= {
        text,size,stop,context,false
    };
    TSTree *tree=ts_parser_parse_with_options(parser,NULL,(TSInput){&input,read_input,TSInputEncodingUTF8,NULL},(TSParseOptions){&input,progress});
    if(!tree||input.failed||stop(context)) {
        if(tree)ts_tree_delete(tree);
        ts_parser_delete(parser);
        return 1;
    }
    TSNode root=ts_tree_root_node(tree);
    TSTreeCursor cursor=ts_tree_cursor_new(root);
    const char *const bodies[]= {
        "function_body","class_body","enum_class_body","compound_statement","field_declaration_list","statement_block","declaration_list","struct_body","impl_body","interface_body"
    };
    const char *const controls[]= {
        "if_statement","for_statement","while_statement","repeat_while_statement","do_statement","guard_statement","switch_statement","catch_block"
    };
    unsigned depth=0;
    uint32_t visited=0;
    int status=0;
    bool done=false;
    while(!done) {
        if(++visited>2000000||depth>512) {
            status=3;
            break;
        }
        if((visited&255)==0&&stop(context)) {
            status=1;
            break;
        }
        TSNode node=ts_tree_cursor_current_node(&cursor);
        const char *kind=ts_node_type(node);
        bool valid=ts_node_is_named(node)&&strcmp(kind,"ERROR")&&!ts_node_is_missing(node)&&(!ts_node_has_error(node)||ts_node_eq(node,root));
        if(valid) {
            if(!ts_node_has_error(node)&&(in_set(kind,bodies,10)||in_set(kind,controls,8)||(!python&&!strcmp(kind,"block")))) {
                uint32_t opening=UINT32_MAX;
                for(uint32_t i=0,n=ts_node_child_count(node);i<n;i++) {
                    if((i&255)==0&&stop(context)) {
                        status=1;
                        break;
                    }
                    TSNode child=ts_node_child(node,i);
                    if(ts_node_is_missing(child))continue;
                    const char *type=ts_node_type(child);
                    if(!strcmp(type,"{"))opening=ts_node_end_byte(child);
                    if(!strcmp(type,"}")&&opening<ts_node_start_byte(child)) {
                        if(!emit(context,opening,ts_node_start_byte(child))) {
                            status=3;
                            break;
                        }
                        opening=UINT32_MAX;
                    }
                }
            } else if(python&&!strcmp(kind,"block")) {
                TSNode parent=ts_node_parent(node);
                uint32_t start=header_end(text,size,ts_node_start_byte(parent)),end=ts_node_end_byte(node);
                if(end>start&&!emit(context,start,end))status=3;
            }
        }
        if(status)break;
        if(valid&&ts_tree_cursor_goto_first_child(&cursor)) {
            depth++;
            continue;
        }
        while(!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if(!depth) {
                done=true;
                break;
            }
            ts_tree_cursor_goto_parent(&cursor);
            depth--;
        }
    }
    ts_tree_cursor_delete(&cursor);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
    return status;
}

unsigned fastra_folding_abi(unsigned grammar) {
    const TSLanguage *language=fold_language(grammar);
    return language?ts_language_abi_version(language):0;
}
