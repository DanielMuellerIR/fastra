#include <unicode/uchar.h>
#include <stdint.h>
#include <unicode/ubrk.h>
#include <unicode/unorm2.h>
#include <unicode/ucol.h>
#include <unicode/uregex.h>
#include <unicode/ustring.h>
#include <unicode/uloc.h>
#include <unicode/uvernum.h>

#if U_ICU_VERSION_MAJOR_NUM != 78 || U_ICU_VERSION_MINOR_NUM != 3
#error "Fastra requires the ICU 78.3 headers; check the actual pkg-config prefix."
#endif

void *fastra_regex_open(const uint16_t *pattern, int32_t length, uint32_t flags,
                       int32_t *offset, int32_t *status) {
    UParseError error = {0};
    URegularExpression *regex = uregex_open(pattern, length, flags, &error, status);
    *offset = error.offset;
    return regex;
}
void fastra_regex_close(void *regex) { uregex_close(regex); }
void *fastra_regex_clone(const void *regex, int32_t *status) { return uregex_clone(regex, status); }
void fastra_regex_text(void *regex, const uint16_t *text, int32_t length, int32_t *status) {
    uregex_setText(regex, text, length, status);
}
void fastra_regex_limits(void *regex, int32_t time, int32_t stack, int32_t *status) {
    uregex_setTimeLimit(regex, time, status);
    uregex_setStackLimit(regex, stack, status);
}
void fastra_regex_callback(void *regex, URegexMatchCallback *callback,
                           const void *context, int32_t *status) {
    uregex_setMatchCallback(regex, callback, context, status);
}
int32_t fastra_regex_next(void *regex, int32_t *status) { return uregex_findNext(regex, status); }
int32_t fastra_regex_groups(void *regex, int32_t *status) { return uregex_groupCount(regex, status); }
int32_t fastra_regex_start(void *regex, int32_t group, int32_t *status) { return uregex_start(regex, group, status); }
int32_t fastra_regex_end(void *regex, int32_t group, int32_t *status) { return uregex_end(regex, group, status); }
int32_t fastra_case(const uint16_t *text, int32_t length, uint16_t *output,
                   int32_t capacity, int32_t upper, const char *locale, int32_t *status) {
    return upper ? u_strToUpper(output, capacity, text, length, locale, status)
                 : u_strToLower(output, capacity, text, length, locale, status);
}
int32_t fastra_locale_known(const char *locale) {
    const char *language = uloc_getISO3Language(locale);
    return language != NULL && language[0] != '\0';
}
int32_t fastra_titlecase(const uint16_t *text, int32_t length, uint16_t *output,
                        int32_t capacity, const char *locale, int32_t *status) {
    /* Foundation-Referenzen verwenden diese Wortgrenzen auch bei anderer Casing-Locale. */
    UBreakIterator *words = ubrk_open(UBRK_WORD, "en_US_POSIX", text, length, status);
    if (U_FAILURE(*status)) { return 0; }
    int32_t result = u_strToTitle(output, capacity, text, length, words, locale, status);
    ubrk_close(words);
    return result;
}
void *fastra_graphemes_open(const uint16_t *text, int32_t length, int32_t *status) {
    return ubrk_open(UBRK_CHARACTER, "", text, length, status);
}
int32_t fastra_graphemes_next(void *iterator) { return ubrk_next(iterator); }
void fastra_graphemes_close(void *iterator) { ubrk_close(iterator); }

int32_t fastra_normalize(const uint16_t *text, int32_t length, uint16_t *output,
                        int32_t capacity, int32_t nfc, int32_t *status) {
    const UNormalizer2 *normalizer = nfc ? unorm2_getNFCInstance(status)
                                       : unorm2_getNFDInstance(status);
    if (U_FAILURE(*status)) { return 0; }
    return unorm2_normalize(normalizer, text, length, output, capacity, status);
}
void *fastra_collator_open(int32_t numeric, int32_t case_sensitive, int32_t *status) {
    UCollator *collator = ucol_open("root", status);
    if (U_FAILURE(*status)) { return NULL; }
    ucol_setAttribute(collator, UCOL_STRENGTH,
                      case_sensitive ? UCOL_TERTIARY : UCOL_SECONDARY, status);
    ucol_setAttribute(collator, UCOL_NUMERIC_COLLATION, numeric ? UCOL_ON : UCOL_OFF, status);
    ucol_setAttribute(collator, UCOL_NORMALIZATION_MODE, UCOL_ON, status);
    if (U_FAILURE(*status)) { ucol_close(collator); return NULL; }
    return collator;
}
/* Fester Produktvertrag; keine Nachbildung von Finders erzwungener Ordnung. */
void *fastra_localized_collator_open(const char *locale, int32_t *status) {
    UCollator *collator = ucol_open(locale, status);
    if (U_FAILURE(*status)) { return NULL; }
    ucol_setAttribute(collator, UCOL_STRENGTH, UCOL_TERTIARY, status);
    ucol_setAttribute(collator, UCOL_CASE_LEVEL, UCOL_OFF, status);
    ucol_setAttribute(collator, UCOL_CASE_FIRST, UCOL_LOWER_FIRST, status);
    ucol_setAttribute(collator, UCOL_ALTERNATE_HANDLING, UCOL_NON_IGNORABLE, status);
    ucol_setAttribute(collator, UCOL_NUMERIC_COLLATION, UCOL_ON, status);
    ucol_setAttribute(collator, UCOL_NORMALIZATION_MODE, UCOL_ON, status);
    if (U_FAILURE(*status)) { ucol_close(collator); return NULL; }
    return collator;
}
void fastra_collator_close(void *collator) { ucol_close(collator); }
int32_t fastra_collator_key(const void *collator, const uint16_t *text,
                           int32_t length, uint8_t *output, int32_t capacity) {
    return ucol_getSortKey(collator, text, length, output, capacity);
}

uint32_t fastra_scalar_flags(int32_t scalar) {
    uint32_t flags = 0;
    if (U_MASK(u_charType(scalar)) & (U_GC_L_MASK | U_GC_M_MASK | U_GC_N_MASK)) flags |= 1;
    if (u_getIntPropertyValue(scalar, UCHAR_GRAPHEME_CLUSTER_BREAK) == U_GCB_EXTEND) flags |= 2;
    if (scalar >= 0x80 && u_hasBinaryProperty(scalar, UCHAR_EMOJI)
        && !u_hasBinaryProperty(scalar, UCHAR_EMOJI_PRESENTATION)
        && scalar != 0xA9 && scalar != 0xAE && scalar != 0x2122
        && scalar != 0x203C && scalar != 0x2049) flags |= 4;
    if (u_getIntPropertyValue(scalar, UCHAR_DECOMPOSITION_TYPE) == U_DT_CANONICAL) flags |= 8;
    return flags;
}
int32_t fastra_combining_class(int32_t scalar) { return u_getCombiningClass(scalar); }

int32_t fastra_scalar_decimal_digit(int32_t scalar) {
    return u_charDigitValue(scalar);
}
