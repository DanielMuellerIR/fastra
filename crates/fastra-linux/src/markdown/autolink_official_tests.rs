use super::autolink_tests::links;
#[test]
fn official_autolink_0() {
    let source = r###": http://google.com https://google.com

<http://google.com/å> http://google.com/å

scyther@pokemon.com

scy.the_rbe-edr+ill@pokemon.com

scyther@pokemon.com.

scyther@pokemon.com/

scyther@pokemon.com/beedrill@pokemon.com

mailto:scyther@pokemon.com

This is a mailto:scyther@pokemon.com

mailto:scyther@pokemon.com.

mmmmailto:scyther@pokemon.com

mailto:scyther@pokemon.com/

mailto:scyther@pokemon.com/message

mailto:scyther@pokemon.com/mailto:beedrill@pokemon.com

xmpp:scyther@pokemon.com

xmpp:scyther@pokemon.com.

xmpp:scyther@pokemon.com/message

xmpp:scyther@pokemon.com/message.

Email me at:scyther@pokemon.com

www.github.com www.github.com/á

www.google.com/a_b

Underscores not allowed in host name www.xxx.yyy._zzz

Underscores not allowed in host name www.xxx._yyy.zzz

Underscores allowed in domain name www._xxx.yyy.zzz

**Autolink and http://inlines**

![http://inline.com/image](http://inline.com/image)

a.w@b.c

Full stop outside parens shouldn't be included http://google.com/ok.

(Full stop inside parens shouldn't be included http://google.com/ok.)

"http://google.com"

'http://google.com'

http://🍄.ga/ http://x🍄.ga/"###;
    let expected = vec![
        (
            r###"http://google.com"###.to_owned(),
            r###"http://google.com"###.to_owned(),
            2..19,
        ),
        (
            r###"https://google.com"###.to_owned(),
            r###"https://google.com"###.to_owned(),
            20..38,
        ),
        (
            r###"http://google.com/å"###.to_owned(),
            r###"http://google.com/å"###.to_owned(),
            40..62,
        ),
        (
            r###"http://google.com/å"###.to_owned(),
            r###"http://google.com/å"###.to_owned(),
            63..83,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            85..104,
        ),
        (
            r###"mailto:scy.the_rbe-edr+ill@pokemon.com"###.to_owned(),
            r###"scy.the_rbe-edr+ill@pokemon.com"###.to_owned(),
            106..137,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            139..158,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            161..180,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            183..202,
        ),
        (
            r###"mailto:beedrill@pokemon.com"###.to_owned(),
            r###"beedrill@pokemon.com"###.to_owned(),
            203..223,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            225..251,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            263..289,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            291..317,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            330..349,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            351..377,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            380..406,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            416..442,
        ),
        (
            r###"mailto:beedrill@pokemon.com"###.to_owned(),
            r###"mailto:beedrill@pokemon.com"###.to_owned(),
            443..470,
        ),
        (
            r###"xmpp:scyther@pokemon.com"###.to_owned(),
            r###"xmpp:scyther@pokemon.com"###.to_owned(),
            472..496,
        ),
        (
            r###"xmpp:scyther@pokemon.com"###.to_owned(),
            r###"xmpp:scyther@pokemon.com"###.to_owned(),
            498..522,
        ),
        (
            r###"xmpp:scyther@pokemon.com/message"###.to_owned(),
            r###"xmpp:scyther@pokemon.com/message"###.to_owned(),
            525..557,
        ),
        (
            r###"xmpp:scyther@pokemon.com/message"###.to_owned(),
            r###"xmpp:scyther@pokemon.com/message"###.to_owned(),
            559..591,
        ),
        (
            r###"mailto:scyther@pokemon.com"###.to_owned(),
            r###"scyther@pokemon.com"###.to_owned(),
            606..625,
        ),
        (
            r###"http://www.github.com"###.to_owned(),
            r###"www.github.com"###.to_owned(),
            627..641,
        ),
        (
            r###"http://www.github.com/á"###.to_owned(),
            r###"www.github.com/á"###.to_owned(),
            642..659,
        ),
        (
            r###"http://www.google.com/a_b"###.to_owned(),
            r###"www.google.com/a_b"###.to_owned(),
            661..679,
        ),
        (
            r###"http://www._xxx.yyy.zzz"###.to_owned(),
            r###"www._xxx.yyy.zzz"###.to_owned(),
            826..842,
        ),
        (
            r###"http://inlines"###.to_owned(),
            r###"http://inlines"###.to_owned(),
            859..873,
        ),
        (
            r###"mailto:a.w@b.c"###.to_owned(),
            r###"a.w@b.c"###.to_owned(),
            930..937,
        ),
        (
            r###"http://google.com/ok"###.to_owned(),
            r###"http://google.com/ok"###.to_owned(),
            986..1006,
        ),
        (
            r###"http://google.com/ok"###.to_owned(),
            r###"http://google.com/ok"###.to_owned(),
            1056..1076,
        ),
        (
            r###"http://google.com"###.to_owned(),
            r###"http://google.com"###.to_owned(),
            1081..1098,
        ),
        (
            r###"http://google.com"###.to_owned(),
            r###"http://google.com"###.to_owned(),
            1102..1119,
        ),
        (
            r###"http://🍄.ga/"###.to_owned(),
            r###"http://🍄.ga/"###.to_owned(),
            1122..1137,
        ),
        (
            r###"http://x🍄.ga/"###.to_owned(),
            r###"http://x🍄.ga/"###.to_owned(),
            1138..1154,
        ),
    ];
    assert_eq!(links(source, true), expected);
}
#[test]
fn official_autolink_1() {
    let source = r###"This shouldn't crash everything: (_A_@_.A"###;
    let expected = vec![];
    assert_eq!(links(source, true), expected);
}
#[test]
fn official_autolink_2() {
    let source = r###"These should not link:

* @a.b.c@. x
* n@.  b"###;
    let expected = vec![];
    assert_eq!(links(source, true), expected);
}
