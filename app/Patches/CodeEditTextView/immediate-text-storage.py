import os
import sys

(
    obsolete_swift_path,
    header_path,
    implementation_path,
    modulemap_path,
    text_view_path,
    set_text_path,
) = sys.argv[1:]
text_view = open(text_view_path).read()
set_text = open(set_text_path).read()
modulemap = open(modulemap_path).read()

# Nur pruefen und vormerken — geloescht wird erst nach allen Validierungen
# am Ende, damit ein Anker-Fehlschlag keinen halb gepatchten Stand hinterlaesst.
remove_obsolete_swift = False
if os.path.exists(obsolete_swift_path):
    obsolete = open(obsolete_swift_path).read()
    if "Fastra-Patch: vollstaendige Attribute ohne spaetes AppKit-Fixing" not in obsolete:
        raise SystemExit(
            f"{obsolete_swift_path}: fremde Datei kollidiert mit Patch 4z12"
        )
    remove_obsolete_swift = True

header = '''// Fastra-Patch: vollstaendige Attribute ohne spaetes AppKit-Fixing.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Klartextspeicher, dessen vollstaendige Schrift- und Farbattribute nicht
/// beim ersten CoreText-Layout noch einmal von AppKit repariert werden.
@interface ImmediateAttributeTextStorage : NSTextStorage {
@private
    NSMutableAttributedString *_backing;
}

- (instancetype)initWithString:(NSString *)string;
- (instancetype)initWithString:(NSString *)string
                     attributes:(nullable NSDictionary<NSAttributedStringKey, id> *)attributes;

@end

NS_ASSUME_NONNULL_END
'''

implementation = '''// Fastra-Patch: vollstaendige Attribute ohne spaetes AppKit-Fixing.

#import "ImmediateAttributeTextStorage.h"

@implementation ImmediateAttributeTextStorage

- (instancetype)initWithString:(NSString *)string {
    return [self initWithString:string attributes:nil];
}

- (instancetype)initWithString:(NSString *)string
                     attributes:(NSDictionary<NSAttributedStringKey, id> *)attributes {
    self = [super init];
    if (self) {
        _backing = [[NSMutableAttributedString alloc] initWithString:string
                                                          attributes:attributes];
    }
    return self;
}

- (NSString *)string {
    return _backing.string;
}

- (BOOL)fixesAttributesLazily {
    return NO;
}

- (void)fixAttributesInRange:(NSRange)range {
    // Fastra-Patch: Editorattribute brauchen keine Absatzkorrektur.
    // Schrift, Farbe und Absatzdaten gehoeren dem Editor; CoreText formt
    // Glyphen samt Schriftfallback. Editing- und Delegate-Meldungen bleiben.
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)location
                                                 effectiveRange:(NSRangePointer)range {
    return [_backing attributesAtIndex:location effectiveRange:range];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string {
    [self beginEditing];
    [_backing replaceCharactersInRange:range withString:string];
    [self edited:NSTextStorageEditedCharacters
           range:range
  changeInLength:(NSInteger)string.length - (NSInteger)range.length];
    [self endEditing];
}

- (void)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes
                 range:(NSRange)range {
    [self beginEditing];
    [_backing setAttributes:attributes range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
    [self endEditing];
}

@end
'''

if 'header "ImmediateAttributeTextStorage.h"' not in modulemap:
    marker = '    header "CGContextHidden.h"\n'
    if marker not in modulemap:
        raise SystemExit(
            f"{modulemap_path}: Headerliste hat sich geaendert — Patch 4z12 pruefen"
        )
    modulemap = modulemap.replace(
        marker,
        marker + '    header "ImmediateAttributeTextStorage.h"\n',
        1,
    )

for path, source in ((text_view_path, text_view), (set_text_path, set_text)):
    if "import CodeEditTextViewObjC" not in source:
        marker = "import AppKit\n"
        if marker not in source:
            raise SystemExit(
                f"{path}: AppKit-Import hat sich geaendert — Patch 4z12 pruefen"
            )
        source = source.replace(marker, marker + "import CodeEditTextViewObjC\n", 1)
    if path == text_view_path:
        text_view = source
    else:
        set_text = source

old_storage_init = '''        self.textStorage = NSTextStorage(string: string)
        self.delegate = delegate'''
new_storage_init = '''        let initialTypingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        // Fastra-Patch: intern erzeugter Klartext startet bereits mit einem
        // vollstaendigen Attributsatz und braucht kein spaetes AppKit-Fixing.
        self.textStorage = ImmediateAttributeTextStorage(
            string: string,
            attributes: initialTypingAttributes
        )
        self.delegate = delegate'''
if "attributes: initialTypingAttributes" not in text_view:
    if old_storage_init not in text_view:
        raise SystemExit(
            f"{text_view_path}: TextStorage-Aufbau hat sich geaendert — Patch 4z12 pruefen"
        )
    text_view = text_view.replace(old_storage_init, new_storage_init, 1)

old_typing_attributes = '''        self.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]

        textStorage.addAttributes(typingAttributes, range: documentRange)'''
new_typing_attributes = '''        self.typingAttributes = initialTypingAttributes'''
if old_typing_attributes in text_view:
    text_view = text_view.replace(old_typing_attributes, new_typing_attributes, 1)
elif new_typing_attributes not in text_view:
    raise SystemExit(
        f"{text_view_path}: initiale Attribute haben sich geaendert — Patch 4z12 pruefen"
    )

old_set_text = '''        let newStorage = NSTextStorage(string: text)
        self.setTextStorage(newStorage)'''
new_set_text = '''        let newStorage = ImmediateAttributeTextStorage(
            string: text,
            attributes: typingAttributes
        )
        self.setTextStorage(newStorage)'''
if "attributes: typingAttributes" not in set_text:
    if old_set_text not in set_text:
        raise SystemExit(
            f"{set_text_path}: setText-Aufbau hat sich geaendert — Patch 4z12 pruefen"
        )
    set_text = set_text.replace(old_set_text, new_set_text, 1)

old_apply_attributes = '''        textStorage.addAttributes(typingAttributes, range: documentRange)
        layoutManager.textStorage = textStorage'''
new_apply_attributes = '''        // Intern erzeugter Speicher erhielt diesen Satz schon atomar im
        // Initializer. Nur fremde NSTextStorage-Instanzen nachruesten.
        if !(textStorage is ImmediateAttributeTextStorage) {
            textStorage.addAttributes(typingAttributes, range: documentRange)
        }
        layoutManager.textStorage = textStorage'''
if "if !(textStorage is ImmediateAttributeTextStorage)" not in set_text:
    if old_apply_attributes not in set_text:
        raise SystemExit(
            f"{set_text_path}: Attributuebernahme hat sich geaendert — Patch 4z12 pruefen"
        )
    set_text = set_text.replace(old_apply_attributes, new_apply_attributes, 1)

# Erst nach allen Validierungen schreiben und aufraeumen — gemeinsam,
# damit kein halb gepatchter Checkout zurueckbleiben kann.
open(header_path, "w").write(header)
open(implementation_path, "w").write(implementation)
open(text_view_path, "w").write(text_view)
open(set_text_path, "w").write(set_text)
open(modulemap_path, "w").write(modulemap)
if remove_obsolete_swift:
    os.remove(obsolete_swift_path)
