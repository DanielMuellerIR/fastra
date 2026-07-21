#ifndef FASTRA_MARKDOWN_MARK_H
#define FASTRA_MARKDOWN_MARK_H

#include <cmark-gfm.h>
#include <cmark-gfm-extension_api.h>

/// Erzeugt eine lokale cmark-Inline-Erweiterung für `==Textmarker==`.
/// Der Aufrufer behält den Besitz und gibt sie mit der passenden Funktion frei.
cmark_syntax_extension *fastra_mark_extension_new(void);

/// Gibt eine nicht mehr an einen Parser gebundene Fastra-Mark-Erweiterung frei.
void fastra_mark_extension_free(cmark_syntax_extension *extension);

#endif
