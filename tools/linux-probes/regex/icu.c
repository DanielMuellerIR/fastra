#include <unicode/uregex.h>
#include <unicode/uversion.h>
#include <stdint.h>
// Nur die Probe kapselt die versionsgebundenen ICU-Symbole hinter einer C-Grenze.
void *probe_open(const uint16_t *p, int32_t n, uint32_t flags, int32_t *status) {
    UParseError error;
    return uregex_open(p, n, flags, &error, status);
}
void probe_text(void *r, const uint16_t *p, int32_t n, int32_t *s) { uregex_setText(r,p,n,s); }
int32_t probe_next(void *r,int32_t *s) { return uregex_findNext(r,s); }
int32_t probe_groups(void *r,int32_t *s) { return uregex_groupCount(r,s); }
int32_t probe_start(void *r,int32_t g,int32_t *s) { return uregex_start(r,g,s); }
int32_t probe_end(void *r,int32_t g,int32_t *s) { return uregex_end(r,g,s); }
int32_t probe_replace(void *r,const uint16_t *p,int32_t n,uint16_t *out,int32_t cap,int32_t *s) {
    return uregex_replaceAll(r,p,n,out,cap,s);
}
void probe_limit(void *r,int32_t *s) { uregex_setTimeLimit(r,25,s); uregex_setStackLimit(r,1048576,s); }
void probe_close(void *r) { uregex_close(r); }
#include <unicode/ubrk.h>
#include <unicode/ustring.h>
int32_t probe_case(const uint16_t *p,int32_t n,uint16_t *out,int32_t cap,int32_t upper,int32_t *s) {
    return upper ? u_strToUpper(out,cap,p,n,"",s) : u_strToLower(out,cap,p,n,"",s);
}
int32_t probe_first_grapheme(const uint16_t *p,int32_t n,int32_t *s) {
    UBreakIterator *b=ubrk_open(UBRK_CHARACTER,"",p,n,s);
    if (!b) return 0;
    int32_t length=ubrk_next(b);ubrk_close(b);return length;
}
void probe_region(void *r,int32_t start,int32_t end,int32_t *s) { uregex_setRegion(r,start,end,s); }
static UBool stop_match(const void *context,int32_t steps) { return 0; }
void probe_cancel(void *r,int32_t *s) { uregex_setMatchCallback(r,stop_match,0,s); }
